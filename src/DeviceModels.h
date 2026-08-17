#import <Foundation/Foundation.h>

typedef struct {
    NSString *displayName;
    NSString *hwMachine;
    NSString *modelNumber;
    NSString *systemVersion;
} FullDeviceProfile;

static const FullDeviceProfile kFullDevicePool[] = {
    // iPhone 15 系列
    {@"iPhone 15 Pro Max", @"iPhone16,2", @"MU793CH/A", @"17.4"},
    {@"iPhone 15 Pro",     @"iPhone16,1", @"MTV03CH/A", @"17.4"},
    {@"iPhone 15 Plus",    @"iPhone15,5", @"MU183CH/A", @"17.2"},
    {@"iPhone 15",         @"iPhone15,4", @"MTM63CH/A", @"17.2"},

    // iPhone 14 系列
    {@"iPhone 14 Pro Max", @"iPhone15,3", @"MQ8R3CH/A", @"16.6"},
    {@"iPhone 14 Pro",     @"iPhone15,2", @"MQ023CH/A", @"16.5"},
    {@"iPhone 14 Plus",    @"iPhone14,8", @"MQ3X3CH/A", @"16.5"},
    {@"iPhone 14",         @"iPhone14,7", @"MPUD3CH/A", @"16.4"},

    // iPhone 13 系列
    {@"iPhone 13 Pro Max", @"iPhone14,3", @"MLHD3CH/A", @"16.1"},
    {@"iPhone 13 Pro",     @"iPhone14,2", @"ML843CH/A", @"16.0"},
    {@"iPhone 13",         @"iPhone14,5", @"MLDF3CH/A", @"15.7"},
    {@"iPhone 13 mini",    @"iPhone14,4", @"MLDC3CH/A", @"15.7"},

    // iPhone 12 / 11 / SE 系列
    {@"iPhone 12 Pro Max", @"iPhone13,4", @"MGC33CH/A", @"15.4"},
    {@"iPhone 12",         @"iPhone13,2", @"MGGM3CH/A", @"15.4"},
    {@"iPhone 11 Pro Max", @"iPhone12,5", @"MWF32CH/A", @"15.0"},
    {@"iPhone 11",         @"iPhone12,1", @"MWND2CH/A", @"15.0"},
    {@"iPhone SE (3rd)",   @"iPhone14,6", @"MMX53CH/A", @"16.0"},

    // iPad Pro 系列
    {@"iPad Pro 13 (M4)",  @"iPad16,6",  @"MVX23CH/A", @"17.5"},
    {@"iPad Pro 11 (M4)",  @"iPad16,4",  @"MVDC3CH/A", @"17.5"},
    {@"iPad Pro 12.9 (6th)", @"iPad14,6", @"MNXR3CH/A", @"16.5"},
    {@"iPad Pro 11 (4th)", @"iPad14,4",  @"MNXF3CH/A", @"16.5"},

    // iPad Air / mini
    {@"iPad Air (6th 13\")", @"iPad14,10",@"MUWE3CH/A", @"17.5"},
    {@"iPad Air (5th M1)", @"iPad13,17", @"MM9E3CH/A", @"16.2"},
    {@"iPad mini (6th)",   @"iPad14,2",  @"MK7R3CH/A", @"16.0"},
    {@"iPad (10th gen)",   @"iPad13,18", @"MPQ03CH/A", @"16.1"}
};

// Luhn checksum calculation for Apple serial number validation
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

// Generate serial number with Luhn checksum, multi-factory prefix and dynamic year-week
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

    // Apple OUI MAC with BT = WiFi + 1 (hardware-consistent)
    uint8_t mac3 = arc4random_uniform(255);
    uint8_t mac4 = arc4random_uniform(255);
    uint8_t mac5 = arc4random_uniform(255);
    NSString *wifiMAC = [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, mac5];
    NSString *btMAC = [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, (mac5 + 1) % 256];

    return @{
        @"enabled": @(YES),
        @"DisplayName": dev.displayName,
        @"hw.machine": dev.hwMachine,
        @"ModelNumber": dev.modelNumber,
        @"SystemVersion": dev.systemVersion,
        @"SerialNumber": sn,
        @"MLBSerialNumber": mlb,
        @"BatterySerialNumber": batterySN,
        @"LCMSerialNumber": lcmSN,
        @"RearFacingCameraIdentifier": rearCam,
        @"FrontFacingCameraIdentifier": frontCam,
        @"CoverGlassSerialNumber": coverSN,
        @"UniqueDeviceID": udid,
        @"IDFA": idfa,
        @"IDFV": idfv,
        @"WifiAddress": wifiMAC,
        @"BluetoothAddress": btMAC
    };
}
