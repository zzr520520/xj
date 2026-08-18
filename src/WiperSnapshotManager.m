#import "WiperSnapshotManager.h"

@implementation WiperSnapshotManager

+ (NSString *)snapshotDirForBundleID:(NSString *)bundleID {
    NSString *baseDir = [WiperHelper getConfigPathForBundleID:bundleID];
    NSString *dir = [[baseDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Snapshots"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:bundleID];
}

+ (NSArray<NSString *> *)savedSnapshotsForBundleID:(NSString *)bundleID {
    NSString *path = [self snapshotDirForBundleID:bundleID];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return @[];

    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:path error:&error];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *file in files) {
        if ([[file pathExtension] isEqualToString:@"plist"]) {
            [names addObject:[file stringByDeletingPathExtension]];
        }
    }
    return [names copy];
}

+ (NSDictionary *)loadSnapshot:(NSString *)snapshotName forBundleID:(NSString *)bundleID {
    NSString *path = [[self snapshotDirForBundleID:bundleID] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.plist", snapshotName]];
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

+ (BOOL)saveCurrentConfigAsSnapshot:(NSString *)snapshotName forBundleID:(NSString *)bundleID {
    NSString *currentConfigPath = [WiperHelper getConfigPathForBundleID:bundleID];
    NSDictionary *currentConfig = [NSDictionary dictionaryWithContentsOfFile:currentConfigPath];
    if (!currentConfig) return NO;

    NSString *path = [[self snapshotDirForBundleID:bundleID] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.plist", snapshotName]];
    return [currentConfig writeToFile:path atomically:YES];
}

+ (BOOL)deleteSnapshot:(NSString *)snapshotName forBundleID:(NSString *)bundleID {
    NSString *path = [[self snapshotDirForBundleID:bundleID] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.plist", snapshotName]];
    return [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

+ (BOOL)applySnapshot:(NSString *)snapshotName forBundleID:(NSString *)bundleID {
    NSDictionary *snapshot = [self loadSnapshot:snapshotName forBundleID:bundleID];
    if (!snapshot) return NO;

    NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
    NSString *dir = [configPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [snapshot writeToFile:configPath atomically:YES];
}

@end
