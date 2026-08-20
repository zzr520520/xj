#import "WiperHelper.h"
#import <sqlite3.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <unistd.h>
#import <syslog.h>
#import <fcntl.h>
#import <stdlib.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// ============================================================
// Helper: posix_spawn shell (兼容 /var/jb 半越狱)
// ============================================================
static void runShellCommand(const char *cmd) {
    if (!cmd || strlen(cmd) == 0) return;
    pid_t pid;
    const char *argv[] = {"sh", "-c", cmd, NULL};

    // 优先使用 Dopamine /var/jb 路径，兼容半越狱
    const char *shellPaths[] = {"/var/jb/usr/bin/sh", "/bin/sh", NULL};
    for (int i = 0; shellPaths[i] != NULL; i++) {
        if (access(shellPaths[i], X_OK) == 0) {
            if (posix_spawn(&pid, shellPaths[i], NULL, NULL, (char *const *)argv, NULL) == 0) {
                int status;
                waitpid(pid, &status, 0);
            }
            return;
        }
    }
}

static void killProcessByName(const char *name) {
    if (!name || strlen(name) == 0) return;
    const char *paths[] = {"/var/jb/usr/bin/killall", "/usr/bin/killall", NULL};
    for (int i = 0; paths[i] != NULL; i++) {
        if (access(paths[i], X_OK) == 0) {
            pid_t pid;
            const char *argv[] = {"killall", "-9", name, NULL};
            int ret = posix_spawn(&pid, paths[i], NULL, NULL, (char *const *)argv, NULL);
            if (ret == 0) {
                int status;
                waitpid(pid, &status, 0);
            }
            return;
        }
    }
}

__attribute__((unused))
static BOOL executeSQLiteOnDB(NSString *dbPath, void(^workBlock)(sqlite3 *db)) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) return NO;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2([dbPath UTF8String], &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return NO;
    }
    sqlite3_busy_timeout(db, 3000);
    @try {
        workBlock(db);
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
    } @catch (NSException *exception) {
        syslog(LOG_ERR, "[WiperHelper] SQLite Error: %s", [exception.reason UTF8String]);
    } @finally {
        sqlite3_close(db);
    }
    return YES;
}

// Private API
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@property (nonatomic, readonly) NSDictionary *groupContainerURLs;
@property (nonatomic, readonly) NSString *applicationType;
@end
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

// v2.07: 内部方法前向声明 (class extension)
@interface WiperHelper ()
+ (void)secureDeleteItemAtPath:(NSString *)path;
+ (void)fullCleanKeychainForBundleID:(NSString *)bundleID;
+ (void)cleanAllAppGroupsForBundleID:(NSString *)bundleID;
+ (void)cleanTCCDatabaseForBundleID:(NSString *)bundleID;
+ (void)cleanBiomeAndCoreDuetForBundleID:(NSString *)bundleID;
+ (void)refreshAPNsToken;
+ (void)killAllProcessesForProxy:(id)proxy bundleID:(NSString *)bundleID;
+ (void)deepCleanSandboxForProxy:(id)proxy;
+ (void)cleanAppPreferencesAndWebKitForBundleID:(NSString *)bundleID;
+ (void)cleanSnapshotsForBundleID:(NSString *)bundleID;
+ (void)cleanPasteboard;
+ (void)cleanKeyboardCache;
+ (void)cleanLocationCacheForBundleID:(NSString *)bundleID;
+ (void)cleanAppStoreCacheForBundleID:(NSString *)bundleID;
+ (void)changeSystemFileMetadata;
+ (void)aggressiveCleanUserDefaultsForBundleID:(NSString *)bundleID;  // v2.08
+ (void)enableWriteProtectionForBundleID:(NSString *)bundleID;         // v2.08
+ (void)wipeEntireKeychainForCurrentApp;                                 // v2.09: SSKeychain式全量擦除
@end

@implementation WiperHelper

+ (NSString *)getConfigPathForBundleID:(NSString *)bundleID {
    NSString *baseDir = @"/var/jb/var/mobile/Library/Preferences/MyAppWiper/configs";
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        baseDir = @"/var/mobile/Library/Preferences/MyAppWiper/configs";
    }
    return [baseDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
}

