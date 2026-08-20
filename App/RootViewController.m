#import "RootViewController.h"
#import "../src/WiperHelper.h"
#import "../src/DeviceModels.h"
#import "../src/WiperSnapshotManager.h"
#import "../src/NetworkFaker.h"
#import <objc/runtime.h>

@interface UIImage (Private)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedShortName;
@property (nonatomic, readonly) NSString *applicationType;
@end

@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

@interface RootViewController () <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSMutableArray<LSApplicationProxy *> *allApps;
@property (nonatomic, strong) NSMutableArray<LSApplicationProxy *> *filteredApps;
@property (nonatomic, copy) NSString *searchText;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"应用抹机与机型伪装";
    self.allApps = [NSMutableArray array];
    self.filteredApps = [NSMutableArray array];

    [self setupUI];
    [self loadInstalledApps];
}

#pragma mark - UI Setup

- (void)setupUI {
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 65;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.placeholder = @"搜索应用名称或 Bundle ID...";
    self.searchBar.delegate = self;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.searchTextField.backgroundColor = [UIColor secondarySystemBackgroundColor];

    self.tableView.tableHeaderView = self.searchBar;
    [self.view addSubview:self.tableView];
}

#pragma mark - App Loading & Filtering

- (void)loadInstalledApps {
    [self.allApps removeAllObjects];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) {
        id workspace = [workspaceClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
        NSArray *apps = [workspace performSelector:NSSelectorFromString(@"allInstalledApplications")];
        for (LSApplicationProxy *app in apps) {
            if ([app.applicationType isEqualToString:@"User"]) {
                [self.allApps addObject:app];
            }
        }
    }
    [self applyFilter];
}

- (void)applyFilter {
    [self.filteredApps removeAllObjects];

    if (self.searchText.length == 0) {
        [self.filteredApps addObjectsFromArray:self.allApps];
    } else {
        NSString *lowerSearch = [self.searchText lowercaseString];
        for (LSApplicationProxy *app in self.allApps) {
            BOOL matchName = NO;
            if (app.localizedShortName) {
                matchName = [app.localizedShortName localizedCaseInsensitiveContainsString:self.searchText];
            }
            BOOL matchBundle = [app.bundleIdentifier.lowercaseString containsString:lowerSearch];
            if (matchName || matchBundle) {
                [self.filteredApps addObject:app];
            }
        }
    }
    [self.tableView reloadData];
}

#pragma mark - UISearchBar Delegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.searchText = searchText;
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    self.searchText = @"";
    [searchBar setText:@""];
    [searchBar resignFirstResponder];
    [self applyFilter];
}

#pragma mark - TableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"AppWiperCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    }

    LSApplicationProxy *app = self.filteredApps[indexPath.row];
    cell.textLabel.text = app.localizedShortName ?: @"未知应用";

    // Load app config to show current spoof status
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:configPath];

    if (config && [config[@"enabled"] boolValue]) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ | %@",
            app.bundleIdentifier, config[@"DisplayName"] ?: config[@"hw.machine"]];
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
        cell.tintColor = [UIColor systemGreenColor];
    } else {
        cell.detailTextLabel.text = app.bundleIdentifier;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:app.bundleIdentifier format:2 scale:[UIScreen mainScreen].scale];
    cell.imageView.image = icon ?: [UIImage systemImageNamed:@"app.fill"];
    cell.imageView.layer.cornerRadius = 10;
    cell.imageView.layer.masksToBounds = YES;

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LSApplicationProxy *app = self.filteredApps[indexPath.row];
    [self showActionDialogForApp:app];
}

#pragma mark - Action Dialog

