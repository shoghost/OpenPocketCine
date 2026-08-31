#import <Foundation/Foundation.h>

#import "MimoKickModels.h"

NS_ASSUME_NONNULL_BEGIN

@protocol MCKickClientDelegate <NSObject>
- (void)kickClientDidChangeState:(MCKickConnectionState)state
                         detail:(nullable NSString *)detail;
- (void)kickClientDidUpdateViewerCount:(nullable NSNumber *)viewerCount
                                isLive:(BOOL)isLive;
- (void)kickClientDidReceiveMessage:(MCKickMessage *)message;
- (void)kickClientDidDeleteMessageIdentifier:(NSString *)messageIdentifier;
- (void)kickClientDidDeleteMessagesForUserIdentifier:(NSString *)userIdentifier;
@end

/// Read-only Kick chat/status client. It is independent from every DJI camera path.
@interface MCKickClient : NSObject <NSURLSessionWebSocketDelegate>
@property(nonatomic, weak, nullable) id<MCKickClientDelegate> delegate;
- (void)start;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
