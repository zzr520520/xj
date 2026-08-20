// ============================================================
// AppWiper Hooks.m v2.04 — 商业级完整版
// v2.01: 飞行模式模拟 / 无卡模拟 / WiFi SSID-BSSID伪造 /
//        UIDevice伪装 / radioAccessTechnology / uname / 电池伪装
// v2.02: 系统版本全链路伪装 (NSProcessInfo + sysctl kern.osversion) /
//        定位伪造 (LocationFaker 集成)
// v2.03: 网络伪装模块 (NetworkFaker: 运营商/RadioTech/SCNetworkReachability)
// v2.04: 电池状态全量伪装 (健康度/循环次数/充电状态/温度/容量) 从配置读取
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ============================================================
// 开关控制 (全部启用)
// ============================================================
#define EMERGENCY_MODE      0
#define HOOK_ENABLE_IOKIT   1
#define HOOK_ENABLE_SYSCTL  1
#define HOOK_ENABLE_SYSPROC 1   // v2.01: 启用进程列表过滤
#define HOOK_ENABLE_STAT    1   // v2.01: 启用越狱路径封锁
#define HOOK_ENABLE_ACCESS  1   // v2.01: 启用越狱路径封锁
#define HOOK_ENABLE_SCNET   1   // v2.01: 启用网络可达性
#define HOOK_ENABLE_SCREEN  1
#define HOOK_ENABLE_DISK    1
#define HOOK_ENABLE_LOCALE  1
#define HOOK_ENABLE_TIMEZONE 1
#define HOOK_ENABLE_UA      1
#define HOOK_ENABLE_CARRIER 1
#define HOOK_ENABLE_NETINFO 1
#define HOOK_ENABLE_UNAME   1   // v2.01: 新增 uname Hook
#define HOOK_ENABLE_WIFI    1   // v2.01: 新增 WiFi SSID/BSSID 伪造
#define HOOK_ENABLE_UIDEVICE 1  // v2.01: 新增 UIDevice 伪装
#define HOOK_ENABLE_SYSVER   1  // v2.02: 系统版本全链路伪装 (NSProcessInfo + sysctl kern.osversion)
#define HOOK_ENABLE_LOCATION 1  // v2.02: 定位伪造 (LocationFaker)

// ============================================================
// 条件导入
// ============================================================
#if !EMERGENCY_MODE
#import <WebKit/WebKit.h>
#import <AdSupport/AdSupport.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <syslog.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <IOKit/IOKitLib.h>
#import <CoreLocation/CoreLocation.h>
#import "WiperHelper.h"
#import "LocationFaker.h"
#import "NetworkFaker.h"
#endif

// ============================================================
// 空壳模式
// ============================================================
#if EMERGENCY_MODE

@interface SafeEmergencyLoader : NSObject
@end

@implementation SafeEmergencyLoader

+ (void)load {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID) return;
        if ([bundleID hasPrefix:@"com.apple."]) return;
        if ([bundleID isEqualToString:@"com.custom.appwiper.ui"]) return;
        NSLog(@"[AppWiper] Emergency Safe Loader: %@ — no hooks installed.", bundleID);
    }
}

@end

// ============================================================
// 完整模式
// ============================================================
#else

// ============================================================
// dlsym 运行时解析 MSHookFunction (不使用 ellekit 编译期链接)
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

static NSDictionary *g_fakeConfig = nil;
static BOOL g_isEnabled = NO;
static BOOL g_isHooked = NO;
static int g_hookMode = 2;
static __thread int g_reentrancyDepth = 0;