#pragma mark - DoD 5220.22-M 7-pass secure delete (with symlink protection)
+ (void)secureDeleteItemAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;

    // 处理符号链接：不删除链接目标，只删除链接本身
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (attrs && [attrs fileType] == NSFileTypeSymbolicLink) {
        [fm removeItemAtPath:path error:nil];
        return;
    }

    // 删除 SQLite WAL 文件
    NSString *walPath = [path stringByAppendingString:@"-wal"];
    NSString *shmPath = [path stringByAppendingString:@"-shm"];
    if ([fm fileExistsAtPath:walPath]) [fm removeItemAtPath:walPath error:nil];
    if ([fm fileExistsAtPath:shmPath]) [fm removeItemAtPath:shmPath error:nil];

    BOOL isDir = NO;
    [fm fileExistsAtPath:path isDirectory:&isDir];
    if (isDir) {
        NSArray *contents = [fm contentsOfDirectoryAtPath:path error:nil];
        for (NSString *subItem in contents) {
            [self secureDeleteItemAtPath:[path stringByAppendingPathComponent:subItem]];
        }
        [fm removeItemAtPath:path error:nil];
    } else {
        unsigned long long fileSize = [attrs fileSize];
        if (fileSize > 0 && fileSize < 100 * 1024 * 1024) {
            int fd = open([path UTF8String], O_WRONLY);
            if (fd != -1) {
                char *buf = malloc((size_t)fileSize);
                if (buf) {
                    for (int pass = 0; pass < 7; pass++) {
                        lseek(fd, 0, SEEK_SET);
                        if (pass == 0) memset(buf, 0x00, (size_t)fileSize);
                        else if (pass == 1) memset(buf, 0xFF, (size_t)fileSize);
                        else if (pass == 6) memset(buf, 0x00, (size_t)fileSize);
                        else arc4random_buf(buf, (size_t)fileSize);
                        write(fd, buf, (size_t)fileSize);
                        fsync(fd);
                    }
                    free(buf);
                }
                close(fd);
            }
        }
        [fm removeItemAtPath:path error:nil];
    }
}

#pragma mark - 1. 🔑 钥匙串全属性 + 共享组全量穿透清理（修复误删其他App）
+ (void)fullCleanKeychainForBundleID:(NSString *)bundleID {
    syslog(LOG_NOTICE, "[Keychain] Starting full clean for %s", [bundleID UTF8String]);

    NSArray *secClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity
    ];

    // 构建关键词：优先精确匹配 bundleID，厂商关键词仅做辅助兜底
    NSMutableSet *primaryKeywords = [NSMutableSet setWithObject:bundleID];
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    if (parts.count > 1) {
        [primaryKeywords addObject:parts[1]];  // 厂商名
    }

    // 辅助兜底关键词（仅当 accessGroup 完全无法匹配时使用）
    NSArray *fallbackPatterns = @[@"meituan", @"sankuai", @"xingin", @"pinduoduo", @"yangkeduo", @"vipshop", @"tencent", @"alibaba", @"taobao"];
    NSMutableSet *fallbackKeywords = [NSMutableSet set];
    for (NSString *pattern in fallbackPatterns) {
        if ([bundleID containsString:pattern]) {
            [fallbackKeywords addObject:pattern];
        }
    }

    for (id secClass in secClasses) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecReturnRef: @NO,
            (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
        };

        CFArrayRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
        if (status != errSecSuccess || !result) continue;

        NSArray *items = (__bridge_transfer NSArray *)result;
        for (NSDictionary *item in items) {
            NSString *service = item[(__bridge id)kSecAttrService];
            NSString *accessGroup = item[(__bridge id)kSecAttrAccessGroup];
            NSString *account = item[(__bridge id)kSecAttrAccount];

            BOOL shouldDelete = NO;

            // 【策略1】优先：accessGroup 精确匹配 bundleID
            if (accessGroup && [accessGroup containsString:bundleID]) {
                shouldDelete = YES;
            }

            // 【策略2】次优：service 或 account 精确匹配 bundleID
            if (!shouldDelete && ((service && [service containsString:bundleID]) ||
                                  (account && [account containsString:bundleID]))) {
                shouldDelete = YES;
            }

            // 【策略3】兜底：accessGroup 匹配厂商关键词（仅当 bundleID 包含该厂商名）
            if (!shouldDelete && accessGroup) {
                for (NSString *kw in fallbackKeywords) {
                    if ([accessGroup containsString:kw]) {
                        shouldDelete = YES;
                        break;
                    }
                }
            }

            if (shouldDelete) {
                NSMutableDictionary *delQuery = [NSMutableDictionary dictionary];
                delQuery[(__bridge id)kSecClass] = secClass;
                delQuery[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
                if (service) delQuery[(__bridge id)kSecAttrService] = service;
                if (accessGroup) delQuery[(__bridge id)kSecAttrAccessGroup] = accessGroup;
                if (account) delQuery[(__bridge id)kSecAttrAccount] = account;
                SecItemDelete((__bridge CFDictionaryRef)delQuery);
                syslog(LOG_NOTICE, "[Keychain] Deleted: service=%s, group=%s",
                       [service UTF8String] ?: "", [accessGroup UTF8String] ?: "");
            }
        }
    }

    runShellCommand("killall -9 securityd 2>/dev/null || true");
    syslog(LOG_NOTICE, "[Keychain] Full clean completed for %s", [bundleID UTF8String]);
}

