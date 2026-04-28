import Foundation
import ObjectiveC.runtime
import CPrivate
import CSupport
@preconcurrency import IOSurface

public final class Display: @unchecked Sendable {
    public struct Info: Sendable {
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let scale: CGFloat
    }

    public typealias SurfaceHandler = @Sendable (IOSurfaceRef, Info) -> Void
    public typealias DamageHandler = @Sendable () -> Void

    private let device: SimDevice
    private let queue = DispatchQueue(label: "t3.simbridge.display")
    private var currentSurface: IOSurfaceRef?
    private var handler: SurfaceHandler?
    private var damageHandler: DamageHandler?
    private var descriptor: NSObject?
    private var surfaceUUID: UUID?
    private var damageUUID: UUID?
    private var framebufferService: NSObject?
    private var framebufferClient: FramebufferClient?
    private var surfacePollTimer: DispatchSourceTimer?
    private var simDeviceScreen: NSObject?
    private var attachedIO: NSObject?
    private var attachedPort: NSObject?
    private var attachedConsumer: FramebufferClient?
    private var adapterDesc: NSObject?
    private var adapterUUID: UUID?
    private var screen: NSObject?
    private var screenUUID: UUID?

    // Diagnostic counters — serialized on `queue` so no locking required.
    private var ioDamageTicks: UInt = 0
    private var screenFrameTicks: UInt = 0

    public init(device: SimDevice) { self.device = device }

    /// Snapshot the most recently published IOSurface. Safe to call from
    /// any thread; returns nil if no frame has been delivered yet or the
    /// simulator is not attached. The returned reference is retained by
    /// `Display`, so callers MUST NOT `IOSurfaceLock` across the bounds of
    /// a new frame arriving — take a read-locked copy before reading pixels.
    public func snapshotSurface() -> IOSurfaceRef? {
        return currentSurface
    }

    public func attach(onSurface: @escaping SurfaceHandler, onDamage: @escaping DamageHandler = {}) throws {
        self.handler = onSurface
        self.damageHandler = onDamage
        Self.log("attach begin")
        do {
            Self.log("attach framebuffer service")
            try attachViaFramebufferService()
            Self.log("attach framebuffer service ok")
        } catch {
            Self.log("attach framebuffer service failed error=\(error.localizedDescription)")
            Self.log("attach io ports")
            try attachViaIOPorts()
            Self.log("attach io ports ok")
        }
        Self.log("attach screen adapter")
        try? attachViaScreenAdapter()
        Self.log("attach end")
    }

    private func attachViaSimDeviceScreen() throws {
        guard let screen = Self.makeDeviceScreen(for: device, screenID: 0) else {
            throw DisplayError.simDeviceScreenUnavailable
        }
        simDeviceScreen = screen
        Self.log("SimDeviceScreen class=\(NSStringFromClass(type(of: screen)))")
        if let surface = currentDeviceScreenSurface(from: screen) {
            publishSurface(surface)
        } else {
            Self.log("SimDeviceScreen surface missing on attach")
        }
        startSimDeviceScreenPolling(screen)
    }

    private func attachViaFramebufferService() throws {
        guard let service = Self.makeFramebufferService(for: device) else {
            throw DisplayError.framebufferServiceUnavailable
        }
        Self.log("framebuffer service class=\(NSStringFromClass(type(of: service)))")
        let client = FramebufferClient(
            onSurface: { [weak self] surface in
                self?.queue.async { [weak self] in
                    self?.publishSurface(surface)
                }
            },
            onDamage: { [weak self] in
                self?.damageHandler?()
            }
        )
        Self.register(client: client, on: queue, service: service)
        Self.log("framebuffer service registerClient ok")
        Self.resume(service: service)
        Self.log("framebuffer service resume ok")
        framebufferService = service
        framebufferClient = client
        descriptor = try? resolveDisplayDescriptor()
        if let descriptor {
            Self.log("framebuffer descriptor class=\(NSStringFromClass(type(of: descriptor)))")
        } else {
            Self.log("framebuffer descriptor missing")
        }
        startSurfacePolling()
    }

