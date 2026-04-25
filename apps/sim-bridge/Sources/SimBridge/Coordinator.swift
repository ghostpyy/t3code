import Foundation
import AppKit
@preconcurrency import IOSurface
@preconcurrency import CPrivate
import CSupport

@MainActor
final class Coordinator {
    private let ws: WSServer
    private let ctx: ServiceContext
    private let layerBridge = LayerBridge()

    private var currentDevice: Device?
    private var bridge: Bridge?
    private var inspector: Inspector?
    private var axInspector: AXInspector?
    private var display: Display?
    private var hid: HIDClient?
    private var bootMonitor: BootMonitor?
    private var currentInfo: Display.Info?
    // UIDeviceOrientation: 1 portrait, 2 portraitUpsideDown, 3 landscapeRight,
    // 4 landscapeLeft. Renderer drives this via `.rotate(_)`; we mirror the
    // value so onSurface re-applies the same transform whenever the framebuffer
    // service hands us a new IOSurface identity (otherwise a guest re-render
    // would land in portrait orientation until the user rotated again).
    private var currentOrientation: Int = 1
    private let port: UInt16
    // Monotonic sequence for hover requests. Each inbound axHit(.hover) bumps
    // the counter; responses check their captured seq against the latest
    // before dispatching, discarding stale work so rapid pointer motion
    // can't flash prior-frame hits over the current hovered element.
    private var lastHoverSeq: UInt64 = 0
    // Dedicated serial queue for HID sends. Every touch/drag/key message
    // routes through here so the guest iOS digitizer sees events in strict
    // FIFO order. Before this existed, performTap ran synchronously on main
    // but performDrag dispatched to DispatchQueue.global concurrently — so
    // a finger-up could race ahead of the in-flight drag samples, making the
    // simulator treat a swipe as a stray tap.
    private let hidQueue = DispatchQueue(label: "t3.simbridge.hid.ordered", qos: .userInteractive)

