// ============================================================
// DeviceModels.h v2.13 — iPhone 6 ~ iPhone 16 全系硬件自洽矩阵
// v2.13: 扩展结构体, 添加 SOC/CPU核数/物理内存/像素分辨率/刷新率/Metal家族/GPU名称
//        30+ 机型完整交叉自洽矩阵 (对标全球方案)
// ============================================================

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// ============================================================
// 扩展设备画像 (v2.13: 硬件参数严格交叉自洽)
// ============================================================
typedef struct {
    NSString *displayName;    // 市场名称 (如 "iPhone 15 Pro Max")
    NSString *hwMachine;      // hw.machine (如 "iPhone16,2")
    NSString *modelNumber;    // hw.model / Apple 零件号 (如 "D84AP")
    NSString *systemVersion;  // iOS 版本
    NSString *buildVersion;   // iOS Build 号
    CGFloat width;            // 逻辑宽度 (pt)
    CGFloat height;           // 逻辑高度 (pt)
    CGFloat scale;            // 缩放倍率
    int ppi;                  // 像素密度
    // v2.13 新增字段
    NSString *soc;            // 芯片名称 (如 "Apple A17 Pro")
    int cpuCores;             // CPU 核心数
    uint64_t physmem;         // 物理内存 (bytes)
    int pxWidth;              // 像素宽度
    int pxHeight;             // 像素高度
    int maxFps;               // 最大刷新率
    int metalFamily;          // Metal GPU 家族号
    NSString *gpuName;        // GPU 名称
} FullDeviceProfile;

