#import "MimoCleanController.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

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
@property(nonatomic, strong) NSMutableSet<NSString *> *inspectedRuntimeClasses;
@property(nonatomic, strong) NSTimer *safetyTimer;
@property(nonatomic, weak) UIView *cleanPreviewView;
@property(nonatomic, weak) UIView *cleanRootView;
@property(nonatomic, weak) UIView *cleanPreviewSuperview;
@property(nonatomic, weak) UIViewController *cleanLiveViewController;
@property(nonatomic, assign) CGRect cleanPreviewFrame;
@property(nonatomic, assign) CGRect cleanPreviewBounds;
@property(nonatomic, assign) CGAffineTransform cleanPreviewTransform;
@property(nonatomic, assign) BOOL cleanModeEnabled;
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
        _originalHiddenStates = [NSMapTable weakToStrongObjectsMapTable];
        _classifications = [NSMapTable weakToStrongObjectsMapTable];
        _inspectedRuntimeClasses = [NSMutableSet set];
        NSArray<NSString *> *stored = [NSUserDefaults.standardUserDefaults arrayForKey:MCUserHideClassesKey];
        _userHideClassNames = [NSMutableSet setWithArray:stored ?: @[]];
    }
    return self;
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"MimoClean must start on the main thread");
}

- (void)toggleCleanMode {
    NSAssert(NSThread.isMainThread, @"MimoClean toggle must run on the main thread");
    if (self.cleanModeEnabled) [self restoreAllShowingToast:NO];
    else [self applyCleanMode];
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

- (void)startSafetyTimer {
    if (self.safetyTimer != nil) return;
    self.safetyTimer = [NSTimer timerWithTimeInterval:0.5 target:self
                                             selector:@selector(safetyTick:)
                                             userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.safetyTimer forMode:NSRunLoopCommonModes];
}

- (void)stopSafetyTimer {
    [self.safetyTimer invalidate];
    self.safetyTimer = nil;
}

- (void)safetyTick:(NSTimer *)timer {
    (void)timer;
    NSAssert(NSThread.isMainThread, @"MimoClean safety check must run on the main thread");
    if (!self.cleanModeEnabled) {
        [self stopSafetyTimer];
        return;
    }
    if (![self previewIsIntact:self.cleanPreviewView]) {
        [self restoreAllShowingToast:NO];
        NSLog(@"[MimoClean] Safety Restore");
    }
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
        if (showFailure) NSLog(@"[MimoClean] LiveView preview not found");
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
    self.cleanPreviewFrame = preview.frame; self.cleanPreviewBounds = preview.bounds;
    self.cleanPreviewTransform = preview.transform;
    [self applyClassifiedBranchesInView:root];
    self.cleanModeEnabled = YES;
    [self startSafetyTimer];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.cleanModeEnabled && ![self previewIsIntact:self.cleanPreviewView]) {
            [self restoreAllShowingToast:NO];
            NSLog(@"[MimoClean] Safety Restore");
        }
    });
}

- (BOOL)previewIsIntact:(UIView *)preview {
    if (preview == nil || preview.window == nil || preview.superview != self.cleanPreviewSuperview ||
        ![preview isDescendantOfView:self.cleanRootView] || preview.alpha <= 0.0 || preview.hidden ||
        ![NSStringFromClass(preview.layer.class) isEqualToString:@"CAEAGLLayer"] ||
        !CGRectEqualToRect(preview.frame, self.cleanPreviewFrame) ||
        !CGRectEqualToRect(preview.bounds, self.cleanPreviewBounds) ||
        !CGAffineTransformEqualToTransform(preview.transform, self.cleanPreviewTransform)) return NO;
    for (UIView *ancestor = preview; ancestor != nil; ancestor = ancestor.superview) {
        if (ancestor.alpha <= 0.0 || ancestor.hidden) return NO;
        if (ancestor == self.cleanRootView) return YES;
    }
    return NO;
}

- (void)restoreAllShowingToast:(BOOL)showToast {
    NSAssert(NSThread.isMainThread, @"MimoClean restore must run on the main thread");
    NSEnumerator<UIView *> *enumerator = self.originalHiddenStates.keyEnumerator;
    for (UIView *view = enumerator.nextObject; view != nil; view = enumerator.nextObject) {
        NSNumber *hidden = [self.originalHiddenStates objectForKey:view];
        if (hidden != nil) view.hidden = hidden.boolValue;
    }
    [self.originalHiddenStates removeAllObjects];
    [self stopSafetyTimer];
    self.cleanModeEnabled = NO; self.cleanLiveViewController = nil;
    self.cleanPreviewView = nil; self.cleanRootView = nil;
    self.cleanPreviewSuperview = nil;
    if (showToast) NSLog(@"[MimoClean] Mimo UI restored");
}

@end
