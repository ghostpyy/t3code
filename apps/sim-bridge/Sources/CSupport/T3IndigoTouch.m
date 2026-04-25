#import "CSupport.h"
#import <SimulatorApp/Indigo.h>
#import <mach/mach_time.h>
#import <string.h>
#import <stdlib.h>

// Raw function signature for IndigoHIDMessageForMouseNSEvent, resolved at
// load-time from SimulatorKit via dlsym() on the Swift side. Signature
// inferred from disassembly:
//   IndigoMessage * _IndigoHIDMessageForMouseNSEvent(
//       CGPoint *p1,
//       CGPoint *p2,
//       int eventTarget,        // 0x32 for touch-screen
//       int eventType,          // 0x1 down / 0x2 up
//       bool hasOtherArg);
// Returns a calloc'd 192-byte (0xC0) IndigoMessage with mouse-event defaults.
typedef IndigoMessage * (*T3MouseNSEventFn)(CGPoint *, CGPoint * _Nullable,
                                             int, int, bool);

/*
 Why this helper exists
 ----------------------
 `IndigoHIDMessageForMouseNSEvent` produces a 192-byte (0xc0) message with
 `eventType=IndigoEventTypeButton` (0x1). The guest-side dispatcher
 `SimHIDVirtualServiceManager.serviceForIndigoHIDData:` routes on
 `payload.field1` (eventKind). For touches it expects:

   * message size  = sizeof(IndigoMessage) + sizeof(IndigoPayload) = 0x140
                     (0xb0 for the IndigoMessage header + 0x90 stride for
                     the duplicated payload trailer)
   * eventType     = 0x2 (IndigoEventTypeTouch)
   * innerSize     = sizeof(IndigoPayload) = 0x90 (144 bytes under
                     #pragma pack(push, 4); the Indigo.h inline comment
                     mis-states "always 0xa0" — fb-idb documents 0x90 and
                     runtime observation agrees)
   * payload.field1 = 0x0000000b (magic eventKind for digitizer touches)
   * payload duplicated at stride offset with touch.field1=1, touch.field2=2

 Passing a mouse-shaped (0xC0) message makes the dispatcher drop the event
 silently — which is exactly the bug we were hitting ("clicks reach the
 daemon, tap log fires, but the simulator never responds"). fb-idb solves
 this in +[FBSimulatorIndigoHID touchMessageWithPayload:]; we port it
 faithfully here so the touch pipeline actually triggers SpringBoard.

 We do the work in C instead of Swift because:
   1. We already ship a CSupport target that can include the private
      Indigo headers without polluting Swift.
   2. `calloc`/`memcpy` lets us do exact byte-level shaping without
      fighting Swift's UnsafeMutableRawPointer ergonomics.
 */
void * _Nullable T3BuildIndigoTouchMessage(const void * _Nullable mouseNSEventSym,
                                            double xRatio, double yRatio,
                                            int direction,
                                            size_t * _Nullable outSize) {
    if (!mouseNSEventSym) {
        return NULL;
    }

    T3MouseNSEventFn fn = (T3MouseNSEventFn)mouseNSEventSym;

    // Build the template to capture the per-event-type defaults the
    // framework normally writes (field3, field6..field18). We discard the
    // xRatio/yRatio it calculates and use ours because passing a pre-
    // normalized ratio avoids a scale/offset mismatch when Apple changes
    // the internal scaling later.
    CGPoint p = (CGPoint){ xRatio, yRatio };
    IndigoMessage *tmpl = fn(&p, NULL, 0x32, direction, false);
    if (!tmpl) {
        return NULL;
    }
    tmpl->payload.event.touch.xRatio = xRatio;
    tmpl->payload.event.touch.yRatio = yRatio;

    size_t messageSize = sizeof(IndigoMessage) + sizeof(IndigoPayload);
    size_t stride = sizeof(IndigoPayload);
    if (outSize) {
        *outSize = messageSize;
    }

    IndigoMessage *message = calloc(1, messageSize);
    if (!message) {
        free(tmpl);
        return NULL;
    }

    message->innerSize = (unsigned int)sizeof(IndigoPayload);
    message->eventType = IndigoEventTypeTouch;
    message->payload.field1 = 0x0000000b;
    message->payload.timestamp = mach_absolute_time();

    // IndigoEvent is a union; &event.button == &event.touch — we write
    // into the first member slot so the touch fields land at the right
    // offsets no matter which union tag we prefer in C.
    memcpy(&message->payload.event.button,
           &tmpl->payload.event.touch,
           sizeof(IndigoTouch));

    // Duplicate the payload at stride. The guest reads both copies to
    // reconstruct touch deltas; without the second copy the tap is seen
    // as "state machine out of sequence" and discarded.
    void *src = &message->payload;
    void *dst = (char *)src + stride;
    memcpy(dst, src, stride);

    IndigoPayload *second = (IndigoPayload *)dst;
    second->event.touch.field1 = 0x00000001;
    second->event.touch.field2 = 0x00000002;

    // The template was calloc'd by SimulatorKit; safe to free.
    free(tmpl);

    return message;
}
