//
//  GBEntry.m
//
//  插件入口。injected dylib 的 constructor 在 dyld 加载时就会执行，
//  但那时 App 的 UIWindowScene 还没起来，所以要轮询等待。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>
#import "GBConfig.h"
#import "GBLog.h"
#import "GBAdHooks.h"
#import "GBRewardHooks.h"
#import "GBOverlay.h"
#import "GBRuntime.h"

static BOOL gBooted = NO;
static int  gBootTries = 0;

static BOOL GBHasActiveScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                return YES;
            }
        }
        return NO;
    }
    return UIApplication.sharedApplication.keyWindow != nil;
}

static void GBEntryBoot(void);

/// 游戏可能会自己新建 window 并置顶，这时把悬浮窗重新抬上来
static void GBInstallWindowGuard(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    Class cls = [UIWindow class];
    SEL sel = @selector(makeKeyAndVisible);
    // 必须用 __block，否则 block 捕获的是创建时的 NULL，守卫里就调不到原实现
    __block IMP orig = NULL;

    void (^guard)(id, SEL) = ^(id self, SEL _cmd) {
        if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
        // 只在已经有悬浮窗时刷新一下，保证它还在最上层
        if (GBOverlayIsVisible()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                GBOverlayRefresh();
            });
        }
    };

    IMP imp = imp_implementationWithBlock(guard);
    if (GBInstallHook(cls, sel, imp, NO, &orig)) {
        GBLog(@"已挂载 window 层级守卫");
    } else {
        imp_removeBlock(imp);
    }
}

// ═══════════════════════════════════════════════════════════════
//  主线程看门狗
// ═══════════════════════════════════════════════════════════════
//
//  免越狱环境既没有 crash log 也没法 attach lldb。万一某个 hook 把主线程
//  拖住，用户看到的就只有「点一下卡住」而且毫无反馈。
//
//  这里从独立后台队列定时 ping 主队列：连续 10 秒收不到回应，
//  就自动关掉两个最容易出问题的功能并写日志，让游戏能自己缓过来。

static CFAbsoluteTime gLastPong = 0;
static volatile BOOL   gPongFlag = NO;

static void GBStartMainThreadWatchdog(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_queue_create("com.gameboost.watchdog",
                                                   DISPATCH_QUEUE_SERIAL);
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(t,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                                  (uint64_t)(2.0 * NSEC_PER_SEC),
                                  (uint64_t)(0.5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(t, ^{
            // 退到后台时主线程本来就不跑，不能误判
            if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
                gLastPong = 0;
                return;
            }

            gPongFlag = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                gPongFlag = YES;
                gLastPong = CFAbsoluteTimeGetCurrent();
            });

            usleep(1500 * 1000);      // 给主线程 1.5 秒回应

            if (gPongFlag) return;

            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (gLastPong <= 0) { gLastPong = now; return; }
            if (now - gLastPong < 10.0) return;

            GBConfig *cfg = [GBConfig shared];
            if (cfg.closeAdViews || cfg.interceptPresentVC) {
                cfg.closeAdViews = NO;
                cfg.interceptPresentVC = NO;
                GBLog(@"⚠️ 主线程连续 %.0f 秒无响应，已自动关闭「兜底关闭广告」与「拦截弹窗广告」",
                      now - gLastPong);
            } else {
                GBLog(@"⚠️ 主线程连续 %.0f 秒无响应（危险功能已是关闭状态）", now - gLastPong);
            }
            gLastPong = now;
        });
        dispatch_resume(t);
    });
}

static void GBEntryBoot(void) {
    gBootTries++;

    if (!GBHasActiveScene() && gBootTries < 80) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ GBEntryBoot(); });
        return;
    }

    if (gBooted) return;
    gBooted = YES;

    GBLogEnableFileOutput();
    GBLog(@"================ GameBoost v1.2 启动 ================");
    GBLog(@"进程：%@  (pid %d)",
          NSProcessInfo.processInfo.processName, getpid());
    GBLog(@"主类：%@", NSProcessInfo.processInfo.arguments.firstObject);
    GBLog(@"启动等待：%d 次轮询", gBootTries);

    // 广告 hook 需要碰 UIViewController，放主线程更稳
    GBInstallAdHooks();

    // 奖励扫描要遍历全部类和方法。本来就很重，再叠在游戏启动最忙的时候
    // 会明显拖慢首屏，所以延后 2 秒 + 放后台线程。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            GBInstallRewardHooks();
            dispatch_async(dispatch_get_main_queue(), ^{
                GBLog(@"奖励 hook 已就绪，共挂载 %lu 个（悬浮窗可查看命中情况）",
                      (unsigned long)GBInstalledHookCount());
            });
        });
    });

    GBInstallWindowGuard();
    GBOverlayShow();
    GBStartMainThreadWatchdog();

    GBLog(@"提示：奖励翻倍默认只记录不修改；确认目标后再打开「启用改写数值」");
}

__attribute__((constructor))
static void GBEntryInit(void) {
    @autoreleasepool {
        NSLog(@"[GameBoost] dylib loaded, waiting for app...");
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                GBEntryBoot();
            });
        });
    }
}