// ============================================================
// iPhone 6 ~ iPhone 16 全系完整矩阵 (30+ 机型)
// 风控对抗原则: hw.machine <-> SOC <-> Metal <-> 分辨率 <-> 刷新率 严格交叉自洽
// ============================================================
static const FullDeviceProfile kFullDevicePool[] = {
    // ---- iPhone 6 系列 (A8, 1GB) ----
    {@"iPhone 6",          @"iPhone7,2",  @"N61AP",  @"12.5.7", @"19H370", 375, 667,  2.0, 326,
     @"Apple A8", 2, 1073741824ULL, 750,  1334, 60, 1002, @"PowerVR GX6450"},
    {@"iPhone 6 Plus",     @"iPhone7,1",  @"N56AP",  @"12.5.7", @"19H370", 414, 736,  3.0, 401,
     @"Apple A8", 2, 1073741824ULL, 1080, 1920, 60, 1002, @"PowerVR GX6450"},

    // ---- iPhone 6s 系列 (A9, 2GB) ----
    {@"iPhone 6s",         @"iPhone8,1",  @"N71AP",  @"15.8.3", @"19H386", 375, 667,  2.0, 326,
     @"Apple A9", 2, 2147483648ULL, 750,  1334, 60, 1003, @"PowerVR GT7600"},
    {@"iPhone 6s Plus",    @"iPhone8,2",  @"N66AP",  @"15.8.3", @"19H386", 414, 736,  3.0, 401,
     @"Apple A9", 2, 2147483648ULL, 1080, 1920, 60, 1003, @"PowerVR GT7600"},
    {@"iPhone SE (1st)",   @"iPhone8,4",  @"N69AP",  @"15.8.3", @"19H386", 320, 568,  2.0, 326,
     @"Apple A9", 2, 2147483648ULL, 640,  1136, 60, 1003, @"PowerVR GT7600"},

    // ---- iPhone 7 系列 (A10 Fusion, 2-3GB) ----
    {@"iPhone 7",          @"iPhone9,1",  @"D10AP",  @"15.8.3", @"19H386", 375, 667,  2.0, 326,
     @"Apple A10 Fusion", 4, 2147483648ULL, 750,  1334, 60, 1003, @"PowerVR Series7XT Plus"},
    {@"iPhone 7 Plus",     @"iPhone9,2",  @"D11AP",  @"15.8.3", @"19H386", 414, 736,  3.0, 401,
     @"Apple A10 Fusion", 4, 3221225472ULL, 1080, 1920, 60, 1003, @"PowerVR Series7XT Plus"},

    // ---- iPhone 8 系列 (A11 Bionic, 2-3GB) ----
    {@"iPhone 8",          @"iPhone10,1", @"D20AP",  @"16.7.10",@"20H115", 375, 667,  2.0, 326,
     @"Apple A11 Bionic", 6, 2147483648ULL, 750,  1334, 60, 1004, @"Apple A11 GPU"},
    {@"iPhone 8 Plus",     @"iPhone10,2", @"D21AP",  @"16.7.10",@"20H115", 414, 736,  3.0, 401,
     @"Apple A11 Bionic", 6, 3221225472ULL, 1080, 1920, 60, 1004, @"Apple A11 GPU"},
    {@"iPhone X",          @"iPhone10,3", @"D22AP",  @"16.7.10",@"20H115", 375, 812,  3.0, 458,
     @"Apple A11 Bionic", 6, 3221225472ULL, 1125, 2436, 60, 1004, @"Apple A11 GPU"},

    // ---- iPhone XR/XS 系列 (A12 Bionic, 3-4GB) ----
    {@"iPhone XR",         @"iPhone11,8", @"N841AP",  @"17.7.2", @"21H221", 414, 896,  2.0, 326,
     @"Apple A12 Bionic", 6, 3221225472ULL, 828,  1792, 60, 1005, @"Apple A12 GPU"},
    {@"iPhone XS",         @"iPhone11,2", @"D321AP", @"17.7.2", @"21H221", 375, 812,  3.0, 458,
     @"Apple A12 Bionic", 6, 4294967296ULL, 1125, 2436, 60, 1005, @"Apple A12 GPU"},
    {@"iPhone XS Max",     @"iPhone11,4", @"D331pAP",@"17.7.2", @"21H221", 414, 896,  3.0, 458,
     @"Apple A12 Bionic", 6, 4294967296ULL, 1242, 2688, 60, 1005, @"Apple A12 GPU"},

    // ---- iPhone 11 系列 (A13 Bionic, 3-4GB) ----
    {@"iPhone 11",         @"iPhone12,1", @"N104AP",  @"17.7.2", @"21H221", 414, 896,  2.0, 326,
     @"Apple A13 Bionic", 6, 4294967296ULL, 828,  1792, 60, 1006, @"Apple A13 GPU"},
    {@"iPhone 11 Pro",     @"iPhone12,3", @"D421AP",  @"17.7.2", @"21H221", 375, 812,  3.0, 458,
     @"Apple A13 Bionic", 6, 4294967296ULL, 1125, 2436, 60, 1006, @"Apple A13 GPU"},
    {@"iPhone 11 Pro Max", @"iPhone12,5", @"D431AP",  @"17.7.2", @"21H221", 414, 896,  3.0, 458,
     @"Apple A13 Bionic", 6, 4294967296ULL, 1242, 2688, 60, 1006, @"Apple A13 GPU"},
    {@"iPhone SE (2nd)",   @"iPhone12,8", @"D79AP",   @"17.7.2", @"21H221", 375, 667,  2.0, 326,
     @"Apple A13 Bionic", 6, 3221225472ULL, 750,  1334, 60, 1006, @"Apple A13 GPU"},

    // ---- iPhone 12 系列 (A14 Bionic, 4-6GB) ----
    {@"iPhone 12 mini",    @"iPhone13,1", @"D52gAP",  @"17.7.2", @"21H221", 360, 780,  3.0, 476,
     @"Apple A14 Bionic", 6, 4294967296ULL, 1080, 2340, 60, 1007, @"Apple A14 GPU"},
    {@"iPhone 12",         @"iPhone13,2", @"D53gAP",  @"17.7.2", @"21H221", 390, 844,  3.0, 460,
     @"Apple A14 Bionic", 6, 4294967296ULL, 1170, 2532, 60, 1007, @"Apple A14 GPU"},
    {@"iPhone 12 Pro",     @"iPhone13,3", @"D53pAP",  @"17.7.2", @"21H221", 390, 844,  3.0, 460,
     @"Apple A14 Bionic", 6, 6442450944ULL, 1170, 2532, 60, 1007, @"Apple A14 GPU"},
    {@"iPhone 12 Pro Max", @"iPhone13,4", @"D54pAP",  @"17.7.2", @"21H221", 428, 926,  3.0, 458,
     @"Apple A14 Bionic", 6, 6442450944ULL, 1284, 2778, 60, 1007, @"Apple A14 GPU"},

    // ---- iPhone 13 系列 (A15 Bionic, 4-6GB) ----
    {@"iPhone 13 mini",    @"iPhone14,4", @"D16AP",   @"16.6.1", @"20G81",  360, 780,  3.0, 476,
     @"Apple A15 Bionic", 6, 4294967296ULL, 1080, 2340, 60, 1008, @"Apple A15 GPU (4-core)"},
    {@"iPhone 13",         @"iPhone14,5", @"D17AP",   @"16.6.1", @"20G81",  390, 844,  3.0, 460,
     @"Apple A15 Bionic", 6, 4294967296ULL, 1170, 2532, 60, 1008, @"Apple A15 GPU (4-core)"},
    {@"iPhone 13 Pro",     @"iPhone14,2", @"D63AP",   @"16.6.1", @"20G81",  390, 844,  3.0, 460,
     @"Apple A15 Bionic", 6, 6442450944ULL, 1170, 2532, 120, 1008, @"Apple A15 GPU (5-core)"},
    {@"iPhone 13 Pro Max", @"iPhone14,3", @"D64AP",   @"16.6.1", @"20G81",  428, 926,  3.0, 458,
     @"Apple A15 Bionic", 6, 6442450944ULL, 1284, 2778, 120, 1008, @"Apple A15 GPU (5-core)"},
    {@"iPhone SE (3rd)",   @"iPhone14,6", @"D49AP",   @"17.7.2", @"21H221", 375, 667,  2.0, 326,
     @"Apple A15 Bionic", 6, 4294967296ULL, 750,  1334, 60, 1008, @"Apple A15 GPU (4-core)"},

    // ---- iPhone 14 系列 (A15/A16 Bionic, 6-8GB) ----
    {@"iPhone 14",         @"iPhone14,7", @"D27AP",   @"17.7.2", @"21H221", 390, 844,  3.0, 460,
     @"Apple A15 Bionic", 6, 6442450944ULL, 1170, 2532, 60, 1008, @"Apple A15 GPU (5-core)"},
    {@"iPhone 14 Plus",    @"iPhone14,8", @"D28AP",   @"17.7.2", @"21H221", 428, 926,  3.0, 458,
     @"Apple A15 Bionic", 6, 6442450944ULL, 1284, 2778, 60, 1008, @"Apple A15 GPU (5-core)"},
    {@"iPhone 14 Pro",     @"iPhone15,2", @"D73AP",   @"17.7.2", @"21H221", 393, 852,  3.0, 460,
     @"Apple A16 Bionic", 6, 6442450944ULL, 1179, 2556, 120, 1008, @"Apple A16 GPU"},
    {@"iPhone 14 Pro Max", @"iPhone15,3", @"D74AP",   @"17.7.2", @"21H221", 430, 932,  3.0, 460,
     @"Apple A16 Bionic", 6, 6442450944ULL, 1290, 2796, 120, 1008, @"Apple A16 GPU"},

    // ---- iPhone 15 系列 (A16/A17 Pro, 6-8GB) ----
    {@"iPhone 15",         @"iPhone15,4", @"D37AP",   @"18.3.2", @"22D82",  393, 852,  3.0, 460,
     @"Apple A16 Bionic", 6, 6442450944ULL, 1179, 2556, 60, 1008, @"Apple A16 GPU"},
    {@"iPhone 15 Plus",    @"iPhone15,5", @"D38AP",   @"18.3.2", @"22D82",  430, 932,  3.0, 460,
     @"Apple A16 Bionic", 6, 6442450944ULL, 1290, 2796, 60, 1008, @"Apple A16 GPU"},
    {@"iPhone 15 Pro",     @"iPhone16,1", @"D83AP",   @"18.3.2", @"22D82",  393, 852,  3.0, 460,
     @"Apple A17 Pro",   6, 8589934592ULL, 1179, 2556, 120, 1009, @"Apple A17 Pro GPU"},
    {@"iPhone 15 Pro Max", @"iPhone16,2", @"D84AP",   @"18.3.2", @"22D82",  430, 932,  3.0, 460,
     @"Apple A17 Pro",   6, 8589934592ULL, 1290, 2796, 120, 1009, @"Apple A17 Pro GPU"},

    // ---- iPhone 16 系列 (A18/A18 Pro, 8GB) ----
    {@"iPhone 16",         @"iPhone17,3", @"D47AP",   @"18.3.2", @"22D82",  393, 852,  3.0, 460,
     @"Apple A18",       6, 8589934592ULL, 1179, 2556, 60, 1009, @"Apple A18 GPU (5-core)"},
    {@"iPhone 16 Plus",    @"iPhone17,4", @"D48AP",   @"18.3.2", @"22D82",  430, 932,  3.0, 460,
     @"Apple A18",       6, 8589934592ULL, 1290, 2796, 60, 1009, @"Apple A18 GPU (5-core)"},
    {@"iPhone 16 Pro",     @"iPhone17,1", @"D93AP",   @"18.3.2", @"22D82",  402, 874,  3.0, 460,
     @"Apple A18 Pro",   6, 8589934592ULL, 1206, 2622, 120, 1009, @"Apple A18 Pro GPU (6-core)"},
    {@"iPhone 16 Pro Max", @"iPhone17,2", @"D94AP",   @"18.3.2", @"22D82",  440, 956,  3.0, 460,
     @"Apple A18 Pro",   6, 8589934592ULL, 1320, 2868, 120, 1009, @"Apple A18 Pro GPU (6-core)"},
};

