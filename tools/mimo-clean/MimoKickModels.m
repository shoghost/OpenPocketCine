#import "MimoKickModels.h"

@implementation MCKickSegment

+ (instancetype)textSegment:(NSString *)text {
    MCKickSegment *segment = [MCKickSegment new];
    segment.text = text;
    return segment;
}

+ (instancetype)imageSegment:(NSURL *)URL {
    MCKickSegment *segment = [MCKickSegment new];
    segment.imageURL = URL;
    return segment;
}

@end

@implementation MCKickMessage

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = NSUUID.UUID.UUIDString;
        _username = @"Kick";
        _userColorHex = @"#53FC18";
        _badgeURLs = @[];
        _badgeLabels = @[];
        _segments = @[];
        _receivedAt = [NSDate date];
    }
    return self;
}

@end
