#import "CSupport.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <SimulatorApp/GSEvent.h>

// PurpleWorkspacePort GSEvent transport. The legacy SimulatorBridge DO
// helper (`-[SimulatorBridge setDeviceOrientation:]`) is gone on Xcode 26+,
// so device-rotation has no Distributed-Objects path. Instead we replicate
// what Simulator.app's `-[SimDevice(GSEventsPrivate) sendPurpleEvent:]` does
// at the wire level: look up `PurpleWorkspacePort` via SimDevice, build the
// 108-byte GSEvent mach message documented in PrivateHeaders/SimulatorApp/
// GSEvent.h, and hand it to mach_msg_send. Guest-side
// GraphicsServices._PurpleEventCallback delivers it to backboardd, which
// rotates the front app the same way a real device tilt would.
//
// Wrapped in @try/@catch because `-lookup:error:` reaches into CoreSimulator
// internals via objc_msgSend; an unexpected NSException must not unwind past
// Swift (we'd lose the daemon).

static uint32_t T3LookupPort(id simDevice, NSString *name, NSError **outError) {
    SEL sel = NSSelectorFromString(@"lookup:error:");
    if (![simDevice respondsToSelector:sel]) return 0;
    Method method = class_getInstanceMethod([simDevice class], sel);
    if (!method) return 0;
    typedef uint32_t (*LookupIMP)(id, SEL, NSString *, NSError * __autoreleasing *);
    LookupIMP fn = (LookupIMP)method_getImplementation(method);
    return fn(simDevice, sel, name, outError);
}

BOOL T3SendOrientationEvent(id simDevice, uint32_t orientation) {
    if (simDevice == nil) return NO;

    NSError *err = nil;
    mach_port_t port = MACH_PORT_NULL;
    @try {
        port = T3LookupPort(simDevice, @"PurpleWorkspacePort", &err);
    } @catch (NSException *ex) {
        fputs("[gsevent] lookup PurpleWorkspacePort threw\n", stderr);
        return NO;
    }
    if (port == MACH_PORT_NULL) {
        if (err) {
            fprintf(stderr, "[gsevent] PurpleWorkspacePort lookup failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
        } else {
            fputs("[gsevent] PurpleWorkspacePort unavailable\n", stderr);
        }
        return NO;
    }

    // 108-byte (0x6C) layout — see PrivateHeaders/SimulatorApp/GSEvent.h.
    #define T3_ORIENTATION_MSG_SIZE 108
    uint8_t buf[T3_ORIENTATION_MSG_SIZE] = {0};

    // mach header
    *(uint32_t *)(buf + 0x00) = 0x13;             // MACH_MSG_TYPE_COPY_SEND
    *(uint32_t *)(buf + 0x04) = (uint32_t)T3_ORIENTATION_MSG_SIZE;
    *(uint32_t *)(buf + 0x08) = port;             // remote
    *(uint32_t *)(buf + 0x0C) = 0;                // local
    *(uint32_t *)(buf + 0x10) = 0;                // voucher
    *(int32_t  *)(buf + 0x14) = GSEventMachMessageID;

    // GSEvent body
    *(uint32_t *)(buf + 0x18) = (uint32_t)GSEventTypeDeviceOrientationChanged | (uint32_t)GSEventHostFlag;
    // 0x1C..0x47 zeroed (subtype + locations + windowLocation + timestamp)
    *(uint32_t *)(buf + 0x48) = 4;                // record_info_size
    *(uint32_t *)(buf + 0x4C) = orientation;      // UIDeviceOrientation payload

    mach_msg_header_t *hdr = (mach_msg_header_t *)buf;
    kern_return_t kr = mach_msg(hdr,
                                MACH_SEND_MSG,
                                (mach_msg_size_t)T3_ORIENTATION_MSG_SIZE,
                                0,
                                MACH_PORT_NULL,
                                MACH_MSG_TIMEOUT_NONE,
                                MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[gsevent] mach_msg_send failed: 0x%x (%s)\n",
                kr, mach_error_string(kr));
        return NO;
    }
    return YES;
}
