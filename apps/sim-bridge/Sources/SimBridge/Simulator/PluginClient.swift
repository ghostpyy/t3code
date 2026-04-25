import Foundation

/// Queries the debug-only HTTP server running inside the target iOS app
/// (`InspectableServer` in Satira). The iOS Simulator shares the host Mac's
/// `127.0.0.1`, so a loopback HTTP call from sim-bridge reaches the in-app
/// listener directly — no USB, no XPC, no port forwarding.
///
/// This is the authoritative source-mapping path. It bypasses Xcode 26.2's
/// broken AX attribute hydration entirely: every rect here originates from a
/// literal `.inspectable()` call in the app's own SwiftUI, stamped with the
/// caller's `#fileID` / `#line` at compile time. No heuristics, no semantic
/// grep, no OCR.
public enum PluginClient {
    public struct Node: Sendable, Equatable {
        public let id: String
        public let file: String
        public let line: Int
        public let module: String?
        public let alias: String?
        public let frame: AXFrame
    }

    /// Default baseline. The iOS simulator and the host share loopback, so
    /// `127.0.0.1:18181` is how sim-bridge reaches the app's in-process
    /// listener. Port is hard-coded to match `Satira/InspectableServer`.
    private static let baseURL = URL(string: "http://127.0.0.1:18181")!

    /// Short-lived ephemeral session. The inspector is hot-path code — we
    /// prefer "no answer" over "slow answer" so the pane stays responsive
    /// when the target app isn't Satira (or hasn't booted yet).
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.08
        cfg.timeoutIntervalForResource = 0.12
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    public static func hit(x: Double, y: Double) -> [Node] {
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
        else { return [] }
        return payload.chain.map(Self.convert(_:))
    }

    public static func tree() -> (nodes: [Node], generation: UInt64)? {
        let url = baseURL.appendingPathComponent("tree")
        guard let data = sync(url: url),
              let payload = try? JSONDecoder().decode(TreePayload.self, from: data)
        else { return nil }
        return (payload.nodes.map(Self.convert(_:)), payload.generation)
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
        /// Optional so an older Satira build (pre-cornerRadius Node payload)
        /// still decodes — the field drops to zero and the picker falls back
        /// to square corners, which matches the previous behavior.
        let cornerRadius: Double?
    }
}
