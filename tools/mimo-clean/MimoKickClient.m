#import "MimoKickClient.h"

#import "MimoKickConfig.h"

#import <dispatch/dispatch.h>

static NSString *const MCKickBadgeBaseURL =
    @"https://raw.githubusercontent.com/id3adeye/kickicons/refs/heads/main";

@interface MCKickClient ()
@property(nonatomic, strong) dispatch_queue_t stateQueue;
@property(nonatomic, strong) NSOperationQueue *sessionDelegateQueue;
@property(nonatomic, strong, nullable) NSURLSession *session;
@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *webSocketTask;
@property(nonatomic, strong, nullable) dispatch_source_t viewerTimer;
@property(nonatomic, strong, nullable) dispatch_source_t pingTimer;
@property(nonatomic, strong, nullable) dispatch_block_t reconnectBlock;
@property(nonatomic, copy, nullable) NSString *chatroomIdentifier;
@property(nonatomic, copy, nullable) NSString *chatroomChannelIdentifier;
@property(nonatomic, copy) NSArray<NSDictionary *> *subscriberBadges;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, assign) NSTimeInterval reconnectDelay;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, assign) BOOL socketOpen;
@property(nonatomic, assign) BOOL streamOnline;
@end

@implementation MCKickClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.mimoclean.kick-client", DISPATCH_QUEUE_SERIAL);
        _sessionDelegateQueue = [NSOperationQueue new];
        _sessionDelegateQueue.name = @"com.mimoclean.kick-urlsession";
        _sessionDelegateQueue.maxConcurrentOperationCount = 1;
        _subscriberBadges = @[];
        _reconnectDelay = MCKickReconnectInitialDelay;
    }
    return self;
}

- (void)start {
    dispatch_async(self.stateQueue, ^{
        if (self.running) return;
        self.running = YES;
        self.generation++;
        self.reconnectDelay = MCKickReconnectInitialDelay;
        if (MCKickConfigurationIsPlaceholder()) {
            [self publishState:MCKickConnectionStateConfigurationRequired
                        detail:@"Set MCKickChannelName"];
            return;
        }
        [self publishState:MCKickConnectionStateConnecting detail:nil];
        [self fetchChannelMetadataForGeneration:self.generation];
    });
}

- (void)stop {
    dispatch_async(self.stateQueue, ^{
        if (!self.running && self.session == nil) return;
        self.running = NO;
        self.generation++;
        [self cancelReconnect];
        [self cancelViewerTimer];
        [self cancelPingTimer];
        [self.webSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                                          reason:nil];
        self.webSocketTask = nil;
        self.socketOpen = NO;
        [self.session invalidateAndCancel];
        self.session = nil;
    });
}

- (void)cancelViewerTimer {
    if (self.viewerTimer == nil) return;
    dispatch_source_cancel(self.viewerTimer);
    self.viewerTimer = nil;
}

- (void)cancelPingTimer {
    if (self.pingTimer == nil) return;
    dispatch_source_cancel(self.pingTimer);
    self.pingTimer = nil;
}

- (void)publishState:(MCKickConnectionState)state detail:(NSString *)detail {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate kickClientDidChangeState:state detail:detail];
    });
}

- (void)publishViewerCount:(NSNumber *)viewerCount isLive:(BOOL)isLive {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate kickClientDidUpdateViewerCount:viewerCount isLive:isLive];
    });
}

