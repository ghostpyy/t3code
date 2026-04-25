import Foundation
import CoreServices

/// File-watched, in-memory index of every `.swift` file under a project root.
/// Indexed lazily on first use, kept fresh via `FSEventStream`. Per-file data
/// is line-split once so `SourceResolver` can substring-match in O(lines) per
/// query instead of re-reading from disk on every hit-test.
///
/// Replaces the 8-second TTL cache that used to live in `AXSourceInference`.
/// That cache ate up to 60 ms on every hit-test when the cached copy had just
/// expired; the live index amortizes that cost to first-use plus debounced
/// rebuilds on actual edits.
public final class SourceIndex: @unchecked Sendable {
    public struct FileEntry: Sendable {
        public let path: String
        public let filename: String
        public let lines: [String]
        public let lowercasedLines: [String]
    }

    public struct SearchHit: Sendable, Equatable {
        public let path: String
        public let line: Int
        public let context: String
    }

    public static let shared = SourceIndex()

    private let queue = DispatchQueue(
        label: "t3.simbridge.source-index",
        qos: .utility
    )
    private var files: [String: [String: FileEntry]] = [:]
    private var streams: [String: FSEventStreamRef] = [:]
    private var pendingRebuild: [String: DispatchWorkItem] = [:]
    private let rebuildDebounce: TimeInterval = 0.15

    private init() {}

    /// Register a project root. Cheap when the root is already indexed.
    public func ensureIndexed(root: String) {
        let normalized = normalize(root)
        queue.sync { _ = ensureIndexedLocked(root: normalized) }
    }

    public func files(in root: String) -> [FileEntry] {
        let normalized = normalize(root)
        return queue.sync {
            Array((files[normalized] ?? [:]).values)
        }
    }

    public func entry(for absolutePath: String) -> FileEntry? {
        let canonical = normalize(absolutePath)
        return queue.sync {
            for (root, bucket) in files where canonical.hasPrefix(root) {
                if let entry = bucket[canonical] { return entry }
            }
            return nil
        }
    }

    public func line(at path: String, line: Int) -> String? {
        guard let entry = entry(for: path),
              line >= 1, line <= entry.lines.count else { return nil }
        return entry.lines[line - 1]
    }

    public struct Snippet: Sendable, Equatable {
        public let text: String
        public let startLine: Int
    }

    /// Neighborhood around `line` — `context` lines above and below, clamped
    /// to file bounds. Returns nil for unindexed paths or out-of-range lines
    /// so callers can cheaply skip snippet emission when we don't actually
    /// have ground truth.
    public func snippet(at path: String, line: Int, context: Int = 6) -> Snippet? {
        guard let entry = entry(for: path),
              entry.lines.count > 0,
              line >= 1, line <= entry.lines.count else { return nil }
        let span = max(0, context)
        let start = max(1, line - span)
        let end = min(entry.lines.count, line + span)
        let slice = entry.lines[(start - 1)...(end - 1)]
        return Snippet(text: slice.joined(separator: "\n"), startLine: start)
    }

    /// Find an indexed file whose last path component matches `filename`.
    /// When multiple files share the name, prefer one whose path contains
    /// `/<module>/` — matches SwiftUI `#fileID` layout conventions.
    public func resolveByFilename(
        _ filename: String,
        module: String?,
        in root: String
    ) -> String? {
        let normalized = normalize(root)
        return queue.sync {
            guard let bucket = files[normalized] else { return nil }
            let matches = bucket.values.filter { $0.filename == filename }
            if matches.isEmpty { return nil }
            if matches.count == 1 { return matches[0].path }
            if let module {
                if let byModule = matches.first(where: {
                    $0.path.contains("/\(module)/")
                }) { return byModule.path }
            }
            return matches.map(\.path).sorted().first
        }
    }

