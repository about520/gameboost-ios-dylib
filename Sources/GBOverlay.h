//
//  GBOverlay.h
//
//  悬浮窗。一个可拖拽的悬浮球，点开是控制面板。
//
//  关键点：整个覆盖层必须**点击穿透** —— 空白区域不能挡住游戏操作。
//  穿透必须做在两层上，缺一不可：
//    1) UIWindow 层：GBPassthroughWindow，hitTest 命中窗口自己就返回 nil；
//    2) rootView 层：GBPassthroughView，命中自己就返回 nil。
//  只做 rootView 那一层是不够的 —— UIView.hitTest 在无子视图命中时会返回
//  self，而窗口 bounds 就是整屏，于是窗口会把所有触摸吃掉，游戏整屏点不动。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 显示悬浮窗（重复调用无副作用）
void GBOverlayShow(void);

/// 刷新面板上的控件状态（配置被外部改动后调用）
void GBOverlayRefresh(void);

/// 悬浮窗是否已经出现
BOOL GBOverlayIsVisible(void);

/// 临时隐藏整个悬浮窗（seconds 秒后自动恢复）。
/// 用于悬浮球挡住游戏按钮（比如登录按钮）时的应急逃生通道。
void GBOverlaySetHiddenTemporarily(NSTimeInterval seconds);

/// 把悬浮球挪回屏幕右侧的安全位置并持久化
void GBOverlayResetBallPosition(void);

NS_ASSUME_NONNULL_END
