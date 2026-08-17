#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <CoreTelephony/CTCarrier.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <dlfcn.h>
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
    // Try ellekit first, then CydiaSubstrate
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

#pragma mark - IOKit interception

static CFTypeRef (*orig_IORegistryEntryCreateCFProperty)(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) = NULL;
static CFTypeRef fake_IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) {
    if (g_isEnabled && key) {
        NSString *keyStr = (__bridge NSString *)key;
        if ([keyStr isEqualToString:@"IOPlatformSerialNumber"] || [keyStr isEqualToString:@"serial-number"]) {
            if (g_fakeConfig[@"SerialNumber"]) {
                return (__bridge_retained CFTypeRef)g_fakeConfig[@"SerialNumber"];
            }
        }
        if ([keyStr isEqualToString:@"IOPlatformUUID"]) {
            if (g_fakeConfig[@"UniqueDeviceID"]) {
                return (__bridge_retained CFTypeRef)g_fakeConfig[@"UniqueDeviceID"];
            }
        }
    }
    return orig_IORegistryEntryCreateCFProperty ? orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options) : NULL;
}

#pragma mark - sysctl interception

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
    }
    return orig_sysctlbyname ? orig_sysctlbyname(name, oldp, oldlenp, newp, newlen) : -1;
}

#pragma mark - Jailbreak detection bypass (DYLD_INTERPOSE for C functions)

#define DYLD_INTERPOSE(_replacement, _replacee) \
__attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
__attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

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

#pragma mark - Carrier spoofing

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

#pragma mark - Anti-debug / Anti-frida

static void PerformSecurityChecks(void) {
    // PT_DENY_ATTACH
    typedef int (*ptrace_ptr_t)(int _request, pid_t _pid, caddr_t _addr, int _data);
    ptrace_ptr_t ptrace_p = (ptrace_ptr_t)dlsym(RTLD_DEFAULT, "ptrace");
    if (ptrace_p) {
        ptrace_p(31, 0, 0, 0);
    }
    // Anti-frida
    if (dlsym(RTLD_DEFAULT, "frida_agent_main") != NULL) {
        exit(0);
    }
}

#pragma mark - Boot entry

@interface CommercialInitializer : NSObject
@end

@implementation CommercialInitializer

+ (void)load {
    @autoreleasepool {
        PerformSecurityChecks();

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID || [bundleID hasPrefix:@"com.apple."]) return;
        if ([bundleID isEqualToString:@"com.custom.appwiper.ui"]) return;

        NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
        if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) return;

        g_fakeConfig = [NSDictionary dictionaryWithContentsOfFile:configPath];
        if (g_fakeConfig && [g_fakeConfig[@"enabled"] boolValue]) {
            g_isEnabled = YES;

            // Resolve hooking framework at runtime (ellekit / CydiaSubstrate)
            if (!initHookFramework()) {
                syslog(LOG_ERR, "[Hooks] Failed to resolve MSHookFunction — hooks inactive");
                return;
            }

            // Hook IOKit for hardware serial number queries
            g_MSHookFunction((void *)IORegistryEntryCreateCFProperty,
                          (void *)fake_IORegistryEntryCreateCFProperty,
                          (void **)&orig_IORegistryEntryCreateCFProperty);

            // Hook sysctl for hw.machine / hw.model
            g_MSHookFunction((void *)sysctlbyname,
                          (void *)fake_sysctlbyname,
                          (void **)&orig_sysctlbyname);

            // Carrier method swizzling (corrected: independent exchanges)
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

            // Clear pasteboard cross-process persistence
            [[UIPasteboard generalPasteboard] setItems:@[]];
        }
    }
}

@end
