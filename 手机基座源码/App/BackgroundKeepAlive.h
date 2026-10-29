#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Prevents iOS from suspending the tipa process (no speaker audio).
@interface BackgroundKeepAlive : NSObject
+ (instancetype)shared;
- (void)start;
- (BOOL)isActive;
- (NSString *)detail;
@end

NS_ASSUME_NONNULL_END