- (void)showActionDialogForApp:(LSApplicationProxy *)app {
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    BOOL isConfigured = [[NSFileManager defaultManager] fileExistsAtPath:configPath];
    BOOL hasSnapshots = [WiperSnapshotManager savedSnapshotsForBundleID:app.bundleIdentifier].count > 0;
    NSDictionary *config = isConfigured ? [NSDictionary dictionaryWithContentsOfFile:configPath] : nil;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:app.localizedShortName
                                                                   message:app.bundleIdentifier
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 1. Random wipe + new identity (commercial-grade 5-code)
    [alert addAction:[UIAlertAction actionWithTitle:@"一键抹除 + 随机新机 (全硬件五码)"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self executeWipeWithConfig:GenerateCommercialSeedProfile() forApp:app];
    }]];

    // 2. Manual model selection
    [alert addAction:[UIAlertAction actionWithTitle:@"自选特定 iPhone 机型抹除..."
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self showModelPickerForApp:app];
    }]];

    // 3. View current config
    if (isConfigured) {
        [alert addAction:[UIAlertAction actionWithTitle:@"查看当前伪装参数"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showCurrentConfigForApp:app];
        }]];

        // 4. Save current config as snapshot
        [alert addAction:[UIAlertAction actionWithTitle:@"保存当前身份为快照..."
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showSaveSnapshotDialogForApp:app];
        }]];

        // 5. Snapshot management
        if (hasSnapshots) {
            [alert addAction:[UIAlertAction actionWithTitle:@"加载已保存的快照..."
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * _Nonnull action) {
                [self showSnapshotListForApp:app];
            }]];
        }

        // 6. Hook Mode selector
    int currentMode = 2;
    if (config[@"HookMode"]) currentMode = [config[@"HookMode"] intValue];
    NSString *modeLabel = currentMode == 0 ? @"诊断模式 (全部禁用)" : (currentMode == 1 ? @"保守模式 (仅核心)" : @"完整模式 (全部)");
    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Hook 模式: %@", modeLabel]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self showHookModePickerForApp:app];
    }]];

    // v2.04: 网络模式选择 (合并旧版飞行模式/无卡模拟开关)
    NSString *netMode = config[@"NetworkMode"] ?: @"未设置";
    NSString *netLabel = @"未设置";
    if ([netMode isEqualToString:@"wifi"]) netLabel = @"Wi-Fi";
    else if ([netMode isEqualToString:@"cellular"]) netLabel = @"蜂窝数据";
    else if ([netMode isEqualToString:@"flight"]) netLabel = @"飞行模式";
    else if ([netMode isEqualToString:@"nosim"]) netLabel = @"无卡";
    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"网络模式: %@", netLabel]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self showNetworkModePickerForApp:app];
    }]];

    // 7. Restore
        [alert addAction:[UIAlertAction actionWithTitle:@"还原真实设备环境"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            [[NSFileManager defaultManager] removeItemAtPath:configPath error:nil];
            [self.tableView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Hook Mode Picker

- (void)showHookModePickerForApp:(LSApplicationProxy *)app {
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    NSMutableDictionary *config = [[NSDictionary dictionaryWithContentsOfFile:configPath] mutableCopy] ?: [NSMutableDictionary dictionary];

    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"选择 Hook 模式"
                                                                     message:@"如果应用卡在启动页, 请依次尝试:\n1. 诊断模式 (确认是否插件导致)\n2. 保守模式 (仅核心伪装)\n3. 完整模式 (全部伪装)"
                                                              preferredStyle:UIAlertControllerStyleActionSheet];

    [picker addAction:[UIAlertAction actionWithTitle:@"诊断模式 (0 - 全部 Hook 禁用)"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction * _Nonnull action) {
        [self setHookMode:0 forApp:app config:config];
    }]];

    [picker addAction:[UIAlertAction actionWithTitle:@"保守模式 (1 - 仅 IOKit + sysctlbyname + 屏幕 + 磁盘)"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction * _Nonnull action) {
        [self setHookMode:1 forApp:app config:config];
    }]];

    [picker addAction:[UIAlertAction actionWithTitle:@"完整模式 (2 - 全部 13 类 Hook, 默认)"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction * _Nonnull action) {
        [self setHookMode:2 forApp:app config:config];
    }]];

    [picker addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)setHookMode:(int)mode forApp:(LSApplicationProxy *)app config:(NSMutableDictionary *)config {
    config[@"HookMode"] = @(mode);
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    NSString *dir = [configPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [config writeToFile:configPath atomically:YES];

    NSString *modeName = mode == 0 ? @"诊断模式" : (mode == 1 ? @"保守模式" : @"完整模式");
    NSString *hint = mode == 0 ? @"已禁用全部 Hook, 请重启目标应用测试\n如果仍卡死则问题不在插件" : 
                       mode == 1 ? @"仅保留核心伪装, 已跳过可能致卡死的 Hook\n请重启目标应用测试" :
                                   @"已启用全部 13 类 Hook\n请重启目标应用测试";

    UIAlertController *result = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Hook 模式已切换: %@", modeName]
                                                                     message:hint
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [result addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:result animated:YES completion:nil];
}

#pragma mark - Model Picker

- (void)showModelPickerForApp:(LSApplicationProxy *)app {
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"选择目标伪装机型"
                                                                    message:@"选择后将同步物理清空该应用数据并写入全硬件五码"
                                                             preferredStyle:UIAlertControllerStyleActionSheet];

    size_t count = sizeof(kFullDevicePool) / sizeof(FullDeviceProfile);
    for (size_t i = 0; i < count; i++) {
        FullDeviceProfile dev = kFullDevicePool[i];
        [picker addAction:[UIAlertAction actionWithTitle:dev.displayName style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSDictionary *config = [self buildConfigForDevice:dev];
            [self executeWipeWithConfig:config forApp:app];
        }]];
    }

    [picker addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:picker animated:YES completion:nil];
}

