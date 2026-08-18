#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AdSupport/AdSupport.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <syslog.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#import <IOKit/IOKitLib.h>
#import "WiperHelper.h"

// ============================================================
// dlsym 运行时解析 MSHookFunction — 无编译期 ellekit 依赖
// ============================================================
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

// ============================================================
// 全局状态
// ============================================================
static NSDictionary *g_fakeConfig = nil;
static BOOL g_isEnabled = NO;
static BOOL g_isHooked = NO;  // 双重 Hook 防护

// 重入守卫 — 防止 stat/access/sysctl 无限递归导致栈溢出
static __thread int g_reentrancyDepth = 0;

// ============================================================
// 1. IOKit 内核级 Hook (序列号/UDID/ECID/电池)
// ============================================================
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
            return (__bridge_retained CFTypeRef)@(250);
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

// ============================================================
// 2. sysctlbyname (hw.machine / hw.memsize / CPU)
// ============================================================
static int (*orig_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) = NULL;
static int fake_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (g_isEnabled && name != NULL) {
        if (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0) {
            NSString *val = g_fakeConfig[@"hw.machine"] ?: @"iPhone16,2";
            const char *str = [val UTF8String];
            size_t len = strlen(str) + 1;
            if (oldp && oldlenp && *oldlenp >= len) {
                memcpy(oldp, str, len);
                *oldlenp = len;
                return 0;
            }
        }
        if (strcmp(name, "hw.memsize") == 0) {
            uint64_t ram = 8589934592ULL;
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

// ============================================================
// 3. sysctl KERN_PROC — 越狱进程封锁 (带重入守卫)
// ============================================================
static int (*orig_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) = NULL;
static int fake_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (g_reentrancyDepth > 0) {
        return orig_sysctl ? orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen) : -1;
    }
    g_reentrancyDepth++;

    int ret = orig_sysctl ? orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen) : -1;

    if (g_isEnabled && ret == 0 && oldp && name && name[0] == CTL_KERN && name[1] == KERN_PROC) {
        struct kinfo_proc *procList = (struct kinfo_proc *)oldp;
        int count = (int)(*oldlenp / sizeof(struct kinfo_proc));
        int filteredCount = 0;
        for (int i = 0; i < count; i++) {
            char *procName = procList[i].kp_proc.p_comm;
            if (strstr(procName, "cydia") || strstr(procName, "sileo") ||
                strstr(procName, "frida") || strstr(procName, "substrate") ||
                strstr(procName, "ellekit") || strstr(procName, "ssh") ||
                strstr(procName, "dropbear") || strstr(procName, "sshd") ||
                strstr(procName, "zebra") || strstr(procName, "checkra1n") ||
                strstr(procName, "dopamine") || strstr(procName, "palera1n") ||
                strstr(procName, "trollstore")) {
                continue;
            }
            if (filteredCount != i) {
                memcpy(&procList[filteredCount], &procList[i], sizeof(struct kinfo_proc));
            }
            filteredCount++;
        }
        *oldlenp = filteredCount * sizeof(struct kinfo_proc);
    }

    g_reentrancyDepth--;
    return ret;
}

// ============================================================
// 4. stat — 越狱文件封锁 (带重入守卫)
// ============================================================
static int (*orig_stat)(const char *path, struct stat *buf) = NULL;
static int fake_stat(const char *path, struct stat *buf) {
    if (g_reentrancyDepth > 0) {
        return orig_stat ? orig_stat(path, buf) : -1;
    }
    g_reentrancyDepth++;

    int result;
    if (g_isEnabled && path != NULL) {
        if (strstr(path, "/var/jb") || strstr(path, "Cydia") || strstr(path, "Sileo") ||
            strstr(path, "MobileSubstrate") || strstr(path, "ellekit") || strstr(path, "frida") ||
            strstr(path, "/bin/bash") || strstr(path, "/usr/sbin/sshd") ||
            strstr(path, "Zebra") || strstr(path, "checkra1n") || strstr(path, "dopamine") ||
            strstr(path, "/etc/apt") || strstr(path, "/var/lib/apt") ||
            strstr(path, "/Applications/Cydia") || strstr(path, "/Applications/Sileo") ||
            strstr(path, "/Applications/Zebra") || strstr(path, "TrollStore")) {
            errno = ENOENT;
            result = -1;
            goto cleanup;
        }
    }
    result = orig_stat ? orig_stat(path, buf) : -1;

cleanup:
    g_reentrancyDepth--;
    return result;
}

