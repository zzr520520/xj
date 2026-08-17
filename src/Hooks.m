#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AdSupport/AdSupport.h>
#import <CoreTelephony/CTCarrier.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
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

#pragma mark - 1. IOKit kernel-level hooks (ECID, serial, UDID, battery)

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
    }
    return orig_IORegistryEntryCreateCFProperty ? orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options) : NULL;
}

#pragma mark - 2. sysctlbyname kernel parameter interception

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

#pragma mark - 3. sysctl process list filtering (hide jailbreak processes)

static int (*orig_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) = NULL;
static int fake_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl ? orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen) : -1;
    if (g_isEnabled && ret == 0 && oldp && oldlenp && namelen >= 3 &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && name[2] == KERN_PROC_ALL) {
        @try {
            size_t procSize = sizeof(struct kinfo_proc);
            if (procSize == 0) return ret;
            int count = (int)(*oldlenp / procSize);
            if (count <= 0 || count > 5000) return ret; // sanity check
            struct kinfo_proc *procList = (struct kinfo_proc *)oldp;
            int filteredCount = 0;
            for (int i = 0; i < count; i++) {
                char *procName = procList[i].kp_proc.p_comm;
                if (strstr(procName, "cydia") || strstr(procName, "sileo") ||
                    strstr(procName, "frida") || strstr(procName, "substrate") ||
                    strstr(procName, "ellekit") || strstr(procName, "sshd")) {
                    continue;
                }
                if (filteredCount != i) {
                    memcpy(&procList[filteredCount], &procList[i], procSize);
                }
                filteredCount++;
            }
            *oldlenp = filteredCount * procSize;
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] sysctl proc filter error: %s", [e.reason UTF8String]);
        }
    }
    return ret;
}

#pragma mark - 4. Jailbreak file access blocking (stat / access / getenv)

static int (*orig_stat)(const char *path, struct stat *buf) = NULL;
static int fake_stat(const char *path, struct stat *buf) {
    if (g_isEnabled && path != NULL) {
        if (strstr(path, "/var/jb") || strstr(path, "Cydia") || strstr(path, "Sileo") ||
            strstr(path, "MobileSubstrate") || strstr(path, "ellekit") ||
            strstr(path, "frida") || strstr(path, "/bin/bash") ||
            strstr(path, "apt") || strstr(path, "dpkg")) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_stat ? orig_stat(path, buf) : -1;
}

static int (*orig_access)(const char *path, int mode) = NULL;
static int fake_access(const char *path, int mode) {
    if (g_isEnabled && path != NULL) {
        if (strstr(path, "/var/jb") || strstr(path, "Cydia") || strstr(path, "Sileo") ||
            strstr(path, "MobileSubstrate") || strstr(path, "ellekit") ||
            strstr(path, "frida")) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_access ? orig_access(path, mode) : -1;
}

static char *(*orig_getenv)(const char *) = NULL;
static char *fake_getenv(const char *name) {
    if (g_isEnabled && name != NULL) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
            strcmp(name, "_MSSafeMode") == 0 ||
            strcmp(name, "MobileSubstrate") == 0) {
            return NULL;
        }
    }
    return orig_getenv ? orig_getenv(name) : getenv(name);
}

#pragma mark - 5. Disk capacity simulation (NSFileManager)

@interface NSFileManager (FakeDisk)
- (NSDictionary *)fake_attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error;
@end
@implementation NSFileManager (FakeDisk)
- (NSDictionary *)fake_attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error {
    NSDictionary *original = [self fake_attributesOfFileSystemForPath:path error:error];
    if (g_isEnabled && original) {
        NSMutableDictionary *attrs = [original mutableCopy];
        attrs[NSFileSystemSize] = @(256000000000ULL);      // 256GB
        attrs[NSFileSystemFreeSize] = @(200000000000ULL);   // 200GB free
        return attrs;
    }
    return original;
}
@end

#pragma mark - 6. Screen resolution & PPI spoofing

@interface UIScreen (FakeScreen)
- (CGRect)fake_bounds;
- (CGFloat)fake_scale;
@end
@implementation UIScreen (FakeScreen)
- (CGRect)fake_bounds {
    if (g_isEnabled) return CGRectMake(0, 0, 393, 852); // iPhone 14 Pro
    return [self fake_bounds];
}
- (CGFloat)fake_scale {
    if (g_isEnabled) return 3.0;
    return [self fake_scale];
}
@end

