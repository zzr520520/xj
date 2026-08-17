#import "RootViewController.h"
#import "../src/WiperHelper.h"
#import "../src/DeviceModels.h"
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

@interface RootViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<LSApplicationProxy *> *userApps;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"应用抹机与机型伪装";
    self.userApps = [NSMutableArray array];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 65;
    [self.view addSubview:self.tableView];

    [self loadInstalledApps];
}

- (void)loadInstalledApps {
    [self.userApps removeAllObjects];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) {
        id workspace = [workspaceClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
        NSArray *apps = [workspace performSelector:NSSelectorFromString(@"allInstalledApplications")];
        for (LSApplicationProxy *app in apps) {
            if ([app.applicationType isEqualToString:@"User"]) {
                [self.userApps addObject:app];
            }
        }
    }
    [self.tableView reloadData];
}

#pragma mark - TableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.userApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"AppWiperCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    }

    LSApplicationProxy *app = self.userApps[indexPath.row];
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
    LSApplicationProxy *app = self.userApps[indexPath.row];
    [self showActionDialogForApp:app];
}

#pragma mark - Action Dialog

- (void)showActionDialogForApp:(LSApplicationProxy *)app {
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    BOOL isConfigured = [[NSFileManager defaultManager] fileExistsAtPath:configPath];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:app.localizedShortName
                                                                   message:app.bundleIdentifier
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 1. Random wipe + new identity (commercial-grade 5-code)
    [alert addAction:[UIAlertAction actionWithTitle:@"一键抹除 + 随机新机 (全硬件五码)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self executeWipeWithConfig:GenerateCommercialSeedProfile() forApp:app];
    }]];

    // 2. Manual model selection
    [alert addAction:[UIAlertAction actionWithTitle:@"自选特定 iPhone/iPad 机型抹除..." style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showModelPickerForApp:app];
    }]];

    // 3. View current config
    if (isConfigured) {
        [alert addAction:[UIAlertAction actionWithTitle:@"查看当前伪装参数" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self showCurrentConfigForApp:app];
        }]];

        // 4. Restore
        [alert addAction:[UIAlertAction actionWithTitle:@"还原真实设备环境" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[NSFileManager defaultManager] removeItemAtPath:configPath error:nil];
            [self.tableView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
            // Generate full hardware profile with Luhn-validated serials
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

            NSDictionary *config = @{
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
                @"UniqueDeviceID": [[NSUUID UUID].UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""],
                @"IDFA": [NSUUID UUID].UUIDString,
                @"IDFV": [NSUUID UUID].UUIDString,
                @"WifiAddress": [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, mac5],
                @"BluetoothAddress": [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, (mac5 + 1) % 256]
            };
            [self executeWipeWithConfig:config forApp:app];
        }]];
    }

    [picker addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:picker animated:YES completion:nil];
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
        @"【Wi-Fi MAC】: %@\n"
        @"【蓝牙 MAC】: %@\n"
        @"【系统版本】: iOS %@\n"
        @"【ChipID】: %@\n"
        @"【UDID】: %@\n"
        @"【IDFA】: %@",
        config[@"DisplayName"] ?: config[@"hw.machine"],
        config[@"hw.machine"],
        config[@"SerialNumber"],
        config[@"MLBSerialNumber"],
        config[@"BatterySerialNumber"],
        config[@"LCMSerialNumber"],
        config[@"FrontFacingCameraIdentifier"],
        config[@"RearFacingCameraIdentifier"],
        config[@"CoverGlassSerialNumber"],
        config[@"WifiAddress"],
        config[@"BluetoothAddress"],
        config[@"SystemVersion"],
        config[@"ChipID"],
        config[@"UniqueDeviceID"],
        config[@"IDFA"]];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"当前伪装参数"
                                                                   message:detail
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
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
                        @"\U00002714 TCC 隐私权限已全量重置\n\n"
                        @"【整机型号】: %@ (%@)\n"
                        @"【设备序列号】: %@\n"
                        @"【主板码/MLB】: %@\n"
                        @"【电池码/Battery】: %@\n"
                        @"【屏幕码/LCM】: %@\n"
                        @"【前/后摄码】: %@ / %@\n"
                        @"【Wi-Fi/蓝牙MAC】: %@\n"
                        @"【系统版本】: iOS %@\n\n"
                        @"\U00002714 硬件五码已完全自洽重置",
                        config[@"DisplayName"],
                        config[@"hw.machine"],
                        config[@"SerialNumber"],
                        config[@"MLBSerialNumber"],
                        config[@"BatterySerialNumber"],
                        config[@"LCMSerialNumber"],
                        config[@"FrontFacingCameraIdentifier"],
                        config[@"RearFacingCameraIdentifier"],
                        config[@"WifiAddress"],
                        config[@"SystemVersion"]];

                    UIAlertController *doneAlert = [UIAlertController alertControllerWithTitle:@"抹机完成"
                                                                                       message:detail
                                                                                preferredStyle:UIAlertControllerStyleAlert];
                    [doneAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                    [weakSelf presentViewController:doneAlert animated:YES completion:nil];
                }];
            });
        });
    }];
}

@end