// ============================================================
// 5. access — 越狱文件封锁 (带重入守卫)
// ============================================================
static int (*orig_access)(const char *path, int mode) = NULL;
static int fake_access(const char *path, int mode) {
    if (g_reentrancyDepth > 0) {
        return orig_access ? orig_access(path, mode) : -1;
    }
    g_reentrancyDepth++;

    int result;
    if (g_isEnabled && path != NULL) {
        if (strstr(path, "/var/jb") || strstr(path, "Cydia") || strstr(path, "Sileo") ||
            strstr(path, "MobileSubstrate") || strstr(path, "ellekit") || strstr(path, "frida") ||
            strstr(path, "Zebra") || strstr(path, "checkra1n") || strstr(path, "dopamine") ||
            strstr(path, "/bin/bash") || strstr(path, "/usr/sbin/sshd") ||
            strstr(path, "/etc/apt") || strstr(path, "/var/lib/apt") ||
            strstr(path, "TrollStore")) {
            errno = ENOENT;
            result = -1;
            goto cleanup;
        }
    }
    result = orig_access ? orig_access(path, mode) : -1;

cleanup:
    g_reentrancyDepth--;
    return result;
}

// ============================================================
// 6. SCNetworkReachability — 直连伪装 (仅在原函数返回 YES 时修改)
// ============================================================
static Boolean (*orig_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) = NULL;
static Boolean fake_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    Boolean ret = orig_SCNetworkReachabilityGetFlags ? orig_SCNetworkReachabilityGetFlags(target, flags) : NO;
    if (g_isEnabled && ret == YES && flags) {
        *flags &= ~kSCNetworkReachabilityFlagsConnectionRequired;
        *flags &= ~kSCNetworkReachabilityFlagsConnectionAutomatic;
        *flags |= kSCNetworkReachabilityFlagsReachable;
        *flags |= kSCNetworkReachabilityFlagsIsDirect;
    }
    return ret;
}

// ============================================================
// 7. UIScreen — 动态分辨率伪装
// ============================================================
@interface UIScreen (DynamicScreen)
- (CGRect)dynamic_bounds;
- (CGFloat)dynamic_scale;
@end
@implementation UIScreen (DynamicScreen)
- (CGRect)dynamic_bounds {
    if (g_isEnabled && g_fakeConfig[@"ScreenWidth"] && g_fakeConfig[@"ScreenHeight"]) {
        return CGRectMake(0, 0,
            [g_fakeConfig[@"ScreenWidth"] doubleValue],
            [g_fakeConfig[@"ScreenHeight"] doubleValue]);
    }
    return [self dynamic_bounds];
}
- (CGFloat)dynamic_scale {
    if (g_isEnabled && g_fakeConfig[@"ScreenScale"]) return [g_fakeConfig[@"ScreenScale"] doubleValue];
    return [self dynamic_scale];
}
@end

// ============================================================
// 8. NSFileManager — 动态磁盘容量
// ============================================================
@interface NSFileManager (DynamicDisk)
- (NSDictionary *)dynamic_attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error;
@end
@implementation NSFileManager (DynamicDisk)
- (NSDictionary *)dynamic_attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error {
    NSDictionary *original = [self dynamic_attributesOfFileSystemForPath:path error:error];
    if (g_isEnabled && original) {
        NSMutableDictionary *attrs = [original mutableCopy];
        if (g_fakeConfig[@"TotalDiskSize"]) {
            unsigned long long total = [g_fakeConfig[@"TotalDiskSize"] unsignedLongLongValue];
            attrs[NSFileSystemSize] = @(total);
            attrs[NSFileSystemFreeSize] = @(total * 0.8);
        }
        return attrs;
    }
    return original;
}
@end

// ============================================================
// 9. NSLocale — dispatch_once 静态单例防递归
// [[NSLocale alloc] initWithLocaleIdentifier:] 底层会触发 currentLocale
// 导致无限递归死锁。改用 localeWithLocaleIdentifier: + dispatch_once
// ============================================================
@interface NSLocale (FakeLocale)
+ (id)fake_currentLocale;
+ (id)fake_autoupdatingCurrentLocale;
@end
@implementation NSLocale (FakeLocale)
+ (id)fake_currentLocale {
    if (g_isEnabled) {
        static NSLocale *fakeLocale = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            fakeLocale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        });
        return fakeLocale;
    }
    return [NSLocale fake_currentLocale];
}
+ (id)fake_autoupdatingCurrentLocale {
    if (g_isEnabled) {
        static NSLocale *fakeAutoLocale = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            fakeAutoLocale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        });
        return fakeAutoLocale;
    }
    return [NSLocale fake_autoupdatingCurrentLocale];
}
@end

