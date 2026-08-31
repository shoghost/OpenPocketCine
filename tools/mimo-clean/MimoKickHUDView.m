#import "MimoKickHUDView.h"

#import "MimoKickConfig.h"

#import <dispatch/dispatch.h>

@interface MCRemoteImageStore : NSObject
@property(nonatomic, strong) NSCache<NSURL *, UIImage *> *cache;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableSet<NSURL *> *inFlight;
+ (instancetype)sharedStore;
- (nullable UIImage *)imageForURL:(NSURL *)URL completion:(dispatch_block_t)completion;
@end

@implementation MCRemoteImageStore

+ (instancetype)sharedStore {
    static MCRemoteImageStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [MCRemoteImageStore new]; });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [NSCache new];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 10.0;
        _session = [NSURLSession sessionWithConfiguration:configuration];
        _inFlight = [NSMutableSet set];
    }
    return self;
}

- (nullable UIImage *)imageForURL:(NSURL *)URL completion:(dispatch_block_t)completion {
    UIImage *cached = [self.cache objectForKey:URL];
    if (cached != nil) return cached;
    if ([self.inFlight containsObject:URL]) return nil;
    [self.inFlight addObject:URL];
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:URL
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)response;
            UIImage *image = error == nil && data != nil ? [UIImage imageWithData:data] : nil;
            if (image != nil) [self.cache setObject:image forKey:URL];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.inFlight removeObject:URL];
                if (completion != nil) completion();
            });
        }];
    [task resume];
    return nil;
}

@end

@interface MCKickMessageCell : UITableViewCell
@property(nonatomic, strong) UILabel *messageLabel;
@end

@implementation MCKickMessageCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _messageLabel = [UILabel new];
        _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _messageLabel.numberOfLines = 0;
        _messageLabel.lineBreakMode = NSLineBreakByWordWrapping;
        _messageLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.42];
        _messageLabel.layer.cornerRadius = 4.0;
        _messageLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:_messageLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_messageLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_messageLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_messageLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:1.0],
            [_messageLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-1.0],
        ]];
    }
    return self;
}

@end

@interface MCKickHUDView () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSMutableArray<MCKickMessage *> *messages;
@property(nonatomic, assign) MCKickConnectionState connectionState;
@property(nonatomic, strong, nullable) NSNumber *viewerCount;
@property(nonatomic, assign) BOOL streamLive;
@property(nonatomic, copy, nullable) NSString *stateDetail;
@end

@implementation MCPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point;
    (void)event;
    return nil;
}

@end

@implementation MCKickHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO;
        _messages = [NSMutableArray array];
        _connectionState = MCKickConnectionStateConnecting;

        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
        _statusLabel.textColor = UIColor.whiteColor;
        _statusLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        _statusLabel.layer.cornerRadius = 4.0;
        _statusLabel.layer.masksToBounds = YES;
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_statusLabel];

        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.backgroundColor = UIColor.clearColor;
        _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        _tableView.showsVerticalScrollIndicator = NO;
        _tableView.userInteractionEnabled = NO;
        _tableView.estimatedRowHeight = 42.0;
        _tableView.rowHeight = UITableViewAutomaticDimension;
        _tableView.dataSource = self;
        _tableView.delegate = self;
        [_tableView registerClass:MCKickMessageCell.class forCellReuseIdentifier:@"KickMessage"];
        [self addSubview:_tableView];
        [self refreshStatusLabel];
    }
    return self;
}