#pragma mark - 1.5. 🔑 SSKeychain 式全量通用密码擦除 (v2.09: 无关键词过滤)
// 对标「新设备插件」: 不依赖 bundleID 匹配, 直接按 SecClass 全量删除
// 解决: App 使用加密 service 字符串时外部正则匹配漏删的问题
+ (void)wipeEntireKeychainForCurrentApp {
    syslog(LOG_NOTICE, "[Keychain] Wipe-entire START (SSKeychain-style)");

    NSArray *secClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity
    ];

    for (id secClass in secClasses) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
        syslog(LOG_NOTICE, "[Keychain] Wipe class=%s status=%d",
               [(__bridge NSString *)secClass UTF8String], status);
    }

    runShellCommand("killall -9 securityd 2>/dev/null || true");
    syslog(LOG_NOTICE, "[Keychain] Wipe-entire COMPLETE");
}

#pragma mark - 2. 📁 共享 App-Group / SystemGroup 递归全量清理
+ (void)cleanAllAppGroupsForBundleID:(NSString *)bundleID {
    syslog(LOG_NOTICE, "[AppGroup] Starting clean for %s", [bundleID UTF8String]);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet *groupPaths = [NSMutableSet set];

    NSArray *roots = @[
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/containers/Shared/SystemGroup"
    ];

    NSArray *vendorPatterns = @[@"meituan", @"sankuai", @"xingin", @"pinduoduo", @"yangkeduo", @"vipshop", @"tencent", @"alibaba"];

    for (NSString *root in roots) {
        if (![fm fileExistsAtPath:root]) continue;
        NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *uuid in uuids) {
            NSString *metaPath = [root stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", uuid]];
            if (![fm fileExistsAtPath:metaPath]) continue;

            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
            NSString *identifier = meta[@"MCMMetadataIdentifier"];
            if (!identifier) continue;

            BOOL match = [identifier containsString:bundleID];
            if (!match) {
                NSArray *parts = [bundleID componentsSeparatedByString:@"."];
                if (parts.count > 1 && [identifier containsString:parts[1]]) {
                    match = YES;
                }
                for (NSString *pattern in vendorPatterns) {
                    if ([bundleID containsString:pattern] && [identifier containsString:pattern]) {
                        match = YES;
                        break;
                    }
                }
            }
            if (match) {
                [groupPaths addObject:[root stringByAppendingPathComponent:uuid]];
            }
        }
    }

    for (NSString *path in groupPaths) {
        syslog(LOG_NOTICE, "[AppGroup] Deleting: %s", [path UTF8String]);
        [self secureDeleteItemAtPath:path];
    }
}