// ============================================================
// 10. NSTimeZone — dispatch_once 静态单例防递归
// ============================================================
@interface NSTimeZone (FakeTimeZone)
+ (NSTimeZone *)fake_localTimeZone;
@end
@implementation NSTimeZone (FakeTimeZone)
+ (NSTimeZone *)fake_localTimeZone {
    if (g_isEnabled) {
        static NSTimeZone *fakeTZ = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            fakeTZ = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
        });
        return fakeTZ;
    }
    return [NSTimeZone fake_localTimeZone];
}
@end

// ============================================================
// 11. WKWebView — 动态 User-Agent
// ============================================================
@interface WKWebView (DynamicUA)
- (NSString *)dynamic_customUserAgent;
@end
@implementation WKWebView (DynamicUA)
- (NSString *)dynamic_customUserAgent {
    if (g_isEnabled && g_fakeConfig[@"SystemVersion"]) {
        NSString *sysVer = [g_fakeConfig[@"SystemVersion"] stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        return [NSString stringWithFormat:
            @"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", sysVer];
    }
    return [self dynamic_customUserAgent];
}
@end

// ============================================================
// 12. CTCarrier — 运营商伪装
// ============================================================
@interface CTCarrier (DynamicCarrier)
- (NSString *)dynamic_carrierName;
- (NSString *)dynamic_mobileCountryCode;
- (NSString *)dynamic_mobileNetworkCode;
- (NSString *)dynamic_isoCountryCode;
@end
@implementation CTCarrier (DynamicCarrier)
- (NSString *)dynamic_carrierName { return @"中国移动"; }
- (NSString *)dynamic_mobileCountryCode { return @"460"; }
- (NSString *)dynamic_mobileNetworkCode { return @"00"; }
- (NSString *)dynamic_isoCountryCode { return @"cn"; }
@end

// ============================================================
// 13. CTTelephonyNetworkInfo — 网络信息伪装
// ============================================================
@interface CTTelephonyNetworkInfo (DynamicNetwork)
- (NSDictionary *)dynamic_serviceSubscriberCellularProviders;
@end
@implementation CTTelephonyNetworkInfo (DynamicNetwork)
- (NSDictionary *)dynamic_serviceSubscriberCellularProviders {
    if (g_isEnabled) return @{@"00000001-0000-0000-0000-000000000001": [CTCarrier new]};
    return [self dynamic_serviceSubscriberCellularProviders];
}
@end

// ============================================================
// Hook 安装器 — +load 抢跑 + fallback 双保险
// ============================================================
@interface UltimateEarlyLoader : NSObject
@end

@implementation UltimateEarlyLoader

+ (void)load {
    @autoreleasepool {
        // 注册 fallback: 如果 +load 阶段 dlsym 失败，App 启动后重试
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(setupHooksFallback)
                                                     name:UIApplicationDidFinishLaunchingNotification
                                                   object:nil];
        // 尝试 +load 阶段立即安装 (抢跑防检测)
        [self setupHooks];
    }
}

+ (void)setupHooksFallback {
    if (!g_isHooked) {
        syslog(LOG_NOTICE, "[Hooks] Fallback: retrying in didFinishLaunching");
        [self setupHooks];
    }
}

