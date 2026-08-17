#import "WiperHelper.h"
#import <sqlite3.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <unistd.h>
#import <syslog.h>

#pragma mark - Private API

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSURL *dataContainerURL;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSDictionary *groupContainerURLs;
@property (nonatomic, readonly) NSArray *plugInKitPlugins;
+ (LSApplicationProxy *)applicationProxyForIdentifier:(id)identifier;
@end

#pragma mark - Safe killall helper

static void killProcessByName(const char *name) {
    if (!name || strlen(name) == 0) return;

    const char *paths[] = {
        "/var/jb/usr/bin/killall",
        "/usr/bin/killall",
        NULL
    };

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

#pragma mark - Safe SQLite executor with WAL checkpoint

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
        syslog(LOG_ERR, "[MyAppWiper] SQLite Error: %s", [exception.reason UTF8String]);
    } @finally {
        sqlite3_close(db);
    }
    return YES;
}

#pragma mark - Implementation

@implementation WiperHelper

+ (NSString *)getConfigPathForBundleID:(NSString *)bundleID {
    NSString *baseDir = @"/var/jb/var/mobile/Library/Preferences/MyAppWiper/configs";
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        baseDir = @"/var/mobile/Library/Preferences/MyAppWiper/configs";
    }
    return [baseDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
}

#pragma mark - 1. Kill all processes (main + extensions)