- (NSURL *)channelMetadataURL {
    NSString *normalized = [MCKickChannelName stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    NSString *slug = [normalized stringByAddingPercentEncodingWithAllowedCharacters:
                      NSCharacterSet.URLPathAllowedCharacterSet];
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://kick.com/api/v1/channels/%@", slug]];
}

- (NSURLSession *)ensureSession {
    if (self.session == nil) {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 15.0;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        self.session = [NSURLSession sessionWithConfiguration:configuration
                                                     delegate:self
                                                delegateQueue:self.sessionDelegateQueue];
    }
    return self.session;
}

- (void)fetchChannelMetadataForGeneration:(NSUInteger)generation {
    if (!self.running || generation != self.generation) return;
    NSURL *URL = self.channelMetadataURL;
    if (URL == nil) {
        [self publishState:MCKickConnectionStateError detail:@"Invalid Kick channel"];
        [self scheduleViewerPollForGeneration:generation after:5.0];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSURLSessionDataTask *task = [[self ensureSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(self.stateQueue, ^{
                if (!self.running || generation != self.generation) return;
                NSHTTPURLResponse *HTTP = [response isKindOfClass:NSHTTPURLResponse.class]
                    ? (NSHTTPURLResponse *)response : nil;
                NSDictionary *JSON = data == nil ? nil :
                    [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (error != nil || HTTP.statusCode < 200 || HTTP.statusCode >= 300 ||
                    ![JSON isKindOfClass:NSDictionary.class]) {
                    NSString *detail = error.localizedDescription ?: @"Kick API unavailable";
                    [self publishState:MCKickConnectionStateError detail:detail];
                    [self publishViewerCount:nil isLive:NO];
                    [self scheduleViewerPollForGeneration:generation after:5.0];
                    return;
                }
                [self consumeChannelMetadata:JSON generation:generation];
            });
        }];
    [task resume];
}

- (void)consumeChannelMetadata:(NSDictionary *)JSON generation:(NSUInteger)generation {
    NSDictionary *chatroom = [JSON[@"chatroom"] isKindOfClass:NSDictionary.class] ? JSON[@"chatroom"] : nil;
    NSNumber *chatroomID = [chatroom[@"id"] isKindOfClass:NSNumber.class] ? chatroom[@"id"] : nil;
    NSNumber *channelID = [chatroom[@"channel_id"] isKindOfClass:NSNumber.class] ? chatroom[@"channel_id"] : nil;
    NSArray *badges = [JSON[@"subscriber_badges"] isKindOfClass:NSArray.class]
        ? JSON[@"subscriber_badges"] : @[];
    self.subscriberBadges = badges;
    self.chatroomIdentifier = chatroomID.stringValue;
    self.chatroomChannelIdentifier = channelID.stringValue;

    NSDictionary *livestream = [JSON[@"livestream"] isKindOfClass:NSDictionary.class]
        ? JSON[@"livestream"] : nil;
    NSNumber *viewers = [livestream[@"viewers"] isKindOfClass:NSNumber.class]
        ? livestream[@"viewers"] : nil;
    self.streamOnline = livestream != nil;
    [self publishViewerCount:viewers isLive:self.streamOnline];
    if (self.socketOpen) {
        [self publishState:self.streamOnline ? MCKickConnectionStateConnected
                                             : MCKickConnectionStateOffline
                    detail:nil];
    } else if (self.chatroomIdentifier.length > 0 && self.chatroomChannelIdentifier.length > 0 &&
               self.webSocketTask == nil) {
        [self connectWebSocketForGeneration:generation];
    }
    [self scheduleViewerPollForGeneration:generation after:MCKickViewerPollInterval];
}

- (void)scheduleViewerPollForGeneration:(NSUInteger)generation after:(NSTimeInterval)delay {
    [self cancelViewerTimer];
    if (!self.running || generation != self.generation) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.stateQueue);
    self.viewerTimer = timer;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        [self cancelViewerTimer];
        [self fetchChannelMetadataForGeneration:generation];
    });
    dispatch_resume(timer);
}

