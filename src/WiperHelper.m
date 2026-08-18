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

#pragma mark - posix_spawn shell (system() NOT available on iOS)

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

#pragma mark - SQLite executor with WAL checkpoint

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

@implementation WiperHelper

+ (NSString *)getConfigPathForBundleID:(NSString *)bundleID {
    NSString *baseDir = @"/var/jb/var/mobile/Library/Preferences/MyAppWiper/configs";
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        baseDir = @"/var/mobile/Library/Preferences/MyAppWiper/configs";
    }
    return [baseDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
}

#pragma mark - 1. DoD 5220.22-M 7-pass secure delete + inode disturbance

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

        // inode 扰动: 重命名后覆写，破坏 inode/journal 取证
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

#pragma mark - 2. Kill main process + extensions

+ (void)killAllProcessesForProxy:(id)proxy bundleID:(NSString *)bundleID {
    @try {
        NSURL *bundleURL = [proxy valueForKey:@"bundleURL"];
        if (!bundleURL) return;

        NSString *infoPlistPath = [bundleURL.path stringByAppendingPathComponent:@"Info.plist"];
        NSString *mainExec = [[NSDictionary dictionaryWithContentsOfFile:infoPlistPath] objectForKey:@"CFBundleExecutable"];
        if (!mainExec) {
            mainExec = bundleURL.lastPathComponent.stringByDeletingPathExtension;
        }
        if (mainExec.length > 0) {
            killProcessByName([mainExec UTF8String]);
        }

        if ([proxy respondsToSelector:@selector(plugInKitPlugins)]) {
            NSArray *plugins = [proxy performSelector:@selector(plugInKitPlugins)];
            for (id plugin in plugins) {
                NSString *extBundleID = nil;
                if ([plugin respondsToSelector:@selector(bundleIdentifier)]) {
                    extBundleID = [plugin performSelector:@selector(bundleIdentifier)];
                }
                if (extBundleID) {
                    NSString *extExec = [extBundleID componentsSeparatedByString:@"."].lastObject;
                    if (extExec.length > 0) {
                        killProcessByName([extExec UTF8String]);
                    }
                }
            }
        }
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[WiperHelper] killAllProcesses exception: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 3. Deep sandbox subdirectory recursive wipe

+ (void)deepCleanSandboxForProxy:(id)proxy {
    NSURL *dataURL = [proxy valueForKey:@"dataContainerURL"];
    if (!dataURL || !dataURL.path) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *subDirs = @[
        @"Documents",
        @"Library/Caches",
        @"Library/Application Support",
        @"Library/Preferences",
        @"Library/SyncedPreferences",
        @"tmp"
    ];

    for (NSString *sub in subDirs) {
        NSString *targetPath = [dataURL.path stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:targetPath]) continue;

        syslog(LOG_NOTICE, "[WiperHelper] Deep cleaning sandbox: %s", [targetPath UTF8String]);

        NSError *error = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:targetPath error:&error];
        for (NSString *item in contents) {
            [self secureDeleteItemAtPath:[targetPath stringByAppendingPathComponent:item]];
        }
    }
}

#pragma mark - 4. App Group deep cleanup with vendor matching

+ (void)cleanAppGroupsForProxy:(id)proxy bundleID:(NSString *)bundleID {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableSet<NSString *> *groupPaths = [NSMutableSet set];

        if ([proxy respondsToSelector:@selector(groupContainerURLs)]) {
            NSDictionary *dict = [proxy performSelector:@selector(groupContainerURLs)];
            for (id value in dict.allValues) {
                if ([value isKindOfClass:[NSURL class]]) {
                    [groupPaths addObject:[value path]];
                } else if ([value isKindOfClass:[NSString class]]) {
                    [groupPaths addObject:value];
                }
            }
        }

        NSArray *parts = [bundleID componentsSeparatedByString:@"."];
        NSString *vendorKey = parts.count > 1 ? parts[1] : bundleID;

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
                            NSArray *vendorPatterns = @[@"meituan", @"sankuai", @"dianping",
                                                       @"xingin", @"xunmeng", @"pinduoduo"];
                            for (NSString *pattern in vendorPatterns) {
                                if ([bundleID containsString:pattern] && [identifier containsString:pattern]) {
                                    match = YES;
                                    break;
                                }
                            }
                        }
                        if (match) {
                            [groupPaths addObject:[sharedGroupRoot stringByAppendingPathComponent:uuid]];
                        }
                    }
                }
            }
        }

        for (NSString *groupPath in groupPaths) {
            syslog(LOG_NOTICE, "[WiperHelper] Secure deleting App Group: %s", [groupPath UTF8String]);
            [self secureDeleteItemAtPath:groupPath];
        }
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[WiperHelper] cleanAppGroups exception: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 5. Extension sandbox cleanup

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
                            syslog(LOG_NOTICE, "[WiperHelper] Secure deleting extension: %s", [extDataURL.path UTF8String]);
                            [self secureDeleteItemAtPath:extDataURL.path];
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[WiperHelper] cleanExtensions exception: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 6. Enhanced Keychain wipe — parameterized SQL + API fuzzy