    init(port: UInt16 = 17323) throws {
        self.port = port
        self.ctx = try ServiceContext.make()
        self.ws = WSServer(port: port)
        ws.onMessage = { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                Task { await self.handle(data: data) }
            }
        }
    }

    func run() {
        do {
            try ws.start()
            broadcastDeviceList()
        } catch {
            emitError(code: "ws.start", message: error.localizedDescription)
        }
    }

    private func handle(data: Data) async {
        guard let msg = try? JSONDecoder().decode(PaneToBridge.self, from: data) else { return }
        switch msg {
        case .deviceList:
            broadcastDeviceList()
        case .deviceBoot(let udid):
            await startDevice(udid: udid)
        case .deviceShutdown(let udid):
            await stopDevice(udid: udid)
        case .inputTap(let x, let y, let phase):
            performTap(x: x, y: y, phase: phase)
        case .inputDrag(let points):
            performDrag(points: points)
        case .inputKey(let usage, let down, _):
            performKey(usage: usage, down: down)
        case .inputButton(let kind, let down):
            performButton(kind: kind, down: down)
        case .axEnable:
            inspector?.enable()
        case .axHit(let x, let y, let mode):
            emitHit(x: x, y: y, mode: mode)
        case .axTree:
            emitTree()
        case .axSnapshot:
            emitSnapshot()
        case .rotate(let orientation):
            performRotate(orientation: orientation)
        case .deviceInstall(_, let appPath):
            do { try currentDevice?.install(appAt: URL(fileURLWithPath: appPath)) }
            catch { emitError(code: "install", message: error.localizedDescription) }
        case .deviceLaunch(_, let bundleId):
            do { _ = try currentDevice?.launch(bundleId: bundleId) }
            catch { emitError(code: "launch", message: error.localizedDescription) }
        case .axAction:
            break
        case .unknown:
            break
        }
    }

    private func broadcastDeviceList() {
        let devices = ctx.devices()
        send(.deviceListResponse(devices: devices))
    }

    private func startDevice(udid: String) async {
        if let current = currentDevice, current.udid != udid {
            await stopDevice(udid: current.udid)
        }

        guard let simDevice = ctx.device(udid: udid) else {
            emitError(code: "device.unknown", message: "No device with UDID \(udid)")
            return
        }
        let device = Device(simDevice: simDevice)
        currentDevice = device

        FileHandle.standardError.write(Data("[start] state=\(device.state)\n".utf8))
        if device.state == .booted {
            do {
                try wireDisplay(simDevice: simDevice)
                send(.deviceState(udid: udid, state: .booted, bootStatus: "Booted"))
                broadcastDeviceList()
            } catch {
                emitError(code: "boot", message: error.localizedDescription)
            }
            return
        }

        let monitor = BootMonitor(device: simDevice)
        let handler: @Sendable (BootStatus) -> Void = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                let state: DeviceState = status == .booted ? .booted : device.state
                self.send(.deviceState(udid: udid, state: state, bootStatus: status.label))
                if status == .booted {
                    self.finishBootIfNeeded(simDevice: simDevice, udid: udid)
                }
            }
        }
        monitor.start(onChange: handler)
        bootMonitor = monitor

        do {
            try await device.boot()
            if device.state == .booted {
                finishBootIfNeeded(simDevice: simDevice, udid: udid)
            }
        } catch {
            emitError(code: "boot", message: error.localizedDescription)
        }
    }

    private var postBootDone = false

    private func finishBootIfNeeded(simDevice: SimDevice, udid: String) {
        if postBootDone { return }
        postBootDone = true
        do {
            try wireDisplay(simDevice: simDevice)
            send(.deviceState(udid: udid, state: .booted, bootStatus: "Booted"))
            broadcastDeviceList()
        } catch {
            postBootDone = false
            emitError(code: "boot.wiring", message: error.localizedDescription)
        }
    }

    private func stopDevice(udid: String) async {
        let target: Device
        if let current = currentDevice, current.udid == udid {
            target = current
        } else if let simDevice = ctx.device(udid: udid) {
            target = Device(simDevice: simDevice)
        } else {
            emitError(code: "device.unknown", message: "No device with UDID \(udid)")
            return
        }
        bootMonitor?.stop(); bootMonitor = nil
        display?.detach(); display = nil
        hid = nil
        inspector = nil
        axInspector = nil
        bridge = nil
        do { try await target.shutdown() } catch {
            emitError(code: "shutdown", message: error.localizedDescription)
        }
        layerBridge.dispose()
        currentDevice = nil
        currentInfo = nil
        currentOrientation = 1
        postBootDone = false
        // contextId=0 tells the renderer to detach its CALayerHost.
        send(.displayReady(contextId: 0, pixelWidth: 0, pixelHeight: 0, scale: 1.0))
        send(.deviceState(udid: udid, state: .shutdown, bootStatus: nil))
        broadcastDeviceList()
    }

    private func wireDisplay(simDevice: SimDevice) throws {
        FileHandle.standardError.write(Data("[display] wireDisplay begin\n".utf8))
        display?.detach()
        display = nil
        let d = Display(device: simDevice)
        display = d
        try d.attach(
            onSurface: { [weak self] surface, info in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.currentInfo = info
                    self.layerBridge.update(surface: surface, info: info, orientation: self.currentOrientation)
                    FileHandle.standardError.write(Data("[display] surface contextId=\(self.layerBridge.contextId) px=\(info.pixelWidth)x\(info.pixelHeight) scale=\(info.scale) orientation=\(self.currentOrientation)\n".utf8))
                    self.emitDisplayReady(info: info)
                }
            },
            onDamage: { [weak self] in
                DispatchQueue.main.async { self?.layerBridge.invalidate() }
            }
        )
        wireAuxiliaryServices(simDevice: simDevice)
        FileHandle.standardError.write(Data("[display] wireDisplay attached\n".utf8))
    }

    /// Publish the displayed pixel dims to the renderer/native. The values
    /// must match `LayerBridge.applyGeometry`'s rootLayer extent — landscape
    /// for orientations 3/4, portrait for 1/2 — otherwise the native
    /// CALayerHost.bounds (taken from this payload) won't match the imported
    /// rootLayer.bounds and the content renders distorted or rotationally
    /// misaligned. The simulator framebuffer is always portrait pixels at
    /// the source, so we swap dims based on the active UIInterfaceOrientation
    /// rather than trusting `info.pixelWidth/Height`'s native order.
    private func emitDisplayReady(info: Display.Info) {
        let isLandscape = currentOrientation == 3 || currentOrientation == 4
        let longEdge = max(info.pixelWidth, info.pixelHeight)
        let shortEdge = min(info.pixelWidth, info.pixelHeight)
        let outW = isLandscape ? longEdge : shortEdge
        let outH = isLandscape ? shortEdge : longEdge
        send(.displayReady(
            contextId: layerBridge.contextId,
            pixelWidth: outW,
            pixelHeight: outH,
            scale: Double(info.scale)
        ))
    }

    private func wireAuxiliaryServices(simDevice: SimDevice) {
        // Nested autoreleasepool — XPC-backed proxies need to drain synchronously
        // inside the GCD block or SIGSEGV on `objc_autoreleasePoolPop` later.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            autoreleasepool {
                do {
                    let hid = try HIDClient(device: simDevice)
                    DispatchQueue.main.async { self?.hid = hid }
                } catch {
                    let msg = error.localizedDescription
                    DispatchQueue.main.async {
                        self?.emitError(code: "hid.unavailable", message: msg)
                    }
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            autoreleasepool {
                do {
                    let bridge = try Bridge(device: simDevice)
                    let inspector = Inspector(bridge: bridge)
                    inspector.enable()
                    DispatchQueue.main.async {
                        self?.bridge = bridge
                        self?.inspector = inspector
                    }
                } catch {
                    let desc = error.localizedDescription
                    FileHandle.standardError.write(
                        Data("[bridge] legacy SimulatorBridge init failed: \(desc) — trying AXPTranslator\n".utf8)
                    )
                    _ = self
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            autoreleasepool {
                let axi = AXInspector(device: simDevice)
                DispatchQueue.main.async {
                    self?.axInspector = axi
                    if axi != nil {
                        FileHandle.standardError.write(Data(
                            "[ax] AXPTranslator inspector ready\n".utf8))
                    }
                }
            }
        }
    }

    private func performTap(x: Double, y: Double, phase: PaneToBridge.TapPhase) {
        FileHandle.standardError.write(Data(
            "[hid] performTap x=\(x) y=\(y) phase=\(phase) hid=\(hid != nil) info=\(currentInfo.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "nil")\n".utf8
        ))
        guard let hid, let info = currentInfo else {
            FileHandle.standardError.write(Data("[hid] performTap dropped: hid/info missing\n".utf8))
            return
        }
        let pixelWidth = info.pixelWidth
        let pixelHeight = info.pixelHeight
        hidQueue.async { [weak self] in
            do {
                let op: IndigoBridge.TouchOp = phase == .down ? .down : .up
                let msg = try IndigoBridge.shared.makeTapMessage(x: x, y: y,
                                                                  pixelWidth: pixelWidth,
                                                                  pixelHeight: pixelHeight,
                                                                  op: op)
                try hid.send(messagePointer: msg)
                FileHandle.standardError.write(Data("[hid] performTap sent op=\(op)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("[hid] performTap ERROR: \(error)\n".utf8))
                let desc = error.localizedDescription
                DispatchQueue.main.async {
                    self?.emitError(code: "input.tap", message: desc)
                }
            }
        }
    }

    private func performDrag(points: [PaneToBridge.DragPoint]) {
        guard let hid, let info = currentInfo, !points.isEmpty else { return }
        let snapshot = points
        let w = info.pixelWidth
        let h = info.pixelHeight
        hidQueue.async {
            for (i, p) in snapshot.enumerated() {
                let op: IndigoBridge.TouchOp = (i == 0) ? .down : (i == snapshot.count - 1 ? .up : .down)
                if let msg = try? IndigoBridge.shared.makeTapMessage(x: p.x, y: p.y,
                                                                     pixelWidth: w,
                                                                     pixelHeight: h,
                                                                     op: op) {
                    try? hid.send(messagePointer: msg)
                }
                // Pace samples WITHIN a multi-point batch only. The trailing
                // sleep would otherwise pile up on the serial queue for
                // single-point drags (the common case from NSEvent .move) and
                // delay the final inputTap(up) by ~8 ms per in-flight sample.
                if i < snapshot.count - 1 {
                    usleep(8_000)
                }
            }
        }
    }

    private func performKey(usage: Int32, down: Bool) {
        guard let hid else { return }
        hidQueue.async { [weak self] in
            do {
                let msg = try IndigoBridge.shared.makeArbitraryKey(usage: usage, op: down ? .down : .up)
                try hid.send(messagePointer: msg)
            } catch {
                let desc = error.localizedDescription
                DispatchQueue.main.async {
                    self?.emitError(code: "input.key", message: desc)
                }
            }
        }
    }

    private func performRotate(orientation: Int) {
        guard let simDevice = currentDevice?.simDevice else {
            FileHandle.standardError.write(Data("[rotate] no booted device\n".utf8))
            return
        }
        let clamped = max(1, min(4, orientation))
        currentOrientation = clamped
        // Apply the layer-tree rotation immediately so the host-side bezel
        // and framebuffer stay in lockstep with the renderer's CSS bezel
        // rotation. Doing this BEFORE the GSEvent means the user sees the
        // chrome flip first, masking the ~2-frame stall while iOS itself
        // animates the in-app rotation.
        if let info = currentInfo {
            layerBridge.setOrientation(clamped, info: info)
            // Republish dims so native CALayerHost.bounds tracks the new
            // orientation. Without this, native keeps the previous-orientation
            // dims and the imported rootLayer (now landscape) renders against
            // a portrait host extent, distorting the content.
            emitDisplayReady(info: info)
        }
        let value = UInt32(clamped)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = T3SendOrientationEvent(simDevice, value)
            FileHandle.standardError.write(Data(
                "[rotate] orientation=\(value) ok=\(ok)\n".utf8
            ))
        }
    }

    private func performButton(kind: HardwareButton, down: Bool) {
        guard let hid else { return }
        hidQueue.async { [weak self] in
            do {
                let msg = try IndigoBridge.shared.makeButtonMessage(button: kind, op: down ? .down : .up)
                try hid.send(messagePointer: msg)
            } catch {
                let desc = error.localizedDescription
                DispatchQueue.main.async {
                    self?.emitError(code: "input.button", message: desc)
                }
            }
        }
    }

    private func emitHit(x: Double, y: Double, mode: PaneToBridge.AXHitMode) {
        let udid = currentDevice?.udid
        let axInspectorRef = axInspector
        let inspectorRef = inspector
        let displayRef = display
        let info = currentInfo

        let seq: UInt64
        if mode == .hover {
            lastHoverSeq &+= 1
            seq = lastHoverSeq
        } else {
            seq = 0
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            let appContext: SimAppInfo? = udid.flatMap { AppResolver.resolve(udid: $0) }
            let tApp = CFAbsoluteTimeGetCurrent()
            let hitX = Int(x.rounded())
            let hitY = Int(y.rounded())

            let plugin = Self.pluginChain(x: x, y: y, appContext: appContext)
            let tPlugin = CFAbsoluteTimeGetCurrent()
            let axChain = axInspectorRef.map { $0.hitTest(x: hitX, y: hitY) } ?? []
            let legacyChain: [AXElement] = axChain.isEmpty
                ? (inspectorRef?.hitTest(x: hitX, y: hitY) ?? [])
                : []
            var chain: [AXElement]
            var usedFallback: String
            if !plugin.isEmpty {
                chain = plugin
                usedFallback = !axChain.isEmpty ? "plugin+ax"
                    : !legacyChain.isEmpty ? "plugin+legacy" : "plugin"
            } else if !axChain.isEmpty {
                chain = axChain
                usedFallback = "ax"
            } else {
                chain = legacyChain
                usedFallback = "legacy"
            }
            let usedPlugin = !plugin.isEmpty
            let tHit = CFAbsoluteTimeGetCurrent()

            if Self.isUnhydratedChain(chain) {
                // Xcode 26.2 returned a chain with no attrs/frame and the
                // plugin isn't available (target app lacks the debug
                // `InspectableServer` or isn't Satira). Surface a terse
                // HitPoint marker so the UI still has something to draw —
                // no synthesis from pixels; the pane explains what's
                // actually missing.
                chain = [Self.syntheticHitPoint(x: x, y: y, appContext: appContext)]
            }

            _ = displayRef
            let normalized = Self.normalizeHitChain(
                chain,
                hitX: x,
                hitY: y,
                info: info,
                alreadyDisplayPoints: usedPlugin
            )
            let hinted: [AXElement]
            if mode == .select {
                let resolved = SourceResolver.resolve(chain: normalized, appContext: appContext)
                hinted = Self.attachSourceHints(resolved.hints, to: normalized)
            } else {
                hinted = normalized
            }
            let decorated = hinted.map { Self.withAppContext($0, appContext: appContext) }
            // Pure-geometry leaf pick: the element with the smallest non-stub
            // frame is what the human visually clicked on. Wrappers and stage
            // roots have larger areas and lose by definition. The plugin path
            // already returns the chain smallest-first (Satira's hit-test sorts
            // by area+z), so smallestUsableHit returns 0 there for free.
            let hitIndex = Self.smallestUsableHit(in: hinted)

            let tDone = CFAbsoluteTimeGetCurrent()
            let msApp = Int((tApp - t0) * 1000)
            let msPlugin = Int((tPlugin - tApp) * 1000)
            let msHit = Int((tHit - tPlugin) * 1000)
            let msRest = Int((tDone - tHit) * 1000)
            let msTotal = Int((tDone - t0) * 1000)
            FileHandle.standardError.write(Data(
                "[ax.hit] mode=\(mode) via=\(usedFallback) total=\(msTotal)ms (app=\(msApp) plugin=\(msPlugin) fallback=\(msHit) post=\(msRest)) chain=\(chain.count)\n".utf8
            ))

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if mode == .hover, seq != self.lastHoverSeq { return }
                self.send(.axHitResponse(chain: decorated, hitIndex: hitIndex, mode: mode))
            }
        }
    }

    nonisolated private static func withAppContext(
        _ element: AXElement, appContext: SimAppInfo?
    ) -> AXElement {
        AXElement(
            id: element.id,
            role: element.role,
            label: element.label,
            value: element.value,
            frame: element.frame,
            identifier: element.identifier,
            enabled: element.enabled,
            selected: element.selected,
            children: element.children,
            appContext: appContext,
            sourceHints: element.sourceHints
        )
    }

    nonisolated static func normalizeHitChain(
        _ chain: [AXElement],
        hitX: Double,
        hitY: Double,
        info: Display.Info?,
        alreadyDisplayPoints: Bool = false
    ) -> [AXElement] {
        if alreadyDisplayPoints { return chain }
        guard !chain.isEmpty, let info else { return chain }
        let scale = max(Double(info.scale), 1)
        let display = AXFrame(
            x: 0,
            y: 0,
            width: Double(info.pixelWidth) / scale,
            height: Double(info.pixelHeight) / scale
        )
        let divided = chain.map { divide($0, by: scale) }
        let localized = localize(chain)
        let dividedLocalized = localize(divided)
        let candidates = [chain, divided, localized, dividedLocalized]
        return candidates.max {
            hitChainScore($0, hitX: hitX, hitY: hitY, display: display) <
                hitChainScore($1, hitX: hitX, hitY: hitY, display: display)
        } ?? chain
    }

    nonisolated private static func localize(_ chain: [AXElement]) -> [AXElement] {
        guard let root = chain.last?.frame else { return chain }
        return chain.map { element in
            AXElement(
                id: element.id,
                role: element.role,
                label: element.label,
                value: element.value,
                frame: globalToLocal(element.frame, root: root),
                identifier: element.identifier,
                enabled: element.enabled,
                selected: element.selected,
                children: element.children,
                appContext: element.appContext,
                sourceHints: element.sourceHints
            )
        }
    }

    nonisolated private static func divide(_ element: AXElement, by scale: Double) -> AXElement {
        AXElement(
            id: element.id,
            role: element.role,
            label: element.label,
            value: element.value,
            frame: divide(element.frame, by: scale),
            identifier: element.identifier,
            enabled: element.enabled,
            selected: element.selected,
            children: element.children,
            appContext: element.appContext,
            sourceHints: element.sourceHints
        )
    }

    nonisolated private static func divide(_ frame: AXFrame, by scale: Double) -> AXFrame {
        guard scale.isFinite, scale > 0 else { return frame }
        return AXFrame(
            x: frame.x / scale,
            y: frame.y / scale,
            width: frame.width / scale,
            height: frame.height / scale
        )
    }

    nonisolated private static func globalToLocal(_ frame: AXFrame, root: AXFrame) -> AXFrame {
        AXFrame(
            x: frame.x - root.x,
            y: frame.y - root.y,
            width: frame.width,
            height: frame.height
        )
    }

    nonisolated private static func hitChainScore(
        _ chain: [AXElement],
        hitX: Double,
        hitY: Double,
        display: AXFrame
    ) -> Double {
        guard let leaf = chain.first, let root = chain.last else { return -.greatestFiniteMagnitude }
        var score = 0.0
        if contains(leaf.frame, x: hitX, y: hitY, padding: 1.5) {
            score += 80
        } else {
            score -= min(distanceToFrame(leaf.frame, x: hitX, y: hitY), 240) * 0.75
        }
        if contains(root.frame, x: hitX, y: hitY, padding: 12) {
            score += 10
        }
        score += frameFitScore(root.frame, display: display)
        for element in chain {
            if element.frame.width < 0 || element.frame.height < 0 {
                score -= 40
                continue
            }
            score += intersects(element.frame, display: display, padding: 24) ? 2 : -6
        }
        return score
    }

    nonisolated private static func attachSourceHints(
        _ hints: [AXSourceHint],
        to chain: [AXElement]
    ) -> [AXElement] {
        guard !hints.isEmpty, var leaf = chain.first else { return chain }
        if leaf.sourceHints != nil { return chain }
        leaf = AXElement(
            id: leaf.id,
            role: leaf.role,
            label: leaf.label,
            value: leaf.value,
            frame: leaf.frame,
            identifier: leaf.identifier,
            enabled: leaf.enabled,
            selected: leaf.selected,
            children: leaf.children,
            appContext: leaf.appContext,
            sourceHints: hints
        )
        return [leaf] + chain.dropFirst()
    }

    /// Smallest-area-first hit pick. The element with the smallest usable
    /// frame is the one the human's finger actually landed on; wrappers and
    /// stage roots have larger frames and cannot be the visual target.
    /// Identical algorithm to Satira-side `InspectableHitTest` so both code
    /// paths converge on the same answer.
    ///
    /// Falls back to the chain's leading element only when every entry is a
    /// 1×1 coordinate stub (the synthetic-hit-point degenerate case) — the
    /// chain is "as good as it gets" and there's nothing smaller to pick.
    nonisolated private static func smallestUsableHit(in chain: [AXElement]) -> Int {
        guard !chain.isEmpty else { return 0 }
        var bestIndex = 0
        var bestArea = Double.greatestFiniteMagnitude
        for (index, element) in chain.enumerated() {
            let frame = element.frame
            let width = max(0, frame.width)
            let height = max(0, frame.height)
            // Skip degenerate frames (zero, negative, or 1×1 stubs) — they
            // would always "win" by area but represent no visible target.
            guard width > 1, height > 1 else { continue }
            let area = width * height
            if area < bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }

    nonisolated private static func frameFitScore(_ frame: AXFrame, display: AXFrame) -> Double {
        let width = max(display.width, 1)
        let height = max(display.height, 1)
        let widthDelta = abs(frame.width - display.width) / width
        let heightDelta = abs(frame.height - display.height) / height
        let originXDelta = abs(frame.x) / width
        let originYDelta = abs(frame.y) / height
        return max(0, 1 - widthDelta) * 10 +
            max(0, 1 - heightDelta) * 10 +
            max(0, 1 - originXDelta) * 8 +
            max(0, 1 - originYDelta) * 8
    }

    nonisolated private static func contains(
        _ frame: AXFrame,
        x: Double,
        y: Double,
        padding: Double
    ) -> Bool {
        let minX = frame.x - padding
        let minY = frame.y - padding
        let maxX = frame.x + max(frame.width, 0) + padding
        let maxY = frame.y + max(frame.height, 0) + padding
        return x >= minX && x <= maxX && y >= minY && y <= maxY
    }

    nonisolated private static func distanceToFrame(_ frame: AXFrame, x: Double, y: Double) -> Double {
        let minX = frame.x
        let minY = frame.y
        let maxX = frame.x + max(frame.width, 0)
        let maxY = frame.y + max(frame.height, 0)
        let dx = x < minX ? minX - x : (x > maxX ? x - maxX : 0)
        let dy = y < minY ? minY - y : (y > maxY ? y - maxY : 0)
        return hypot(dx, dy)
    }

    nonisolated private static func intersects(
        _ frame: AXFrame,
        display: AXFrame,
        padding: Double
    ) -> Bool {
        let minX = display.x - padding
        let minY = display.y - padding
        let maxX = display.x + display.width + padding
        let maxY = display.y + display.height + padding
        return frame.x <= maxX &&
            frame.y <= maxY &&
            frame.x + max(frame.width, 0) >= minX &&
            frame.y + max(frame.height, 0) >= minY
    }

    nonisolated private static func hasUsableFrame(_ frame: AXFrame) -> Bool {
        frame.width > 2 && frame.height > 2
    }

    /// On Xcode 26.2 the remote AX runtime returns translation objects with
    /// empty attribute caches unless the target app was launched under
    /// VoiceOver. `T3AXBridge` then defaults the role to "AXUIElement" and
    /// the frame to zero — producing a chain that's technically present but
    /// carries no useful signal. Detect that state so we can replace the
    /// chain with something the UI can actually draw.
    nonisolated private static func isUnhydratedChain(_ chain: [AXElement]) -> Bool {
        guard !chain.isEmpty else { return false }
        return chain.allSatisfy { element in
            isGenericRole(element.role)
                && (element.label?.isEmpty ?? true)
                && (element.value?.isEmpty ?? true)
                && (element.identifier?.isEmpty ?? true)
                && !hasUsableFrame(element.frame)
        }
    }

    nonisolated private static func syntheticHitPoint(
        x: Double, y: Double, appContext: SimAppInfo?
    ) -> AXElement {
        let size: Double = 48
        let frame = AXFrame(
            x: x - size / 2,
            y: y - size / 2,
            width: size,
            height: size
        )
        return AXElement(
            id: "hitpoint:\(Int(x.rounded())),\(Int(y.rounded()))",
            role: "HitPoint",
            label: "Unverified source - tap at (\(Int(x.rounded())), \(Int(y.rounded())))",
            value: "No visible AX element could verify the app-provided source anchor.",
            frame: frame,
            identifier: nil,
            enabled: true,
            selected: false,
            children: nil,
            appContext: appContext
        )
    }

    nonisolated private static func pluginChain(
        x: Double, y: Double, appContext: SimAppInfo?
    ) -> [AXElement] {
        let nodes = PluginClient.hit(x: x, y: y)
        guard !nodes.isEmpty else { return [] }
        return nodes.map { node in
            axElement(from: node, appContext: appContext)
        }
    }

    nonisolated private static func pluginSnapshot(
        bounds: AXFrame?, appContext: SimAppInfo?
    ) -> [AXNode]? {
        guard let snapshot = PluginClient.tree(), !snapshot.nodes.isEmpty else {
            return nil
        }
        let rootId = "plugin-root"
        let rootFrame = bounds ?? AXFrame.zero
        let root = AXNode(
            id: rootId,
            parentId: nil,
            role: "Application",
            label: appContext?.name ?? appContext?.bundleId ?? "App",
            value: appContext?.bundleId,
            identifier: appContext?.bundleId,
            frame: rootFrame,
            enabled: true,
            selected: false
        )
        let children: [AXNode] = snapshot.nodes.map { node in
            AXNode(
                id: node.id,
                parentId: rootId,
                role: "Inspectable",
                label: node.alias,
                value: nil,
                identifier: axIdentifier(for: node),
                frame: node.frame,
                enabled: true,
                selected: false
            )
        }
        return [root] + children
    }

    nonisolated private static func axElement(
        from node: PluginClient.Node, appContext: SimAppInfo?
    ) -> AXElement {
        AXElement(
            id: node.id,
            role: "Inspectable",
            label: node.alias,
            value: nil,
            frame: node.frame,
            identifier: axIdentifier(for: node),
            enabled: true,
            selected: false,
            children: nil,
            appContext: appContext
        )
    }

    /// Build the wire-format identifier that `AXIdentifier.parse` expects.
    /// Format: `<fileID>:<line>[|name=<alias>]` — `fileID` already prefixes
    /// the module when the source file lives inside a package/module, so
    /// we just reconstruct the original `.inspectable()` stamp without
    /// double-encoding the module.
    nonisolated private static func axIdentifier(for node: PluginClient.Node) -> String {
        let prefix: String
        if let module = node.module, !module.isEmpty,
           !node.file.contains("/") {
            prefix = "\(module)/\(node.file)"
        } else {
            prefix = node.file
        }
        let base = "\(prefix):\(node.line)"
        if let alias = node.alias, !alias.isEmpty {
            return "\(base)|name=\(alias)"
        }
        return base
    }

    nonisolated private static func isGenericRole(_ role: String) -> Bool {
        let value = role.lowercased()
        return value == "axuielement" ||
            value == "axapplication" ||
            value == "application" ||
            value == "window" ||
            value == "unknown"
    }

    private func emitSnapshot() {
        let udid = currentDevice?.udid
        let axInspectorRef = axInspector
        let inspectorRef = inspector
        let info = currentInfo

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let appContext: SimAppInfo? = udid.flatMap { AppResolver.resolve(udid: $0) }
            if let root = appContext?.projectPath {
                SourceIndex.shared.ensureIndexed(root: root)
            }
            let bounds: AXFrame? = info.map {
                let scale = max(Double($0.scale), 1)
                return AXFrame(
                    x: 0, y: 0,
                    width: Double($0.pixelWidth) / scale,
                    height: Double($0.pixelHeight) / scale
                )
            }

            var nodes: [AXNode] = []
            // Same priority as `emitHit`: plugin → AX → empty. The pane
            // just draws whatever rects land here, so the ordering
            // decides which source of truth wins.
            if let pluginNodes = Self.pluginSnapshot(
                bounds: bounds, appContext: appContext
            ) {
                nodes = pluginNodes
            } else if let inspector = inspectorRef, let root = inspector.tree() {
                nodes = AXFullSnapshot.flatten(tree: root, displayBounds: bounds)
            } else if let axi = axInspectorRef, let root = axi.frontmost() {
                nodes = AXFullSnapshot.flatten(tree: root, displayBounds: bounds)
            }

            DispatchQueue.main.async { [weak self] in
                self?.send(.axSnapshotResponse(nodes: nodes, appContext: appContext))
            }
        }
    }

    private func emitTree() {
        if let axi = axInspector, let root = axi.frontmost() {
            send(.axTreeResponse(root: root))
            return
        }
        if let inspector, let root = inspector.tree() {
            send(.axTreeResponse(root: root))
            return
        }
        let appContext = currentDevice.flatMap { AppResolver.resolve(udid: $0.udid) }
        let stub = AXElement(
            id: "tree:root",
            role: "Application",
            label: appContext?.name ?? appContext?.bundleId ?? "Simulator",
            value: appContext?.bundleId,
            frame: .zero,
            identifier: appContext?.bundleId,
            enabled: true,
            selected: false,
            children: nil,
            appContext: appContext
        )
        send(.axTreeResponse(root: stub))
    }

    private func send(_ message: BridgeToPane) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        ws.broadcast(data: data)
    }

    private func emitError(code: String, message: String, detail: [String: String]? = nil) {
        send(.error(code: code, message: message, detail: detail))
    }
}
