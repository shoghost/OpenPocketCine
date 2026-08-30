#import "MimoCleanController.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>

typedef NS_ENUM(NSInteger, MCCleanClassification) {
    MCCleanClassificationKeep,
    MCCleanClassificationHide,
    MCCleanClassificationUnknown,
};

static NSString *const MCUserHideClassesKey = @"MimoClean.UserHideClassNames.v1";

@interface MCCleanOverlayWindow : UIWindow
@end

@implementation MCCleanOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = [super hitTest:point withEvent:event];
    return view == self.rootViewController.view ? nil : view;
}
@end

@interface MCMimoCleanController () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) NSMapTable<UIView *, NSNumber *> *originalAlphas;
@property(nonatomic, strong) NSMapTable<UIView *, NSNumber *> *classifications;
@property(nonatomic, strong) NSMutableSet<NSString *> *userHideClassNames;
@property(nonatomic, strong) NSMutableSet<NSString *> *inspectedRuntimeClasses;
@property(nonatomic, strong) NSTimer *housekeepingTimer;
@property(nonatomic, strong) MCCleanOverlayWindow *overlayWindow;
@property(nonatomic, strong) UIButton *cleanButton;
@property(nonatomic, strong) UILabel *toastLabel;
@property(nonatomic, strong) NSArray<UIView *> *restoreGestureAreas;
@property(nonatomic, weak) UIView *cleanPreviewView;
@property(nonatomic, weak) UIView *cleanRootView;
@property(nonatomic, weak) UIView *cleanPreviewSuperview;
@property(nonatomic, assign) CGRect cleanPreviewFrame;
@property(nonatomic, assign) CGRect cleanPreviewBounds;
@property(nonatomic, assign) CGAffineTransform cleanPreviewTransform;
@property(nonatomic, assign) BOOL cleanModeEnabled;
@property(nonatomic, assign) BOOL suppressNextCleanTap;
@property(nonatomic, assign) NSUInteger keepCount;
@property(nonatomic, assign) NSUInteger hideCount;
@property(nonatomic, assign) NSUInteger unknownCount;
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
        _originalAlphas = [NSMapTable weakToStrongObjectsMapTable];
        _classifications = [NSMapTable weakToStrongObjectsMapTable];
        _inspectedRuntimeClasses = [NSMutableSet set];
        NSArray<NSString *> *stored = [NSUserDefaults.standardUserDefaults arrayForKey:MCUserHideClassesKey];
        _userHideClassNames = [NSMutableSet setWithArray:stored ?: @[]];
    }
    return self;
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"MimoClean must start on the main thread");
    if (self.housekeepingTimer != nil) return;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(applicationBecameActive:)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    if (@available(iOS 13.0, *)) {
        [center addObserver:self selector:@selector(applicationBecameActive:)
                       name:UISceneDidActivateNotification object:nil];
    }
    self.housekeepingTimer = [NSTimer timerWithTimeInterval:0.5 target:self
                                                   selector:@selector(housekeepingTick:)
                                                   userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.housekeepingTimer forMode:NSRunLoopCommonModes];
    [self housekeepingTick:self.housekeepingTimer];
}