- (void)connectWebSocketForGeneration:(NSUInteger)generation {
    if (!self.running || generation != self.generation || self.webSocketTask != nil) return;
    NSURL *URL = [NSURL URLWithString:MCKickPusherURLString];
    if (URL == nil) {
        [self publishState:MCKickConnectionStateError detail:@"Invalid Kick WebSocket URL"];
        return;
    }
    [self publishState:MCKickConnectionStateConnecting detail:nil];
    self.webSocketTask = [[self ensureSession] webSocketTaskWithURL:URL];
    [self.webSocketTask resume];
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didOpenWithProtocol:(NSString *)protocol API_AVAILABLE(ios(13.0)) {
    (void)session;
    (void)protocol;
    dispatch_async(self.stateQueue, ^{
        if (!self.running || webSocketTask != self.webSocketTask) return;
        self.socketOpen = YES;
        self.reconnectDelay = MCKickReconnectInitialDelay;
        [self cancelReconnect];
        [self subscribeToKickChannels];
        [self receiveNextMessageFromTask:webSocketTask generation:self.generation];
        [self startPingTimerForGeneration:self.generation];
        [self publishState:self.streamOnline ? MCKickConnectionStateConnected
                                             : MCKickConnectionStateOffline
                    detail:nil];
    });
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
             reason:(NSData *)reason API_AVAILABLE(ios(13.0)) {
    (void)session;
    (void)closeCode;
    (void)reason;
    dispatch_async(self.stateQueue, ^{
        if (webSocketTask != self.webSocketTask) return;
        [self handleSocketFailure:nil generation:self.generation];
    });
}

- (void)subscribeToKickChannels {
    NSArray<NSString *> *channels = @[
        [NSString stringWithFormat:@"chatrooms.%@.v2", self.chatroomIdentifier],
        [NSString stringWithFormat:@"chatroom_%@", self.chatroomIdentifier],
        [NSString stringWithFormat:@"chatrooms.%@", self.chatroomIdentifier],
        [NSString stringWithFormat:@"predictions-channel-%@", self.chatroomIdentifier],
        [NSString stringWithFormat:@"channel_%@", self.chatroomChannelIdentifier],
    ];
    for (NSString *channel in channels) {
        NSDictionary *payload = @{@"event": @"pusher:subscribe",
                                  @"data": @{@"auth": @"", @"channel": channel}};
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        NSString *text = data == nil ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text != nil) [self sendString:text onTask:self.webSocketTask];
    }
}

- (void)sendString:(NSString *)string onTask:(NSURLSessionWebSocketTask *)task {
    if (task == nil) return;
    [task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:string]
       completionHandler:^(NSError *error) {
        if (error == nil) return;
        dispatch_async(self.stateQueue, ^{
            if (task == self.webSocketTask) [self handleSocketFailure:error generation:self.generation];
        });
    }];
}

- (void)receiveNextMessageFromTask:(NSURLSessionWebSocketTask *)task generation:(NSUInteger)generation {
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        dispatch_async(self.stateQueue, ^{
            if (!self.running || generation != self.generation || task != self.webSocketTask) return;
            if (error != nil) {
                [self handleSocketFailure:error generation:generation];
                return;
            }
            NSString *text = message.string;
            if (text == nil && message.data != nil)
                text = [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
            if (text != nil) [self consumePusherText:text];
            [self receiveNextMessageFromTask:task generation:generation];
        });
    }];
}

- (void)startPingTimerForGeneration:(NSUInteger)generation {
    [self cancelPingTimer];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.stateQueue);
    self.pingTimer = timer;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                              10 * NSEC_PER_SEC,
                              250 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        NSURLSessionWebSocketTask *task = self.webSocketTask;
        if (!self.running || generation != self.generation || task == nil) return;
        [task sendPingWithPongReceiveHandler:^(NSError *error) {
            if (error == nil) return;
            dispatch_async(self.stateQueue, ^{
                if (task == self.webSocketTask)
                    [self handleSocketFailure:error generation:generation];
            });
        }];
    });
    dispatch_resume(timer);
}

