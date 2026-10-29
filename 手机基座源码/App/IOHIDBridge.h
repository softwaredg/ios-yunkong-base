#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// ObjC façade over open-source `STHIDEventGenerator` (IOHID).
@interface IOHIDBridge : NSObject

+ (instancetype)shared;

- (void)pointerAction:(NSString *)action x:(double)x y:(double)y;
- (void)tapAtX:(double)x y:(double)y NS_SWIFT_NAME(tap(atX:y:));
- (void)doubleTapAtX:(double)x y:(double)y NS_SWIFT_NAME(doubleTap(atX:y:));
- (void)longPressAtX:(double)x y:(double)y NS_SWIFT_NAME(longPress(atX:y:));
- (void)multiTouchAction:(NSString *)action x:(double)x y:(double)y count:(NSUInteger)count;
- (void)dragFromX:(double)x0
            fromY:(double)y0
              toX:(double)x1
              toY:(double)y1
         duration:(NSTimeInterval)seconds
            curve:(BOOL)curve NS_SWIFT_NAME(drag(fromX:fromY:toX:toY:duration:curve:));
- (void)pinchAtX:(double)x
               y:(double)y
           width:(double)w
          height:(double)h
           scale:(CGFloat)scale
           angle:(CGFloat)angle
        duration:(NSTimeInterval)seconds NS_SWIFT_NAME(pinch(atX:y:width:height:scale:angle:duration:));

- (void)stylusAction:(NSString *)action
                   x:(double)x
                   y:(double)y
             azimuth:(CGFloat)azimuth
            altitude:(CGFloat)altitude
            pressure:(CGFloat)pressure;

/// button: home|power|mute|volumeUp|volumeDown|brightnessUp|brightnessDown|snapshot|shake|lock|unlock|keyboard|spotlight
/// action: press|double|triple|long|down|up
- (BOOL)hardwareButton:(NSString *)button action:(NSString *)action;

- (void)injectText:(NSString *)text;
- (void)injectKey:(NSString *)key action:(NSString *)action;
- (void)releaseEveryKeys;
- (void)setKeepAliveInterval:(NSTimeInterval)seconds;

@end

NS_ASSUME_NONNULL_END
