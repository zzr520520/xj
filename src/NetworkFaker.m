// ============================================================
// NetworkFaker.m v2.03 — 网络伪装模块 (修正版)
// 修复: 双卡兼容 / 标志位精准 / dlsym 解析 MSHookFunction
// ============================================================

#import "NetworkFaker.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <syslog.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>

// ============================================================
// dlsym 运行时解析 MSHookFunction (不使用 ellekit 编译期链接)
// ============================================================
typedef void (*MSHookFunction_t)(void *symbol, void *replacement, void **original);
static MSHookFunction_t g_MSHookFunction = NULL;

static BOOL initNetHookFramework(void) {
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
// 静态状态
// ============================================================
static NSDictionary *g_netConfig = nil;
static BOOL g_isFaking = NO;

// ============================================================
// CTCarrier 动态代理
// ============================================================
@interface CTCarrier (SafeFakeCarrier)
- (NSString *)fake_carrierName;
- (NSString *)fake_mobileCountryCode;
- (NSString *)fake_mobileNetworkCode;
- (NSString *)fake_isoCountryCode;
@end

@implementation CTCarrier (SafeFakeCarrier)
- (NSString *)fake_carrierName {
    if (g_isFaking && g_netConfig) {
        NSString *mode = g_netConfig[@"NetworkMode"];
        if ([mode isEqualToString:@"nosim"] || [mode isEqualToString:@"flight"]) {
            return nil;
        }
        return g_netConfig[@"CarrierName"] ?: @"中国移动";
    }
    return [self fake_carrierName];
}
- (NSString *)fake_mobileCountryCode {
    if (g_isFaking && g_netConfig) {
        NSString *mode = g_netConfig[@"NetworkMode"];
        if ([mode isEqualToString:@"nosim"] || [mode isEqualToString:@"flight"]) {
            return nil;
        }
        return g_netConfig[@"CarrierMCC"] ?: @"460";
    }
    return [self fake_mobileCountryCode];
}
- (NSString *)fake_mobileNetworkCode {
    if (g_isFaking && g_netConfig) {
        NSString *mode = g_netConfig[@"NetworkMode"];
        if ([mode isEqualToString:@"nosim"] || [mode isEqualToString:@"flight"]) {
            return nil;
        }
        return g_netConfig[@"CarrierMNC"] ?: @"00";
    }
    return [self fake_mobileNetworkCode];
}
- (NSString *)fake_isoCountryCode {
    if (g_isFaking && g_netConfig) {
        NSString *mode = g_netConfig[@"NetworkMode"];
        if ([mode isEqualToString:@"nosim"] || [mode isEqualToString:@"flight"]) {
            return nil;
        }
        return @"cn";
    }
    return [self fake_isoCountryCode];
}
@end

// ============================================================
// CTTelephonyNetworkInfo 单/多卡兼容
// ============================================================
@interface CTTelephonyNetworkInfo (SafeFakeNetwork)
- (NSDictionary *)fake_serviceSubscriberCellularProviders;
- (NSDictionary *)fake_serviceCurrentRadioAccessTechnology;
- (NSString *)fake_currentRadioAccessTechnology;
@end

@implementation CTTelephonyNetworkInfo (SafeFakeNetwork)
- (NSDictionary *)fake_serviceSubscriberCellularProviders {
    if (g_isFaking && g_netConfig) {
        NSString *mode = g_netConfig[@"NetworkMode"];
        if ([mode isEqualToString:@"nosim"] || [mode isEqualToString:@"flight"]) {
            return @{};
        }
        return @{@"00000001-0000-0000-0000-000000000001": [CTCarrier new]};
    }
    return [self fake_serviceSubscriberCellularProviders];
}
- (NSDictionary *)fake_serviceCurrentRadioAccessTechnology {
    if (g_isFaking && g_netConfig) {
        NSString *mode = g_netConfig[@"NetworkMode"];
        if ([mode isEqualToString:@"nosim"] || [mode isEqualToString:@"flight"]) {
            return @{};
        }
        NSString *tech = g_netConfig[@"RadioAccessTechnology"] ?: @"CTRadioAccessTechnologyLTE";
        return @{@"00000001-0000-0000-0000-000000000001": tech};
    }
    return [self fake_serviceCurrentRadioAccessTechnology];
}
- (NSString *)fake_currentRadioAccessTechnology {
    if (g_isFaking && g_netConfig) {
        NSString *mode = g_netConfig[@"NetworkMode"];
        if ([mode isEqualToString:@"nosim"] || [mode isEqualToString:@"flight"]) {
            return nil;
        }
        return g_netConfig[@"RadioAccessTechnology"] ?: @"CTRadioAccessTechnologyLTE";
    }
    return [self fake_currentRadioAccessTechnology];
}
@end

// ============================================================
// SCNetworkReachability 精准标志模拟
// ============================================================
static Boolean (*orig_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *) = NULL;
static Boolean fake_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    Boolean ret = orig_SCNetworkReachabilityGetFlags ? orig_SCNetworkReachabilityGetFlags(target, flags) : NO;
    if (g_isFaking && g_netConfig && ret == YES && flags) {
        NSString *mode = g_netConfig[@"NetworkMode"];
        if ([mode isEqualToString:@"flight"]) {
            *flags = 0;
            return YES;
        } else if ([mode isEqualToString:@"wifi"] || [mode isEqualToString:@"nosim"]) {
            *flags = kSCNetworkReachabilityFlagsReachable | kSCNetworkReachabilityFlagsIsDirect;
            *flags &= ~kSCNetworkReachabilityFlagsIsWWAN;
            *flags &= ~kSCNetworkReachabilityFlagsConnectionRequired;
            return YES;
        } else if ([mode isEqualToString:@"cellular"]) {
            *flags = kSCNetworkReachabilityFlagsReachable | kSCNetworkReachabilityFlagsIsWWAN;
            *flags &= ~kSCNetworkReachabilityFlagsIsDirect;
            *flags &= ~kSCNetworkReachabilityFlagsConnectionRequired;
            return YES;
        }
    }
    return ret;
}

