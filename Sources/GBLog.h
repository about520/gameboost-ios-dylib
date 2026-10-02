//
//  GBLog.h
//
//  环形日志。免越狱环境下没法 attach lldb，日志面板就是唯一的调试手段，
//  所以这里保留最近 300 条并在悬浮窗里实时显示。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void GBLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// 最近 N 条日志（时间倒序不需要，按写入顺序）
NSArray<NSString *> *GBLogSnapshot(void);
void GBLogClear(void);

/// 把日志同时写到 App 沙盒 Documents/GameBoost.log，方便用 iMazing/爱思导出
void GBLogEnableFileOutput(void);

NS_ASSUME_NONNULL_END