#pragma mark - 3. 🗄️ TCC 参数绑定删除 + VACUUM（修复SQL注入）
+ (void)cleanTCCDatabaseForBundleID:(NSString *)bundleID {
    syslog(LOG_NOTICE, "[TCC] Starting clean for %s", [bundleID UTF8String]);
    runShellCommand("killall -9 tccd 2>/dev/null || true");
    usleep(200000);

    NSArray *dbPaths = @[
        @"/var/mobile/Library/TCC/TCC.db",
        @"/var/jb/var/mobile/Library/TCC/TCC.db"
    ];

    for (NSString *dbPath in dbPaths) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) continue;

        sqlite3 *db = NULL;
        if (sqlite3_open_v2([dbPath UTF8String], &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
            if (db) sqlite3_close(db);
            continue;
        }

        sqlite3_exec(db, "BEGIN TRANSACTION;", NULL, NULL, NULL);

        // ✅ 使用参数绑定，防止 SQL 注入
        sqlite3_stmt *stmt;
        const char *sql = "DELETE FROM access WHERE client LIKE ?;";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            NSString *pattern = [NSString stringWithFormat:@"%%%@%%", bundleID];
            sqlite3_bind_text(stmt, 1, [pattern UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }

        sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
        sqlite3_exec(db, "VACUUM;", NULL, NULL, NULL);
        sqlite3_close(db);

        [[NSFileManager defaultManager] removeItemAtPath:[dbPath stringByAppendingString:@"-wal"] error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[dbPath stringByAppendingString:@"-shm"] error:nil];
    }

    runShellCommand("launchctl kickstart -k system/com.apple.tccd 2>/dev/null || true");
    syslog(LOG_NOTICE, "[TCC] Clean completed for %s", [bundleID UTF8String]);
}

#pragma mark - 4. 🧹 Biome / CoreDuet 行为缓存清理（含边界注释）
// ⚠️ 重要限制：用户 mobile 权限只能删除用户层缓存。
// 系统域 Biome 流记录（如系统级 App 启动日志）无法删除，此为 Dopamine 半越狱固有限制。
+ (void)cleanBiomeAndCoreDuetForBundleID:(NSString *)bundleID {
    syslog(LOG_NOTICE, "[Biome] Starting clean (user-level only) for %s", [bundleID UTF8String]);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *baseDirs = @[
        @"/var/mobile/Library/Biome",
        @"/var/mobile/Library/CoreDuet",
        @"/private/var/mobile/Library/Biome"
    ];
    int deletedCount = 0;
    for (NSString *base in baseDirs) {
        if (![fm fileExistsAtPath:base]) continue;
        NSArray *subs = [fm contentsOfDirectoryAtPath:base error:nil];
        for (NSString *sub in subs) {
            if ([sub containsString:bundleID] || [sub hasPrefix:bundleID]) {
                NSString *target = [base stringByAppendingPathComponent:sub];
                [self secureDeleteItemAtPath:target];
                deletedCount++;
                syslog(LOG_NOTICE, "[Biome] Deleted: %s", [target UTF8String]);
            }
        }
    }
    syslog(LOG_NOTICE, "[Biome] Clean completed: %d user-level items deleted (system-level Biome cannot be cleared)", deletedCount);
}

#pragma mark - 5. 📡 APNs 守护进程重置（后台30秒等待，不阻塞UI）
// ⚠️ 重要：系统生成全新 APNs token 需要 15-30 秒。
// 此方法在后台线程等待 30 秒，不阻塞主线程和抹机流程返回。
+ (void)refreshAPNsToken {
    syslog(LOG_NOTICE, "[APNs] Killing apnsd/apsd");
    runShellCommand("killall -9 apnsd apsd 2>/dev/null || true");

    // 在后台线程等待 30 秒，让系统重新生成 APNs token
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        syslog(LOG_NOTICE, "[APNs] Waiting 30 seconds for token regeneration...");
        sleep(30);
        syslog(LOG_NOTICE, "[APNs] Token regeneration wait complete.");
    });
}

