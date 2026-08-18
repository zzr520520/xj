// ============================================================
// AppWiper Hooks.m — 紧急空壳模式 (Emergency Safe Loader)
//
// 当前版本: 空壳隔离法
// 目的: 验证是否为 Hook 导致应用启动卡死
//
// 排查流程:
//   1. 安装此空壳版本 → 重启手机 → 测试普通 App
//   2. 如果 App 正常启动 → 问题在 Hook 代码, 使用二分法逐个恢复
//   3. 如果 App 仍卡死 → 问题在越狱环境, 重新越狱
//
// 恢复 Hook 的步骤:
//   将下面的 EMERGENCY_MODE 改为 0, 即恢复完整 Hook
//   或使用二分法: 每次只放开一个 HOOK_ENABLE_x
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ============================================================
// 开关控制
// ============================================================
#define EMERGENCY_MODE      1   // 1=空壳(不做任何Hook) 0=恢复Hook
#define HOOK_ENABLE_IOKIT   0   // IOKit 硬件伪装
#define HOOK_ENABLE_SYSCTL  0   // sysctlbyname 机型伪装
#define HOOK_ENABLE_SCREEN  0   // UIScreen 分辨率
#define HOOK_ENABLE_DISK    0   // NSFileManager 磁盘
#define HOOK_ENABLE_LOCALE  0   // NSLocale
#define HOOK_ENABLE_TIMEZONE 0  // NSTimeZone
#define HOOK_ENABLE_UA      0   // WKWebView UA
#define HOOK_ENABLE_CARRIER 0   // CTCarrier
#define HOOK_ENABLE_NETINFO 0   // CTTelephonyNetworkInfo
#define HOOK_ENABLE_STAT    0   // stat 文件封锁
#define HOOK_ENABLE_ACCESS  0   // access 文件封锁
#define HOOK_ENABLE_SYSPROC 0   // sysctl 进程隐藏
#define HOOK_ENABLE_SCNET  0   // SCNetworkReachability

// ============================================================
// 仅在非空壳模式下才导入额外头文件
// ============================================================
#if !EMERGENCY_MODE
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
#endif

// ============================================================
// 空壳模式: 最小化安全加载器
// ============================================================
#if EMERGENCY_MODE

// 空壳模式不依赖任何项目内部头文件
// 仅做 BundleID 过滤 + 日志, 不执行任何 Hook

@interface SafeEmergencyLoader : NSObject
@end

@implementation SafeEmergencyLoader

+ (void)load {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        // 严格过滤: 系统进程 + 自身管理 App
        if (!bundleID) return;
        if ([bundleID hasPrefix:@"com.apple."]) return;
        if ([bundleID isEqualToString:@"com.custom.appwiper.ui"]) return;

        // 空壳模式: 不做任何 Hook, 仅日志
        NSLog(@"[AppWiper] Emergency Safe Loader: %@ — no hooks installed.", bundleID);
    }
}

@end

// ============================================================
// 完整模式: 以下为全部 Hook 代码 (EMERGENCY_MODE=0 时编译)
// ============================================================
#else

// ============================================================
// dlsym 运行时解析 MSHookFunction
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
// 1. IOKit
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
            unsigned long long ecid = 0;
            if (g_fakeConfig[@"ECID"]) ecid = [g_fakeConfig[@"ECID"] unsignedLongLongValue];
            if (ecid == 0) ecid = 3849201847291ULL;
            return (__bridge_retained CFTypeRef)@(ecid);
        }
    }
    return orig_IORegistryEntryCreateCFProperty ? orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options) : NULL;
}
#endif

// ============================================================
// 2. sysctlbyname
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
    }
    return orig_sysctlbyname ? orig_sysctlbyname(name, oldp, oldlenp, newp, newlen) : -1;
}
#endif

// ============================================================
// 3. sysctl KERN_PROC (高危: 可能导致卡死)
// ============================================================
#if HOOK_ENABLE_SYSPROC
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;
static int fake_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (g_reentrancyDepth > 0) return orig_sysctl ? orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen) : -1;
    g_reentrancyDepth++;
    int ret = orig_sysctl ? orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen) : -1;
    if (g_isEnabled && ret == 0 && oldp && name && name[0] == CTL_KERN && name[1] == KERN_PROC) {
        struct kinfo_proc *procList = (struct kinfo_proc *)oldp;
        int count = (int)(*oldlenp / sizeof(struct kinfo_proc));
        int filteredCount = 0;
        for (int i = 0; i < count; i++) {
            char *procName = procList[i].kp_proc.p_comm;
            if (strstr(procName, "cydia") || strstr(procName, "sileo") || strstr(procName, "frida") ||
                strstr(procName, "substrate") || strstr(procName, "ellekit") || strstr(procName, "ssh") ||
                strstr(procName, "dropbear") || strstr(procName, "sshd")) continue;
            if (filteredCount != i) memcpy(&procList[filteredCount], &procList[i], sizeof(struct kinfo_proc));
            filteredCount++;
        }
        *oldlenp = filteredCount * sizeof(struct kinfo_proc);
    }
    g_reentrancyDepth--;
    return ret;
}
#endif

