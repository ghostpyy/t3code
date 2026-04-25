#import "CSupport.h"
#import <Block.h>
#import <objc/message.h>

// Swift's @convention(block) closures arrive on the stack. If the receiver
// stores them via assignment (no -copy), the stored pointer dangles as soon
// as our frame unwinds. We Block_copy every block on the way in to promote
// it to the heap. The balancing Block_release happens when the receiver
// either explicitly releases it (ARC -release on the stored block) or the
// enclosing autoreleasepool drains.
//
// Every entry point below is wrapped in @try/@catch because ROCK forwards to
// a remote process: when the remote's target doesn't implement the selector,
// or throws any ObjC exception, ROCK re-raises it locally. Swift does not
// bridge NSException -> Swift error, so the exception unwinds past the
// Swift caller silently. With @try we can log and keep executing (attaching
// a fallback path) instead of dropping the surface chain mid-setup.

static void T3LogException(NSString *where, NSException *ex) {
    NSString *msg = [NSString stringWithFormat:@"[csupport] %@ threw %@: %@\n",
                     where, ex.name ?: @"?", ex.reason ?: @"?"];
    fputs(msg.UTF8String ?: "[csupport] exception (no desc)\n", stderr);
    fflush(stderr);
}

void T3MsgSendRegisterCallback(id target, SEL sel, NSUUID *uuid, id block) {
    id heap = [block copy];
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(target, sel, uuid, heap);
    } @catch (NSException *ex) {
        T3LogException([NSString stringWithFormat:@"RegisterCallback(%@)", NSStringFromSelector(sel)], ex);
    }
}

void T3MsgSendUnregisterCallback(id target, SEL sel, NSUUID *uuid) {
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(target, sel, uuid);
    } @catch (NSException *ex) {
        T3LogException([NSString stringWithFormat:@"UnregisterCallback(%@)", NSStringFromSelector(sel)], ex);
    }
}

void T3MsgSendAttach(id io, SEL sel, id consumer, id port) {
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(io, sel, consumer, port);
    } @catch (NSException *ex) {
        T3LogException(@"Attach", ex);
    }
}

void T3MsgSendDetach(id io, SEL sel, id consumer, id port) {
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(io, sel, consumer, port);
    } @catch (NSException *ex) {
        T3LogException(@"Detach", ex);
    }
}

void T3MsgSendRegisterScreenAdapter(id target, SEL sel, NSUUID *uuid,
                                    dispatch_queue_t queue,
                                    id connectedBlock, id disconnectedBlock) {
    id c = [connectedBlock copy];
    id d = [disconnectedBlock copy];
    @try {
        ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(target, sel, uuid, queue, c, d);
    } @catch (NSException *ex) {
        T3LogException(@"RegisterScreenAdapter", ex);
    }
}

void T3MsgSendRegisterScreen(id target, SEL sel, NSUUID *uuid,
                             dispatch_queue_t queue,
                             id frameBlock, id surfacesChangedBlock, id propertiesChangedBlock) {
    id f = [frameBlock copy];
    id s = [surfacesChangedBlock copy];
    id p = [propertiesChangedBlock copy];
    @try {
        ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(target, sel, uuid, queue, f, s, p);
    } @catch (NSException *ex) {
        T3LogException(@"RegisterScreen", ex);
    }
}

void T3MsgSendEnumerateScreens(id target, SEL sel,
                               dispatch_queue_t queue,
                               id completionHandler) {
    id h = [completionHandler copy];
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(target, sel, queue, h);
    } @catch (NSException *ex) {
        T3LogException(@"EnumerateScreens", ex);
    }
}

id T3SafeRootProxy(id nsConnection) {
    SEL sel = NSSelectorFromString(@"rootProxy");
    if (![nsConnection respondsToSelector:sel]) {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(nsConnection, sel);
    } @catch (NSException *ex) {
        T3LogException(@"rootProxy", ex);
        return nil;
    }
}