#pragma mark - 6. 📦 原有方法（保持不变）
+ (void)killAllProcessesForProxy:(id)proxy bundleID:(NSString *)bundleID {
    @try {
        NSURL *bundleURL = [proxy valueForKey:@"bundleURL"];
        if (bundleURL) {
            NSString *infoPlistPath = [bundleURL.path stringByAppendingPathComponent:@"Info.plist"];
            NSString *mainExec = [[NSDictionary dictionaryWithContentsOfFile:infoPlistPath] objectForKey:@"CFBundleExecutable"];
            if (!mainExec) mainExec = bundleURL.lastPathComponent.stringByDeletingPathExtension;
            if (mainExec.length > 0) killProcessByName([mainExec UTF8String]);
        }
        if ([proxy respondsToSelector:@selector(plugInKitPlugins)]) {
            NSArray *plugins = [proxy performSelector:@selector(plugInKitPlugins)];
            for (id plugin in plugins) {
                NSString *extBundleID = [plugin valueForKey:@"bundleIdentifier"];
                if (extBundleID) {
                    NSString *extExec = [extBundleID componentsSeparatedByString:@"."].lastObject;
                    if (extExec.length > 0) killProcessByName([extExec UTF8String]);
                }
            }
        }
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[WiperHelper] killAllProcesses: %s", [e.reason UTF8String]);
    }
}

+ (void)deepCleanSandboxForProxy:(id)proxy {
    NSURL *dataURL = [proxy valueForKey:@"dataContainerURL"];
    if (!dataURL || !dataURL.path) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *subDirs = @[@"Documents", @"Library/Caches", @"Library/Application Support", @"Library/Preferences", @"tmp", @"Library/SyncedPreferences"];
    for (NSString *sub in subDirs) {
        NSString *targetPath = [dataURL.path stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:targetPath]) continue;
        NSArray *contents = [fm contentsOfDirectoryAtPath:targetPath error:nil];
        for (NSString *item in contents) {
            [self secureDeleteItemAtPath:[targetPath stringByAppendingPathComponent:item]];
        }
    }
}

+ (void)cleanAppPreferencesAndWebKitForBundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *prefDirs = @[@"/var/mobile/Library/Preferences", @"/var/jb/var/mobile/Library/Preferences"];
    for (NSString *dir in prefDirs) {
        NSString *prefFile = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
        if ([fm fileExistsAtPath:prefFile]) [self secureDeleteItemAtPath:prefFile];
    }
    NSArray *webDirs = @[@"/var/mobile/Library/WebKit", @"/var/jb/var/mobile/Library/WebKit"];
    for (NSString *dir in webDirs) {
        NSString *webFolder = [dir stringByAppendingPathComponent:bundleID];
        if ([fm fileExistsAtPath:webFolder]) [self secureDeleteItemAtPath:webFolder];
    }
    runShellCommand("killall cfprefsd 2>/dev/null || true");
}

+ (void)cleanSnapshotsForBundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *snapDirs = @[@"/var/mobile/Library/Caches/Snapshots", @"/var/jb/var/mobile/Library/Caches/Snapshots"];
    for (NSString *dir in snapDirs) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *item in items) {
            if ([item containsString:bundleID]) {
                [self secureDeleteItemAtPath:[dir stringByAppendingPathComponent:item]];
            }
        }
    }
}

+ (void)cleanPasteboard {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [[UIPasteboard generalPasteboard] setItems:@[]]; } @catch (NSException *e) {}
    });
}

+ (void)cleanKeyboardCache {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *keyboardPath = @"/var/mobile/Library/Keyboard/dynamic-text.dat";
    if ([fm fileExistsAtPath:keyboardPath]) [self secureDeleteItemAtPath:keyboardPath];
    NSString *learnPath = @"/var/mobile/Library/Keyboard";
    if ([fm fileExistsAtPath:learnPath]) {
        NSArray *items = [fm contentsOfDirectoryAtPath:learnPath error:nil];
        for (NSString *item in items) {
            if ([item hasSuffix:@".dat"] || [item hasSuffix:@".plist"]) {
                [self secureDeleteItemAtPath:[learnPath stringByAppendingPathComponent:item]];
            }
        }
    }
}