+ (void)killAllProcessesForBundleID:(NSString *)bundleID {
    @try {
        LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
        if (!proxy || !proxy.bundleURL) return;

        NSString *infoPlistPath = [proxy.bundleURL.path stringByAppendingPathComponent:@"Info.plist"];
        NSString *mainExec = [[NSDictionary dictionaryWithContentsOfFile:infoPlistPath] objectForKey:@"CFBundleExecutable"];
        if (!mainExec) {
            mainExec = proxy.bundleURL.lastPathComponent.stringByDeletingPathExtension;
        }
        if (mainExec.length > 0) {
            killProcessByName([mainExec UTF8String]);
        }

        if ([proxy respondsToSelector:@selector(plugInKitPlugins)]) {
            NSArray *plugins = [proxy plugInKitPlugins];
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
        syslog(LOG_ERR, "[MyAppWiper] killAllProcesses exception: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 2. Wipe directory contents

+ (void)wipeDirectoryContents:(NSString *)path {
    if (!path || path.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;

    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:path error:&error];
    if (!error && files) {
        for (NSString *file in files) {
            NSString *fullPath = [path stringByAppendingPathComponent:file];
            [fm removeItemAtPath:fullPath error:nil];
        }
    }
}

#pragma mark - 3. Clean App Group shared containers

+ (void)cleanAppGroupsForProxy:(LSApplicationProxy *)proxy bundleID:(NSString *)bundleID {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableSet<NSString *> *groupPaths = [NSMutableSet set];

        if ([proxy respondsToSelector:@selector(groupContainerURLs)]) {
            NSDictionary *dict = [proxy groupContainerURLs];
            for (id value in dict.allValues) {
                if ([value isKindOfClass:[NSURL class]]) {
                    [groupPaths addObject:[value path]];
                } else if ([value isKindOfClass:[NSString class]]) {
                    [groupPaths addObject:value];
                }
            }
        }

        // Extract vendor key (e.g. "xunmeng" from "com.xunmeng.pinduoduo")
        NSArray *parts = [bundleID componentsSeparatedByString:@"."];
        NSString *vendorKey = parts.count > 1 ? parts[1] : bundleID;

        NSString *sharedGroupRoot = @"/var/mobile/Containers/Shared/AppGroup";
        if ([fm fileExistsAtPath:sharedGroupRoot]) {
            NSArray *groups = [fm contentsOfDirectoryAtPath:sharedGroupRoot error:nil];
            for (NSString *uuid in groups) {
                NSString *metaPath = [sharedGroupRoot
                    stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", uuid]];
                if ([fm fileExistsAtPath:metaPath]) {
                    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
                    NSString *identifier = meta[@"MCMMetadataIdentifier"];
                    if (identifier && ([identifier containsString:bundleID] ||
                                       [identifier containsString:vendorKey])) {
                        [groupPaths addObject:[sharedGroupRoot stringByAppendingPathComponent:uuid]];
                    }
                }
            }
        }

        for (NSString *groupPath in groupPaths) {
            syslog(LOG_NOTICE, "[MyAppWiper] Cleaning App Group: %s", [groupPath UTF8String]);
            [self wipeDirectoryContents:groupPath];
        }
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[MyAppWiper] cleanAppGroups exception: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 4. Clean Extension sandboxes

+ (void)cleanExtensionsForProxy:(LSApplicationProxy *)proxy {
    @try {
        if ([proxy respondsToSelector:@selector(plugInKitPlugins)]) {
            NSArray *plugins = [proxy plugInKitPlugins];
            for (id plugin in plugins) {
                NSString *extBundleID = nil;
                if ([plugin respondsToSelector:@selector(bundleIdentifier)]) {
                    extBundleID = [plugin performSelector:@selector(bundleIdentifier)];
                }
                if (extBundleID) {
                    LSApplicationProxy *extProxy = [LSApplicationProxy applicationProxyForIdentifier:extBundleID];
                    if (extProxy && extProxy.dataContainerURL && extProxy.dataContainerURL.path) {
                        syslog(LOG_NOTICE, "[MyAppWiper] Cleaning Extension: %s", [extBundleID UTF8String]);
                        [self wipeDirectoryContents:extProxy.dataContainerURL.path];
                    }
                }
            }
        }
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[MyAppWiper] cleanExtensions exception: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 5. Keychain database wipe (vendorKey matching + prepared statements)

+ (void)cleanKeychainDatabaseForBundleID:(NSString *)bundleID {
    NSArray *keychainPaths = @[
        @"/var/Keychains/keychain-2.db",
        @"/private/var/Keychains/keychain-2.db"
    ];

    // Extract vendor key for broader matching (e.g. "xunmeng" from "com.xunmeng.pinduoduo")
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    NSString *vendorKey = parts.count > 1 ? parts[1] : bundleID;

    for (NSString *dbPath in keychainPaths) {
        executeSQLiteOnDB(dbPath, ^(sqlite3 *db) {
            sqlite3_stmt *stmt;

            // Match both full bundleID and vendorKey in genp (agrp, svce)
            const char *sqlGenp = "DELETE FROM genp WHERE agrp LIKE ? OR agrp LIKE ? OR svce LIKE ? OR svce LIKE ?";
            if (sqlite3_prepare_v2(db, sqlGenp, -1, &stmt, NULL) == SQLITE_OK) {
                NSString *pattern1 = [NSString stringWithFormat:@"%%%@%%", bundleID];
                NSString *pattern2 = [NSString stringWithFormat:@"%%%@%%", vendorKey];
                sqlite3_bind_text(stmt, 1, [pattern1 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 2, [pattern2 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 3, [pattern1 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 4, [pattern2 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }

            // Match in inet (agrp, srvr)
            const char *sqlInet = "DELETE FROM inet WHERE agrp LIKE ? OR agrp LIKE ?";
            if (sqlite3_prepare_v2(db, sqlInet, -1, &stmt, NULL) == SQLITE_OK) {
                NSString *pattern1 = [NSString stringWithFormat:@"%%%@%%", bundleID];
                NSString *pattern2 = [NSString stringWithFormat:@"%%%@%%", vendorKey];
                sqlite3_bind_text(stmt, 1, [pattern1 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 2, [pattern2 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }
        });
    }
}

#pragma mark - 6. TCC permission reset

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
                syslog(LOG_NOTICE, "[MyAppWiper] TCC DELETE for %s (affected=%d)",
                       [bundleID UTF8String], sqlite3_changes(db));
                sqlite3_finalize(stmt);
            }
        });
    }
}

#pragma mark - 7. Clean Snapshots (prevent app restoration preview leak)

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
                [fm removeItemAtPath:[dir stringByAppendingPathComponent:item] error:nil];
            }
        }
    }
}

#pragma mark - Core: 8-step full wipe pipeline

+ (BOOL)performFullWipeForBundleID:(NSString *)bundleID {
    @try {
        LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
        if (!proxy) {
            syslog(LOG_ERR, "[MyAppWiper] performFullWipe: no proxy for %s", [bundleID UTF8String]);
            return NO;
        }

        syslog(LOG_NOTICE, "[MyAppWiper] === Full wipe started for %s ===", [bundleID UTF8String]);

        // Step 1: Kill main app + all extension processes
        [self killAllProcessesForBundleID:bundleID];

        // Step 2: Critical timing delay - wait for kernel to release mmap mappings
        usleep(1500000); // 1.5 seconds

        // Step 3: Wipe main app standard sandbox
        if (proxy.dataContainerURL && proxy.dataContainerURL.path) {
            syslog(LOG_NOTICE, "[MyAppWiper] Step 3: Cleaning main sandbox");
            [self wipeDirectoryContents:proxy.dataContainerURL.path];
        }

        // Step 4: Wipe App Group shared containers (MMKV + SQLCipher + .crc)
        syslog(LOG_NOTICE, "[MyAppWiper] Step 4: Cleaning App Group containers");
        [self cleanAppGroupsForProxy:proxy bundleID:bundleID];

        // Step 5: Wipe all Extension sandboxes
        syslog(LOG_NOTICE, "[MyAppWiper] Step 5: Cleaning Extension sandboxes");
        [self cleanExtensionsForProxy:proxy];

        // Step 6: Database-level Keychain wipe
        syslog(LOG_NOTICE, "[MyAppWiper] Step 6: Cleaning Keychain database");
        [self cleanKeychainDatabaseForBundleID:bundleID];

        // Step 7: Database-level TCC permission reset
        syslog(LOG_NOTICE, "[MyAppWiper] Step 7: Resetting TCC permissions");
        [self cleanTCCDatabaseForBundleID:bundleID];

        // Step 8: Clean app snapshots
        syslog(LOG_NOTICE, "[MyAppWiper] Step 8: Cleaning Snapshots");
        [self cleanSnapshotsForBundleID:bundleID];

        syslog(LOG_NOTICE, "[MyAppWiper] === Full wipe completed for %s ===", [bundleID UTF8String]);
        return YES;
    } @catch (NSException *exception) {
        syslog(LOG_ERR, "[MyAppWiper] performFullWipe fatal error: %s", [exception.reason UTF8String]);
        return NO;
    }
}

@end
