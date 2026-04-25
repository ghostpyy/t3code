import Foundation
import ObjectiveC.runtime
import AppKit
import QuartzCore
import IOSurface

/// Publishes the simulator's IOSurface into a CAContext whose contextId can be
/// sent to another process that will instantiate a CALayerHost bound to it.
///
/// Core Animation's public `setNeedsDisplay()` is a no-op for layers whose
/// `contents` is already an IOSurface — it only schedules a redraw for
/// delegate-drawn layers. Cross-process, the render server keeps whatever
/// texture it sampled the first time it composited the exported tree. To
/// force a re-sample on every guest frame commit we must send the private
/// `setContentsChanged` selector; this is the same trick WebKit and
/// Chromium use for their IOSurface-backed remote layers. Without it the
/// pane paints the first frame, then freezes.
@MainActor
public final class LayerBridge {
    public private(set) var contextId: UInt32 = 0
    private var caContext: CAContext?
    // Root layer owns the exported tree; surfaceLayer hosts the IOSurface.
    // CAContext's `.layer` property expects a container root — WebKit's
    // `LayerHostingContext` keeps a CALayer "layerForContext" and parents
    // content layers under it. Setting a sublayer's contents to an IOSurface
    // and exporting THAT as root works locally but some macOS versions
    // silently fail to forward contents for a pure leaf root; the
    // container+sublayer pattern matches WebKit/Chromium and is what
    // consistently renders.
    private let rootLayer: CALayer
    private let surfaceLayer: CALayer

    /// Cached private selector. Looked up once; re-used on every damage
    /// tick. `Selector(("…"))` bypasses Swift's public-API allow-list so
    /// the private `-[CALayer setContentsChanged]` method is reachable.
    private static let contentsChangedSel = Selector(("setContentsChanged"))

    public init() {
        let root = CALayer()
        root.anchorPoint = .zero
        root.position = .zero
        root.isOpaque = true
        root.masksToBounds = false

        let surface = CALayer()
        surface.anchorPoint = .zero
        surface.position = .zero
        surface.contentsGravity = .resize
        surface.magnificationFilter = .nearest
        // Chromium's "IOSurface → CAContext → CALayerHost" recipe for macOS:
        //  - geometryFlipped = YES  → IOSurface is top-origin; render server
        //                             would otherwise composite upside-down.
        //  - isOpaque = YES         → render server skips the alpha-blend
        //                             pass; without this, cross-process
        //                             composite can cross-fade to the
        //                             underlying window background.
        //  - actions[contents]=null → disable the implicit fade animation
        //                             every `layer.contents =` assignment
        //                             triggers. Without this, rapid frames
        //                             visually cross-fade through "black"
        //                             (the empty transition backdrop).
        //  - contentsFormat=RGBA8   → on P3 / extended-range displays, the
        //                             default contentsFormat triggers
        //                             double colour-space conversion that
        //                             darkens the image toward black.
        surface.isGeometryFlipped = true
        surface.isOpaque = true
        surface.actions = ["contents": NSNull()]
        surface.needsDisplayOnBoundsChange = false
        surface.contentsFormat = .RGBA8Uint
        root.addSublayer(surface)

        self.rootLayer = root
        self.surfaceLayer = surface
    }

    public func update(surface: IOSurfaceRef, info: Display.Info, orientation: Int = 1) {
        // All CoreAnimation state mutations must land inside an explicit
        // transaction so the render server sees them as a single commit.
        // CATransaction.flush() drains existing transactions but doesn't
        // wrap our assignments — without begin/commit, some mutations get
        // queued onto a "pending" transaction the framework may coalesce
        // weirdly across the CAContext export boundary.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        applyGeometry(info: info, orientation: orientation)
        surfaceLayer.contents = surface
        // Force the render server to re-bind to the new IOSurface identity.
        // Assigning `contents` alone is not enough cross-process; some paths
        // cache the previous surface's locked state and keep displaying it
        // until an explicit `setContentsChanged` nudge.
        surfaceLayer.perform(LayerBridge.contentsChangedSel)

        if caContext == nil {
            // macOS uses `+contextWithCGSConnection:options:` with the caller's
            // main CGS connection (Chromium/WebKit pattern). WebKit additionally
            // passes `kCAContextCIFilterBehavior: @"ignore"` on the CGS path —
            // the default triggers CoreImage filter pipelines that aren't
            // wired up in a headless accessory daemon, which on some macOS
            // builds causes the exported tree to render empty cross-process.
            let options: NSDictionary = ["kCAContextCIFilterBehavior": "ignore"]
            caContext = CAContext(cgsConnection: CGSMainConnectionID(), options: options)
            caContext?.layer = rootLayer
            contextId = caContext?.contextId ?? 0
        }

        CATransaction.commit()
        // Flush queues the commit to the render server immediately so the
        // consumer's CALayerHost picks up contents on the very next display
        // pass rather than one runloop tick later.
        CATransaction.flush()
    }