- (void)applicationBecameActive:(NSNotification *)notification {
    (void)notification;
    [self housekeepingTick:self.housekeepingTimer];
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
        if (window == self.overlayWindow) continue;
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

- (void)housekeepingTick:(NSTimer *)timer {
    (void)timer;
    UIViewController *liveController = [self liveViewController];
    if (liveController == nil || liveController.view.window == nil) {
        if (self.cleanModeEnabled) [self restoreAllShowingToast:NO];
        self.cleanButton.alpha = 0.0;
        self.cleanButton.userInteractionEnabled = NO;
        return;
    }
    [self ensureOverlayForHostWindow:liveController.view.window];
    [self updateOverlayFramesForController:liveController];
    if (self.cleanModeEnabled) {
        if (![self previewIsIntact:self.cleanPreviewView]) {
            [self restoreAllShowingToast:NO];
            [self showToast:@"MimoClean Safety Restore"];
        }
    } else {
        self.cleanButton.alpha = 1.0;
        self.cleanButton.userInteractionEnabled = YES;
    }
}

- (void)ensureOverlayForHostWindow:(UIWindow *)hostWindow {
    if (self.overlayWindow != nil && self.overlayWindow.windowScene == hostWindow.windowScene) return;
    self.overlayWindow.hidden = YES;
    self.toastLabel = nil;
    MCCleanOverlayWindow *window;
    if (@available(iOS 13.0, *)) {
        window = [[MCCleanOverlayWindow alloc] initWithWindowScene:hostWindow.windowScene];
    } else {
        window = [[MCCleanOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }
    window.frame = hostWindow.bounds;
    window.windowLevel = UIWindowLevelAlert + 2.0;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *rootController = [UIViewController new];
    rootController.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = rootController;
    window.hidden = NO;
    self.overlayWindow = window;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"CLEAN" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.68];
    button.layer.cornerRadius = 7.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
    button.layer.borderWidth = 0.5;
    [button addTarget:self action:@selector(cleanButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(cleanButtonLongPressed:)];
    longPress.minimumPressDuration = 0.6;
    [button addGestureRecognizer:longPress];
    [rootController.view addSubview:button];
    self.cleanButton = button;

    NSMutableArray<UIView *> *areas = [NSMutableArray array];
    for (NSUInteger index = 0; index < 2; index++) {
        UIView *area = [UIView new];
        area.backgroundColor = UIColor.clearColor;
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(blackBarRestoreTapped:)];
        doubleTap.numberOfTouchesRequired = 2;
        doubleTap.numberOfTapsRequired = 2;
        doubleTap.cancelsTouchesInView = NO;
        doubleTap.delegate = self;
        [area addGestureRecognizer:doubleTap];
        UILongPressGestureRecognizer *panelPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(blackBarLongPressed:)];
        panelPress.numberOfTouchesRequired = 2;
        panelPress.minimumPressDuration = 0.7;
        panelPress.cancelsTouchesInView = NO;
        panelPress.delegate = self;
        [area addGestureRecognizer:panelPress];
        [rootController.view addSubview:area];
        [areas addObject:area];
    }
    self.restoreGestureAreas = areas;
}

- (void)updateOverlayFramesForController:(UIViewController *)controller {
    UIView *overlayRoot = self.overlayWindow.rootViewController.view;
    CGRect bounds = overlayRoot.bounds;
    self.cleanButton.frame = CGRectMake(MAX(8.0, CGRectGetWidth(bounds) - 72.0), 12.0, 62.0, 32.0);
    UIView *preview = [self findPreviewInView:controller.view];
    CGRect previewRect = preview == nil ? CGRectZero : [preview convertRect:preview.bounds toView:overlayRoot];
    CGFloat topHeight = MAX(0.0, MIN(CGRectGetMinY(previewRect), CGRectGetHeight(bounds)));
    CGFloat bottomY = MAX(0.0, MIN(CGRectGetMaxY(previewRect), CGRectGetHeight(bounds)));
    if (self.restoreGestureAreas.count == 2) {
        self.restoreGestureAreas[0].frame = CGRectMake(0.0, 0.0, CGRectGetWidth(bounds), topHeight);
        self.restoreGestureAreas[1].frame = CGRectMake(0.0, bottomY, CGRectGetWidth(bounds),
                                                       MAX(0.0, CGRectGetHeight(bounds) - bottomY));
        for (UIView *area in self.restoreGestureAreas) area.userInteractionEnabled = self.cleanModeEnabled;
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer; (void)otherGestureRecognizer; return YES;
}

- (void)cleanButtonTapped:(UIButton *)sender {
    (void)sender;
    if (self.suppressNextCleanTap) { self.suppressNextCleanTap = NO; return; }
    [self applyCleanMode];
}

- (void)cleanButtonLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.suppressNextCleanTap = YES;
        [self presentControlPanel];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ self.suppressNextCleanTap = NO; });
    }
}

- (void)blackBarRestoreTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized && self.cleanModeEnabled)
        [self restoreAllShowingToast:NO];
}

