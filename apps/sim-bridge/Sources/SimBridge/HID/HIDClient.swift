import Foundation
import ObjectiveC.runtime
import CPrivate

/// Wraps SimDeviceLegacyClient (the Obj-C name of what fb-idb calls
/// "SimDeviceLegacyHIDClient" in docs — per the vendored header at
/// PrivateHeaders/SimulatorKit/SimDeviceLegacyClient.h).
public final class HIDClient: @unchecked Sendable {
    private let legacy: NSObject
    private let queue = DispatchQueue(label: "t3.simbridge.hid")

    public enum HIDError: Error, LocalizedError {
        case clientUnavailable(String)
        public var errorDescription: String? {
            switch self {
            case .clientUnavailable(let m): return "HID client unavailable: \(m)"
            }
        }
    }

    public init(device: SimDevice) throws {
        // Force SimulatorKit dlopen so its classes register with the ObjC runtime.
        try? IndigoBridge.shared.load()

        // Class names span Xcode versions. The ObjC class is
        // SimDeviceLegacyClient; a Swift subclass may register as
        // SimulatorKit.SimDeviceLegacyHIDClient.
        let classNames = [
            "SimDeviceLegacyClient",
            "SimulatorKit.SimDeviceLegacyHIDClient",
            "_TtC12SimulatorKit24SimDeviceLegacyHIDClient",
            "SimDeviceLegacyHIDClient",
        ]
        guard let cls = classNames.lazy.compactMap({ NSClassFromString($0) }).first else {
            throw HIDError.clientUnavailable("class not found (tried: \(classNames.joined(separator: ", ")))")
        }

        // alloc via runtime (NSObject.alloc() is Swift-unavailable).
        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else {
            throw HIDError.clientUnavailable("alloc missing on \(NSStringFromClass(cls))")
        }
        typealias AllocIMP = @convention(c) (AnyClass, Selector) -> AnyObject?
        let allocFn = unsafeBitCast(method_getImplementation(allocMethod), to: AllocIMP.self)
        guard let allocated = allocFn(cls, allocSel) else {
            throw HIDError.clientUnavailable("alloc returned nil")
        }

        // initWithDevice:error: — SYNCHRONOUS (per vendored header).
        // Returns id, not BOOL. Error out-param is `id *` in header (really NSError**).
        let initSel = NSSelectorFromString("initWithDevice:error:")
        guard let initMethod = class_getInstanceMethod(cls, initSel) else {
            // Fallback: some toolchains expose only `init` + `setDevice:` — try init.
            let plainInitSel = NSSelectorFromString("init")
            if let plainInit = class_getInstanceMethod(cls, plainInitSel) {
                typealias PlainInitIMP = @convention(c) (AnyObject, Selector) -> AnyObject?
                let fn = unsafeBitCast(method_getImplementation(plainInit), to: PlainInitIMP.self)
                guard let obj = fn(allocated, plainInitSel) as? NSObject else {
                    throw HIDError.clientUnavailable("plain init returned nil")
                }
                self.legacy = obj
                return
            }
            throw HIDError.clientUnavailable("initWithDevice:error: + init both missing")
        }
        // AutoreleasingUnsafeMutablePointer is the correct Swift bridging type
        // for `NSError **` out-params in `@convention(c)` IMP casts. See
        // Bridge.swift for the full explanation.
        typealias InitIMP = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        let initFn = unsafeBitCast(method_getImplementation(initMethod), to: InitIMP.self)
        var err: NSError?
        guard let initialized = initFn(allocated, initSel, device, &err) as? NSObject else {
            let msg = err?.localizedDescription ?? "no error"
            throw HIDError.clientUnavailable("initWithDevice:error: returned nil — \(msg)")
        }
        if let err {
            let msg = err.localizedDescription
            throw HIDError.clientUnavailable(msg)
        }
        self.legacy = initialized
    }

    /// Send a raw Indigo message pointer. Ownership transfers (freeWhenDone: YES).
    public func send(messagePointer: UnsafeMutableRawPointer) throws {
        let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let method = class_getInstanceMethod(type(of: legacy), sel) else {
            // Fallback to the simpler one-arg send (per vendored header).
            let simpleSel = NSSelectorFromString("sendWithMessage:")
            guard let simple = class_getInstanceMethod(type(of: legacy), simpleSel) else {
                throw HIDError.clientUnavailable("sendWithMessage:... selector missing")
            }
            typealias SimpleIMP = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Void
            let fn = unsafeBitCast(method_getImplementation(simple), to: SimpleIMP.self)
            fn(legacy, simpleSel, messagePointer)
            return
        }
        // @convention(block) closures passed to @convention(c) IMPs are
        // stack-allocated unless the compiler can prove escape. The framework
        // schedules `completion` on `queue` — it outlives our stack frame,
        // so a non-heap block points to garbage by the time it runs, crashing
        // with SIGTRAP on the main queue when the framework dispatches back.
        // The vendored selector allows nil completion — skip the block
        // entirely rather than fight Block_copy from Swift.
        typealias SendIMP = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue, AnyObject?) -> Void
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: SendIMP.self)
        fn(legacy, sel, messagePointer, true, queue, nil)
    }
}
