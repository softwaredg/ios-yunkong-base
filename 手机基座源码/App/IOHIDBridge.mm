#import "IOHIDBridge.h"
#import "STHIDEventGenerator.h"
#import "UIScreen+Private.h"
#import <UIKit/UIKit.h>

@interface STHIDEventGenerator (IOHIDMove)
- (void)_updateTouchPoints:(CGPoint *)points count:(NSUInteger)count;
@end

@implementation IOHIDBridge {
    BOOL _down;
    CGPoint _lastPx;
}

+ (instancetype)shared {
    static IOHIDBridge *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[IOHIDBridge alloc] init]; });
    return s;
}

- (CGSize)pixelSize {
    CGSize size = [[UIScreen mainScreen] _unjailedReferenceBoundsInPixels].size;
    if (size.width < 1 || size.height < 1) {
        CGRect b = UIScreen.mainScreen.bounds;
        CGFloat s = UIScreen.mainScreen.scale;
        size = CGSizeMake(b.size.width * s, b.size.height * s);
    }
    return size;
}

- (CGPoint)px:(double)x y:(double)y {
    CGSize size = [self pixelSize];
    return CGPointMake(MAX(0, MIN(1, x)) * size.width, MAX(0, MIN(1, y)) * size.height);
}

- (CGRect)pxRectX:(double)x y:(double)y width:(double)w height:(double)h {
    CGSize size = [self pixelSize];
    return CGRectMake(MAX(0, MIN(1, x)) * size.width, MAX(0, MIN(1, y)) * size.height,
                      MAX(0.01, MIN(1, w)) * size.width, MAX(0.01, MIN(1, h)) * size.height);
}

- (STHIDEventGenerator *)gen {
    return [STHIDEventGenerator sharedGenerator];
}

#pragma mark - Pointer / gestures

- (void)pointerAction:(NSString *)action x:(double)x y:(double)y {
    CGPoint pt = [self px:x y:y];
    if ([action isEqualToString:@"down"]) {
        _down = YES;
        _lastPx = pt;
        [[self gen] touchDown:pt];
    } else if ([action isEqualToString:@"move"]) {
        if (!_down)
            return;
        _lastPx = pt;
        [[self gen] _updateTouchPoints:&pt count:1];
    } else if ([action isEqualToString:@"up"] || [action isEqualToString:@"cancel"]) {
        if (!_down)
            return;
        _down = NO;
        CGPoint lift = [action isEqualToString:@"cancel"] ? _lastPx : pt;
        [[self gen] liftUp:lift];
    }
}

- (void)tapAtX:(double)x y:(double)y {
    [[self gen] tap:[self px:x y:y]];
}

- (void)doubleTapAtX:(double)x y:(double)y {
    [[self gen] doubleTap:[self px:x y:y]];
}

- (void)longPressAtX:(double)x y:(double)y {
    [[self gen] longPress:[self px:x y:y]];
}

- (void)multiTouchAction:(NSString *)action x:(double)x y:(double)y count:(NSUInteger)count {
    count = MAX(1, MIN(count, 5));
    CGPoint pt = [self px:x y:y];
    if ([action isEqualToString:@"down"]) {
        [[self gen] touchDown:pt touchCount:count];
    } else if ([action isEqualToString:@"up"]) {
        [[self gen] liftUp:pt touchCount:count];
    } else if ([action isEqualToString:@"tap"]) {
        if (count == 2)
            [[self gen] twoFingerTap:pt];
        else if (count >= 3)
            [[self gen] threeFingerTap:pt];
        else
            [[self gen] tap:pt];
    }
}

- (void)dragFromX:(double)x0
            fromY:(double)y0
              toX:(double)x1
              toY:(double)y1
         duration:(NSTimeInterval)seconds
            curve:(BOOL)curve {
    if (seconds <= 0)
        seconds = 0.25;
    CGPoint a = [self px:x0 y:y0];
    CGPoint b = [self px:x1 y:y1];
    if (curve)
        [[self gen] dragCurveWithStartPoint:a endPoint:b duration:seconds];
    else
        [[self gen] dragLinearWithStartPoint:a endPoint:b duration:seconds];
}

- (void)pinchAtX:(double)x
               y:(double)y
           width:(double)w
          height:(double)h
           scale:(CGFloat)scale
           angle:(CGFloat)angle
        duration:(NSTimeInterval)seconds {
    if (seconds <= 0)
        seconds = 0.35;
    if (scale == 0)
        scale = 0.5;
    CGRect bounds = [self pxRectX:x y:y width:w height:h];
    [[self gen] pinchLinearInBounds:bounds scale:scale angle:angle duration:seconds];
}

- (void)stylusAction:(NSString *)action
                   x:(double)x
                   y:(double)y
             azimuth:(CGFloat)azimuth
            altitude:(CGFloat)altitude
            pressure:(CGFloat)pressure {
    CGPoint pt = [self px:x y:y];
    if ([action isEqualToString:@"down"]) {
        [[self gen] stylusDownAtPoint:pt azimuthAngle:azimuth altitudeAngle:altitude pressure:pressure];
    } else if ([action isEqualToString:@"move"]) {
        [[self gen] stylusMoveToPoint:pt azimuthAngle:azimuth altitudeAngle:altitude pressure:pressure];
    } else if ([action isEqualToString:@"up"]) {
        [[self gen] stylusUpAtPoint:pt];
    } else if ([action isEqualToString:@"tap"]) {
        [[self gen] stylusTapAtPoint:pt azimuthAngle:azimuth altitudeAngle:altitude pressure:pressure];
    }
}

