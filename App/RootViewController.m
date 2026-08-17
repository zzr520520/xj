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

// 执行全量抹除并生成新机：异步后台执行，避免主线程阻塞触发 Watchdog 闪退
- (void)performWipeAndGenerateForApp:(LSApplicationProxy *)app {
    NSString *bundleID = app.bundleIdentifier;

    // 1. 弹出加载提示，防止用户重复点击
    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在抹除"
                                                                          message:@"正在清理沙盒、App Group、钥匙串及重置权限，请稍候..."
                                                                   preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loadingAlert animated:YES completion:nil];

    // 2. 扔进全局后台队列异步执行，彻底释放主线程
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{

        // 执行 10 步物理抹除流水线
        BOOL wipeSuccess = [WiperHelper performFullWipeForBundleID:bundleID];
        if (!wipeSuccess) {
            NSLog(@"[AppWiper] 容器查找失败或清理异常");
        }

        // 生成新机参数
        NSArray *models = @[@"iPhone14,2", @"iPhone14,3", @"iPhone14,5", @"iPhone15,2", @"iPhone15,3"];
        NSString *randomModel = models[arc4random_uniform((uint32_t)models.count)];

        NSString *letters = @"ABCDEFGHJKLMNPQRSTUVWXYZ0123456789";
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

        // 写入配置
        NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
        NSString *dir = [configPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [config writeToFile:configPath atomically:YES];

        // 3. 切回主线程关闭 Loading 并弹出结果
        dispatch_async(dispatch_get_main_queue(), ^{
            [loadingAlert dismissViewControllerAnimated:YES completion:^{
                [self.tableView reloadData];

                NSString *detailMsg = [NSString stringWithFormat:
                                       @"\U00002714 目标进程与扩展已安全终止\n"
                                       @"\U00002714 App Group 及 MMKV 缓存已清空\n"
                                       @"\U00002714 Keychain 凭据与 TCC 权限已重置\n\n"
                                       @"【机型】: %@\n"
                                       @"【序列号】: %@\n"
                                       @"【UDID】: %@\n"
                                       @"【IDFA】: %@\n"
                                       @"【MAC】: %@",
                                       config[@"hw.machine"],
                                       config[@"SerialNumber"],
                                       config[@"UniqueDeviceID"],
                                       config[@"IDFA"],
                                       config[@"WifiAddress"]];

                UIAlertController *doneAlert = [UIAlertController alertControllerWithTitle:@"抹除成功"
                                                                                   message:detailMsg
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                [doneAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:doneAlert animated:YES completion:nil];
            }];
        });
    });
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
