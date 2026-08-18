#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AdSupport/AdSupport.h>
#import <CoreTelephony/CTCarrier.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <syslog.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#import <IOKit/IOKitLib.h>
#import "WiperHelper.h"

// Runtime-resolved MSHookFunction via dlsym — no build-time ellekit dependency
typedef void (*MSHookFunction_t)(void *symbol, void *replacement, void **original);
static MSHookFunction_t g_MSHookFunction = NULL;

static BOOL initHookFramework(void) {
    if (g_MSHookFunction) return YES;
    g_MSHookFunction = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!g_MSHookFunction) {
        void *handle = dlopen("/var/jb/usr/lib/TweakInject.dylib", RTLD_NOW);
        if (!handle) handle = dlopen("/usr/lib/TweakInject.dylib", RTLD_NOW);
        if (!handle) handle = dlopen("/var/jb/usr/lib/libellekit.dylib", RTLD_NOW);
        if (handle) {
            g_MSHookFunction = (MSHookFunction_t)dlsym(handle, "MSHookFunction");
        }
    }
    return g_MSHookFunction != NULL;
}

static NSDictionary *g_fakeConfig = nil;
static BOOL g_isEnabled = NO;
static BOOL g_isHooked = NO;

// CRITICAL: Do NOT hook stat/access/getenv/sysctl (process list).
// These are used internally by jbroot/ellekit path resolution and cause
// infinite recursion -> stack overflow (___chkstk_darwin crash).

#pragma mark - 1. IOKit kernel-level hooks (serial, UDID, ECID, battery)

static CFTypeRef (*orig_IORegistryEntryCreateCFProperty)(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) = NULL;
static CFTypeRef fake_IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) {
    if (g_isEnabled && key) {
        NSString *keyStr = (__bridge NSString *)key;
        if ([keyStr isEqualToString:@"IOPlatformSerialNumber"] || [keyStr isEqualToString:@"serial-number"]) {
            if (g_fakeConfig[@"SerialNumber"]) return (__bridge_retained CFTypeRef)g_fakeConfig[@"SerialNumber"];
        }
        if ([keyStr isEqualToString:@"IOPlatformUUID"]) {
            if (g_fakeConfig[@"UniqueDeviceID"]) return (__bridge_retained CFTypeRef)g_fakeConfig[@"UniqueDeviceID"];
        }
        if ([keyStr isEqualToString:@"IOPlatformECID"] || [keyStr isEqualToString:@"ECID"]) {
            unsigned long long ecid = 0;
            if (g_fakeConfig[@"ECID"]) ecid = [g_fakeConfig[@"ECID"] unsignedLongLongValue];
            if (ecid == 0) ecid = 3849201847291ULL;
            return (__bridge_retained CFTypeRef)@(ecid);
        }
        if ([keyStr isEqualToString:@"BatteryTemperature"] || [keyStr isEqualToString:@"Temperature"]) {
            return (__bridge_retained CFTypeRef)@(250); // 25.0 C
        }
        if ([keyStr isEqualToString:@"BatteryCurrentCapacity"]) {
            return (__bridge_retained CFTypeRef)@(95);
        }
        if ([keyStr isEqualToString:@"BatteryMaxCapacity"]) {
            return (__bridge_retained CFTypeRef)@(3500);
        }
    }
    return orig_IORegistryEntryCreateCFProperty ? orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options) : NULL;
}

#pragma mark - 2. sysctlbyname (hw.machine, hw.memsize, CPU — safe, NOT path resolution)

static int (*orig_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) = NULL;
static int fake_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
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
        if (strcmp(name, "hw.memsize") == 0) {
            uint64_t ram = 8589934592ULL; // 8GB
            if (oldp && oldlenp && *oldlenp >= sizeof(ram)) {
                memcpy(oldp, &ram, sizeof(ram));
                *oldlenp = sizeof(ram);
                return 0;
            }
        }
        if (strcmp(name, "hw.logicalcpu") == 0 || strcmp(name, "hw.physicalcpu") == 0) {
            int cpus = 6;
            if (oldp && oldlenp && *oldlenp >= sizeof(cpus)) {
                memcpy(oldp, &cpus, sizeof(cpus));
                *oldlenp = sizeof(cpus);
                return 0;
            }
        }
    }
    return orig_sysctlbyname ? orig_sysctlbyname(name, oldp, oldlenp, newp, newlen) : -1;
}

