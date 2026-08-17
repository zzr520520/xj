#import "RootViewController.h"
#import "../src/WiperHelper.h"
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
    self.title = @"应用抹机与伪装管理器";
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
    cell.detailTextLabel.text = app.bundleIdentifier;
    
    // 加载 App 真实高清桌面图标
    UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:app.bundleIdentifier format:2 scale:[UIScreen mainScreen].scale];
    cell.imageView.image = icon ?: [UIImage systemImageNamed:@"app.fill"];
    cell.imageView.layer.cornerRadius = 10;
    cell.imageView.layer.masksToBounds = YES;
    
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    BOOL isConfigured = [[NSFileManager defaultManager] fileExistsAtPath:configPath];
    
    if (isConfigured) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
        cell.tintColor = [UIColor systemGreenColor];
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LSApplicationProxy *app = self.userApps[indexPath.row];
    [self showActionDialogForApp:app];
}

#pragma mark - 交互与操作弹窗

- (void)showActionDialogForApp:(LSApplicationProxy *)app {
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    BOOL isConfigured = [[NSFileManager defaultManager] fileExistsAtPath:configPath];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:app.localizedShortName
                                                                   message:app.bundleIdentifier
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 1. 一键抹除新机
    [alert addAction:[UIAlertAction actionWithTitle:@"一键抹除数据 + 生成新机" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self performWipeAndGenerateForApp:app];
    }]];

    // 2. 查看当前伪装参数
    if (isConfigured) {
        [alert addAction:[UIAlertAction actionWithTitle:@"查看当前伪装参数" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self showCurrentConfigForApp:app];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"还原真实环境 (取消伪装)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[NSFileManager defaultManager] removeItemAtPath:configPath error:nil];
            [self.tableView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 执行抹除并生成新数据：杀进程 -> 清沙盒 -> 删钥匙串 -> 清系统授权 -> 生成新指纹
- (void)performWipeAndGenerateForApp:(LSApplicationProxy *)app {
    NSString *bundleID = app.bundleIdentifier;

    // 1. 强制终止正在运行的 App 进程（防止内存写回）
    [WiperHelper killTargetApp:bundleID];

    // 2. 物理清除沙盒文件（含 App Group 共享容器）
    [WiperHelper cleanSandboxForBundleID:bundleID];

    // 3. 抹除钥匙串残留（keychain-2.db 级别删除）
    [WiperHelper cleanKeychainForBundleID:bundleID];

    // 4. 重置系统权限（相机、定位、相册等全部重置为未授权状态）
    [WiperHelper resetAllPermissionsForBundleID:bundleID];

    // 5. 生成高度拟真的全新硬件与系统指纹
    NSArray *models = @[@"iPhone14,2", @"iPhone14,3", @"iPhone14,5", @"iPhone15,2", @"iPhone15,3"];
    NSString *randomModel = models[arc4random_uniform((uint32_t)models.count)];

    NSString *letters = @"ABCDEFGHJKLMNPQRSTUVWXYZ";
    NSMutableString *randomSerial = [NSMutableString stringWithFormat:@"F17"];
    for (int i = 0; i < 9; i++) {
        [randomSerial appendFormat:@"%C", [letters characterAtIndex:arc4random_uniform((uint32_t)[letters length])]];
    }

    NSString *randomUDID = [[NSUUID UUID].UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *randomIDFA = [NSUUID UUID].UUIDString;
    NSString *randomIDFV = [NSUUID UUID].UUIDString;
    NSString *randomMAC = [NSString stringWithFormat:@"02:00:00:%02X:%02X:%02X",
                           arc4random_uniform(255), arc4random_uniform(255), arc4random_uniform(255)];

    NSDictionary *config = @{
        @"enabled": @(YES),
        @"hw.machine": randomModel,
        @"SerialNumber": [randomSerial copy],
        @"UniqueDeviceID": randomUDID,
        @"IDFA": randomIDFA,
        @"IDFV": randomIDFV,
        @"WifiAddress": randomMAC,
        @"SystemVersion": @"16.5"
    };

    // 6. 持久化新配置
    NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
    NSString *dir = [configPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [config writeToFile:configPath atomically:YES];

    [self.tableView reloadData];

    // 7. 弹窗呈现新机状态
    NSString *detailMsg = [NSString stringWithFormat:
                           @"\U00002714 目标进程已强制结束\n"
                           @"\U00002714 沙盒与钥匙串已彻底清空\n"
                           @"\U00002714 隐私权限(TCC)已全部重置\n\n"
                           @"【新机型】: %@\n"
                           @"【序列号】: %@\n"
                           @"【UDID】: %@\n"
                           @"【IDFA】: %@\n"
                           @"【MAC地址】: %@",
                           config[@"hw.machine"],
                           config[@"SerialNumber"],
                           config[@"UniqueDeviceID"],
                           config[@"IDFA"],
                           config[@"WifiAddress"]];

    UIAlertController *doneAlert = [UIAlertController alertControllerWithTitle:@"抹机完成（已全量重置）"
                                                                       message:detailMsg
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [doneAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:doneAlert animated:YES completion:nil];
}

- (void)showCurrentConfigForApp:(LSApplicationProxy *)app {
    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:configPath];
    if (!config) return;

    NSString *msg = [NSString stringWithFormat:
                     @"机型: %@\n序列号: %@\nUDID: %@\nIDFA: %@\nMAC: %@",
                     config[@"hw.machine"], config[@"SerialNumber"], config[@"UniqueDeviceID"], config[@"IDFA"], config[@"WifiAddress"]];

    UIAlertController *infoAlert = [UIAlertController alertControllerWithTitle:@"当前伪装信息"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [infoAlert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:infoAlert animated:YES completion:nil];
}

@end
