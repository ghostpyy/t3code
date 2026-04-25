#ifndef T3_C_SUPPORT_H
#define T3_C_SUPPORT_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Direct objc_msgSend wrapper for `registerCallbackWithUUID:<kind>Callback:`
/// selectors. Swift's `NSObject.perform(_:with:with:)` boxes `Any` args via
/// `_SwiftValue`, which breaks ObjC block pointers — the receiver sees an
/// opaque wrapper, never fires the block. Going through `objc_msgSend`
/// directly preserves the block identity so ARC/block-copy works on the
/// receiver. ROCKRemoteProxy forwards through `forwardInvocation:`, so the
/// call is still correctly routed across the RPC channel.
void T3MsgSendRegisterCallback(id target, SEL selector, NSUUID *uuid, id block);
void T3MsgSendUnregisterCallback(id target, SEL selector, NSUUID *uuid);

void T3MsgSendAttach(id io, SEL selector, id consumer, id port);
void T3MsgSendDetach(id io, SEL selector, id consumer, id port);

/// `-[SimScreenAdapter registerScreenAdapterCallbacksWithUUID:callbackQueue:screenConnectedCallback:screenWillDisconnectCallback:]`
void T3MsgSendRegisterScreenAdapter(id target, SEL selector, NSUUID *uuid,
                                     dispatch_queue_t queue,
                                     id connectedBlock,
                                     id disconnectedBlock);

/// `-[SimScreenAdapter enumerateScreensWithCompletionQueue:completionHandler:]`
void T3MsgSendEnumerateScreens(id target, SEL selector,
                                dispatch_queue_t queue,
                                id completionHandler);

/// `-[<screen> registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:]`
void T3MsgSendRegisterScreen(id target, SEL selector, NSUUID *uuid,
                              dispatch_queue_t queue,
                              id frameBlock,
                              id surfacesChangedBlock,
                              id propertiesChangedBlock);

/// Safe wrapper around `-[NSConnection rootProxy]`. On Xcode 26+, multiple
/// Mach names resolve via `-[SimDevice lookup:error:]`, but only the legacy
/// `SimulatorBridge` helper speaks the Distributed Objects wire protocol.
/// XPC-only endpoints (e.g. `com.apple.CoreSimulator.host_support`) accept
/// the send-port fine but never reply to DO, so `-rootProxy` blocks until
/// the connection's `replyTimeout` fires `NSPortTimeoutException`. Swift
/// can't bridge that to a Swift error, so the exception unwinds past us
/// and calls `abort()` via `libc++abi`. Wrap it in @try/@catch so we can
/// return nil and keep the sim-bridge daemon alive to serve display +
/// HID, even when AX is unavailable.
_Nullable id T3SafeRootProxy(id nsConnection);

/// Build a properly-shaped 320-byte (0x140) Indigo *touch* message for the
/// simulator's digitizer HID service. The raw `IndigoHIDMessageForMouseNSEvent`
/// helper returns a 192-byte MOUSE/pointer message with `eventType=0x1` that
/// the guest-side `SimHIDVirtualServiceManager` ignores unless a pointer
/// service is registered first. For touches we need a different shape:
///   * size = sizeof(IndigoMessage) + sizeof(IndigoPayload) = 0x140 bytes
///   * eventType = IndigoEventTypeTouch (0x2)
///   * payload.field1 (eventKind) = 0x0000000b
///   * payload duplicated at stride offset with touch.field1=0x1, field2=0x2
/// Matches fb-idb's `+[FBSimulatorIndigoHID touchMessageWithPayload:]` and
/// is what drives taps in `xcrun simctl io` and Simulator.app itself. The
/// base IndigoTouch defaults (field3, field6-18) come from invoking
/// `IndigoHIDMessageForMouseNSEvent` internally to produce a template with
/// the same per-event-type scaffolding the framework normally provides.
///
/// `mouseNSEventSym` is a pointer to the dlsym'd
/// `IndigoHIDMessageForMouseNSEvent` function. We pass it in from Swift to
/// avoid re-resolving SimulatorKit's symbol on every tap.
///
/// `direction` is `1` for press / `2` for release (IndigoEventTypeDown/Up).
/// Output `outSize` receives the allocated buffer size (0x140). The
/// returned buffer is malloc'd; callers pass it to
/// `-[SimDeviceLegacyClient sendWithMessage:freeWhenDone:...]` with
/// `freeWhenDone=YES` to transfer ownership.
void * _Nullable T3BuildIndigoTouchMessage(const void * _Nullable mouseNSEventSym,
                                            double xRatio, double yRatio,
                                            int direction,
                                            size_t * _Nullable outSize);

/// Configure `+[AXPTranslator sharediOSInstance]` with a bridge delegate
/// that proxies requests to `simDevice` via `-sendAccessibilityRequestAsync:`.
/// Returns `YES` on success. After a successful call, `T3AXBridgeHitTest`
/// / `T3AXBridgeFrontmost` can be called from any queue.
BOOL T3AXBridgeSetup(id simDevice);

/// Hit-test the booted simulator's accessibility hierarchy at the given
/// device-CSS-point. Returns a chain where index 0 is the leaf (the actual
/// element under the point) and the last entry is the app root. Each entry
/// is an NSDictionary with keys: `id`, `role`, `label`, `value`, `title`,
/// `identifier`, `frame` (as [x,y,w,h] NSNumbers), `enabled`, `selected`,
/// `pid`. Returns nil on failure.
NSArray<NSDictionary *> * _Nullable T3AXBridgeHitTest(double x, double y, uint32_t displayId);

/// Fetch the frontmost app's root accessibility element. Same shape as an
/// entry in `T3AXBridgeHitTest` output.
NSDictionary * _Nullable T3AXBridgeFrontmost(uint32_t displayId);

/// Whether the translator was successfully set up.
BOOL T3AXBridgeAvailable(void);

/// Resolve the frontmost simulator-side application's process identifier for
/// the given display. Works on Xcode 26.2 even when attribute round-trips
/// return empty, because the AXPTranslationObject carries the pid directly.
/// Returns `0` if no app is in the foreground (e.g. SpringBoard transitions
/// without a bound application process).
int32_t T3AXForegroundAppPID(uint32_t displayId);

/// Send a `GSEventTypeDeviceOrientationChanged` mach message to the booted
/// simulator's `PurpleWorkspacePort` so the guest rotates the front app.
/// Replaces `-[SimulatorBridge setDeviceOrientation:]`, which is gone on
/// Xcode 26+ (the legacy DO helper no longer ships). `orientation` is the
/// `UIDeviceOrientation` enum: 1=portrait, 2=portraitUpsideDown,
/// 3=landscapeRight, 4=landscapeLeft. Returns `YES` if `mach_msg_send`
/// reported KERN_SUCCESS; `NO` if the port couldn't be looked up or the
/// send failed (sim not booted, port revoked, etc).
BOOL T3SendOrientationEvent(id simDevice, uint32_t orientation);

NS_ASSUME_NONNULL_END

#endif
