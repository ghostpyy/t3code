#import "simview.h"
#import <objc/runtime.h>
#import <objc/message.h>

// CALayerHost is private QuartzCore. Declare interface; AppKit links it at runtime.
@interface CALayerHost : CALayer
@property (assign) uint32_t contextId;
@end

// Diagnostic logging for the touch pipeline. Every message goes to stderr
// with the `[simview]` prefix so the packaged app's desktop-main.log captures
// it. Move-event spam is rate-limited: only every 12th call actually logs.
static inline void T3SimLog(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char buf[512];
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    fprintf(stderr, "[simview] %s\n", buf);
    fflush(stderr);
}

@implementation T3SimView {
    CALayerHost *_layerHost;
    uint32_t _contextId;
    NSTrackingArea *_tracking;
    CGSize _sourcePixelSize;
    // Inner cornerRadius that matches the bezel SVG's screen-socket radius.
    // Applied to self.layer so CALayerHost gets clipped to rounded corners,
    // keeping the live screen flush with the titanium chassis cutout at the
    // four corners instead of square-cornering past the bezel arc.
    CGFloat _cornerRadius;
    // Outline layers rendered natively atop CALayerHost. Two layers: the
    // chain (dim, all ancestors) and the primary (bright, innermost hit).
    // Stored as source-pixel NSValues so they can be re-painted whenever
    // _sourcePixelSize changes without re-crossing the IPC boundary.
    CAShapeLayer *_chainOutline;
    CAShapeLayer *_primaryOutline;
    NSArray<NSValue *> *_outlinePixelRects;
    NSValue *_primaryPixelRect;
    // Rounded-rect radius of the innermost hit, already scaled into source-pixel
    // space. Travels from Satira's `resolvedCornerRadius()` (UIKit CALayer read)
    // through the outline IPC so the picker can paint a path that matches the
    // element's actual curvature instead of a flat rectangle.
    CGFloat _primaryCornerRadius;
    // Local-monitor-based input pipeline. Registered with NSEvent in init,
    // torn down in dealloc. This bypasses NSView hit-testing entirely so
    // clicks reach us even when Electron's WebContentsView tries to own the
    // hit-region. See `installEventMonitor` for full rationale.
    id _eventMonitor;
    // True while the left mouse button is down over our frame. Used by the
    // event monitor to continue tracking drags even if the pointer leaves the
    // simulator's rect during a gesture.
    BOOL _tracking_leftDown;
    // Debug counter for mouseMoved spam control.
    NSUInteger _moveLogTick;
    // Monotonic timestamp of the last ax-hover emit. We rate-limit hover
    // dispatch to ~60Hz because each event triggers a full native→main→WS→
    // daemon→AX→WS→main→renderer round-trip; without gating, rapid pointer
    // motion queues responses that land out of order, overwriting fresh state
    // with stale hits and causing the overlay to flicker or stick.
    CFTimeInterval _lastHoverEmitTime;
    // Tracks whether the pointer is currently inside the simulator's rect.
    // Required so we can emit a single "ax-hover-exit" on leave instead of
    // leaving the last hovered element pinned after the cursor moves off.
    BOOL _hoverInside;
}