+ (void)cleanLocationCacheForBundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *locPaths = @[@"/var/mobile/Library/Caches/locationd", @"/var/jb/var/mobile/Library/Caches/locationd"];
    for (NSString *dir in locPaths) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *item in items) {
            if (![[item pathExtension] isEqualToString:@"plist"]) {
                [self secureDeleteItemAtPath:[dir stringByAppendingPathComponent:item]];
            }
        }
    }
    runShellCommand("killall locationd 2>/dev/null || true");
}

+ (void)cleanAppStoreCacheForBundleID:(NSString *)bundleID {
    runShellCommand("killall installd 2>/dev/null || true");
    runShellCommand("killall appstored 2>/dev/null || true");
}

+ (void)changeSystemFileMetadata {
    runShellCommand("touch -t 202401010000 /var/mobile/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true");
    runShellCommand("chown 501:501 /var/mobile/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true");
}

#pragma mark - 8. 🧹 NSUserDefaults 整个域激进清除 (v2.08: 对标新设备插件)
+ (void)aggressiveCleanUserDefaultsForBundleID:(NSString *)bundleID {
    @try {
        // 1. 删除标准UserDefaults中所有匹配的键
        NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];
        NSDictionary *allKeys = [standardDefaults dictionaryRepresentation];
        for (NSString *key in allKeys.allKeys) {
            if ([key containsString:bundleID] || [key hasPrefix:bundleID]) {
                [standardDefaults removeObjectForKey:key];
            }
        }
        [standardDefaults synchronize];

        // 2. 使用套件名称删除整个域
        NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:bundleID];
        if (suiteDefaults) {
            [suiteDefaults removePersistentDomainForName:bundleID];
            [suiteDefaults synchronize];
        }

        // 3. 删除所有第三方SDK常见的存储键（大厂App常用）
        NSArray *commonKeys = @[
            @"com.tencent.oauth", @"com.alibaba.oauth",
            @"com.bytedance.oauth", @"com.meituan.token",
            @"com.pinduoduo.session", @"com.xingin.user",
            @"com.sankuai.auth", @"com.vipshop.login"
        ];
        for (NSString *key in commonKeys) {
            [standardDefaults removeObjectForKey:key];
        }
        [standardDefaults synchronize];

        // 4. 刷新cfprefsd，使内存中的缓存失效
        runShellCommand("killall cfprefsd 2>/dev/null || true");

        syslog(LOG_NOTICE, "[UserDefaults] Aggressive cleanup completed for %s", [bundleID UTF8String]);
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[UserDefaults] Error: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 9. 🔒 清理后写保护 (v2.08: 阻止App重启后重写凭证 5秒)
+ (void)enableWriteProtectionForBundleID:(NSString *)bundleID {
    // 创建写保护标志文件 (Hooks.m 的 wp_setObject:forKey: 会检查此文件)
    NSString *configDir = [[self getConfigPathForBundleID:bundleID] stringByDeletingLastPathComponent];
    NSString *flagPath = [configDir stringByAppendingPathComponent:@".writeprotection"];
    [@"YES" writeToFile:flagPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    syslog(LOG_NOTICE, "[WriteProtection] Enabled for %s (5s)", [bundleID UTF8String]);

    // 5秒后自动解除保护
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[NSFileManager defaultManager] removeItemAtPath:flagPath error:nil];
        syslog(LOG_NOTICE, "[WriteProtection] Disabled for %s", [bundleID UTF8String]);
    });
}

