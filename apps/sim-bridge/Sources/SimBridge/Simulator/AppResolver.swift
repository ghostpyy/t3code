import Foundation
import CSupport

/// Rich context for the foreground application in the simulator. Returned to
/// the pane as part of every AX hit response so the inspector / send-to-chat
/// always has a meaningful payload even when the AX attribute path is empty.
public struct SimAppInfo: Codable, Sendable {
    public let bundleId: String
    public let name: String?
    public let pid: Int32
    public let bundlePath: String?
    public let dataContainer: String?
    public let executablePath: String?
    public let projectPath: String?
}

/// Resolves foreground-app metadata using a mix of the AXPTranslator (for pid
/// extraction) and `xcrun simctl` CLI calls (for bundle/container info).
///
/// We keep this off the main actor: all calls shell out briefly. Callers
/// should invoke from a background queue and deliver results back to the
/// main actor.
enum AppResolver {
    /// Cached resolution keyed on udid. The foreground pid is the cheap
    /// private-SPI read `T3AXForegroundAppPID` — if it matches the cached
    /// entry's pid we return immediately and skip three sequential xcrun
    /// shell-outs (launchctl list + listapps + mdfind fallback), which
    /// each cost ~0.5-3s. That pipeline used to run on every axHit and
    /// made the inspector feel like it had a 5-7s lag.
    private struct CacheEntry {
        let pid: Int32
        let info: SimAppInfo
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: CacheEntry] = [:]

    static func resolve(udid: String, displayId: UInt32 = 0) -> SimAppInfo? {
        let pid = T3AXForegroundAppPID(displayId)
        guard pid > 0 else { return nil }

        cacheLock.lock()
        let cached = cache[udid]
        cacheLock.unlock()
        if let cached, cached.pid == pid {
            return cached.info
        }

        let bundleId = bundleIdForPid(udid: udid, pid: Int(pid)) ?? ""
        if bundleId.isEmpty { return nil }

        let appsRaw = runSimctl(["listapps", udid]) ?? ""
        let (name, bundlePath, dataContainer, executablePath) =
            parseAppsPlist(appsRaw, bundleId: bundleId)
        let projectPath = bundlePath.flatMap { findProjectRoot(startingAt: $0) }
            ?? findProjectByBundleId(bundleId)

        let info = SimAppInfo(
            bundleId: bundleId,
            name: name,
            pid: pid,
            bundlePath: bundlePath.map(normalizePath),
            dataContainer: dataContainer.map(normalizePath),
            executablePath: executablePath.map(normalizePath),
            projectPath: projectPath
        )
        cacheLock.lock()
        cache[udid] = CacheEntry(pid: pid, info: info)
        cacheLock.unlock()
        return info
    }

    /// Strip a `file://` prefix if simctl returned a URL-style path.
    private static func normalizePath(_ p: String) -> String {
        if p.hasPrefix("file://") {
            if let url = URL(string: p) { return url.path }
            return String(p.dropFirst("file://".count))
        }
        return p
    }

    // MARK: - Process helpers

    /// Runs `xcrun simctl <args>` and returns stdout. Returns nil on failure.
    private static func runSimctl(_ args: [String]) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/xcrun"
        task.arguments = ["simctl"] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Map a simulator-side pid → bundle identifier by asking launchctl for
    /// the service that hosts the process. The service label is always of
    /// the form `UIKitApplication:<bundle-id>[...]`.
    private static func bundleIdForPid(udid: String, pid: Int) -> String? {
        // `spawn booted launchctl list` output rows: `pid status label`.
        guard let listing = runSimctl([
            "spawn", udid, "launchctl", "list"
        ]) else { return nil }
        for line in listing.split(separator: "\n") {
            // Lines are tab-separated.
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let pidStr = parts[0].trimmingCharacters(in: .whitespaces)
            guard Int(pidStr) == pid else { continue }
            let label = parts[2].trimmingCharacters(in: .whitespaces)
            // `UIKitApplication:com.example.app[...][...]`
            if label.hasPrefix("UIKitApplication:") {
                let afterPrefix = label.dropFirst("UIKitApplication:".count)
                if let bracket = afterPrefix.firstIndex(of: "[") {
                    return String(afterPrefix[..<bracket])
                }
                return String(afterPrefix)
            }
            // Unsupported label types (extensions, xpc services, etc.).
            return label
        }
        return nil
    }