- (instancetype)initWithContextId:(uint32_t)contextId {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layer = [CALayer layer];
    self.layer.masksToBounds = YES;
    // Keep the host layer clear so pixels from CALayerHost show through.
    self.layer.backgroundColor = NSColor.clearColor.CGColor;

    _contextId = contextId;
    _sourcePixelSize = CGSizeZero;
    _cornerRadius = 0.0;
    _primaryCornerRadius = 0.0;
    _tracking_leftDown = NO;
    _moveLogTick = 0;
    _lastHoverEmitTime = 0.0;
    _hoverInside = NO;

    // CALayerHost is private QuartzCore; AppKit links it at runtime. Using
    // KVC as a fallback means a missing `setContextId:` property (seen on
    // some macOS betas where the private class ships without the declared
    // property) still sets the ivar that drives rendering.
    Class layerHostClass = NSClassFromString(@"CALayerHost");
    if (layerHostClass) {
        _layerHost = [[layerHostClass alloc] init];
        if ([_layerHost respondsToSelector:@selector(setContextId:)]) {
            _layerHost.contextId = contextId;
        } else {
            [_layerHost setValue:@(contextId) forKey:@"contextId"];
        }
        _layerHost.anchorPoint = CGPointZero;
        _layerHost.position = CGPointZero;
        _layerHost.bounds = self.bounds;
        _layerHost.masksToBounds = NO;
        _layerHost.needsDisplayOnBoundsChange = YES;
        [self.layer addSublayer:_layerHost];
    }

    // Outlines sit as siblings of CALayerHost so they composite at CA
    // priority above the hosted simulator pixels. Because the DOM cannot
    // stack above a CALayerHost reliably on macOS (NSWindowAbove wins),
    // this is the only way to draw a highlight that's always visible.
    //
    // masksToBounds=YES on each outline layer is the primary clipper — it
    // intersects each stroked path with the layer's own rect (which we keep
    // locked to the screen rect in `applyLayerHostGeometry`). Without this,
    // shadows and 2px-centered strokes bleed past the bezel cutout and paint
    // on top of the titanium chassis SVG.
    // Two coplanar strokes on the SAME rounded path produce a soft halo + crisp
    // core without needing CALayer shadows (which get clipped by masksToBounds
    // and we can't drop masksToBounds without the stroke bleeding onto the
    // bezel SVG). The chain layer paints first (wider, translucent) so the
    // primary's bright edge sits on top of a mint glow.
    _chainOutline = [CAShapeLayer layer];
    _chainOutline.fillColor = NULL;
    _chainOutline.strokeColor = [[NSColor colorWithRed:0.56 green:1.0 blue:0.66 alpha:0.32] CGColor];
    _chainOutline.lineWidth = 5.0;
    _chainOutline.lineCap = kCALineCapRound;
    _chainOutline.lineJoin = kCALineJoinRound;
    _chainOutline.anchorPoint = CGPointZero;
    _chainOutline.position = CGPointZero;
    _chainOutline.masksToBounds = YES;
    _chainOutline.actions = @{@"path": [NSNull null]};
    [self.layer addSublayer:_chainOutline];

    _primaryOutline = [CAShapeLayer layer];
    _primaryOutline.fillColor = NULL;
    // Mint green, matches the web-side `.inspectable()` anchor colour.
    _primaryOutline.strokeColor = [[NSColor colorWithRed:0.64 green:1.0 blue:0.72 alpha:1.0] CGColor];
    _primaryOutline.lineWidth = 1.75;
    _primaryOutline.lineCap = kCALineCapRound;
    _primaryOutline.lineJoin = kCALineJoinRound;
    _primaryOutline.anchorPoint = CGPointZero;
    _primaryOutline.position = CGPointZero;
    _primaryOutline.masksToBounds = YES;
    _primaryOutline.actions = @{@"path": [NSNull null]};
    [self.layer addSublayer:_primaryOutline];

    _mode = @"input";
    T3SimLog("init ctx=%u", contextId);
    [self installEventMonitor];
    return self;
}

- (void)dealloc {
    if (_eventMonitor) {
        [NSEvent removeMonitor:_eventMonitor];
        _eventMonitor = nil;
    }
}

- (void)updateBounds:(NSRect)rect {
    self.frame = rect;
    [self applyLayerHostGeometry];
    [self applyCornerRadius];
    [self updateTrackingAreas];
    // A freshly-resized NSView sometimes ends up below sibling views added
    // later by Electron. Re-assert our z-order on every bounds change so
    // hit-testing keeps returning us for clicks inside the simulator.
    if (self.superview) {
        [self.superview addSubview:self positioned:NSWindowAbove relativeTo:nil];
    }
    T3SimLog("setBounds rect={%.2f,%.2f,%.2f,%.2f} r=%.2f window=%p superview=%p subview_count=%lu",
             rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
             _cornerRadius,
             (__bridge void *)self.window, (__bridge void *)self.superview,
             (unsigned long)self.superview.subviews.count);
}

