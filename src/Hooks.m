#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "WiperHelper.h"

#define DYLD_INTERPOSE(_replacement, _replacee) \
__attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
__attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static NSDictionary *g_fakeConfig = nil;
static BOOL g_isEnabled = NO;

#pragma mark - 1. sysctl / uname interception

int fake_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (g_isEnabled && name != NULL) {
        if (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0) {
            NSString *val = g_fakeConfig[@"hw.machine"] ?: @"iPhone15,2";
            const char *str = [val UTF8String];
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
        strncpy(buf->machine, [fakeMachine UTF8String], sizeof(buf->machine) - 1);
        buf->machine[sizeof(buf->machine) - 1] = '\0';
    }
    return ret;
}
DYLD_INTERPOSE(fake_uname, uname);

#pragma mark - 2. MGCopyAnswer deep interception

CFTypeRef (*orig_MGCopyAnswer)(CFStringRef property) = NULL;

// MGCopyAnswer is a private MobileGestalt API - use dlsym for runtime resolution
extern CFTypeRef MGCopyAnswer(CFStringRef property) __attribute__((weak_import));

CFTypeRef fake_MGCopyAnswer(CFStringRef property) {
    if (g_isEnabled && property != NULL) {
        NSString *prop = (__bridge NSString *)property;

        // Direct key match from config
        if (g_fakeConfig[prop]) {
            return (__bridge_retained CFTypeRef)g_fakeConfig[prop];
        }

        // Alias mappings
        if ([prop isEqualToString:@"ProductType"] || [prop isEqualToString:@"hw.model"]) {
            return (__bridge_retained CFTypeRef)g_fakeConfig[@"hw.machine"];
        }
        if ([prop isEqualToString:@"ProductVersion"]) {
            return (__bridge_retained CFTypeRef)g_fakeConfig[@"SystemVersion"];
        }
        if ([prop isEqualToString:@"ModelNumber"] || [prop isEqualToString:@"RegionCode"]) {
            NSString *val = g_fakeConfig[prop];
            if (val) return (__bridge_retained CFTypeRef)val;
        }
        if ([prop isEqualToString:@"ChipID"]) {
            NSString *val = g_fakeConfig[@"ChipID"];
            if (val) return (__bridge_retained CFTypeRef)val;
        }
        if ([prop isEqualToString:@"DieID"]) {
            NSString *val = g_fakeConfig[@"DieID"];
            if (val) return (__bridge_retained CFTypeRef)val;
        }
    }
    if (!orig_MGCopyAnswer) {
        orig_MGCopyAnswer = dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    }
    return orig_MGCopyAnswer ? orig_MGCopyAnswer(property) : NULL;
}

// Use dlsym to get the real MGCopyAnswer for interpose
static CFTypeRef (*get_real_MGCopyAnswer)(CFStringRef) = NULL;

// Custom interpose: we interpose fake_MGCopyAnswer over the real MGCopyAnswer symbol
// Since MGCopyAnswer is private, we resolve it dynamically
__attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_MGCopyAnswer
__attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&fake_MGCopyAnswer, (const void*)(unsigned long)&MGCopyAnswer };

// Deep patch MobileGestalt internal cache dictionary
static void patchFullMGCache(NSDictionary *config) {
    CFMutableDictionaryRef *mgCachePtr = (CFMutableDictionaryRef *)dlsym(RTLD_DEFAULT, "_MGCache");
    if (mgCachePtr && *mgCachePtr) {
        CFMutableDictionaryRef cache = *mgCachePtr;
        [config enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            CFDictionarySetValue(cache, (__bridge CFStringRef)key, (__bridge CFTypeRef)obj);
        }];
    }
}

#pragma mark - 3. CoreTelephony carrier spoofing

@interface CTCarrier (FakeCarrier)
@end

@implementation CTCarrier (FakeCarrier)
- (NSString *)fake_carrierName { return @"中国移动"; }
- (NSString *)fake_mobileCountryCode { return @"460"; }
- (NSString *)fake_mobileNetworkCode { return @"00"; }
- (NSString *)fake_isoCountryCode { return @"cn"; }
@end

#pragma mark - 4. Jailbreak detection bypass

char *fake_getenv(const char *name) {
    if (g_isEnabled && name != NULL) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
            strcmp(name, "_MSSafeMode") == 0 ||
            strcmp(name, "MobileSubstrate") == 0) {
            return NULL;
        }
    }
    return getenv(name);
}
DYLD_INTERPOSE(fake_getenv, getenv);

int fake_stat(const char *path, struct stat *buf) {
    if (g_isEnabled && path != NULL) {
        if (strstr(path, "/var/jb") ||
            strstr(path, "Cydia") ||
            strstr(path, "Sileo") ||
            strstr(path, "MobileSubstrate") ||
            strstr(path, "ellekit") ||
            strstr(path, "/bin/bash") ||
            strstr(path, "apt") ||
            strstr(path, "dpkg")) {
            errno = ENOENT;
            return -1;
        }
    }
    return stat(path, buf);
}
DYLD_INTERPOSE(fake_stat, stat);

int fake_access(const char *path, int mode) {
    if (g_isEnabled && path != NULL) {
        if (strstr(path, "/var/jb") ||
            strstr(path, "Cydia") ||
            strstr(path, "Sileo") ||
            strstr(path, "MobileSubstrate") ||
            strstr(path, "ellekit")) {
            errno = ENOENT;
            return -1;
        }
    }
    return access(path, mode);
}
DYLD_INTERPOSE(fake_access, access);

#pragma mark - 5. Boot entry: load config and mount hooks

static void swizzle(Class cls, SEL orig, SEL rep) {
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, rep);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

@interface EarlyInitializer : NSObject
@end

@implementation EarlyInitializer

+ (void)load {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        // Skip system apps AND management app itself
        if (!bundleID || [bundleID hasPrefix:@"com.apple."]) return;
        if ([bundleID isEqualToString:@"com.custom.appwiper.ui"]) return;

        NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
        if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) return;

        g_fakeConfig = [NSDictionary dictionaryWithContentsOfFile:configPath];
        if (g_fakeConfig && [g_fakeConfig[@"enabled"] boolValue]) {
            g_isEnabled = YES;

            // 1. Deep patch MobileGestalt hardware cache
            patchFullMGCache(g_fakeConfig);

            // 2. Mount carrier spoof
            Class carrierCls = [CTCarrier class];
            swizzle(carrierCls, @selector(carrierName), @selector(fake_carrierName));
            swizzle(carrierCls, @selector(mobileCountryCode), @selector(fake_mobileCountryCode));
            swizzle(carrierCls, @selector(mobileNetworkCode), @selector(fake_mobileNetworkCode));
            swizzle(carrierCls, @selector(isoCountryCode), @selector(fake_isoCountryCode));

            // 3. Clear pasteboard cross-process persistence
            [[UIPasteboard generalPasteboard] setItems:@[]];
        }
    }
}

@end