+ (void)enhancedCleanKeychainForBundleID:(NSString *)bundleID {
    NSArray *keychainPaths = @[
        @"/var/Keychains/keychain-2.db",
        @"/private/var/Keychains/keychain-2.db"
    ];

    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    NSString *vendorKey = parts.count > 1 ? parts[1] : bundleID;

    // Database-level: parameterized queries (防注入)
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
                    int changes = sqlite3_changes(db);
                    if (changes > 0) {
                        syslog(LOG_NOTICE, "[WiperHelper] Keychain %s: deleted %d rows", [table UTF8String], changes);
                    }
                    sqlite3_finalize(stmt);
                }
            }
        });
    }

    // API-level fallback: fuzzy match on service AND access group
    NSDictionary *allQuery = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecMatchLimit: (id)kSecMatchLimitAll,
        (id)kSecReturnAttributes: @YES,
    };
    CFArrayRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)allQuery, (CFTypeRef *)&result);
    if (status == errSecSuccess && result) {
        NSArray *items = (__bridge_transfer NSArray *)result;
        for (NSDictionary *item in items) {
            NSString *service = item[(id)kSecAttrService];
            NSString *accessGroup = item[(id)kSecAttrAccessGroup];

            BOOL match = (service && ([service containsString:bundleID] || [service containsString:vendorKey])) ||
                         (accessGroup && ([accessGroup containsString:bundleID] || [accessGroup containsString:vendorKey]));

            if (match) {
                NSMutableDictionary *delQuery = [NSMutableDictionary dictionary];
                delQuery[(id)kSecClass] = (id)kSecClassGenericPassword;
                if (service) delQuery[(id)kSecAttrService] = service;
                if (accessGroup) delQuery[(id)kSecAttrAccessGroup] = accessGroup;
                OSStatus delStatus = SecItemDelete((__bridge CFDictionaryRef)delQuery);
                if (delStatus != errSecSuccess) {
                    syslog(LOG_ERR, "[WiperHelper] SecItemDelete failed (status=%d) for service=%s",
                           (int)delStatus, [service UTF8String]);
                }
            }
        }
    }
}

#pragma mark - 7. TCC permission reset + daemon refresh (posix_spawn)

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
                syslog(LOG_NOTICE, "[WiperHelper] TCC DELETE for %s (affected=%d)",
                       [bundleID UTF8String], sqlite3_changes(db));
                sqlite3_finalize(stmt);
            }
        });
    }

    // Flush tccd via posix_spawn (system() NOT available on iOS)
    runShellCommand("launchctl kickstart -k system/com.apple.tccd 2>/dev/null || killall tccd 2>/dev/null");
}

#pragma mark - 8. Preferences + WebKit cleanup

+ (void)cleanAppPreferencesAndWebKitForBundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *prefDirs = @[@"/var/mobile/Library/Preferences", @"/var/jb/var/mobile/Library/Preferences"];
    for (NSString *dir in prefDirs) {
        NSString *prefFile = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
        if ([fm fileExistsAtPath:prefFile]) {
            syslog(LOG_NOTICE, "[WiperHelper] Cleaning preferences: %s", [prefFile UTF8String]);
            [self secureDeleteItemAtPath:prefFile];
        }
    }

    NSArray *webDirs = @[@"/var/mobile/Library/WebKit", @"/var/jb/var/mobile/Library/WebKit"];
    for (NSString *dir in webDirs) {
        NSString *webFolder = [dir stringByAppendingPathComponent:bundleID];
        if ([fm fileExistsAtPath:webFolder]) {
            syslog(LOG_NOTICE, "[WiperHelper] Cleaning WebKit: %s", [webFolder UTF8String]);
            [self secureDeleteItemAtPath:webFolder];
        }
    }
}

