// T3AXBridge — bridges `AccessibilityPlatformTranslation` (AXPTranslator) to
// Swift so we can perform best-effort, Xcode-grade element inspection against
// an Xcode 26+ simulator. The legacy `SimulatorBridge` Distributed-Objects
// helper has been removed in Xcode 26, so the only blessed path left is the
// AXPTranslator / `-[SimDevice sendAccessibilityRequestAsync:...]` pipeline
// that Apple's own Accessibility Inspector uses.
//
// On Xcode 26.2 the translator correctly reports the frontmost application's
// pid and delegate token, and will hand back AXPTranslationObject/
// AXPMacPlatformElement instances. Attribute round-trips (role/label/value)
// currently come back empty on stock Xcode 26.2 because the remote AX runtime
// does not hydrate the attribute cache unless the app is explicitly launched
// with `UIAccessibilityIsVoiceOverRunning`; we keep the infrastructure so the
// translator path lights up automatically when Apple re-enables the hydration
// path (or when running against an AX-instrumented app).
//
// We also export `T3AXForegroundAppPID` so Swift can resolve the frontmost
// application's host-side pid — enough to look up the bundle identifier via
// `simctl spawn launchctl print system` regardless of whether the AX
// attribute path works, which drives the rich inspect UI in the pane.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void T3AXLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fputs([[NSString stringWithFormat:@"[ax] %@\n", msg] UTF8String], stderr);
    fflush(stderr);
}

// One-shot dlopen of AccessibilityPlatformTranslation. The framework lives
// under /System/Library/PrivateFrameworks/ and isn't auto-linked, so we pull
// it in lazily on first setup.
static dispatch_once_t gAXFrameworkLoadOnce;
static BOOL gAXFrameworkAvailable = NO;

static void T3AXLoadFramework(void) {
    dispatch_once(&gAXFrameworkLoadOnce, ^{
        void *h = dlopen(
            "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation",
            RTLD_LAZY);
        if (!h) {
            T3AXLog(@"dlopen AccessibilityPlatformTranslation failed: %s", dlerror());
            return;
        }
        gAXFrameworkAvailable = YES;
    });
}

// MARK: - Bridge delegate

// The translator invokes this object's bridge-callback to obtain a block
// that turns an AXPTranslatorRequest into an AXPTranslatorResponse. We run
// the request through `-[SimDevice sendAccessibilityRequestAsync:...]` and
// use a dispatch_semaphore_t to make the async call synchronous from the
// translator's point of view. See
// `AXPTranslationDelegateHelper.accessibilityTranslationDelegateBridgeCallback`.
@interface T3AXBridgeDelegate : NSObject
@property(nonatomic, weak) id simDevice;
@property(nonatomic, copy) NSString *token;
@property(nonatomic) NSTimeInterval timeout;
@end

@implementation T3AXBridgeDelegate

- (instancetype)initWithSimDevice:(id)simDevice token:(NSString *)token {
    if ((self = [super init])) {
        _simDevice = simDevice;
        _token = [token copy];
        _timeout = 1.5;
    }
    return self;
}

- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(id)token {
    return [self _bridgeCallbackBlock];
}

- (id)accessibilityTranslationDelegateBridgeCallback {
    return [self _bridgeCallbackBlock];
}

- (id)_bridgeCallbackBlock {
    __weak typeof(self) weakSelf = self;
    id block = ^id(id request) {
        typeof(self) strongSelf = weakSelf;
        id device = strongSelf.simDevice;
        if (!strongSelf || !device) return nil;

        SEL sendSel = NSSelectorFromString(@"sendAccessibilityRequestAsync:completionQueue:completionHandler:");
        if (![device respondsToSelector:sendSel]) return nil;

        __block id captured = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        static dispatch_queue_t completionQueue;
        static dispatch_once_t qOnce;
        dispatch_once(&qOnce, ^{
            completionQueue = dispatch_queue_create(
                "com.t3tools.sim-bridge.ax-completion", DISPATCH_QUEUE_SERIAL);
        });
        void (^handler)(id) = ^(id response) {
            captured = response;
            dispatch_semaphore_signal(sem);
        };
        @try {
            ((void (*)(id, SEL, id, dispatch_queue_t, id))objc_msgSend)(
                device, sendSel, request, completionQueue, handler);
        } @catch (NSException *ex) {
            T3AXLog(@"sendAccessibilityRequestAsync threw %@: %@", ex.name, ex.reason);
            return nil;
        }
        if (dispatch_semaphore_wait(sem,
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(strongSelf.timeout * NSEC_PER_SEC))) != 0) {
            return nil;
        }
        return captured;
    };
    return [block copy];
}

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect
                                                  withContext:(id)context
                                                  postProcess:(id)postProcess {
    return rect;
}

