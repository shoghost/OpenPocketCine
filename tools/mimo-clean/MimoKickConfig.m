#import "MimoKickConfig.h"

// Change this one value to the Kick channel slug used by the streaming HUD.
NSString *const MCKickChannelName = @"kerokero9";

// Matches Moblin's current unauthenticated Kick/Pusher chat transport.
NSString *const MCKickPusherURLString =
    @"wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=js&version=7.6.0&flash=false";

NSTimeInterval const MCKickViewerPollInterval = 30.0;
NSTimeInterval const MCKickReconnectInitialDelay = 0.5;
NSTimeInterval const MCKickReconnectMaximumDelay = 10.0;
NSUInteger const MCKickMaximumVisibleMessages = 80;

BOOL MCKickConfigurationIsPlaceholder(void) {
    return MCKickChannelName.length == 0 ||
           [MCKickChannelName isEqualToString:@"REPLACE_WITH_KICK_CHANNEL"];
}