#pragma mark - 7. WebView / NSURLRequest User-Agent proxy

@interface WKWebView (FakeUA)
- (NSString *)fake_customUserAgent;
@end
@implementation WKWebView (FakeUA)
- (NSString *)fake_customUserAgent {
    if (g_isEnabled) {
        return @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
    }
    return [self fake_customUserAgent];
}
@end

@interface NSMutableURLRequest (FakeUA)
- (void)fake_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field;
@end
@implementation NSMutableURLRequest (FakeUA)
- (void)fake_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (g_isEnabled && field && [field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        value = @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
    }
    [self fake_setValue:value forHTTPHeaderField:field];
}
@end

#pragma mark - 8. Wi-Fi & carrier spoofing

static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef interfaceName) = NULL;
static CFDictionaryRef fake_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    if (g_isEnabled) return NULL; // Force "no Wi-Fi" for risk control
    return orig_CNCopyCurrentNetworkInfo ? orig_CNCopyCurrentNetworkInfo(interfaceName) : NULL;
}

@interface CTCarrier (FakeCarrier)
- (NSString *)fake_carrierName;
- (NSString *)fake_mobileCountryCode;
- (NSString *)fake_mobileNetworkCode;
- (NSString *)fake_isoCountryCode;
@end
@implementation CTCarrier (FakeCarrier)
- (NSString *)fake_carrierName { return @"中国移动"; }
- (NSString *)fake_mobileCountryCode { return @"460"; }
- (NSString *)fake_mobileNetworkCode { return @"00"; }
- (NSString *)fake_isoCountryCode { return @"cn"; }
@end

#pragma mark - 9. Anti-debug / Anti-frida (safe in +load, only uses syscalls)

static void PerformSecurityChecks(void) {
    @try {
        typedef int (*ptrace_ptr_t)(int _request, pid_t _pid, caddr_t _addr, int _data);
        ptrace_ptr_t ptrace_p = (ptrace_ptr_t)dlsym(RTLD_DEFAULT, "ptrace");
        if (ptrace_p) {
            ptrace_p(31, 0, 0, 0); // PT_DENY_ATTACH
        }
        if (dlsym(RTLD_DEFAULT, "frida_agent_main") != NULL) {
            exit(0);
        }
    } @catch (NSException *e) {
        // Silently fail — never crash the host app from security checks
    }
}

#pragma mark - 10. Safe deferred boot entry

@interface SafeHookLoader : NSObject
@end

@implementation SafeHookLoader

// +load: only register notification, NEVER touch UIKit/WebKit classes here
+ (void)load {
    @autoreleasepool {
        // Anti-debug is safe in +load (only uses dlsym + ptrace syscall)
        PerformSecurityChecks();

        // Defer all hook installation to UIApplicationDidFinishLaunchingNotification
        // At that point, all system frameworks (UIKit, WebKit, etc.) are fully loaded
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(performSafeHooks)
                                                     name:UIApplicationDidFinishLaunchingNotification
                                                   object:nil];
    }
}