// ============================================================
// Wi-Fi 信息拦截
// ============================================================
static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef interfaceName) = NULL;
static CFDictionaryRef fake_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    if (g_isFaking && g_netConfig) {
        NSString *mode = g_netConfig[@"NetworkMode"];
        if ([mode isEqualToString:@"flight"] || [mode isEqualToString:@"cellular"]) {
            return NULL;
        }
        NSDictionary *info = @{
            (__bridge NSString *)kCNNetworkInfoKeySSID: g_netConfig[@"WifiSSID"] ?: @"WiFi-0000",
            (__bridge NSString *)kCNNetworkInfoKeyBSSID: g_netConfig[@"WifiBSSID"] ?: @"00:00:00:00:00:00"
        };
        return (__bridge_retained CFDictionaryRef)info;
    }
    return orig_CNCopyCurrentNetworkInfo ? orig_CNCopyCurrentNetworkInfo(interfaceName) : NULL;
}

// ============================================================
// NetworkFaker 实现
// ============================================================
@implementation NetworkFaker

+ (void)applyNetworkConfig:(NSDictionary *)config {
    if (!config) return;
    g_netConfig = config;
    g_isFaking = YES;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // CTCarrier Swizzle
        Class carrierCls = [CTCarrier class];
        method_exchangeImplementations(class_getInstanceMethod(carrierCls, @selector(carrierName)),
                                       class_getInstanceMethod(carrierCls, @selector(fake_carrierName)));
        method_exchangeImplementations(class_getInstanceMethod(carrierCls, @selector(mobileCountryCode)),
                                       class_getInstanceMethod(carrierCls, @selector(fake_mobileCountryCode)));
        method_exchangeImplementations(class_getInstanceMethod(carrierCls, @selector(mobileNetworkCode)),
                                       class_getInstanceMethod(carrierCls, @selector(fake_mobileNetworkCode)));
        method_exchangeImplementations(class_getInstanceMethod(carrierCls, @selector(isoCountryCode)),
                                       class_getInstanceMethod(carrierCls, @selector(fake_isoCountryCode)));

        // CTTelephonyNetworkInfo Swizzle (单卡+多卡兼容)
        Class netInfoCls = [CTTelephonyNetworkInfo class];
        method_exchangeImplementations(class_getInstanceMethod(netInfoCls, @selector(serviceSubscriberCellularProviders)),
                                       class_getInstanceMethod(netInfoCls, @selector(fake_serviceSubscriberCellularProviders)));
        method_exchangeImplementations(class_getInstanceMethod(netInfoCls, @selector(serviceCurrentRadioAccessTechnology)),
                                       class_getInstanceMethod(netInfoCls, @selector(fake_serviceCurrentRadioAccessTechnology)));
        method_exchangeImplementations(class_getInstanceMethod(netInfoCls, @selector(currentRadioAccessTechnology)),
                                       class_getInstanceMethod(netInfoCls, @selector(fake_currentRadioAccessTechnology)));

        // C 函数 Hook (使用 dlsym 解析的 MSHookFunction)
        if (initNetHookFramework()) {
            if (!orig_SCNetworkReachabilityGetFlags) {
                g_MSHookFunction((void *)SCNetworkReachabilityGetFlags,
                                 (void *)fake_SCNetworkReachabilityGetFlags,
                                 (void **)&orig_SCNetworkReachabilityGetFlags);
            }
            if (!orig_CNCopyCurrentNetworkInfo) {
                g_MSHookFunction((void *)CNCopyCurrentNetworkInfo,
                                 (void *)fake_CNCopyCurrentNetworkInfo,
                                 (void **)&orig_CNCopyCurrentNetworkInfo);
            }
            syslog(LOG_NOTICE, "[NetworkFaker] C function hooks installed");
        } else {
            syslog(LOG_ERR, "[NetworkFaker] MSHookFunction not resolved, C hooks skipped");
        }
    });

    syslog(LOG_NOTICE, "[NetworkFaker] active: mode=%s carrier=%s",
           [g_netConfig[@"NetworkMode"] UTF8String],
           [g_netConfig[@"CarrierName"] UTF8String]);
}

+ (void)resetToDefault {
    g_isFaking = NO;
    g_netConfig = nil;
    syslog(LOG_NOTICE, "[NetworkFaker] reset to default");
}

+ (BOOL)isFaking {
    return g_isFaking;
}

@end
