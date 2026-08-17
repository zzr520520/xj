#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <dlfcn.h>
#import "WiperHelper.h"

#define DYLD_INTERPOSE(_replacement, _replacee) \
__attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
__attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static NSDictionary *g_fakeConfig = nil;
static BOOL g_isEnabled = NO;

#pragma mark - 1. 底层硬件与时间伪装

int fake_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (g_isEnabled && name != NULL) {
        if (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0) {
            NSString *fakeMachine = g_fakeConfig[@"hw.machine"] ?: @"iPhone15,2";
            const char *str = [fakeMachine UTF8String];
            size_t len = strlen(str) + 1;
            if (oldp && oldlenp && *oldlenp >= len) {
                memcpy(oldp, str, len);
                *oldlenp = len;
                return 0;
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

#pragma mark - 2. 越狱痕迹与环境防检测 (Anti-Jailbreak / Anti-Detection)

// 拦截环境变量，隐藏注入库痕迹
char *fake_getenv(const char *name) {
    if (g_isEnabled && name != NULL) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 || strcmp(name, "_MSSafeMode") == 0) {
            return NULL;
        }
    }
    return getenv(name);
}
DYLD_INTERPOSE(fake_getenv, getenv);

// 拦截文件状态检测，隐藏越狱路径
int fake_stat(const char *path, struct stat *buf) {
    if (g_isEnabled && path != NULL) {
        // 屏蔽常见越狱文件探测
        if (strstr(path, "/var/jb") ||
            strstr(path, "Cydia") ||
            strstr(path, "Sileo") ||
            strstr(path, "MobileSubstrate") ||
            strstr(path, "ellekit") ||
            strstr(path, "/bin/bash") ||
            strstr(path, "/usr/sbin/sshd")) {
            errno = ENOENT;
            return -1;
        }
    }
    return stat(path, buf);
}
DYLD_INTERPOSE(fake_stat, stat);

// 拦截 access 检测
int fake_access(const char *path, int mode) {
    if (g_isEnabled && path != NULL) {
        if (strstr(path, "/var/jb") || strstr(path, "Cydia") || strstr(path, "Sileo")) {
            errno = ENOENT;
            return -1;
        }
    }
    return access(path, mode);
}
DYLD_INTERPOSE(fake_access, access);

#pragma mark - 3. 网卡与 MAC 伪造

int fake_getifaddrs(struct ifaddrs **ifap) {
    int ret = getifaddrs(ifap);
    if (g_isEnabled && ret == 0 && ifap != NULL && *ifap != NULL) {
        struct ifaddrs *curr = *ifap;
        while (curr != NULL) {
            // 隐藏 VPN/代理虚拟网卡
            if (strncmp(curr->ifa_name, "tun", 3) == 0 || strncmp(curr->ifa_name, "ppp", 3) == 0) {
                curr->ifa_flags &= ~IFF_UP;
            }
            // 伪造 MAC 地址结构
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

#pragma mark - 4. MGCache 内存修改

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
        if (config[@"WifiAddress"]) {
            CFDictionarySetValue(cache, CFSTR("WifiAddress"), (__bridge CFTypeRef)config[@"WifiAddress"]);
        }
    }
}

#pragma mark - 5. 极速注入时序

@interface EarlyInitializer : NSObject
@end

@implementation EarlyInitializer

+ (void)load {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        // Skip system apps AND the management app itself (prevents self-injection conflict)
        if (!bundleID || [bundleID hasPrefix:@"com.apple."]) return;
        if ([bundleID isEqualToString:@"com.custom.appwiper.ui"]) return;

        NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
        if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) return;

        g_fakeConfig = [NSDictionary dictionaryWithContentsOfFile:configPath];
        if (g_fakeConfig && [g_fakeConfig[@"enabled"] boolValue]) {
            g_isEnabled = YES;
            
            // 仅进行内存缓存篡改，不重复触发沙盒抹除
            patchMGCache(g_fakeConfig);
        }
    }
}

@end
