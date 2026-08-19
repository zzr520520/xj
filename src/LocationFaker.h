#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface LocationFaker : NSObject

// v2.02: 初始化定位伪造, 传入基准坐标和漂移半径(km)
+ (void)setupLocationFakerWithLat:(double)lat lon:(double)lon radiusKm:(double)radius;

// v2.02: 停止定位伪造
+ (void)teardown;

// v2.02: 生成一个随机漂移坐标 (基于基准点 + 半径内随机偏移)
+ (CLLocation *)generateFakeLocation;

@end