// ============================================================
// 1. IOKit (序列号, UUID, ECID, 电池)
// ============================================================
#if HOOK_ENABLE_IOKIT
static CFTypeRef (*orig_IORegistryEntryCreateCFProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t) = NULL;
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
            unsigned long long ecid = [g_fakeConfig[@"ECID"] unsignedLongLongValue];
            if (ecid == 0) ecid = 3849201847291ULL;
            return (__bridge_retained CFTypeRef)@(ecid);
        }
        // v2.04: 电池伪装 (从配置读取, 支持完整电池属性)
        if ([keyStr isEqualToString:@"BatteryTemperature"] || [keyStr isEqualToString:@"Temperature"]) {
            if (g_fakeConfig[@"BatteryTemperature"]) return (__bridge_retained CFTypeRef)g_fakeConfig[@"BatteryTemperature"];
            return (__bridge_retained CFTypeRef)@(250);
        }
        if ([keyStr isEqualToString:@"BatteryCurrentCapacity"] || [keyStr isEqualToString:@"CurrentCapacity"]) {
            if (g_fakeConfig[@"BatteryCurrentCapacity"]) return (__bridge_retained CFTypeRef)g_fakeConfig[@"BatteryCurrentCapacity"];
            return (__bridge_retained CFTypeRef)@(95);
        }
        if ([keyStr isEqualToString:@"BatteryHealth"] || [keyStr isEqualToString:@"Health"]) {
            if (g_fakeConfig[@"BatteryHealth"]) return (__bridge_retained CFTypeRef)g_fakeConfig[@"BatteryHealth"];
        }
        if ([keyStr isEqualToString:@"BatteryCycleCount"] || [keyStr isEqualToString:@"CycleCount"]) {
            if (g_fakeConfig[@"BatteryCycleCount"]) return (__bridge_retained CFTypeRef)g_fakeConfig[@"BatteryCycleCount"];
        }
        if ([keyStr isEqualToString:@"BatteryIsCharging"] || [keyStr isEqualToString:@"IsCharging"] || [keyStr isEqualToString:@"Charging"]) {
            BOOL charging = [g_fakeConfig[@"IsCharging"] boolValue];
            return (__bridge_retained CFTypeRef)@(charging ? 1 : 0);
        }
        if ([keyStr isEqualToString:@"BatteryMaxCapacity"] || [keyStr isEqualToString:@"MaxCapacity"]) {
            if (g_fakeConfig[@"BatteryMaxCapacity"]) return (__bridge_retained CFTypeRef)g_fakeConfig[@"BatteryMaxCapacity"];
        }
        if ([keyStr isEqualToString:@"BatteryDesignCapacity"] || [keyStr isEqualToString:@"DesignCapacity"]) {
            if (g_fakeConfig[@"BatteryDesignCapacity"]) return (__bridge_retained CFTypeRef)g_fakeConfig[@"BatteryDesignCapacity"];
        }
        if ([keyStr isEqualToString:@"BatteryCurrentMAh"] || [keyStr isEqualToString:@"CurrentMAh"]) {
            if (g_fakeConfig[@"BatteryCurrentMAh"]) return (__bridge_retained CFTypeRef)g_fakeConfig[@"BatteryCurrentMAh"];
        }
    }
    return orig_IORegistryEntryCreateCFProperty ? orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options) : NULL;
}
#endif

// ============================================================
// 2. sysctlbyname (hw.machine, hw.memsize, hw.logicalcpu)
// ============================================================
#if HOOK_ENABLE_SYSCTL
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
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
        // v2.01: 内存容量伪装 (8GB)
        if (strcmp(name, "hw.memsize") == 0) {
            uint64_t ram = 8589934592ULL;
            if (oldp && oldlenp && *oldlenp >= sizeof(ram)) {
                memcpy(oldp, &ram, sizeof(ram));
                *oldlenp = sizeof(ram);
                return 0;
            }
        }
        // v2.01: CPU 核心数伪装
        if (strcmp(name, "hw.logicalcpu") == 0 || strcmp(name, "hw.physicalcpu") == 0) {
            int cpus = 6;
            if (oldp && oldlenp && *oldlenp >= sizeof(cpus)) {
                memcpy(oldp, &cpus, sizeof(cpus));
                *oldlenp = sizeof(cpus);
                return 0;
            }
        }
        // v2.02: 系统构建版本号伪装 (kern.osversion)
        if (strcmp(name, "kern.osversion") == 0 && g_fakeConfig[@"OSBuildVersion"]) {
            const char *str = [g_fakeConfig[@"OSBuildVersion"] UTF8String];
            size_t len = strlen(str) + 1;
            if (oldp && oldlenp && *oldlenp >= len) {
                memcpy(oldp, str, len);
                *oldlenp = len;
                return 0;
            }
        }
        // v2.02: 系统版本号伪装 (kern.osrelease)
        if (strcmp(name, "kern.osrelease") == 0 && g_fakeConfig[@"SystemVersion"]) {
            const char *str = [g_fakeConfig[@"SystemVersion"] UTF8String];
            size_t len = strlen(str) + 1;
            if (oldp && oldlenp && *oldlenp >= len) {
                memcpy(oldp, str, len);
                *oldlenp = len;
                return 0;
            }
        }
    }
    return orig_sysctlbyname ? orig_sysctlbyname(name, oldp, oldlenp, newp, newlen) : -1;
}
#endif

