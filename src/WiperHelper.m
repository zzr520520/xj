#import "WiperHelper.h"
#import <Security/Security.h>

@implementation WiperHelper

+ (NSString *)getConfigPathForBundleID:(NSString *)bundleID {
    // 兼容 Rootless 路径
    NSString *baseDir = @"/var/jb/var/mobile/Library/Preferences/MyAppWiper/configs";
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        baseDir = @"/var/mobile/Library/Preferences/MyAppWiper/configs";
    }
    return [baseDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
}

+ (void)cleanKeychainForCurrentApp {
    NSArray *secClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity
    ];

    for (id secClass in secClasses) {
        NSDictionary *spec = @{(__bridge id)kSecClass: secClass};
        SecItemDelete((__bridge CFDictionaryRef)spec);
    }
}

+ (void)cleanSandboxForBundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();

    NSArray *pathsToClean = @[
        [home stringByAppendingPathComponent:@"Documents"],
        [home stringByAppendingPathComponent:@"Library/Caches"],
        [home stringByAppendingPathComponent:@"Library/Preferences"],
        [home stringByAppendingPathComponent:@"Library/WebKit"],
        [home stringByAppendingPathComponent:@"tmp"]
    ];

    for (NSString *path in pathsToClean) {
        if ([fm fileExistsAtPath:path]) {
            NSError *error = nil;
            NSArray *contents = [fm contentsOfDirectoryAtPath:path error:&error];
            for (NSString *item in contents) {
                [fm removeItemAtPath:[path stringByAppendingPathComponent:item] error:nil];
            }
        }
    }
}

@end
