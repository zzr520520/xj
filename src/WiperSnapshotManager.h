#import <Foundation/Foundation.h>
#import "WiperHelper.h"

@interface WiperSnapshotManager : NSObject

+ (NSString *)snapshotDirForBundleID:(NSString *)bundleID;
+ (NSArray<NSString *> *)savedSnapshotsForBundleID:(NSString *)bundleID;
+ (NSDictionary *)loadSnapshot:(NSString *)snapshotName forBundleID:(NSString *)bundleID;
+ (BOOL)saveCurrentConfigAsSnapshot:(NSString *)snapshotName forBundleID:(NSString *)bundleID;
+ (BOOL)deleteSnapshot:(NSString *)snapshotName forBundleID:(NSString *)bundleID;
+ (BOOL)applySnapshot:(NSString *)snapshotName forBundleID:(NSString *)bundleID;

@end