#pragma mark - 3. Dynamic self-consistent screen resolution (reads from config)

@interface UIScreen (DynamicFakeScreen)
- (CGRect)safe_bounds;
- (CGFloat)safe_scale;
@end
@implementation UIScreen (DynamicFakeScreen)
- (CGRect)safe_bounds {
    if (g_isEnabled && g_fakeConfig[@"ScreenWidth"] && g_fakeConfig[@"ScreenHeight"]) {
        CGFloat w = [g_fakeConfig[@"ScreenWidth"] doubleValue];
        CGFloat h = [g_fakeConfig[@"ScreenHeight"] doubleValue];
        return CGRectMake(0, 0, w, h);
    }
    return [self safe_bounds];
}
- (CGFloat)safe_scale {
    if (g_isEnabled && g_fakeConfig[@"ScreenScale"]) {
        return [g_fakeConfig[@"ScreenScale"] doubleValue];
    }
    return [self safe_scale];
}
@end

#pragma mark - 4. NSFileManager disk capacity (ObjC swizzle — safe)

@interface NSFileManager (SafeFakeDisk)
- (NSDictionary *)safe_attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error;
@end
@implementation NSFileManager (SafeFakeDisk)
- (NSDictionary *)safe_attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error {
    NSDictionary *original = [self safe_attributesOfFileSystemForPath:path error:error];
    if (g_isEnabled && original) {
        NSMutableDictionary *attrs = [original mutableCopy];
        attrs[NSFileSystemSize] = @(256000000000ULL);      // 256GB
        attrs[NSFileSystemFreeSize] = @(200000000000ULL);   // 200GB free
        return attrs;
    }
    return original;
}
@end

#pragma mark - 5. WKWebView User-Agent (ObjC swizzle — safe)

@interface WKWebView (SafeFakeUA)
- (NSString *)safe_customUserAgent;
@end
@implementation WKWebView (SafeFakeUA)
- (NSString *)safe_customUserAgent {
    if (g_isEnabled) {
        return @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
    }
    return [self safe_customUserAgent];
}
@end

#pragma mark - 6. NSMutableURLRequest User-Agent (ObjC swizzle — safe)

@interface NSMutableURLRequest (SafeFakeUA)
- (void)safe_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field;
@end
@implementation NSMutableURLRequest (SafeFakeUA)
- (void)safe_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (g_isEnabled && field && [field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        value = @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
    }
    [self safe_setValue:value forHTTPHeaderField:field];
}
@end

#pragma mark - 7. Carrier spoofing (ObjC swizzle — safe, all 4 methods)

@interface CTCarrier (SafeFakeCarrier)
- (NSString *)safe_carrierName;
- (NSString *)safe_mobileCountryCode;
- (NSString *)safe_mobileNetworkCode;
- (NSString *)safe_isoCountryCode;
@end
@implementation CTCarrier (SafeFakeCarrier)
- (NSString *)safe_carrierName { return @"中国移动"; }
- (NSString *)safe_mobileCountryCode { return @"460"; }
- (NSString *)safe_mobileNetworkCode { return @"00"; }
- (NSString *)safe_isoCountryCode { return @"cn"; }
@end

#pragma mark - 8. Safe deferred boot entry (zero +load risk)

@interface StableHookLoader : NSObject
@end

@implementation StableHookLoader

// +load: ONLY register notification observer. No UIKit/WebKit/dlsym calls.
+ (void)load {
    @autoreleasepool {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(setupHooks)
                                                     name:UIApplicationDidFinishLaunchingNotification
                                                   object:nil];
    }
}

