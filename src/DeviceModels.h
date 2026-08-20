#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef struct {
    NSString *displayName;
    NSString *hwMachine;
    NSString *modelNumber;
    NSString *systemVersion;
    NSString *buildVersion;
    CGFloat width;
    CGFloat height;
    CGFloat scale;
    int ppi;
} FullDeviceProfile;

static const FullDeviceProfile kFullDevicePool[] = {
    // iPhone 17 系列
    {@"iPhone 17 Pro Max", @"iPhone18,2", @"MU793CH/A", @"19.0", @"21F77", 430, 932, 3.0, 460},
    {@"iPhone 17 Pro",     @"iPhone18,1", @"MTV03CH/A", @"19.0", @"21F77", 393, 852, 3.0, 460},
    {@"iPhone 17 Air",     @"iPhone18,4", @"MU183CH/A", @"19.0", @"21F77", 393, 852, 3.0, 460},
    {@"iPhone 17",          @"iPhone18,3", @"MTM63CH/A", @"19.0", @"21F77", 393, 852, 3.0, 460},

    // iPhone 16 系列
    {@"iPhone 16 Pro Max", @"iPhone17,2", @"MYWW3CH/A", @"18.0", @"21A331", 440, 956, 3.0, 460},
    {@"iPhone 16 Pro",     @"iPhone17,1", @"MYV43CH/A", @"18.0", @"21A331", 402, 874, 3.0, 460},
    {@"iPhone 16 Plus",    @"iPhone17,4", @"MYE23CH/A", @"18.0", @"21A331", 430, 932, 3.0, 460},
    {@"iPhone 16",         @"iPhone17,3", @"MYD83CH/A", @"18.0", @"21A331", 393, 852, 3.0, 460},

    // iPhone 15 系列
    {@"iPhone 15 Pro Max", @"iPhone16,2", @"MU793CH/A", @"17.4", @"21E219", 430, 932, 3.0, 460},
    {@"iPhone 15 Pro",     @"iPhone16,1", @"MTV03CH/A", @"17.4", @"21E219", 393, 852, 3.0, 460},

    // iPhone 14 系列
    {@"iPhone 14 Pro Max", @"iPhone15,3", @"MQ8R3CH/A", @"16.6", @"20G75",  430, 932, 3.0, 460},
    {@"iPhone 14 Pro",     @"iPhone15,2", @"MQ023CH/A", @"16.5", @"20F66",  393, 852, 3.0, 460},

    // iPhone 13 系列
    {@"iPhone 13 Pro Max", @"iPhone14,3", @"MLHD3CH/A", @"16.1", @"20B82",  428, 926, 3.0, 458},
    {@"iPhone 13 Pro",     @"iPhone14,2", @"ML843CH/A", @"16.0", @"20A362", 390, 844, 3.0, 460},

    // iPhone 12 / 11 / SE
    {@"iPhone 12",         @"iPhone13,2", @"MGGM3CH/A", @"15.4", @"19E241", 390, 844, 3.0, 460},
    {@"iPhone 11",         @"iPhone12,1", @"MWND2CH/A", @"15.0", @"19A346", 414, 896, 2.0, 326},
    {@"iPhone SE (3rd)",   @"iPhone14,6", @"MMX53CH/A", @"16.0", @"20A362", 375, 667, 2.0, 326}
};

// Luhn checksum — Apple 序列号末位校验
static inline char CalculateLuhnChecksum(NSString *baseStr) {
    int sum = 0;
    BOOL alternate = NO;
    for (NSInteger i = baseStr.length - 1; i >= 0; i--) {
        int n = [baseStr characterAtIndex:i] - '0';
        if (n < 0 || n > 9) n = 0;
        if (alternate) {
            n *= 2;
            if (n > 9) n -= 9;
        }
        sum += n;
        alternate = !alternate;
    }
    int check = (10 - (sum % 10)) % 10;
    return '0' + check;
}

