import Foundation
import ObjectiveC.runtime
import CPrivate
import CSupport

public enum BridgeError: Error, LocalizedError {
    case notAvailable
    case lookupFailed(String)
    case noRootProxy

    public var errorDescription: String? {
        switch self {
        case .notAvailable: return "SimulatorBridge not available on this device."
        case .lookupFailed(let m): return "SimulatorBridge lookup failed: \(m)"
        case .noRootProxy: return "SimulatorBridge NSConnection yielded no rootProxy (is the sim booted?)."
        }
    }
}

/// Wraps the `<SimulatorBridge>` distributed-object proxy obtained via
/// `SimDevice -lookup:error:` on the Mach name `com.apple.iphonesimulator.bridge`.
///
/// `-lookup:error:` returns a `mach_port_t` (unsigned int, per
/// `PrivateHeaders/CoreSimulator/SimDevice.h` line 132). We convert the port
/// to a distributed proxy by constructing an `NSMachPort` + `NSConnection` and
/// pulling `rootProxy`. NSConnection is `NS_SWIFT_UNAVAILABLE`, so we use
/// the same ObjC-runtime IMP-cast pattern the rest of this target uses.
public final class Bridge: @unchecked Sendable {
    internal let proxy: NSObject
    /// Retain the NSConnection for the proxy's lifetime — distributed-object
    /// proxies do not retain their connection, so dropping this reference
    /// invalidates the proxy the moment ARC collects it.
    private let connection: NSObject

    public init(device: SimDevice) throws {
        let sel = NSSelectorFromString("lookup:error:")
        guard device.responds(to: sel),
              let method = class_getInstanceMethod(type(of: device), sel) else {
            throw BridgeError.notAvailable
        }
        // NSError** out-params must use AutoreleasingUnsafeMutablePointer, not
        // the plain UnsafeMutablePointer — the former tracks ObjC +0 autorelease
        // semantics correctly, the latter leaves the NSError's refcount desynced
        // so it enters the autorelease pool as a dangling entry and crashes
        // objc_autoreleasePoolPop on drain. This is the documented Swift
        // bridging type for `NSError **` in `@convention(c)` IMP casts.
        typealias LookupIMP = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt32
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: LookupIMP.self)