    public func search(token: String, in root: String, limit: Int = 64) -> [SearchHit] {
        let needle = token.lowercased()
        guard !needle.isEmpty else { return [] }
        let normalized = normalize(root)
        return queue.sync {
            guard let bucket = files[normalized] else { return [] }
            var hits: [SearchHit] = []
            for entry in bucket.values {
                for (idx, line) in entry.lowercasedLines.enumerated()
                where line.contains(needle) {
                    hits.append(SearchHit(
                        path: entry.path,
                        line: idx + 1,
                        context: entry.lines[idx]
                    ))
                    if hits.count >= limit { return hits }
                }
            }
            return hits
        }
    }

    // MARK: - private

    private func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    @discardableResult
    private func ensureIndexedLocked(root: String) -> Bool {
        if files[root] != nil { return false }
        var bucket: [String: FileEntry] = [:]
        walk(root: root, into: &bucket)
        files[root] = bucket
        startWatcher(root: root)
        return true
    }

    private func walk(root: String, into bucket: inout [String: FileEntry]) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else { return }
        while let next = enumerator.nextObject() as? String {
            if shouldSkip(relative: next) {
                enumerator.skipDescendants()
                continue
            }
            guard next.hasSuffix(".swift") else { continue }
            let absolute = "\(root)/\(next)"
            if let entry = readEntry(at: absolute) {
                bucket[entry.path] = entry
            }
        }
    }

    private func readEntry(at path: String) -> FileEntry? {
        let canonical = normalize(path)
        guard let contents = try? String(
            contentsOfFile: canonical, encoding: .utf8
        ) else { return nil }
        let lines = contents.components(separatedBy: .newlines)
        return FileEntry(
            path: canonical,
            filename: (canonical as NSString).lastPathComponent,
            lines: lines,
            lowercasedLines: lines.map { $0.lowercased() }
        )
    }

    private func shouldSkip(relative: String) -> Bool {
        let segments = relative.split(separator: "/")
        return segments.contains(".build") ||
            segments.contains("DerivedData") ||
            segments.contains("Pods") ||
            segments.contains("xcuserdata") ||
            segments.contains(".swiftpm") ||
            segments.contains("Preview Content") ||
            segments.contains(".git") ||
            segments.contains("node_modules")
    }

    private func startWatcher(root: String) {
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let this = Unmanaged<SourceIndex>
                .fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<NSArray>
                .fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            _ = count
            this.handleFSEvents(paths: list)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &ctx,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        streams[root] = stream
    }

    /// Invoked on `queue` (FSEventStreamSetDispatchQueue wires that).
    /// Debounces per-path so a burst of `.swift` saves (e.g. a file-format
    /// pass in Xcode) collapses into a single rebuild.
    private func handleFSEvents(paths: [String]) {
        for raw in paths {
            let canonical = normalize(raw)
            pendingRebuild[canonical]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.rebuild(path: canonical)
            }
            pendingRebuild[canonical] = work
            queue.asyncAfter(deadline: .now() + rebuildDebounce, execute: work)
        }
    }

    private func rebuild(path: String) {
        pendingRebuild.removeValue(forKey: path)
        guard let root = files.keys.first(where: { path.hasPrefix($0) }) else { return }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)

        if path.hasSuffix(".swift") {
            if exists {
                if let entry = readEntry(at: path) {
                    files[root]?[entry.path] = entry
                }
            } else {
                files[root]?.removeValue(forKey: path)
            }
            return
        }
        guard exists, isDir.boolValue else { return }
        guard let enumerator = fm.enumerator(atPath: path) else { return }
        var bucket = files[root] ?? [:]
        while let next = enumerator.nextObject() as? String {
            if shouldSkip(relative: next) {
                enumerator.skipDescendants()
                continue
            }
            guard next.hasSuffix(".swift") else { continue }
            let absolute = "\(path)/\(next)"
            if let entry = readEntry(at: absolute) {
                bucket[entry.path] = entry
            }
        }
        files[root] = bucket
    }
}