- (void)updateCornerRadius:(CGFloat)radius {
    CGFloat clamped = MAX(0.0, radius);
    if (fabs(clamped - _cornerRadius) < 0.01) return;
    _cornerRadius = clamped;
    [self applyCornerRadius];
    // Outline layers mirror the screen's radius so their clip mask follows
    // the curved screen corner instead of a square-cornered bounding box.
    [self applyLayerHostGeometry];
}

// Apply the inner cornerRadius to self.layer. Clamp to half the smaller
// dimension so a radius larger than the frame never collapses the view —
// e.g. during the first bounds publish before React has laid out.
- (void)applyCornerRadius {
    if (!self.layer) return;
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat maxR = MIN(w, h) * 0.5;
    CGFloat r = (maxR > 0.0) ? MIN(_cornerRadius, maxR) : _cornerRadius;
    self.layer.cornerRadius = r;
    // Match CA behavior of the bezel SVG corner: continuous (squircle-ish)
    // rounding reads as one shape with the titanium chassis instead of the
    // cheaper quarter-circle arc.
    if (@available(macOS 11.0, *)) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

- (void)updateSourcePixelSize:(NSSize)size {
    _sourcePixelSize = size;
    [self applyLayerHostGeometry];
}

// CALayerHost imports the remote CAContext's root layer at its native pixel
// dimensions; applying `sublayerTransform` on the host would try to transform
// sublayers that never exist in this process. Instead, set CALayerHost.bounds
// to the source pixel size (so the imported content fills those bounds) and
// apply `transform` on CALayerHost itself to scale the whole layer down to
// the view's bounds. Anchor at (0,0) keeps the top-left fixed.
- (void)applyLayerHostGeometry {
    if (!_layerHost) return;
    CGFloat viewW = self.bounds.size.width;
    CGFloat viewH = self.bounds.size.height;
    if (viewW <= 0.0 || viewH <= 0.0) return;

    _layerHost.anchorPoint = CGPointZero;
    _layerHost.position = CGPointZero;

    if (_sourcePixelSize.width <= 0.0 || _sourcePixelSize.height <= 0.0) {
        // Source size not yet announced — fall back to 1:1.
        _layerHost.bounds = CGRectMake(0, 0, viewW, viewH);
        _layerHost.transform = CATransform3DIdentity;
        return;
    }

    _layerHost.bounds = CGRectMake(0, 0, _sourcePixelSize.width, _sourcePixelSize.height);
    CGFloat sx = viewW / _sourcePixelSize.width;
    CGFloat sy = viewH / _sourcePixelSize.height;
    _layerHost.transform = CATransform3DMakeScale(sx, sy, 1.0);

    // Mirror CALayerHost geometry on the outline layers so paths authored
    // in source-pixel space land pixel-perfect on the simulator content.
    // Inverse-scale the corner radius (which is in view-space points) so it
    // renders as the right CSS px after the layer's own scale transform.
    _chainOutline.bounds = _layerHost.bounds;
    _chainOutline.transform = _layerHost.transform;
    _primaryOutline.bounds = _layerHost.bounds;
    _primaryOutline.transform = _layerHost.transform;
    CGFloat avgScale = (sx + sy) * 0.5;
    CGFloat outlineCornerRadius = (avgScale > 0.0 && _cornerRadius > 0.0) ? (_cornerRadius / avgScale) : 0.0;
    _chainOutline.cornerRadius = outlineCornerRadius;
    _primaryOutline.cornerRadius = outlineCornerRadius;
    if (@available(macOS 11.0, *)) {
        _chainOutline.cornerCurve = kCACornerCurveContinuous;
        _primaryOutline.cornerCurve = kCACornerCurveContinuous;
    }
    [self rebuildOutlinePaths];
}

- (void)updateOutlines:(NSArray<NSDictionary *> *)chainRects scale:(CGFloat)scale {
    // Only the innermost hit paints. Ancestors are already enumerated as
    // numbered pills in the InspectCard — repainting them on the sim produced
    // overlapping clutter with no information gain.
    _outlinePixelRects = nil;
    _primaryPixelRect = nil;
    _primaryCornerRadius = 0.0;
    if (!chainRects || chainRects.count == 0) {
        [self rebuildOutlinePaths];
        return;
    }
    CGFloat s = (scale > 0.0 && isfinite(scale)) ? scale : 1.0;
    NSDictionary *first = chainRects.firstObject;
    if ([first isKindOfClass:[NSDictionary class]]) {
        CGFloat x = [first[@"x"] doubleValue] * s;
        CGFloat y = [first[@"y"] doubleValue] * s;
        CGFloat w = [first[@"width"] doubleValue] * s;
        CGFloat h = [first[@"height"] doubleValue] * s;
        CGFloat r = [first[@"cornerRadius"] doubleValue] * s;
        if (w > 0.0 && h > 0.0) {
            _primaryPixelRect = [NSValue valueWithRect:NSMakeRect(x, y, w, h)];
            _primaryCornerRadius = MAX(0.0, r);
        }
    }
    [self rebuildOutlinePaths];
}

// Rebuild the shape-layer paths in layer-local (source-pixel) space. CALayer
// uses a bottom-left origin; AX frames arrive in top-left (iOS/SwiftUI),
// hence the explicit Y-flip against _sourcePixelSize.height. Every rect is
// intersected with the screen rect — AX frames for full-width containers
// often extend fractionally past the pixel bounds, and without this clip
// the stroke bleeds onto the adjacent bezel SVG (masksToBounds catches the
// rest, but a pre-clip saves CA a tile-mask pass for the common case).
- (void)rebuildOutlinePaths {
    CGFloat pw = _sourcePixelSize.width;
    CGFloat ph = _sourcePixelSize.height;
    if (pw <= 0.0 || ph <= 0.0 || !_chainOutline || !_primaryOutline) return;
    CGRect screenRect = CGRectMake(0.0, 0.0, pw, ph);

    if (!_primaryPixelRect) {
        _chainOutline.path = NULL;
        _primaryOutline.path = NULL;
        return;
    }

    NSRect r = _primaryPixelRect.rectValue;
    CGRect flipped = CGRectMake(r.origin.x,
                                 ph - r.origin.y - r.size.height,
                                 r.size.width,
                                 r.size.height);
    CGRect clipped = CGRectIntersection(flipped, screenRect);
    if (CGRectIsNull(clipped) || CGRectIsEmpty(clipped)) {
        _chainOutline.path = NULL;
        _primaryOutline.path = NULL;
        return;
    }

    // The primary stroke is centered on the path; with lineWidth 1.75 that puts
    // ~0.875px outside the element rect. Insetting by half the stroke width
    // seats the visible edge of the primary exactly on the element's bounds.
    // The halo shares this path but at lineWidth 5 — its extra thickness paints
    // outward from the same centerline, producing a ~1.6px glow that bleeds
    // past the element edge without offsetting the bright core.
    CGFloat primaryInset = 0.875;
    CGRect primaryRect = CGRectInset(clipped, primaryInset, primaryInset);
    // Shrinking a rect by k means its inscribed radius also loses k; otherwise
    // the arc would read as a wider curve than the underlying UIKit layer.
    CGFloat primaryRadius = (_primaryCornerRadius > 0.0)
        ? MAX(0.0, _primaryCornerRadius - primaryInset)
        : 0.0;

    CGPathRef path = (primaryRadius > 0.0)
        ? CGPathCreateWithRoundedRect(primaryRect, primaryRadius, primaryRadius, NULL)
        : CGPathCreateWithRect(primaryRect, NULL);
    _chainOutline.path = path;
    _primaryOutline.path = path;
    CGPathRelease(path);
}

- (void)updateTrackingAreas {
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingMouseMoved |
                                                       NSTrackingActiveAlways |
                                                       NSTrackingInVisibleRect)
                                                owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

#pragma mark - Event monitor (bulletproof touch routing)

// Electron's WebContentsView on macOS registers a native NSView that lives
// inside the same contentView as T3SimView. In theory `addSubview:positioned:`
// plus `hitTest:` overrides are enough to route clicks. In practice, Chromium
// occasionally re-parents or re-orders its compositor view (e.g. after focus
// changes, window resizes, or IME interactions), and `acceptsFirstMouse:` does
// not cover trackpad-only secondary clicks. An NSEvent local monitor receives
// every mouse event at the NSApp dispatch level — BEFORE any view hit-testing
// — so we can forward events to the simulator unconditionally whenever the
// pointer is over our frame. Returning nil from the handler drops the event
// from the normal NSResponder chain so Chromium never sees the click.
- (void)installEventMonitor {
    NSEventMask mask = (NSEventMaskLeftMouseDown |
                        NSEventMaskLeftMouseUp |
                        NSEventMaskLeftMouseDragged |
                        NSEventMaskMouseMoved |
                        NSEventMaskScrollWheel |
                        NSEventMaskKeyDown |
                        NSEventMaskKeyUp);
    __weak __typeof(self) weakSelf = self;
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                          handler:^NSEvent * _Nullable (NSEvent *event) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return event;
        return [strongSelf handleMonitoredEvent:event];
    }];
    T3SimLog("event-monitor installed token=%p", (__bridge void *)_eventMonitor);
}

