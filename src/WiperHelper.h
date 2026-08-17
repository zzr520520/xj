#import <Foundation/Foundation.h>

@interface WiperHelper : NSObject

+ (void)cleanSandboxForBundleID:(NSString *)bundleID;
+ (void)cleanKeychainForCurrentApp;
+ (NSString *)getConfigPathForBundleID:(NSString *)bundleID;

@end