#pragma mark - Hardware

- (BOOL)hardwareButton:(NSString *)button action:(NSString *)action {
    NSString *b = button.lowercaseString;
    NSString *a = action.length ? action.lowercaseString : @"press";
    STHIDEventGenerator *g = [self gen];

    if ([b isEqualToString:@"home"] || [b isEqualToString:@"menu"]) {
        if ([a isEqualToString:@"double"])
            [g menuDoublePress];
        else if ([a isEqualToString:@"long"])
            [g menuLongPress];
        else if ([a isEqualToString:@"down"])
            [g menuDown];
        else if ([a isEqualToString:@"up"])
            [g menuUp];
        else
            [g menuPress];
        return YES;
    }
    if ([b isEqualToString:@"power"]) {
        if ([a isEqualToString:@"double"])
            [g powerDoublePress];
        else if ([a isEqualToString:@"triple"])
            [g powerTriplePress];
        else if ([a isEqualToString:@"long"])
            [g powerLongPress];
        else if ([a isEqualToString:@"down"])
            [g powerDown];
        else if ([a isEqualToString:@"up"])
            [g powerUp];
        else
            [g powerPress];
        return YES;
    }
    if ([b isEqualToString:@"mute"]) {
        if ([a isEqualToString:@"down"])
            [g muteDown];
        else if ([a isEqualToString:@"up"])
            [g muteUp];
        else
            [g mutePress];
        return YES;
    }
    if ([b isEqualToString:@"volumeup"] || [b isEqualToString:@"vol+"] || [b isEqualToString:@"volume+"]) {
        if ([a isEqualToString:@"down"])
            [g volumeIncrementDown];
        else if ([a isEqualToString:@"up"])
            [g volumeIncrementUp];
        else
            [g volumeIncrementPress];
        return YES;
    }
    if ([b isEqualToString:@"volumedown"] || [b isEqualToString:@"vol-"] || [b isEqualToString:@"volume-"]) {
        if ([a isEqualToString:@"down"])
            [g volumeDecrementDown];
        else if ([a isEqualToString:@"up"])
            [g volumeDecrementUp];
        else
            [g volumeDecrementPress];
        return YES;
    }
    if ([b isEqualToString:@"brightnessup"] || [b isEqualToString:@"bright+"]) {
        if ([a isEqualToString:@"down"])
            [g displayBrightnessIncrementDown];
        else if ([a isEqualToString:@"up"])
            [g displayBrightnessIncrementUp];
        else
            [g displayBrightnessIncrementPress];
        return YES;
    }
    if ([b isEqualToString:@"brightnessdown"] || [b isEqualToString:@"bright-"]) {
        if ([a isEqualToString:@"down"])
            [g displayBrightnessDecrementDown];
        else if ([a isEqualToString:@"up"])
            [g displayBrightnessDecrementUp];
        else
            [g displayBrightnessDecrementPress];
        return YES;
    }
    if ([b isEqualToString:@"snapshot"] || [b isEqualToString:@"screenshot"]) {
        [g snapshotPress];
        return YES;
    }
    if ([b isEqualToString:@"shake"]) {
        [g shakeIt];
        return YES;
    }
    if ([b isEqualToString:@"lock"]) {
        [g hardwareLock];
        return YES;
    }
    if ([b isEqualToString:@"unlock"]) {
        [g hardwareUnlock];
        return YES;
    }
    if ([b isEqualToString:@"keyboard"]) {
        [g toggleOnScreenKeyboard];
        return YES;
    }
    if ([b isEqualToString:@"spotlight"]) {
        [g toggleSpotlight];
        return YES;
    }
    return NO;
}

#pragma mark - Keyboard

- (NSString *)mappedKey:(NSString *)key {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"backspace" : @"BACKSPACE",
            @"delete" : @"BACKSPACE",
            @"enter" : @"ENTER",
            @"return" : @"ENTER",
            @"tab" : @"TAB",
            @"escape" : @"ESCAPE",
            @"esc" : @"ESCAPE",
            @"left" : @"LEFTARROW",
            @"right" : @"RIGHTARROW",
            @"up" : @"UPARROW",
            @"down" : @"DOWNARROW",
            @"home" : @"HOME",
            @"end" : @"END",
            @"pageup" : @"PAGEUP",
            @"pagedown" : @"PAGEDOWN",
            @"space" : @" ",
        };
    });
    NSString *mapped = map[key.lowercaseString];
    return mapped ?: key;
}

- (void)injectText:(NSString *)text {
    STHIDEventGenerator *g = [self gen];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\n' || c == '\r')
            [g keyPress:@"ENTER"];
        else if (c == '\t')
            [g keyPress:@"TAB"];
        else
            [g keyPress:[NSString stringWithCharacters:&c length:1]];
    }
}

- (void)injectKey:(NSString *)key action:(NSString *)action {
    NSString *name = [self mappedKey:key];
    NSString *a = action.length ? action.lowercaseString : @"press";
    STHIDEventGenerator *g = [self gen];
    if ([a isEqualToString:@"down"])
        [g keyDown:name];
    else if ([a isEqualToString:@"up"])
        [g keyUp:name];
    else
        [g keyPress:name];
}

- (void)releaseEveryKeys {
    [[self gen] releaseEveryKeys];
}

- (void)setKeepAliveInterval:(NSTimeInterval)seconds {
    [self gen].keepAliveInterval = MAX(0, seconds);
}

@end