- (void)blackBarLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan && self.cleanModeEnabled) [self presentControlPanel];
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
           [self subtreeContainsViewClassNamed:@"DJICobraTouchView" view:view];
}

- (BOOL)isUIKitControlBranch:(UIView *)view {
    return [view isKindOfClass:UIControl.class] || [view isKindOfClass:UILabel.class] ||
           [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UISlider.class] ||
           [view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class];
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
    if ([self.userHideClassNames containsObject:className] ||
        [className isEqualToString:@"DJIAC103SettingFloorView"] ||
        [className isEqualToString:@"DJIAC103OSDView"] ||
        [className isEqualToString:@"DJILiveviewMirrorContainerView"] ||
        [self isUIKitControlBranch:view] || [self classNameHasUIOnlyKeyword:className])
        return MCCleanClassificationHide;
    CGRect frameInRoot = [view convertRect:view.bounds toView:root];
    CGFloat rootArea = CGRectGetWidth(root.bounds) * CGRectGetHeight(root.bounds);
    CGFloat viewArea = CGRectGetWidth(frameInRoot) * CGRectGetHeight(frameInRoot);
    BOOL largeContainer = rootArea > 0.0 && viewArea / rootArea >= 0.75;
    NSUInteger total = 0, controls = 0;
    [self subtreeStatsForView:view total:&total controls:&controls];
    if (!largeContainer && total > 0 && controls > 0 && controls * 2 >= total)
        return MCCleanClassificationHide;
    return MCCleanClassificationUnknown;
}

- (NSString *)classificationName:(MCCleanClassification)value {
    if (value == MCCleanClassificationKeep) return @"KEEP";
    if (value == MCCleanClassificationHide) return @"HIDE";
    return @"UNKNOWN";
}

- (NSString *)ancestorChainForView:(UIView *)view root:(UIView *)root {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UIView *current = view; current != nil; current = current.superview) {
        [parts addObject:NSStringFromClass(current.class)];
        if (current == root) break;
    }
    return [parts.reverseObjectEnumerator.allObjects componentsJoinedByString:@" > "];
}

- (NSArray<NSString *> *)runtimeNamesForClass:(Class)runtimeClass kind:(NSString *)kind {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if ([kind isEqualToString:@"ivars"]) {
        unsigned int count = 0; Ivar *items = class_copyIvarList(runtimeClass, &count);
        for (unsigned int i = 0; i < count; i++)
            [names addObject:[NSString stringWithFormat:@"%s:%s", ivar_getName(items[i]) ?: "",
                              ivar_getTypeEncoding(items[i]) ?: ""]];
        free(items);
    } else if ([kind isEqualToString:@"properties"]) {
        unsigned int count = 0; objc_property_t *items = class_copyPropertyList(runtimeClass, &count);
        for (unsigned int i = 0; i < count; i++)
            [names addObject:[NSString stringWithFormat:@"%s:%s", property_getName(items[i]) ?: "",
                              property_getAttributes(items[i]) ?: ""]];
        free(items);
    } else {
        unsigned int count = 0; Method *items = class_copyMethodList(runtimeClass, &count);
        NSUInteger limit = MIN((NSUInteger)count, (NSUInteger)100);
        for (NSUInteger i = 0; i < limit; i++) [names addObject:NSStringFromSelector(method_getName(items[i]))];
        if (count > limit) [names addObject:[NSString stringWithFormat:@"... +%u selectors", count - (unsigned int)limit]];
        free(items);
    }
    return names;
}

- (void)logRuntimeMetadataForClass:(Class)runtimeClass {
    NSString *className = NSStringFromClass(runtimeClass);
    if ([self.inspectedRuntimeClasses containsObject:className]) return;
    [self.inspectedRuntimeClasses addObject:className];
    const char *imageName = class_getImageName(runtimeClass);
    NSLog(@"[MimoClean][runtime] class=%@ superclass=%@ image=%s ivars=%@ properties=%@ selectors=%@",
          className, NSStringFromClass(class_getSuperclass(runtimeClass)), imageName ?: "",
          [[self runtimeNamesForClass:runtimeClass kind:@"ivars"] componentsJoinedByString:@","],
          [[self runtimeNamesForClass:runtimeClass kind:@"properties"] componentsJoinedByString:@","],
          [[self runtimeNamesForClass:runtimeClass kind:@"selectors"] componentsJoinedByString:@","]);
}

