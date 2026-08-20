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
// v2.06: CTCarrier ICCID 私有方法安全检查
// ============================================================
@interface CTCarrier (SafePrivateICCID)
- (NSString *)fake_iccId;
- (NSString *)fake_simICCID;
@end
@implementation CTCarrier (SafePrivateICCID)
- (NSString *)fake_iccId {
    if (g_isFaking && g_netConfig[@"ICCID"]) return g_netConfig[@"ICCID"];
    return [self fake_iccId];
}
- (NSString *)fake_simICCID {
    if (g_isFaking && g_netConfig[@"ICCID"]) return g_netConfig[@"ICCID"];
    return [self fake_simICCID];
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
// v2.10.1: 精准风控拦截器 (不拦截登录/验证码/支付)
// 仅拦截设备指纹上报/风控采集类请求, 放行所有业务请求
// ============================================================
@interface WipeCustomURLProtocol : NSURLProtocol
@end

@implementation WipeCustomURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request || !request.URL) return NO;
    NSString *url = [request.URL.absoluteString lowercaseString];

    // 放行白名单: 登录/验证码/支付/认证等关键业务请求
    NSArray *whitelist = @[@"login", @"auth", @"code", @"pay",
                            @"captcha", @"sms", @"token", @"session"];
    for (NSString *wl in whitelist) {
        if ([url containsString:wl]) return NO;
    }

    // 仅拦截明确的风控上报/设备指纹采集类请求
    NSArray *blockKeywords = @[@"risk", @"fingerprint", @"devicecheck",
                                @"device_check", @"blackbox", @"turing",
                                @"shield", @"fraud",
                                @"report", @"tracking", @"analytics",
                                @"collect", @"monitor", @"sensor"];
    for (NSString *kw in blockKeywords) {
        if ([url containsString:kw]) return YES;
    }

    // verify/device/collect 需排除登录场景
    if ([url containsString:@"verify"] && ![url containsString:@"login"]) return YES;
    if ([url containsString:@"device"] && ![url containsString:@"login"]) return YES;
    if ([url containsString:@"collect"] && ![url containsString:@"login"]) return YES;

    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [super requestIsCacheEquivalent:a toRequest:b];
}

- (void)startLoading {
    // 返回空 JSON 响应, 阻止 App 向服务器同步旧设备状态
    NSData *emptyData = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Content-Type": @"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:emptyData];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    // noop
}

@end

// ============================================================
// v2.12: KingSessionConfiguration 式网络拦截 (对标新设备插件核心)
// Swizzle NSURLSessionConfiguration.protocolClasses — 拦截所有 NSURLSession 请求
// 新设备插件通过 KingSessionConfiguration swizzle 此方法, 比 registerClass 更全面
// ============================================================
@interface NSURLSessionConfiguration (KingSessionSwizzle)
- (NSArray *)king_protocolClasses;
@end

@implementation NSURLSessionConfiguration (KingSessionSwizzle)
- (NSArray *)king_protocolClasses {
    // 调用原始实现获取已有的 protocolClasses
    NSArray *orig = [self king_protocolClasses];
    NSMutableArray *result = [NSMutableArray array];
    // 在最前面插入拦截器, 确保优先处理
    [result addObject:[WipeCustomURLProtocol class]];
    if (orig) {
        [result addObjectsFromArray:orig];
    }
    return result;
}
@end

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

        // v2.06: ICCID 私有方法安全检查与交换
        SEL selIccid = NSSelectorFromString(@"iccId");
        if ([CTCarrier instancesRespondToSelector:selIccid]) {
            method_exchangeImplementations(class_getInstanceMethod([CTCarrier class], selIccid),
                                           class_getInstanceMethod([CTCarrier class], @selector(fake_iccId)));
        }
        SEL selSimIccid = NSSelectorFromString(@"simICCID");
        if ([CTCarrier instancesRespondToSelector:selSimIccid]) {
            method_exchangeImplementations(class_getInstanceMethod([CTCarrier class], selSimIccid),
                                           class_getInstanceMethod([CTCarrier class], @selector(fake_simICCID)));
        }

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

        // v2.12: KingSessionConfiguration 式网络拦截 (对标新设备插件核心)
        // swizzle NSURLSessionConfiguration.protocolClasses — 拦截所有 session 请求
        // 比 registerClass 更全面: 覆盖 [NSURLSession sessionWithConfiguration:] 创建的自定义 session
        @try {
            Class sessionCls = [NSURLSessionConfiguration class];
            Method origM = class_getInstanceMethod(sessionCls, @selector(protocolClasses));
            Method fakeM = class_getInstanceMethod(sessionCls, @selector(king_protocolClasses));
            if (origM && fakeM) {
                method_exchangeImplementations(origM, fakeM);
                syslog(LOG_NOTICE, "[NetworkFaker] NSURLSessionConfiguration.protocolClasses swizzled (KingSession mode)");
            }
        } @catch(NSException *e) {
            syslog(LOG_ERR, "[NetworkFaker] KingSession swizzle error: %s", [e.reason UTF8String]);
        }
        // 同时保留 registerClass, 确保 [NSURLConnection sendSynchronousRequest:] 和 sharedSession 也被拦截
        [NSURLProtocol registerClass:[WipeCustomURLProtocol class]];
        syslog(LOG_NOTICE, "[NetworkFaker] WipeCustomURLProtocol registered + KingSession swizzled");
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