+ (void)setupHooks {
    if (g_isHooked) return;  // 双重 Hook 防护
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
        syslog(LOG_NOTICE, "[Hooks] setupHooks starting for %s", [bundleID UTF8String]);

        // --- C 函数 Hook (dlsym 解析 MSHookFunction) ---
        if (!initHookFramework()) {
            syslog(LOG_ERR, "[Hooks] MSHookFunction not resolved — C hooks skipped, ObjC swizzle only");
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

            @try {
                g_MSHookFunction((void *)sysctl,
                                 (void *)fake_sysctl,
                                 (void **)&orig_sysctl);
                syslog(LOG_NOTICE, "[Hooks] sysctl KERN_PROC hook installed (process hiding)");
            } @catch (NSException *e) {
                syslog(LOG_ERR, "[Hooks] sysctl hook error: %s", [e.reason UTF8String]);
            }

            @try {
                g_MSHookFunction((void *)stat,
                                 (void *)fake_stat,
                                 (void **)&orig_stat);
                syslog(LOG_NOTICE, "[Hooks] stat hook installed (file hiding)");
            } @catch (NSException *e) {
                syslog(LOG_ERR, "[Hooks] stat hook error: %s", [e.reason UTF8String]);
            }

            @try {
                g_MSHookFunction((void *)access,
                                 (void *)fake_access,
                                 (void **)&orig_access);
                syslog(LOG_NOTICE, "[Hooks] access hook installed (file hiding)");
            } @catch (NSException *e) {
                syslog(LOG_ERR, "[Hooks] access hook error: %s", [e.reason UTF8String]);
            }

            @try {
                g_MSHookFunction((void *)SCNetworkReachabilityGetFlags,
                                 (void *)fake_SCNetworkReachabilityGetFlags,
                                 (void **)&orig_SCNetworkReachabilityGetFlags);
                syslog(LOG_NOTICE, "[Hooks] SCNetworkReachability hook installed (direct connection)");
            } @catch (NSException *e) {
                syslog(LOG_ERR, "[Hooks] SCNetworkReachability hook error: %s", [e.reason UTF8String]);
            }
        }

        // --- ObjC 方法交换 (dispatch_once 防递归 + @try/@catch) ---

        @try {
            Class screenCls = [UIScreen class];
            method_exchangeImplementations(
                class_getInstanceMethod(screenCls, @selector(bounds)),
                class_getInstanceMethod(screenCls, @selector(dynamic_bounds)));
            method_exchangeImplementations(
                class_getInstanceMethod(screenCls, @selector(scale)),
                class_getInstanceMethod(screenCls, @selector(dynamic_scale)));
            syslog(LOG_NOTICE, "[Hooks] UIScreen swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] UIScreen swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class fmCls = [NSFileManager class];
            method_exchangeImplementations(
                class_getInstanceMethod(fmCls, @selector(attributesOfFileSystemForPath:error:)),
                class_getInstanceMethod(fmCls, @selector(dynamic_attributesOfFileSystemForPath:error:)));
            syslog(LOG_NOTICE, "[Hooks] NSFileManager swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] NSFileManager swizzle error: %s", [e.reason UTF8String]);
        }

        // NSLocale: dispatch_once 静态单例 — 彻底杜绝 initWithLocaleIdentifier 反向触发 currentLocale 递归死锁
        @try {
            Class localeCls = [NSLocale class];
            method_exchangeImplementations(
                class_getClassMethod(localeCls, @selector(currentLocale)),
                class_getClassMethod(localeCls, @selector(fake_currentLocale)));
            method_exchangeImplementations(
                class_getClassMethod(localeCls, @selector(autoupdatingCurrentLocale)),
                class_getClassMethod(localeCls, @selector(fake_autoupdatingCurrentLocale)));
            syslog(LOG_NOTICE, "[Hooks] NSLocale swizzle installed (dispatch_once anti-recursion)");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] NSLocale swizzle error: %s", [e.reason UTF8String]);
        }

        // NSTimeZone: 同样使用 dispatch_once 防递归
        @try {
            Class tzCls = [NSTimeZone class];
            method_exchangeImplementations(
                class_getClassMethod(tzCls, @selector(localTimeZone)),
                class_getClassMethod(tzCls, @selector(fake_localTimeZone)));
            syslog(LOG_NOTICE, "[Hooks] NSTimeZone swizzle installed (dispatch_once anti-recursion)");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] NSTimeZone swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class wkCls = [WKWebView class];
            method_exchangeImplementations(
                class_getInstanceMethod(wkCls, @selector(customUserAgent)),
                class_getInstanceMethod(wkCls, @selector(dynamic_customUserAgent)));
            syslog(LOG_NOTICE, "[Hooks] WKWebView swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] WKWebView swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class carrierCls = [CTCarrier class];
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(carrierName)),
                class_getInstanceMethod(carrierCls, @selector(dynamic_carrierName)));
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(mobileCountryCode)),
                class_getInstanceMethod(carrierCls, @selector(dynamic_mobileCountryCode)));
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(mobileNetworkCode)),
                class_getInstanceMethod(carrierCls, @selector(dynamic_mobileNetworkCode)));
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(isoCountryCode)),
                class_getInstanceMethod(carrierCls, @selector(dynamic_isoCountryCode)));
            syslog(LOG_NOTICE, "[Hooks] CTCarrier swizzle installed (4 methods)");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] CTCarrier swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class netInfoCls = [CTTelephonyNetworkInfo class];
            method_exchangeImplementations(
                class_getInstanceMethod(netInfoCls, @selector(serviceSubscriberCellularProviders)),
                class_getInstanceMethod(netInfoCls, @selector(dynamic_serviceSubscriberCellularProviders)));
            syslog(LOG_NOTICE, "[Hooks] CTTelephonyNetworkInfo swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] CTTelephonyNetworkInfo swizzle error: %s", [e.reason UTF8String]);
        }

        // 清空剪贴板
        @try {
            [[UIPasteboard generalPasteboard] setItems:@[]];
        } @catch (NSException *e) {
            // 非关键
        }

        syslog(LOG_NOTICE, "[Hooks] All hooks processed for %s", [bundleID UTF8String]);
    }
}

@end
