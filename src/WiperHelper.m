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
// Helper: posix_spawn shell (system() NOT available on iOS)
// ============================================================
static void runShellCommand(const char *cmd) {
    if (!cmd || strlen(cmd) == 0) return;
    pid_t pid;
    const char *argv[] = {"sh", "-c", cmd, NULL};
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

// ============================================================
// Private API declarations
// ============================================================
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

@implementation WiperHelper

+ (NSString *)getConfigPathForBundleID:(NSString *)bundleID {
    NSString *baseDir = @"/var/jb/var/mobile/Library/Preferences/MyAppWiper/configs";
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        baseDir = @"/var/mobile/Library/Preferences/MyAppWiper/configs";
    }
    return [baseDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
}

#pragma mark - DoD 5220.22-M 7-pass secure delete + inode disturbance

+ (void)secureDeleteItemAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;

    BOOL isDir = NO;
    [fm fileExistsAtPath:path isDirectory:&isDir];

    if (isDir) {
        NSError *error = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:path error:&error];
        for (NSString *subItem in contents) {
            [self secureDeleteItemAtPath:[path stringByAppendingPathComponent:subItem]];
        }
        [fm removeItemAtPath:path error:nil];
    } else {
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        unsigned long long fileSize = [attrs fileSize];

        if (fileSize > 0 && fileSize < 100 * 1024 * 1024) {
            NSString *parentDir = [path stringByDeletingLastPathComponent];
            NSString *tempName = [NSString stringWithFormat:@".wipe_%u", arc4random()];
            NSString *tempPath = [parentDir stringByAppendingPathComponent:tempName];

            if (rename([path UTF8String], [tempPath UTF8String]) == 0) {
                path = tempPath;
            }

            int fd = open([path UTF8String], O_WRONLY);
            if (fd != -1) {
                char *buf = malloc((size_t)fileSize);
                if (buf) {
                    for (int pass = 0; pass < 7; pass++) {
                        lseek(fd, 0, SEEK_SET);
                        if (pass == 0)      memset(buf, 0x00, (size_t)fileSize);
                        else if (pass == 1)  memset(buf, 0xFF, (size_t)fileSize);
                        else if (pass == 6)  memset(buf, 0x00, (size_t)fileSize);
                        else                 arc4random_buf(buf, (size_t)fileSize);
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

#pragma mark - 1. Kill main process + extensions + Notification daemon

+ (void)killAllProcessesForProxy:(id)proxy bundleID:(NSString *)bundleID {
    @try {
        NSURL *bundleURL = [proxy valueForKey:@"bundleURL"];
        if (bundleURL) {
            NSString *infoPlistPath = [bundleURL.path stringByAppendingPathComponent:@"Info.plist"];
            NSString *mainExec = [[NSDictionary dictionaryWithContentsOfFile:infoPlistPath] objectForKey:@"CFBundleExecutable"];
            if (!mainExec) mainExec = bundleURL.lastPathComponent.stringByDeletingPathExtension;
            if (mainExec.length > 0) killProcessByName([mainExec UTF8String]);
        }

        // Kill PlugInKit extensions
        if ([proxy respondsToSelector:@selector(plugInKitPlugins)]) {
            NSArray *plugins = [proxy performSelector:@selector(plugInKitPlugins)];
            for (id plugin in plugins) {
                NSString *extBundleID = nil;
                if ([plugin respondsToSelector:@selector(bundleIdentifier)]) {
                    extBundleID = [plugin performSelector:@selector(bundleIdentifier)];
                }
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

#pragma mark - 2. Deep sandbox subdirectory recursive wipe (expanded)

+ (void)deepCleanSandboxForProxy:(id)proxy {
    NSURL *dataURL = [proxy valueForKey:@"dataContainerURL"];
    if (!dataURL || !dataURL.path) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    // Expanded: includes StoreKit, Cookies, HTTPStorages, BackwardsCompliance
    NSArray *subDirs = @[
        @"Documents",
        @"Documents/Inbox",
        @"Library",
        @"Library/Caches",
        @"Library/Caches/Snapshots",
        @"Library/Application Support",
        @"Library/Application Support/SceneStorage",
        @"Library/Preferences",
        @"Library/Preferences/" ,
        @"Library/SyncedPreferences",
        @"Library/Cookies",
        @"Library/HTTPStorages",
        @"Library/WebClips",
        @"Library/SplashBoard",
        @"tmp",
        @"StoreKit"
    ];

    for (NSString *sub in subDirs) {
        NSString *targetPath = [dataURL.path stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:targetPath]) continue;

        NSError *error = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:targetPath error:&error];
        for (NSString *item in contents) {
            [self secureDeleteItemAtPath:[targetPath stringByAppendingPathComponent:item]];
        }
    }

    // Also wipe the entire data container root (catch-all)
    NSError *error = nil;
    NSArray *rootContents = [fm contentsOfDirectoryAtPath:dataURL.path error:&error];
    for (NSString *item in rootContents) {
        [self secureDeleteItemAtPath:[dataURL.path stringByAppendingPathComponent:item]];
    }
}

#pragma mark - 3. App Group + System Group deep cleanup (expanded)

+ (void)cleanAppGroupsForProxy:(id)proxy bundleID:(NSString *)bundleID {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableSet<NSString *> *groupPaths = [NSMutableSet set];

        // App's own group containers
        if ([proxy respondsToSelector:@selector(groupContainerURLs)]) {
            NSDictionary *dict = [proxy performSelector:@selector(groupContainerURLs)];
            for (id value in dict.allValues) {
                if ([value isKindOfClass:[NSURL class]]) [groupPaths addObject:[value path]];
                else if ([value isKindOfClass:[NSString class]]) [groupPaths addObject:value];
            }
        }

        NSArray *parts = [bundleID componentsSeparatedByString:@"."];
        NSString *vendorKey = parts.count > 1 ? parts[1] : bundleID;

        // Scan shared AppGroup containers (user apps)
        NSString *sharedGroupRoot = @"/var/mobile/Containers/Shared/AppGroup";
        if ([fm fileExistsAtPath:sharedGroupRoot]) {
            NSArray *groups = [fm contentsOfDirectoryAtPath:sharedGroupRoot error:nil];
            for (NSString *uuid in groups) {
                NSString *metaPath = [sharedGroupRoot stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", uuid]];
                if ([fm fileExistsAtPath:metaPath]) {
                    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
                    NSString *identifier = meta[@"MCMMetadataIdentifier"];
                    if (identifier) {
                        BOOL match = [identifier containsString:bundleID] || [identifier containsString:vendorKey];
                        if (!match) {
                            // Cross-app vendor pattern matching
                            NSArray *vendorPatterns = @[@"meituan", @"sankuai", @"dianping",
                                                       @"xingin", @"xunmeng", @"pinduoduo",
                                                       @"tencent", @"qq", @"wechat", @"weixin",
                                                       @"alibaba", @"taobao", @"amap",
                                                       @"baidu", @"bytedance", @"douyin", @"tiktok"];
                            for (NSString *pattern in vendorPatterns) {
                                if ([bundleID containsString:pattern] && [identifier containsString:pattern]) {
                                    match = YES;
                                    break;
                                }
                            }
                        }
                        if (match) [groupPaths addObject:[sharedGroupRoot stringByAppendingPathComponent:uuid]];
                    }
                }
            }
        }

        // Scan System Group containers (system-level shared data)
        NSString *systemGroupRoot = @"/private/var/containers/Shared/SystemGroup";
        if ([fm fileExistsAtPath:systemGroupRoot]) {
            NSArray *sysGroups = [fm contentsOfDirectoryAtPath:systemGroupRoot error:nil];
            for (NSString *uuid in sysGroups) {
                NSString *metaPath = [systemGroupRoot stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", uuid]];
                if ([fm fileExistsAtPath:metaPath]) {
                    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
                    NSString *identifier = meta[@"MCMMetadataIdentifier"];
                    if (identifier && ([identifier containsString:bundleID] || [identifier containsString:vendorKey])) {
                        [groupPaths addObject:[systemGroupRoot stringByAppendingPathComponent:uuid]];
                    }
                }
            }
        }

        for (NSString *groupPath in groupPaths) {
            syslog(LOG_NOTICE, "[WiperHelper] Secure deleting group: %s", [groupPath UTF8String]);
            [self secureDeleteItemAtPath:groupPath];
        }
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[WiperHelper] cleanAppGroups: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 4. Extension sandbox cleanup

+ (void)cleanExtensionsForProxy:(id)proxy {
    @try {
        Class LSApplicationProxyClass = NSClassFromString(@"LSApplicationProxy");
        if (!LSApplicationProxyClass) return;

        if ([proxy respondsToSelector:@selector(plugInKitPlugins)]) {
            NSArray *plugins = [proxy performSelector:@selector(plugInKitPlugins)];
            for (id plugin in plugins) {
                NSString *extBundleID = nil;
                if ([plugin respondsToSelector:@selector(bundleIdentifier)]) {
                    extBundleID = [plugin performSelector:@selector(bundleIdentifier)];
                }
                if (extBundleID) {
                    id extProxy = [LSApplicationProxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:extBundleID];
                    if (extProxy) {
                        NSURL *extDataURL = [extProxy valueForKey:@"dataContainerURL"];
                        if (extDataURL && extDataURL.path) {
                            [self secureDeleteItemAtPath:extDataURL.path];
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[WiperHelper] cleanExtensions: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 5. Enhanced Keychain wipe — SQL + API + access group

+ (void)enhancedCleanKeychainForBundleID:(NSString *)bundleID {
    NSArray *keychainPaths = @[
        @"/var/Keychains/keychain-2.db",
        @"/private/var/Keychains/keychain-2.db"
    ];

    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    NSString *vendorKey = parts.count > 1 ? parts[1] : bundleID;

    // Database-level: parameterized queries
    for (NSString *dbPath in keychainPaths) {
        executeSQLiteOnDB(dbPath, ^(sqlite3 *db) {
            NSArray *tables = @[@"genp", @"inet", @"cert", @"keys", @"identities"];
            for (NSString *table in tables) {
                sqlite3_stmt *stmt;
                NSString *sql = [NSString stringWithFormat:
                    @"DELETE FROM %@ WHERE agrp LIKE ? OR agrp LIKE ? OR svce LIKE ? OR svce LIKE ? OR desc LIKE ?",
                    table];
                if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
                    NSString *p1 = [NSString stringWithFormat:@"%%%@%%", bundleID];
                    NSString *p2 = [NSString stringWithFormat:@"%%%@%%", vendorKey];
                    sqlite3_bind_text(stmt, 1, [p1 UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 2, [p2 UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 3, [p1 UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 4, [p2 UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 5, [p2 UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_step(stmt);
                    sqlite3_finalize(stmt);
                }
            }
        });
    }

    // API-level: all keychain classes
    NSArray *secClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassIdentity
    ];

    for (id secClass in secClasses) {
        NSDictionary *allQuery = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnAttributes: @YES,
        };
        CFArrayRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)allQuery, (CFTypeRef *)&result);
        if (status == errSecSuccess && result) {
            NSArray *items = (__bridge_transfer NSArray *)result;
            for (NSDictionary *item in items) {
                NSString *service = item[(__bridge id)kSecAttrService];
                NSString *accessGroup = item[(__bridge id)kSecAttrAccessGroup];
                NSString *account = item[(__bridge id)kSecAttrAccount];

                BOOL match = (service && ([service containsString:bundleID] || [service containsString:vendorKey])) ||
                             (accessGroup && ([accessGroup containsString:bundleID] || [accessGroup containsString:vendorKey])) ||
                             (account && ([account containsString:bundleID] || [account containsString:vendorKey]));

                if (match) {
                    NSMutableDictionary *delQuery = [NSMutableDictionary dictionary];
                    delQuery[(__bridge id)kSecClass] = secClass;
                    if (service) delQuery[(__bridge id)kSecAttrService] = service;
                    if (accessGroup) delQuery[(__bridge id)kSecAttrAccessGroup] = accessGroup;
                    SecItemDelete((__bridge CFDictionaryRef)delQuery);
                }
            }
        }
    }

    // Flush securityd
    runShellCommand("killall securityd 2>/dev/null || true");
}

#pragma mark - 6. TCC permission reset + daemon refresh

+ (void)cleanTCCDatabaseForBundleID:(NSString *)bundleID {
    NSArray *tccPaths = @[
        @"/var/mobile/Library/TCC/TCC.db",
        @"/var/jb/var/mobile/Library/TCC/TCC.db"
    ];

    for (NSString *dbPath in tccPaths) {
        executeSQLiteOnDB(dbPath, ^(sqlite3 *db) {
            sqlite3_stmt *stmt;
            const char *sql = "DELETE FROM access WHERE client LIKE ?";
            if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
                NSString *pattern = [NSString stringWithFormat:@"%%%@%%", bundleID];
                sqlite3_bind_text(stmt, 1, [pattern UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }
        });
    }

    runShellCommand("launchctl kickstart -k system/com.apple.tccd 2>/dev/null || killall tccd 2>/dev/null || true");
}

#pragma mark - 7. Preferences + WebKit + cfprefsd flush

+ (void)cleanAppPreferencesAndWebKitForBundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Delete preference plist files (both rootless and rootful paths)
    NSArray *prefDirs = @[@"/var/mobile/Library/Preferences", @"/var/jb/var/mobile/Library/Preferences"];
    for (NSString *dir in prefDirs) {
        // Exact match
        NSString *prefFile = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
        if ([fm fileExistsAtPath:prefFile]) [self secureDeleteItemAtPath:prefFile];

        // Fuzzy: any plist containing the bundle ID
        NSArray *allPrefs = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *pf in allPrefs) {
            if ([pf hasSuffix:@".plist"] && ([pf containsString:bundleID] || [pf hasPrefix:[bundleID componentsSeparatedByString:@"."][0]])) {
                NSString *fullPath = [dir stringByAppendingPathComponent:pf];
                if (![fullPath isEqualToString:prefFile]) [self secureDeleteItemAtPath:fullPath];
            }
        }
    }

    // Flush cfprefsd daemon (preferences cache)
    runShellCommand("killall cfprefsd 2>/dev/null || true");

    // WebKit data
    NSArray *webDirs = @[@"/var/mobile/Library/WebKit", @"/var/jb/var/mobile/Library/WebKit"];
    for (NSString *dir in webDirs) {
        NSString *webFolder = [dir stringByAppendingPathComponent:bundleID];
        if ([fm fileExistsAtPath:webFolder]) [self secureDeleteItemAtPath:webFolder];
    }

    // NetworkExtension preferences
    NSString *nePrefs = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/com.apple.networkextension.%@.plist", bundleID];
    if ([fm fileExistsAtPath:nePrefs]) [self secureDeleteItemAtPath:nePrefs];
}

#pragma mark - 8. Snapshots + SplashBoard

+ (void)cleanSnapshotsForBundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *snapDirs = @[
        @"/var/mobile/Library/Caches/Snapshots",
        @"/var/jb/var/mobile/Library/Caches/Snapshots",
        @"/var/mobile/Containers/Data/Application",
        @"/var/jb/var/mobile/Containers/Data/Application"
    ];

    for (NSString *dir in snapDirs) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *item in items) {
            if ([item containsString:bundleID]) {
                [self secureDeleteItemAtPath:[dir stringByAppendingPathComponent:item]];
            }
        }
    }

    // SplashBoard (app launch screen cache)
    NSString *splashDir = @"/var/mobile/Library/SplashBoard";
    if ([fm fileExistsAtPath:splashDir]) {
        NSArray *items = [fm contentsOfDirectoryAtPath:splashDir error:nil];
        for (NSString *item in items) {
            if ([item containsString:bundleID]) {
                [self secureDeleteItemAtPath:[splashDir stringByAppendingPathComponent:item]];
            }
        }
    }
}

#pragma mark - 9. NSUbiquitousKeyValueStore (iCloud KVS) wipe

+ (void)cleanICloudKVSForBundleID:(NSString *)bundleID {
    @try {
        // Clear all keys from iCloud KVS for this app
        // This must run in the target app's process context
        NSUbiquitousKeyValueStore *store = [NSUbiquitousKeyValueStore defaultStore];
        NSDictionary *allKeys = [store dictionaryRepresentation];
        for (NSString *key in allKeys.allKeys) {
            [store removeObjectForKey:key];
        }
        [store synchronize];
        syslog(LOG_NOTICE, "[WiperHelper] iCloud KVS: cleared %lu keys", (unsigned long)allKeys.count);
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[WiperHelper] iCloud KVS error: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 10. CoreDuet / KnowledgeC database wipe

+ (void)cleanCoreDuetForBundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];

    // CoreDuet Knowledge database (iOS 15 and earlier)
    NSArray *coreDuetPaths = @[
        @"/var/mobile/Library/CoreDuet/Knowledge/knowledgeC.db",
        @"/private/var/mobile/Library/CoreDuet/Knowledge/knowledgeC.db"
    ];

    NSString *pattern = [NSString stringWithFormat:@"%%%@%%", bundleID];
    const char *patt = [pattern UTF8String];

    for (NSString *dbPath in coreDuetPaths) {
        executeSQLiteOnDB(dbPath, ^(sqlite3 *db) {
            sqlite3_stmt *stmt;
            const char *sql1 = "DELETE FROM ZOBJECT WHERE ZSTRUCTUREDDATA LIKE ?;";
            if (sqlite3_prepare_v2(db, sql1, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, patt, -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }
            const char *sql2 = "DELETE FROM ZOBJECT WHERE ZSTRING LIKE ?;";
            if (sqlite3_prepare_v2(db, sql2, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, patt, -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }
        });
    }

    // Biome streams (iOS 16+)
    NSArray *biomePaths = @[
        @"/var/mobile/Library/Biome/streams/public",
        @"/var/mobile/Library/Biome/streams/restricted",
        @"/private/var/db/biome/streams",
        @"/private/var/mobile/Library/Biome/streams"
    ];

    for (NSString *dir in biomePaths) {
        if (![fm fileExistsAtPath:dir]) continue;
        // Biome stores events in subdirectories; delete the entire biome directory for this app
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *item in items) {
            if ([item containsString:bundleID]) {
                [self secureDeleteItemAtPath:[dir stringByAppendingPathComponent:item]];
            }
        }
    }
}

#pragma mark - 11. Keyboard / QuickType cache wipe

+ (void)cleanKeyboardCache {
    NSFileManager *fm = [NSFileManager defaultManager];
    // dynamic-text.dat — "iPhone keylogger" — stores user input from ALL apps
    NSString *keyboardPath = @"/var/mobile/Library/Keyboard/dynamic-text.dat";
    if ([fm fileExistsAtPath:keyboardPath]) {
        [self secureDeleteItemAtPath:keyboardPath];
        syslog(LOG_NOTICE, "[WiperHelper] Keyboard dynamic-text.dat wiped");
    }

    // Also clear keyboard learning cache
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

#pragma mark - 12. Location cache (locationd) wipe

+ (void)cleanLocationCacheForBundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];

    // locationd caches
    NSArray *locPaths = @[
        @"/var/mobile/Library/Caches/locationd",
        @"/var/jb/var/mobile/Library/Caches/locationd"
    ];

    for (NSString *dir in locPaths) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *item in items) {
            // Delete cache files but keep the directory structure
            NSString *fullPath = [dir stringByAppendingPathComponent:item];
            if (![[item pathExtension] isEqualToString:@"plist"]) {
                [self secureDeleteItemAtPath:fullPath];
            }
        }
    }

    // Reset location daemon
    runShellCommand("killall locationd 2>/dev/null || true");
}

#pragma mark - 13. CFNetwork / URLCache wipe

+ (void)cleanNetworkCacheForProxy:(id)proxy bundleID:(NSString *)bundleID {
    NSURL *dataURL = [proxy valueForKey:@"dataContainerURL"];
    if (!dataURL || !dataURL.path) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    // CFNetwork cache directories
    NSArray *cacheDirs = @[
        @"Library/Caches/com.apple.nsurlsessiond",
        @"Library/Caches/com.apple.CFNetwork",
        @"Library/Caches/com.apple.network",
        @"Library/Caches/CFNetworkCache",
        @"Library/Caches"
    ];

    for (NSString *sub in cacheDirs) {
        NSString *path = [dataURL.path stringByAppendingPathComponent:sub];
        if ([fm fileExistsAtPath:path]) {
            NSArray *items = [fm contentsOfDirectoryAtPath:path error:nil];
            for (NSString *item in items) {
                [self secureDeleteItemAtPath:[path stringByAppendingPathComponent:item]];
            }
        }
    }
}

#pragma mark - 14. StoreKit / In-app purchase data wipe

+ (void)cleanStoreKitForProxy:(id)proxy {
    NSURL *dataURL = [proxy valueForKey:@"dataContainerURL"];
    if (!dataURL || !dataURL.path) return;

    NSString *storekitPath = [dataURL.path stringByAppendingPathComponent:@"StoreKit"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:storekitPath]) {
        [self secureDeleteItemAtPath:storekitPath];
    }

    // System-level StoreKit cache
    NSString *sysStoreKit = @"/var/mobile/Library/Caches/com.apple.storekitd";
    if ([[NSFileManager defaultManager] fileExistsAtPath:sysStoreKit]) {
        [self secureDeleteItemAtPath:sysStoreKit];
    }
}

#pragma mark - 15. Notification center + APNs token wipe

+ (void)cleanNotificationsForBundleID:(NSString *)bundleID {
    // Unregister from push notifications (if running in app context)
    @try {
        Class UIApplicationClass = NSClassFromString(@"UIApplication");
        if (UIApplicationClass) {
            id app = [UIApplicationClass performSelector:@selector(sharedApplication)];
            if (app && [app respondsToSelector:@selector(unregisterForRemoteNotifications)]) {
                [app performSelector:@selector(unregisterForRemoteNotifications)];
            }
        }
    } @catch (NSException *e) {}

    // Clear notification center cache for this app
    runShellCommand("killall usernoted 2>/dev/null || true");

    // Clear notification scheduling database
    NSString *notifDB = @"/var/mobile/Library/RemoteNotification/db";
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:notifDB]) {
        NSArray *items = [fm contentsOfDirectoryAtPath:notifDB error:nil];
        for (NSString *item in items) {
            if ([item containsString:bundleID]) {
                [self secureDeleteItemAtPath:[notifDB stringByAppendingPathComponent:item]];
            }
        }
    }
}

#pragma mark - 16. System file metadata + timestamp disturbance

+ (void)changeSystemFileMetadata {
    // Modify timestamps on GlobalPreferences
    runShellCommand("touch -t 202401010000 /var/mobile/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true");
    runShellCommand("chown 501:501 /var/mobile/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true");

    // Reset installation timestamp for the app
    runShellCommand("touch -t 202401010000 /var/mobile/Containers/Data/Application/*/ 2>/dev/null || true");
}

#pragma mark - 17. Pasteboard + Clipboard

+ (void)cleanPasteboard {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [[UIPasteboard generalPasteboard] setItems:@[]];
            // Also clear named pasteboards if any
            [UIPasteboard generalPasteboard].string = @"";
        } @catch (NSException *e) {}
    });
}

#pragma mark - 18. appstored / installcoordinationd cache

+ (void)cleanAppStoreCacheForBundleID:(NSString *)bundleID {
    // Refresh app installation metadata
    runShellCommand("killall installd 2>/dev/null || true");
    runShellCommand("killall appstored 2>/dev/null || true");
    runShellCommand("killall installcoordinationd 2>/dev/null || true");
}

#pragma mark - Core: 18-step full wipe pipeline

+ (BOOL)performFullWipeForBundleID:(NSString *)bundleID {
    @try {
        Class LSApplicationProxyClass = NSClassFromString(@"LSApplicationProxy");
        if (!LSApplicationProxyClass) {
            syslog(LOG_ERR, "[WiperHelper] LSApplicationProxy not found");
            return NO;
        }

        id proxy = [LSApplicationProxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleID];
        if (!proxy) {
            syslog(LOG_ERR, "[WiperHelper] No proxy for %s", [bundleID UTF8String]);
            return NO;
        }

        syslog(LOG_NOTICE, "[WiperHelper] === 18-step wipe started for %s ===", [bundleID UTF8String]);

        // Step 1: Kill processes + extensions
        syslog(LOG_NOTICE, "[WiperHelper] Step 1/18: Kill processes");
        [self killAllProcessesForProxy:proxy bundleID:bundleID];
        usleep(1500000); // 1.5s for mmap release

        // Step 2: Deep clean sandbox (expanded subdirs)
        syslog(LOG_NOTICE, "[WiperHelper] Step 2/18: Deep sandbox wipe");
        [self deepCleanSandboxForProxy:proxy];

        // Step 3: App Group + System Group containers
        syslog(LOG_NOTICE, "[WiperHelper] Step 3/18: App Group + System Group");
        [self cleanAppGroupsForProxy:proxy bundleID:bundleID];

        // Step 4: Extension sandboxes
        syslog(LOG_NOTICE, "[WiperHelper] Step 4/18: Extensions");
        [self cleanExtensionsForProxy:proxy];

        // Step 5: Keychain (5 classes: genp/inet/cert/keys/identities)
        syslog(LOG_NOTICE, "[WiperHelper] Step 5/18: Keychain (5 classes)");
        [self enhancedCleanKeychainForBundleID:bundleID];

        // Step 6: TCC permission reset
        syslog(LOG_NOTICE, "[WiperHelper] Step 6/18: TCC reset");
        [self cleanTCCDatabaseForBundleID:bundleID];

        // Step 7: Preferences + WebKit + cfprefsd flush
        syslog(LOG_NOTICE, "[WiperHelper] Step 7/18: Preferences + cfprefsd");
        [self cleanAppPreferencesAndWebKitForBundleID:bundleID];

        // Step 8: Snapshots + SplashBoard
        syslog(LOG_NOTICE, "[WiperHelper] Step 8/18: Snapshots + SplashBoard");
        [self cleanSnapshotsForBundleID:bundleID];

        // Step 9: iCloud KVS (NSUbiquitousKeyValueStore)
        syslog(LOG_NOTICE, "[WiperHelper] Step 9/18: iCloud KVS");
        [self cleanICloudKVSForBundleID:bundleID];

        // Step 10: CoreDuet / KnowledgeC / Biome
        syslog(LOG_NOTICE, "[WiperHelper] Step 10/18: CoreDuet + Biome");
        [self cleanCoreDuetForBundleID:bundleID];

        // Step 11: Keyboard / QuickType cache
        syslog(LOG_NOTICE, "[WiperHelper] Step 11/18: Keyboard cache");
        [self cleanKeyboardCache];

        // Step 12: Location cache
        syslog(LOG_NOTICE, "[WiperHelper] Step 12/18: Location cache");
        [self cleanLocationCacheForBundleID:bundleID];

        // Step 13: CFNetwork / URLCache
        syslog(LOG_NOTICE, "[WiperHelper] Step 13/18: Network cache");
        [self cleanNetworkCacheForProxy:proxy bundleID:bundleID];

        // Step 14: StoreKit / IAP data
        syslog(LOG_NOTICE, "[WiperHelper] Step 14/18: StoreKit");
        [self cleanStoreKitForProxy:proxy];

        // Step 15: Notifications + APNs token
        syslog(LOG_NOTICE, "[WiperHelper] Step 15/18: Notifications + APNs");
        [self cleanNotificationsForBundleID:bundleID];

        // Step 16: System file metadata + timestamps
        syslog(LOG_NOTICE, "[WiperHelper] Step 16/18: Metadata disturbance");
        [self changeSystemFileMetadata];

        // Step 17: Pasteboard
        syslog(LOG_NOTICE, "[WiperHelper] Step 17/18: Pasteboard");
        [self cleanPasteboard];

        // Step 18: App store daemon cache
        syslog(LOG_NOTICE, "[WiperHelper] Step 18/18: AppStore daemon cache");
        [self cleanAppStoreCacheForBundleID:bundleID];

        syslog(LOG_NOTICE, "[WiperHelper] === 18-step wipe COMPLETE for %s ===", [bundleID UTF8String]);
        return YES;
    } @catch (NSException *exception) {
        syslog(LOG_ERR, "[WiperHelper] FATAL: %s", [exception.reason UTF8String]);
        return NO;
    }
}

@end
