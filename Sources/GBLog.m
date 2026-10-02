//
//  GBLog.m
//

#import "GBLog.h"

static NSMutableArray<NSString *> *gLines = nil;
static NSLock *gLock = nil;
static NSFileHandle *gFile = nil;
static BOOL gFileOn = NO;
#define GB_LOG_MAX 300

__attribute__((constructor))
static void GBLogInit(void) {
    gLock  = [NSLock new];
    gLines = [NSMutableArray arrayWithCapacity:GB_LOG_MAX];
}

static NSString *GBTimestamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    return [fmt stringFromDate:[NSDate date]];
}

void GBLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *line = [NSString stringWithFormat:@"[%@] %@", GBTimestamp(), body];
    NSLog(@"[GameBoost] %@", line);

    [gLock lock];
    [gLines addObject:line];
    if (gLines.count > GB_LOG_MAX) {
        [gLines removeObjectsInRange:NSMakeRange(0, gLines.count - GB_LOG_MAX)];
    }
    if (gFileOn && gFile) {
        NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        @try { [gFile writeData:d]; } @catch (__unused NSException *e) {}
    }
    [gLock unlock];
}

NSArray<NSString *> *GBLogSnapshot(void) {
    [gLock lock];
    NSArray *copy = [gLines copy];
    [gLock unlock];
    return copy;
}

void GBLogClear(void) {
    [gLock lock];
    [gLines removeAllObjects];
    [gLock unlock];
}

void GBLogEnableFileOutput(void) {
    // 写到 App 自己的沙盒，不需要越狱权限。用 iMazing / 爱思助手 导出即可。
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return;
    NSString *path = [paths.firstObject stringByAppendingPathComponent:@"GameBoost.log"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    gFile = [NSFileHandle fileHandleForWritingAtPath:path];
    [gFile seekToEndOfFile];
    gFileOn = (gFile != nil);
    GBLog(@"日志文件输出已开启：%@", path);
}
