import Foundation
import ObjectiveC.runtime
import CPrivate

public enum DeviceError: Error, LocalizedError {
    case bootFailed(String)
    case shutdownFailed(String)
    case installFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bootFailed(let m): return "Boot failed: \(m)"
        case .shutdownFailed(let m): return "Shutdown failed: \(m)"
        case .installFailed(let m): return "Install failed: \(m)"
        case .launchFailed(let m): return "Launch failed: \(m)"
        }
    }
}

public final class Device: @unchecked Sendable {
    public let udid: String
    public let simDevice: SimDevice

    public init(simDevice: SimDevice) {
        self.simDevice = simDevice
        self.udid = (simDevice.value(forKey: "UDID") as? NSUUID)?.uuidString ?? ""
    }

    public var state: DeviceState {
        let raw = (simDevice.value(forKey: "state") as? NSNumber)?.uint64Value ?? 0
        let stateString = simDevice.perform(NSSelectorFromString("stateString"))?.takeUnretainedValue() as? String
        return .from(raw: raw, stateString: stateString)
    }

    public func boot() async throws {
        let options: [String: Any] = [
            "persist": true,
            "env": [String: String]()
        ]
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let sel = NSSelectorFromString("bootAsyncWithOptions:completionQueue:completionHandler:")
            guard simDevice.responds(to: sel),
                  let method = class_getInstanceMethod(type(of: simDevice), sel) else {
                cont.resume(throwing: DeviceError.bootFailed("bootAsyncWithOptions: not available"))
                return
            }
            typealias BootIMP = @convention(c) (AnyObject, Selector, NSDictionary, DispatchQueue, @convention(block) (NSError?) -> Void) -> Void
            let imp = method_getImplementation(method)
            let fn = unsafeBitCast(imp, to: BootIMP.self)
            let handler: @convention(block) (NSError?) -> Void = { err in
                if let err { cont.resume(throwing: DeviceError.bootFailed(err.localizedDescription)) }
                else { cont.resume() }
            }
            fn(simDevice, sel, options as NSDictionary, DispatchQueue.global(), handler)
        }
    }

    public func shutdown() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let sel = NSSelectorFromString("shutdownAsyncWithCompletionQueue:completionHandler:")
            guard simDevice.responds(to: sel),
                  let method = class_getInstanceMethod(type(of: simDevice), sel) else {
                cont.resume(throwing: DeviceError.shutdownFailed("shutdownAsync not available"))
                return
            }
            typealias ShutdownIMP = @convention(c) (AnyObject, Selector, DispatchQueue, @convention(block) (NSError?) -> Void) -> Void
            let imp = method_getImplementation(method)
            let fn = unsafeBitCast(imp, to: ShutdownIMP.self)
            let handler: @convention(block) (NSError?) -> Void = { err in
                if let err { cont.resume(throwing: DeviceError.shutdownFailed(err.localizedDescription)) }
                else { cont.resume() }
            }
            fn(simDevice, sel, DispatchQueue.global(), handler)
        }
    }

    public func install(appAt url: URL) throws {
        var err: NSError?
        let sel = NSSelectorFromString("installApplication:withOptions:error:")
        guard simDevice.responds(to: sel),
              let method = class_getInstanceMethod(type(of: simDevice), sel) else {
            throw DeviceError.installFailed("installApplication: not available")
        }
        typealias InstallIMP = @convention(c) (AnyObject, Selector, NSURL, NSDictionary?, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: InstallIMP.self)
        let ok = fn(simDevice, sel, url as NSURL, nil, &err)
        if !ok { throw DeviceError.installFailed(err?.localizedDescription ?? "unknown") }
    }

    public func launch(bundleId: String) throws -> Int32 {
        var err: NSError?
        let sel = NSSelectorFromString("launchApplicationWithID:options:error:")
        guard simDevice.responds(to: sel),
              let method = class_getInstanceMethod(type(of: simDevice), sel) else {
            throw DeviceError.launchFailed("launchApplicationWithID: missing")
        }
        typealias LaunchIMP = @convention(c) (AnyObject, Selector, NSString, NSDictionary?, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Int32
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: LaunchIMP.self)
        let pid = fn(simDevice, sel, bundleId as NSString, nil, &err)
        if pid <= 0 { throw DeviceError.launchFailed(err?.localizedDescription ?? "unknown") }
        return pid
    }

    public func terminate(bundleId: String) throws {
        var err: NSError?
        let sel = NSSelectorFromString("terminateApplicationWithID:error:")
        guard simDevice.responds(to: sel),
              let method = class_getInstanceMethod(type(of: simDevice), sel) else {
            throw DeviceError.launchFailed("terminateApplicationWithID: missing")
        }
        typealias TerminateIMP = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: TerminateIMP.self)
        let ok = fn(simDevice, sel, bundleId as NSString, &err)
        if !ok { throw DeviceError.launchFailed(err?.localizedDescription ?? "unknown") }
    }
}