- (void)updateForBounds:(CGRect)bounds safeArea:(UIEdgeInsets)safeArea
     previewFrameInRoot:(CGRect)previewFrame {
    NSAssert(NSThread.isMainThread, @"Kick HUD layout must run on the main thread");
    self.frame = bounds;
    CGFloat left = CGRectGetMinX(bounds) + MAX(8.0, safeArea.left);
    CGFloat top = CGRectGetMinY(bounds) + MAX(8.0, safeArea.top);
    CGFloat blackBandWidth = MAX(0.0, CGRectGetMinX(previewFrame) - left);
    CGFloat statusWidth = MIN(220.0, MAX(130.0, blackBandWidth - 8.0));
    statusWidth = MIN(statusWidth, CGRectGetWidth(bounds) - left - 8.0);
    self.statusLabel.frame = CGRectMake(left, top, statusWidth, 24.0);

    // The chat starts in the left black band but intentionally spans the screen. It is not
    // clipped to the band, allowing long comments and inline emotes to extend over the preview.
    CGFloat chatTop = CGRectGetMaxY(self.statusLabel.frame) + 5.0;
    CGFloat rightInset = MAX(8.0, safeArea.right);
    CGFloat bottomInset = MAX(8.0, safeArea.bottom);
    self.tableView.frame = CGRectMake(left, chatTop,
        MAX(1.0, CGRectGetWidth(bounds) - left - rightInset),
        MAX(1.0, CGRectGetHeight(bounds) - chatTop - bottomInset));
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.messages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MCKickMessageCell *cell = [tableView dequeueReusableCellWithIdentifier:@"KickMessage"
                                                              forIndexPath:indexPath];
    MCKickMessage *message = self.messages[(NSUInteger)indexPath.row];
    cell.messageLabel.attributedText = [self attributedTextForMessage:message];
    return cell;
}

- (NSAttributedString *)attributedTextForMessage:(MCKickMessage *)message {
    CGFloat fontSize = 15.0;
    UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightRegular];
    UIFont *bold = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    NSMutableAttributedString *result = [NSMutableAttributedString new];
    NSDictionary *plainAttributes = @{NSFontAttributeName: font,
                                      NSForegroundColorAttributeName: UIColor.whiteColor};
    if (message.replyUsername.length > 0 || message.replyText.length > 0) {
        NSString *reply = [NSString stringWithFormat:@"↪ %@: %@\n",
            message.replyUsername ?: @"", message.replyText ?: @""];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:reply
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12.0],
                         NSForegroundColorAttributeName: UIColor.lightGrayColor}]];
    }
    for (NSURL *badgeURL in message.badgeURLs) {
        [result appendAttributedString:[self attachmentForURL:badgeURL height:fontSize * 1.2]];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
    }
    for (NSString *label in message.badgeLabels) {
        NSString *badge = [NSString stringWithFormat:@"[%@] ", label];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:badge
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold],
                         NSForegroundColorAttributeName: UIColor.systemGreenColor}]];
    }
    UIColor *usernameColor = [self colorFromHex:message.userColorHex fallback:UIColor.systemGreenColor];
    [result appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@: ", message.username]
        attributes:@{NSFontAttributeName: bold, NSForegroundColorAttributeName: usernameColor}]];
    for (MCKickSegment *segment in message.segments) {
        if (segment.text != nil)
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:segment.text
                                                                           attributes:plainAttributes]];
        if (segment.imageURL != nil) {
            [result appendAttributedString:[self attachmentForURL:segment.imageURL height:fontSize * 1.45]];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
        }
    }
    return result;
}

- (NSAttributedString *)attachmentForURL:(NSURL *)URL height:(CGFloat)height {
    __weak typeof(self) weakSelf = self;
    UIImage *image = [MCRemoteImageStore.sharedStore imageForURL:URL completion:^{
        [weakSelf.tableView reloadData];
        [weakSelf scrollToLatestAnimated:NO];
    }];
    if (image == nil) return [[NSAttributedString alloc] initWithString:@"□"];
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = image;
    CGFloat width = image.size.height > 0.0 ? height * image.size.width / image.size.height : height;
    attachment.bounds = CGRectMake(0.0, -3.0, MIN(width, height * 2.5), height);
    return [NSAttributedString attributedStringWithAttachment:attachment];
}

