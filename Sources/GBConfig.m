//
//  GBConfig.m
//

#import "GBConfig.h"
#import <UIKit/UIKit.h>

NSString *const kGBMaster        = @"gb.master";
NSString *const kGBSkipAds       = @"gb.skipAds";
NSString *const kGBCloseAdViews  = @"gb.closeAdViews";
NSString *const kGBSimulateReward= @"gb.simulateReward";
NSString *const kGBInterceptPresent = @"gb.interceptPresent";
NSString *const kGBEnforceReward = @"gb.enforceReward";
NSString *const kGBRepeatNoArg   = @"gb.repeatNoArg";
NSString *const kGBMultiplier    = @"gb.multiplier";
static NSString *const kGBBallX  = @"gb.ball.x";
static NSString *const kGBBallY  = @"gb.ball.y";
static NSString *const kGBBallHas= @"gb.ball.has";

@implementation GBConfig

+ (instancetype)shared {
    static GBConfig *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [GBConfig new];
        [inst load];
    });
    return inst;
}

- (void)load {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    // 首次运行写入默认值：总开关开、跳过广告开、翻倍开但“只记录不改写”，避免误伤存档
    if ([d objectForKey:kGBMaster] == nil) {
        [d setBool:YES forKey:kGBMaster];
        [d setBool:YES forKey:kGBSkipAds];
        [d setBool:NO  forKey:kGBCloseAdViews];
        [d setBool:YES forKey:kGBSimulateReward];
        [d setBool:NO  forKey:kGBEnforceReward];   // 默认只探测，不真改数值
        [d setBool:NO  forKey:kGBRepeatNoArg];
        [d setInteger:2 forKey:kGBMultiplier];
    }
    // v1.2 新增项：老版本升级上来的设备不会走到上面的分支，单独补一次默认值
    if ([d objectForKey:kGBInterceptPresent] == nil) {
        [d setBool:NO forKey:kGBInterceptPresent];   // 拦截弹窗容易误伤，默认关闭
    }

    _masterEnabled          = [d boolForKey:kGBMaster];
    _skipAds                = [d boolForKey:kGBSkipAds];
    _closeAdViews           = [d boolForKey:kGBCloseAdViews];
    _simulateRewardCallback = [d boolForKey:kGBSimulateReward];
    _interceptPresentVC     = [d boolForKey:kGBInterceptPresent];
    _enforceReward          = [d boolForKey:kGBEnforceReward];
    _repeatNoArgGrants      = [d boolForKey:kGBRepeatNoArg];
    _multiplier             = MAX(1, [d integerForKey:kGBMultiplier]);

    _hookedRewardMethods = [NSMutableArray array];
    _detectedAdClasses   = [NSMutableArray array];

    CGFloat x = [d floatForKey:kGBBallX];
    CGFloat y = [d floatForKey:kGBBallY];
    _hasBallCenter = [d boolForKey:kGBBallHas];
    _ballCenter = CGPointMake(x, y);
}

- (void)setMasterEnabled:(BOOL)v              { _masterEnabled = v;          [self sync]; }
- (void)setSkipAds:(BOOL)v                    { _skipAds = v;                [self sync]; }
- (void)setCloseAdViews:(BOOL)v               { _closeAdViews = v;           [self sync]; }
- (void)setSimulateRewardCallback:(BOOL)v     { _simulateRewardCallback = v; [self sync]; }
- (void)setInterceptPresentVC:(BOOL)v         { _interceptPresentVC = v;     [self sync]; }
- (void)setEnforceReward:(BOOL)v              { _enforceReward = v;          [self sync]; }
- (void)setRepeatNoArgGrants:(BOOL)v          { _repeatNoArgGrants = v;      [self sync]; }
- (void)setMultiplier:(NSInteger)m            { _multiplier = MAX(1, MIN(20, m)); [self sync]; }

- (void)sync {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:_masterEnabled          forKey:kGBMaster];
    [d setBool:_skipAds                forKey:kGBSkipAds];
    [d setBool:_closeAdViews           forKey:kGBCloseAdViews];
    [d setBool:_simulateRewardCallback forKey:kGBSimulateReward];
    [d setBool:_interceptPresentVC     forKey:kGBInterceptPresent];
    [d setBool:_enforceReward          forKey:kGBEnforceReward];
    [d setBool:_repeatNoArgGrants      forKey:kGBRepeatNoArg];
    [d setInteger:_multiplier          forKey:kGBMultiplier];
}

- (NSInteger)effectiveMultiplier {
    if (!_masterEnabled) return 1;
    if (!_enforceReward) return 1;   // 未启用以改写，倍率无效
    return MAX(1, _multiplier);
}

- (void)saveBallCenter {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setFloat:_ballCenter.x forKey:kGBBallX];
    [d setFloat:_ballCenter.y forKey:kGBBallY];
    [d setBool:YES           forKey:kGBBallHas];
}

@end