    private func attachViaIOPorts() throws {
        let endpoint = try resolveDisplayEndpoint()
        Self.log("io endpoint portClass=\(NSStringFromClass(type(of: endpoint.port))) descClass=\(NSStringFromClass(type(of: endpoint.descriptor)))")
        descriptor = endpoint.descriptor
        attachedIO = endpoint.io
        attachedPort = endpoint.port

        let consumer = FramebufferClient(
            onSurface: { [weak self] surface in
                self?.queue.async { [weak self] in
                    self?.publishSurface(surface)
                }
            },
            onDamage: { [weak self] in
                self?.damageHandler?()
            }
        )
        attachedConsumer = consumer
        let attachSel = NSSelectorFromString("attachConsumer:toPort:")
        if endpoint.io.responds(to: attachSel) {
            T3MsgSendAttach(endpoint.io, attachSel, consumer, endpoint.port)
            Self.log("io attachConsumer ok")
        }

        let desc = endpoint.descriptor

        if let surface = currentSurface(from: desc) {
            publishSurface(surface)
            Self.log("io initial publishSurface returned")
        }

        let descClassName = NSStringFromClass(type(of: desc))
        if descClassName.contains("SimScreen") {
            // Xcode 26+: `iOPorts` now return SimScreen objects (under
            // `SimDeviceIOPortDescriptorInterface`) instead of the older
            // `SimDisplayIOSurfaceRenderable` descriptors. The legacy
            // `registerCallbackWithUUID:ioSurface*ChangeCallback:` and
            // `registerCallbackWithUUID:damageRectanglesCallback:` selectors
            // DON'T EXIST on SimScreen — sending them raises `unrecognized
            // selector sent to instance`, which ROCK forwards across XPC.
            // Swift can't see that NSException, so the callback-registration
            // phase unwinds silently and the pane freezes at first frame.
            //
            // The modern equivalent is `registerScreenCallbacksWithUUID:
            // callbackQueue:frameCallback:surfacesChangedCallback:
            // propertiesChangedCallback:` which covers both damage (via
            // frameCallback) and surface swap (via surfacesChangedCallback)
            // in one registration. Route directly through `bind(screen:)`.
            Self.log("io descriptor is a SimScreen — using modern screen callbacks")
            bind(screen: desc, initialSurface: currentSurface(from: desc))
        } else {
            // Legacy SimDisplay descriptor path: register BOTH plural and
            // singular surface-change shapes unconditionally (ROCK proxies
            // lie about respondsToSelector:), plus a damage callback.
            let surfaceUUID = UUID()
            self.surfaceUUID = surfaceUUID
            let pluralCb: @convention(block) (AnyObject?) -> Void = { [weak self] payload in
                guard let self else { return }
                self.queue.async {
                    Self.log("io-surface-callback (plural) fired payload=\(payload.map { String(describing: type(of: $0)) } ?? "nil")")
                    guard let surface = Self.surface(from: payload) ?? self.currentSurface(from: desc) else {
                        Self.log("io-surface-callback (plural) no surface resolved")
                        return
                    }
                    self.publishSurface(surface)
                }
            }
            let singularCb: @convention(block) (AnyObject?) -> Void = { [weak self] payload in
                guard let self else { return }
                self.queue.async {
                    Self.log("io-surface-callback (singular) fired payload=\(payload.map { String(describing: type(of: $0)) } ?? "nil")")
                    guard let surface = Self.surface(from: payload) ?? self.currentSurface(from: desc) else {
                        Self.log("io-surface-callback (singular) no surface resolved")
                        return
                    }
                    self.publishSurface(surface)
                }
            }
            let pluralSel = NSSelectorFromString("registerCallbackWithUUID:ioSurfacesChangeCallback:")
            let singularSel = NSSelectorFromString("registerCallbackWithUUID:ioSurfaceChangeCallback:")
            T3MsgSendRegisterCallback(desc, pluralSel, surfaceUUID, pluralCb)
            T3MsgSendRegisterCallback(desc, singularSel, surfaceUUID, singularCb)
            Self.log("io surface callbacks registered (plural + singular)")

            let damageUUID = UUID()
            self.damageUUID = damageUUID
            let damageSel = NSSelectorFromString("registerCallbackWithUUID:damageRectanglesCallback:")
            let damageCb: @convention(block) ([AnyObject]?) -> Void = { [weak self] rects in
                guard let self else { return }
                self.queue.async {
                    self.ioDamageTicks &+= 1
                    if self.ioDamageTicks <= 3 || self.ioDamageTicks % 60 == 0 {
                        Self.log("io-damage fired n=\(self.ioDamageTicks) rects=\(rects?.count ?? 0)")
                    }
                    self.damageHandler?()
                }
            }
            T3MsgSendRegisterCallback(desc, damageSel, damageUUID, damageCb)
            Self.log("io damage callback registered")
        }
        startSurfacePolling()
    }

