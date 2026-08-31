#import "MimoCleanController.h"

#import "MimoKickClient.h"
#import "MimoKickHUDView.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <math.h>

typedef NS_ENUM(NSInteger, MCCleanClassification) {
    MCCleanClassificationKeep,
    MCCleanClassificationHide,
    MCCleanClassificationUnknown,
};

static NSString *const MCUserHideClassesKey = @"MimoClean.UserHideClassNames.v1";

@interface MCMimoCleanController ()
@property(nonatomic, strong) NSMapTable<UIView *, NSNumber *> *originalHiddenStates;
@property(nonatomic, strong) NSMapTable<UIView *, NSNumber *> *classifications;
@property(nonatomic, strong) NSMutableSet<NSString *> *userHideClassNames;
@property(nonatomic, strong) NSTimer *monitorTimer;
@property(nonatomic, weak) UIView *cleanPreviewView;
@property(nonatomic, weak) UIView *cleanRootView;
@property(nonatomic, weak) UIView *cleanPreviewSuperview;
@property(nonatomic, weak) UIView *cleanPreviewLayoutView;
@property(nonatomic, weak) UIView *cleanPreviewLayoutSuperview;
@property(nonatomic, weak) UIViewController *cleanLiveViewController;
@property(nonatomic, assign) CGRect cleanPreviewBounds;
@property(nonatomic, assign) CGAffineTransform cleanPreviewTransform;
@property(nonatomic, assign) CGRect cleanPreviewLayoutBounds;
@property(nonatomic, assign) CGAffineTransform cleanPreviewLayoutTransform;
@property(nonatomic, assign) CGPoint originalPreviewCenter;
@property(nonatomic, assign) BOOL cleanModeEnabled;
@property(nonatomic, assign) NSUInteger keepCount;
@property(nonatomic, assign) NSUInteger hideCount;
@property(nonatomic, assign) NSUInteger unknownCount;
@property(nonatomic, strong) MCKickClient *kickClient;
@property(nonatomic, strong) MCKickHUDView *kickHUD;
@property(nonatomic, strong) MCPassthroughWindow *overlayWindow;
@property(nonatomic, strong) UIViewController *overlayViewController;
@end

@implementation MCMimoCleanController

+ (instancetype)sharedController {
    static MCMimoCleanController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ controller = [MCMimoCleanController new]; });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _originalHiddenStates = [NSMapTable weakToStrongObjectsMapTable];
        _classifications = [NSMapTable weakToStrongObjectsMapTable];
        NSArray<NSString *> *stored = [NSUserDefaults.standardUserDefaults arrayForKey:MCUserHideClassesKey];
        _userHideClassNames = [NSMutableSet setWithArray:stored ?: @[]];
        _kickClient = [MCKickClient new];
        _kickHUD = [[MCKickHUDView alloc] initWithFrame:CGRectZero];
        _kickClient.delegate = _kickHUD;
    }
    return self;
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"MimoClean must start on the main thread");
    if (self.monitorTimer != nil) return;
    [self.kickClient start];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    if (@available(iOS 13.0, *)) {
        [center addObserver:self selector:@selector(applicationDidBecomeActive:)
                       name:UISceneDidActivateNotification object:nil];
    }
    self.monitorTimer = [NSTimer timerWithTimeInterval:0.5 target:self
                                              selector:@selector(streamingLayoutTick:)
                                              userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.monitorTimer forMode:NSRunLoopCommonModes];
    [self streamingLayoutTick:self.monitorTimer];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self streamingLayoutTick:self.monitorTimer];
}

- (NSArray<UIWindow *> *)applicationWindows {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) {
                [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
    } else {
        [windows addObjectsFromArray:UIApplication.sharedApplication.windows];
    }
    return windows;
}

- (UIViewController *)findViewControllerNamed:(NSString *)className
                            fromViewController:(UIViewController *)viewController {
    if (viewController == nil) return nil;
    if ([NSStringFromClass(viewController.class) isEqualToString:className]) return viewController;
    UIViewController *presented = [self findViewControllerNamed:className
                                             fromViewController:viewController.presentedViewController];
    if (presented != nil) return presented;
    for (UIViewController *child in [viewController childViewControllers]) {
        UIViewController *match = [self findViewControllerNamed:className fromViewController:child];
        if (match != nil) return match;
    }
    return nil;
}