// performSafeHooks: called when app has finished launching — safe to swizzle any class
+ (void)performSafeHooks {
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
        syslog(LOG_NOTICE, "[Hooks] performSafeHooks starting for %s", [bundleID UTF8String]);

        // Resolve hooking framework at runtime
        if (!initHookFramework()) {
            syslog(LOG_ERR, "[Hooks] Failed to resolve MSHookFunction — hooks inactive");
            return;
        }

        // --- C function hooks (each in its own @try/@catch) ---

        @try {
            g_MSHookFunction((void *)IORegistryEntryCreateCFProperty,
                          (void *)fake_IORegistryEntryCreateCFProperty,
                          (void **)&orig_IORegistryEntryCreateCFProperty);
            syslog(LOG_NOTICE, "[Hooks] IOKit hooks installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] IOKit hook error: %s", [e.reason UTF8String]);
        }

        @try {
            g_MSHookFunction((void *)sysctlbyname,
                          (void *)fake_sysctlbyname,
                          (void **)&orig_sysctlbyname);
            syslog(LOG_NOTICE, "[Hooks] sysctlbyname hooks installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] sysctlbyname hook error: %s", [e.reason UTF8String]);
        }

        @try {
            g_MSHookFunction((void *)sysctl,
                          (void *)fake_sysctl,
                          (void **)&orig_sysctl);
            syslog(LOG_NOTICE, "[Hooks] sysctl proc filter installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] sysctl hook error: %s", [e.reason UTF8String]);
        }

        @try {
            g_MSHookFunction((void *)stat,
                          (void *)fake_stat,
                          (void **)&orig_stat);
            g_MSHookFunction((void *)access,
                          (void *)fake_access,
                          (void **)&orig_access);
            g_MSHookFunction((void *)getenv,
                          (void *)fake_getenv,
                          (void **)&orig_getenv);
            syslog(LOG_NOTICE, "[Hooks] stat/access/getenv hooks installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] file access hook error: %s", [e.reason UTF8String]);
        }

        @try {
            g_MSHookFunction((void *)CNCopyCurrentNetworkInfo,
                          (void *)fake_CNCopyCurrentNetworkInfo,
                          (void **)&orig_CNCopyCurrentNetworkInfo);
            syslog(LOG_NOTICE, "[Hooks] CNCopyCurrentNetworkInfo hook installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] Wi-Fi hook error: %s", [e.reason UTF8String]);
        }

        // --- Objective-C method swizzling (each in its own @try/@catch) ---

        @try {
            Class screenCls = [UIScreen class];
            method_exchangeImplementations(
                class_getInstanceMethod(screenCls, @selector(bounds)),
                class_getInstanceMethod(screenCls, @selector(fake_bounds)));
            method_exchangeImplementations(
                class_getInstanceMethod(screenCls, @selector(scale)),
                class_getInstanceMethod(screenCls, @selector(fake_scale)));
            syslog(LOG_NOTICE, "[Hooks] UIScreen swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] UIScreen swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class fmCls = [NSFileManager class];
            method_exchangeImplementations(
                class_getInstanceMethod(fmCls, @selector(attributesOfFileSystemForPath:error:)),
                class_getInstanceMethod(fmCls, @selector(fake_attributesOfFileSystemForPath:error:)));
            syslog(LOG_NOTICE, "[Hooks] NSFileManager swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] NSFileManager swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class wkCls = [WKWebView class];
            method_exchangeImplementations(
                class_getInstanceMethod(wkCls, @selector(customUserAgent)),
                class_getInstanceMethod(wkCls, @selector(fake_customUserAgent)));
            syslog(LOG_NOTICE, "[Hooks] WKWebView swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] WKWebView swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class reqCls = [NSMutableURLRequest class];
            method_exchangeImplementations(
                class_getInstanceMethod(reqCls, @selector(setValue:forHTTPHeaderField:)),
                class_getInstanceMethod(reqCls, @selector(fake_setValue:forHTTPHeaderField:)));
            syslog(LOG_NOTICE, "[Hooks] NSMutableURLRequest swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] NSURLRequest swizzle error: %s", [e.reason UTF8String]);
        }

        @try {
            Class carrierCls = [CTCarrier class];
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(carrierName)),
                class_getInstanceMethod(carrierCls, @selector(fake_carrierName)));
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(mobileCountryCode)),
                class_getInstanceMethod(carrierCls, @selector(fake_mobileCountryCode)));
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(mobileNetworkCode)),
                class_getInstanceMethod(carrierCls, @selector(fake_mobileNetworkCode)));
            method_exchangeImplementations(
                class_getInstanceMethod(carrierCls, @selector(isoCountryCode)),
                class_getInstanceMethod(carrierCls, @selector(fake_isoCountryCode)));
            syslog(LOG_NOTICE, "[Hooks] CTCarrier swizzle installed");
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] CTCarrier swizzle error: %s", [e.reason UTF8String]);
        }

        // Clear cross-process pasteboard
        @try {
            [[UIPasteboard generalPasteboard] setItems:@[]];
        } @catch (NSException *e) {
            syslog(LOG_ERR, "[Hooks] Pasteboard clear error: %s", [e.reason UTF8String]);
        }

        syslog(LOG_NOTICE, "[Hooks] All hooks processed for %s", [bundleID UTF8String]);
    }
}

@end