- (nullable NSEvent *)handleMonitoredEvent:(NSEvent *)event {
    // Only handle events for our own window.
    if (!self.window || event.window != self.window) return event;
    if (!self.superview) return event;
    if (self.isHidden) return event;

    NSEventType type = event.type;

    // Key events only when we own first responder.
    if (type == NSEventTypeKeyDown || type == NSEventTypeKeyUp) {
        if (self.window.firstResponder != self) return event;
        if (type == NSEventTypeKeyDown) {
            [self keyDown:event];
        } else {
            [self keyUp:event];
        }
        return nil;
    }

    // Project the event into our local (bottom-left) coordinate system.
    NSPoint winPoint = event.locationInWindow;
    NSPoint localPoint = [self convertPoint:winPoint fromView:nil];
    BOOL inside = NSPointInRect(localPoint, self.bounds);

    // Continue dragging even if the pointer temporarily leaves our rect.
    if (type == NSEventTypeLeftMouseDragged && _tracking_leftDown) {
        [self mouseDragged:event];
        return nil;
    }
    if (type == NSEventTypeLeftMouseUp && _tracking_leftDown) {
        _tracking_leftDown = NO;
        [self mouseUp:event];
        return nil;
    }

    if (!inside) return event;

    switch (type) {
        case NSEventTypeLeftMouseDown: {
            _tracking_leftDown = YES;
            if (self.window.firstResponder != self) {
                [self.window makeFirstResponder:self];
            }
            [self mouseDown:event];
            return nil;
        }
        case NSEventTypeLeftMouseUp: {
            _tracking_leftDown = NO;
            [self mouseUp:event];
            return nil;
        }
        case NSEventTypeLeftMouseDragged: {
            [self mouseDragged:event];
            return nil;
        }
        case NSEventTypeMouseMoved: {
            // Only forward moves in inspect mode to limit bridge chatter.
            if ([self.mode isEqualToString:@"inspect"]) {
                [self mouseMoved:event];
                return nil;
            }
            return event;
        }
        case NSEventTypeScrollWheel: {
            [self scrollWheel:event];
            return nil;
        }
        default:
            return event;
    }
}

