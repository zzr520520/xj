#import <Foundation/Foundation.h>

typedef struct {
    NSString *displayName;
    NSString *hwMachine;
    NSString *modelNumber;
    NSString *regionCode;
    NSString *systemVersion;
    NSString *chipID;
} FullDeviceProfile;

static const FullDeviceProfile kFullDevicePool[] = {
    // iPhone 15 系列
    {@"iPhone 15 Pro Max", @"iPhone16,2", @"MU793CH/A", @"CH/A", @"17.4", @"0x8130"},
    {@"iPhone 15 Pro",     @"iPhone16,1", @"MTV03CH/A", @"CH/A", @"17.4", @"0x8130"},
    {@"iPhone 15 Plus",    @"iPhone15,5", @"MU183CH/A", @"CH/A", @"17.2", @"0x8120"},
    {@"iPhone 15",         @"iPhone15,4", @"MTM63CH/A", @"CH/A", @"17.2", @"0x8120"},

    // iPhone 14 系列
    {@"iPhone 14 Pro Max", @"iPhone15,3", @"MQ8R3CH/A", @"CH/A", @"16.6", @"0x8120"},
    {@"iPhone 14 Pro",     @"iPhone15,2", @"MQ023CH/A", @"CH/A", @"16.5", @"0x8120"},
    {@"iPhone 14 Plus",    @"iPhone14,8", @"MQ3X3CH/A", @"CH/A", @"16.5", @"0x8110"},
    {@"iPhone 14",         @"iPhone14,7", @"MPUD3CH/A", @"CH/A", @"16.4", @"0x8110"},

    // iPhone 13 系列
    {@"iPhone 13 Pro Max", @"iPhone14,3", @"MLHD3CH/A", @"CH/A", @"16.1", @"0x8110"},
    {@"iPhone 13 Pro",     @"iPhone14,2", @"ML843CH/A", @"CH/A", @"16.0", @"0x8110"},
    {@"iPhone 13",         @"iPhone14,5", @"MLDF3CH/A", @"CH/A", @"15.7", @"0x8103"},
    {@"iPhone 13 mini",    @"iPhone14,4", @"MLDC3CH/A", @"CH/A", @"15.7", @"0x8103"},

    // iPhone 12 / 11 / SE 系列
    {@"iPhone 12 Pro Max", @"iPhone13,4", @"MGC33CH/A", @"CH/A", @"15.4", @"0x8103"},
    {@"iPhone 12",         @"iPhone13,2", @"MGGM3CH/A", @"CH/A", @"15.4", @"0x8103"},
    {@"iPhone 11 Pro Max", @"iPhone12,5", @"MWF32CH/A", @"CH/A", @"15.0", @"0x8020"},
    {@"iPhone 11",         @"iPhone12,1", @"MWND2CH/A", @"CH/A", @"15.0", @"0x8020"},
    {@"iPhone SE (3rd)",   @"iPhone14,6", @"MMX53CH/A", @"CH/A", @"16.0", @"0x8110"},

    // iPad Pro 系列
    {@"iPad Pro 13 (M4)",  @"iPad16,6",  @"MVX23CH/A", @"CH/A", @"17.5", @"0x8132"},
    {@"iPad Pro 11 (M4)",  @"iPad16,4",  @"MVDC3CH/A", @"CH/A", @"17.5", @"0x8132"},
    {@"iPad Pro 12.9 (6th)", @"iPad14,6", @"MNXR3CH/A", @"CH/A", @"16.5", @"0x8121"},
    {@"iPad Pro 11 (4th)", @"iPad14,4",  @"MNXF3CH/A", @"CH/A", @"16.5", @"0x8121"},

    // iPad Air / mini
    {@"iPad Air (6th 13\")", @"iPad14,10",@"MUWE3CH/A", @"CH/A", @"17.5", @"0x8121"},
    {@"iPad Air (5th M1)", @"iPad13,17", @"MM9E3CH/A", @"CH/A", @"16.2", @"0x8110"},
    {@"iPad mini (6th)",   @"iPad14,2",  @"MK7R3CH/A", @"CH/A", @"16.0", @"0x8110"},
    {@"iPad (10th gen)",   @"iPad13,18", @"MPQ03CH/A", @"CH/A", @"16.1", @"0x8110"}
};

// Generate random code with given prefix and length
static inline NSString *GenRandomCode(NSString *prefix, int len) {
    NSString *chars = @"ABCDEFGHJKLMNPQRSTUVWXYZ0123456789";
    NSMutableString *res = [NSMutableString stringWithString:prefix];
    for (int i = 0; i < len; i++) {
        [res appendFormat:@"%C", [chars characterAtIndex:arc4random_uniform((uint32_t)chars.length)]];
    }
    return [res copy];
}

static inline NSDictionary *GenerateFullHardwareProfile(void) {
    size_t count = sizeof(kFullDevicePool) / sizeof(FullDeviceProfile);
    FullDeviceProfile dev = kFullDevicePool[arc4random_uniform((uint32_t)count)];

    // Full hardware 5-code self-consistent generation
    NSString *sn = GenRandomCode(@"F17", 9);
    NSString *mlb = GenRandomCode(@"FD18", 13);
    NSString *batterySN = GenRandomCode(@"F8Y", 14);
    NSString *lcmSN = GenRandomCode(@"C3F", 15);
    NSString *rearCam = GenRandomCode(@"DN8", 14);
    NSString *frontCam = GenRandomCode(@"F0W", 14);
    NSString *coverSN = GenRandomCode(@"G4L", 15);

    NSString *udid = [[NSUUID UUID].UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *idfa = [NSUUID UUID].UUIDString;
    NSString *idfv = [NSUUID UUID].UUIDString;

    // Generate consistent Wi-Fi/Bluetooth MAC (OUI prefix for Apple)
    uint8_t mac3 = arc4random_uniform(255);
    uint8_t mac4 = arc4random_uniform(255);
    uint8_t mac5 = arc4random_uniform(255);
    NSString *wifiMAC = [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, mac5];
    // Bluetooth MAC = Wi-Fi MAC + 1 (real Apple hardware behavior)
    NSString *btMAC = [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, (mac5 + 1) % 256];

    // DieID and ChipID
    NSString *dieID = [NSString stringWithFormat:@"0x%08X%08X", arc4random(), arc4random()];

    return @{
        @"enabled": @(YES),
        @"DisplayName": dev.displayName,
        @"hw.machine": dev.hwMachine,
        @"ModelNumber": dev.modelNumber,
        @"RegionCode": dev.regionCode,
        @"SystemVersion": dev.systemVersion,
        @"ChipID": dev.chipID,
        @"DieID": dieID,
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