- (NSDictionary *)buildConfigForDevice:(FullDeviceProfile)dev {
    NSString *sn = GenValidSerialNumber();
    NSString *mlb = [NSString stringWithFormat:@"%@8XBX", sn];
    NSString *batterySN = GenValidSerialNumber();
    NSString *lcmSN = GenValidSerialNumber();
    NSString *rearCam = GenValidSerialNumber();
    NSString *frontCam = GenValidSerialNumber();
    NSString *coverSN = GenValidSerialNumber();

    uint8_t mac3 = arc4random_uniform(255);
    uint8_t mac4 = arc4random_uniform(255);
    uint8_t mac5 = arc4random_uniform(255);

    NSArray *diskOptions = @[@(256000000000ULL), @(512000000000ULL)];
    NSNumber *selectedDisk = diskOptions[arc4random_uniform((uint32_t)diskOptions.count)];

    // v2.04: 网络 + 电池字段
    NSArray *netModes = @[@"wifi", @"cellular", @"flight", @"nosim"];
    NSString *netMode = netModes[arc4random_uniform((uint32_t)netModes.count)];
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
    // v2.05: 广电 MNC 15 强制 5G
    NSString *radioTech;
    if ([carrier[@"mnc"] isEqualToString:@"15"]) {
        radioTech = @"CTRadioAccessTechnologyNR";
    } else {
        NSArray *radioTechs = @[@"CTRadioAccessTechnologyLTE", @"CTRadioAccessTechnologyNR"];
        radioTech = radioTechs[arc4random_uniform((uint32_t)radioTechs.count)];
    }
    // v2.05: 随机设备名称 + 动态 User-Agent
    NSArray *owners = @[@"我的", @"小明的", @"小红的", @"张三的", @"李四的", @"王五的", @"赵六的", @"陈七的"];
    NSString *deviceName = [NSString stringWithFormat:@"%@iPhone", owners[arc4random_uniform((uint32_t)owners.count)]];
    NSString *sysVerUA = [dev.systemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *userAgent = [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", sysVerUA];
    NSString *wifiSSID = [NSString stringWithFormat:@"WiFi-%04X", arc4random_uniform(0xFFFF)];
    NSString *wifiBSSID = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
                           arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256),
                           arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];
    NSInteger batteryHealth = 80 + arc4random_uniform(20);
    NSInteger batteryCycle = 100 + arc4random_uniform(400);
    BOOL isCharging = arc4random_uniform(2) == 1;
    NSInteger batteryTemp = 200 + arc4random_uniform(150);
    NSInteger batteryCapacity = 20 + arc4random_uniform(80);
    NSInteger designCap = 3500;
    NSInteger maxCap = (NSInteger)((double)designCap * batteryHealth / 100.0);
    NSInteger currentMAh = (NSInteger)((double)maxCap * batteryCapacity / 100.0);
    int cityIdx = arc4random_uniform(sizeof(kCityCoords) / sizeof(kCityCoords[0]));

    // v2.06: 物理内存精准映射
    uint64_t ramSize = 6442450944ULL;
    if ([dev.hwMachine hasPrefix:@"iPhone18"] ||
        [dev.hwMachine hasPrefix:@"iPhone17"] ||
        [dev.hwMachine hasPrefix:@"iPhone16,1"] ||
        [dev.hwMachine hasPrefix:@"iPhone16,2"]) {
        ramSize = 8589934592ULL;
    } else if ([dev.hwMachine hasPrefix:@"iPhone12"] || [dev.hwMachine isEqualToString:@"iPhone14,6"]) {
        ramSize = 4294967296ULL;
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
    // v2.06: 开机时间偏移
    NSTimeInterval bootOffset = 7200 + arc4random_uniform(250000);
    time_t fakeBootSec = time(NULL) - (time_t)bootOffset;
    // v2.06: ICCID
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
        @"TotalDiskSize": selectedDisk,
        @"SerialNumber": sn,
        @"MLBSerialNumber": mlb,
        @"BatterySerialNumber": batterySN,
        @"LCMSerialNumber": lcmSN,
        @"RearFacingCameraIdentifier": rearCam,
        @"FrontFacingCameraIdentifier": frontCam,
        @"CoverGlassSerialNumber": coverSN,
        @"ECID": GenerateRandomECID(),
        @"UniqueDeviceID": [[NSUUID UUID].UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""],
        @"IDFA": [NSUUID UUID].UUIDString,
        @"IDFV": [NSUUID UUID].UUIDString,
        @"WifiAddress": [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, mac5],
        @"BluetoothAddress": [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, (mac5 + 1) % 256],
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
        @"DeviceName": deviceName,           // v2.05: 设备名称
        @"UserAgent": userAgent,             // v2.05: HTTP User-Agent
        @"BatteryHealth": @(batteryHealth),
        @"BatteryCycleCount": @(batteryCycle),
        @"IsCharging": @(isCharging),
        @"BatteryTemperature": @(batteryTemp),
        @"BatteryCurrentCapacity": @(batteryCapacity),
        @"BatteryDesignCapacity": @(designCap),
        @"BatteryMaxCapacity": @(maxCap),
        @"BatteryCurrentMAh": @(currentMAh),
        @"PhysMemory": @(ramSize),
        @"MaxRefreshRate": @(maxRefreshRate),
        @"GPUFamilyName": gpuName,
        @"BootTimeSec": @(fakeBootSec),
        @"ICCID": [rawIccid copy]
    };
}

