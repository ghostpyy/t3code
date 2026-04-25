import Foundation
import ObjectiveC.runtime
import CPrivate

public enum BootStatus: Equatable, Sendable {
    case booting
    case waitingOnBackboard
    case waitingOnDataMigration
    case dataMigrationFailed
    case waitingOnSystemApp
    case booted
    case unknown

    public var label: String {
        switch self {
        case .booting: return "Booting"
        case .waitingOnBackboard: return "Waiting on backboard"
        case .waitingOnDataMigration: return "Waiting on data migration"
        case .dataMigrationFailed: return "Data migration failed"
        case .waitingOnSystemApp: return "Waiting on system app"
        case .booted: return "Booted"
        case .unknown: return "Unknown"
        }
    }

    /// Raw values map to the `SimDeviceBootInfoStatus` enum in CoreSimulator
    /// (see `PrivateHeaders/CoreSimulator/SimDeviceBootInfo.h`).
    public static func from(raw: UInt64) -> BootStatus {
        switch raw {
        case 0: return .booting
        case 1: return .waitingOnBackboard
        case 2: return .waitingOnDataMigration
        case 3: return .dataMigrationFailed
        case 4: return .waitingOnSystemApp
        case 4_294_967_295: return .booted
        default: return .unknown
        }
    }
}

public final class BootMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (BootStatus) -> Void

    private let device: SimDevice
    private var registrationId: UInt64 = 0
    private var pollTimer: DispatchSourceTimer?
    private var lastStatus: BootStatus?

    public init(device: SimDevice) { self.device = device }

    public func start(onChange: @escaping Handler) {
        emit(currentStatus() ?? .booting, onChange)

        let block: @convention(block) (AnyObject?) -> Void = { info in
            guard let info else { return }
            guard let raw = extractStatus(from: info) else { return }
            self.emit(BootStatus.from(raw: raw), onChange)
        }
        let sel = NSSelectorFromString("registerNotificationHandler:")
        guard device.responds(to: sel),
              let method = class_getInstanceMethod(type(of: device), sel) else {
            startPolling(onChange: onChange)
            return
        }
        typealias RegisterIMP = @convention(c) (AnyObject, Selector, @convention(block) (AnyObject?) -> Void) -> UInt64
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: RegisterIMP.self)
        registrationId = fn(device, sel, block)
        startPolling(onChange: onChange)
    }

    public func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        guard registrationId != 0 else { return }
        let sel = NSSelectorFromString("unregisterNotificationHandler:error:")
        guard device.responds(to: sel),
              let method = class_getInstanceMethod(type(of: device), sel) else {
            registrationId = 0
            return
        }
        typealias UnregisterIMP = @convention(c) (AnyObject, Selector, UInt64, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: UnregisterIMP.self)
        var err: NSError?
        _ = fn(device, sel, registrationId, &err)
        registrationId = 0
    }

    private func startPolling(onChange: @escaping Handler) {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, let status = self.currentStatus() else { return }
            self.emit(status, onChange)
            if status == .booted {
                self.pollTimer?.cancel()
                self.pollTimer = nil
            }
        }
        pollTimer = timer
        timer.resume()
    }

    private func currentStatus() -> BootStatus? {
        let sel = NSSelectorFromString("bootStatus")
        guard device.responds(to: sel),
              let info = device.perform(sel)?.takeUnretainedValue() as? NSObject,
              let raw = (info.value(forKey: "status") as? NSNumber)?.uint64Value else {
            return nil
        }
        return BootStatus.from(raw: raw)
    }

    private func emit(_ status: BootStatus, _ onChange: Handler) {
        if lastStatus == status {
            return
        }
        lastStatus = status
        onChange(status)
    }
}

private func extractStatus(from info: AnyObject) -> UInt64? {
    if let dict = info as? NSDictionary {
        if let n = dict["status"] as? NSNumber { return n.uint64Value }
        if let bi = dict["SimDeviceBootInfo"] as? NSObject,
           let n = bi.value(forKey: "status") as? NSNumber {
            return n.uint64Value
        }
        if let bi = dict["notification"] as? NSObject,
           let n = bi.value(forKey: "status") as? NSNumber {
            return n.uint64Value
        }
    }
    if let n = (info as? NSObject)?.value(forKey: "status") as? NSNumber {
        return n.uint64Value
    }
    return nil
}
