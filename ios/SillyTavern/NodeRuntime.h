#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NodeRuntime : NSObject

@property (nonatomic, readonly) BOOL started;
@property (nonatomic, readonly, nullable) NSString *failureMessage;

+ (instancetype)sharedRuntime;
- (void)start;

@end

NS_ASSUME_NONNULL_END