#pragma mark - View Current Config

- (void)showCurrentConfigForApp:(LSApplicationProxy *)app {
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:configPath];

    NSString *detail = [NSString stringWithFormat:
        @"【整机型号】: %@ (%@)\n"
        @"【设备序列号】: %@\n"
        @"【主板码/MLB】: %@\n"
        @"【电池码】: %@\n"
        @"【屏幕码/LCM】: %@\n"
        @"【前/后摄码】: %@ / %@\n"
        @"【盖板码】: %@\n"
        @"【屏幕分辨率】: %@x%@ @%@x (%d PPI)\n"
        @"【Wi-Fi MAC】: %@\n"
        @"【蓝牙 MAC】: %@\n"
        @"【系统版本】: iOS %@\n"
        @"【ECID】: %@\n"
        @"【UDID】: %@\n"
        @"【IDFA】: %@\n"
        @"【设备名称】: %@\n"
        @"【User-Agent】: %@\n\n"
        @"--- v2.03 网络伪装 ---\n"
        @"【网络模式】: %@\n"
        @"【运营商】: %@ (MCC:%@ MNC:%@)\n"
        @"【网络类型】: %@\n"
        @"【WiFi SSID】: %@\n"
        @"【WiFi BSSID】: %@\n\n"
        @"--- v2.04 电池状态 ---\n"
        @"【电池健康】: %@%%\n"
        @"【循环次数】: %@\n"
        @"【充电状态】: %@\n"
        @"【电池温度】: %@.%@°C\n"
        @"【当前电量】: %@%%\n"
        @"【设计容量】: %@ mAh\n"
        @"【最大容量】: %@ mAh",
        config[@"DisplayName"] ?: config[@"hw.machine"],
        config[@"hw.machine"],
        config[@"SerialNumber"],
        config[@"MLBSerialNumber"],
        config[@"BatterySerialNumber"],
        config[@"LCMSerialNumber"],
        config[@"FrontFacingCameraIdentifier"],
        config[@"RearFacingCameraIdentifier"],
        config[@"CoverGlassSerialNumber"],
        config[@"ScreenWidth"],
        config[@"ScreenHeight"],
        config[@"ScreenScale"],
        [config[@"ScreenPPI"] intValue],
        config[@"WifiAddress"],
        config[@"BluetoothAddress"],
        config[@"SystemVersion"],
        config[@"ECID"] ?: @"N/A",
        config[@"UniqueDeviceID"],
        config[@"IDFA"],
        config[@"DeviceName"] ?: @"N/A",
        config[@"UserAgent"] ?: @"N/A",
        config[@"NetworkMode"] ?: @"未设置",
        config[@"CarrierName"] ?: @"N/A",
        config[@"CarrierMCC"] ?: @"N/A",
        config[@"CarrierMNC"] ?: @"N/A",
        config[@"RadioAccessTechnology"] ?: @"N/A",
        config[@"WifiSSID"] ?: @"N/A",
        config[@"WifiBSSID"] ?: @"N/A",
        config[@"BatteryHealth"] ?: @"?",
        config[@"BatteryCycleCount"] ?: @"?",
        [config[@"IsCharging"] boolValue] ? @"充电中" : @"未充电",
        @([config[@"BatteryTemperature"] integerValue] / 10),
        @([config[@"BatteryTemperature"] integerValue] % 10),
        config[@"BatteryCurrentCapacity"] ?: @"?",
        config[@"BatteryDesignCapacity"] ?: @"N/A",
        config[@"BatteryMaxCapacity"] ?: @"N/A"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"当前伪装参数"
                                                                   message:detail
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Snapshot Management

- (void)showSaveSnapshotDialogForApp:(LSApplicationProxy *)app {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存快照"
                                                                    message:@"输入快照名称"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"例如: 抖音-iPhone15Pro";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0) return;

        BOOL success = [WiperSnapshotManager saveCurrentConfigAsSnapshot:name forBundleID:app.bundleIdentifier];
        UIAlertController *result = [UIAlertController alertControllerWithTitle:success ? @"已保存" : @"保存失败"
                                                                          message:success ? [NSString stringWithFormat:@"快照 \"%@\" 已保存", name] : nil
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [result addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:result animated:YES completion:nil];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSnapshotListForApp:(LSApplicationProxy *)app {
    NSArray<NSString *> *snapshots = [WiperSnapshotManager savedSnapshotsForBundleID:app.bundleIdentifier];
    if (snapshots.count == 0) {
        UIAlertController *empty = [UIAlertController alertControllerWithTitle:@"无快照"
                                                                         message:nil
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:empty animated:YES completion:nil];
        return;
    }

    UIAlertController *list = [UIAlertController alertControllerWithTitle:@"选择快照加载"
                                                                     message:app.bundleIdentifier
                                                              preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *snapshotName in snapshots) {
        [list addAction:[UIAlertAction actionWithTitle:snapshotName style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self showSnapshotActionsForApp:app snapshotName:snapshotName];
        }]];
    }

    [list addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:list animated:YES completion:nil];
}