- (id)accessibilityTranslationRootParent { return nil; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *s = [super methodSignatureForSelector:sel];
    if (!s) s = [NSMethodSignature signatureWithObjCTypes:"@@:@@"];
    return s;
}
- (void)forwardInvocation:(NSInvocation *)inv {
    id nilReturn = nil;
    [inv setReturnValue:&nilReturn];
}

@end

// MARK: - Translator setup

static id gTranslator = nil;
static T3AXBridgeDelegate *gDelegate = nil;
static NSString *gToken = nil;

BOOL T3AXBridgeSetup(id simDevice) {
    T3AXLoadFramework();
    if (!gAXFrameworkAvailable) return NO;
    if (!simDevice) return NO;

    Class translatorCls = NSClassFromString(@"AXPTranslator");
    if (!translatorCls) return NO;

    SEL iOSSel = NSSelectorFromString(@"sharediOSInstance");
    SEL anySel = NSSelectorFromString(@"sharedInstance");
    id translator = nil;
    if ([translatorCls respondsToSelector:iOSSel]) {
        translator = ((id (*)(id, SEL))objc_msgSend)(translatorCls, iOSSel);
    } else if ([translatorCls respondsToSelector:anySel]) {
        translator = ((id (*)(id, SEL))objc_msgSend)(translatorCls, anySel);
    }
    if (!translator) return NO;

    NSString *token = nil;
    SEL tokSel = NSSelectorFromString(@"accessibilityPlatformTranslationToken");
    if ([simDevice respondsToSelector:tokSel]) {
        @try { token = ((id (*)(id, SEL))objc_msgSend)(simDevice, tokSel); }
        @catch (NSException *ex) { /* ignore */ }
    }
    if (!token) {
        SEL udidSel = NSSelectorFromString(@"UDID");
        if ([simDevice respondsToSelector:udidSel]) {
            @try {
                id udid = ((id (*)(id, SEL))objc_msgSend)(simDevice, udidSel);
                token = [NSString stringWithFormat:@"%@", udid];
            } @catch (NSException *ex) { /* ignore */ }
        }
    }
    if (!token) token = @"com.t3tools.t3code.default";

    T3AXBridgeDelegate *delegate =
        [[T3AXBridgeDelegate alloc] initWithSimDevice:simDevice token:token];

    @try {
        SEL setBD = NSSelectorFromString(@"setBridgeDelegate:");
        SEL setBTD = NSSelectorFromString(@"setBridgeTokenDelegate:");
        SEL setSDT = NSSelectorFromString(@"setSupportsDelegateTokens:");
        SEL setAXE = NSSelectorFromString(@"setAccessibilityEnabled:");
        SEL enable = NSSelectorFromString(@"enableAccessibility");
        if ([translator respondsToSelector:setBD]) {
            ((void (*)(id, SEL, id))objc_msgSend)(translator, setBD, delegate);
        }
        if ([translator respondsToSelector:setBTD]) {
            ((void (*)(id, SEL, id))objc_msgSend)(translator, setBTD, delegate);
        }
        if ([translator respondsToSelector:setSDT]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(translator, setSDT, YES);
        }
        if ([translator respondsToSelector:setAXE]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(translator, setAXE, YES);
        }
        if ([translator respondsToSelector:enable]) {
            ((void (*)(id, SEL))objc_msgSend)(translator, enable);
        }
    } @catch (NSException *ex) {
        T3AXLog(@"translator setup threw %@: %@", ex.name, ex.reason);
        return NO;
    }

    gTranslator = translator;
    gDelegate = delegate;
    gToken = [token copy];
    T3AXLog(@"AXPTranslator ready");
    return YES;
}

// MARK: - Element helpers

static NSString *T3AXStringValue(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSAttributedString.class]) return [v string];
    if ([v respondsToSelector:@selector(stringValue)]) return [v stringValue];
    return [v description];
}

static id T3AXRawAttr(id element, NSString *legacyAttr, NSString *modernSel) {
    if (legacyAttr) {
        SEL legSel = NSSelectorFromString(@"accessibilityAttributeValue:");
        if ([element respondsToSelector:legSel]) {
            @try {
                id v = ((id (*)(id, SEL, id))objc_msgSend)(element, legSel, legacyAttr);
                if (v) return v;
            } @catch (NSException *ex) { /* ignore */ }
        }
    }
    if (modernSel) {
        SEL sel = NSSelectorFromString(modernSel);
        if ([element respondsToSelector:sel]) {
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)(element, sel);
                if (v) return v;
            } @catch (NSException *ex) { /* ignore */ }
        }
    }
    return nil;
}

