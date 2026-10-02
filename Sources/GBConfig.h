//
//  GBConfig.h
//  GameBoost —— iOS 免越狱 dylib 插件
//
//  全局配置：开关 + 倍率，全部持久化到 NSUserDefaults。
//  面板上的每个开关都会实时生效（hook 内部每次都读配置，不缓存）。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// —— 总开关
extern NSString *const kGBMaster;          // 插件总开关

// —— 广告
extern NSString *const kGBSkipAds;         // 跳过广告（拦截展示 + 补触发回调）
extern NSString *const kGBCloseAdViews;    // 兜底：自动关闭已弹出的广告全屏视图
extern NSString *const kGBSimulateReward;  // 拦截广告时补发“已获得奖励”回调

// —— 奖励
extern NSString *const kGBEnforceReward;   // 真正改写奖励数值（关闭时只记录不改）
extern NSString *const kGBRepeatNoArg;     // 无参数的发奖方法重复调用 N 次
extern NSString *const kGBMultiplier;      // 倍率 2~20

@interface GBConfig : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) BOOL masterEnabled;
@property (nonatomic, assign) BOOL skipAds;
@property (nonatomic, assign) BOOL closeAdViews;
@property (nonatomic, assign) BOOL simulateRewardCallback;
@property (nonatomic, assign) BOOL enforceReward;
@property (nonatomic, assign) BOOL repeatNoArgGrants;
@property (nonatomic, assign) NSInteger multiplier;

// 面板拖动位置持久化
@property (nonatomic, assign) CGPoint ballCenter;
@property (nonatomic, assign) BOOL hasBallCenter;

// 一批已挂载的奖励方法（用于面板展示 / 诊断）
@property (nonatomic, strong) NSMutableArray<NSString *> *hookedRewardMethods;
@property (nonatomic, strong) NSMutableArray<NSString *> *detectedAdClasses;

// 取有效倍率：总开关或翻倍关闭时返回 1
- (NSInteger)effectiveMultiplier;

@end

NS_ASSUME_NONNULL_END
