#import "WiperHelper.h"
#import <sqlite3.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <syslog.h>

#pragma mark - Private API

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSURL *dataContainerURL;
@property (nonatomic, readonly) NSURL *bundleURL;
+ (LSApplicationProxy *)applicationProxyForIdentifier:(id)identifier;
@end

#pragma mark - Helper Functions

// Kill a system process by name, trying multiple killall paths
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

// Open a SQLite database, execute a block, checkpoint WAL, then close
static BOOL executeSQLiteOnDB(NSString *dbPath, void(^workBlock)(sqlite3 *db)) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) return NO;

    sqlite3 *db;
    if (sqlite3_open_v2([dbPath UTF8String], &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        syslog(LOG_ERR, "[MyAppWiper] Failed to open DB: %s (%s)",
               [dbPath UTF8String], db ? sqlite3_errmsg(db) : "null");
        if (db) sqlite3_close(db);
        return NO;
    }

    // Wait up to 5s if the database is locked by a daemon
    sqlite3_busy_timeout(db, 5000);

    workBlock(db);

    // Force WAL checkpoint so changes are persisted to the main database file
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

#pragma mark - 1. Process Kill (prevent memory write-back)

+ (void)killTargetApp:(NSString *)bundleID {
    LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    if (!proxy || !proxy.bundleURL) {
        syslog(LOG_ERR, "[MyAppWiper] killTargetApp: no bundleURL for %@", bundleID);
        return;
    }

    // Read CFBundleExecutable from Info.plist for accurate process name
    NSString *infoPlistPath = [proxy.bundleURL.path stringByAppendingPathComponent:@"Info.plist"];
    NSString *executableName = [[NSDictionary dictionaryWithContentsOfFile:infoPlistPath] objectForKey:@"CFBundleExecutable"];
    if (!executableName) {
        executableName = proxy.bundleURL.lastPathComponent.stringByDeletingPathExtension;
    }
    if (executableName.length == 0) return;

    killProcessByName([executableName UTF8String]);
}

#pragma mark - 2. Sandbox Container Wipe (including App Group)

+ (void)cleanSandboxForBundleID:(NSString *)bundleID {
    LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    if (!proxy || !proxy.dataContainerURL) {
        syslog(LOG_ERR, "[MyAppWiper] No data container for %@", bundleID);
        return;
    }

    NSString *dataPath = proxy.dataContainerURL.path;
    if (!dataPath || dataPath.length == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];

    // Clean standard sandbox subdirectories
    NSArray *subDirs = @[@"Documents", @"Library", @"tmp", @"SystemData", @"StoreKit"];
    for (NSString *subDir in subDirs) {
        NSString *targetDir = [dataPath stringByAppendingPathComponent:subDir];
        if (![fm fileExistsAtPath:targetDir]) continue;
        NSError *error = nil;
        NSArray *items = [fm contentsOfDirectoryAtPath:targetDir error:&error];
        for (NSString *item in items) {
            [fm removeItemAtPath:[targetDir stringByAppendingPathComponent:item] error:nil];
        }
    }

    // Clean App Group shared containers (many apps store critical data here)
    SEL groupSel = NSSelectorFromString(@"groupContainerURLs");
    if ([proxy respondsToSelector:groupSel]) {
        NSDictionary *groups = [proxy performSelector:groupSel];
        for (id value in [groups allValues]) {
            NSString *groupPath = nil;
            if ([value isKindOfClass:[NSURL class]]) {
                groupPath = [value path];
            } else if ([value isKindOfClass:[NSString class]]) {
                groupPath = value;
            }
            if (!groupPath || ![fm fileExistsAtPath:groupPath]) continue;
            NSError *error = nil;
            NSArray *items = [fm contentsOfDirectoryAtPath:groupPath error:&error];
            for (NSString *item in items) {
                [fm removeItemAtPath:[groupPath stringByAppendingPathComponent:item] error:nil];
            }
        }
    }

    syslog(LOG_NOTICE, "[MyAppWiper] Sandbox cleaned for %@", bundleID);

    // Kill cfprefsd to prevent cached preferences from being written back to disk
    killProcessByName("cfprefsd");
}

#pragma mark - 3. TCC Permission Reset

+ (void)resetAllPermissionsForBundleID:(NSString *)bundleID {
    NSArray *tccPaths = @[
        @"/var/mobile/Library/TCC/TCC.db",
        @"/var/jb/var/mobile/Library/TCC/TCC.db"
    ];

    for (NSString *dbPath in tccPaths) {
        executeSQLiteOnDB(dbPath, ^(sqlite3 *db) {
            // Use prepared statement (prevents SQL injection / special-char breakage)
            sqlite3_stmt *stmt;
            const char *sql = "DELETE FROM access WHERE client = ?";
            if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, [bundleID UTF8String], -1, SQLITE_TRANSIENT);
                int rc = sqlite3_step(stmt);
                syslog(LOG_NOTICE, "[MyAppWiper] TCC DELETE for %@ (%s, affected=%d)",
                       bundleID, sqlite3_errstr(rc), sqlite3_changes(db));
                sqlite3_finalize(stmt);
            } else {
                syslog(LOG_ERR, "[MyAppWiper] TCC prepare failed: %s", sqlite3_errmsg(db));
            }
        });
    }

    // Kill tccd so it reloads permissions from the database (not memory cache)
    killProcessByName("tccd");
    // Kill locationd for location permission cache
    killProcessByName("locationd");
}

#pragma mark - 4. Keychain Physical Wipe

+ (void)cleanKeychainForBundleID:(NSString *)bundleID {
    NSArray *keychainPaths = @[
        @"/var/Keychains/keychain-2.db",
        @"/private/var/Keychains/keychain-2.db"
    ];

    // Build LIKE pattern for matching access groups / services containing the bundle ID
    NSString *pattern = [NSString stringWithFormat:@"%%%@%%", bundleID];
    const char *patternUTF8 = [pattern UTF8String];

    for (NSString *dbPath in keychainPaths) {
        executeSQLiteOnDB(dbPath, ^(sqlite3 *db) {
            sqlite3_stmt *stmt;

            // Delete generic password entries
            const char *sqlGenp = "DELETE FROM genp WHERE agrp LIKE ? OR svce LIKE ?";
            if (sqlite3_prepare_v2(db, sqlGenp, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, patternUTF8, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 2, patternUTF8, -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                syslog(LOG_NOTICE, "[MyAppWiper] Keychain genp DELETE for %@ (affected=%d)",
                       bundleID, sqlite3_changes(db));
                sqlite3_finalize(stmt);
            }

            // Delete internet password entries
            const char *sqlInet = "DELETE FROM inet WHERE agrp LIKE ?";
            if (sqlite3_prepare_v2(db, sqlInet, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, patternUTF8, -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }
        });
    }

    // Kill securityd to force keychain reload from database
    killProcessByName("securityd");
}

@end
