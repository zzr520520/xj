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

@interface LSPlugInKitProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *path;
@end

#pragma mark - Helper: kill process by name (dual-path with access check)

static void killProcessByName(const char *name) {
    const char *paths[] = {
        "/var/jb/usr/bin/killall",
        "/usr/bin/killall",
        NULL
    };
    for (int i = 0; paths[i] != NULL; i++) {
        if (access(paths[i], X_OK) == 0) {
            pid_t pid;
            const char *argv[] = {"killall", "-9", name, NULL};
            posix_spawn(&pid, paths[i], NULL, NULL, (char *const *)argv, NULL);
            int status;
            waitpid(pid, &status, 0);
            syslog(LOG_NOTICE, "[MyAppWiper] killall -9 %s (exit=%d)", name, WEXITSTATUS(status));
            return;
        }
    }
    syslog(LOG_ERR, "[MyAppWiper] killall not found for %s", name);
}

#pragma mark - Helper: SQLite execute with WAL checkpoint + busy timeout

static BOOL executeSQLiteOnDB(NSString *dbPath, void(^workBlock)(sqlite3 *db)) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) return NO;

    sqlite3 *db;
    if (sqlite3_open_v2([dbPath UTF8String], &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        syslog(LOG_ERR, "[MyAppWiper] Failed to open DB: %s (%s)",
               [dbPath UTF8String], db ? sqlite3_errmsg(db) : "null");
        if (db) sqlite3_close(db);
        return NO;
    }

    sqlite3_busy_timeout(db, 5000);

    workBlock(db);

    // CRITICAL: Force WAL checkpoint so changes persist to the main database file
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
    sqlite3_close(db);
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
    LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    if (!proxy || !proxy.bundleURL) {
        syslog(LOG_ERR, "[MyAppWiper] killAll: no bundleURL for %s", [bundleID UTF8String]);
        return;
    }

    // 1. Kill main app process
    NSString *infoPlistPath = [proxy.bundleURL.path stringByAppendingPathComponent:@"Info.plist"];
    NSString *mainExec = [[NSDictionary dictionaryWithContentsOfFile:infoPlistPath] objectForKey:@"CFBundleExecutable"];
    if (!mainExec) {
        mainExec = proxy.bundleURL.lastPathComponent.stringByDeletingPathExtension;
    }
    if (mainExec.length > 0) {
        killProcessByName([mainExec UTF8String]);
    }

    // 2. Kill all Extension processes via plugInKitPlugins
    NSArray *plugins = [proxy plugInKitPlugins];
    for (LSPlugInKitProxy *plugin in plugins) {
        NSString *extBundleID = plugin.bundleIdentifier;
        if (!extBundleID) continue;

        // Try to read CFBundleExecutable from extension's Info.plist
        NSString *extPath = plugin.path;
        NSString *extExec = nil;
        if (extPath) {
            NSString *extInfoPlist = [extPath stringByAppendingPathComponent:@"Info.plist"];
            extExec = [[NSDictionary dictionaryWithContentsOfFile:extInfoPlist] objectForKey:@"CFBundleExecutable"];
        }
        if (!extExec) {
            extExec = [extBundleID componentsSeparatedByString:@"."].lastObject;
        }
        if (extExec.length > 0) {
            killProcessByName([extExec UTF8String]);
        }
    }
}

#pragma mark - 2. Wipe directory contents

+ (void)wipeDirectoryContents:(NSString *)path {
    if (!path || path.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;

    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:path error:&error];
    if (error || !files) return;

    for (NSString *file in files) {
        NSString *fullPath = [path stringByAppendingPathComponent:file];
        [fm removeItemAtPath:fullPath error:nil];
    }
}

#pragma mark - 3. Clean App Group shared containers (MMKV + SQLCipher)

+ (void)cleanAppGroupsForProxy:(LSApplicationProxy *)proxy bundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet<NSString *> *groupPaths = [NSMutableSet set];

    // Method A: LSApplicationProxy groupContainerURLs
    if ([proxy respondsToSelector:@selector(groupContainerURLs)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSDictionary *dict = [proxy performSelector:@selector(groupContainerURLs)];
#pragma clang diagnostic pop
        for (id value in dict.allValues) {
            NSString *groupPath = nil;
            if ([value isKindOfClass:[NSURL class]]) {
                groupPath = [value path];
            } else if ([value isKindOfClass:[NSString class]]) {
                groupPath = value;
            }
            if (groupPath) [groupPaths addObject:groupPath];
        }
    }

    // Method B: Brute-force scan /var/mobile/Containers/Shared/AppGroup/ via metadata plist
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
                                   [identifier containsString:@"pinduoduo"] ||
                                   [identifier containsString:@"xunmeng"])) {
                    [groupPaths addObject:[sharedGroupRoot stringByAppendingPathComponent:uuid]];
                }
            }
        }
    }

    // Wipe all found group containers (destroys MMKV files + .crc + SQLCipher databases)
    for (NSString *groupPath in groupPaths) {
        syslog(LOG_NOTICE, "[MyAppWiper] Cleaning App Group: %s", [groupPath UTF8String]);
        [self wipeDirectoryContents:groupPath];
    }
}

