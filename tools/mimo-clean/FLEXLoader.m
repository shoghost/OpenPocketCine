#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

/// Phase 2 inspection loader only. This file does not hook or swizzle DJI classes.
@interface MCFLEXLoader : NSObject <UIGestureRecognizerDelegate>
@end

@implementation MCFLEXLoader

static const void *MCFLEXGestureKey = &MCFLEXGestureKey;

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
    if (window == nil || objc_getAssociatedObject(window, MCFLEXGestureKey) != nil) {
        return;
    }

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

@end

__attribute__((constructor)) static void MCFLEXLoaderInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MCFLEXLoader *loader = MCFLEXLoader.sharedLoader;
        (void)loader;
        [loader installGestureOnApplicationWindows];
    });
}
