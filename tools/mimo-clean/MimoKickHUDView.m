#import "MimoKickHUDView.h"

#import "MimoKickConfig.h"

#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#import <math.h>

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
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _messageLabel = [UILabel new];
        _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _messageLabel.numberOfLines = 0;
        _messageLabel.lineBreakMode = NSLineBreakByWordWrapping;
        _messageLabel.backgroundColor = UIColor.clearColor;
        _messageLabel.layer.masksToBounds = NO;
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
@property(nonatomic, strong) UIView *viewerBadgeView;
@property(nonatomic, strong) UILabel *kickMarkLabel;
@property(nonatomic, strong) UILabel *viewerLabel;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) CAGradientLayer *chatFadeMask;
@property(nonatomic, strong) NSMutableArray<MCKickMessage *> *messages;
@property(nonatomic, assign) MCKickConnectionState connectionState;
@property(nonatomic, assign) UIInterfaceOrientation lastLandscapeOrientation;
@property(nonatomic, strong, nullable) NSNumber *viewerCount;
@property(nonatomic, assign) BOOL streamLive;
@property(nonatomic, copy, nullable) NSString *stateDetail;
- (void)updateChatBottomInset;
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
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
        _messages = [NSMutableArray array];
        _connectionState = MCKickConnectionStateConnecting;
        _lastLandscapeOrientation = UIInterfaceOrientationLandscapeRight;

        _viewerBadgeView = [UIView new];
        _viewerBadgeView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.88];
        _viewerBadgeView.layer.cornerRadius = 5.0;
        _viewerBadgeView.layer.masksToBounds = YES;
        [self addSubview:_viewerBadgeView];

        _kickMarkLabel = [UILabel new];
        _kickMarkLabel.backgroundColor = [UIColor colorWithRed:0.32 green:1.0 blue:0.20 alpha:1.0];
        _kickMarkLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBlack];
        _kickMarkLabel.textColor = UIColor.blackColor;
        _kickMarkLabel.textAlignment = NSTextAlignmentCenter;
        _kickMarkLabel.text = @"K";
        [_viewerBadgeView addSubview:_kickMarkLabel];

        _viewerLabel = [UILabel new];
        _viewerLabel.font = [UIFont monospacedDigitSystemFontOfSize:17.0 weight:UIFontWeightBold];
        _viewerLabel.textColor = UIColor.whiteColor;
        _viewerLabel.textAlignment = NSTextAlignmentLeft;
        [_viewerBadgeView addSubview:_viewerLabel];

        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.backgroundColor = UIColor.clearColor;
        _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        _tableView.showsVerticalScrollIndicator = NO;
        _tableView.userInteractionEnabled = NO;
        _tableView.clipsToBounds = NO;
        if (@available(iOS 11.0, *))
            _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        _tableView.estimatedRowHeight = 42.0;
        _tableView.rowHeight = UITableViewAutomaticDimension;
        _tableView.dataSource = self;
        _tableView.delegate = self;
        [_tableView registerClass:MCKickMessageCell.class forCellReuseIdentifier:@"KickMessage"];
        [self addSubview:_tableView];

        _chatFadeMask = [CAGradientLayer layer];
        _chatFadeMask.colors = @[(id)UIColor.clearColor.CGColor,
                                 (id)[UIColor colorWithWhite:1.0 alpha:0.38].CGColor,
                                 (id)UIColor.whiteColor.CGColor];
        _chatFadeMask.locations = @[@0.0, @0.16, @0.32];
        _chatFadeMask.startPoint = CGPointMake(0.5, 0.0);
        _chatFadeMask.endPoint = CGPointMake(0.5, 1.0);
        _tableView.layer.mask = _chatFadeMask;
        [self refreshStatusLabel];
    }
    return self;
}

- (UIInterfaceOrientation)preferredLandscapeOrientation {
    UIDeviceOrientation deviceOrientation = UIDevice.currentDevice.orientation;
    if (deviceOrientation == UIDeviceOrientationLandscapeLeft)
        self.lastLandscapeOrientation = UIInterfaceOrientationLandscapeLeft;
    else if (deviceOrientation == UIDeviceOrientationLandscapeRight)
        self.lastLandscapeOrientation = UIInterfaceOrientationLandscapeRight;
    return self.lastLandscapeOrientation;
}

- (void)applyLandscapeCanvasForBounds:(CGRect)bounds {
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    self.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    if (width >= height) {
        self.transform = CGAffineTransformIdentity;
        self.bounds = CGRectMake(0.0, 0.0, width, height);
        return;
    }

    self.bounds = CGRectMake(0.0, 0.0, height, width);
    UIInterfaceOrientation orientation = [self preferredLandscapeOrientation];
    CGFloat angle = orientation == UIInterfaceOrientationLandscapeLeft ? M_PI_2 : -M_PI_2;
    self.transform = CGAffineTransformMakeRotation(angle);
}

- (void)layoutViewerBadgeAtLeft:(CGFloat)left top:(CGFloat)top {
    static const CGFloat badgeHeight = 30.0;
    static const CGFloat markWidth = 30.0;
    CGSize viewerSize = [self.viewerLabel sizeThatFits:CGSizeMake(180.0, badgeHeight)];
    CGFloat badgeWidth = markWidth + MAX(40.0, ceil(viewerSize.width) + 14.0);
    self.viewerBadgeView.frame = CGRectMake(left, top, badgeWidth, badgeHeight);
    self.kickMarkLabel.frame = CGRectMake(0.0, 0.0, markWidth, badgeHeight);
    self.viewerLabel.frame = CGRectMake(markWidth + 7.0, 0.0,
                                        badgeWidth - markWidth - 9.0, badgeHeight);
}

