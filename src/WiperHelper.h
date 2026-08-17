#import <Foundation/Foundation.h>

@interface WiperHelper : NSObject

+ (NSString *)getConfigPathForBundleID:(NSString *)bundleID;
+ (BOOL)performFullWipeForBundleID:(NSString *)bundleID;

@end
