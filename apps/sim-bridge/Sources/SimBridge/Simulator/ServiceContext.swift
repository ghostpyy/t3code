import Foundation
import CPrivate

public enum DeviceState: String, Codable, Sendable {
    case shutdown
    case booting
    case booted
    case shuttingDown
    case creating
    case unknown

    static func from(raw: UInt64, stateString: String? = nil) -> DeviceState {
        if let state = from(stateString: stateString) {
            return state
        }
        switch raw {
        case 1: return .shutdown
        case 2: return .booting
        case 3: return .booted
        case 4: return .shuttingDown
        case 5: return .creating
        default: return .unknown
        }
    }

    private static func from(stateString: String?) -> DeviceState? {
        guard let raw = stateString?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        switch raw.replacingOccurrences(of: " ", with: "") {
        case "shutdown": return .shutdown
        case "booting": return .booting
        case "booted": return .booted
        case "shuttingdown": return .shuttingDown
        case "creating": return .creating
        default: return nil
        }
    }
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public let udid: String
    public let name: String
    public let runtime: String
    public let model: String
    public var state: DeviceState

    public var summary: String { "\(name) · \(runtime)" }
    public var isBooted: Bool { state == .booted }
}

public enum ServiceContextError: Error, LocalizedError {
    case frameworkLoadFailed(String)
    case xcodeMissing
    case serviceContextUnavailable(String)
    case deviceSetUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .frameworkLoadFailed(let f): return "Failed to load \(f). Xcode install may be corrupted."
        case .xcodeMissing: return "Xcode is not installed or xcode-select is not pointed at an Xcode.app."
        case .serviceContextUnavailable(let m): return "CoreSimulator service unavailable: \(m)."
        case .deviceSetUnavailable(let m): return "Device set unavailable: \(m)."
        }
    }
}

public final class ServiceContext: @unchecked Sendable {
    private let context: SimServiceContext
    private let deviceSet: SimDeviceSet

    public static func make() throws -> ServiceContext {
        try ensureXcodeAvailable()
        var ctxErr: AnyObject?
        let dev = try developerDir()
        guard let ctx = SimServiceContext.sharedServiceContext(forDeveloperDir: dev, error: &ctxErr) as? SimServiceContext else {
            throw ServiceContextError.serviceContextUnavailable(describe(error: ctxErr))
        }
        var setErr: AnyObject?
        guard let set = ctx.defaultDeviceSetWithError(&setErr) as? SimDeviceSet else {
            throw ServiceContextError.deviceSetUnavailable(describe(error: setErr))
        }
        return ServiceContext(context: ctx, deviceSet: set)
    }

    private static func describe(error: AnyObject?) -> String {
        (error as? NSError)?.localizedDescription ?? "unknown"
    }

    private init(context: SimServiceContext, deviceSet: SimDeviceSet) {
        self.context = context
        self.deviceSet = deviceSet
    }

    public func devices() -> [DeviceInfo] {
        let simDevices = (deviceSet.value(forKey: "devices") as? [NSObject]) ?? []
        return simDevices.compactMap { sd -> DeviceInfo? in
            guard let udid = sd.value(forKey: "UDID") as? NSUUID else { return nil }
            let name = (sd.value(forKey: "name") as? String) ?? "Unknown"
            let stateRaw = (sd.value(forKey: "state") as? NSNumber)?.uint64Value ?? 0
            let stateString = Self.msg(sd, "stateString") as? String
            let runtime = (sd.value(forKey: "runtime") as? NSObject)?.value(forKey: "versionString") as? String ?? "unknown"
            let modelId = (sd.value(forKey: "deviceType") as? NSObject)?.value(forKey: "modelIdentifier") as? String ?? "unknown"
            return DeviceInfo(
                udid: udid.uuidString,
                name: name,
                runtime: runtime,
                model: modelId,
                state: .from(raw: stateRaw, stateString: stateString)
            )
        }
    }

    public func device(udid: String) -> SimDevice? {
        let simDevices = (deviceSet.value(forKey: "devices") as? [NSObject]) ?? []
        return simDevices.first(where: {
            ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid
        }) as? SimDevice
    }

    // MARK: - private helpers

    private static func ensureXcodeAvailable() throws {
        let dev = try developerDir()
        let simKitPath = "\(dev)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        if !FileManager.default.fileExists(atPath: simKitPath) {
            throw ServiceContextError.frameworkLoadFailed("SimulatorKit (expected at \(simKitPath))")
        }
    }

    private static func developerDir() throws -> String {
        let task = Process()
        task.launchPath = "/usr/bin/xcode-select"
        task.arguments = ["-p"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { throw ServiceContextError.xcodeMissing }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || !FileManager.default.fileExists(atPath: path) {
            throw ServiceContextError.xcodeMissing
        }
        return path
    }

    private static func msg(_ obj: NSObject, _ name: String) -> Any? {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return nil }
        return obj.perform(sel)?.takeUnretainedValue()
    }
}