- (void)updateForBounds:(CGRect)bounds safeArea:(UIEdgeInsets)safeArea
     previewFrameInRoot:(CGRect)previewFrame {
    NSAssert(NSThread.isMainThread, @"Kick HUD layout must run on the main thread");
    (void)previewFrame;
    [self applyLandscapeCanvasForBounds:bounds];
    static const CGFloat MCKickHUDEdgePadding = 10.0;
    CGFloat canvasWidth = CGRectGetWidth(self.bounds);
    CGFloat canvasHeight = CGRectGetHeight(self.bounds);
    CGFloat left = MCKickHUDEdgePadding;
    CGFloat top = MCKickHUDEdgePadding;
    CGFloat right = MCKickHUDEdgePadding;
    CGFloat bottom = MCKickHUDEdgePadding;
    if (CGRectGetWidth(bounds) >= CGRectGetHeight(bounds)) {
        left = MAX(left, safeArea.left);
        top = MAX(top, safeArea.top);
        right = MAX(right, safeArea.right);
        bottom = MAX(bottom, safeArea.bottom);
    } else if ([self preferredLandscapeOrientation] == UIInterfaceOrientationLandscapeLeft) {
        left = MAX(left, safeArea.top);
        top = MAX(top, safeArea.right);
        right = MAX(right, safeArea.bottom);
        bottom = MAX(bottom, safeArea.left);
    } else {
        left = MAX(left, safeArea.bottom);
        top = MAX(top, safeArea.left);
        right = MAX(right, safeArea.top);
        bottom = MAX(bottom, safeArea.right);
    }
    [self layoutViewerBadgeAtLeft:left top:top];

    // Chat is bottom-anchored on a canonical landscape canvas. It spans the canvas width,
    // so long text can naturally continue from the black band over the preview.
    CGFloat chatHeight = floor(canvasHeight * (2.0 / 3.0));
    self.tableView.frame = CGRectMake(left,
                                      canvasHeight - bottom - chatHeight,
                                      MAX(1.0, canvasWidth - left - right),
                                      MAX(1.0, chatHeight));
    self.chatFadeMask.frame = self.tableView.bounds;
    [self updateChatBottomInset];
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
    NSShadow *textShadow = [NSShadow new];
    textShadow.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.9];
    textShadow.shadowOffset = CGSizeMake(0.0, 1.0);
    textShadow.shadowBlurRadius = 2.0;
    NSDictionary *plainAttributes = @{NSFontAttributeName: font,
                                      NSForegroundColorAttributeName: UIColor.whiteColor,
                                      NSShadowAttributeName: textShadow};
    if (message.replyUsername.length > 0 || message.replyText.length > 0) {
        NSString *reply = [NSString stringWithFormat:@"↪ %@: %@\n",
            message.replyUsername ?: @"", message.replyText ?: @""];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:reply
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12.0],
                         NSForegroundColorAttributeName: UIColor.lightGrayColor,
                         NSShadowAttributeName: textShadow}]];
    }
    for (NSURL *badgeURL in message.badgeURLs) {
        [result appendAttributedString:[self attachmentForURL:badgeURL height:fontSize * 1.2]];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
    }
    for (NSString *label in message.badgeLabels) {
        NSString *badge = [NSString stringWithFormat:@"[%@] ", label];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:badge
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold],
                         NSForegroundColorAttributeName: UIColor.systemGreenColor,
                         NSShadowAttributeName: textShadow}]];
    }
    UIColor *usernameColor = [self colorFromHex:message.userColorHex fallback:UIColor.systemGreenColor];
    [result appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@: ", message.username]
        attributes:@{NSFontAttributeName: bold,
                     NSForegroundColorAttributeName: usernameColor,
                     NSShadowAttributeName: textShadow}]];
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
    [self updateChatBottomInset];
    NSIndexPath *last = [NSIndexPath indexPathForRow:(NSInteger)self.messages.count - 1 inSection:0];
    [self.tableView scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionBottom
                                  animated:animated];
}

- (void)updateChatBottomInset {
    [self.tableView layoutIfNeeded];
    CGFloat topInset = MAX(0.0, CGRectGetHeight(self.tableView.bounds) -
                                self.tableView.contentSize.height);
    UIEdgeInsets inset = self.tableView.contentInset;
    if (fabs(inset.top - topInset) < 0.5) return;
    inset.top = topInset;
    self.tableView.contentInset = inset;
}

- (void)refreshStatusLabel {
    NSString *text = @"CONNECTING";
    UIColor *markColor = [UIColor colorWithRed:0.32 green:1.0 blue:0.20 alpha:1.0];
    if (self.connectionState == MCKickConnectionStateConfigurationRequired) {
        text = @"SET CHANNEL";
        markColor = UIColor.systemOrangeColor;
    } else if (self.connectionState == MCKickConnectionStateOffline) {
        text = @"OFFLINE";
        markColor = UIColor.darkGrayColor;
    } else if (self.connectionState == MCKickConnectionStateError) {
        text = @"UNAVAILABLE";
        markColor = UIColor.systemRedColor;
    } else if (self.connectionState == MCKickConnectionStateConnected) {
        text = self.viewerCount == nil ? @"LIVE" : self.viewerCount.stringValue;
    }
    self.kickMarkLabel.backgroundColor = markColor;
    self.viewerLabel.text = text;
    self.viewerLabel.accessibilityValue = self.stateDetail;
    [self setNeedsLayout];
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
        [self updateChatBottomInset];
        [self scrollToLatestAnimated:NO];
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
        [self updateChatBottomInset];
        [self scrollToLatestAnimated:NO];
    }
}

@end