// 多工厂前缀 + 动态年周 + Luhn 校验序列号
static inline NSString *GenValidSerialNumber(void) {
    NSArray *seedPrefixes = @[@"F17", @"C68", @"FD3", @"G4L", @"DN8"];
    NSArray *yearWeeks = @[@"332", @"411", @"220", @"152", @"210"];
    NSString *prefix = seedPrefixes[arc4random_uniform((uint32_t)seedPrefixes.count)];
    NSString *week = yearWeeks[arc4random_uniform((uint32_t)yearWeeks.count)];

    NSString *chars = @"0123456789ABCDEFGHJKLMNPQRSTUVWXYZ";
    NSMutableString *partial = [NSMutableString stringWithFormat:@"%@%@", prefix, week];
    for (int i = 0; i < 5; i++) {
        [partial appendFormat:@"%C", [chars characterAtIndex:arc4random_uniform((uint32_t)chars.length)]];
    }
    char checkChar = CalculateLuhnChecksum(partial);
    [partial appendFormat:@"%c", checkChar];
    return [partial copy];
}

// 随机 ECID (64-bit, 高位非零)
static inline NSString *GenerateRandomECID(void) {
    uint64_t ecid = 0;
    while (ecid < 0x100000000000000ULL) {
        ecid = ((uint64_t)arc4random() << 32) | arc4random();
    }
    return [NSString stringWithFormat:@"%llu", ecid];
}

// v2.02: 城市坐标池 — 定位伪造基准点
static const struct { double lat; double lon; } kCityCoords[] = {
    {39.9042, 116.4074}, // 北京
    {31.2304, 121.4737}, // 上海
    {23.1291, 113.2644}, // 广州
    {22.5431, 114.0579}, // 深圳
    {30.2741, 120.1551}, // 杭州
    {30.5728, 104.0668}  // 成都
};