- (void)scanView:(UIView *)view root:(UIView *)root preview:(UIView *)preview keepSet:(NSSet<UIView *> *)keepSet {
    MCCleanClassification value = [self classificationForView:view root:root preview:preview keepSet:keepSet];
    [self.classifications setObject:@(value) forKey:view];
    if (value == MCCleanClassificationKeep) self.keepCount++;
    else if (value == MCCleanClassificationHide) self.hideCount++;
    else self.unknownCount++;
    [self logRuntimeMetadataForClass:view.class];
    NSLog(@"[MimoClean][classify] result=%@ class=%@ superclass=%@ frame=%@ bounds=%@ alpha=%.3f hidden=%d layer=%@ subviews=%lu ancestors=%@",
          [self classificationName:value], NSStringFromClass(view.class),
          NSStringFromClass(class_getSuperclass(view.class)), NSStringFromCGRect(view.frame),
          NSStringFromCGRect(view.bounds), view.alpha, view.hidden, NSStringFromClass(view.layer.class),
          (unsigned long)view.subviews.count, [self ancestorChainForView:view root:root]);
    for (UIView *subview in view.subviews) [self scanView:subview root:root preview:preview keepSet:keepSet];
}

- (BOOL)scanCurrentLiveViewSuppressingNothing:(BOOL)showFailure {
    UIViewController *controller = [self liveViewController];
    UIView *root = controller.view;
    UIView *preview = root == nil ? nil : [self findPreviewInView:root];
    if (controller == nil || root == nil || preview == nil) {
        if (showFailure) [self showToast:@"MimoClean: LiveView preview not found"];
        return NO;
    }
    [self.classifications removeAllObjects];
    self.keepCount = self.hideCount = self.unknownCount = 0;
    NSSet<UIView *> *keepSet = [self previewKeepSetFromView:preview root:root];
    [self scanView:root root:root preview:preview keepSet:keepSet];
    NSLog(@"[MimoClean][summary] KEEP=%lu HIDE=%lu UNKNOWN=%lu", (unsigned long)self.keepCount,
          (unsigned long)self.hideCount, (unsigned long)self.unknownCount);
    return YES;
}

- (void)recordAndSuppressView:(UIView *)view {
    if ([self.originalAlphas objectForKey:view] == nil) [self.originalAlphas setObject:@(view.alpha) forKey:view];
    view.alpha = 0.0;
}

- (void)applyClassifiedBranchesInView:(UIView *)view preview:(UIView *)preview {
    for (UIView *subview in view.subviews) {
        NSNumber *stored = [self.classifications objectForKey:subview];
        MCCleanClassification value = stored == nil ? MCCleanClassificationUnknown : stored.integerValue;
        if (value == MCCleanClassificationHide) [self recordAndSuppressView:subview];
        else if (value == MCCleanClassificationUnknown ||
                 (value == MCCleanClassificationKeep && [self view:subview containsView:preview]))
            [self applyClassifiedBranchesInView:subview preview:preview];
    }
}

- (void)applyCleanMode {
    UIViewController *controller = [self liveViewController];
    UIView *root = controller.view;
    UIView *preview = root == nil ? nil : [self findPreviewInView:root];
    if (controller == nil || root == nil || preview == nil || ![self scanCurrentLiveViewSuppressingNothing:YES]) return;
    self.cleanRootView = root; self.cleanPreviewView = preview; self.cleanPreviewSuperview = preview.superview;
    self.cleanPreviewFrame = preview.frame; self.cleanPreviewBounds = preview.bounds;
    self.cleanPreviewTransform = preview.transform;
    [self applyClassifiedBranchesInView:root preview:preview];
    self.cleanModeEnabled = YES;
    self.cleanButton.alpha = 0.0; self.cleanButton.userInteractionEnabled = NO;
    [self updateOverlayFramesForController:controller];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.cleanModeEnabled && ![self previewIsIntact:self.cleanPreviewView]) {
            [self restoreAllShowingToast:NO]; [self showToast:@"MimoClean Safety Restore"];
        }
    });
}

