#import <napi.h>
#import "simview.h"

static inline void T3AddonLog(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char buf[512];
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    fprintf(stderr, "[simview-addon] %s\n", buf);
    fflush(stderr);
}

class SimView : public Napi::ObjectWrap<SimView> {
public:
    static Napi::Object Init(Napi::Env env, Napi::Object exports) {
        Napi::Function func = DefineClass(env, "SimView", {
            InstanceMethod("attach", &SimView::Attach),
            InstanceMethod("setBounds", &SimView::SetBounds),
            InstanceMethod("setSourcePixelSize", &SimView::SetSourcePixelSize),
            InstanceMethod("setMode", &SimView::SetMode),
            InstanceMethod("setOutlines", &SimView::SetOutlines),
            InstanceMethod("destroy", &SimView::Destroy),
            InstanceMethod("on", &SimView::On),
        });
        exports.Set("SimView", func);
        return exports;
    }

    SimView(const Napi::CallbackInfo &info) : Napi::ObjectWrap<SimView>(info) {
        Napi::Env env = info.Env();
        if (info.Length() < 1 || !info[0].IsNumber()) {
            Napi::TypeError::New(env, "contextId: number required").ThrowAsJavaScriptException();
            return;
        }
        uint32_t contextId = info[0].As<Napi::Number>().Uint32Value();
        @autoreleasepool {
            view_ = [[T3SimView alloc] initWithContextId:contextId];
        }
    }

    ~SimView() {
        // DO NOT call tsfn_.Release() here.
        //
        // Node's env teardown order is: Environment::RunCleanup() drains
        // cleanup hooks (which destroys the TSFN's internal uv_mutex_t)
        // BEFORE the CleanupQueue drains reference finalizers (which is
        // where this destructor runs). Calling Release() at that point
        // re-enters napi_release_threadsafe_function → uv_mutex_lock on
        // a destroyed mutex → abort(). That is the SIGABRT we shipped in
        // 0.0.20. Release() is the caller's responsibility via destroy()
        // (see Destroy below), which runs from JS while the env is live.
        view_ = nil;
    }

private:
    T3SimView *view_ = nil;
    Napi::ThreadSafeFunction tsfn_;
    bool tsfnReleased_ = false;