// 商业级全套五码生成 — 硬件自洽 (v2.03: 含网络配置)
static inline NSDictionary *GenerateCommercialSeedProfile(void) {
    size_t count = sizeof(kFullDevicePool) / sizeof(FullDeviceProfile);
    FullDeviceProfile dev = kFullDevicePool[arc4random_uniform((uint32_t)count)];

    NSString *sn = GenValidSerialNumber();
    NSString *mlb = [NSString stringWithFormat:@"%@8XBX", sn];
    NSString *batterySN = GenValidSerialNumber();
    NSString *lcmSN = GenValidSerialNumber();
    NSString *rearCam = GenValidSerialNumber();
    NSString *frontCam = GenValidSerialNumber();
    NSString *coverSN = GenValidSerialNumber();

    NSString *udid = [[NSUUID UUID].UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *idfa = [NSUUID UUID].UUIDString;
    NSString *idfv = [NSUUID UUID].UUIDString;

    // Apple OUI MAC — BT = WiFi + 1 (硬件一致)
    uint8_t mac3 = arc4random_uniform(255);
    uint8_t mac4 = arc4random_uniform(255);
    uint8_t mac5 = arc4random_uniform(255);
    NSString *wifiMAC = [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, mac5];
    NSString *btMAC   = [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, (mac5 + 1) % 256];

    // 磁盘容量随机 256GB / 512GB
    NSArray *diskOptions = @[@(256000000000ULL), @(512000000000ULL)];
    NSNumber *selectedDisk = diskOptions[arc4random_uniform((uint32_t)diskOptions.count)];

    // v2.02: 随机城市坐标
    int cityIdx = arc4random_uniform(sizeof(kCityCoords) / sizeof(kCityCoords[0]));

    // v2.03: 网络模式随机选择
    NSArray *netModes = @[@"wifi", @"cellular", @"flight", @"nosim"];
    NSString *netMode = netModes[arc4random_uniform((uint32_t)netModes.count)];

    // v2.04: 随机运营商 (完整 MCC+MNC 列表, 含四大运营商)
    NSArray *carriers = @[
        // 中国移动
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"00"},
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"02"},
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"04"},
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"07"},
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"08"},
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"13"},
        // 中国联通
        @{@"name": @"中国联通", @"mcc": @"460", @"mnc": @"01"},
        @{@"name": @"中国联通", @"mcc": @"460", @"mnc": @"06"},
        @{@"name": @"中国联通", @"mcc": @"460", @"mnc": @"09"},
        @{@"name": @"中国联通", @"mcc": @"460", @"mnc": @"10"},
        // 中国电信
        @{@"name": @"中国电信", @"mcc": @"460", @"mnc": @"03"},
        @{@"name": @"中国电信", @"mcc": @"460", @"mnc": @"05"},
        @{@"name": @"中国电信", @"mcc": @"460", @"mnc": @"11"},
        @{@"name": @"中国电信", @"mcc": @"460", @"mnc": @"12"},
        // 中国广电
        @{@"name": @"中国广电", @"mcc": @"460", @"mnc": @"15"}
    ];
    NSDictionary *carrier = carriers[arc4random_uniform((uint32_t)carriers.count)];

    // v2.05: 广电 MNC 15 强制 5G, 其他随机 4G/5G
    NSString *radioTech;
    if ([carrier[@"mnc"] isEqualToString:@"15"]) {
        radioTech = @"CTRadioAccessTechnologyNR";  // 广电仅支持 5G
    } else {
        NSArray *radioTechs = @[@"CTRadioAccessTechnologyLTE", @"CTRadioAccessTechnologyNR"];
        radioTech = radioTechs[arc4random_uniform((uint32_t)radioTechs.count)];
    }

    // v2.05: 随机设备名称
    NSArray *owners = @[@"我的", @"小明的", @"小红的", @"张三的", @"李四的", @"王五的", @"赵六的", @"陈七的"];
    NSString *deviceName = [NSString stringWithFormat:@"%@iPhone", owners[arc4random_uniform((uint32_t)owners.count)]];

    // v2.05: 动态 User-Agent (基于系统版本)
    NSString *sysVerUnderscore = [dev.systemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *userAgent = [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", sysVerUnderscore];

    // v2.03: 随机 Wi-Fi SSID/BSSID
    NSString *wifiSSID = [NSString stringWithFormat:@"WiFi-%04X", arc4random_uniform(0xFFFF)];
    NSString *wifiBSSID = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
                           arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256),
                           arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];

    // v2.04: 电池状态随机生成
    NSInteger batteryHealth = 80 + arc4random_uniform(20);       // 80%~99%
    NSInteger batteryCycle = 100 + arc4random_uniform(400);       // 100~500次
    BOOL isCharging = arc4random_uniform(2) == 1;
    NSInteger batteryTemp = 200 + arc4random_uniform(150);        // 20.0~35.0°C (centi-degrees)
    NSInteger batteryCapacity = 20 + arc4random_uniform(80);     // 20%~99%
    NSInteger designCapacity = 3500;                               // 设计容量 mAh
    NSInteger maxCapacity = (NSInteger)((double)designCapacity * batteryHealth / 100.0);
    NSInteger currentCapacity = (NSInteger)((double)maxCapacity * batteryCapacity / 100.0);

    // v2.06: 物理内存精准映射
    uint64_t ramSize = 6442450944ULL; // 默认 6GB
    if ([dev.hwMachine hasPrefix:@"iPhone18"] ||
        [dev.hwMachine hasPrefix:@"iPhone17"] ||
        [dev.hwMachine hasPrefix:@"iPhone16,1"] ||
        [dev.hwMachine hasPrefix:@"iPhone16,2"]) {
        ramSize = 8589934592ULL; // 8GB
    } else if ([dev.hwMachine hasPrefix:@"iPhone12"] || [dev.hwMachine isEqualToString:@"iPhone14,6"]) {
        ramSize = 4294967296ULL; // 4GB
    }

    // v2.06: 屏幕刷新率
    BOOL isProMotion = [dev.displayName containsString:@"Pro"];
    double maxRefreshRate = isProMotion ? 120.0 : 60.0;

    // v2.06: GPU 名称
    NSString *gpuName = @"Apple A16 GPU";
    if ([dev.hwMachine hasPrefix:@"iPhone18"]) gpuName = @"Apple A19 Pro GPU";
    else if ([dev.hwMachine hasPrefix:@"iPhone17,1"] || [dev.hwMachine hasPrefix:@"iPhone17,2"]) gpuName = @"Apple A18 Pro GPU";
    else if ([dev.hwMachine hasPrefix:@"iPhone17"]) gpuName = @"Apple A18 GPU";
    else if ([dev.hwMachine hasPrefix:@"iPhone16,1"] || [dev.hwMachine hasPrefix:@"iPhone16,2"]) gpuName = @"Apple A17 Pro GPU";
    else if ([dev.hwMachine hasPrefix:@"iPhone15"]) gpuName = @"Apple A16 GPU";
    else if ([dev.hwMachine hasPrefix:@"iPhone14"]) gpuName = @"Apple A15 GPU";

    // v2.06: 开机时间偏移 (2~72 小时前)
    NSTimeInterval bootOffset = 7200 + arc4random_uniform(250000);
    time_t fakeBootSec = time(NULL) - (time_t)bootOffset;

    // v2.06: ICCID (8986 + 随机 + Luhn校验)
    NSMutableString *rawIccid = [NSMutableString stringWithFormat:@"898600%04u%08u",
                                 arc4random_uniform(9999), arc4random_uniform(99999999)];
    char iccidCheck = CalculateLuhnChecksum(rawIccid);
    [rawIccid appendFormat:@"%c", iccidCheck];

    return @{
        @"enabled": @(YES),
        @"HookMode": @(2),  // 默认完整模式, 可在 UI 中切换为 0(诊断) 或 1(保守)
        @"FlightMode": @([netMode isEqualToString:@"flight"]),   // v2.04: 由 NetworkMode 自动同步
        @"NoSIM": @([netMode isEqualToString:@"flight"] || [netMode isEqualToString:@"nosim"]),  // v2.04: 由 NetworkMode 自动同步
        @"DisplayName": dev.displayName,
        @"hw.machine": dev.hwMachine,
        @"ModelNumber": dev.modelNumber,
        @"SystemVersion": dev.systemVersion,
        @"OSBuildVersion": dev.buildVersion,  // v2.02: 系统构建版本号
        @"ScreenWidth": @(dev.width),
        @"ScreenHeight": @(dev.height),
        @"ScreenScale": @(dev.scale),
        @"ScreenPPI": @(dev.ppi),
        @"TotalDiskSize": selectedDisk,
        @"SerialNumber": sn,
        @"MLBSerialNumber": mlb,
        @"BatterySerialNumber": batterySN,
        @"LCMSerialNumber": lcmSN,
        @"RearFacingCameraIdentifier": rearCam,
        @"FrontFacingCameraIdentifier": frontCam,
        @"CoverGlassSerialNumber": coverSN,
        @"ECID": GenerateRandomECID(),
        @"UniqueDeviceID": udid,
        @"IDFA": idfa,
        @"IDFV": idfv,
        @"WifiAddress": wifiMAC,
        @"BluetoothAddress": btMAC,
        @"LocationLat": @(kCityCoords[cityIdx].lat),   // v2.02: 定位纬度
        @"LocationLon": @(kCityCoords[cityIdx].lon),   // v2.02: 定位经度
        @"LocationRadius": @(10.0),                      // v2.02: 漂移半径(km)
        @"NetworkMode": netMode,                         // v2.03: 网络模式
        @"CarrierName": carrier[@"name"],               // v2.03: 运营商名称
        @"CarrierMCC": carrier[@"mcc"],                  // v2.03: 运营商 MCC
        @"CarrierMNC": carrier[@"mnc"],                  // v2.03: 运营商 MNC
        @"RadioAccessTechnology": radioTech,             // v2.03: 网络类型 4G/5G
        @"WifiSSID": wifiSSID,                           // v2.03: WiFi SSID
        @"WifiBSSID": wifiBSSID,                         // v2.03: WiFi BSSID
        @"DeviceName": deviceName,                        // v2.05: 设备名称
        @"UserAgent": userAgent,                          // v2.05: HTTP User-Agent
        @"BatteryHealth": @(batteryHealth),              // v2.04: 电池健康度 (%)
        @"BatteryCycleCount": @(batteryCycle),           // v2.04: 电池循环次数
        @"IsCharging": @(isCharging),                    // v2.04: 充电状态
        @"BatteryTemperature": @(batteryTemp),           // v2.04: 电池温度 (centi-degrees)
        @"BatteryCurrentCapacity": @(batteryCapacity),    // v2.04: 当前电量 (%)
        @"BatteryDesignCapacity": @(designCapacity),      // v2.04: 设计容量 (mAh)
        @"BatteryMaxCapacity": @(maxCapacity),            // v2.04: 最大容量 (mAh)
        @"BatteryCurrentMAh": @(currentCapacity),         // v2.04: 当前容量 (mAh)
        @"PhysMemory": @(ramSize),                          // v2.06: 物理内存 (bytes)
        @"MaxRefreshRate": @(maxRefreshRate),               // v2.06: 屏幕最大刷新率
        @"GPUFamilyName": gpuName,                           // v2.06: GPU 名称
        @"BootTimeSec": @(fakeBootSec),                     // v2.06: 开机时间 (Unix epoch)
        @"ICCID": [rawIccid copy]                            // v2.06: SIM 卡 ICCID
    };
}