// Always return self for any point inside bounds. Kept as belt-and-braces in
// case the local monitor is ever disabled or misses an edge case; the monitor
// is the primary routing mechanism.
- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if (!NSPointInRect(local, self.bounds)) return nil;
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (NSPoint)devicePointFromEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat x = p.x;
    CGFloat y = self.bounds.size.height - p.y;  // flip to top-left origin
    return NSMakePoint(x, y);
}

- (void)mouseDown:(NSEvent *)event {
    // Claim keyboard focus so subsequent keyDown events route to us.
    if (self.window && self.window.firstResponder != self) {
        [self.window makeFirstResponder:self];
    }
    NSPoint p = [self devicePointFromEvent:event];
    T3SimLog("down pt=(%.1f,%.1f) bounds=(%.1fx%.1f) mode=%s onEvent=%d",
             p.x, p.y, self.bounds.size.width, self.bounds.size.height,
             self.mode.UTF8String ?: "(null)", self.onEvent ? 1 : 0);
    if (self.onEvent) self.onEvent(@{@"kind": [self.mode isEqualToString:@"inspect"] ? @"ax-hit" : @"down",
                                      @"x": @(p.x), @"y": @(p.y)});
}

- (void)mouseDragged:(NSEvent *)event {
    if ([self.mode isEqualToString:@"inspect"]) return;
    NSPoint p = [self devicePointFromEvent:event];
    if ((_moveLogTick++ % 12) == 0) {
        T3SimLog("drag pt=(%.1f,%.1f)", p.x, p.y);
    }
    if (self.onEvent) self.onEvent(@{@"kind": @"move", @"x": @(p.x), @"y": @(p.y)});
}

