#import <Foundation/Foundation.h>

@interface WiperHelper : NSObject

+ (NSString *)getConfigPathForBundleID:(NSString *)bundleID;
+ (void)killTargetApp:(NSString *)bundleID;
+ (void)cleanSandboxForBundleID:(NSString *)bundleID;
+ (void)resetAllPermissionsForBundleID:(NSString *)bundleID;
+ (void)cleanKeychainForBundleID:(NSString *)bundleID;

@end
