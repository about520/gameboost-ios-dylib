//
//  GBOverlay.h
//
//  悬浮窗。一个可拖拽的悬浮球，点开是控制面板。
//
//  关键点：整个覆盖层必须**点击穿透** —— 空白区域不能挡住游戏操作。
//  实现方式是 rootView 用 GBPassthroughView，hitTest 命中自己就返回 nil。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 显示悬浮窗（重复调用无副作用）
void GBOverlayShow(void);

/// 刷新面板上的控件状态（配置被外部改动后调用）
void GBOverlayRefresh(void);

/// 悬浮窗是否已经出现
BOOL GBOverlayIsVisible(void);

NS_ASSUME_NONNULL_END
