#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIScreen (Private)
- (CGRect)_referenceBounds;
- (CGRect)_unjailedReferenceBoundsInPixels;
@end

NS_ASSUME_NONNULL_END