#pragma mark - 4. Clean all App Extension sandboxes

+ (void)cleanExtensionsForProxy:(LSApplicationProxy *)proxy {
    NSArray *plugins = [proxy plugInKitPlugins];
    for (LSPlugInKitProxy *plugin in plugins) {
        NSString *extBundleID = plugin.bundleIdentifier;
        if (!extBundleID) continue;

        // LSPlugInKitProxy has no dataContainerURL property;
        // create an LSApplicationProxy for the extension to get its container
        LSApplicationProxy *extProxy = [LSApplicationProxy applicationProxyForIdentifier:extBundleID];
        if (extProxy && extProxy.dataContainerURL) {
            NSString *extDataPath = extProxy.dataContainerURL.path;
            if (extDataPath.length > 0) {
                syslog(LOG_NOTICE, "[MyAppWiper] Cleaning Extension sandbox: %s", [extBundleID UTF8String]);
                [self wipeDirectoryContents:extDataPath];
            }
        }
    }
}

#pragma mark - 5. Database-level Keychain wipe (prepared statements + WAL checkpoint)

+ (void)cleanKeychainDatabaseForBundleID:(NSString *)bundleID {
    NSArray *keychainPaths = @[
        @"/var/Keychains/keychain-2.db",
        @"/private/var/Keychains/keychain-2.db"
    ];

    NSString *pattern = [NSString stringWithFormat:@"%%%@%%", bundleID];
    const char *patternUTF8 = [pattern UTF8String];

    for (NSString *dbPath in keychainPaths) {
        executeSQLiteOnDB(dbPath, ^(sqlite3 *db) {
            sqlite3_stmt *stmt;

            // Delete generic passwords (agrp = access group, svce = service, desc = description)
            const char *sqlGenp = "DELETE FROM genp WHERE agrp LIKE ? OR svce LIKE ? OR desc LIKE ?";
            if (sqlite3_prepare_v2(db, sqlGenp, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, patternUTF8, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 2, patternUTF8, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 3, patternUTF8, -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                syslog(LOG_NOTICE, "[MyAppWiper] Keychain genp DELETE for %s (affected=%d)",
                       [bundleID UTF8String], sqlite3_changes(db));
                sqlite3_finalize(stmt);
            }

            // Delete internet passwords (agrp = access group, srvr = server)
            const char *sqlInet = "DELETE FROM inet WHERE agrp LIKE ? OR srvr LIKE ?";
            if (sqlite3_prepare_v2(db, sqlInet, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, patternUTF8, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 2, patternUTF8, -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }

            // Delete certificates
            const char *sqlCert = "DELETE FROM cert WHERE agrp LIKE ?";
            if (sqlite3_prepare_v2(db, sqlCert, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, patternUTF8, -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }
        });
    }
}

#pragma mark - 6. Database-level TCC permission reset

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

#pragma mark - 7. Clean HTTP Cookie storage

+ (void)cleanHTTPCookiesForBundleID:(NSString *)bundleID {
    // Clear all HTTP cookies (NSHTTPCookieStorage is shared system-wide)
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [cookieStorage cookies];
    for (NSHTTPCookie *cookie in cookies) {
        [cookieStorage deleteCookie:cookie];
    }
    syslog(LOG_NOTICE, "[MyAppWiper] Cleaned %lu HTTP cookies", (unsigned long)cookies.count);
}

#pragma mark - 8. Restart system daemons

+ (void)restartSystemDaemons {
    const char *daemons[] = {"cfprefsd", "tccd", "securityd", "locationd", NULL};
    for (int i = 0; daemons[i] != NULL; i++) {
        killProcessByName(daemons[i]);
    }
}

#pragma mark - Core Pipeline: 10-step full wipe

+ (BOOL)performFullWipeForBundleID:(NSString *)bundleID {
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

    // Step 4: Wipe App Group shared containers (MMKV + SQLCipher + .crc files)
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

    // Step 8: Clean HTTP cookies
    syslog(LOG_NOTICE, "[MyAppWiper] Step 8: Cleaning HTTP cookies");
    [self cleanHTTPCookiesForBundleID:bundleID];

    // Step 9: Restart system daemons (flush in-memory caches)
    syslog(LOG_NOTICE, "[MyAppWiper] Step 9: Restarting system daemons");
    [self restartSystemDaemons];

    // Step 9b: Wait for daemons to restart
    usleep(500000); // 0.5 seconds

    syslog(LOG_NOTICE, "[MyAppWiper] === Full wipe completed for %s ===", [bundleID UTF8String]);
    return YES;
}

@end
