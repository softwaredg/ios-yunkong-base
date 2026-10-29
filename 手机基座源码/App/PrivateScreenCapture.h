#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Full-display capture via QuartzCore render server + IOSurface (no ReplayKit prompt).
/// Requires TrollStore/private entitlements (QuartzCore.global-capture, etc.).
@interface PrivateScreenCapture : NSObject

+ (instancetype)shared;
- (BOOL)isAvailable;
- (void)startWithHandler:(void (^)(CVPixelBufferRef pixelBuffer, uint64_t ptsUs))handler;
/// Fired once when several consecutive renders look empty (black) — caller should fall back.
- (void)setBlankHandler:(void (^ _Nullable)(void))handler;
- (void)stop;
- (void)setPreferredFPS:(NSInteger)fps;

@end

NS_ASSUME_NONNULL_END