static NSString *T3AXAttrString(id element, NSString *modernSel, NSString *legacyAttr) {
    return T3AXStringValue(T3AXRawAttr(element, legacyAttr, modernSel));
}

static NSDictionary *T3AXDictFromElement(id element) {
    if (!element) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    @try {
        NSString *role = T3AXAttrString(element, @"accessibilityRole", @"AXRole");
        NSString *subrole = T3AXAttrString(element, @"accessibilitySubrole", @"AXSubrole");
        NSString *label = T3AXAttrString(element, @"accessibilityLabel", @"AXLabel");
        NSString *title = T3AXAttrString(element, @"accessibilityTitle", @"AXTitle");
        NSString *value = T3AXAttrString(element, @"accessibilityValue", @"AXValue");
        NSString *help = T3AXAttrString(element, @"accessibilityHelp", @"AXHelp");
        NSString *ident = T3AXAttrString(element, @"accessibilityIdentifier", @"AXIdentifier");

        if (role) out[@"role"] = role;
        if (subrole) out[@"subrole"] = subrole;
        if (label) out[@"label"] = label;
        else if (title) out[@"label"] = title;
        if (title) out[@"title"] = title;
        if (value) out[@"value"] = value;
        if (help) out[@"help"] = help;
        if (ident) out[@"identifier"] = ident;

        SEL enabledSel = NSSelectorFromString(@"isAccessibilityEnabled");
        if ([element respondsToSelector:enabledSel]) {
            out[@"enabled"] = @(((BOOL (*)(id, SEL))objc_msgSend)(element, enabledSel));
        }

        CGRect rect = CGRectZero;
        BOOL haveRect = NO;
        SEL attrSel = NSSelectorFromString(@"accessibilityAttributeValue:");
        if ([element respondsToSelector:attrSel]) {
            @try {
                id v = ((id (*)(id, SEL, id))objc_msgSend)(element, attrSel, @"AXFrame");
                if ([v isKindOfClass:NSValue.class]) {
                    rect = [(NSValue *)v rectValue];
                    haveRect = YES;
                }
            } @catch (NSException *ex) { /* ignore */ }
        }
        if (!haveRect) {
            SEL modernFrame = NSSelectorFromString(@"accessibilityFrame");
            if ([element respondsToSelector:modernFrame]) {
                typedef CGRect (*FrameIMP)(id, SEL);
                FrameIMP fn = (FrameIMP)class_getMethodImplementation(
                    object_getClass(element), modernFrame);
                rect = fn(element, modernFrame);
                haveRect = YES;
            }
        }
        if (haveRect) {
            out[@"frame"] = @[
                @(rect.origin.x), @(rect.origin.y),
                @(rect.size.width), @(rect.size.height)
            ];
        }

        unsigned long long objectID = 0;
        @try {
            SEL translSel = NSSelectorFromString(@"translation");
            if ([element respondsToSelector:translSel]) {
                id t = ((id (*)(id, SEL))objc_msgSend)(element, translSel);
                SEL oidSel = NSSelectorFromString(@"objectID");
                if ([t respondsToSelector:oidSel]) {
                    objectID = ((unsigned long long (*)(id, SEL))objc_msgSend)(t, oidSel);
                }
            }
        } @catch (NSException *ex) { /* ignore */ }

        // The Swift side treats a missing "role" key as "Unknown" and
        // discards the whole hit chain. Always emit a concrete role so
        // `isChainUnhydrated` can hand off to the OCR + SourceScanner path
        // while still classifying the node as a real UI element.
        if (!out[@"role"]) {
            out[@"role"] = @"AXUIElement";
        }
        NSString *finalRole = out[@"role"];
        NSArray *frame = out[@"frame"] ?: @[ @0, @0, @0, @0 ];
        out[@"id"] = objectID
            ? [NSString stringWithFormat:@"%llu", objectID]
            : [NSString stringWithFormat:@"%@@%@,%@,%@,%@", finalRole,
               frame[0], frame[1], frame[2], frame[3]];
    } @catch (NSException *ex) {
        T3AXLog(@"AXDictFromElement threw %@: %@", ex.name, ex.reason);
    }
    return out;
}

NSArray<NSDictionary *> *T3AXBuildChain(id hitElement, int maxDepth) {
    NSMutableArray *chain = [NSMutableArray array];
    id cur = hitElement;
    int depth = 0;
    while (cur && depth < maxDepth) {
        NSDictionary *dict = T3AXDictFromElement(cur);
        if (dict) [chain addObject:dict];
        depth++;
        SEL parentSel = NSSelectorFromString(@"accessibilityParent");
        if (![cur respondsToSelector:parentSel]) break;
        @try {
            id parent = ((id (*)(id, SEL))objc_msgSend)(cur, parentSel);
            if (!parent || parent == cur) break;
            cur = parent;
        } @catch (NSException *ex) { break; }
    }
    return chain;
}

