import Foundation

// `DeviceInfo` and `DeviceState` declare `Codable` at their definition site in
// `Simulator/ServiceContext.swift` — Swift blocks automatic synthesis from a
// non-declaring file.

// MARK: - Incoming (pane → daemon)

public enum PaneToBridge: Sendable {
    case deviceList
    case deviceBoot(udid: String)
    case deviceShutdown(udid: String)
    case deviceInstall(udid: String, appPath: String)
    case deviceLaunch(udid: String, bundleId: String)
    case inputTap(x: Double, y: Double, phase: TapPhase)
    case inputDrag(points: [DragPoint])
    case inputKey(usage: Int32, down: Bool, modifiers: Int32)
    case inputButton(kind: HardwareButton, down: Bool)
    case axEnable
    case axHit(x: Double, y: Double, mode: AXHitMode)
    case axTree
    case axSnapshot
    case axAction(elementId: String, action: String)
    case rotate(orientation: Int)
    case unknown

    public enum TapPhase: String, Codable, Sendable { case down, up }
    public enum AXHitMode: String, Codable, Sendable { case hover, select }

    public struct DragPoint: Codable, Sendable {
        public let x: Double
        public let y: Double
        public let t: Double
    }
}

extension PaneToBridge: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, udid, appPath, bundleId, x, y, phase, points, usage, down, modifiers, kind, elementId, action, orientation, mode
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .type)
        switch t {
        case "deviceList": self = .deviceList
        case "deviceBoot": self = .deviceBoot(udid: try c.decode(String.self, forKey: .udid))
        case "deviceShutdown": self = .deviceShutdown(udid: try c.decode(String.self, forKey: .udid))
        case "deviceInstall":
            self = .deviceInstall(udid: try c.decode(String.self, forKey: .udid),
                                   appPath: try c.decode(String.self, forKey: .appPath))
        case "deviceLaunch":
            self = .deviceLaunch(udid: try c.decode(String.self, forKey: .udid),
                                 bundleId: try c.decode(String.self, forKey: .bundleId))
        case "inputTap":
            self = .inputTap(
                x: try c.decode(Double.self, forKey: .x),
                y: try c.decode(Double.self, forKey: .y),
                phase: try c.decode(TapPhase.self, forKey: .phase)
            )
        case "inputDrag":
            self = .inputDrag(points: try c.decode([DragPoint].self, forKey: .points))
        case "inputKey":
            self = .inputKey(
                usage: try c.decode(Int32.self, forKey: .usage),
                down: try c.decode(Bool.self, forKey: .down),
                modifiers: try c.decodeIfPresent(Int32.self, forKey: .modifiers) ?? 0
            )
        case "inputButton":
            let kindRaw = try c.decode(String.self, forKey: .kind)
            let kind = HardwareButton(rawValue: kindRaw) ?? .home
            self = .inputButton(kind: kind, down: try c.decode(Bool.self, forKey: .down))
        case "axEnable": self = .axEnable
        case "axHit":
            self = .axHit(
                x: try c.decode(Double.self, forKey: .x),
                y: try c.decode(Double.self, forKey: .y),
                mode: try c.decodeIfPresent(AXHitMode.self, forKey: .mode) ?? .select
            )
        case "axTree": self = .axTree
        case "axSnapshot": self = .axSnapshot
        case "axAction":
            self = .axAction(
                elementId: try c.decode(String.self, forKey: .elementId),
                action: try c.decode(String.self, forKey: .action)
            )
        case "rotate":
            self = .rotate(orientation: try c.decode(Int.self, forKey: .orientation))
        default:
            self = .unknown
        }
    }
}

// MARK: - Outgoing (daemon → pane)

public enum BridgeToPane: Sendable {
    case deviceListResponse(devices: [DeviceInfo])
    case deviceState(udid: String, state: DeviceState, bootStatus: String?)
    case displayReady(contextId: UInt32, pixelWidth: Int, pixelHeight: Int, scale: Double)
    case displaySurfaceChanged(pixelWidth: Int, pixelHeight: Int)
    case axHitResponse(chain: [AXElement], hitIndex: Int, mode: PaneToBridge.AXHitMode)
    case axTreeResponse(root: AXElement)
    case axSnapshotResponse(nodes: [AXNode], appContext: SimAppInfo?)
    case error(code: String, message: String, detail: [String: String]?)
}

extension BridgeToPane: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, devices, udid, state, bootStatus, contextId, pixelWidth, pixelHeight, scale, chain, hitIndex, root, code, message, detail, mode, nodes, appContext
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .deviceListResponse(devices):
            try c.encode("deviceListResponse", forKey: .type)
            try c.encode(devices, forKey: .devices)
        case let .deviceState(udid, state, bootStatus):
            try c.encode("deviceState", forKey: .type)
            try c.encode(udid, forKey: .udid)
            try c.encode(state, forKey: .state)
            try c.encodeIfPresent(bootStatus, forKey: .bootStatus)
        case let .displayReady(contextId, w, h, scale):
            try c.encode("displayReady", forKey: .type)
            try c.encode(contextId, forKey: .contextId)
            try c.encode(w, forKey: .pixelWidth)
            try c.encode(h, forKey: .pixelHeight)
            try c.encode(scale, forKey: .scale)
        case let .displaySurfaceChanged(w, h):
            try c.encode("displaySurfaceChanged", forKey: .type)
            try c.encode(w, forKey: .pixelWidth)
            try c.encode(h, forKey: .pixelHeight)
        case let .axHitResponse(chain, hitIndex, mode):
            try c.encode("axHitResponse", forKey: .type)
            try c.encode(chain, forKey: .chain)
            try c.encode(hitIndex, forKey: .hitIndex)
            try c.encode(mode, forKey: .mode)
        case let .axTreeResponse(root):
            try c.encode("axTreeResponse", forKey: .type)
            try c.encode(root, forKey: .root)
        case let .axSnapshotResponse(nodes, appContext):
            try c.encode("axSnapshotResponse", forKey: .type)
            try c.encode(nodes, forKey: .nodes)
            try c.encodeIfPresent(appContext, forKey: .appContext)
        case let .error(code, message, detail):
            try c.encode("error", forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(detail, forKey: .detail)
        }
    }
}
