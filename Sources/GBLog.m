//
//  GBLog.m
//
//  v1.2 改动（卡顿治理）：
//   1. 时间戳不再用 NSDateFormatter —— 它每次调用要 10~50 微秒，
//      游戏主循环里高频命中日志时会直接拖慢帧率。改成 gettimeofday + localtime_r。
//   2. 文件写入改成「内存缓冲 + 串行队列异步落盘」。
//      原来是持锁同步 writeData:，主线程被磁盘 IO 拖住就是「点一下卡一下」。
//   3. NSLog 限流（每秒最多 40 条）。NSLog 是同步写 stderr，
//      不限制会在高频命中时把主线程吃掉。
//

#import "GBLog.h"
#import <sys/time.h>
#import <time.h>

static NSMutableArray<NSString *> *gLines = nil;
static NSLock *gLock = nil;
static NSFileHandle *gFile = nil;
static NSMutableData *gFileBuf = nil;
static dispatch_queue_t gFileQueue = nil;
static dispatch_source_t gFlushTimer = nil;
static BOOL gFileOn = NO;

#define GB_LOG_MAX 300
#define GB_FILE_BUF_LIMIT (32 * 1024)
#define GB_NSLOG_PER_SEC 40

static CFAbsoluteTime gNslogWindowStart = 0;
static int gNslogInWindow = 0;

__attribute__((constructor))
static void GBLogInit(void) {
    gLock = [NSLock new];
    gLines = [NSMutableArray arrayWithCapacity:GB_LOG_MAX];
    gFileBuf = [NSMutableData data];
    gFileQueue = dispatch_queue_create("com.gameboost.logfile", DISPATCH_QUEUE_SERIAL);
}

/// 廉价时间戳。禁止换回 NSDateFormatter。
static NSString *GBTimestamp(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmv;
    time_t sec = (time_t)tv.tv_sec;
    localtime_r(&sec, &tmv);
    return [NSString stringWithFormat:@"%02d:%02d:%02d.%03d",
            tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000)];
}

static BOOL GBShouldNSLog(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gNslogWindowStart >= 1.0) {
        gNslogWindowStart = now;
        gNslogInWindow = 0;
    }
    gNslogInWindow++;
    return gNslogInWindow <= GB_NSLOG_PER_SEC;
}

/// 调用前必须已持有 gLock
static void GBFlushFileLocked(void) {
    if (!gFileOn || !gFile || gFileBuf.length == 0) return;

    NSData *payload = [gFileBuf copy];
    NSFileHandle *fh = gFile;
    [gFileBuf setLength:0];

    // 异步落盘：主线程只做一次 memcpy，不等磁盘
    dispatch_async(gFileQueue, ^{
        @try {
            [fh writeData:payload];
        } @catch (__unused NSException *e) {}
    });
}

void GBLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    BOOL nslog = GBShouldNSLog();

    [gLock lock];
    NSString *line = [NSString stringWithFormat:@"[%@] %@", GBTimestamp(), body];
    [gLines addObject:line];
    if (gLines.count > GB_LOG_MAX) {
        [gLines removeObjectsInRange:NSMakeRange(0, gLines.count - GB_LOG_MAX)];
    }
    if (gFileOn && gFile) {
        [gFileBuf appendData:[[line stringByAppendingString:@"\n"]
                                 dataUsingEncoding:NSUTF8StringEncoding]];
        if (gFileBuf.length >= GB_FILE_BUF_LIMIT) GBFlushFileLocked();
    }
    [gLock unlock];

    // NSLog 放在锁外，避免持锁做 IO
    if (nslog) NSLog(@"[GameBoost] %@", body);
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
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];

    [gLock lock];
    gFile = fh;
    gFileOn = (fh != nil);
    [gLock unlock];

    // 每秒把残留缓冲刷一次盘
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gFlushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gFileQueue);
        dispatch_source_set_timer(gFlushTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                  (uint64_t)(1.0 * NSEC_PER_SEC),
                                  (uint64_t)(0.2 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(gFlushTimer, ^{
            [gLock lock];
            GBFlushFileLocked();
            [gLock unlock];
        });
        dispatch_resume(gFlushTimer);
    });

    GBLog(@"日志文件输出已开启（异步缓冲落盘）：%@", path);
}