- (void)showSnapshotActionsForApp:(LSApplicationProxy *)app snapshotName:(NSString *)snapshotName {
    NSDictionary *snapshot = [WiperSnapshotManager loadSnapshot:snapshotName forBundleID:app.bundleIdentifier];
    NSString *summary = [NSString stringWithFormat:@"%@ (%@)\nSN: %@",
        snapshot[@"DisplayName"] ?: snapshot[@"hw.machine"],
        snapshot[@"hw.machine"],
        snapshot[@"SerialNumber"]];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:snapshotName
                                                                     message:summary
                                                              preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"加载此快照 (覆盖当前配置)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        BOOL success = [WiperSnapshotManager applySnapshot:snapshotName forBundleID:app.bundleIdentifier];
        [self.tableView reloadData];
        UIAlertController *result = [UIAlertController alertControllerWithTitle:success ? @"快照已加载" : @"加载失败"
                                                                          message:nil
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [result addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:result animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"删除此快照" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [WiperSnapshotManager deleteSnapshot:snapshotName forBundleID:app.bundleIdentifier];
        [self.tableView reloadData];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Execute Wipe with Config

- (void)executeWipeWithConfig:(NSDictionary *)config forApp:(LSApplicationProxy *)app {
    NSString *bundleID = app.bundleIdentifier;

    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在深度抹除"
                                                                          message:@"正在清空沙盒、MMKV缓存、钥匙串并重置权限..."
                                                                   preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [self presentViewController:loadingAlert animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{

            [WiperHelper performFullWipeForBundleID:bundleID];

            NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
            NSString *dir = [configPath stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [config writeToFile:configPath atomically:YES];

            dispatch_async(dispatch_get_main_queue(), ^{
                [loadingAlert dismissViewControllerAnimated:YES completion:^{
                    [weakSelf.tableView reloadData];

                    NSString *detail = [NSString stringWithFormat:
                        @"\U00002714 进程与扩展已安全终止\n"
                        @"\U00002714 沙盒/MMKV/Keychain 已彻底清空\n"
                        @"\U00002714 TCC 隐私权限已全量重置\n"
                        @"\U00002714 inode 已扰动、快照已清理\n\n"
                        @"【整机型号】: %@ (%@)\n"
                        @"【设备序列号】: %@\n"
                        @"【主板码/MLB】: %@\n"
                        @"【电池码/Battery】: %@\n"
                        @"【屏幕码/LCM】: %@\n"
                        @"【前/后摄码】: %@ / %@\n"
                        @"【屏幕】: %@x%@ @%@x\n"
                        @"【Wi-Fi/蓝牙MAC】: %@\n"
                        @"【系统版本】: iOS %@\n\n"
                        @"--- 网络: %@ | %@ | %@%% ---\n"
                        @"--- 电池: %@%% | 循环%@ | %@ ---\n\n"
                        @"\U00002714 硬件五码 + 网络伪装 + 电池状态已自洽",
                        config[@"DisplayName"],
                        config[@"hw.machine"],
                        config[@"SerialNumber"],
                        config[@"MLBSerialNumber"],
                        config[@"BatterySerialNumber"],
                        config[@"LCMSerialNumber"],
                        config[@"FrontFacingCameraIdentifier"],
                        config[@"RearFacingCameraIdentifier"],
                        config[@"ScreenWidth"],
                        config[@"ScreenHeight"],
                        config[@"ScreenScale"],
                        config[@"WifiAddress"],
                        config[@"SystemVersion"],
                        config[@"NetworkMode"] ?: @"N/A",
                        config[@"CarrierName"] ?: @"N/A",
                        config[@"BatteryCurrentCapacity"] ?: @"?",
                        config[@"BatteryHealth"] ?: @"?",
                        config[@"BatteryCycleCount"] ?: @"?",
                        [config[@"IsCharging"] boolValue] ? @"充电中" : @"未充电"];

                    NSString *fullDetail = [NSString stringWithFormat:
                        @"%@\n\n"
                        @"\U0001F4CC 请按以下顺序操作：\n\n"
                        @"1\U0000FE0F 手动卸载目标 App（如果还安装着）\n"
                        @"2\U0000FE0F \u23F0 等待 30 秒后再重新安装\n"
                        @"3\U0000FE0F 从 App Store 全新下载安装\n"
                        @"4\U0000FE0F 使用全新账号登录\n\n"
                        @"\U0001F4A1 提示：重启手机效果更佳（但会掉越狱，需重新越狱）",
                        detail];

                    UIAlertController *doneAlert = [UIAlertController alertControllerWithTitle:@"\u2705 抹机完成"
                                                                                         message:fullDetail
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                    [doneAlert addAction:[UIAlertAction actionWithTitle:@"我知道了" style:UIAlertActionStyleDefault handler:nil]];
                    [weakSelf presentViewController:doneAlert animated:YES completion:nil];
                }];
            });
        });
    }];
}

#pragma mark - Network Mode Picker (v2.04)

- (void)showNetworkModePickerForApp:(LSApplicationProxy *)app {
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    NSDictionary *existingConfig = [NSDictionary dictionaryWithContentsOfFile:configPath];
    NSString *currentMode = existingConfig[@"NetworkMode"] ?: @"未设置";

    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"选择网络模式"
                                                                     message:[NSString stringWithFormat:@"当前: %@\n切换后将立即生效", currentMode]
                                                              preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *modes = @[@"wifi", @"cellular", @"flight", @"nosim"];
    NSArray *labels = @[@"Wi-Fi 模式", @"蜂窝数据模式", @"飞行模式", @"无卡模式"];

    for (int i = 0; i < (int)modes.count; i++) {
        NSString *mode = modes[i];
        NSString *label = labels[i];
        NSString *title = [mode isEqualToString:currentMode] ? [NSString stringWithFormat:@"%@ ✓", label] : label;
        [picker addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setNetworkMode:mode forApp:app];
        }]];
    }

    [picker addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)setNetworkMode:(NSString *)mode forApp:(LSApplicationProxy *)app {
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    NSMutableDictionary *config = [[NSDictionary dictionaryWithContentsOfFile:configPath] mutableCopy] ?: [NSMutableDictionary dictionary];
    config[@"NetworkMode"] = mode;
    config[@"enabled"] = @(YES);

    // v2.04: 自动同步 FlightMode/NoSIM 标志位 (Hooks.m 旧逻辑向后兼容)
    if ([mode isEqualToString:@"flight"]) {
        config[@"FlightMode"] = @(YES);
        config[@"NoSIM"] = @(YES);
    } else if ([mode isEqualToString:@"nosim"]) {
        config[@"FlightMode"] = @(NO);
        config[@"NoSIM"] = @(YES);
    } else {
        config[@"FlightMode"] = @(NO);
        config[@"NoSIM"] = @(NO);
    }

    // 根据模式重新生成对应的网络参数
    if ([mode isEqualToString:@"wifi"]) {
        config[@"WifiSSID"] = [NSString stringWithFormat:@"WiFi-%04X", arc4random_uniform(0xFFFF)];
        config[@"WifiBSSID"] = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
                                arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256),
                                arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];
    } else if ([mode isEqualToString:@"cellular"] || [mode isEqualToString:@"nosim"]) {
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
        config[@"CarrierName"] = carrier[@"name"];
        config[@"CarrierMCC"] = carrier[@"mcc"];
        config[@"CarrierMNC"] = carrier[@"mnc"];
        config[@"RadioAccessTechnology"] = (arc4random_uniform(2) == 0) ? @"CTRadioAccessTechnologyLTE" : @"CTRadioAccessTechnologyNR";
    }

    NSString *dir = [configPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [config writeToFile:configPath atomically:YES];

    // 立即应用网络伪装
    @try {
        [NetworkFaker applyNetworkConfig:config];
    } @catch (NSException *e) {
        NSLog(@"[RootVC] NetworkFaker apply error: %@", e.reason);
    }

    [self.tableView reloadData];

    NSString *modeLabel = [mode isEqualToString:@"wifi"] ? @"Wi-Fi" :
                          [mode isEqualToString:@"cellular"] ? @"蜂窝数据" :
                          [mode isEqualToString:@"flight"] ? @"飞行模式" : @"无卡";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"网络模式已切换: %@", modeLabel]
                                                                   message:@"已立即生效, 请重启目标应用确认"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
