#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

@interface T3SimView : NSView
@property (nonatomic, assign) NSString *mode;  // @"input" or @"inspect"
@property (nonatomic, copy) void (^onEvent)(NSDictionary *);
- (instancetype)initWithContextId:(uint32_t)contextId;
- (void)updateBounds:(NSRect)rect;
- (void)updateSourcePixelSize:(NSSize)size;
- (void)updateCornerRadius:(CGFloat)radius;
/// `chainRects` are AX frames in display points, outer→inner; `scale` converts
/// points to source pixels (matches the simulator's CALayerHost bounds). Pass
/// an empty array to clear the outline. Drawn as a native CAShapeLayer
/// sibling of CALayerHost so the live simulator pixels stay visible while
/// the highlight composites at Core Animation priority above Chromium.
- (void)updateOutlines:(NSArray<NSDictionary *> *)chainRects scale:(CGFloat)scale;
@end