        // The legacy name `com.apple.iphonesimulator.bridge` shipped with the
        // old SimulatorBridge helper that Xcode's Simulator.app spawns. On
        // Xcode 26+, the CoreSimulatorBridge LaunchDaemon advertises the
        // equivalent endpoints under `com.apple.CoreSimulator.*` names (see
        // `launchctl print user/501/com.apple.CoreSimulator.bridge` in a
        // booted simruntime — it lists `com.apple.CoreSimulator.accessibility`,
        // `com.apple.CoreSimulator.host_support`, etc).
        //
        // CRITICAL: `-[SimDevice lookup:]` will happily return a valid
        // mach_port_t for XPC-only endpoints like `host_support`, but those
        // endpoints don't speak the legacy Distributed Objects wire protocol.
        // Sending them `-[NSConnection rootProxy]` blocks for `replyTimeout`
        // seconds and then throws `NSPortTimeoutException`, which Swift can't
        // catch — `libc++abi::__terminate` runs and takes the whole
        // sim-bridge daemon with it (display pane freezes, chat loses HID).
        //
        // Strategy: walk the candidate list, and for each resolved port try
        // `rootProxy` inside @try/@catch (via `T3SafeRootProxy`). Accept the
        // first candidate that returns a real remote proxy. If nothing
        // speaks DO (current Xcode 26 reality — the SimulatorBridge helper
        // is gone), surface `.notAvailable` so the caller logs "AX disabled"
        // and keeps running. Display + HID don't need SimulatorBridge.
        let candidates: [String] = [
            "com.apple.iphonesimulator.bridge",
            "com.apple.CoreSimulator.SimulatorBridge",
            "com.apple.CoreSimulator.CoreSimulatorBridge",
        ]
        var chosen: (proxy: NSObject, connection: NSObject)?
        var lastError: String?
        for name in candidates {
            var err: NSError?
            let p = fn(device, sel, name as NSString, &err)
            if p == 0 {
                if let err {
                    lastError = err.localizedDescription
                }
                continue
            }
            FileHandle.standardError.write(Data("[bridge] lookup ok name=\(name) port=\(p)\n".utf8))
            if let pair = Self.rootProxyAndConnection(fromMachPort: p) {
                FileHandle.standardError.write(Data("[bridge] rootProxy ok name=\(name)\n".utf8))
                chosen = pair
                break
            }
            FileHandle.standardError.write(Data("[bridge] rootProxy nil name=\(name) (not DO-compatible, trying next)\n".utf8))
        }
        guard let pair = chosen else {
            // No candidate speaks Distributed Objects. Current Xcode 26.x
            // CoreSimulatorBridge no longer exposes a DO endpoint — the AX
            // path needs to migrate to `AXPTranslator` XPC or CoreSimulator's
            // own accessibility service. For now, gracefully report
            // unavailable so display/HID still work.
            throw BridgeError.lookupFailed(lastError ?? "no Distributed-Objects-compatible SimulatorBridge (Xcode 26+)")
        }
        self.proxy = pair.proxy
        self.connection = pair.connection
    }

    public func enableAccessibility() {
        let sel = NSSelectorFromString("enableAccessibility")
        if proxy.responds(to: sel) { _ = proxy.perform(sel) }
    }

    public func setDeviceOrientation(_ orientation: Int) {
        let sel = NSSelectorFromString("setDeviceOrientation:")
        if proxy.responds(to: sel) {
            _ = proxy.perform(sel, with: NSNumber(value: orientation))
        }
    }

    public func processAXRequest(_ requestData: Data) -> Data? {
        let sel = NSSelectorFromString("processPlatformTranslationRequestWithData:")
        guard proxy.responds(to: sel),
              let method = class_getInstanceMethod(type(of: proxy), sel) else { return nil }
        // +0 autoreleased return — see Display.msg for why Unmanaged is required
        // for @convention(c) IMP casts with non-retained object returns.
        typealias AXIMP = @convention(c) (AnyObject, Selector, NSData) -> Unmanaged<NSData>?
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: AXIMP.self)
        return fn(proxy, sel, requestData as NSData)?.takeUnretainedValue() as Data?
    }

    public func setLocation(latitude: Double, longitude: Double) {
        let sel = NSSelectorFromString("setLocationWithLatitude:andLongitude:")
        guard proxy.responds(to: sel),
              let method = class_getInstanceMethod(type(of: proxy), sel) else { return }
        typealias LocIMP = @convention(c) (AnyObject, Selector, Double, Double) -> Void
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: LocIMP.self)
        fn(proxy, sel, latitude, longitude)
    }

    // MARK: - mach_port_t → NSDistantObject<SimulatorBridge> bridge

    /// Wraps a mach send-port in an NSMachPort + NSConnection and returns
    /// BOTH the remote root proxy AND the NSConnection so the caller can
    /// retain the connection. Dropping the connection invalidates the proxy.
    private static func rootProxyAndConnection(fromMachPort port: UInt32) -> (proxy: NSObject, connection: NSObject)? {
        guard let portCls = NSClassFromString("NSMachPort") as? NSObject.Type,
              let connCls = NSClassFromString("NSConnection") as? NSObject.Type else {
            return nil
        }

        guard let sendPort = Self.makeNSMachPort(class: portCls, machPort: port) else { return nil }

        let connSel = NSSelectorFromString("connectionWithReceivePort:sendPort:")
        guard let connMethod = class_getClassMethod(connCls, connSel) else { return nil }
        // +0 autoreleased factory — raw AnyObject? causes double-release on pool
        // drain. Use Unmanaged+takeUnretainedValue for explicit retain (same fix
        // pattern as Display.msg and LayerBridge.CAContext).
        typealias ConnIMP = @convention(c) (AnyClass, Selector, AnyObject?, AnyObject) -> Unmanaged<AnyObject>?
        let connImp = method_getImplementation(connMethod)
        let connFn = unsafeBitCast(connImp, to: ConnIMP.self)
        guard let conn = connFn(connCls, connSel, nil, sendPort)?.takeUnretainedValue() as? NSObject else { return nil }

        // Keep timeouts small: Xcode-26 CoreSimulatorBridge advertises XPC-only
        // Mach names that accept our send-port but never answer DO messages.
        // A 5s block here used to stall device-boot by 5s PER candidate and
        // terminate the daemon on NSPortTimeoutException. 1.5s is enough for
        // a real SimulatorBridge helper to reply on localhost.
        for (selName, val) in [("setRequestTimeout:", 1.5), ("setReplyTimeout:", 1.5)] {
            let s = NSSelectorFromString(selName)
            if conn.responds(to: s),
               let m = class_getInstanceMethod(type(of: conn), s) {
                typealias DblIMP = @convention(c) (AnyObject, Selector, Double) -> Void
                let fn = unsafeBitCast(method_getImplementation(m), to: DblIMP.self)
                fn(conn, s, val)
            }
        }

        // Route through a C shim that wraps `-rootProxy` in @try/@catch.
        // `NSPortTimeoutException` from a non-DO endpoint would otherwise
        // unwind past Swift and abort the whole process.
        guard let proxy = T3SafeRootProxy(conn) as? NSObject else { return nil }
        return (proxy, conn)
    }

    private static func makeNSMachPort(class portCls: NSObject.Type, machPort: UInt32) -> NSObject? {
        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(portCls, allocSel) else { return nil }
        typealias AllocIMP = @convention(c) (AnyClass, Selector) -> AnyObject?
        let allocFn = unsafeBitCast(method_getImplementation(allocMethod), to: AllocIMP.self)
        guard let allocated = allocFn(portCls, allocSel) else { return nil }

        let initSel = NSSelectorFromString("initWithMachPort:")
        guard let initMethod = class_getInstanceMethod(portCls, initSel) else { return nil }
        typealias InitIMP = @convention(c) (AnyObject, Selector, UInt32) -> AnyObject?
        let initFn = unsafeBitCast(method_getImplementation(initMethod), to: InitIMP.self)
        return initFn(allocated, initSel, machPort) as? NSObject
    }
}
