#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "WiperHelper.h"

// 宏定义：动态链接符号拦截 (DYLD_INTERPOSE)
#define DYLD_INTERPOSE(_replacement, _replacee) \
__attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
__attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static NSDictionary *g_fakeConfig = nil;
static BOOL g_isEnabled = NO;

#pragma mark - 拦截实现

int fake_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (g_isEnabled && name != NULL) {
        if (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0) {
            NSString *fakeMachine = g_fakeConfig[@"hw.machine"] ?: @"iPhone15,2";
            const char *str = [fakeMachine UTF8String];
            size_t len = strlen(str) + 1;
            if (oldp && oldlenp) {
                if (*oldlenp >= len) {
                    memcpy(oldp, str, len);
                    *oldlenp = len;
                    return 0;
                }
            }
        }
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}
DYLD_INTERPOSE(fake_sysctlbyname, sysctlbyname);

int fake_uname(struct utsname *buf) {
    int ret = uname(buf);
    if (g_isEnabled && ret == 0 && buf != NULL) {
        NSString *fakeMachine = g_fakeConfig[@"hw.machine"] ?: @"iPhone15,2";
        strncpy(buf->machine, [fakeMachine UTF8String], sizeof(buf->machine));
    }
    return ret;
}
DYLD_INTERPOSE(fake_uname, uname);

int fake_stat(const char *path, struct stat *buf) {
    int ret = stat(path, buf);
    if (g_isEnabled && ret == 0 && buf != NULL && path != NULL) {
        if (strstr(path, "com.apple.mobile.installation.plist") != NULL ||
            strstr(path, "Library/Preferences") != NULL) {
            time_t fakeTime = 1735689600; // 2025-01-01 00:00:00 UTC
            buf->st_atime = fakeTime;
            buf->st_mtime = fakeTime;
            buf->st_ctime = fakeTime;
            buf->st_birthtime = fakeTime;
        }
    }
    return ret;
}
DYLD_INTERPOSE(fake_stat, stat);

int fake_getifaddrs(struct ifaddrs **ifap) {
    int ret = getifaddrs(ifap);
    if (g_isEnabled && ret == 0 && ifap != NULL && *ifap != NULL) {
        struct ifaddrs *curr = *ifap;
        while (curr != NULL) {
            if (curr->ifa_addr && curr->ifa_addr->sa_family == AF_LINK) {
                struct sockaddr_dl *sdl = (struct sockaddr_dl *)curr->ifa_addr;
                if (sdl->sdl_alen >= 6) {
                    unsigned char *mac = (unsigned char *)LLADDR(sdl);
                    memset(mac, 0x00, 6);
                }
            }
            curr = curr->ifa_next;
        }
    }
    return ret;
}
DYLD_INTERPOSE(fake_getifaddrs, getifaddrs);

#pragma mark - MGCache 内存修改

static void patchMGCache(NSDictionary *config) {
    CFMutableDictionaryRef *mgCachePtr = (CFMutableDictionaryRef *)dlsym(RTLD_DEFAULT, "_MGCache");
    if (mgCachePtr && *mgCachePtr) {
        CFMutableDictionaryRef cache = *mgCachePtr;
        if (config[@"SerialNumber"]) {
            CFDictionarySetValue(cache, CFSTR("SerialNumber"), (__bridge CFTypeRef)config[@"SerialNumber"]);
        }
        if (config[@"UniqueDeviceID"]) {
            CFDictionarySetValue(cache, CFSTR("UniqueDeviceID"), (__bridge CFTypeRef)config[@"UniqueDeviceID"]);
        }
        if (config[@"ModelNumber"]) {
            CFDictionarySetValue(cache, CFSTR("ModelNumber"), (__bridge CFTypeRef)config[@"ModelNumber"]);
        }
    }
}

#pragma mark - 启动时序

@interface EarlyInitializer : NSObject
@end

@implementation EarlyInitializer

+ (void)load {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID || [bundleID hasPrefix:@"com.apple."]) {
            return;
        }

        NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
        if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
            return;
        }

        g_fakeConfig = [NSDictionary dictionaryWithContentsOfFile:configPath];
        if (g_fakeConfig && [g_fakeConfig[@"enabled"] boolValue]) {
            g_isEnabled = YES;

            // 1. 检查是否需要执行重置
            if ([g_fakeConfig[@"needs_wipe"] boolValue]) {
                [WiperHelper cleanKeychainForCurrentApp];
                [WiperHelper cleanSandboxForBundleID:bundleID];

                // 重置标记并回写
                NSMutableDictionary *mutableConfig = [g_fakeConfig mutableCopy];
                mutableConfig[@"needs_wipe"] = @(NO);
                [mutableConfig writeToFile:configPath atomically:YES];
            }

            // 2. 篡改内部缓存
            patchMGCache(g_fakeConfig);
        }
    }
}

@end
