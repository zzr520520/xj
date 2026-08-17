#import "WiperHelper.h"
#import <sqlite3.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <unistd.h>
#import <syslog.h>
#import <fcntl.h>

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSURL *dataContainerURL;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSDictionary *groupContainerURLs;
@property (nonatomic, readonly) NSArray *plugInKitPlugins;
+ (LSApplicationProxy *)applicationProxyForIdentifier:(id)identifier;
@end

#pragma mark - Safe killall

static void killProcessByName(const char *name) {
    if (!name || strlen(name) == 0) return;
    const char *paths[] = { "/var/jb/usr/bin/killall", "/usr/bin/killall", NULL };
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

#pragma mark - 1. DoD 5220.22-M 7-pass secure delete

+ (void)secureDeleteItemAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;

    BOOL isDir = NO;
    [fm fileExistsAtPath:path isDirectory:&isDir];

    if (isDir) {
        // Recurse into subdirectories
        NSError *error = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:path error:&error];
        for (NSString *subItem in contents) {
            NSString *fullSubPath = [path stringByAppendingPathComponent:subItem];
            [self secureDeleteItemAtPath:fullSubPath];
        }
        [fm removeItemAtPath:path error:nil];
    } else {
        // 7-pass DoD overwrite on files
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        unsigned long long fileSize = [attrs fileSize];

        if (fileSize > 0 && fileSize < 100 * 1024 * 1024) { // Skip files > 100MB to prevent hang
            int fd = open([path UTF8String], O_WRONLY);
            if (fd != -1) {
                char *buf = malloc((size_t)fileSize);
                if (buf) {
                    for (int pass = 0; pass < 7; pass++) {
                        lseek(fd, 0, SEEK_SET);
                        if (pass == 0)      memset(buf, 0x00, (size_t)fileSize);  // Pass 1: zeros
                        else if (pass == 1)  memset(buf, 0xFF, (size_t)fileSize);  // Pass 2: ones
                        else if (pass == 6)  memset(buf, 0x00, (size_t)fileSize);  // Pass 7: zeros
                        else                 arc4random_buf(buf, (size_t)fileSize); // Passes 3-6: random

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

#pragma mark - 2. Kill all processes

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
        syslog(LOG_ERR, "[WiperHelper] killAllProcesses exception: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 3. App Group deep cleanup

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

        NSArray *parts = [bundleID componentsSeparatedByString:@"."];
        NSString *vendorKey = parts.count > 1 ? parts[1] : bundleID;

        NSString *sharedGroupRoot = @"/var/mobile/Containers/Shared/AppGroup";
        if ([fm fileExistsAtPath:sharedGroupRoot]) {
            NSArray *groups = [fm contentsOfDirectoryAtPath:sharedGroupRoot error:nil];
            for (NSString *uuid in groups) {
                NSString *metaPath = [sharedGroupRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", uuid]];
                if ([fm fileExistsAtPath:metaPath]) {
                    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
                    NSString *identifier = meta[@"MCMMetadataIdentifier"];
                    if (identifier && ([identifier containsString:bundleID] || [identifier containsString:vendorKey])) {
                        [groupPaths addObject:[sharedGroupRoot stringByAppendingPathComponent:uuid]];
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

#pragma mark - 4. Extension sandbox cleanup

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
                        [self secureDeleteItemAtPath:extProxy.dataContainerURL.path];
                    }
                }
            }
        }
    } @catch (NSException *e) {
        syslog(LOG_ERR, "[WiperHelper] cleanExtensions exception: %s", [e.reason UTF8String]);
    }
}

#pragma mark - 5. Keychain database wipe

+ (void)cleanKeychainDatabaseForBundleID:(NSString *)bundleID {
    NSArray *keychainPaths = @[
        @"/var/Keychains/keychain-2.db",
        @"/private/var/Keychains/keychain-2.db"
    ];

    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    NSString *vendorKey = parts.count > 1 ? parts[1] : bundleID;

    for (NSString *dbPath in keychainPaths) {
        executeSQLiteOnDB(dbPath, ^(sqlite3 *db) {
            sqlite3_stmt *stmt;

            const char *sqlGenp = "DELETE FROM genp WHERE agrp LIKE ? OR agrp LIKE ? OR svce LIKE ? OR svce LIKE ?";
            if (sqlite3_prepare_v2(db, sqlGenp, -1, &stmt, NULL) == SQLITE_OK) {
                NSString *p1 = [NSString stringWithFormat:@"%%%@%%", bundleID];
                NSString *p2 = [NSString stringWithFormat:@"%%%@%%", vendorKey];
                sqlite3_bind_text(stmt, 1, [p1 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 2, [p2 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 3, [p1 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 4, [p2 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }

            const char *sqlInet = "DELETE FROM inet WHERE agrp LIKE ? OR agrp LIKE ?";
            if (sqlite3_prepare_v2(db, sqlInet, -1, &stmt, NULL) == SQLITE_OK) {
                NSString *p1 = [NSString stringWithFormat:@"%%%@%%", bundleID];
                NSString *p2 = [NSString stringWithFormat:@"%%%@%%", vendorKey];
                sqlite3_bind_text(stmt, 1, [p1 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 2, [p2 UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }
        });
    }
}

#pragma mark - 6. TCC database cleanup

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
}

#pragma mark - 7. Snapshot cleanup

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

#pragma mark - Core: 8-step full wipe pipeline with DoD 5220.22-M

+ (BOOL)performFullWipeForBundleID:(NSString *)bundleID {
    @try {
        LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
        if (!proxy) {
            syslog(LOG_ERR, "[WiperHelper] performFullWipe: no proxy for %s", [bundleID UTF8String]);
            return NO;
        }

        syslog(LOG_NOTICE, "[WiperHelper] === Full wipe (DoD 7-pass) started for %s ===", [bundleID UTF8String]);

        // Step 1: Kill processes
        [self killAllProcessesForBundleID:bundleID];

        // Step 2: Wait for mmap release
        usleep(1500000); // 1.5s

        // Step 3: Secure delete main sandbox
        if (proxy.dataContainerURL && proxy.dataContainerURL.path) {
            syslog(LOG_NOTICE, "[WiperHelper] Step 3: Secure deleting main sandbox");
            [self secureDeleteItemAtPath:proxy.dataContainerURL.path];
        }

        // Step 4: Secure delete App Group containers
        syslog(LOG_NOTICE, "[WiperHelper] Step 4: Secure deleting App Group containers");
        [self cleanAppGroupsForProxy:proxy bundleID:bundleID];

        // Step 5: Secure delete Extension sandboxes
        syslog(LOG_NOTICE, "[WiperHelper] Step 5: Secure deleting Extension sandboxes");
        [self cleanExtensionsForProxy:proxy];

        // Step 6: Keychain database wipe
        syslog(LOG_NOTICE, "[WiperHelper] Step 6: Cleaning Keychain database");
        [self cleanKeychainDatabaseForBundleID:bundleID];

        // Step 7: TCC permission reset
        syslog(LOG_NOTICE, "[WiperHelper] Step 7: Resetting TCC permissions");
        [self cleanTCCDatabaseForBundleID:bundleID];

        // Step 8: Snapshot cleanup
        syslog(LOG_NOTICE, "[WiperHelper] Step 8: Cleaning Snapshots");
        [self cleanSnapshotsForBundleID:bundleID];

        syslog(LOG_NOTICE, "[WiperHelper] === Full wipe completed for %s ===", [bundleID UTF8String]);
        return YES;
    } @catch (NSException *exception) {
        syslog(LOG_ERR, "[WiperHelper] performFullWipe error: %s", [exception.reason UTF8String]);
        return NO;
    }
}

@end