// ============================================================
// 3. sysctl (hw.machine + 进程列表过滤)
// ============================================================
#if HOOK_ENABLE_SYSPROC
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;
static int fake_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    // v2.01: CTL_HW + HW_MACHINE 直接返回伪装机型
    if (g_isEnabled && name && namelen >= 2 && name[0] == CTL_HW && name[1] == HW_MACHINE) {
        NSString *val = g_fakeConfig[@"hw.machine"] ?: @"iPhone16,2";
        const char *str = [val UTF8String];
        size_t len = strlen(str) + 1;
        if (oldp && oldlenp && *oldlenp >= len) {
            memcpy(oldp, str, len);
            *oldlenp = len;
            return 0;
        }
    }

    if (g_reentrancyDepth > 0) return orig_sysctl ? orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen) : -1;
    g_reentrancyDepth++;
    int ret = orig_sysctl ? orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen) : -1;

    // v2.01: KERN_PROC 进程列表过滤 (隐藏越狱进程)
    if (g_isEnabled && ret == 0 && oldp && name && name[0] == CTL_KERN && name[1] == KERN_PROC) {
        struct kinfo_proc *procList = (struct kinfo_proc *)oldp;
        int count = (int)(*oldlenp / sizeof(struct kinfo_proc));
        int filteredCount = 0;
        for (int i = 0; i < count; i++) {
            char *procName = procList[i].kp_proc.p_comm;
            if (strstr(procName, "cydia") || strstr(procName, "sileo") ||
                strstr(procName, "frida") || strstr(procName, "substrate") ||
                strstr(procName, "ellekit") || strstr(procName, "ssh") ||
                strstr(procName, "dropbear") || strstr(procName, "sshd")) {
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
#endif

// ============================================================
// 4. uname (v2.01 新增)
// ============================================================
#if HOOK_ENABLE_UNAME
static int (*orig_uname)(struct utsname *) = NULL;
static int fake_uname(struct utsname *buf) {
    int ret = orig_uname ? orig_uname(buf) : -1;
    if (g_isEnabled && ret == 0 && buf) {
        NSString *machine = g_fakeConfig[@"hw.machine"] ?: @"iPhone16,2";
        strncpy(buf->machine, [machine UTF8String], sizeof(buf->machine) - 1);
        buf->machine[sizeof(buf->machine) - 1] = '\0';
    }
    return ret;
}
#endif

// ============================================================
// 5. stat (越狱路径封锁)
// ============================================================
#if HOOK_ENABLE_STAT
static int (*orig_stat)(const char *, struct stat *) = NULL;
static int fake_stat(const char *path, struct stat *buf) {
    if (g_reentrancyDepth > 0) return orig_stat ? orig_stat(path, buf) : -1;
    g_reentrancyDepth++;
    int result;
    if (g_isEnabled && path != NULL) {
        if (strstr(path, "/var/jb") || strstr(path, "/Applications/Cydia.app") ||
            strstr(path, "/bin/bash") || strstr(path, "/usr/sbin/sshd") ||
            strstr(path, "/usr/lib/libhooker.dylib") || strstr(path, "/.bootstrapped")) {
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
#endif

// ============================================================
// 6. access (越狱路径封锁)
// ============================================================
#if HOOK_ENABLE_ACCESS
static int (*orig_access)(const char *, int) = NULL;
static int fake_access(const char *path, int mode) {
    if (g_reentrancyDepth > 0) return orig_access ? orig_access(path, mode) : -1;
    g_reentrancyDepth++;
    int result;
    if (g_isEnabled && path != NULL) {
        if (strstr(path, "/var/jb") || strstr(path, "/Applications/Cydia.app") ||
            strstr(path, "/bin/bash") || strstr(path, "/usr/sbin/sshd") ||
            strstr(path, "/usr/lib/libhooker.dylib") || strstr(path, "/.bootstrapped")) {
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
#endif

// ============================================================
// 7. SCNetworkReachability (网络直连伪装 + 飞行模式模拟)
// ============================================================
#if HOOK_ENABLE_SCNET
static Boolean (*orig_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *) = NULL;
static Boolean fake_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    Boolean ret = orig_SCNetworkReachabilityGetFlags ? orig_SCNetworkReachabilityGetFlags(target, flags) : NO;
    if (g_isEnabled && ret == YES && flags) {
        // v2.01: 飞行模式 — 强制返回无网络
        if ([g_fakeConfig[@"FlightMode"] boolValue]) {
            *flags = 0;
            return YES;
        }
        // 伪装为直连
        *flags &= ~kSCNetworkReachabilityFlagsConnectionRequired;
        *flags &= ~kSCNetworkReachabilityFlagsConnectionAutomatic;
        *flags |= kSCNetworkReachabilityFlagsReachable;
        *flags |= kSCNetworkReachabilityFlagsIsDirect;
    }
    return ret;
}
#endif

// ============================================================
// 8. CNCopyCurrentNetworkInfo (WiFi SSID/BSSID 伪造) (v2.01 新增)
// ============================================================
#if HOOK_ENABLE_WIFI
static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef interfaceName) = NULL;
static CFDictionaryRef fake_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    if (g_isEnabled) {
        // 飞行模式下返回 NULL (无 WiFi)
        if ([g_fakeConfig[@"FlightMode"] boolValue]) {
            return NULL;
        }
        NSString *ssid = [NSString stringWithFormat:@"WiFi-%04X", arc4random_uniform(0xFFFF)];
        NSString *bssid = [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X",
                           arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];
        NSDictionary *info = @{
            (__bridge NSString *)kCNNetworkInfoKeySSID: ssid,
            (__bridge NSString *)kCNNetworkInfoKeyBSSID: bssid
        };
        return (__bridge_retained CFDictionaryRef)info;
    }
    return orig_CNCopyCurrentNetworkInfo ? orig_CNCopyCurrentNetworkInfo(interfaceName) : NULL;
}
#endif

// ============================================================
// 9. UIDevice (model, localizedModel, identifierForVendor) (v2.01 新增)
// ============================================================
#if HOOK_ENABLE_UIDEVICE
@interface UIDevice (FakeDevice)
- (NSString *)fake_model;
- (NSString *)fake_localizedModel;
- (NSUUID *)fake_identifierForVendor;
@end

@implementation UIDevice (FakeDevice)

- (NSString *)fake_model {
    if (g_isEnabled) return @"iPhone";
    return [self fake_model];
}

- (NSString *)fake_localizedModel {
    if (g_isEnabled) return @"iPhone";
    return [self fake_localizedModel];
}

- (NSUUID *)fake_identifierForVendor {
    if (g_isEnabled) {
        // v2.01: 基于厂商关键字的 MD5 确定性 IDFV (同一厂商返回相同 IDFV)
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSArray *parts = [bundleID componentsSeparatedByString:@"."];
        NSString *vendorKey = (parts.count > 1) ? parts[1] : bundleID;

        static NSMutableDictionary *vendorIDFVCache = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            vendorIDFVCache = [NSMutableDictionary dictionary];
        });

        NSUUID *cached = vendorIDFVCache[vendorKey];
        if (!cached) {
            NSString *seed = [NSString stringWithFormat:@"IDFV_%@", vendorKey];
            unsigned char digest[32];
            CC_SHA256([seed UTF8String], (CC_LONG)strlen([seed UTF8String]), digest);
            // v2.01: SHA-256 替代已废弃的 MD5, 取前 16 字节生成 UUID
            NSString *uuidString = [NSString stringWithFormat:
                @"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                digest[0], digest[1], digest[2], digest[3],
                digest[4], digest[5], digest[6], digest[7],
                digest[8], digest[9], digest[10], digest[11],
                digest[12], digest[13], digest[14], digest[15]];
            cached = [[NSUUID alloc] initWithUUIDString:uuidString];
            if (cached) vendorIDFVCache[vendorKey] = cached;
        }
        return cached;
    }
    return [self fake_identifierForVendor];
}

@end
#endif

// ============================================================
// 9b. NSProcessInfo (系统版本全链路伪装) (v2.02 新增)
// ============================================================
#if HOOK_ENABLE_SYSVER
@interface NSProcessInfo (FakeProcessInfo)
- (NSOperatingSystemVersion)fake_operatingSystemVersion;
- (NSString *)fake_operatingSystemVersionString;
@end
@implementation NSProcessInfo (FakeProcessInfo)
- (NSOperatingSystemVersion)fake_operatingSystemVersion {
    if (g_isEnabled && g_fakeConfig[@"SystemVersion"]) {
        NSString *verStr = g_fakeConfig[@"SystemVersion"];
        NSArray *parts = [verStr componentsSeparatedByString:@"."];
        NSOperatingSystemVersion ver;
        ver.majorVersion = parts.count > 0 ? [parts[0] integerValue] : 16;
        ver.minorVersion = parts.count > 1 ? [parts[1] integerValue] : 0;
        ver.patchVersion = parts.count > 2 ? [parts[2] integerValue] : 0;
        return ver;
    }
    return [self fake_operatingSystemVersion];
}
- (NSString *)fake_operatingSystemVersionString {
    if (g_isEnabled && g_fakeConfig[@"SystemVersion"]) {
        return [NSString stringWithFormat:@"Version %@ (Build %@)",
                g_fakeConfig[@"SystemVersion"],
                g_fakeConfig[@"OSBuildVersion"] ?: @"21A331"];
    }
    return [self fake_operatingSystemVersionString];
}
@end
#endif

// ============================================================
// 10. UIScreen (动态分辨率)
// ============================================================
#if HOOK_ENABLE_SCREEN
@interface UIScreen (DynamicScreen)
- (CGRect)dynamic_bounds;
- (CGFloat)dynamic_scale;
@end
@implementation UIScreen (DynamicScreen)
- (CGRect)dynamic_bounds {
    if (g_isEnabled && g_fakeConfig[@"ScreenWidth"] && g_fakeConfig[@"ScreenHeight"]) {
        return CGRectMake(0, 0, [g_fakeConfig[@"ScreenWidth"] doubleValue], [g_fakeConfig[@"ScreenHeight"] doubleValue]);
    }
    return [self dynamic_bounds];
}
- (CGFloat)dynamic_scale {
    if (g_isEnabled && g_fakeConfig[@"ScreenScale"]) return [g_fakeConfig[@"ScreenScale"] doubleValue];
    return [self dynamic_scale];
}
@end
#endif

// ============================================================
// 11. NSFileManager (磁盘容量伪装)
// ============================================================
#if HOOK_ENABLE_DISK
@interface NSFileManager (DynamicDisk)
- (NSDictionary *)dynamic_attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error;
@end
@implementation NSFileManager (DynamicDisk)
- (NSDictionary *)dynamic_attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error {
    NSDictionary *original = [self dynamic_attributesOfFileSystemForPath:path error:error];
    if (g_isEnabled && original && g_fakeConfig[@"TotalDiskSize"]) {
        NSMutableDictionary *attrs = [original mutableCopy];
        unsigned long long total = [g_fakeConfig[@"TotalDiskSize"] unsignedLongLongValue];
        attrs[NSFileSystemSize] = @(total);
        attrs[NSFileSystemFreeSize] = @(total * 0.8);
        return attrs;
    }
    return original;
}
@end
#endif

// ============================================================
// 12. NSLocale (dispatch_once 防递归)
// ============================================================
#if HOOK_ENABLE_LOCALE
@interface NSLocale (FakeLocale)
+ (id)fake_currentLocale;
+ (id)fake_autoupdatingCurrentLocale;
@end
@implementation NSLocale (FakeLocale)
+ (id)fake_currentLocale {
    if (g_isEnabled) {
        static NSLocale *fakeLocale = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ fakeLocale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"]; });
        return fakeLocale;
    }
    return [NSLocale fake_currentLocale];
}
+ (id)fake_autoupdatingCurrentLocale {
    if (g_isEnabled) {
        static NSLocale *fakeAutoLocale = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ fakeAutoLocale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"]; });
        return fakeAutoLocale;
    }
    return [NSLocale fake_autoupdatingCurrentLocale];
}
@end
#endif

// ============================================================
// 13. NSTimeZone (dispatch_once 防递归)
// ============================================================
#if HOOK_ENABLE_TIMEZONE
@interface NSTimeZone (FakeTimeZone)
+ (NSTimeZone *)fake_localTimeZone;
@end
@implementation NSTimeZone (FakeTimeZone)
+ (NSTimeZone *)fake_localTimeZone {
    if (g_isEnabled) {
        static NSTimeZone *fakeTZ = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ fakeTZ = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"]; });
        return fakeTZ;
    }
    return [NSTimeZone fake_localTimeZone];
}
@end
#endif

// ============================================================
// 14. WKWebView UA
// ============================================================
#if HOOK_ENABLE_UA
@interface WKWebView (DynamicUA)
- (NSString *)dynamic_customUserAgent;
@end
@implementation WKWebView (DynamicUA)
- (NSString *)dynamic_customUserAgent {
    if (g_isEnabled && g_fakeConfig[@"SystemVersion"]) {
        NSString *sysVer = [g_fakeConfig[@"SystemVersion"] stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        return [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", sysVer];
    }
    return [self dynamic_customUserAgent];
}
@end
#endif

// ============================================================
// 15. CTCarrier (无卡模拟 + 运营商伪装) (v2.01 增强)
// ============================================================
#if HOOK_ENABLE_CARRIER
@interface CTCarrier (FakeCarrier)
- (NSString *)fake_carrierName;
- (NSString *)fake_mobileCountryCode;
- (NSString *)fake_mobileNetworkCode;  // v2.01 新增
- (NSString *)fake_isoCountryCode;     // v2.01 新增
- (NSString *)fake_radioAccessTechnology; // v2.01 新增
@end
@implementation CTCarrier (FakeCarrier)
- (NSString *)fake_carrierName {
    if (g_isEnabled) {
        if ([g_fakeConfig[@"NoSIM"] boolValue]) return nil;  // 无卡模拟
        return @"中国移动";
    }
    return [self fake_carrierName];
}
- (NSString *)fake_mobileCountryCode {
    if (g_isEnabled) {
        if ([g_fakeConfig[@"NoSIM"] boolValue]) return nil;
        return @"460";
    }
    return [self fake_mobileCountryCode];
}
- (NSString *)fake_mobileNetworkCode {
    if (g_isEnabled) {
        if ([g_fakeConfig[@"NoSIM"] boolValue]) return nil;
        return @"00";
    }
    return [self fake_mobileNetworkCode];
}
- (NSString *)fake_isoCountryCode {
    if (g_isEnabled) {
        if ([g_fakeConfig[@"NoSIM"] boolValue]) return nil;
        return @"cn";
    }
    return [self fake_isoCountryCode];
}
- (NSString *)fake_radioAccessTechnology {
    if (g_isEnabled) {
        if ([g_fakeConfig[@"NoSIM"] boolValue] || [g_fakeConfig[@"FlightMode"] boolValue]) return nil;
        // v2.01: 随机返回 4G(LTE) 或 5G(NR)
        NSArray *techs = @[@"CTRadioAccessTechnologyLTE", @"CTRadioAccessTechnologyNR"];
        return techs[arc4random_uniform((uint32_t)techs.count)];
    }
    return [self fake_radioAccessTechnology];
}
@end
#endif

// ============================================================
// 16. CTTelephonyNetworkInfo (无卡模拟 + 网络类型) (v2.01 增强)
// ============================================================
#if HOOK_ENABLE_NETINFO
@interface CTTelephonyNetworkInfo (FakeNetwork)
- (NSDictionary *)fake_serviceSubscriberCellularProviders;
- (NSString *)fake_serviceCurrentRadioAccessTechnology; // v2.01 新增
@end
@implementation CTTelephonyNetworkInfo (FakeNetwork)
- (NSDictionary *)fake_serviceSubscriberCellularProviders {
    if (g_isEnabled) {
        if ([g_fakeConfig[@"NoSIM"] boolValue]) return nil;  // 无卡模拟
        return @{@"00000001-0000-0000-0000-000000000001": [CTCarrier new]};
    }
    return [self fake_serviceSubscriberCellularProviders];
}
- (NSString *)fake_serviceCurrentRadioAccessTechnology {
    if (g_isEnabled) {
        if ([g_fakeConfig[@"NoSIM"] boolValue] || [g_fakeConfig[@"FlightMode"] boolValue]) return nil;
        return @"CTRadioAccessTechnologyLTE";
    }
    return [self fake_serviceCurrentRadioAccessTechnology];
}
@end
#endif

// ============================================================
// Hook 安装器 — 延迟到 UIApplicationDidFinishLaunching
// ============================================================
@interface UltimateEarlyLoader : NSObject
@end

@implementation UltimateEarlyLoader

+ (void)load {
    @autoreleasepool {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(setupHooksDelayed)
                                                     name:UIApplicationDidFinishLaunchingNotification
                                                   object:nil];
    }
}

+ (void)setupHooksDelayed {
    if (g_isHooked) return;
    g_isHooked = YES;

    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID || [bundleID hasPrefix:@"com.apple."]) return;
        if ([bundleID isEqualToString:@"com.custom.appwiper.ui"]) return;

        @try {
            NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
            if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) return;

            g_fakeConfig = [NSDictionary dictionaryWithContentsOfFile:configPath];
            if (!g_fakeConfig || ![g_fakeConfig[@"enabled"] boolValue]) return;

            g_isEnabled = YES;
            NSNumber *modeNum = g_fakeConfig[@"HookMode"];
            g_hookMode = modeNum ? [modeNum intValue] : 2;

            syslog(LOG_NOTICE, "[Hooks] setupHooksDelayed for %s (mode=%d)", [bundleID UTF8String], g_hookMode);

            if (g_hookMode == 0) {
                syslog(LOG_NOTICE, "[Hooks] DIAGNOSTIC MODE: all hooks disabled");
                return;
            }

            if (!initHookFramework()) {
                syslog(LOG_ERR, "[Hooks] MSHookFunction not resolved");
                return;
            }

            // ===== C 函数 Hook =====

#if HOOK_ENABLE_IOKIT
            if (g_hookMode >= 1) {
                @try { g_MSHookFunction((void*)IORegistryEntryCreateCFProperty, (void*)fake_IORegistryEntryCreateCFProperty, (void**)&orig_IORegistryEntryCreateCFProperty); }
                @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] IOKit error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_SYSCTL
            if (g_hookMode >= 1) {
                @try { g_MSHookFunction((void*)sysctlbyname, (void*)fake_sysctlbyname, (void**)&orig_sysctlbyname); }
                @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] sysctlbyname error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_SYSPROC
            if (g_hookMode == 2) {
                @try { g_MSHookFunction((void*)sysctl, (void*)fake_sysctl, (void**)&orig_sysctl); }
                @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] sysctl error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_UNAME
            if (g_hookMode >= 1) {
                @try { g_MSHookFunction((void*)uname, (void*)fake_uname, (void**)&orig_uname); }
                @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] uname error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_STAT
            if (g_hookMode == 2) {
                @try { g_MSHookFunction((void*)stat, (void*)fake_stat, (void**)&orig_stat); }
                @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] stat error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_ACCESS
            if (g_hookMode == 2) {
                @try { g_MSHookFunction((void*)access, (void*)fake_access, (void**)&orig_access); }
                @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] access error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_SCNET
            if (g_hookMode >= 1) {
                @try { g_MSHookFunction((void*)SCNetworkReachabilityGetFlags, (void*)fake_SCNetworkReachabilityGetFlags, (void**)&orig_SCNetworkReachabilityGetFlags); }
                @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] SCNet error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_WIFI
            if (g_hookMode == 2) {
                @try { g_MSHookFunction((void*)CNCopyCurrentNetworkInfo, (void*)fake_CNCopyCurrentNetworkInfo, (void**)&orig_CNCopyCurrentNetworkInfo); }
                @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] CNCopy error: %s", [e.reason UTF8String]); }
            }
#endif

            // ===== ObjC Swizzle =====

#if HOOK_ENABLE_UIDEVICE
            if (g_hookMode >= 1) {
                @try {
                    Class cls = [UIDevice class];
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(model)), class_getInstanceMethod(cls, @selector(fake_model)));
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(localizedModel)), class_getInstanceMethod(cls, @selector(fake_localizedModel)));
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(identifierForVendor)), class_getInstanceMethod(cls, @selector(fake_identifierForVendor)));
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] UIDevice error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_SCREEN
            if (g_hookMode >= 1) {
                @try {
                    Class cls = [UIScreen class];
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(bounds)), class_getInstanceMethod(cls, @selector(dynamic_bounds)));
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(scale)), class_getInstanceMethod(cls, @selector(dynamic_scale)));
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] UIScreen error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_DISK
            if (g_hookMode >= 1) {
                @try {
                    Class cls = [NSFileManager class];
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(attributesOfFileSystemForPath:error:)), class_getInstanceMethod(cls, @selector(dynamic_attributesOfFileSystemForPath:error:)));
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] NSFileManager error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_LOCALE
            if (g_hookMode == 2) {
                @try {
                    Class cls = [NSLocale class];
                    method_exchangeImplementations(class_getClassMethod(cls, @selector(currentLocale)), class_getClassMethod(cls, @selector(fake_currentLocale)));
                    method_exchangeImplementations(class_getClassMethod(cls, @selector(autoupdatingCurrentLocale)), class_getClassMethod(cls, @selector(fake_autoupdatingCurrentLocale)));
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] NSLocale error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_TIMEZONE
            if (g_hookMode == 2) {
                @try {
                    Class cls = [NSTimeZone class];
                    method_exchangeImplementations(class_getClassMethod(cls, @selector(localTimeZone)), class_getClassMethod(cls, @selector(fake_localTimeZone)));
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] NSTimeZone error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_UA
            if (g_hookMode == 2) {
                @try {
                    Class cls = [WKWebView class];
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(customUserAgent)), class_getInstanceMethod(cls, @selector(dynamic_customUserAgent)));
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] WKWebView error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_CARRIER
            if (g_hookMode == 2) {
                @try {
                    Class cls = [CTCarrier class];
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(carrierName)), class_getInstanceMethod(cls, @selector(fake_carrierName)));
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(mobileCountryCode)), class_getInstanceMethod(cls, @selector(fake_mobileCountryCode)));
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(mobileNetworkCode)), class_getInstanceMethod(cls, @selector(fake_mobileNetworkCode)));
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(isoCountryCode)), class_getInstanceMethod(cls, @selector(fake_isoCountryCode)));
                    // v2.01: radioAccessTechnology 可能是 CTTelephonyNetworkInfo 的方法, 这里也尝试交换
                    SEL radioSel = NSSelectorFromString(@"radioAccessTechnology");
                    if (class_getInstanceMethod(cls, radioSel)) {
                        method_exchangeImplementations(class_getInstanceMethod(cls, radioSel), class_getInstanceMethod(cls, @selector(fake_radioAccessTechnology)));
                    }
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] CTCarrier error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_NETINFO
            if (g_hookMode == 2) {
                @try {
                    Class cls = [CTTelephonyNetworkInfo class];
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(serviceSubscriberCellularProviders)), class_getInstanceMethod(cls, @selector(fake_serviceSubscriberCellularProviders)));
                    // v2.01: serviceCurrentRadioAccessTechnology
                    SEL radioTechSel = NSSelectorFromString(@"serviceCurrentRadioAccessTechnology");
                    if (class_getInstanceMethod(cls, radioTechSel)) {
                        method_exchangeImplementations(class_getInstanceMethod(cls, radioTechSel), class_getInstanceMethod(cls, @selector(fake_serviceCurrentRadioAccessTechnology)));
                    }
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] CTTelephony error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_SYSVER
            // v2.02: NSProcessInfo 系统版本全链路伪装
            if (g_hookMode >= 1) {
                @try {
                    Class cls = [NSProcessInfo class];
                    SEL osVerSel = @selector(operatingSystemVersion);
                    SEL osVerStrSel = @selector(operatingSystemVersionString);
                    if (class_getInstanceMethod(cls, osVerSel)) {
                        method_exchangeImplementations(class_getInstanceMethod(cls, osVerSel), class_getInstanceMethod(cls, @selector(fake_operatingSystemVersion)));
                    }
                    if (class_getInstanceMethod(cls, osVerStrSel)) {
                        method_exchangeImplementations(class_getInstanceMethod(cls, osVerStrSel), class_getInstanceMethod(cls, @selector(fake_operatingSystemVersionString)));
                    }
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] NSProcessInfo error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_LOCATION
            // v2.02: 定位伪造初始化
            if (g_hookMode == 2 && g_fakeConfig[@"LocationLat"] && g_fakeConfig[@"LocationLon"]) {
                @try {
                    double lat = [g_fakeConfig[@"LocationLat"] doubleValue];
                    double lon = [g_fakeConfig[@"LocationLon"] doubleValue];
                    double radius = [g_fakeConfig[@"LocationRadius"] doubleValue];
                    if (radius <= 0) radius = 10.0;
                    [LocationFaker setupLocationFakerWithLat:lat lon:lon radiusKm:radius];
                    syslog(LOG_NOTICE, "[Hooks] LocationFaker active: %.6f,%.6f r=%.1fkm", lat, lon, radius);
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] LocationFaker error: %s", [e.reason UTF8String]); }
            }
#endif

            // v2.03: 网络伪装 (必须在所有 Hook 安装之后)
            if (g_fakeConfig[@"NetworkMode"]) {
                @try {
                    [NetworkFaker applyNetworkConfig:g_fakeConfig];
                    syslog(LOG_NOTICE, "[Hooks] NetworkFaker active: mode=%s",
                           [g_fakeConfig[@"NetworkMode"] UTF8String]);
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] NetworkFaker error: %s", [e.reason UTF8String]); }
            }

            syslog(LOG_NOTICE, "[Hooks] all hooks processed for %s (FlightMode=%d, NoSIM=%d)",
                   [bundleID UTF8String],
                   [g_fakeConfig[@"FlightMode"] boolValue],
                   [g_fakeConfig[@"NoSIM"] boolValue]);

        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] setupHooksDelayed FATAL: %s", [e.reason UTF8String]);
        }
    }
}

@end

#endif // EMERGENCY_MODE
