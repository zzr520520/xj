#import "RootViewController.h"
#import "../src/WiperHelper.h"
#import "../src/DeviceModels.h"
#import "../src/WiperSnapshotManager.h"
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

        // 6. Restore
        [alert addAction:[UIAlertAction actionWithTitle:@"还原真实设备环境"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
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
        @"UniqueDeviceID": [[NSUUID UUID].UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""],
        @"IDFA": [NSUUID UUID].UUIDString,
        @"IDFV": [NSUUID UUID].UUIDString,
        @"WifiAddress": [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, mac5],
        @"BluetoothAddress": [NSString stringWithFormat:@"64:5A:ED:%02X:%02X:%02X", mac3, mac4, (mac5 + 1) % 256]
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
        config[@"ScreenWidth"],
        config[@"ScreenHeight"],
        config[@"ScreenScale"],
        [config[@"ScreenPPI"] intValue],
        config[@"WifiAddress"],
        config[@"BluetoothAddress"],
        config[@"SystemVersion"],
        config[@"ECID"] ?: @"N/A",
        config[@"UniqueDeviceID"],
        config[@"IDFA"]];

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
                        @"\U00002714 硬件五码已完全自洽重置",
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