- (UIViewController *)liveViewController {
    for (UIWindow *window in self.applicationWindows.reverseObjectEnumerator) {
        UIViewController *match = [self findViewControllerNamed:@"DJIHG2X0FPVViewController"
                                             fromViewController:window.rootViewController];
        if (match != nil) return match;
    }
    return nil;
}

- (UIView *)findPreviewInView:(UIView *)view {
    if ([NSStringFromClass(view.class) isEqualToString:@"DJIGLImageViewCupertino"] &&
        [NSStringFromClass(view.layer.class) isEqualToString:@"CAEAGLLayer"]) return view;
    for (UIView *subview in view.subviews) {
        UIView *match = [self findPreviewInView:subview];
        if (match != nil) return match;
    }
    return nil;
}

- (UIView *)ancestorNamed:(NSString *)className fromView:(UIView *)view root:(UIView *)root {
    for (UIView *candidate = view; candidate != nil; candidate = candidate.superview) {
        if ([NSStringFromClass(candidate.class) isEqualToString:className]) return candidate;
        if (candidate == root) break;
    }
    return nil;
}

- (void)streamingLayoutTick:(NSTimer *)timer {
    (void)timer;
    NSAssert(NSThread.isMainThread, @"Mimo streaming layout must run on the main thread");
    UIViewController *controller = self.cleanModeEnabled ? self.cleanLiveViewController
                                                         : [self liveViewController];
    UIView *root = self.cleanModeEnabled ? self.cleanRootView : controller.view;
    UIView *preview = self.cleanModeEnabled ? self.cleanPreviewView
                                            : (root == nil ? nil : [self findPreviewInView:root]);
    if (controller == nil || root == nil || preview == nil || preview.window == nil) {
        if (self.cleanModeEnabled) [self restoreAllShowingToast:NO];
        self.overlayWindow.hidden = YES;
        return;
    }

    BOOL changedLiveView = controller != self.cleanLiveViewController ||
                           preview != self.cleanPreviewView;
    if (changedLiveView) {
        if (self.cleanModeEnabled) [self restoreAllShowingToast:NO];
        [self applyCleanMode];
        return;
    }

    if (![self previewIsIntact:preview]) {
        [self restoreAllShowingToast:NO];
        NSLog(@"[MimoClean] safety restore: preview renderer changed unexpectedly");
        return;
    }

    [self alignPreviewToRightEdge];
    [self updateKickOverlayForPreview:preview root:root];
}

- (BOOL)view:(UIView *)view containsView:(UIView *)target {
    return view == target || [target isDescendantOfView:view];
}

- (NSSet<UIView *> *)previewKeepSetFromView:(UIView *)preview root:(UIView *)root {
    NSMutableSet<UIView *> *keepSet = [NSMutableSet set];
    UIView *view = preview;
    while (view != nil) {
        [keepSet addObject:view];
        if (view == root) break;
        view = view.superview;
    }
    return keepSet;
}

- (BOOL)subtreeContainsLayerNamed:(NSString *)className view:(UIView *)view {
    if ([NSStringFromClass(view.layer.class) isEqualToString:className]) return YES;
    for (UIView *subview in view.subviews)
        if ([self subtreeContainsLayerNamed:className view:subview]) return YES;
    return NO;
}

- (BOOL)subtreeContainsViewClassNamed:(NSString *)className view:(UIView *)view {
    if ([NSStringFromClass(view.class) isEqualToString:className]) return YES;
    for (UIView *subview in view.subviews)
        if ([self subtreeContainsViewClassNamed:className view:subview]) return YES;
    return NO;
}

- (BOOL)isProtectedBranch:(UIView *)view preview:(UIView *)preview keepSet:(NSSet<UIView *> *)keepSet {
    return [keepSet containsObject:view] || [self view:view containsView:preview] ||
           [self subtreeContainsLayerNamed:@"CAEAGLLayer" view:view] ||
           [self subtreeContainsViewClassNamed:@"DJIAC103PreviewView" view:view] ||
           [self subtreeContainsViewClassNamed:@"DJIAC103TopPresentView" view:view] ||
           [self subtreeContainsViewClassNamed:@"DJICobraTouchView" view:view] ||
           [self subtreeContainsViewClassNamed:@"UITransitionView" view:view];
}

