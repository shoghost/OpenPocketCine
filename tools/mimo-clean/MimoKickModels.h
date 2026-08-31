#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MCKickConnectionState) {
    MCKickConnectionStateConfigurationRequired,
    MCKickConnectionStateConnecting,
    MCKickConnectionStateConnected,
    MCKickConnectionStateOffline,
    MCKickConnectionStateError,
};

typedef NS_ENUM(NSInteger, MCKickMessageKind) {
    MCKickMessageKindChat,
    MCKickMessageKindSubscription,
    MCKickMessageKindGiftSubscription,
    MCKickMessageKindReward,
    MCKickMessageKindHost,
    MCKickMessageKindKicks,
    MCKickMessageKindSystem,
};

@interface MCKickSegment : NSObject
@property(nonatomic, copy, nullable) NSString *text;
@property(nonatomic, strong, nullable) NSURL *imageURL;
+ (instancetype)textSegment:(NSString *)text;
+ (instancetype)imageSegment:(NSURL *)URL;
@end

@interface MCKickMessage : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy, nullable) NSString *userIdentifier;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) NSString *userColorHex;
@property(nonatomic, copy) NSArray<NSURL *> *badgeURLs;
@property(nonatomic, copy) NSArray<NSString *> *badgeLabels;
@property(nonatomic, copy) NSArray<MCKickSegment *> *segments;
@property(nonatomic, copy, nullable) NSString *replyUsername;
@property(nonatomic, copy, nullable) NSString *replyText;
@property(nonatomic, assign) MCKickMessageKind kind;
@property(nonatomic, strong) NSDate *receivedAt;
@end

NS_ASSUME_NONNULL_END
