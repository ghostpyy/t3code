import Foundation

/// Queries the debug-only HTTP server running inside the target iOS app.
/// The iOS Simulator shares the host Mac's
/// `127.0.0.1`, so a loopback HTTP call from sim-bridge reaches the in-app
/// listener directly — no USB, no XPC, no port forwarding.
///
/// This is a source-mapping side channel. Runtime AX remains the visual source
/// of truth; plugin rectangles are only eligible to annotate a live hit when
/// the bridge verifies their geometry against that runtime target.
public enum PluginClient {
    public struct Node: Sendable, Equatable {
        public let id: String
        public let file: String
        public let line: Int
        public let module: String?
        public let alias: String?
        public let frame: AXFrame
    }

    private static var baseURLs: [URL] {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["T3_INSPECTABLE_URLS"] {
            let urls = raw.split(separator: ",").compactMap {
                URL(string: String($0).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !urls.isEmpty { return urls }
        }
        if let raw = env["T3_INSPECTABLE_PORTS"] {
            let urls = raw.split(separator: ",").compactMap { part -> URL? in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let port = Int(trimmed), port > 0, port < 65536 else { return nil }
                return URL(string: "http://127.0.0.1:\(port)")
            }
            if !urls.isEmpty { return urls }
        }
        return [URL(string: "http://127.0.0.1:18181")!]
    }

    /// Short-lived ephemeral session. The inspector is hot-path code — we
    /// prefer "no answer" over "slow answer" so the pane stays responsive
    /// when the target app does not expose an inspector (or has not booted yet).
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.08
        cfg.timeoutIntervalForResource = 0.12
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    public static func hit(x: Double, y: Double) -> [Node] {
        for baseURL in baseURLs {
            var comps = URLComponents(
                url: baseURL.appendingPathComponent("hit"),
                resolvingAgainstBaseURL: false
            )
            comps?.queryItems = [
                URLQueryItem(name: "x", value: format(x)),
                URLQueryItem(name: "y", value: format(y)),
            ]
            guard let url = comps?.url,
                  let data = sync(url: url),
                  let payload = try? JSONDecoder().decode(HitPayload.self, from: data)
            else { continue }
            return payload.chain.map(Self.convert(_:))
        }
        return []
    }

    public static func tree() -> (nodes: [Node], generation: UInt64)? {
        for baseURL in baseURLs {
            let url = baseURL.appendingPathComponent("tree")
            guard let data = sync(url: url),
                  let payload = try? JSONDecoder().decode(TreePayload.self, from: data)
            else { continue }
            return (payload.nodes.map(Self.convert(_:)), payload.generation)
        }
        return nil
    }

    // MARK: - private

    private static func sync(url: URL) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = session.dataTask(with: url) { data, _, _ in
            result = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 0.12)
        if result == nil { task.cancel() }
        return result
    }

    private static func convert(_ raw: RawNode) -> Node {
        Node(
            id: raw.id,
            file: raw.file,
            line: raw.line,
            module: raw.module,
            alias: raw.alias,
            frame: AXFrame(
                x: raw.x,
                y: raw.y,
                width: raw.width,
                height: raw.height,
                cornerRadius: raw.cornerRadius ?? 0
            )
        )
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private struct HitPayload: Decodable {
        let chain: [RawNode]
    }

    private struct TreePayload: Decodable {
        let generation: UInt64
        let nodes: [RawNode]
    }

    private struct RawNode: Decodable {
        let id: String
        let file: String
        let line: Int
        let module: String?
        let alias: String?
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        /// Optional so older inspector payloads
        /// still decodes — the field drops to zero and the picker falls back
        /// to square corners, which matches the previous behavior.
        let cornerRadius: Double?
    }
}