// ============================================================
// Luhn checksum — Apple 序列号末位校验
// ============================================================
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

// ============================================================
// 商业级全套五码生成 — 硬件自洽 (v2.13: 直接从机型矩阵读取全部参数)
// ============================================================
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
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"00"},
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"02"},
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"04"},
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"07"},
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"08"},
        @{@"name": @"中国移动", @"mcc": @"460", @"mnc": @"13"},
        @{@"name": @"中国联通", @"mcc": @"460", @"mnc": @"01"},
        @{@"name": @"中国联通", @"mcc": @"460", @"mnc": @"06"},
        @{@"name": @"中国联通", @"mcc": @"460", @"mnc": @"09"},
        @{@"name": @"中国联通", @"mcc": @"460", @"mnc": @"10"},
        @{@"name": @"中国电信", @"mcc": @"460", @"mnc": @"03"},
        @{@"name": @"中国电信", @"mcc": @"460", @"mnc": @"05"},
        @{@"name": @"中国电信", @"mcc": @"460", @"mnc": @"11"},
        @{@"name": @"中国电信", @"mcc": @"460", @"mnc": @"12"},
        @{@"name": @"中国广电", @"mcc": @"460", @"mnc": @"15"}
    ];
    NSDictionary *carrier = carriers[arc4random_uniform((uint32_t)carriers.count)];

    // v2.05: 广电 MNC 15 强制 5G, 其他随机 4G/5G
    NSString *radioTech;
    if ([carrier[@"mnc"] isEqualToString:@"15"]) {
        radioTech = @"CTRadioAccessTechnologyNR";
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
    NSInteger batteryHealth = 80 + arc4random_uniform(20);
    NSInteger batteryCycle = 100 + arc4random_uniform(400);
    BOOL isCharging = arc4random_uniform(2) == 1;
    NSInteger batteryTemp = 200 + arc4random_uniform(150);
    NSInteger batteryCapacity = 20 + arc4random_uniform(80);
    NSInteger designCapacity = 3500;
    NSInteger maxCapacity = (NSInteger)((double)designCapacity * batteryHealth / 100.0);
    NSInteger currentCapacity = (NSInteger)((double)maxCapacity * batteryCapacity / 100.0);

    // v2.13: 直接从机型矩阵读取, 不再硬编码 if-else
    // (之前 v2.06 用 hwMachine 前缀匹配 ramSize/maxFps/gpuName, 现在直接用结构体字段)
    uint64_t ramSize = dev.physmem;
    double maxRefreshRate = (double)dev.maxFps;
    NSString *gpuName = dev.gpuName;

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
        @"HookMode": @(2),
        @"FlightMode": @([netMode isEqualToString:@"flight"]),
        @"NoSIM": @([netMode isEqualToString:@"flight"] || [netMode isEqualToString:@"nosim"]),
        @"DisplayName": dev.displayName,
        @"hw.machine": dev.hwMachine,
        @"ModelNumber": dev.modelNumber,
        @"SystemVersion": dev.systemVersion,
        @"OSBuildVersion": dev.buildVersion,
        @"ScreenWidth": @(dev.width),
        @"ScreenHeight": @(dev.height),
        @"ScreenScale": @(dev.scale),
        @"ScreenPPI": @(dev.ppi),
        // v2.13: 新增硬件自洽参数
        @"SOC": dev.soc,
        @"CPUCores": @(dev.cpuCores),
        @"PhysMemory": @(ramSize),
        @"PixelWidth": @(dev.pxWidth),
        @"PixelHeight": @(dev.pxHeight),
        @"MaxRefreshRate": @(maxRefreshRate),
        @"MetalFamily": @(dev.metalFamily),
        @"GPUFamilyName": gpuName,
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
        @"LocationLat": @(kCityCoords[cityIdx].lat),
        @"LocationLon": @(kCityCoords[cityIdx].lon),
        @"LocationRadius": @(10.0),
        @"NetworkMode": netMode,
        @"CarrierName": carrier[@"name"],
        @"CarrierMCC": carrier[@"mcc"],
        @"CarrierMNC": carrier[@"mnc"],
        @"RadioAccessTechnology": radioTech,
        @"WifiSSID": wifiSSID,
        @"WifiBSSID": wifiBSSID,
        @"DeviceName": deviceName,
        @"UserAgent": userAgent,
        @"BatteryHealth": @(batteryHealth),
        @"BatteryCycleCount": @(batteryCycle),
        @"IsCharging": @(isCharging),
        @"BatteryTemperature": @(batteryTemp),
        @"BatteryCurrentCapacity": @(batteryCapacity),
        @"BatteryDesignCapacity": @(designCapacity),
        @"BatteryMaxCapacity": @(maxCapacity),
        @"BatteryCurrentMAh": @(currentCapacity),
        @"BootTimeSec": @(fakeBootSec),
        @"ICCID": [rawIccid copy]
    };
}
