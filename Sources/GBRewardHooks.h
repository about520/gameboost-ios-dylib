//
//  GBRewardHooks.h
//
//  奖励翻倍。
//
//  做法：全量扫描进程内非系统类的实例方法，按 selector 关键词
//  （动词 + 资源名词）筛出「发奖方法」，再按方法签名分桶挂载 hook，
//  把第一个数值参数乘以倍率。
//
//  为什么按签名分桶：ObjC 没法写一个「万能」IMP 去接任意签名的方法。
//  如果签名对不上（比如返回 BOOL 却按 void 处理），调用方会读到垃圾 →
//  必然崩溃。所以必须严格匹配 return/arg 类型，不支持的签名就只记录不挂载。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 扫描并挂载奖励 hook。返回本次新挂载的数量（重复调用是幂等的）。
NSInteger GBInstallRewardHooks(void);

/// 当前已挂载的发奖方法数量
NSInteger GBHookCount(void);

NS_ASSUME_NONNULL_END