    // MARK: - plist parsing

    /// `xcrun simctl listapps <udid>` returns an old-style property list
    /// mapping `bundleId -> {CFBundleName, BundleContainer, DataContainer, ...}`.
    /// Extract just the fields we need for the given bundle id.
    private static func parseAppsPlist(
        _ raw: String, bundleId: String
    ) -> (name: String?, bundlePath: String?, data: String?, executable: String?) {
        guard !raw.isEmpty else { return (nil, nil, nil, nil) }
        // Convert to binary plist → parse via PropertyListSerialization.
        guard
            let plistData = raw.data(using: .utf8),
            let plist = try? PropertyListSerialization
                .propertyList(from: plistData, options: [], format: nil) as? [String: Any],
            let entry = plist[bundleId] as? [String: Any]
        else { return (nil, nil, nil, nil) }
        let name = (entry["CFBundleName"] as? String)
            ?? (entry["CFBundleDisplayName"] as? String)
        let bundle = (entry["Bundle"] as? String)
            ?? (entry["BundleContainer"] as? String)
            ?? (entry["Path"] as? String)
        let data = entry["DataContainer"] as? String
        // Look up the executable name to build a full path.
        let exec = (entry["CFBundleExecutable"] as? String).map { execName -> String in
            guard let b = bundle else { return execName }
            return b.hasSuffix("/") ? "\(b)\(execName)" : "\(b)/\(execName)"
        }
        return (name, bundle, data, exec)
    }

    /// Use Spotlight to find an `Info.plist` somewhere on disk whose
    /// CFBundleIdentifier matches — the containing directory is almost
    /// always a source/project checkout (or at least the compiled app's
    /// DerivedData source root).
    private static func findProjectByBundleId(_ bundleId: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/mdfind"
        task.arguments = [
            "kMDItemCFBundleIdentifier == \"\(bundleId)\""
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        let lines = out.split(separator: "\n").map(String.init)
        // Prefer hits outside of `/Library/Developer/CoreSimulator/`
        // (that's the installed copy we already know about).
        let preferred = lines.first { hit in
            !hit.contains("/CoreSimulator/") && !hit.contains("/Library/Caches/")
        } ?? lines.first { $0.contains(".xcodeproj") || $0.contains(".app") }
        guard let hit = preferred else { return nil }
        // If the hit is an `Info.plist`, walk up to the project-root; if
        // it's a bundle (.app/.xcodeproj/.framework), do the same dance.
        return findProjectRoot(startingAt: hit)
    }

    // MARK: - Project-root heuristics

    /// Walk up from the compiled `.app` bundle looking for something that
    /// looks like a source-of-truth Xcode project / Swift package so the
    /// inspect panel can reference back to source. The simulator's app
    /// container path usually lives deep under
    /// `~/Library/Developer/Xcode/DerivedData/.../Build/Products/.../App.app`,
    /// so we also walk DerivedData → SourcePackages / workspace root.
    private static func findProjectRoot(startingAt path: String) -> String? {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        let fm = FileManager.default
        let sentinels = ["project.pbxproj", ".xcworkspace", ".xcodeproj", "Package.swift"]
        // Walk up at most 10 levels to avoid runaway traversal.
        for _ in 0..<10 {
            if let entries = try? fm.contentsOfDirectory(atPath: url.path) {
                for entry in entries {
                    for sentinel in sentinels {
                        if entry == sentinel || entry.hasSuffix(sentinel) {
                            return url.path
                        }
                    }
                }
            }
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        // Inside DerivedData: try `info.plist` workspace hint.
        if path.contains("DerivedData") {
            var searchURL = URL(fileURLWithPath: path)
            for _ in 0..<12 {
                let infoPath = searchURL.appendingPathComponent("info.plist").path
                if let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)),
                   let plist = try? PropertyListSerialization
                       .propertyList(from: data, options: [], format: nil) as? [String: Any],
                   let ws = plist["WorkspacePath"] as? String {
                    return (ws as NSString).deletingLastPathComponent
                }
                if searchURL.path == "/" { break }
                searchURL = searchURL.deletingLastPathComponent()
            }
        }
        return nil
    }
}
