#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef struct {
    NSString *displayName;
    NSString *hwMachine;
    NSString *modelNumber;
    NSString *systemVersion;
    CGFloat width;
    CGFloat height;
    CGFloat scale;
    int ppi;
} FullDeviceProfile;

static const FullDeviceProfile kFullDevicePool[] = {
    // iPhone 17 系列
    {@"iPhone 17 Pro Max", @"iPhone18,2", @"MU793CH/A", @"19.0", 430, 932, 3.0, 460},
    {@"iPhone 17 Pro",     @"iPhone18,1", @"MTV03CH/A", @"19.0", 393, 852, 3.0, 460},
    {@"iPhone 17 Air",     @"iPhone18,4", @"MU183CH/A", @"19.0", 393, 852, 3.0, 460},
    {@"iPhone 17",          @"iPhone18,3", @"MTM63CH/A", @"19.0", 393, 852, 3.0, 460},

    // iPhone 16 系列
    {@"iPhone 16 Pro Max", @"iPhone17,2", @"MYWW3CH/A", @"18.0", 440, 956, 3.0, 460},
    {@"iPhone 16 Pro",     @"iPhone17,1", @"MYV43CH/A", @"18.0", 402, 874, 3.0, 460},
    {@"iPhone 16 Plus",    @"iPhone17,4", @"MYE23CH/A", @"18.0", 430, 932, 3.0, 460},
    {@"iPhone 16",         @"iPhone17,3", @"MYD83CH/A", @"18.0", 393, 852, 3.0, 460},

    // iPhone 15 系列
    {@"iPhone 15 Pro Max", @"iPhone16,2", @"MU793CH/A", @"17.4", 430, 932, 3.0, 460},
    {@"iPhone 15 Pro",     @"iPhone16,1", @"MTV03CH/A", @"17.4", 393, 852, 3.0, 460},

    // iPhone 14 系列
    {@"iPhone 14 Pro Max", @"iPhone15,3", @"MQ8R3CH/A", @"16.6", 430, 932, 3.0, 460},
    {@"iPhone 14 Pro",     @"iPhone15,2", @"MQ023CH/A", @"16.5", 393, 852, 3.0, 460},

    // iPhone 13 系列
    {@"iPhone 13 Pro Max", @"iPhone14,3", @"MLHD3CH/A", @"16.1", 428, 926, 3.0, 458},
    {@"iPhone 13 Pro",     @"iPhone14,2", @"ML843CH/A", @"16.0", 390, 844, 3.0, 460},

    // iPhone 12 / 11 / SE
    {@"iPhone 12",         @"iPhone13,2", @"MGGM3CH/A", @"15.4", 390, 844, 3.0, 460},
    {@"iPhone 11",         @"iPhone12,1", @"MWND2CH/A", @"15.0", 414, 896, 2.0, 326},
    {@"iPhone SE (3rd)",   @"iPhone14,6", @"MMX53CH/A", @"16.0", 375, 667, 2.0, 326}
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

// 商业级全套五码生成 — 硬件自洽
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

    return @{
        @"enabled": @(YES),
        @"DisplayName": dev.displayName,
        @"hw.machine": dev.hwMachine,
        @"ModelNumber": dev.modelNumber,
        @"SystemVersion": dev.systemVersion,
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
        @"BluetoothAddress": btMAC
    };
}