- (UIColor *)colorFromHex:(NSString *)hex fallback:(UIColor *)fallback {
    NSString *value = [[hex stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"#"]] uppercaseString];
    if (value.length != 6) return fallback;
    unsigned int RGB = 0;
    if (![[NSScanner scannerWithString:value] scanHexInt:&RGB]) return fallback;
    return [UIColor colorWithRed:((RGB >> 16) & 0xFF) / 255.0
                           green:((RGB >> 8) & 0xFF) / 255.0
                            blue:(RGB & 0xFF) / 255.0 alpha:1.0];
}

- (void)scrollToLatestAnimated:(BOOL)animated {
    if (self.messages.count == 0) return;
    NSIndexPath *last = [NSIndexPath indexPathForRow:(NSInteger)self.messages.count - 1 inSection:0];
    [self.tableView scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionBottom
                                  animated:animated];
}

- (void)refreshStatusLabel {
    NSString *text = @"KICK CONNECTING";
    UIColor *color = UIColor.systemYellowColor;
    if (self.connectionState == MCKickConnectionStateConfigurationRequired) {
        text = @"KICK: SET CHANNEL";
        color = UIColor.systemOrangeColor;
    } else if (self.connectionState == MCKickConnectionStateOffline) {
        text = @"KICK OFFLINE";
        color = UIColor.lightGrayColor;
    } else if (self.connectionState == MCKickConnectionStateError) {
        text = @"KICK UNAVAILABLE";
        color = UIColor.systemRedColor;
    } else if (self.connectionState == MCKickConnectionStateConnected) {
        text = self.viewerCount == nil ? @"KICK LIVE" :
            [NSString stringWithFormat:@"KICK LIVE • %@ 👁", self.viewerCount];
        color = UIColor.systemGreenColor;
    }
    self.statusLabel.text = text;
    self.statusLabel.textColor = color;
    self.statusLabel.accessibilityValue = self.stateDetail;
}

- (void)kickClientDidChangeState:(MCKickConnectionState)state detail:(NSString *)detail {
    NSAssert(NSThread.isMainThread, @"Kick UI updates must run on the main thread");
    self.connectionState = state;
    self.stateDetail = detail;
    [self refreshStatusLabel];
}

- (void)kickClientDidUpdateViewerCount:(NSNumber *)viewerCount isLive:(BOOL)isLive {
    NSAssert(NSThread.isMainThread, @"Kick UI updates must run on the main thread");
    self.viewerCount = viewerCount;
    self.streamLive = isLive;
    if (isLive && self.connectionState != MCKickConnectionStateConnecting)
        self.connectionState = MCKickConnectionStateConnected;
    else if (!isLive && self.connectionState == MCKickConnectionStateConnected)
        self.connectionState = MCKickConnectionStateOffline;
    [self refreshStatusLabel];
}

- (void)kickClientDidReceiveMessage:(MCKickMessage *)message {
    NSAssert(NSThread.isMainThread, @"Kick UI updates must run on the main thread");
    [self.messages addObject:message];
    while (self.messages.count > MCKickMaximumVisibleMessages)
        [self.messages removeObjectAtIndex:0];
    [self.tableView reloadData];
    [self scrollToLatestAnimated:YES];
}

- (void)kickClientDidDeleteMessageIdentifier:(NSString *)messageIdentifier {
    NSIndexSet *indexes = [self.messages indexesOfObjectsPassingTest:
        ^BOOL(MCKickMessage *message, NSUInteger index, BOOL *stop) {
            (void)index; (void)stop;
            return [message.identifier isEqualToString:messageIdentifier];
        }];
    if (indexes.count > 0) {
        [self.messages removeObjectsAtIndexes:indexes];
        [self.tableView reloadData];
    }
}

- (void)kickClientDidDeleteMessagesForUserIdentifier:(NSString *)userIdentifier {
    NSIndexSet *indexes = [self.messages indexesOfObjectsPassingTest:
        ^BOOL(MCKickMessage *message, NSUInteger index, BOOL *stop) {
            (void)index; (void)stop;
            return [message.userIdentifier isEqualToString:userIdentifier];
        }];
    if (indexes.count > 0) {
        [self.messages removeObjectsAtIndexes:indexes];
        [self.tableView reloadData];
    }
}

@end