- (void)mouseUp:(NSEvent *)event {
    if ([self.mode isEqualToString:@"inspect"]) return;
    NSPoint p = [self devicePointFromEvent:event];
    T3SimLog("up pt=(%.1f,%.1f)", p.x, p.y);
    if (self.onEvent) self.onEvent(@{@"kind": @"up", @"x": @(p.x), @"y": @(p.y)});
}

- (void)mouseMoved:(NSEvent *)event {
    if (![self.mode isEqualToString:@"inspect"]) return;
    // Gate at ~60Hz. Hover dispatch is expensive (round-trip through the
    // Swift daemon's AX hit-test) and rapid motion queues responses that can
    // land out of order. One sample per frame keeps the overlay responsive
    // without swamping the bridge.
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastHoverEmitTime < 0.016) return;
    _lastHoverEmitTime = now;
    _hoverInside = YES;
    NSPoint p = [self devicePointFromEvent:event];
    if (self.onEvent) self.onEvent(@{@"kind": @"ax-hover", @"x": @(p.x), @"y": @(p.y)});
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (!_hoverInside) return;
    _hoverInside = NO;
    // Emit a synthetic "ax-hover-exit" so the renderer can clear its stale
    // hoveredHit state. Without this, the last hovered element stays pinned
    // under the cursor's last-known position even after the pointer leaves
    // the simulator rect.
    if (self.onEvent) self.onEvent(@{@"kind": @"ax-hover-exit"});
}

- (void)scrollWheel:(NSEvent *)event {
    // Translate trackpad scrolls into synthetic drag points so users can
    // scroll UIScrollViews, tableViews, etc. inside the simulator.
    if ([self.mode isEqualToString:@"inspect"]) return;
    NSPoint p = [self devicePointFromEvent:event];
    CGFloat dx = event.scrollingDeltaX;
    CGFloat dy = event.scrollingDeltaY;
    if (fabs(dx) < 0.1 && fabs(dy) < 0.1) return;
    NSPoint to = NSMakePoint(p.x + dx, p.y - dy);
    if (self.onEvent) self.onEvent(@{@"kind": @"down", @"x": @(p.x), @"y": @(p.y)});
    if (self.onEvent) self.onEvent(@{@"kind": @"move", @"x": @(to.x), @"y": @(to.y)});
    if (self.onEvent) self.onEvent(@{@"kind": @"up", @"x": @(to.x), @"y": @(to.y)});
}

- (void)keyDown:(NSEvent *)event {
    if (self.onEvent) self.onEvent(@{@"kind": @"key-down",
                                      @"usage": @(event.keyCode),
                                      @"modifiers": @(event.modifierFlags),
                                      @"chars": event.charactersIgnoringModifiers ?: @""});
}

- (void)keyUp:(NSEvent *)event {
    if (self.onEvent) self.onEvent(@{@"kind": @"key-up",
                                      @"usage": @(event.keyCode),
                                      @"modifiers": @(event.modifierFlags)});
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)isFlipped { return NO; }
@end
