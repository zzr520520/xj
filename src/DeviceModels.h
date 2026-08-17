#import <Foundation/Foundation.h>

typedef struct {
    NSString *displayName;
    NSString *hwMachine;
    NSString *modelNumber;
    NSString *systemVersion;
} DeviceProfile;

static const DeviceProfile kSupportedDevices[] = {
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

    // iPad Pro 系列 (M1 / M2 / M4)
    {@"iPad Pro 13 (M4)",  @"iPad16,6",  @"MVX23CH/A", @"17.5"},
    {@"iPad Pro 11 (M4)",  @"iPad16,4",  @"MVDC3CH/A", @"17.5"},
    {@"iPad Pro 12.9 (6th)", @"iPad14,6", @"MNXR3CH/A", @"16.5"},
    {@"iPad Pro 11 (4th)", @"iPad14,4",  @"MNXF3CH/A", @"16.5"},
    {@"iPad Pro 12.9 (5th)", @"iPad13,10",@"MHNF3CH/A", @"15.6"},
    {@"iPad Pro 11 (3rd)", @"iPad13,6",  @"MHQU3CH/A", @"15.6"},

    // iPad Air / mini / 基础款
    {@"iPad Air (6th 13\")", @"iPad14,10",@"MUWE3CH/A", @"17.5"},
    {@"iPad Air (5th M1)", @"iPad13,17", @"MM9E3CH/A", @"16.2"},
    {@"iPad mini (6th)",   @"iPad14,2",  @"MK7R3CH/A", @"16.0"},
    {@"iPad (10th gen)",   @"iPad13,18", @"MPQ03CH/A", @"16.1"}
};

static inline NSDictionary *GenerateRandomProfile(void) {
    size_t count = sizeof(kSupportedDevices) / sizeof(DeviceProfile);
    DeviceProfile dev = kSupportedDevices[arc4random_uniform((uint32_t)count)];

    NSString *letters = @"ABCDEFGHJKLMNPQRSTUVWXYZ0123456789";
    NSMutableString *serial = [NSMutableString stringWithFormat:@"F17"];
    for (int i = 0; i < 9; i++) {
        [serial appendFormat:@"%C", [letters characterAtIndex:arc4random_uniform((uint32_t)[letters length])]];
    }

    NSString *udid = [[NSUUID UUID].UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *idfa = [NSUUID UUID].UUIDString;
    NSString *idfv = [NSUUID UUID].UUIDString;
    NSString *mac = [NSString stringWithFormat:@"02:00:00:%02X:%02X:%02X",
                     arc4random_uniform(255), arc4random_uniform(255), arc4random_uniform(255)];

    return @{
        @"enabled": @(YES),
        @"DisplayName": dev.displayName,
        @"hw.machine": dev.hwMachine,
        @"ModelNumber": dev.modelNumber,
        @"SystemVersion": dev.systemVersion,
        @"SerialNumber": [serial copy],
        @"UniqueDeviceID": udid,
        @"IDFA": idfa,
        @"IDFV": idfv,
        @"WifiAddress": mac
    };
}