    /// Apply a new orientation without re-binding the IOSurface. Called from
    /// the rotate path: the framebuffer service keeps the same surface
    /// identity (iOS just re-renders into native portrait pixels at a
    /// different angle), so we only need to swap the root extent and
    /// re-rotate the surface layer.
    public func setOrientation(_ orientation: Int, info: Display.Info) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyGeometry(info: info, orientation: orientation)
        surfaceLayer.perform(LayerBridge.contentsChangedSel)
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Called on every simulator frame commit (damage rect / frame event).
    /// Pixels changed but the IOSurface identity is the same, so we must
    /// nudge the render server directly via the private
    /// `-[CALayer setContentsChanged]` selector. `setNeedsDisplay()` is a
    /// no-op for layers whose `contents` is set to an IOSurface — it only
    /// schedules `drawInContext:` on delegate-drawn layers. Without this
    /// call the pane paints the first frame and freezes.
    public func invalidate() {
        surfaceLayer.perform(LayerBridge.contentsChangedSel)
    }

    /// Single source of truth for the rotated layer tree geometry.
    ///
    /// We can't assume a fixed buffer aspect: depending on the simulator
    /// runtime, the framebuffer service either keeps publishing native
    /// portrait pixels and lets the host rotate, or republishes the
    /// IOSurface with rotated dims after iOS catches up to the GSEvent.
    /// We handle both by deciding rotation per-call from the buffer's
    /// current aspect vs. the desired display orientation:
    ///
    ///   * `aspectMismatch` (portrait buffer + landscape display, or
    ///     vice versa): bridge with a ±π/2 rotation so the buffer
    ///     fills the rotated root.
    ///   * matched aspect + portraitUpsideDown: still need π so the
    ///     content lands the right way up.
    ///   * otherwise: identity, the buffer is already laid out for the
    ///     screen we're presenting.
    ///
    /// Without this, a republish in landscape dims hits a swap path
    /// that double-rotates the already-rotated content (visible as a
    /// 180° flip when the renderer's CSS bezel is also rotating CW).
    private func applyGeometry(info: Display.Info, orientation: Int) {
        let bufferWidth = CGFloat(info.pixelWidth)
        let bufferHeight = CGFloat(info.pixelHeight)
        let bufferIsLandscape = bufferWidth > bufferHeight
        let displayIsLandscape = orientation == 3 || orientation == 4

        let longEdge = max(bufferWidth, bufferHeight)
        let shortEdge = min(bufferWidth, bufferHeight)
        let displayWidth = displayIsLandscape ? longEdge : shortEdge
        let displayHeight = displayIsLandscape ? shortEdge : longEdge

        let aspectMismatch = bufferIsLandscape != displayIsLandscape
        let radians: CGFloat
        if aspectMismatch {
            radians = LayerBridge.rotationRadians(for: orientation)
        } else if orientation == 2 {
            radians = .pi
        } else {
            radians = 0
        }

        rootLayer.bounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        rootLayer.contentsScale = info.scale

        surfaceLayer.bounds = CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight)
        surfaceLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        surfaceLayer.position = CGPoint(x: displayWidth / 2, y: displayHeight / 2)
        surfaceLayer.contentsScale = info.scale
        surfaceLayer.transform = CATransform3DMakeRotation(radians, 0, 0, 1)