    Napi::Value Attach(const Napi::CallbackInfo &info) {
        Napi::Env env = info.Env();
        if (info.Length() < 1 || !info[0].IsBuffer()) {
            Napi::TypeError::New(env, "windowHandle: Buffer required").ThrowAsJavaScriptException();
            return env.Undefined();
        }
        auto buf = info[0].As<Napi::Buffer<void *>>();
        // `Napi::Buffer<T>::Length()` returns byte-count ÷ sizeof(T) — for a
        // `Buffer<void *>`, an 8-byte NSView pointer yields Length()==1.
        // Compare against ByteLength() (raw bytes) so the check is 8 < 8, not
        // 1 < 8 (which rejected every valid handle Electron returns).
        if (buf.ByteLength() < sizeof(void *)) {
            Napi::TypeError::New(env, "invalid window handle").ThrowAsJavaScriptException();
            return env.Undefined();
        }
        NSView *contentView = (__bridge NSView *)(*reinterpret_cast<void **>(buf.Data()));
        T3SimView *localView = view_;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Explicit NSWindowAbove anchors the simulator layer above every
            // other subview Electron has registered on the content view —
            // including its WebContentsView — so NSView hit-testing returns
            // T3SimView for clicks inside the cutout and routes keyboard
            // events once the view becomes first responder.
            [contentView addSubview:localView positioned:NSWindowAbove relativeTo:nil];
            T3AddonLog("attach contentView=%p window=%p subviews=%lu view_layer=%p",
                       (__bridge void *)contentView,
                       (__bridge void *)contentView.window,
                       (unsigned long)contentView.subviews.count,
                       (__bridge void *)localView.layer);
        });
        return env.Undefined();
    }

    Napi::Value SetBounds(const Napi::CallbackInfo &info) {
        Napi::Env env = info.Env();
        if (info.Length() < 1 || !info[0].IsObject()) return env.Undefined();
        auto obj = info[0].As<Napi::Object>();
        double x = obj.Get("x").As<Napi::Number>().DoubleValue();
        double y = obj.Get("y").As<Napi::Number>().DoubleValue();
        double w = obj.Get("width").As<Napi::Number>().DoubleValue();
        double h = obj.Get("height").As<Napi::Number>().DoubleValue();
        double refW = 0.0, refH = 0.0;
        Napi::Value rawRefW = obj.Get("refWidth");
        Napi::Value rawRefH = obj.Get("refHeight");
        if (rawRefW.IsNumber()) refW = rawRefW.As<Napi::Number>().DoubleValue();
        if (rawRefH.IsNumber()) refH = rawRefH.As<Napi::Number>().DoubleValue();
        double cornerRadius = -1.0;
        Napi::Value rawR = obj.Get("cornerRadius");
        if (rawR.IsNumber()) cornerRadius = rawR.As<Napi::Number>().DoubleValue();
        dispatch_async(dispatch_get_main_queue(), ^{
            NSView *super = view_.superview;
            if (!super) return;
            const CGFloat superW = super.bounds.size.width;
            const CGFloat superHv = super.bounds.size.height;
            // Map renderer client coordinates to this superview. Chromium's
            // getBoundingClientRect is in CSS px relative to the layout
            // viewport; the host NSView is often the window contentView, whose
            // size can differ (title-bar insets, zoom, DPR edge cases, or
            // WebContents not filling {0,0}) — proportional mapping keeps the
            // native CALayerHost locked to the visible cutout the user sees.
            CGFloat x1 = (CGFloat)x, y1 = (CGFloat)y, w1 = (CGFloat)w, h1 = (CGFloat)h;
            CGFloat rScale = 1.0;
            const BOOL shouldScale =
                refW > 0.5 && refH > 0.5 && superW > 0.0 && superHv > 0.0 &&
                (fabs(superW - (CGFloat)refW) > 1.0 || fabs(superHv - (CGFloat)refH) > 1.0);
            if (shouldScale) {
                CGFloat rW = (CGFloat)refW;
                CGFloat rH = (CGFloat)refH;
                CGFloat sx = superW / rW;
                CGFloat sy = superHv / rH;
                x1 = x1 * sx;
                w1 = w1 * sx;
                y1 = y1 * sy;
                h1 = h1 * sy;
                // Average axis scale — corner radius is isotropic, and the
                // bezel SVG's innerRadius is a single value, so we match.
                rScale = (sx + sy) * 0.5;
            }
            x1 = MAX(0.0, MIN(superW, x1));
            y1 = MAX(0.0, MIN(superHv, y1));
            w1 = MAX(0.0, MIN(superW - x1, w1));
            h1 = MAX(0.0, MIN(superHv - y1, h1));
            // Subpixel-precise rect. NSIntegralRect used to live here but it
            // introduced up to 1-backing-pixel drift vs the DOM bezel, which
            // is rendered at subpixel precision. Core Animation handles
            // fractional frames natively via backing-scale-aware rasterization.
            NSRect r = NSMakeRect(x1, superHv - y1 - h1, w1, h1);
            [view_ updateBounds:r];
            if (cornerRadius >= 0.0) {
                [view_ updateCornerRadius:(CGFloat)cornerRadius * rScale];
            }
        });
        return env.Undefined();
    }

    Napi::Value SetSourcePixelSize(const Napi::CallbackInfo &info) {
        Napi::Env env = info.Env();
        if (info.Length() < 1 || !info[0].IsObject()) return env.Undefined();
        auto obj = info[0].As<Napi::Object>();
        double w = obj.Get("width").As<Napi::Number>().DoubleValue();
        double h = obj.Get("height").As<Napi::Number>().DoubleValue();
        dispatch_async(dispatch_get_main_queue(), ^{
            [view_ updateSourcePixelSize:NSMakeSize(w, h)];
        });
        return env.Undefined();
    }

    Napi::Value SetMode(const Napi::CallbackInfo &info) {
        if (info.Length() < 1 || !info[0].IsString()) return info.Env().Undefined();
        NSString *mode = [NSString stringWithUTF8String:info[0].As<Napi::String>().Utf8Value().c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{ view_.mode = mode; });
        return info.Env().Undefined();
    }

    Napi::Value SetOutlines(const Napi::CallbackInfo &info) {
        Napi::Env env = info.Env();
        if (info.Length() < 1) return env.Undefined();
        // arg0: Array<{x,y,width,height}> in display points, outer→inner order
        //       (index 0 = innermost/primary hit)
        // arg1: scale (points→pixels; defaults to 1.0)
        double scale = 1.0;
        if (info.Length() >= 2 && info[1].IsNumber()) {
            scale = info[1].As<Napi::Number>().DoubleValue();
        }
        NSMutableArray<NSDictionary *> *rects = [NSMutableArray array];
        if (info[0].IsArray()) {
            auto arr = info[0].As<Napi::Array>();
            uint32_t len = arr.Length();
            for (uint32_t i = 0; i < len; i++) {
                Napi::Value item = arr.Get(i);
                if (!item.IsObject()) continue;
                auto obj = item.As<Napi::Object>();
                double x = obj.Get("x").IsNumber() ? obj.Get("x").As<Napi::Number>().DoubleValue() : 0.0;
                double y = obj.Get("y").IsNumber() ? obj.Get("y").As<Napi::Number>().DoubleValue() : 0.0;
                double w = obj.Get("width").IsNumber() ? obj.Get("width").As<Napi::Number>().DoubleValue() : 0.0;
                double h = obj.Get("height").IsNumber() ? obj.Get("height").As<Napi::Number>().DoubleValue() : 0.0;
                double r = obj.Get("cornerRadius").IsNumber()
                    ? obj.Get("cornerRadius").As<Napi::Number>().DoubleValue() : 0.0;
                [rects addObject:@{@"x": @(x), @"y": @(y),
                                   @"width": @(w), @"height": @(h),
                                   @"cornerRadius": @(r)}];
            }
        }
        T3SimView *localView = view_;
        dispatch_async(dispatch_get_main_queue(), ^{
            [localView updateOutlines:rects scale:(CGFloat)scale];
        });
        return env.Undefined();
    }

    Napi::Value Destroy(const Napi::CallbackInfo &info) {
        dispatch_async(dispatch_get_main_queue(), ^{ [view_ removeFromSuperview]; });
        // Release exactly once. Napi::ThreadSafeFunction::Release() does not
        // null out the internal handle, so a naked `if (tsfn_)` check can't
        // prevent a double-release when destroy() is called from JS and then
        // the destructor also tries to clean up. Guard explicitly.
        if (tsfn_ && !tsfnReleased_) {
            tsfnReleased_ = true;
            tsfn_.Release();
        }
        return info.Env().Undefined();
    }

    Napi::Value On(const Napi::CallbackInfo &info) {
        Napi::Env env = info.Env();
        if (info.Length() < 1 || !info[0].IsFunction()) return env.Undefined();
        // Swap-in a new TSFN: release any prior one first so we don't leak
        // a thread-count reference if On() is called more than once.
        if (tsfn_ && !tsfnReleased_) {
            tsfnReleased_ = true;
            tsfn_.Release();
        }
        tsfnReleased_ = false;
        tsfn_ = Napi::ThreadSafeFunction::New(env, info[0].As<Napi::Function>(), "simview-events", 0, 1);
        __weak T3SimView *weakView = view_;
        auto tsfnCopy = tsfn_;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakView.onEvent = ^(NSDictionary *payload) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
                if (!data) return;
                std::string s((const char *)data.bytes, data.length);
                tsfnCopy.BlockingCall([s](Napi::Env e, Napi::Function jsCb) {
                    jsCb.Call({ Napi::String::New(e, s) });
                });
            };
        });
        return env.Undefined();
    }
};

static Napi::Object InitAll(Napi::Env env, Napi::Object exports) {
    return SimView::Init(env, exports);
}

NODE_API_MODULE(simview, InitAll)