- (BOOL)previewIsIntact:(UIView *)preview {
    if (preview == nil || preview.window == nil || preview.superview != self.cleanPreviewSuperview ||
        ![preview isDescendantOfView:self.cleanRootView] || preview.alpha <= 0.0 || preview.hidden ||
        ![NSStringFromClass(preview.layer.class) isEqualToString:@"CAEAGLLayer"] ||
        !CGRectEqualToRect(preview.frame, self.cleanPreviewFrame) ||
        !CGRectEqualToRect(preview.bounds, self.cleanPreviewBounds) ||
        !CGAffineTransformEqualToTransform(preview.transform, self.cleanPreviewTransform) ||
        [self findPreviewInView:self.cleanRootView] != preview) return NO;
    for (UIView *ancestor = preview; ancestor != nil; ancestor = ancestor.superview) {
        if (ancestor.alpha <= 0.0 || ancestor.hidden) return NO;
        if (ancestor == self.cleanRootView) return YES;
    }
    return NO;
}

- (void)restoreAllShowingToast:(BOOL)showToast {
    NSEnumerator<UIView *> *enumerator = self.originalAlphas.keyEnumerator;
    for (UIView *view = enumerator.nextObject; view != nil; view = enumerator.nextObject) {
        NSNumber *alpha = [self.originalAlphas objectForKey:view];
        if (alpha != nil) view.alpha = alpha.doubleValue;
    }
    [self.originalAlphas removeAllObjects];
    self.cleanModeEnabled = NO; self.cleanPreviewView = nil; self.cleanRootView = nil;
    self.cleanPreviewSuperview = nil; self.cleanButton.alpha = 1.0;
    self.cleanButton.userInteractionEnabled = YES;
    for (UIView *area in self.restoreGestureAreas) area.userInteractionEnabled = NO;
    if (showToast) [self showToast:@"Mimo UI restored"];
}

- (BOOL)viewIsEffectivelyVisible:(UIView *)view {
    if (view.window == nil || CGRectIsEmpty(view.bounds)) return NO;
    for (UIView *ancestor = view; ancestor != nil; ancestor = ancestor.superview)
        if (ancestor.hidden || ancestor.alpha <= 0.01) return NO;
    return YES;
}

- (NSArray<NSString *> *)classNamesForClassification:(MCCleanClassification)value onlyVisible:(BOOL)onlyVisible {
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSEnumerator<UIView *> *enumerator = self.classifications.keyEnumerator;
    for (UIView *view = enumerator.nextObject; view != nil; view = enumerator.nextObject) {
        NSNumber *stored = [self.classifications objectForKey:view];
        if (stored.integerValue == value && (!onlyVisible || [self viewIsEffectivelyVisible:view]))
            [names addObject:NSStringFromClass(view.class)];
    }
    return [names.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (void)presentControlPanel {
    [self scanCurrentLiveViewSuppressingNothing:NO];
    NSString *message = [NSString stringWithFormat:@"KEEP: %lu\nHIDE: %lu\nUNKNOWN: %lu",
                         (unsigned long)self.keepCount, (unsigned long)self.hideCount,
                         (unsigned long)self.unknownCount];
    UIAlertController *panel = [UIAlertController alertControllerWithTitle:@"MimoClean Control"
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [panel addAction:[UIAlertAction actionWithTitle:@"Clean ON" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) { [weakSelf applyCleanMode]; }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"Restore All" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) { [weakSelf restoreAllShowingToast:YES]; }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"Re-scan UI" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [weakSelf scanCurrentLiveViewSuppressingNothing:YES]; [weakSelf showToast:@"Mimo UI re-scanned"];
    }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"Show Classification" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) { [weakSelf presentClassificationSummary]; }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"Inspect Remaining" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) { [weakSelf presentUnknownClassChooser]; }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentOverlayAlert:panel];
}

