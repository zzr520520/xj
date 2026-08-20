// ============================================================
// LocationFaker.m v2.11 — GPS 定位伪造 + 传感器噪声模拟
// v2.02: 基于 CLLocationManager swizzle, 在半径范围内随机漂移
// v2.11: Weibull 分布传感器噪声 / 持续定时器推送 / CoreMotion 拦截
// ============================================================

#import "LocationFaker.h"
#import <objc/runtime.h>
#import <syslog.h>
#import <CoreMotion/CoreMotion.h>
#import <math.h>

// ============================================================
// 静态状态
// ============================================================
static double g_baseLat = 0.0;
static double g_baseLon = 0.0;
static double g_radiusKm = 10.0;
static BOOL g_locationFakerActive = NO;

// ============================================================
// v2.11: Weibull 分布随机噪声 (模拟真实传感器噪声分布)
// lambda: 尺度参数, k: 形状参数
// ============================================================
static double weibullRandom(double lambda, double k) {
    double u = (double)arc4random() / UINT32_MAX;
    if (u == 0.0) u = 0.001;
    if (u >= 1.0) u = 0.999;
    return lambda * pow(-log(1.0 - u), 1.0 / k);
}

// 均匀分布 [-1, 1] 的随机数
static double uniformRandom(void) {
    return ((double)arc4random() / UINT32_MAX) * 2.0 - 1.0;
}

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

    // v2.11: 使用 Weibull 分布生成更真实的海拔和精度
    // 真实 GPS 海拔通常在 30~80m, 附加 Weibull 噪声模拟多径效应
    double altitude = 35.0 + weibullRandom(15.0, 1.8);
    // 水平精度: 基准 5m + Weibull 噪声 (k=1.5 模拟城市环境多径)
    double hAccuracy = 5.0 + weibullRandom(3.0, 1.5);
    // 垂直精度通常比水平差 1.5~2 倍
    double vAccuracy = hAccuracy * (1.5 + weibullRandom(0.3, 1.2));
    // 航向: 随机方向 (0~360)
    double course = ((double)arc4random() / UINT32_MAX) * 360.0;
    // 速度: 静止状态微小波动 (0~0.5 m/s)
    double speed = weibullRandom(0.15, 0.8);

    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(fakeLat, fakeLon);
    NSDate *timestamp = [NSDate date];

    CLLocation *fakeLoc = [[CLLocation alloc] initWithCoordinate:coord
                                                        altitude:altitude
                                              horizontalAccuracy:hAccuracy
                                                verticalAccuracy:vAccuracy
                                                       course:course
                                                        speed:speed
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

        // stopUpdatingLocation -> 清理定时器
        SEL origStopSel = @selector(stopUpdatingLocation);
        SEL fakeStopSel = @selector(fake_stopUpdatingLocation);
        Method origStopMethod = class_getInstanceMethod(cls, origStopSel);
        Method fakeStopMethod = class_getInstanceMethod(cls, fakeStopSel);
        if (origStopMethod && fakeStopMethod) {
            method_exchangeImplementations(origStopMethod, fakeStopMethod);
            syslog(LOG_NOTICE, "[LocationFaker] stopUpdatingLocation swizzled");
        }

        // v2.11: CoreMotion 传感器拦截 (防止通过传感器交叉验证检测假定位)
        Class motionCls = [CMMotionManager class];
        SEL origAccelSel = @selector(startAccelerometerUpdatesToQueue:withHandler:);
        SEL fakeAccelSel = @selector(fake_startAccelerometerUpdatesToQueue:withHandler:);
        Method origAccelMethod = class_getInstanceMethod(motionCls, origAccelSel);
        Method fakeAccelMethod = class_getInstanceMethod(motionCls, fakeAccelSel);
        if (origAccelMethod && fakeAccelMethod) {
            method_exchangeImplementations(origAccelMethod, fakeAccelMethod);
            syslog(LOG_NOTICE, "[LocationFaker] CMMotionManager accelerometer swizzled");
        }

        SEL origDeviceMotionSel = @selector(startDeviceMotionUpdatesToQueue:withHandler:);
        SEL fakeDeviceMotionSel = @selector(fake_startDeviceMotionUpdatesToQueue:withHandler:);
        Method origDMMethod = class_getInstanceMethod(motionCls, origDeviceMotionSel);
        Method fakeDMMethod = class_getInstanceMethod(motionCls, fakeDeviceMotionSel);
        if (origDMMethod && fakeDMMethod) {
            method_exchangeImplementations(origDMMethod, fakeDMMethod);
            syslog(LOG_NOTICE, "[LocationFaker] CMMotionManager deviceMotion swizzled");
        }

        // 加速度计数据属性拦截
        SEL origAccelDataSel = @selector(accelerometerData);
        SEL fakeAccelDataSel = @selector(fake_accelerometerData);
        Method origAccelDataMethod = class_getInstanceMethod(motionCls, origAccelDataSel);
        Method fakeAccelDataMethod = class_getInstanceMethod(motionCls, fakeAccelDataSel);
        if (origAccelDataMethod && fakeAccelDataMethod) {
            method_exchangeImplementations(origAccelDataMethod, fakeAccelDataMethod);
            syslog(LOG_NOTICE, "[LocationFaker] accelerometerData property swizzled");
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
// 关联对象 Key (用于定时器管理)
// ============================================================
static const char *kTimerKey = "LocationFakerTimer";
static const char *kIsFakingKey = "LocationFakerIsFaking";

// ============================================================
// CLLocationManager swizzle 实现
// ============================================================
@interface CLLocationManager (LocationFakerSwizzle)
- (void)fake_startUpdatingLocation;
- (void)fake_requestLocation;
- (CLLocation *)fake_location;
- (void)fake_stopUpdatingLocation;
@end

@implementation CLLocationManager (LocationFakerSwizzle)

- (void)fake_startUpdatingLocation {
    // 调用原始方法让系统启动定位 (保持授权流程正常)
    [self fake_startUpdatingLocation];

    if (g_locationFakerActive) {
        // 防止重复启动定时器
        if ([objc_getAssociatedObject(self, kIsFakingKey) boolValue]) return;
        objc_setAssociatedObject(self, kIsFakingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 延迟 0.3s 发送首个 fake location, 模拟真实 GPS 定位延迟
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CLLocation *fakeLoc = [LocationFaker generateFakeLocation];
            if (fakeLoc && self.delegate) {
                if ([self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
                    [self.delegate locationManager:self didUpdateLocations:@[fakeLoc]];
                }
            }
        });

        // v2.11: 持续定时器推送新坐标 (3~5秒随机间隔, 模拟真实 GPS 更新频率)
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                          target:self
                                                        selector:@selector(fakeLocationTimerFire:)
                                                        userInfo:nil
                                                         repeats:YES];
        objc_setAssociatedObject(self, kTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    }
}

- (void)fakeLocationTimerFire:(NSTimer *)timer {
    if (!g_locationFakerActive) {
        [timer invalidate];
        return;
    }
    CLLocation *loc = [LocationFaker generateFakeLocation];
    if (loc && self.delegate && [self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [self.delegate locationManager:self didUpdateLocations:@[loc]];
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

- (void)fake_stopUpdatingLocation {
    // 清理定时器
    NSTimer *timer = objc_getAssociatedObject(self, kTimerKey);
    if (timer) {
        [timer invalidate];
        objc_setAssociatedObject(self, kTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(self, kIsFakingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // 调用原始方法
    [self fake_stopUpdatingLocation];
}

@end

// ============================================================
// v2.11: CMMotionManager 传感器拦截
// 通过 handler 拦截方式注入噪声, 防止传感器交叉验证检测假定位
// ============================================================
@interface CMMotionManager (FakeSensor)
- (void)fake_startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler;
- (void)fake_startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMDeviceMotionHandler)handler;
- (CMAccelerometerData *)fake_accelerometerData;
@end

@implementation CMMotionManager (FakeSensor)

- (void)fake_startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler {
    // 透传真实传感器数据, 添加微小噪声扰动
    [self fake_startAccelerometerUpdatesToQueue:queue withHandler:^(CMAccelerometerData *data, NSError *error) {
        if (g_locationFakerActive && data && !error) {
            // 通过 KVC 修改加速度值, 添加 Weibull 噪声
            @try {
                CMAcceleration acc = data.acceleration;
                // 添加微小噪声 (±0.02g), 模拟手部微颤
                acc.x += uniformRandom() * weibullRandom(0.01, 1.5);
                acc.y += uniformRandom() * weibullRandom(0.01, 1.5);
                acc.z += uniformRandom() * weibullRandom(0.01, 1.5);
                // 使用 KVC 尝试修改 (CoreMotion 内部 ivar)
                [data setValue:[NSValue value:&acc withObjCType:@encode(CMAcceleration)] forKey:@"acceleration"];
            } @catch(NSException *e) {
                // KVC 修改失败时直接透传原始数据 (不影响正常使用)
            }
        }
        handler(data, error);
    }];
}

- (void)fake_startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMDeviceMotionHandler)handler {
    // 透传真实设备运动数据, 添加微小噪声
    [self fake_startDeviceMotionUpdatesToQueue:queue withHandler:^(CMDeviceMotion *data, NSError *error) {
        if (g_locationFakerActive && data && !error) {
            @try {
                // 修改 attitude (姿态) 添加微小扰动
                CMAttitude *attitude = data.attitude;
                if (attitude) {
                    double roll = attitude.roll + uniformRandom() * weibullRandom(0.005, 1.5);
                    double pitch = attitude.pitch + uniformRandom() * weibullRandom(0.005, 1.5);
                    double yaw = attitude.yaw + uniformRandom() * weibullRandom(0.005, 1.5);
                    [attitude setValue:@(roll) forKey:@"roll"];
                    [attitude setValue:@(pitch) forKey:@"pitch"];
                    [attitude setValue:@(yaw) forKey:@"yaw"];
                }
            } @catch(NSException *e) {
                // KVC 修改失败时直接透传
            }
        }
        handler(data, error);
    }];
}

- (CMAccelerometerData *)fake_accelerometerData {
    CMAccelerometerData *data = [self fake_accelerometerData];
    if (g_locationFakerActive && data) {
        @try {
            CMAcceleration acc = data.acceleration;
            acc.x += uniformRandom() * weibullRandom(0.01, 1.5);
            acc.y += uniformRandom() * weibullRandom(0.01, 1.5);
            acc.z += uniformRandom() * weibullRandom(0.01, 1.5);
            [data setValue:[NSValue value:&acc withObjCType:@encode(CMAcceleration)] forKey:@"acceleration"];
        } @catch(NSException *e) {}
    }
    return data;
}

@end
