#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

/// Phase 3 UI-only loader. This file does not hook or swizzle DJI classes.
@interface MCFLEXLoader : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) NSMapTable<UIView *, NSNumber *> *originalAlphas;
@property(nonatomic, weak) UIView *cleanPreviewView;
@property(nonatomic, assign) CGRect cleanPreviewFrame;
@property(nonatomic, assign) CGAffineTransform cleanPreviewTransform;
@property(nonatomic, assign) BOOL cleanModeEnabled;
@end

@implementation MCFLEXLoader

static const void *MCFLEXGestureKey = &MCFLEXGestureKey;
static const void *MCCleanGestureKey = &MCCleanGestureKey;

+ (instancetype)sharedLoader {
    static MCFLEXLoader *loader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loader = [MCFLEXLoader new];
    });
    return loader;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _originalAlphas = [NSMapTable weakToStrongObjectsMapTable];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self
                   selector:@selector(applicationBecameActive:)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
        if (@available(iOS 13.0, *)) {
            [center addObserver:self
                       selector:@selector(applicationBecameActive:)
                           name:UISceneDidActivateNotification
                         object:nil];
        }
    }
    return self;
}

- (void)applicationBecameActive:(NSNotification *)notification {
    (void)notification;
    [self installGestureOnApplicationWindows];
    if (self.cleanModeEnabled) {
        [self applyCleanMode];
    }
}

- (void)installGestureOnApplicationWindows {
    NSAssert(NSThread.isMainThread, @"FLEX gesture installation must run on the main thread");

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                [self installGestureOnWindow:window];
            }
        }
    } else {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            [self installGestureOnWindow:window];
        }
    }
}