// MARK: - Public entrypoints

static id T3AXGetAppTranslation(uint32_t displayId) {
    if (!gTranslator) return nil;
    @try {
        SEL sel = NSSelectorFromString(@"frontmostApplicationWithDisplayId:bridgeDelegateToken:");
        if (![gTranslator respondsToSelector:sel]) return nil;
        typedef id (*FrontIMP)(id, SEL, uint32_t, id);
        FrontIMP fn = (FrontIMP)class_getMethodImplementation(
            object_getClass(gTranslator), sel);
        return fn(gTranslator, sel, displayId, gToken);
    } @catch (NSException *ex) {
        T3AXLog(@"frontmostApplication threw %@", ex.reason);
        return nil;
    }
}

static id T3AXWrapTranslation(id translation) {
    if (!translation || !gTranslator) return nil;
    SEL setTokSel = NSSelectorFromString(@"setBridgeDelegateToken:");
    if ([translation respondsToSelector:setTokSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(translation, setTokSel, gToken);
    }
    SEL fromTranslation = NSSelectorFromString(@"macPlatformElementFromTranslation:");
    if ([gTranslator respondsToSelector:fromTranslation]) {
        return ((id (*)(id, SEL, id))objc_msgSend)(gTranslator, fromTranslation, translation);
    }
    return nil;
}

// Returns the frontmost simulator-side application's pid, or 0 on failure.
// This resolves even on Xcode 26.2 where attribute round-trips return empty,
// because the translation object itself carries the pid.
int32_t T3AXForegroundAppPID(uint32_t displayId) {
    id translation = T3AXGetAppTranslation(displayId);
    if (!translation) return 0;
    SEL pidSel = NSSelectorFromString(@"pid");
    if (![translation respondsToSelector:pidSel]) return 0;
    @try {
        int pid = ((int (*)(id, SEL))objc_msgSend)(translation, pidSel);
        return pid;
    } @catch (NSException *ex) { return 0; }
}

NSArray<NSDictionary *> * _Nullable T3AXBridgeHitTest(double x, double y, uint32_t displayId) {
    if (!gTranslator || !gDelegate) return nil;

    id hit = nil;
    @try {
        id appTranslation = T3AXGetAppTranslation(displayId);
        id app = T3AXWrapTranslation(appTranslation);
        if (app) {
            SEL hitSel = NSSelectorFromString(@"accessibilityHitTest:withDisplayId:contextId:");
            if ([app respondsToSelector:hitSel]) {
                typedef id (*HitIMP)(id, SEL, CGPoint, uint32_t, uint32_t);
                HitIMP fn = (HitIMP)class_getMethodImplementation(
                    object_getClass(app), hitSel);
                hit = fn(app, hitSel, CGPointMake(x, y), displayId, 0);
            }
            if (!hit) {
                SEL hit2 = NSSelectorFromString(@"accessibilityHitTest:");
                if ([app respondsToSelector:hit2]) {
                    typedef id (*HitIMP2)(id, SEL, CGPoint);
                    HitIMP2 fn2 = (HitIMP2)class_getMethodImplementation(
                        object_getClass(app), hit2);
                    hit = fn2(app, hit2, CGPointMake(x, y));
                }
            }
        }
        if (!hit) {
            SEL sel = NSSelectorFromString(@"objectAtPoint:displayId:bridgeDelegateToken:");
            if ([gTranslator respondsToSelector:sel]) {
                typedef id (*HitIMP)(id, SEL, CGPoint, uint32_t, id);
                HitIMP fn = (HitIMP)class_getMethodImplementation(
                    object_getClass(gTranslator), sel);
                id translationObj = fn(gTranslator, sel, CGPointMake(x, y), displayId, gToken);
                hit = T3AXWrapTranslation(translationObj);
            }
        }
    } @catch (NSException *ex) {
        T3AXLog(@"hit path threw %@: %@", ex.name, ex.reason);
        return nil;
    }

    if (!hit) return nil;
    return T3AXBuildChain(hit, 16);
}

NSDictionary * _Nullable T3AXBridgeFrontmost(uint32_t displayId) {
    id appTranslation = T3AXGetAppTranslation(displayId);
    id app = T3AXWrapTranslation(appTranslation);
    if (!app) return nil;
    return T3AXDictFromElement(app);
}

BOOL T3AXBridgeAvailable(void) {
    return gTranslator != nil && gDelegate != nil;
}
