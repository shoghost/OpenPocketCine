#import <UIKit/UIKit.h>

#import "MimoKickClient.h"

NS_ASSUME_NONNULL_BEGIN

/// A window that never becomes key and never consumes camera touches.
@interface MCPassthroughWindow : UIWindow
@end

/// Read-only Kick overlay. Its frame spans the screen so chat may extend over video.
@interface MCKickHUDView : UIView <MCKickClientDelegate>
- (void)updateForBounds:(CGRect)bounds
               safeArea:(UIEdgeInsets)safeArea
     previewFrameInRoot:(CGRect)previewFrame;
@end

NS_ASSUME_NONNULL_END
