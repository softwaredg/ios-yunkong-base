#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Spawns a sibling `--helper` process (DirectPhoneBase LanCaptureHelper model).
@interface HelperLauncher : NSObject
+ (BOOL)isHelperProcess;
+ (BOOL)isHelperPortOpen;
+ (BOOL)ensureHelperRunning;
@end

NS_ASSUME_NONNULL_END