#pragma mark - 7. 🚀 核心抹除流水线 (v2.08: 双保险pkill + 激进UserDefaults + 写保护)
+ (BOOL)performFullWipeForBundleID:(NSString *)bundleID {
    @try {
        syslog(LOG_NOTICE, "[WiperHelper] === Full wipe START for %s ===", [bundleID UTF8String]);

        Class LSApplicationProxyClass = NSClassFromString(@"LSApplicationProxy");
        id proxy = nil;
        BOOL appStillInstalled = NO;
        if (LSApplicationProxyClass) {
            proxy = [LSApplicationProxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleID];
            if (proxy) appStillInstalled = YES;
        }

        // ⚠️ 警告：如果 App 尚未卸载，运行时可能重新写入指纹
        if (appStillInstalled) {
            syslog(LOG_WARNING, "[WiperHelper] ⚠️ App %s is still installed! Fingerprints may be rewritten.", [bundleID UTF8String]);
        }

        // 第1步：彻底杀死所有相关进程（双保险 pkill）
        syslog(LOG_NOTICE, "[WiperHelper] Step 1: Double pkill");
        runShellCommand([[NSString stringWithFormat:@"pkill -9 -f %@", bundleID] UTF8String]);
        usleep(500000);
        runShellCommand([[NSString stringWithFormat:@"pkill -9 -f %@", bundleID] UTF8String]);
        usleep(500000);
        if (proxy) [self killAllProcessesForProxy:proxy bundleID:bundleID];

        // 第2步：清除 NSUserDefaults 整个域（对标新设备插件）
        syslog(LOG_NOTICE, "[WiperHelper] Step 2: Aggressive UserDefaults");
        [self aggressiveCleanUserDefaultsForBundleID:bundleID];

        // 第3步：Keychain 深度清除 (选择性匹配删除)
        syslog(LOG_NOTICE, "[WiperHelper] Step 3: Keychain (selective)");
        [self fullCleanKeychainForBundleID:bundleID];

        // 第3.5步：Keychain 全量擦除 (v2.09: SSKeychain式, 无关键词过滤, 对标新设备插件)
        syslog(LOG_NOTICE, "[WiperHelper] Step 3.5: Keychain (wipe-entire)");
        [self wipeEntireKeychainForCurrentApp];

        // 第4步：App-Group 共享容器
        syslog(LOG_NOTICE, "[WiperHelper] Step 4: App-Group");
        [self cleanAllAppGroupsForBundleID:bundleID];

        // 第5步：主沙盒清理
        syslog(LOG_NOTICE, "[WiperHelper] Step 5: Sandbox");
        if (proxy) {
            [self deepCleanSandboxForProxy:proxy];
        }

        // 第6步：TCC + VACUUM
        syslog(LOG_NOTICE, "[WiperHelper] Step 6: TCC");
        [self cleanTCCDatabaseForBundleID:bundleID];

        // 第7步：Biome / CoreDuet 用户层
        syslog(LOG_NOTICE, "[WiperHelper] Step 7: Biome");
        [self cleanBiomeAndCoreDuetForBundleID:bundleID];

        // 第8步：偏好设置、剪贴板、快照
        syslog(LOG_NOTICE, "[WiperHelper] Step 8: Preferences + Snapshots");
        [self cleanAppPreferencesAndWebKitForBundleID:bundleID];
        [self cleanSnapshotsForBundleID:bundleID];
        [self cleanPasteboard];
        [self cleanKeyboardCache];
        [self cleanLocationCacheForBundleID:bundleID];
        [self cleanAppStoreCacheForBundleID:bundleID];
        [self changeSystemFileMetadata];

        // 第9步：APNs 刷新（后台30秒等待，不阻塞）
        syslog(LOG_NOTICE, "[WiperHelper] Step 9: APNs");
        [self refreshAPNsToken];

        // 第10步：强制 sync，确保所有写入落盘
        sync();
        usleep(500000);

        // 第11步：启用写保护（阻止App在重启后立刻恢复凭证，5秒）
        syslog(LOG_NOTICE, "[WiperHelper] Step 11: Write protection");
        [self enableWriteProtectionForBundleID:bundleID];

        // 第12步：再次确保进程已死（清理完成后再次 pkill）
        usleep(1000000);
        runShellCommand([[NSString stringWithFormat:@"pkill -9 -f %@", bundleID] UTF8String]);

        if (appStillInstalled) {
            syslog(LOG_WARNING, "[WiperHelper] ⚠️ App still installed after wipe. Recommend uninstalling and rebooting.");
        }

        syslog(LOG_NOTICE, "[WiperHelper] === Full wipe COMPLETE for %s ===", [bundleID UTF8String]);
        return YES;
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[WiperHelper] Full wipe error: %s", [e.reason UTF8String]);
        return NO;
    }
}

@end