    private func publishSurface(_ surface: IOSurfaceRef) {
        currentSurface = surface
        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)
        Self.log("publishSurface \(w)x\(h)")
        Self.samplePixels(surface)
        handler?(surface, Info(pixelWidth: w, pixelHeight: h, scale: mainScreenScale()))
    }

    /// Read 3 pixels (top-left, center, bottom-right) and log their 32-bit
    /// BGRA values. If the simulator is actually writing frames, at least one
    /// sample will be non-zero. All zeros → surface is never touched. Any
    /// non-zero → simulator has painted; the black pane is a composition
    /// problem, not a source problem.
    private static func samplePixels(_ surface: IOSurfaceRef) {
        let lockOpts = IOSurfaceLockOptions.readOnly
        guard IOSurfaceLock(surface, lockOpts, nil) == kIOReturnSuccess else {
            log("samplePixels IOSurfaceLock failed")
            return
        }
        defer { _ = IOSurfaceUnlock(surface, lockOpts, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)
        let stride = IOSurfaceGetBytesPerRow(surface)
        let bpp = IOSurfaceGetBytesPerElement(surface)
        let fmt = IOSurfaceGetPixelFormat(surface)
        // PixelFormat is a FourCC: ASCII bytes. Render for readability.
        let fmtStr = String(format: "%c%c%c%c",
                            (fmt >> 24) & 0xFF,
                            (fmt >> 16) & 0xFF,
                            (fmt >> 8) & 0xFF,
                            fmt & 0xFF)
        func read(_ x: Int, _ y: Int) -> UInt32 {
            let offset = y * stride + x * bpp
            return base.load(fromByteOffset: offset, as: UInt32.self)
        }
        let p0 = read(0, 0)
        let pc = read(w / 2, h / 2)
        let pe = read(max(0, w - 1), max(0, h - 1))
        log(String(format: "pixel fmt=%@ bpp=%d stride=%d tl=0x%08x ct=0x%08x br=0x%08x",
                   fmtStr, bpp, stride, p0, pc, pe))
    }

    public func detach() {
        surfacePollTimer?.cancel()
        surfacePollTimer = nil
        if let service = framebufferService, let client = framebufferClient {
            Self.unregister(client: client, from: service)
            Self.invalidate(service: service)
        }
        framebufferService = nil
        framebufferClient = nil
        simDeviceScreen = nil
        if let io = attachedIO, let port = attachedPort, let consumer = attachedConsumer {
            let detachSel = NSSelectorFromString("detachConsumer:fromPort:")
            if io.responds(to: detachSel) {
                T3MsgSendDetach(io, detachSel, consumer, port)
            }
        }
        attachedIO = nil
        attachedPort = nil
        attachedConsumer = nil
        if let desc = descriptor, let uuid = surfaceUUID {
            // We registered both plural and singular callbacks under the
            // same UUID — mirror that on teardown. Sending an unregister for
            // a selector the remote doesn't implement is a no-op.
            let modern = NSSelectorFromString("unregisterIOSurfacesChangeCallbackWithUUID:")
            let legacy = NSSelectorFromString("unregisterIOSurfaceChangeCallbackWithUUID:")
            T3MsgSendUnregisterCallback(desc, modern, uuid)
            T3MsgSendUnregisterCallback(desc, legacy, uuid)
        }
        if let desc = descriptor, let uuid = damageUUID {
            let selector = NSSelectorFromString("unregisterDamageRectanglesCallbackWithUUID:")
            if desc.responds(to: selector) {
                T3MsgSendUnregisterCallback(desc, selector, uuid)
            }
        }
        unbindScreen()
        if let desc = adapterDesc, let uuid = adapterUUID {
            let selector = NSSelectorFromString("unregisterScreenAdapterCallbacksWithUUID:")
            if desc.responds(to: selector) {
                T3MsgSendUnregisterCallback(desc, selector, uuid)
            }
        }
        adapterDesc = nil
        adapterUUID = nil
        descriptor = nil
        surfaceUUID = nil
        damageUUID = nil
        currentSurface = nil
        handler = nil
        damageHandler = nil
    }

    fileprivate static func msg(_ obj: NSObject, _ name: String) -> Any? {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: obj), sel) else { return nil }
        // ObjC methods return +0 autoreleased by convention. Swift's ARC does not
        // apply `objc_retainAutoreleasedReturnValue` to `@convention(c)` IMP-cast
        // calls, so a raw `-> AnyObject?` return yields an unretained pointer
        // that Swift nevertheless releases at scope-end. The resulting double
        // release (scope release + pool drain) crashes
        // `objc_autoreleasePoolPop`. Returning `Unmanaged<AnyObject>?` and
        // taking via `takeUnretainedValue()` retains explicitly, giving Swift a
        // real +1 that balances correctly against the pool's slot.
        typealias IMP = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(method_getImplementation(method), to: IMP.self)
        return fn(obj, sel)?.takeUnretainedValue()
    }

    /// Same as `msg` but goes through `perform:` so ROCK-proxy forwarded
    /// methods are reachable. Use this for property/selector lookups on
    /// ROCK proxies — `class_getInstanceMethod` returns nil for methods
    /// handled via `forwardInvocation:`, which causes `msg` to bail out
    /// with nil.
    fileprivate static func legacyMsg(_ obj: NSObject, _ name: String) -> Any? {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return nil }
        return obj.perform(sel)?.takeUnretainedValue()
    }

    private func mainScreenScale() -> CGFloat {
        let raw =
            ((device.value(forKey: "deviceType") as? NSObject)?.value(forKey: "mainScreenScale") as? NSNumber)?
            .doubleValue ?? 0
        return raw > 0 ? raw : 1
    }

    private func resolveDisplayDescriptor() throws -> NSObject {
        try resolveDisplayEndpoint().descriptor
    }

    private func resolveDisplayEndpoint() throws -> (io: NSObject, port: NSObject, descriptor: NSObject) {
        guard let io = device.value(forKey: "io") as? NSObject else {
            throw DisplayError.noIOPorts
        }
        if let port = Self.mainDisplayPort(from: io),
           let descriptor = Self.msg(port, "descriptor") as? NSObject {
            Self.log("resolveDisplayEndpoint via portForDisplayClass desc=\(NSStringFromClass(type(of: descriptor)))")
            return (io: io, port: port, descriptor: descriptor)
        }
        guard let ports = Self.msg(io, "ioPorts") as? [NSObject], !ports.isEmpty else {
            throw DisplayError.noIOPorts
        }
        Self.log("resolveDisplayEndpoint ports=\(ports.count)")

        // ROCK encodes the remote protocol set in the proxy class name. On
        // Xcode 26 `state.displayClass` returns nil for every descriptor
        // (ROCK's `state` isn't reachable through `class_getInstanceMethod`
        // the way `msg` uses it), so we can't gate on display-class == 0
        // anymore. The previous fallback picked the first surface-capable
        // descriptor, which in practice was `SimDeviceIOMachServiceProvider`
        // (every port looks surface-capable to a dumb proxy check). Attaching
        // a framebuffer consumer to the Mach service provider blocks
        // `attachConsumer:toPort:` inside ROCK, freezing the pane at
        // "Starting". Rank descriptors by class-name tokens instead.
        let rejectTokens = [
            "MachServiceProvider",
            "LegacyHID",
            "AudioHost",
            "StreamProcessable",
            "AcceleratorMetalDevice",
            "AcceleratorIOSurface",
            "ScreenAdapter",
        ]
        let acceptTokens = [
            "SimDisplayIOSurfaceRenderable",
            "SimDisplayRenderable",
        ]

        var bestDisplay: (port: NSObject, desc: NSObject, area: Int)?
        var firstSurfaceCapable: (NSObject, NSObject)?
        for port in ports {
            guard let desc = Self.legacyMsg(port, "descriptor") as? NSObject else {
                Self.log("port missing descriptor class=\(NSStringFromClass(type(of: port)))")
                continue
            }
            let descClass = NSStringFromClass(type(of: desc))
            if rejectTokens.contains(where: { descClass.contains($0) }) {
                Self.log("skip port desc=\(descClass) non-display")
                continue
            }
            let isDisplay = acceptTokens.contains(where: { descClass.contains($0) })
            let surface = currentSurface(from: desc)
            let canCallback = supportsSurfaceCallback(on: desc)
            if surface == nil && !canCallback && !isDisplay {
                Self.log("skip port desc=\(descClass) no surface/callback")
                continue
            }
            let area = surface.map { IOSurfaceGetWidth($0) * IOSurfaceGetHeight($0) } ?? 0
            Self.log("candidate desc=\(descClass) display=\(isDisplay) hasSurface=\(surface != nil) area=\(area)")
            if isDisplay {
                if bestDisplay == nil || area > bestDisplay!.area {
                    bestDisplay = (port, desc, area)
                }
            } else if firstSurfaceCapable == nil {
                firstSurfaceCapable = (port, desc)
            }
        }
        let picked: (NSObject, NSObject)
        if let best = bestDisplay {
            picked = (best.port, best.desc)
        } else if let fb = firstSurfaceCapable {
            picked = fb
        } else {
            throw DisplayError.mainDisplayNotFound
        }
        Self.log("resolveDisplayEndpoint picked desc=\(NSStringFromClass(type(of: picked.1)))")
        return (io: io, port: picked.0, descriptor: picked.1)
    }

    private func startSurfacePolling() {
        guard let descriptor else { return }
        Self.log("startSurfacePolling")
        surfacePollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self, weak descriptor] in
            guard let self, let descriptor else { return }
            guard let surface = self.currentSurface(from: descriptor) else { return }
            self.publishSurface(surface)
            self.surfacePollTimer?.cancel()
            self.surfacePollTimer = nil
        }
        surfacePollTimer = timer
        timer.resume()
    }

    private func startSimDeviceScreenPolling(_ screen: NSObject) {
        surfacePollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self, weak screen] in
            guard let self, let screen else { return }
            guard let surface = self.currentDeviceScreenSurface(from: screen) else { return }
            if let current = self.currentSurface, Self.sameSurface(current, surface) {
                self.damageHandler?()
                return
            }
            self.publishSurface(surface)
        }
        surfacePollTimer = timer
        timer.resume()
    }

    private func attachViaScreenAdapter() throws {
        guard let io = device.value(forKey: "io") as? NSObject else {
            throw DisplayError.noIOPorts
        }
        guard let ports = Self.msg(io, "ioPorts") as? [NSObject], !ports.isEmpty else {
            throw DisplayError.noIOPorts
        }
        let selector = NSSelectorFromString(
            "registerScreenAdapterCallbacksWithUUID:callbackQueue:screenConnectedCallback:screenWillDisconnectCallback:"
        )
        // `descriptor` is a proxy-forwarded property on ROCK-proxy ports, so
        // use `legacyMsg` (perform:) — `msg`'s class_getInstanceMethod path
        // returns nil for methods routed via forwardInvocation:, which made
        // every lookup fail and the screen-adapter path silently unreachable
        // on Xcode 26.
        guard let desc = ports.compactMap({ Self.legacyMsg($0, "descriptor") as? NSObject }).first(where: {
            $0.responds(to: selector)
        }) else {
            throw DisplayError.screenAdapterUnavailable
        }
        Self.log("screen adapter descClass=\(NSStringFromClass(type(of: desc)))")
        adapterDesc = desc
        let connected: @convention(block) (AnyObject?) -> Void = { [weak self] screen in
            guard let self, let screen = screen as? NSObject else { return }
            self.queue.async { self.bind(screen: screen) }
        }
        // Xcode 26 ObjC encoding: `void(^)(unsigned int)` — `I` = 32-bit uint
        // (screen ID). Declaring `(AnyObject?) -> Void` makes Swift's block
        // thunk read x1 as an object pointer and objc_retain it — crashes
        // when x1 holds a uint value, not a heap pointer.
        let disconnected: @convention(block) (UInt32) -> Void = { [weak self] _ in
            self?.queue.async { [weak self] in self?.unbindScreen() }
        }
        let uuid = UUID()
        adapterUUID = uuid
        T3MsgSendRegisterScreenAdapter(desc, selector, uuid, queue, connected, disconnected)
        Self.log("screen adapter registered")
        enumerateExistingScreens(on: desc)
    }

    private func enumerateExistingScreens(on adapter: NSObject) {
        let selector = NSSelectorFromString("enumerateScreensWithCompletionQueue:completionHandler:")
        guard adapter.responds(to: selector) else { return }
        let completion: @convention(block) (AnyObject?, NSError?) -> Void = { [weak self] screens, _ in
            guard let self else { return }
            let list = (screens as? [AnyObject])?.compactMap { $0 as? NSObject } ?? []
            var best: (NSObject, IOSurfaceRef)?
            for screen in list {
                guard let surface = self.currentScreenSurface(from: screen) else { continue }
                let area = IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface)
                let bestArea = best.map { IOSurfaceGetWidth($0.1) * IOSurfaceGetHeight($0.1) } ?? 0
                if area > bestArea {
                    best = (screen, surface)
                }
            }
            if let best {
                self.queue.async { self.bind(screen: best.0, initialSurface: best.1) }
            } else if let first = list.first {
                self.queue.async { self.bind(screen: first) }
            }
        }
        T3MsgSendEnumerateScreens(adapter, selector, queue, completion)
        Self.log("screen adapter enumerate requested")
    }

    private func bind(screen: NSObject, initialSurface: IOSurfaceRef? = nil) {
        unbindScreen()
        self.screen = screen
        Self.log("bind screen class=\(NSStringFromClass(type(of: screen)))")
        if let surface = initialSurface ?? currentScreenSurface(from: screen) {
            publishSurface(surface)
        }
        let selector = NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"
        )
        guard screen.responds(to: selector) else { return }
        // Xcode 26 ObjC encoding: `void(^)(void)` — no args.
        let frame: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.screenFrameTicks &+= 1
                if self.screenFrameTicks <= 3 || self.screenFrameTicks % 60 == 0 {
                    Self.log("screen-frame fired n=\(self.screenFrameTicks)")
                }
                self.damageHandler?()
            }
        }
        // Xcode 26 ObjC encoding: `void(^)(IOSurface, IOSurface)` — two
        // surfaces (unmasked, masked). Prefer unmasked; fall back to masked.
        let surfacesChanged: @convention(block) (AnyObject?, AnyObject?) -> Void = { [weak self] unmasked, masked in
            guard let self else { return }
            let surface = Self.asIOSurface(unmasked) ?? Self.asIOSurface(masked)
            guard let surface else { return }
            self.queue.async { self.publishSurface(surface) }
        }
        let propertiesChanged: @convention(block) (AnyObject?) -> Void = { _ in }
        let uuid = UUID()
        screenUUID = uuid
        T3MsgSendRegisterScreen(screen, selector, uuid, queue, frame, surfacesChanged, propertiesChanged)
        Self.log("screen callbacks registered")
    }

    private func unbindScreen() {
        if let screen, let uuid = screenUUID {
            let selector = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
            if screen.responds(to: selector) {
                T3MsgSendUnregisterCallback(screen, selector, uuid)
            }
        }
        screen = nil
        screenUUID = nil
    }

    private func currentScreenSurface(from screen: NSObject) -> IOSurfaceRef? {
        // SimScreen arrives as a ROCK proxy on Xcode 26 — its `framebufferSurface`
        // / `ioSurface` properties are forwarded via `forwardInvocation:`, which
        // `class_getInstanceMethod` cannot see. `legacyMsg` goes through
        // `perform:` and triggers the proxy's forwarding so the remote
        // IOSurface is actually fetched.
        if let surface = Self.asIOSurface(Self.legacyMsg(screen, "framebufferSurface")) {
            return surface
        }
        return Self.asIOSurface(Self.legacyMsg(screen, "ioSurface"))
    }

    private func currentDeviceScreenSurface(from screen: NSObject) -> IOSurfaceRef? {
        Self.log("SimDeviceScreen get unmaskedSurface")
        let unmasked = Self.msg(screen, "unmaskedSurface")
        Self.log("SimDeviceScreen got unmaskedSurface type=\(unmasked.map { String(describing: type(of: $0)) } ?? "nil")")
        if let surface = Self.asIOSurface(unmasked) {
            return surface
        }
        Self.log("SimDeviceScreen get framebufferSurface")
        let framebuffer = Self.msg(screen, "framebufferSurface")
        Self.log("SimDeviceScreen got framebufferSurface type=\(framebuffer.map { String(describing: type(of: $0)) } ?? "nil")")
        if let surface = Self.asIOSurface(framebuffer) {
            return surface
        }
        Self.log("SimDeviceScreen get maskedSurface")
        let masked = Self.msg(screen, "maskedSurface")
        Self.log("SimDeviceScreen got maskedSurface type=\(masked.map { String(describing: type(of: $0)) } ?? "nil")")
        return Self.asIOSurface(masked)
    }

    private func currentSurface(from descriptor: NSObject) -> IOSurfaceRef? {
        // The IO-ports descriptor is a ROCK proxy on Xcode 26+: its
        // `framebufferSurface` / `ioSurface` accessors are forwarded via
        // `forwardInvocation:`, which `class_getInstanceMethod` (the path
        // `msg` uses) cannot see — returns nil even when the remote surface
        // exists. `legacyMsg` goes through `perform:` and so triggers the
        // proxy's forwarding machinery. We try both selectors because the
        // SPI evolved: older CoreSimulator exposes `ioSurface`, newer ones
        // rename it to `framebufferSurface` (and ROCK sometimes mis-reports
        // respondsToSelector:, so we don't gate on it).
        if let surface = Self.asIOSurface(Self.legacyMsg(descriptor, "framebufferSurface")) {
            return surface
        }
        return Self.asIOSurface(Self.legacyMsg(descriptor, "ioSurface"))
    }

    private func supportsSurfaceCallback(on descriptor: NSObject) -> Bool {
        // ROCK proxies mis-report respondsToSelector:, so we can't trust
        // either answer. Fall back to asserting at least one of the known
        // selectors exists on the concrete class, and additionally claim
        // support whenever the descriptor is a remote proxy (whose ability
        // to respond is only discoverable by actually sending the message).
        let plural = NSSelectorFromString("registerCallbackWithUUID:ioSurfacesChangeCallback:")
        let singular = NSSelectorFromString("registerCallbackWithUUID:ioSurfaceChangeCallback:")
        if descriptor.responds(to: plural) || descriptor.responds(to: singular) {
            return true
        }
        return NSStringFromClass(type(of: descriptor)).contains("Proxy")
    }

    fileprivate static func surface(from payload: AnyObject?) -> IOSurfaceRef? {
        if let payload,
           let surface = asIOSurface(payload) {
            return surface
        }
        if let dict = payload as? [String: Any] {
            for key in ["framebufferSurface", "framebuffer", "unmaskedSurface", "ioSurface", "surface"] {
                if let surface = asIOSurface(dict[key]) {
                    return surface
                }
            }
        }
        return nil
    }

    private static func asIOSurface(_ value: Any?) -> IOSurfaceRef? {
        guard let object = value as AnyObject? else { return nil }
        let className = String(cString: object_getClassName(object))
        guard className.contains("IOSurface") else {
            log("asIOSurface skipped class=\(className)")
            return nil
        }
        return unsafeBitCast(object, to: IOSurfaceRef.self)
    }

    private static func sameSurface(_ lhs: IOSurfaceRef, _ rhs: IOSurfaceRef) -> Bool {
        Unmanaged.passUnretained(lhs).toOpaque() == Unmanaged.passUnretained(rhs).toOpaque()
    }

    private static func makeDeviceScreen(for device: SimDevice, screenID: UInt32) -> NSObject? {
        guard let cls = simulatorKitClass(named: "SimDeviceScreen") else {
            return nil
        }
        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else {
            return nil
        }
        typealias AllocIMP = @convention(c) (AnyClass, Selector) -> AnyObject
        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: AllocIMP.self)
        let raw = alloc(cls, allocSel)

        let initSel = NSSelectorFromString("initWithDevice:screenID:")
        guard let initMethod = class_getInstanceMethod(cls, initSel) else {
            return nil
        }
        typealias InitIMP = @convention(c) (AnyObject, Selector, SimDevice, UInt32) -> NSObject?
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: InitIMP.self)
        return initialize(raw, initSel, device, screenID)
    }

    private static func simulatorKitClass(named name: String) -> AnyClass? {
        if let cls = NSClassFromString("SimulatorKit.\(name)") {
            return cls
        }
        _ = Bundle(path: "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework")?.load()
        return NSClassFromString("SimulatorKit.\(name)")
    }

    private static func makeFramebufferService(for device: SimDevice) -> NSObject? {
        guard let cls = NSClassFromString("SimDeviceFramebufferService") else {
            return nil
        }
        let sel = NSSelectorFromString("mainScreenFramebufferServiceForDevice:error:")
        guard let method = class_getClassMethod(cls, sel) else {
            return nil
        }
        // Factory class method returns +0 autoreleased per ObjC convention.
        // See `msg` for why Unmanaged+takeUnretainedValue is required.
        // AutoreleasingUnsafeMutablePointer is the Swift bridging type for
        // `NSError **` out-params — plain UnsafeMutablePointer desyncs ARC.
        typealias IMP = @convention(c) (AnyClass, Selector, SimDevice, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Unmanaged<NSObject>?
        let fn = unsafeBitCast(method_getImplementation(method), to: IMP.self)
        var error: NSError?
        if let service = fn(cls, sel, device, &error)?.takeUnretainedValue() {
            return service
        }
        if let error {
            let msg = error.localizedDescription
            log("mainScreenFramebufferServiceForDevice failed error=\(msg)")
        }
        return makeFramebufferServiceManually(using: cls, device: device)
    }

    private static func makeFramebufferServiceManually(using cls: AnyClass, device: SimDevice) -> NSObject? {
        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else {
            return nil
        }
        typealias AllocIMP = @convention(c) (AnyClass, Selector) -> AnyObject
        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: AllocIMP.self)
        let raw = alloc(cls, allocSel)

        let initSel = NSSelectorFromString("initWithName:displayClass:device:")
        guard let initMethod = class_getInstanceMethod(cls, initSel) else {
            return nil
        }
        typealias InitIMP = @convention(c) (AnyObject, Selector, NSString, UInt16, SimDevice) -> NSObject?
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: InitIMP.self)
        let service = initialize(raw, initSel, "t3.display", 0, device)
        if service != nil {
            log("manual framebuffer service init ok")
        }
        return service
    }

    private static func mainDisplayPort(from io: NSObject) -> NSObject? {
        guard let cls = NSClassFromString("SimDeviceFramebufferService") else {
            return nil
        }
        let sel = NSSelectorFromString("portForDisplayClass:io:")
        guard let method = class_getClassMethod(cls, sel) else {
            return nil
        }
        // Factory class method returns +0 autoreleased. See `msg` above.
        typealias IMP = @convention(c) (AnyClass, Selector, UInt16, NSObject) -> Unmanaged<NSObject>?
        let fn = unsafeBitCast(method_getImplementation(method), to: IMP.self)
        return fn(cls, sel, 0, io)?.takeUnretainedValue()
    }

    private static func register(client: NSObject, on queue: DispatchQueue, service: NSObject) {
        let sel = NSSelectorFromString("registerClient:onQueue:")
        guard let method = class_getInstanceMethod(type(of: service), sel) else {
            return
        }
        typealias IMP = @convention(c) (AnyObject, Selector, NSObject, DispatchQueue) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: IMP.self)
        fn(service, sel, client, queue)
    }

    private static func unregister(client: NSObject, from service: NSObject) {
        let sel = NSSelectorFromString("unregisterClient:")
        guard let method = class_getInstanceMethod(type(of: service), sel) else {
            return
        }
        typealias IMP = @convention(c) (AnyObject, Selector, NSObject) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: IMP.self)
        fn(service, sel, client)
    }

    private static func resume(service: NSObject) {
        let sel = NSSelectorFromString("resume")
        guard let method = class_getInstanceMethod(type(of: service), sel) else {
            return
        }
        typealias IMP = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: IMP.self)
        fn(service, sel)
    }

    private static func invalidate(service: NSObject) {
        let sel = NSSelectorFromString("invalidate")
        guard let method = class_getInstanceMethod(type(of: service), sel) else {
            return
        }
        typealias IMP = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: IMP.self)
        fn(service, sel)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[display] \(message)\n".utf8))
    }

    public enum DisplayError: Error, LocalizedError {
        case noIOPorts
        case mainDisplayNotFound
        case framebufferServiceUnavailable
        case simDeviceScreenUnavailable
        case screenAdapterUnavailable

        public var errorDescription: String? {
            switch self {
            case .noIOPorts: return "Simulator has no IO ports (is it booted?)."
            case .mainDisplayNotFound: return "Main display port not found."
            case .framebufferServiceUnavailable: return "Main framebuffer service unavailable."
            case .simDeviceScreenUnavailable: return "SimDeviceScreen unavailable."
            case .screenAdapterUnavailable: return "Screen adapter unavailable."
            }
        }
    }
}

private final class FramebufferClient: NSObject {
    @objc let consumerUUID = UUID()
    @objc let consumerIdentifier = "t3.display"
    private let onSurface: @Sendable (IOSurfaceRef) -> Void
    private let onDamage: @Sendable () -> Void

    init(onSurface: @escaping @Sendable (IOSurfaceRef) -> Void, onDamage: @escaping @Sendable () -> Void) {
        self.onSurface = onSurface
        self.onDamage = onDamage
    }

    @objc
    func didChangeIOSurface(_ value: Any?) {
        guard let surface = Display.surface(from: value as AnyObject?) else {
            return
        }
        onSurface(surface)
    }

    @objc
    func didReceiveDamageRect(_ rect: CGRect) {
        onDamage()
    }

    @objc
    func didChangeDisplayAngle(_ angle: Double) {}
}
