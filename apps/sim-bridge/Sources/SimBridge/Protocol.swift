import Foundation

enum BridgeProtocol {
    static let defaultPort: UInt16 = 17323

    struct SourceRef: Codable, Equatable {
        let file: String
        let line: Int
        var function: String?
        var kind: String?
        var name: String?
        var role: String?
        var title: String?
        var value: String?
        var help: String?
        var identifier: String?
    }

    struct Frame: Codable, Equatable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
    }

    struct AXNode: Codable, Equatable {
        let file: String
        let line: Int
        var function: String?
        var kind: String?
        var name: String?
        var role: String?
        var title: String?
        var value: String?
        var help: String?
        var identifier: String?
        let frame: Frame
    }

    struct SimInfo: Codable, Equatable {
        let udid: String
        let name: String
        let model: String
        let status: String
        let screenW: Int
        let screenH: Int
    }
}

enum PaneToBridgeMessage: Decodable {
    case tap(x: Int, y: Int)
    case drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMs: Int)
    case typeText(String)
    case pressKey(String)
    case inspectAt(x: Int, y: Int, requestId: String)
    case subscribeFrames(fps: Int)
    case subscribeAx(intervalMs: Int)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, x, y, fromX, fromY, toX, toY, durationMs, text, key, requestId, fps, intervalMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "tap":
            self = .tap(x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y))
        case "drag":
            self = .drag(
                fromX: try c.decode(Int.self, forKey: .fromX),
                fromY: try c.decode(Int.self, forKey: .fromY),
                toX: try c.decode(Int.self, forKey: .toX),
                toY: try c.decode(Int.self, forKey: .toY),
                durationMs: try c.decode(Int.self, forKey: .durationMs)
            )
        case "type-text":
            self = .typeText(try c.decode(String.self, forKey: .text))
        case "press-key":
            self = .pressKey(try c.decode(String.self, forKey: .key))
        case "inspect-at":
            self = .inspectAt(
                x: try c.decode(Int.self, forKey: .x),
                y: try c.decode(Int.self, forKey: .y),
                requestId: try c.decode(String.self, forKey: .requestId)
            )
        case "subscribe-frames":
            self = .subscribeFrames(fps: try c.decode(Int.self, forKey: .fps))
        case "subscribe-ax":
            self = .subscribeAx(intervalMs: try c.decode(Int.self, forKey: .intervalMs))
        default:
            self = .unknown
        }
    }
}

enum BridgeToPaneMessage {
    case frame(image: Data, mime: String, w: Int, h: Int, ts: Double)
    case axSnapshot(nodes: [BridgeProtocol.AXNode], ts: Double)
    case sourceClicked(ref: BridgeProtocol.SourceRef, frame: BridgeProtocol.Frame, ts: Double)
    case simInfo(BridgeProtocol.SimInfo)
    case error(String)
    case inspectResult(requestId: String, ref: BridgeProtocol.SourceRef?)

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case let .frame(image, mime, w, h, ts):
            return try encoder.encode(_FramePayload(type: "frame", image: image.base64EncodedString(), mime: mime, w: w, h: h, ts: ts))
        case let .axSnapshot(nodes, ts):
            return try encoder.encode(_AxSnapshotPayload(type: "ax-snapshot", nodes: nodes, ts: ts))
        case let .sourceClicked(ref, frame, ts):
            return try encoder.encode(_SourceClickedPayload(type: "source-clicked", ref: ref, frame: frame, ts: ts))
        case let .simInfo(info):
            return try encoder.encode(_SimInfoPayload(type: "sim-info", info: info))
        case let .error(message):
            return try encoder.encode(_ErrorPayload(type: "error", message: message))
        case let .inspectResult(requestId, ref):
            return try encoder.encode(_InspectResultPayload(type: "inspect-result", requestId: requestId, ref: ref))
        }
    }

    private struct _FramePayload: Encodable { let type: String; let image: String; let mime: String; let w: Int; let h: Int; let ts: Double }
    private struct _AxSnapshotPayload: Encodable { let type: String; let nodes: [BridgeProtocol.AXNode]; let ts: Double }
    private struct _SourceClickedPayload: Encodable { let type: String; let ref: BridgeProtocol.SourceRef; let frame: BridgeProtocol.Frame; let ts: Double }
    private struct _SimInfoPayload: Encodable { let type: String; let info: BridgeProtocol.SimInfo }
    private struct _ErrorPayload: Encodable { let type: String; let message: String }
    private struct _InspectResultPayload: Encodable { let type: String; let requestId: String; let ref: BridgeProtocol.SourceRef? }
}