- (BOOL)isUIKitControlBranch:(UIView *)view {
    return [view isKindOfClass:UIControl.class] || [view isKindOfClass:UILabel.class] ||
           [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UISlider.class] ||
           [view isKindOfClass:UIScrollView.class] || [view isKindOfClass:UICollectionView.class] ||
           [view isKindOfClass:UITableView.class];
}

- (BOOL)viewMatchesKnownOperationAsset:(UIView *)view {
    if (![view isKindOfClass:UIImageView.class]) return NO;
    UIImageView *imageView = (UIImageView *)view;
    NSString *description = [NSString stringWithFormat:@"%@ %@ %@", NSStringFromClass(view.class),
        view.accessibilityIdentifier ?: @"", imageView.image.description ?: @""].lowercaseString;
    NSArray<NSString *> *assetNames = @[@"idle_record_video_image", @"user_guide_fpv_icon",
        @"hg200_bottombar_microphone", @"uisit_sound_volume_off", @"fpvplayback",
        @"custom_mode_enter"];
    for (NSString *assetName in assetNames)
        if ([description containsString:assetName]) return YES;
    return NO;
}

- (BOOL)classNameHasUIOnlyKeyword:(NSString *)className {
    NSString *lower = className.lowercaseString;
    NSArray<NSString *> *keywords = @[@"setting", @"osd", @"button", @"mode", @"capture",
        @"resolution", @"icon", @"guide", @"slider", @"mirror", @"record", @"battery",
        @"wifi", @"remaining", @"exposure", @"shutter", @"iso", @"evview"];
    for (NSString *keyword in keywords) if ([lower containsString:keyword]) return YES;
    return NO;
}

- (void)subtreeStatsForView:(UIView *)view total:(NSUInteger *)total controls:(NSUInteger *)controls {
    (*total)++;
    if ([self isUIKitControlBranch:view]) (*controls)++;
    for (UIView *subview in view.subviews) [self subtreeStatsForView:subview total:total controls:controls];
}

- (MCCleanClassification)classificationForView:(UIView *)view root:(UIView *)root
                                         preview:(UIView *)preview keepSet:(NSSet<UIView *> *)keepSet {
    if (view == root || [self isProtectedBranch:view preview:preview keepSet:keepSet])
        return MCCleanClassificationKeep;
    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"DJIAC103SettingFloorView"] ||
        [self.userHideClassNames containsObject:className])
        return MCCleanClassificationHide;
    CGRect frameInRoot = [view convertRect:view.bounds toView:root];
    CGFloat rootArea = CGRectGetWidth(root.bounds) * CGRectGetHeight(root.bounds);
    CGFloat viewArea = CGRectGetWidth(frameInRoot) * CGRectGetHeight(frameInRoot);
    BOOL largeContainer = rootArea > 0.0 && viewArea / rootArea >= 0.75;
    if (largeContainer) return MCCleanClassificationUnknown;
    if ([className isEqualToString:@"DJIAC103OSDView"] ||
        [className isEqualToString:@"DJILiveviewMirrorContainerView"] ||
        [self viewMatchesKnownOperationAsset:view] || [self isUIKitControlBranch:view] ||
        [self classNameHasUIOnlyKeyword:className])
        return MCCleanClassificationHide;
    NSUInteger total = 0, controls = 0;
    [self subtreeStatsForView:view total:&total controls:&controls];
    BOOL compactOperationContainer = rootArea > 0.0 && viewArea / rootArea <= 0.35 &&
                                     total <= 40 && controls > 0;
    if (!largeContainer && total > 0 && controls > 0 &&
        (controls * 2 >= total || compactOperationContainer))
        return MCCleanClassificationHide;
    return MCCleanClassificationUnknown;
}