- (void)handleSocketFailure:(NSError *)error generation:(NSUInteger)generation {
    if (!self.running || generation != self.generation) return;
    [self cancelPingTimer];
    [self.webSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.webSocketTask = nil;
    self.socketOpen = NO;
    [self publishState:MCKickConnectionStateConnecting detail:error.localizedDescription];
    [self scheduleReconnectForGeneration:generation];
}

- (void)cancelReconnect {
    if (self.reconnectBlock != nil) {
        dispatch_block_cancel(self.reconnectBlock);
        self.reconnectBlock = nil;
    }
}

- (void)scheduleReconnectForGeneration:(NSUInteger)generation {
    [self cancelReconnect];
    NSTimeInterval delay = self.reconnectDelay;
    self.reconnectDelay = MIN(self.reconnectDelay * 2.0, MCKickReconnectMaximumDelay);
    __weak typeof(self) weakSelf = self;
    dispatch_block_t block = dispatch_block_create(0, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.running || generation != strongSelf.generation) return;
        strongSelf.reconnectBlock = nil;
        if (strongSelf.chatroomIdentifier.length == 0) {
            [strongSelf fetchChannelMetadataForGeneration:generation];
        } else {
            [strongSelf connectWebSocketForGeneration:generation];
        }
    });
    self.reconnectBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   self.stateQueue, block);
}

- (void)consumePusherText:(NSString *)text {
    NSData *outerData = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *outer = outerData == nil ? nil :
        [NSJSONSerialization JSONObjectWithData:outerData options:0 error:nil];
    if (![outer isKindOfClass:NSDictionary.class]) return;
    NSString *event = [outer[@"event"] isKindOfClass:NSString.class] ? outer[@"event"] : nil;
    if ([event isEqualToString:@"pusher:ping"]) {
        [self sendString:@"{\"event\":\"pusher:pong\",\"data\":{}}" onTask:self.webSocketTask];
        return;
    }
    id encodedData = outer[@"data"];
    NSDictionary *data = nil;
    if ([encodedData isKindOfClass:NSString.class]) {
        NSData *eventData = [(NSString *)encodedData dataUsingEncoding:NSUTF8StringEncoding];
        data = eventData == nil ? nil : [NSJSONSerialization JSONObjectWithData:eventData options:0 error:nil];
    } else if ([encodedData isKindOfClass:NSDictionary.class]) {
        data = encodedData;
    }
    if (![data isKindOfClass:NSDictionary.class] || event.length == 0) return;

    if ([event isEqualToString:@"App\\Events\\ChatMessageEvent"]) {
        [self consumeChatMessage:data];
    } else if ([event isEqualToString:@"App\\Events\\MessageDeletedEvent"]) {
        NSString *identifier = [data[@"message"] isKindOfClass:NSDictionary.class]
            ? data[@"message"][@"id"] : nil;
        if ([identifier isKindOfClass:NSString.class]) dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate kickClientDidDeleteMessageIdentifier:identifier];
        });
    } else if ([event isEqualToString:@"App\\Events\\UserBannedEvent"]) {
        NSNumber *identifier = [data[@"user"] isKindOfClass:NSDictionary.class]
            ? data[@"user"][@"id"] : nil;
        if ([identifier isKindOfClass:NSNumber.class]) dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate kickClientDidDeleteMessagesForUserIdentifier:identifier.stringValue];
        });
    } else if ([event isEqualToString:@"App\\Events\\SubscriptionEvent"]) {
        NSString *user = [self string:data[@"username"] fallback:@"Someone"];
        NSNumber *months = [data[@"months"] isKindOfClass:NSNumber.class] ? data[@"months"] : @0;
        [self publishEventKind:MCKickMessageKindSubscription user:user
                          text:[NSString stringWithFormat:@"subscribed for %@ month(s)", months]];
    } else if ([event isEqualToString:@"GiftedSubscriptionsEvent"]) {
        NSString *user = [self string:data[@"gifter_username"] fallback:@"Someone"];
        NSArray *users = [data[@"gifted_usernames"] isKindOfClass:NSArray.class] ? data[@"gifted_usernames"] : @[];
        NSNumber *total = [data[@"gifter_total"] isKindOfClass:NSNumber.class] ? data[@"gifter_total"] : @0;
        [self publishEventKind:MCKickMessageKindGiftSubscription user:user
                          text:[NSString stringWithFormat:@"gifted %lu sub(s) • %@ total",
                                (unsigned long)users.count, total]];
    } else if ([event isEqualToString:@"RewardRedeemedEvent"]) {
        NSString *user = [self string:data[@"username"] fallback:@"Someone"];
        NSString *title = [self string:data[@"reward_title"] fallback:@"a reward"];
        NSString *input = [self string:data[@"user_input"] fallback:@""];
        NSString *message = input.length == 0 ? [NSString stringWithFormat:@"redeemed %@", title]
            : [NSString stringWithFormat:@"redeemed %@: %@", title, input];
        [self publishEventKind:MCKickMessageKindReward user:user text:message];
    } else if ([event isEqualToString:@"App\\Events\\StreamHostEvent"]) {
        NSString *user = [self string:data[@"host_username"] fallback:@"Someone"];
        NSNumber *viewers = [data[@"number_viewers"] isKindOfClass:NSNumber.class]
            ? data[@"number_viewers"] : @0;
        [self publishEventKind:MCKickMessageKindHost user:user
                          text:[NSString stringWithFormat:@"is hosting with %@ viewers", viewers]];
    } else if ([event isEqualToString:@"KicksGifted"]) {
        NSDictionary *sender = [data[@"sender"] isKindOfClass:NSDictionary.class] ? data[@"sender"] : @{};
        NSDictionary *gift = [data[@"gift"] isKindOfClass:NSDictionary.class] ? data[@"gift"] : @{};
        NSString *user = [self string:sender[@"username"] fallback:@"Someone"];
        NSString *name = [self string:gift[@"name"] fallback:@"KICKs"];
        NSNumber *amount = [gift[@"amount"] isKindOfClass:NSNumber.class] ? gift[@"amount"] : @0;
        NSString *note = [self string:data[@"message"] fallback:@""];
        NSString *message = [NSString stringWithFormat:@"sent %@ 💎 %@%@", name, amount,
            note.length == 0 ? @"" : [@" • " stringByAppendingString:note]];
        [self publishEventKind:MCKickMessageKindKicks user:user text:message];
    }
}

