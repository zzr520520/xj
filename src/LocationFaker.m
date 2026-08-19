// ============================================================
// LocationFaker.m v2.02 — GPS 定位伪造模块
// 基于 CLLocationManager swizzle, 在半径范围内随机漂移
// ============================================================

#import "LocationFaker.h"
#import <objc/runtime.h>
#import <syslog.h>

// ============================================================
// 静态状态
// ============================================================
static double g_baseLat = 0.0;
static double g_baseLon = 0.0;
static double g_radiusKm = 10.0;
static BOOL g_locationFakerActive = NO;

// ============================================================
// LocationFaker 实现
// ============================================================
@implementation LocationFaker

+ (CLLocation *)generateFakeLocation {
    if (!g_locationFakerActive) return nil;

    // 随机角度 (0 ~ 2*PI)
    double angle = ((double)arc4random_uniform(3600)) / 3600.0 * 2.0 * M_PI;
    // 随机距离 (0 ~ radius, 平方根分布使面积均匀)
    double distance = sqrt((double)arc4random_uniform(10000) / 10000.0) * g_radiusKm;

    // 转换为度数
    double latDelta = (distance * cos(angle)) / 111.0;
    double lonDelta = (distance * sin(angle)) / (111.0 * cos(g_baseLat * M_PI / 180.0));

    double fakeLat = g_baseLat + latDelta;
    double fakeLon = g_baseLon + lonDelta;

    // 随机海拔 50~200m
    double altitude = 50.0 + (arc4random_uniform(15000)) / 100.0;
    // 随机水平精度 5~30m
    double accuracy = 5.0 + (arc4random_uniform(2500)) / 100.0;

    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(fakeLat, fakeLon);
    NSDate *timestamp = [NSDate date];

    CLLocation *fakeLoc = [[CLLocation alloc] initWithCoordinate:coord
                                                        altitude:altitude
                                              horizontalAccuracy:accuracy
                                                verticalAccuracy:accuracy
                                                       timestamp:timestamp];
    return fakeLoc;
}

+ (void)setupLocationFakerWithLat:(double)lat lon:(double)lon radiusKm:(double)radius {
    if (lat == 0.0 && lon == 0.0) {
        syslog(LOG_NOTICE, "[LocationFaker] base coord is 0,0 — skipping");
        return;
    }

    g_baseLat = lat;
    g_baseLon = lon;
    g_radiusKm = radius > 0 ? radius : 10.0;

    if (!g_locationFakerActive) {
        g_locationFakerActive = YES;

        // Swizzle CLLocationManager
        Class cls = [CLLocationManager class];

        // startUpdatingLocation -> 注入 fake location
        SEL origSel = @selector(startUpdatingLocation);
        SEL fakeSel = @selector(fake_startUpdatingLocation);
        Method origMethod = class_getInstanceMethod(cls, origSel);
        Method fakeMethod = class_getInstanceMethod(cls, fakeSel);
        if (origMethod && fakeMethod) {
            method_exchangeImplementations(origMethod, fakeMethod);
            syslog(LOG_NOTICE, "[LocationFaker] startUpdatingLocation swizzled");
        }

        // requestLocation -> 注入 fake location
        SEL origReqSel = @selector(requestLocation);
        SEL fakeReqSel = @selector(fake_requestLocation);
        Method origReqMethod = class_getInstanceMethod(cls, origReqSel);
        Method fakeReqMethod = class_getInstanceMethod(cls, fakeReqSel);
        if (origReqMethod && fakeReqMethod) {
            method_exchangeImplementations(origReqMethod, fakeReqMethod);
            syslog(LOG_NOTICE, "[LocationFaker] requestLocation swizzled");
        }

        // location -> 返回 fake location (用于 CLLocationManager.location 属性)
        SEL origLocSel = @selector(location);
        SEL fakeLocSel = @selector(fake_location);
        Method origLocMethod = class_getInstanceMethod(cls, origLocSel);
        Method fakeLocMethod = class_getInstanceMethod(cls, fakeLocSel);
        if (origLocMethod && fakeLocMethod) {
            method_exchangeImplementations(origLocMethod, fakeLocMethod);
            syslog(LOG_NOTICE, "[LocationFaker] location property swizzled");
        }
    }

    syslog(LOG_NOTICE, "[LocationFaker] active: base=%.6f,%.6f radius=%.1fkm",
           g_baseLat, g_baseLon, g_radiusKm);
}

+ (void)teardown {
    g_locationFakerActive = NO;
    g_baseLat = 0.0;
    g_baseLon = 0.0;
    syslog(LOG_NOTICE, "[LocationFaker] torn down");
}

@end

// ============================================================
// CLLocationManager swizzle 实现
// ============================================================
@interface CLLocationManager (LocationFakerSwizzle)
- (void)fake_startUpdatingLocation;
- (void)fake_requestLocation;
- (CLLocation *)fake_location;
@end

@implementation CLLocationManager (LocationFakerSwizzle)

- (void)fake_startUpdatingLocation {
    // 调用原始方法让系统启动定位 (保持授权流程正常)
    [self fake_startUpdatingLocation];

    if (g_locationFakerActive) {
        // 延迟 0.3s 发送 fake location, 模拟真实 GPS 定位延迟
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CLLocation *fakeLoc = [LocationFaker generateFakeLocation];
            if (fakeLoc && self.delegate) {
                if ([self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
                    [self.delegate locationManager:self didUpdateLocations:@[fakeLoc]];
                }
            }
        });

        // 每 3 秒持续推送新坐标 (模拟移动)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (g_locationFakerActive) {
                CLLocation *loc = [LocationFaker generateFakeLocation];
                if (loc && self.delegate && [self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
                    [self.delegate locationManager:self didUpdateLocations:@[loc]];
                }
            }
        });
    }
}

- (void)fake_requestLocation {
    if (g_locationFakerActive) {
        // 直接返回 fake location, 不调用真实 GPS
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CLLocation *fakeLoc = [LocationFaker generateFakeLocation];
            if (fakeLoc && self.delegate) {
                if ([self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
                    [self.delegate locationManager:self didUpdateLocations:@[fakeLoc]];
                }
                // 停止更新 (模拟单次定位)
                [self stopUpdatingLocation];
            }
        });
    } else {
        [self fake_requestLocation];
    }
}

- (CLLocation *)fake_location {
    if (g_locationFakerActive) {
        return [LocationFaker generateFakeLocation];
    }
    return [self fake_location];
}

@end