- (void)installGestureOnWindow:(UIWindow *)window {
    if (window == nil) {
        return;
    }

    if (objc_getAssociatedObject(window, MCFLEXGestureKey) == nil) {
        UITapGestureRecognizer *gesture = [[UITapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(toggleExplorer:)];
        gesture.numberOfTapsRequired = 1;
        gesture.numberOfTouchesRequired = 3;
        gesture.cancelsTouchesInView = NO;
        gesture.delaysTouchesBegan = NO;
        gesture.delaysTouchesEnded = NO;
        gesture.delegate = self;
        [window addGestureRecognizer:gesture];
        objc_setAssociatedObject(window, MCFLEXGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (objc_getAssociatedObject(window, MCCleanGestureKey) == nil) {
        UITapGestureRecognizer *gesture = [[UITapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(toggleCleanMode:)];
        gesture.numberOfTapsRequired = 1;
        gesture.numberOfTouchesRequired = 4;
        gesture.cancelsTouchesInView = NO;
        gesture.delaysTouchesBegan = NO;
        gesture.delaysTouchesEnded = NO;
        gesture.delegate = self;
        [window addGestureRecognizer:gesture];
        objc_setAssociatedObject(window, MCCleanGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

- (void)toggleExplorer:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) {
        return;
    }

    Class managerClass = NSClassFromString(@"FLEXManager");
    SEL sharedManagerSelector = NSSelectorFromString(@"sharedManager");
    SEL toggleExplorerSelector = NSSelectorFromString(@"toggleExplorer");
    if (managerClass == Nil || ![managerClass respondsToSelector:sharedManagerSelector]) {
        return;
    }

    id (*sendObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    void (*sendVoid)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    id manager = sendObject((id)managerClass, sharedManagerSelector);
    if (manager != nil && [manager respondsToSelector:toggleExplorerSelector]) {
        sendVoid(manager, toggleExplorerSelector);
    }
}

- (void)toggleCleanMode:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) {
        return;
    }

    if (self.cleanModeEnabled) {
        [self restoreCleanMode];
    } else {
        [self applyCleanMode];
    }
}

- (UIViewController *)findViewControllerNamed:(NSString *)className
                            fromViewController:(UIViewController *)viewController {
    if (viewController == nil) {
        return nil;
    }
    if ([NSStringFromClass(viewController.class) isEqualToString:className]) {
        return viewController;
    }
    UIViewController *presented = [self findViewControllerNamed:className
                                             fromViewController:viewController.presentedViewController];
    if (presented != nil) {
        return presented;
    }
    for (UIViewController *child in [viewController childViewControllers]) {
        UIViewController *match = [self findViewControllerNamed:className fromViewController:child];
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

- (UIViewController *)liveViewController {
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        UIViewController *match = [self findViewControllerNamed:@"DJIHG2X0FPVViewController"
                                             fromViewController:window.rootViewController];
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

- (UIView *)findPreviewInView:(UIView *)view {
    if ([NSStringFromClass(view.class) isEqualToString:@"DJIGLImageViewCupertino"] &&
        [NSStringFromClass(view.layer.class) isEqualToString:@"CAEAGLLayer"]) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *match = [self findPreviewInView:subview];
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

- (BOOL)view:(UIView *)view containsView:(UIView *)target {
    return view == target || [target isDescendantOfView:view];
}

- (NSSet<UIView *> *)previewKeepSetFromView:(UIView *)preview root:(UIView *)root {
    NSMutableSet<UIView *> *keepSet = [NSMutableSet set];
    UIView *view = preview;
    while (view != nil) {
        [keepSet addObject:view];
        NSLog(@"[MimoClean] KEEP class=%@ frame=%@ layer=%@",
              NSStringFromClass(view.class),
              NSStringFromCGRect(view.frame),
              NSStringFromClass(view.layer.class));
        if (view == root) {
            break;
        }
        view = view.superview;
    }
    return keepSet;
}

- (BOOL)subtreeContainsLayerNamed:(NSString *)className view:(UIView *)view {
    if ([NSStringFromClass(view.layer.class) isEqualToString:className]) {
        return YES;
    }
    for (UIView *subview in view.subviews) {
        if ([self subtreeContainsLayerNamed:className view:subview]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)subtreeContainsViewClassNamed:(NSString *)className view:(UIView *)view {
    if ([NSStringFromClass(view.class) isEqualToString:className]) {
        return YES;
    }
    for (UIView *subview in view.subviews) {
        if ([self subtreeContainsViewClassNamed:className view:subview]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)isProtectedBranch:(UIView *)view
                  preview:(UIView *)preview
                  keepSet:(NSSet<UIView *> *)keepSet {
    if ([keepSet containsObject:view] ||
        [self view:view containsView:preview] ||
        [self subtreeContainsLayerNamed:@"CAEAGLLayer" view:view] ||
        [self subtreeContainsViewClassNamed:@"DJICobraTouchView" view:view] ||
        [self subtreeContainsViewClassNamed:@"DJIAC103TopPresentView" view:view]) {
        return YES;
    }
    return NO;
}

- (void)recordAndSuppressView:(UIView *)view {
    if ([self.originalAlphas objectForKey:view] == nil) {
        [self.originalAlphas setObject:@(view.alpha) forKey:view];
    }
    NSLog(@"[MimoClean] suppress class=%@ frame=%@ alpha=%.3f hidden=%d subviews=%lu",
          NSStringFromClass(view.class),
          NSStringFromCGRect(view.frame),
          view.alpha,
          view.hidden,
          (unsigned long)view.subviews.count);
    view.alpha = 0.0;
}

- (void)suppressBranchesInView:(UIView *)view
                           root:(UIView *)root
                        preview:(UIView *)preview
                        keepSet:(NSSet<UIView *> *)keepSet
                          depth:(NSUInteger)depth {
    for (UIView *subview in view.subviews) {
        BOOL protectedBranch = [self isProtectedBranch:subview preview:preview keepSet:keepSet];
        CGRect frameInRoot = [subview convertRect:subview.bounds toView:root];
        CGFloat rootArea = CGRectGetWidth(root.bounds) * CGRectGetHeight(root.bounds);
        CGFloat branchArea = CGRectGetWidth(frameInRoot) * CGRectGetHeight(frameInRoot);
        BOOL largeContainer = rootArea > 0.0 && branchArea / rootArea >= 0.75;
        NSLog(@"[MimoClean] inspect depth=%lu class=%@ frame=%@ alpha=%.3f hidden=%d protected=%d large=%d subviews=%lu",
              (unsigned long)depth,
              NSStringFromClass(subview.class),
              NSStringFromCGRect(frameInRoot),
              subview.alpha,
              subview.hidden,
              protectedBranch,
              largeContainer,
              (unsigned long)subview.subviews.count);

        if (protectedBranch) {
            if ([self view:subview containsView:preview] && subview != preview) {
                [self suppressBranchesInView:subview
                                        root:root
                                     preview:preview
                                     keepSet:keepSet
                                       depth:depth + 1];
            }
            continue;
        }

        if ((depth == 0 || largeContainer) && subview.subviews.count > 0) {
            [self suppressBranchesInView:subview
                                    root:root
                                 preview:preview
                                 keepSet:keepSet
                                   depth:depth + 1];
        } else {
            [self recordAndSuppressView:subview];
        }
    }
}

- (BOOL)previewIsIntact:(UIView *)preview {
    return preview != nil &&
           preview.window != nil &&
           preview.alpha > 0.0 &&
           !preview.hidden &&
           [NSStringFromClass(preview.layer.class) isEqualToString:@"CAEAGLLayer"] &&
           CGRectEqualToRect(preview.frame, self.cleanPreviewFrame) &&
           CGAffineTransformEqualToTransform(preview.transform, self.cleanPreviewTransform);
}

- (void)applyCleanMode {
    NSAssert(NSThread.isMainThread, @"Clean Mode traversal must run on the main thread");
    UIViewController *controller = [self liveViewController];
    UIView *root = controller.view;
    UIView *preview = root == nil ? nil : [self findPreviewInView:root];
    if (controller == nil || root == nil || preview == nil) {
        NSLog(@"[MimoClean] Clean Mode unavailable: LiveView controller or CAEAGLLayer preview not found");
        return;
    }

    self.cleanPreviewView = preview;
    self.cleanPreviewFrame = preview.frame;
    self.cleanPreviewTransform = preview.transform;
    NSSet<UIView *> *keepSet = [self previewKeepSetFromView:preview root:root];
    [self suppressBranchesInView:root root:root preview:preview keepSet:keepSet depth:0];
    self.cleanModeEnabled = YES;
    NSLog(@"[MimoClean] Clean Mode ON preview=%@ frame=%@ transform=%@ suppressed=%lu",
          NSStringFromClass(preview.class),
          NSStringFromCGRect(preview.frame),
          NSStringFromCGAffineTransform(preview.transform),
          (unsigned long)self.originalAlphas.count);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.cleanModeEnabled && ![self previewIsIntact:self.cleanPreviewView]) {
            NSLog(@"[MimoClean] safety restore: preview disappeared or geometry changed");
            [self restoreCleanMode];
        }
    });
}

- (void)restoreCleanMode {
    NSAssert(NSThread.isMainThread, @"Clean Mode restore must run on the main thread");
    NSEnumerator<UIView *> *enumerator = self.originalAlphas.keyEnumerator;
    UIView *view;
    while ((view = enumerator.nextObject) != nil) {
        NSNumber *alpha = [self.originalAlphas objectForKey:view];
        if (alpha != nil) {
            view.alpha = alpha.doubleValue;
        }
    }
    [self.originalAlphas removeAllObjects];
    self.cleanModeEnabled = NO;
    self.cleanPreviewView = nil;
    NSLog(@"[MimoClean] Clean Mode OFF: original alpha values restored");
}

@end

__attribute__((constructor)) static void MCFLEXLoaderInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MCFLEXLoader *loader = MCFLEXLoader.sharedLoader;
        (void)loader;
        [loader installGestureOnApplicationWindows];
    });
}