// ============================================================
// 4. stat (高危: 可能导致卡死)
// ============================================================
#if HOOK_ENABLE_STAT
static int (*orig_stat)(const char *, struct stat *) = NULL;
static int fake_stat(const char *path, struct stat *buf) {
    if (g_reentrancyDepth > 0) return orig_stat ? orig_stat(path, buf) : -1;
    g_reentrancyDepth++;
    int result;
    if (g_isEnabled && path != NULL) {
        if (strcmp(path, "/var/jb") == 0 || strcmp(path, "/Applications/Cydia.app") == 0 ||
            strcmp(path, "/bin/bash") == 0 || strcmp(path, "/usr/sbin/sshd") == 0) {
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
// 5. access (高危)
// ============================================================
#if HOOK_ENABLE_ACCESS
static int (*orig_access)(const char *, int) = NULL;
static int fake_access(const char *path, int mode) {
    if (g_reentrancyDepth > 0) return orig_access ? orig_access(path, mode) : -1;
    g_reentrancyDepth++;
    int result;
    if (g_isEnabled && path != NULL) {
        if (strcmp(path, "/var/jb") == 0 || strcmp(path, "/Applications/Cydia.app") == 0 ||
            strcmp(path, "/bin/bash") == 0 || strcmp(path, "/usr/sbin/sshd") == 0) {
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
// 6. SCNetworkReachability
// ============================================================
#if HOOK_ENABLE_SCNET
static Boolean (*orig_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *) = NULL;
static Boolean fake_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    Boolean ret = orig_SCNetworkReachabilityGetFlags ? orig_SCNetworkReachabilityGetFlags(target, flags) : NO;
    if (g_isEnabled && ret == YES && flags) {
        *flags &= ~kSCNetworkReachabilityFlagsConnectionRequired;
        *flags |= kSCNetworkReachabilityFlagsReachable;
        *flags |= kSCNetworkReachabilityFlagsIsDirect;
    }
    return ret;
}
#endif

// ============================================================
// 7. UIScreen
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
// 8. NSFileManager
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
// 9. NSLocale (dispatch_once 防递归)
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
// 10. NSTimeZone (dispatch_once 防递归)
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
// 11-13. WKWebView / CTCarrier / CTTelephonyNetworkInfo
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

#if HOOK_ENABLE_CARRIER
@interface CTCarrier (DynamicCarrier)
- (NSString *)dynamic_carrierName;
- (NSString *)dynamic_mobileCountryCode;
@end
@implementation CTCarrier (DynamicCarrier)
- (NSString *)dynamic_carrierName { return @"中国移动"; }
- (NSString *)dynamic_mobileCountryCode { return @"460"; }
@end
#endif

#if HOOK_ENABLE_NETINFO
@interface CTTelephonyNetworkInfo (DynamicNetwork)
- (NSDictionary *)dynamic_serviceSubscriberCellularProviders;
@end
@implementation CTTelephonyNetworkInfo (DynamicNetwork)
- (NSDictionary *)dynamic_serviceSubscriberCellularProviders {
    if (g_isEnabled) return @{@"00000001-0000-0000-0000-000000000001": [CTCarrier new]};
    return [self dynamic_serviceSubscriberCellularProviders];
}
@end
#endif

// ============================================================
// Hook 安装器 — 延迟到 UIApplicationDidFinishLaunching
// 不在 +load 中读取文件, 避免文件锁死锁
// ============================================================
@interface UltimateEarlyLoader : NSObject
@end

@implementation UltimateEarlyLoader

+ (void)load {
    @autoreleasepool {
        // 仅注册通知, 不做任何文件操作
        // 所有配置读取和 Hook 安装延迟到 App 启动后
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

        // 延迟读取配置文件, 此时沙盒已完全挂载
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

            // 安装 C 函数 Hook (每个都判空)
            if (!initHookFramework()) {
                syslog(LOG_ERR, "[Hooks] MSHookFunction not resolved");
                return;
            }

            // 逐个安装, 每个 @try/@catch
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
            if (g_hookMode == 2) {
                @try { g_MSHookFunction((void*)SCNetworkReachabilityGetFlags, (void*)fake_SCNetworkReachabilityGetFlags, (void**)&orig_SCNetworkReachabilityGetFlags); }
                @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] SCNet error: %s", [e.reason UTF8String]); }
            }
#endif

            // ObjC swizzle
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
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(carrierName)), class_getInstanceMethod(cls, @selector(dynamic_carrierName)));
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(mobileCountryCode)), class_getInstanceMethod(cls, @selector(dynamic_mobileCountryCode)));
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] CTCarrier error: %s", [e.reason UTF8String]); }
            }
#endif

#if HOOK_ENABLE_NETINFO
            if (g_hookMode == 2) {
                @try {
                    Class cls = [CTTelephonyNetworkInfo class];
                    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(serviceSubscriberCellularProviders)), class_getInstanceMethod(cls, @selector(dynamic_serviceSubscriberCellularProviders)));
                } @catch(NSException *e) { syslog(LOG_ERR, "[Hooks] CTTelephony error: %s", [e.reason UTF8String]); }
            }
#endif

            syslog(LOG_NOTICE, "[Hooks] all hooks processed for %s", [bundleID UTF8String]);

        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] setupHooksDelayed FATAL: %s", [e.reason UTF8String]);
        }
    }
}

@end

#endif // EMERGENCY_MODE