- (NSString *)string:(id)value fallback:(NSString *)fallback {
    return [value isKindOfClass:NSString.class] ? value : fallback;
}

- (void)consumeChatMessage:(NSDictionary *)data {
    NSDictionary *sender = [data[@"sender"] isKindOfClass:NSDictionary.class] ? data[@"sender"] : @{};
    NSDictionary *identity = [sender[@"identity"] isKindOfClass:NSDictionary.class]
        ? sender[@"identity"] : @{};
    MCKickMessage *message = [MCKickMessage new];
    message.kind = MCKickMessageKindChat;
    message.identifier = [self string:data[@"id"] fallback:NSUUID.UUID.UUIDString];
    NSNumber *userID = [sender[@"id"] isKindOfClass:NSNumber.class] ? sender[@"id"] : nil;
    message.userIdentifier = userID.stringValue;
    message.username = [self string:sender[@"username"] fallback:@"Unknown"];
    message.userColorHex = [self string:identity[@"color"] fallback:@"#53FC18"];
    message.segments = [self segmentsForKickContent:[self string:data[@"content"] fallback:@""]];

    NSMutableArray<NSURL *> *badgeURLs = [NSMutableArray array];
    NSMutableArray<NSString *> *badgeLabels = [NSMutableArray array];
    NSArray *badgesV2 = [identity[@"badges_v2"] isKindOfClass:NSArray.class] ? identity[@"badges_v2"] : @[];
    for (NSDictionary *badge in badgesV2) {
        if (![badge isKindOfClass:NSDictionary.class] || ![badge[@"selected"] boolValue]) continue;
        NSURL *URL = [NSURL URLWithString:[self string:badge[@"image_url"] fallback:@""]];
        if (URL != nil) [badgeURLs addObject:URL];
    }
    NSArray *badges = [identity[@"badges"] isKindOfClass:NSArray.class] ? identity[@"badges"] : @[];
    for (NSDictionary *badge in badges) {
        if (![badge isKindOfClass:NSDictionary.class]) continue;
        NSString *type = [self string:badge[@"type"] fallback:@""];
        NSURL *URL = nil;
        if ([type isEqualToString:@"subscriber"] && [badge[@"count"] isKindOfClass:NSNumber.class]) {
            URL = [self subscriberBadgeURLForMonths:[badge[@"count"] integerValue]];
        } else {
            URL = [self staticBadgeURLForType:type];
        }
        if (URL != nil) [badgeURLs addObject:URL];
        else if (type.length > 0) [badgeLabels addObject:type.uppercaseString];
    }
    message.badgeURLs = badgeURLs;
    message.badgeLabels = badgeLabels;

    if ([[self string:data[@"type"] fallback:@""] isEqualToString:@"reply"]) {
        NSDictionary *metadata = [data[@"metadata"] isKindOfClass:NSDictionary.class] ? data[@"metadata"] : @{};
        NSDictionary *originalSender = [metadata[@"original_sender"] isKindOfClass:NSDictionary.class]
            ? metadata[@"original_sender"] : @{};
        NSDictionary *originalMessage = [metadata[@"original_message"] isKindOfClass:NSDictionary.class]
            ? metadata[@"original_message"] : @{};
        message.replyUsername = [self string:originalSender[@"username"] fallback:@""];
        message.replyText = [self string:originalMessage[@"content"] fallback:@""];
    }
    [self publishMessage:message];
}