#pragma mark - 9. Snapshot cleanup

+ (void)cleanSnapshotsForBundleID:(NSString *)bundleID {
    NSArray *snapDirs = @[
        @"/var/mobile/Library/Caches/Snapshots",
        @"/var/jb/var/mobile/Library/Caches/Snapshots"
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
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

#pragma mark - 10. System file metadata disturbance (posix_spawn)

+ (void)changeSystemFileMetadata {
    runShellCommand("touch -t 202401010000 /var/mobile/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true");
    runShellCommand("chown 501:501 /var/mobile/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true");
}

#pragma mark - Core: 10-step full wipe pipeline

+ (BOOL)performFullWipeForBundleID:(NSString *)bundleID {
    @try {
        Class LSApplicationProxyClass = NSClassFromString(@"LSApplicationProxy");
        if (!LSApplicationProxyClass) {
            syslog(LOG_ERR, "[WiperHelper] LSApplicationProxy class not found");
            return NO;
        }

        id proxy = [LSApplicationProxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleID];
        if (!proxy) {
            syslog(LOG_ERR, "[WiperHelper] No proxy for %s", [bundleID UTF8String]);
            return NO;
        }

        syslog(LOG_NOTICE, "[WiperHelper] === Full wipe (DoD 7-pass + inode) started for %s ===", [bundleID UTF8String]);

        // Step 1: Kill main process + extensions
        syslog(LOG_NOTICE, "[WiperHelper] Step 1: Killing processes");
        [self killAllProcessesForProxy:proxy bundleID:bundleID];

        // Step 2: Wait for mmap release
        usleep(1500000); // 1.5s

        // Step 3: Deep clean sandbox subdirs
        syslog(LOG_NOTICE, "[WiperHelper] Step 3: Deep cleaning sandbox");
        [self deepCleanSandboxForProxy:proxy];

        // Step 4: App Group containers
        syslog(LOG_NOTICE, "[WiperHelper] Step 4: Cleaning App Groups");
        [self cleanAppGroupsForProxy:proxy bundleID:bundleID];

        // Step 5: Extension sandboxes
        syslog(LOG_NOTICE, "[WiperHelper] Step 5: Cleaning extensions");
        [self cleanExtensionsForProxy:proxy];

        // Step 6: Keychain (parameterized SQL + API fuzzy)
        syslog(LOG_NOTICE, "[WiperHelper] Step 6: Cleaning Keychain");
        [self enhancedCleanKeychainForBundleID:bundleID];

        // Step 7: TCC reset + daemon refresh
        syslog(LOG_NOTICE, "[WiperHelper] Step 7: Resetting TCC");
        [self cleanTCCDatabaseForBundleID:bundleID];

        // Step 8: Preferences + WebKit
        syslog(LOG_NOTICE, "[WiperHelper] Step 8: Cleaning preferences + WebKit");
        [self cleanAppPreferencesAndWebKitForBundleID:bundleID];

        // Step 9: Snapshots
        syslog(LOG_NOTICE, "[WiperHelper] Step 9: Cleaning snapshots");
        [self cleanSnapshotsForBundleID:bundleID];

        // Step 10: System file metadata + pasteboard
        syslog(LOG_NOTICE, "[WiperHelper] Step 10: Metadata disturbance + pasteboard");
        [self changeSystemFileMetadata];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIPasteboard generalPasteboard] setItems:@[]];
        });

        syslog(LOG_NOTICE, "[WiperHelper] === Full wipe completed for %s ===", [bundleID UTF8String]);
        return YES;
    } @catch (NSException *exception) {
        syslog(LOG_ERR, "[WiperHelper] performFullWipe error: %s", [exception.reason UTF8String]);
        return NO;
    }
}

@end
