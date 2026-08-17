#import "RootViewController.h"
#import "../src/WiperHelper.h"

// 声明私有 API 用于获取已安装 App 列表
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
    self.title = @"应用抹机与伪装";
    self.userApps = [NSMutableArray array];

    // 初始化列表
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
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
            // 过滤系统内置 App，仅保留第三方用户应用
            if ([app.applicationType isEqualToString:@"User"]) {
                [self.userApps addObject:app];
            }
        }
    }
    [self.tableView reloadData];
}

#pragma mark - TableView Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.userApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"AppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    }

    LSApplicationProxy *app = self.userApps[indexPath.row];
    cell.textLabel.text = app.localizedShortName ?: @"未知应用";
    cell.detailTextLabel.text = app.bundleIdentifier;

    NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
    BOOL isConfigured = [[NSFileManager defaultManager] fileExistsAtPath:configPath];
    cell.accessoryType = isConfigured ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LSApplicationProxy *app = self.userApps[indexPath.row];
    [self showActionDialogForApp:app];
}

#pragma mark - 交互逻辑

- (void)showActionDialogForApp:(LSApplicationProxy * _Nonnull)app {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:app.localizedShortName
                                                                   message:app.bundleIdentifier
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 1. 生成并应用全新机型伪装
    [alert addAction:[UIAlertAction actionWithTitle:@"一键新机 + 重置沙盒" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self generateConfigForBundleID:app.bundleIdentifier wipeNow:YES];
        [self.tableView reloadData];
    }]];

    // 2. 清除配置恢复真实设备
    [alert addAction:[UIAlertAction actionWithTitle:@"还原真实设备环境" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *configPath = [WiperHelper getConfigPathForBundleID:app.bundleIdentifier];
        [[NSFileManager defaultManager] removeItemAtPath:configPath error:nil];
        [self.tableView reloadData];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)generateConfigForBundleID:(NSString *)bundleID wipeNow:(BOOL)wipe {
    NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
    NSString *dir = [configPath stringByDeletingLastPathComponent];

    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    // 随机生成假硬件指纹
    NSString *randomSerial = [NSString stringWithFormat:@"F17%05d%04d", arc4random_uniform(99999), arc4random_uniform(9999)];
    NSString *randomUDID = [[NSUUID UUID].UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""];

    NSDictionary *config = @{
        @"enabled": @(YES),
        @"needs_wipe": @(wipe),
        @"hw.machine": @"iPhone15,2",
        @"SerialNumber": randomSerial,
        @"UniqueDeviceID": randomUDID,
        @"ModelNumber": @"MQ023CH/A"
    };

    [config writeToFile:configPath atomically:YES];
}

@end