- (void)scanView:(UIView *)view root:(UIView *)root preview:(UIView *)preview keepSet:(NSSet<UIView *> *)keepSet {
    MCCleanClassification value = [self classificationForView:view root:root preview:preview keepSet:keepSet];
    [self.classifications setObject:@(value) forKey:view];
    if (value == MCCleanClassificationKeep) self.keepCount++;
    else if (value == MCCleanClassificationHide) self.hideCount++;
    else self.unknownCount++;
    for (UIView *subview in view.subviews) [self scanView:subview root:root preview:preview keepSet:keepSet];
}

- (BOOL)scanCurrentLiveViewSuppressingNothing:(BOOL)showFailure {
    UIViewController *controller = [self liveViewController];
    UIView *root = controller.view;
    UIView *preview = root == nil ? nil : [self findPreviewInView:root];
    if (controller == nil || root == nil || preview == nil) {
        if (showFailure) NSLog(@"[MimoClean] LiveView preview not found");
        return NO;
    }
    [self.classifications removeAllObjects];
    self.keepCount = self.hideCount = self.unknownCount = 0;
    NSSet<UIView *> *keepSet = [self previewKeepSetFromView:preview root:root];
    [self scanView:root root:root preview:preview keepSet:keepSet];
    return YES;
}

- (void)recordAndSuppressView:(UIView *)view {
    if ([self.originalHiddenStates objectForKey:view] == nil)
        [self.originalHiddenStates setObject:@(view.hidden) forKey:view];
    view.hidden = YES;
}

- (void)applyClassifiedBranchesInView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        NSNumber *stored = [self.classifications objectForKey:subview];
        MCCleanClassification value = stored == nil ? MCCleanClassificationUnknown : stored.integerValue;
        if (value == MCCleanClassificationHide) [self recordAndSuppressView:subview];
        else
            [self applyClassifiedBranchesInView:subview];
    }
}

- (void)applyCleanMode {
    NSAssert(NSThread.isMainThread, @"MimoClean apply must run on the main thread");
    UIViewController *controller = [self liveViewController];
    UIView *root = controller.view;
    UIView *preview = root == nil ? nil : [self findPreviewInView:root];
    if (controller == nil || root == nil || preview == nil || ![self scanCurrentLiveViewSuppressingNothing:YES]) return;
    self.cleanLiveViewController = controller; self.cleanRootView = root;
    self.cleanPreviewView = preview; self.cleanPreviewSuperview = preview.superview;
    UIView *layoutView = [self ancestorNamed:@"DJIAC103PreviewView" fromView:preview root:root] ?: preview;
    self.cleanPreviewLayoutView = layoutView;
    self.cleanPreviewLayoutSuperview = layoutView.superview;
    self.cleanPreviewBounds = preview.bounds;
    self.cleanPreviewTransform = preview.transform;
    self.cleanPreviewLayoutBounds = layoutView.bounds;
    self.cleanPreviewLayoutTransform = layoutView.transform;
    self.originalPreviewCenter = layoutView.center;
    [self applyClassifiedBranchesInView:root];
    self.cleanModeEnabled = YES;
    [self alignPreviewToRightEdge];
    [self updateKickOverlayForPreview:preview root:root];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.cleanModeEnabled && ![self previewIsIntact:self.cleanPreviewView]) {
            [self restoreAllShowingToast:NO];
            NSLog(@"[MimoClean] safety restore: preview renderer changed unexpectedly");
        }
    });
}

- (BOOL)previewIsIntact:(UIView *)preview {
    UIView *layoutView = self.cleanPreviewLayoutView;
    if (preview == nil || preview.window == nil || preview.superview != self.cleanPreviewSuperview ||
        ![preview isDescendantOfView:self.cleanRootView] || preview.alpha <= 0.0 || preview.hidden ||
        ![NSStringFromClass(preview.layer.class) isEqualToString:@"CAEAGLLayer"] ||
        !CGRectEqualToRect(preview.bounds, self.cleanPreviewBounds) ||
        !CGAffineTransformEqualToTransform(preview.transform, self.cleanPreviewTransform)) return NO;
    if (layoutView == nil || layoutView.superview != self.cleanPreviewLayoutSuperview ||
        !CGRectEqualToRect(layoutView.bounds, self.cleanPreviewLayoutBounds) ||
        !CGAffineTransformEqualToTransform(layoutView.transform, self.cleanPreviewLayoutTransform)) return NO;
    for (UIView *ancestor = preview; ancestor != nil; ancestor = ancestor.superview) {
        if (ancestor.alpha <= 0.0 || ancestor.hidden) return NO;
        if (ancestor == self.cleanRootView) return YES;
    }
    return NO;
}

