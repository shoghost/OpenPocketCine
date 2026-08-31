#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Always-on streaming layout controller. It never hooks DJI transport, decode, or rendering code.
@interface MCMimoCleanController : NSObject

+ (instancetype)sharedController;
- (void)start;

@end

NS_ASSUME_NONNULL_END