        let degrees = Int((radians * 180 / .pi).rounded())
        FileHandle.standardError.write(Data(
            "[geom] buf=\(Int(bufferWidth))x\(Int(bufferHeight)) ori=\(orientation) display=\(Int(displayWidth))x\(Int(displayHeight)) aspectMismatch=\(aspectMismatch) rot=\(degrees)°\n".utf8
        ))
    }

    public func dispose() {
        caContext?.layer = nil
        caContext = nil
        surfaceLayer.contents = nil
        contextId = 0
    }

    /// UIDeviceOrientation → CoreAnimation Z-axis rotation.
    ///
    /// Conventions:
    ///  - The IOSurface arrives in native portrait pixels (Dynamic Island at
    ///    portrait TOP, home indicator at portrait BOTTOM). The simulator does
    ///    NOT rotate the buffer when the device rotates — it keeps publishing
    ///    portrait pixels and expects the host to rotate them.
    ///  - `surface.isGeometryFlipped = true` flips the layer's local Y axis,
    ///    so a positive Z rotation is CW *visually* (not CCW as in standard
    ///    math). The signs below are the visual/CW direction the surface must
    ///    rotate so its portrait TOP edge lands at the user-perceived TOP of
    ///    the rotated extent.
    ///
    /// Mapping (UIInterfaceOrientation semantics — what the renderer's CSS
    /// uses for its bezel rotate(): orientation 3 = landscapeRight = status
    /// bar on screen RIGHT, orientation 4 = landscapeLeft = status bar on
    /// screen LEFT):
    ///   1 portrait                →  0
    ///   2 portraitUpsideDown      →  π
    ///   3 landscapeRight          → +π/2  (CW visually: TOP → RIGHT)
    ///   4 landscapeLeft           → -π/2  (CCW visually: TOP → LEFT)
    private static func rotationRadians(for orientation: Int) -> CGFloat {
        switch orientation {
        case 2: return .pi
        case 3: return .pi / 2
        case 4: return -.pi / 2
        default: return 0
        }
    }
}

// MARK: - SPI bridge

@_silgen_name("CGSMainConnectionID")
private func _CGSMainConnectionID() -> UInt32
public func CGSMainConnectionID() -> UInt32 { _CGSMainConnectionID() }

private let _CAContextClass: AnyClass? = NSClassFromString("CAContext")

/// Thin Swift shim around the private `CAContext` class from QuartzCore. We
/// construct it via `+contextWithCGSConnection:options:` — the macOS factory
/// that produces a contextId importable by `CALayerHost` in any other process
/// on the same login session. The iOS `+remoteContextWithOptions:` path is
/// NOT equivalent on macOS despite its superficially similar signature.
public final class CAContext: NSObject {
    private let bridged: NSObject?

    public init(cgsConnection: UInt32, options: NSDictionary) {
        guard let cls = _CAContextClass else {
            self.bridged = nil
            super.init()
            return
        }
        let sel = NSSelectorFromString("contextWithCGSConnection:options:")
        guard let method = class_getClassMethod(cls, sel) else {
            self.bridged = nil
            super.init()
            return
        }
        // `+contextWithCGSConnection:options:` returns +0 autoreleased. When
        // dispatched via `@convention(c)` IMP cast, ARC cannot tag the return
        // as autoreleased — a raw `NSObject?` return is over-released when
        // the pool drains. Unmanaged + takeUnretainedValue retains explicitly
        // so Swift's deinit balances the pool.
        typealias MakeIMP = @convention(c) (AnyClass, Selector, UInt32, NSDictionary) -> Unmanaged<NSObject>?
        let fn = unsafeBitCast(method_getImplementation(method), to: MakeIMP.self)
        self.bridged = fn(cls, sel, cgsConnection, options)?.takeUnretainedValue()
        super.init()
    }

    public var contextId: UInt32 {
        guard let bridged else { return 0 }
        if let n = bridged.value(forKey: "contextId") as? NSNumber {
            return n.uint32Value
        }
        return 0
    }

    public var layer: CALayer? {
        get { bridged?.value(forKey: "layer") as? CALayer }
        set { bridged?.setValue(newValue, forKey: "layer") }
    }
}
