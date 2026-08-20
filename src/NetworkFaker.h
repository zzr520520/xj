#import <Foundation/Foundation.h>

@interface NetworkFaker : NSObject

/// v2.03: 应用网络伪装配置 (传入从 config plist 读取的字典)
+ (void)applyNetworkConfig:(NSDictionary *)config;

/// v2.03: 重置为真实网络状态
+ (void)resetToDefault;

/// v2.03: 检查是否正在伪装
+ (BOOL)isFaking;

@end
