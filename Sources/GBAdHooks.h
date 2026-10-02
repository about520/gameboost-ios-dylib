//
//  GBAdHooks.h
//
//  广告跳过。
//
//  三层拦截（逐层兜底，任何一层生效就够）：
//    L1 SDK 级  —— 已知 SDK 的「展示」方法直接换成不发请求、不展示，
//                   然后手动补触发「已展示 → 已发奖励 → 已关闭」回调，
//                   这些回调是游戏用来发奖励的入口。
//    L2 通用级  —— hook -[UIViewController presentViewController:animated:completion:]，
//                   凡是类名像广告 VC 的一律拦住不回显，并补触发回调。
//    L3 兜底级  —— 定时扫描窗口层级，把已经弹出来的广告全屏视图里的
//                   「×/关闭/跳过」按钮点掉。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 安装广告相关 hook（L1 自动发现 + L2 展示拦截 + L3 兜底定时器）
NSInteger GBInstallAdHooks(void);

/// 立刻执行一次「关闭已弹出的广告」（供面板手动按钮调用）
void GBCloseAdViewsNow(void);

/// 让诊断功能能列出扫描到的广告类
NSArray<NSString *> *GBDetectedAdClasses(void);

NS_ASSUME_NONNULL_END