- (void)presentClassificationSummary {
    NSArray<NSString *> *keep = [self classNamesForClassification:MCCleanClassificationKeep onlyVisible:NO];
    NSArray<NSString *> *hide = [self classNamesForClassification:MCCleanClassificationHide onlyVisible:NO];
    NSArray<NSString *> *unknown = [self classNamesForClassification:MCCleanClassificationUnknown onlyVisible:NO];
    NSString *(^sample)(NSArray<NSString *> *) = ^NSString *(NSArray<NSString *> *values) {
        NSUInteger count = MIN(values.count, (NSUInteger)12);
        return [[values subarrayWithRange:NSMakeRange(0, count)] componentsJoinedByString:@", "];
    };
    NSString *message = [NSString stringWithFormat:@"KEEP %lu\n%@\n\nHIDE %lu\n%@\n\nUNKNOWN %lu\n%@",
                         (unsigned long)self.keepCount, sample(keep), (unsigned long)self.hideCount,
                         sample(hide), (unsigned long)self.unknownCount, sample(unknown)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MimoClean Classification"
                                                                    message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentOverlayAlert:alert];
}

- (void)presentUnknownClassChooser {
    [self scanCurrentLiveViewSuppressingNothing:NO];
    NSArray<NSString *> *classes = [self classNamesForClassification:MCCleanClassificationUnknown
                                                          onlyVisible:self.cleanModeEnabled];
    UIAlertController *chooser = [UIAlertController alertControllerWithTitle:@"Inspect Remaining"
        message:@"Select a class to hide now and on future Clean ON operations. KEEP branches are excluded."
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSUInteger limit = MIN(classes.count, (NSUInteger)24);
    for (NSUInteger index = 0; index < limit; index++) {
        NSString *className = classes[index];
        [chooser addAction:[UIAlertAction actionWithTitle:className style:UIAlertActionStyleDefault
                                                  handler:^(__unused UIAlertAction *a) {
            [weakSelf.userHideClassNames addObject:className];
            [NSUserDefaults.standardUserDefaults setObject:weakSelf.userHideClassNames.allObjects
                                                    forKey:MCUserHideClassesKey];
            if (weakSelf.cleanModeEnabled) [weakSelf applyCleanMode];
            else [weakSelf showToast:[NSString stringWithFormat:@"Hide rule saved: %@", className]];
        }]];
    }
    if (classes.count == 0) chooser.message = @"No visible UNKNOWN classes remain.";
    else if (classes.count > limit)
        chooser.message = [chooser.message stringByAppendingFormat:@"\nShowing first %lu of %lu classes.",
                           (unsigned long)limit, (unsigned long)classes.count];
    [chooser addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentOverlayAlert:chooser];
}

- (void)presentOverlayAlert:(UIAlertController *)alert {
    UIViewController *root = self.overlayWindow.rootViewController;
    if (root.presentedViewController != nil) [root dismissViewControllerAnimated:NO completion:nil];
    if (alert.popoverPresentationController != nil) {
        alert.popoverPresentationController.sourceView = self.cleanButton;
        alert.popoverPresentationController.sourceRect = self.cleanButton.bounds;
    }
    [root presentViewController:alert animated:YES completion:nil];
}

- (void)showToast:(NSString *)text {
    UIView *root = self.overlayWindow.rootViewController.view;
    if (root == nil) return;
    UILabel *label = self.toastLabel;
    if (label == nil) {
        label = [UILabel new];
        self.toastLabel = label;
        [root addSubview:label];
    }
    label.text = text; label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    label.font = [UIFont boldSystemFontOfSize:13.0]; label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2; label.layer.cornerRadius = 8.0; label.clipsToBounds = YES;
    label.frame = CGRectMake(24.0, MAX(60.0, CGRectGetMidY(root.bounds) - 28.0),
                             MAX(100.0, CGRectGetWidth(root.bounds) - 48.0), 56.0);
    label.alpha = 1.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ label.alpha = 0.0; });
}

@end
