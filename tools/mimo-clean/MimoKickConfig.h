#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The only user-editable Kick settings for the injected Mimo HUD.
FOUNDATION_EXPORT NSString *const MCKickChannelName;
FOUNDATION_EXPORT NSString *const MCKickPusherURLString;
FOUNDATION_EXPORT NSTimeInterval const MCKickViewerPollInterval;
FOUNDATION_EXPORT NSTimeInterval const MCKickReconnectInitialDelay;
FOUNDATION_EXPORT NSTimeInterval const MCKickReconnectMaximumDelay;
FOUNDATION_EXPORT NSUInteger const MCKickMaximumVisibleMessages;

FOUNDATION_EXPORT BOOL MCKickConfigurationIsPlaceholder(void);

NS_ASSUME_NONNULL_END