// setupHooks: called after app finished launching — all frameworks loaded
+ (void)setupHooks {
    if (g_isHooked) return; // Prevent double-hooking
    g_isHooked = YES;

    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID || [bundleID hasPrefix:@"com.apple."]) return;
        if ([bundleID isEqualToString:@"com.custom.appwiper.ui"]) return;

        NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
        if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) return;

        g_fakeConfig = [NSDictionary dictionaryWithContentsOfFile:configPath];
        if (!g_fakeConfig || ![g_fakeConfig[@"enabled"] boolValue]) return;

        g_isEnabled = YES;
        syslog(LOG_NOTICE, "[Hooks] setupHooks starting for %s (screen: %@x%@ @%@)",
               [bundleID UTF8String],
               g_fakeConfig[@"ScreenWidth"],
               g_fakeConfig[@"ScreenHeight"],
               g_fakeConfig[@"ScreenScale"]);

        // --- C function hooks (only safe ones, NO stat/access/getenv/sysctl) ---

        if (!initHookFramework()) {
            syslog(LOG_ERR, "[Hooks] MSHookFunction not resolved — C hooks skipped");
        } else {
            @try {
                g_MSHookFunction((void *)IORegistryEntryCreateCFProperty,
                              (void *)fake_IORegistryEntryCreateCFProperty,
                              (void **)&orig_IORegistryEntryCreateCFProperty);
                syslog(LOG_NOTICE, "[Hooks] IOKit hook installed");
            } @catch (NSException *e) {
                syslog(LOG_ERR, "[Hooks] IOKit hook error: %s", [e.reason UTF8String]);
            }

            @try {
                g_MSHookFunction((void *)sysctlbyname,
                              (void *)fake_sysctlbyname,
                              (void **)&orig_sysctlbyname);
                syslog(LOG_NOTICE, "[Hooks] sysctlbyname hook installed");
            } @catch (NSException *e) {
                syslog(LOG_ERR, "[Hooks] sysctlbyname hook error: %s", [e.reason UTF8String]);
            }
        }

        // --- ObjC method swizzling (all safe, each in @try/@catch) ---

        @try {
            Class screenCls = [UIScreen class];
            method_exchangeImplementations(
                class_getInstanceMethod(screenCls, @selector(bounds)),
                class_getInstanceMethod(screenCls, @selector(safe_bounds)));
            method_exchangeImplementations(
                class_getInstanceMethod(screenCls, @selector(scale)),
                class_getInstanceMethod(screenCls, @selector(safe_scale)));
            syslog(LOG_NOTICE, "[Hooks] UIScreen dynamic swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] UIScreen swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class fmCls = [NSFileManager class];
            method_exchangeImplementations(
                class_getInstanceMethod(fmCls, @selector(attributesOfFileSystemForPath:error:)),
                class_getInstanceMethod(fmCls, @selector(safe_attributesOfFileSystemForPath:error:)));
            syslog(LOG_NOTICE, "[Hooks] NSFileManager swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] NSFileManager swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class wkCls = [WKWebView class];
            method_exchangeImplementations(
                class_getInstanceMethod(wkCls, @selector(customUserAgent)),
                class_getInstanceMethod(wkCls, @selector(safe_customUserAgent)));
            syslog(LOG_NOTICE, "[Hooks] WKWebView swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] WKWebView swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class reqCls = [NSMutableURLRequest class];
            method_exchangeImplementations(
                class_getInstanceMethod(reqCls, @selector(setValue:forHTTPHeaderField:)),
                class_getInstanceMethod(reqCls, @selector(safe_setValue:forHTTPHeaderField:)));
            syslog(LOG_NOTICE, "[Hooks] NSMutableURLRequest swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] NSURLRequest swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class carrierCls = [CTCarrier class];
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(carrierName)),
                class_getInstanceMethod(carrierCls, @selector(safe_carrierName)));
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(mobileCountryCode)),
                class_getInstanceMethod(carrierCls, @selector(safe_mobileCountryCode)));
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(mobileNetworkCode)),
                class_getInstanceMethod(carrierCls, @selector(safe_mobileNetworkCode)));
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(isoCountryCode)),
                class_getInstanceMethod(carrierCls, @selector(safe_isoCountryCode)));
            syslog(LOG_NOTICE, "[Hooks] CTCarrier swizzle installed (4 methods)");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] CTCarrier swizzle error: %s", [e.reason UTF8String]);
        }

        // Clear pasteboard
        @try {
            [[UIPasteboard generalPasteboard] setItems:@[]];
        } @catch (NSException *e) {
            // Non-critical
        }

        syslog(LOG_NOTICE, "[Hooks] All hooks processed for %s", [bundleID UTF8String]);
    }
}

@end