- (NSArray<MCKickSegment *> *)segmentsForKickContent:(NSString *)content {
    NSMutableArray<MCKickSegment *> *segments = [NSMutableArray array];
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:@"\\[emote:(\\d+):[^\\]]+\\]" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [expression matchesInString:content options:0
                                                                     range:NSMakeRange(0, content.length)];
    NSUInteger location = 0;
    for (NSTextCheckingResult *match in matches) {
        if (match.range.location > location) {
            [segments addObject:[MCKickSegment textSegment:
                [content substringWithRange:NSMakeRange(location, match.range.location - location)]]];
        }
        NSString *emoteID = [content substringWithRange:[match rangeAtIndex:1]];
        NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:
            @"https://files.kick.com/emotes/%@/fullsize", emoteID]];
        if (URL != nil) [segments addObject:[MCKickSegment imageSegment:URL]];
        location = NSMaxRange(match.range);
    }
    if (location < content.length)
        [segments addObject:[MCKickSegment textSegment:[content substringFromIndex:location]]];
    if (segments.count == 0) [segments addObject:[MCKickSegment textSegment:content]];
    return segments;
}

- (NSURL *)subscriberBadgeURLForMonths:(NSInteger)months {
    NSURL *best = nil;
    NSInteger bestMonths = NSIntegerMin;
    for (NSDictionary *badge in self.subscriberBadges) {
        if (![badge isKindOfClass:NSDictionary.class]) continue;
        NSNumber *candidateMonths = [badge[@"months"] isKindOfClass:NSNumber.class] ? badge[@"months"] : nil;
        NSDictionary *image = [badge[@"badge_image"] isKindOfClass:NSDictionary.class] ? badge[@"badge_image"] : nil;
        NSURL *URL = [NSURL URLWithString:[self string:image[@"src"] fallback:@""]];
        if (candidateMonths != nil && URL != nil && candidateMonths.integerValue <= months &&
            candidateMonths.integerValue > bestMonths) {
            bestMonths = candidateMonths.integerValue;
            best = URL;
        }
    }
    return best;
}

- (NSURL *)staticBadgeURLForType:(NSString *)type {
    NSSet<NSString *> *known = [NSSet setWithArray:@[@"verified", @"staff", @"moderator", @"og",
        @"vip", @"bot", @"broadcaster", @"founder", @"sub_gifter"]];
    if (![known containsObject:type]) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/kick-%@.png", MCKickBadgeBaseURL, type]];
}

- (void)publishEventKind:(MCKickMessageKind)kind user:(NSString *)user text:(NSString *)text {
    MCKickMessage *message = [MCKickMessage new];
    message.kind = kind;
    message.username = user;
    message.segments = @[[MCKickSegment textSegment:text]];
    [self publishMessage:message];
}

- (void)publishMessage:(MCKickMessage *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate kickClientDidReceiveMessage:message];
    });
}

@end
