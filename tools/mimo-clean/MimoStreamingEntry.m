#import "MimoCleanController.h"

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

/// Injected dylib entry point. No DJI class is hooked or swizzled.
__attribute__((constructor)) static void MCMimoStreamingInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [MCMimoCleanController.sharedController start];
    });
}
