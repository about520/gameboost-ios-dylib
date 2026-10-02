//
//  GBEntry.m
//
//  插件入口。injected dylib 的 constructor 在 dyld 加载时就会执行，
//  但那时 App 的 UIWindowScene 还没起来，所以要轮询等待。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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
    GBLog(@"================ GameBoost 启动 ================");
    GBLog(@"进程：%@  (pid %d)",
          NSProcessInfo.processInfo.processName, getpid());
    GBLog(@"主类：%@", NSProcessInfo.processInfo.arguments.firstObject);
    GBLog(@"启动等待：%d 次轮询", gBootTries);

    // 广告 hook 需要碰 UIViewController，放主线程更稳
    GBInstallAdHooks();

    // 奖励扫描要遍历全部类和方法，放后台线程避免卡启动
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        GBInstallRewardHooks();
        dispatch_async(dispatch_get_main_queue(), ^{
            GBLog(@"奖励 hook 已就绪，悬浮窗可查看命中情况");
        });
    });

    GBInstallWindowGuard();
    GBOverlayShow();

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