- (void)alignPreviewToRightEdge {
    UIView *preview = self.cleanPreviewView;
    UIView *root = self.cleanRootView;
    UIView *layoutView = self.cleanPreviewLayoutView;
    UIView *layoutSuperview = layoutView.superview;
    if (preview == nil || root == nil || layoutView == nil || layoutSuperview == nil) return;
    CGRect frameInRoot = [preview convertRect:preview.bounds toView:root];
    CGFloat deltaX = CGRectGetMaxX(root.bounds) - CGRectGetMaxX(frameInRoot);
    if (fabs(deltaX) < 0.5) return;

    // Move the known DJI preview container as a unit so renderer/touch descendants stay aligned.
    // Bounds, transform, CAEAGLLayer, aspect ratio and FOV are untouched.
    CGPoint centerInRoot = [layoutSuperview convertPoint:layoutView.center toView:root];
    centerInRoot.x += deltaX;
    layoutView.center = [root convertPoint:centerInRoot toView:layoutSuperview];
}

- (void)updateKickOverlayForPreview:(UIView *)preview root:(UIView *)root {
    UIWindow *sourceWindow = root.window;
    if (sourceWindow == nil) return;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = sourceWindow.windowScene;
        if (scene == nil) return;
        if (self.overlayWindow == nil || self.overlayWindow.windowScene != scene) {
            self.overlayWindow.hidden = YES;
            self.overlayViewController = [UIViewController new];
            self.overlayViewController.view.backgroundColor = UIColor.clearColor;
            self.overlayWindow = [[MCPassthroughWindow alloc] initWithWindowScene:scene];
            self.overlayWindow.backgroundColor = UIColor.clearColor;
            self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 1.0;
            self.overlayWindow.rootViewController = self.overlayViewController;
            [self.overlayViewController.view addSubview:self.kickHUD];
        }
    } else if (self.overlayWindow == nil) {
        self.overlayViewController = [UIViewController new];
        self.overlayViewController.view.backgroundColor = UIColor.clearColor;
        self.overlayWindow = [[MCPassthroughWindow alloc] initWithFrame:sourceWindow.bounds];
        self.overlayWindow.backgroundColor = UIColor.clearColor;
        self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 1.0;
        self.overlayWindow.rootViewController = self.overlayViewController;
        [self.overlayViewController.view addSubview:self.kickHUD];
    }
    self.overlayWindow.frame = sourceWindow.bounds;
    self.overlayViewController.view.frame = self.overlayWindow.bounds;
    CGRect previewInWindow = [preview convertRect:preview.bounds toView:sourceWindow];
    [self.kickHUD updateForBounds:self.overlayViewController.view.bounds
                        safeArea:sourceWindow.safeAreaInsets
              previewFrameInRoot:previewInWindow];
    self.overlayWindow.hidden = NO;
}

- (void)restoreAllShowingToast:(BOOL)showToast {
    NSAssert(NSThread.isMainThread, @"MimoClean restore must run on the main thread");
    NSEnumerator<UIView *> *enumerator = self.originalHiddenStates.keyEnumerator;
    for (UIView *view = enumerator.nextObject; view != nil; view = enumerator.nextObject) {
        NSNumber *hidden = [self.originalHiddenStates objectForKey:view];
        if (hidden != nil) view.hidden = hidden.boolValue;
    }
    [self.originalHiddenStates removeAllObjects];
    if (self.cleanPreviewLayoutView != nil && self.cleanPreviewLayoutSuperview != nil)
        self.cleanPreviewLayoutView.center = self.originalPreviewCenter;
    self.cleanModeEnabled = NO; self.cleanLiveViewController = nil;
    self.cleanPreviewView = nil; self.cleanRootView = nil;
    self.cleanPreviewSuperview = nil;
    self.cleanPreviewLayoutView = nil;
    self.cleanPreviewLayoutSuperview = nil;
    self.overlayWindow.hidden = YES;
    if (showToast) NSLog(@"[MimoClean] Mimo UI restored");
}

@end
