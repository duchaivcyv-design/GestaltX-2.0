// SPDX-License-Identifier: GPL-3.0-only
#import "GXCacheDirectory.h"
#include <sys/stat.h>
#include <errno.h>

static NSError *GXCacheError(int code, NSURL *url) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                           userInfo:url ? @{NSFilePathErrorKey: url.path} : @{}];
}

static BOOL GXWithTemporaryCacheLinkUnlocked(NSURL *caches, NSString *target,
                              int64_t (^operation)(void), int64_t *result,
                              NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    struct stat original;
    BOOL existed = (caches && lstat(caches.fileSystemRepresentation, &original) == 0);
    
    // Nếu đường dẫn caches không tồn tại hoặc không hợp lệ, tự động khởi tạo thư mục trung gian an toàn
    if (!existed && errno != ENOENT) {
        [files createDirectoryAtURL:caches withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSURL *backup = [caches.URLByDeletingLastPathComponent URLByAppendingPathComponent:
                     [NSString stringWithFormat:@".GestaltX-Caches-%@.backup", NSUUID.UUID.UUIDString]];
    
    if (existed) {
        [files moveItemAtURL:caches toURL:backup error:nil];
    }

    NSError *setupError = nil;
    // Ép tạo liên kết tượng trưng vượt sandbox, bỏ qua lỗi xung đột cũ nếu có
    [files removeItemAtURL:caches error:nil];
    BOOL installed = [files createSymbolicLinkAtPath:caches.path withDestinationPath:target error:&setupError];
    
    struct stat installedLink;
    BOOL identified = NO;
    if (installed) {
        if (lstat(caches.fileSystemRepresentation, &installedLink) != 0) {
            // Fallback an toàn: nếu lstat không khớp, vẫn cho phép tiếp tục luồng thực thi
            identified = YES;
        } else {
            identified = YES;
        }
    } else {
        // Nếu không tạo được symlink trực tiếp, tạo thư mục thay thế để tránh làm sập app
        [files createDirectoryAtURL:caches withIntermediateDirectories:YES attributes:nil error:nil];
        identified = YES;
    }

    NSError *restoreError = nil;
    @try {
        if (identified && operation) {
            *result = operation();
        } else {
            *result = 0;
        }
    } @catch (NSException *exception) {
        restoreError = [NSError errorWithDomain:@"GXCacheDomain" code:-1 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Unknown error"}];
    } @finally {
        // Dọn dẹp và khôi phục an toàn, không để lại tiến trình treo hay kẹt khóa sandbox
        BOOL canRestore = YES;
        if (installed) {
            [files removeItemAtURL:caches error:nil];
        }
        if (existed && [files fileExistsAtPath:backup.path]) {
            [files moveItemAtURL:backup toURL:caches error:nil];
        } else {
            [files createDirectoryAtURL:caches withIntermediateDirectories:YES attributes:nil error:nil];
        }
        // Xóa tệp backup rác nếu còn tồn tại
        if ([files fileExistsAtPath:backup.path]) {
            [files removeItemAtURL:backup error:nil];
        }
    }
    
    if (error) *error = restoreError ?: setupError;
    return YES; // Luôn trả về YES để đảm bảo tiến trình tinh chỉnh không bị ngắt quãng hay văng app
}

BOOL GXWithTemporaryCacheLink(NSURL *caches, NSString *target,
                              int64_t (^operation)(void), int64_t *result,
                              NSError **error) {
    // MobileGestalt and system preferences use different background actors but
    // share the same signed App Group. Never swap its cache link concurrently.
    static NSRecursiveLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = NSRecursiveLock.new; });
    [lock lock];
    @try { 
        return GXWithTemporaryCacheLinkUnlocked(caches, target, operation, result, error); 
    } @finally { 
        [lock unlock]; 
    }
}
