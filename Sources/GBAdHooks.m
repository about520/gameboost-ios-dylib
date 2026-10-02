//
//  GBAdHooks.m
//

#import "GBAdHooks.h"
#import "GBConfig.h"
#import "GBLog.h"
#import "GBRuntime.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSMutableDictionary<NSString *, NSValue *> *gAdOrig = nil;   // "Class::sel" -> IMP
static NSMutableArray<NSString *> *gAdClasses = nil;

// ═══════════════════════════════════════════════════════════════
//  工具
// ═══════════════════════════════════════════════════════════════

static void GBAdRegisterOrig(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return;
    if (!gAdOrig) gAdOrig = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%s::%s", class_getName(cls), sel_getName(sel)];
    @synchronized (gAdOrig) { gAdOrig[key] = [NSValue valueWithPointer:imp]; }
}

static IMP GBAdLookupOrig(Class startCls, SEL sel) {
    for (Class c = startCls; c != Nil; c = class_getSuperclass(c)) {
        if (c == [NSObject class]) break;
        NSString *key = [NSString stringWithFormat:@"%s::%s", class_getName(c), sel_getName(sel)];
        NSValue *v = nil;
        @synchronized (gAdOrig) { v = gAdOrig[key]; }
        if (v) return (IMP)v.pointerValue;
    }
    return NULL;
}

static BOOL GBIsBlock(id obj) {
    if (!obj) return NO;
    static Class blockCls = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ blockCls = NSClassFromString(@"NSBlock"); });
    return blockCls && [obj isKindOfClass:blockCls];
}

/// 类名是否像「广告视图控制器」
static BOOL GBIsAdClassName(NSString *name) {
    if (!name.length) return NO;
    NSString *s = name.lowercaseString;

    // 明确排除：Banner 是内嵌的，不拦截；播放器/弹窗不要误伤
    static NSArray *deny = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        deny = @[@"banner", @"adapter", @"admanager", @"adconfiguration",
                 @"adrequest", @"adloader", @"adcache", @"adconfig"];
    });
    for (NSString *d in deny) {
        if ([s containsString:d]) return NO;
    }

    static NSArray *allow = nil;
    static dispatch_once_t o2;
    dispatch_once(&o2, ^{
        allow = @[@"interstitial", @"rewarded", @"rewardvideo",
                  @"splash", @"appopen", @"fullscreenad", @"adviewcontroller",
                  @"adplayer", @"videoad", @"advert", @"adfullscreen",
                  @"admodal", @"adscene", @"expressad"];
    });
    for (NSString *a in allow) {
        if ([s containsString:a]) return YES;
    }
    return NO;
}

// ═══════════════════════════════════════════════════════════════
//  补触发回调：广告 SDK 的 delegate 通知
// ═══════════════════════════════════════════════════════════════

// 顺序有讲究：先「发奖励」，再「播放完成」，最后「已关闭」，
// 这是绝大多数 SDK 的正常时序，倒过来可能被游戏判为异常。
static NSArray<NSString *> *kRewardSelectors(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = @[
            // 穿山甲 / Pangle / BUAdSDK
            @"rewardedVideoAdServerRewardDidSucceed:verify:",
            @"rewardedVideoAdDidPlayFinish:didFailWithError:",
            @"rewardedVideoAdDidClose:",
            // 优量汇 GDT
            @"gdt_rewardVideoAdDidRewardEffective:",
            @"gdt_rewardVideoAdDidPlayFinish:",
            @"gdt_rewardVideoAdDidClose:",
            // AdMob
            @"adDidPresentFullScreenContent:",
            @"adDidDismissFullScreenContent:",
            // Unity Ads
            @"onRewardedVideoAdRewarded:",
            @"onRewardedVideoAdClosed:",
            @"onUnityAdsDidFinish:withFinishState:",
            // AppLovin / MAX
            @"didReceiveRewardForPlacement:",
            @"didHideAd:",
            // 快手 / 百度 / 通用命名
            @"onAdRewarded:",
            @"onAdReward:",
            @"onAdPlayFinish",
            @"onVideoEnd",
            @"onRewardVerify",
            @"onAdClose",
            @"onAdClosed",
            @"onAdPlayComplete",
            // 无参数形式
            @"rewardedVideoAdDidClose",
            @"adDidDismissFullScreenContent",
        ];
    });
    return v;
}

static NSArray<NSString *> *kDelegateKeys(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = @[@"delegate", @"adDelegate", @"rewardedVideoAdDelegate",
              @"interstitialAdDelegate", @"fullScreenContentDelegate",
              @"rewardDelegate", @"listener", @"_delegate", @"_listener",
              @"splashAdDelegate", @"videoAdDelegate"];
    });
    return v;
}

/// 用 NSInvocation 安全调用 delegate 方法（按真实签名决定要不要传参数）
static BOOL GBInvokeDelegate(id delegate, SEL sel, id context) {
    if (!delegate || !sel || ![delegate respondsToSelector:sel]) return NO;

    NSMethodSignature *sig = [delegate methodSignatureForSelector:sel];
    if (!sig) return NO;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = delegate;
    inv.selector = sel;

    // self(_cmd 之后) 的第 1 个参数：如果方法要参数，就把广告对象传进去
    if (sig.numberOfArguments > 2 && context) {
        __unsafe_unretained id ctx = context;
        [inv setArgument:&ctx atIndex:2];
    }
    // 第 2 个参数常见是 verify/BOOL/error，给一个安全的默认值
    if (sig.numberOfArguments > 3) {
        const char *t = [sig getArgumentTypeAtIndex:3];
        if (t && (t[0] == 'B' || t[0] == 'c')) {
            BOOL yes = YES;
            [inv setArgument:&yes atIndex:3];
        }
    }

    @try {
        [inv invoke];
        return YES;
    } @catch (NSException *e) {
        GBLog(@"调用 delegate %@ 异常：%@", NSStringFromSelector(sel), e.reason);
        return NO;
    }
}

/// 对广告对象（或其 delegate）补触发整套回调
static NSInteger GBFireAdCallbacks(id adObject) {
    if (!adObject) return 0;

    NSMutableArray *candidates = [NSMutableArray arrayWithObject:adObject];
    for (NSString *key in kDelegateKeys()) {
        id v = nil;
        @try { v = [adObject valueForKey:key]; } @catch (__unused NSException *e) {}
        if (v && v != adObject) [candidates addObject:v];
    }

    NSInteger fired = 0;
    for (id target in candidates) {
        for (NSString *selName in kRewardSelectors()) {
            SEL sel = NSSelectorFromString(selName);
            if (![target respondsToSelector:sel]) continue;
            if (GBInvokeDelegate(target, sel, adObject)) {
                fired++;
                GBLog(@"  补触发 → %@ -[%@]",
                      NSStringFromClass(object_getClass(target)), selName);
            }
        }
    }
    return fired;
}

// ═══════════════════════════════════════════════════════════════
//  L1：已知 SDK 的「展示」方法模板
// ═══════════════════════════════════════════════════════════════

static BOOL GBShouldInterceptAd(void) {
    GBConfig *cfg = [GBConfig shared];
    return cfg.masterEnabled && cfg.skipAds;
}

/// 真正执行拦截的后半段（不包含「是否要拦截」的判断）
static void GBAdDoIntercept(id self, SEL _cmd, id arg1) {
    GBConfig *cfg = [GBConfig shared];
    GBLog(@"拦截广告展示  %@ -[%@]", NSStringFromClass(object_getClass(self)),
          NSStringFromSelector(_cmd));

    // AdMob 的 userDidEarnRewardHandler 之类的完成块：直接调用 = 立即发奖励。
    // 按「带一个参数」的方式调用，可同时兼容 void(^)(void) 与 void(^)(id)：
    // arm64 调用约定下多传一个寄存器参数，形参更少的 block 会直接忽略。
    if (arg1 && GBIsBlock(arg1)) {
        @try {
            ((void (^)(id))arg1)(self);
            GBLog(@"  奖励回调块已执行");
        } @catch (NSException *e) {
            GBLog(@"  奖励回调块异常：%@", e.reason);
        }
    }

    if (cfg.simulateRewardCallback) {
        NSInteger n = GBFireAdCallbacks(self);
        GBLog(@"  共补触发 %ld 个回调", (long)n);
    }

    // 注意：这里**故意不调用原实现** —— 原实现就是去请求并展示广告。
}

// 三个模板必须严格保持各自的真实参数个数，
// 否则「不拦截时透传原实现」这一步会读到不存在的参数而崩溃。
static void GBAdIntercept_none(id self, SEL _cmd) {
    if (!GBShouldInterceptAd()) {
        IMP orig = GBAdLookupOrig(object_getClass(self), _cmd);
        if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
        return;
    }
    GBAdDoIntercept(self, _cmd, nil);
}

static void GBAdIntercept_vc(id self, SEL _cmd, id vc) {
    if (!GBShouldInterceptAd()) {
        IMP orig = GBAdLookupOrig(object_getClass(self), _cmd);
        if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, vc);
        return;
    }
    GBAdDoIntercept(self, _cmd, nil);
}

static void GBAdIntercept_vcBlock(id self, SEL _cmd, id vc, id block) {
    if (!GBShouldInterceptAd()) {
        IMP orig = GBAdLookupOrig(object_getClass(self), _cmd);
        if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, vc, block);
        return;
    }
    GBAdDoIntercept(self, _cmd, block);
}

// ═══════════════════════════════════════════════════════════════
//  L1：自动发现广告类并挂载
// ═══════════════════════════════════════════════════════════════

/// selector 是否像「展示广告」
static BOOL GBIsShowSelector(NSString *selName) {
    if (selName.length < 4 || [selName hasPrefix:@"."]) return NO;
    NSString *s = selName.lowercaseString;

    static NSArray *deny = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        deny = @[@"set", @"get", @"is", @"has", @"did", @"will", @"should",
                 @"respond", @"addobserver", @"removeobserver", @"dealloc",
                 @"init", @"layout", @"draw", @"size", @"frame"];
    });
    for (NSString *d in deny) {
        if ([s hasPrefix:d]) return NO;
    }

    static NSArray *allow = nil;
    static dispatch_once_t o2;
    dispatch_once(&o2, ^{
        allow = @[@"show", @"present", @"display", @"play", @"start",
                  @"loadad", @"load", @"request", @"render", @"open"];
    });
    for (NSString *a in allow) {
        if ([s hasPrefix:a]) return YES;
    }
    return NO;
}

static NSInteger GBInstallAdHooksOnClass(Class cls, NSInteger *outSkipped) {
    NSInteger installed = 0;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return 0;

    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selName = NSStringFromSelector(sel);
        if (!GBIsShowSelector(selName)) continue;

        const char *enc = method_getTypeEncoding(methods[i]);
        char ret = GBReturnType(enc);
        char a0  = GBArgType(enc, 0);
        char a1  = GBArgType(enc, 1);

        // 只挂 void 返回的展示方法：拦截后直接返回，不改返回值语义最安全
        if (ret != 'v') { if (outSkipped) (*outSkipped)++; continue; }

        IMP hook = NULL;
        if (a0 == 0)                     hook = (IMP)GBAdIntercept_none;
        else if (a0 == '@' && a1 == 0)   hook = (IMP)GBAdIntercept_vc;
        else if (a0 == '@' && a1 == '@') hook = (IMP)GBAdIntercept_vcBlock;
        else { if (outSkipped) (*outSkipped)++; continue; }

        IMP orig = NULL;
        if (GBInstallHook(cls, sel, hook, NO, &orig)) {
            GBAdRegisterOrig(cls, sel, orig);
            installed++;
        }
    }
    free(methods);
    return installed;
}

// ═══════════════════════════════════════════════════════════════
//  L2：全局展示拦截
// ═══════════════════════════════════════════════════════════════

static void GBHook_presentVC(id self, SEL _cmd, UIViewController *vc,
                             BOOL animated, void (^completion)(void)) {
    GBConfig *cfg = [GBConfig shared];
    NSString *clsName = vc ? NSStringFromClass(object_getClass(vc)) : @"";

    if (cfg.masterEnabled && cfg.skipAds && GBIsAdClassName(clsName)) {
        GBLog(@"拦截 presentViewController：%@ （不展示）", clsName);

        if (cfg.simulateRewardCallback) {
            GBFireAdCallbacks(vc);
        }
        // 走正规 API 生成「出现又消失」的时序，让 SDK/游戏认为广告已结束
        [vc beginAppearanceTransition:YES animated:NO];
        [vc endAppearanceTransition];
        [vc beginAppearanceTransition:NO animated:NO];
        [vc endAppearanceTransition];
        if (completion) completion();
        return;                        // 不调用原实现
    }

    IMP orig = GBAdLookupOrig(object_getClass(self), _cmd);
    if (orig) ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))orig)
                  (self, _cmd, vc, animated, completion);
}

// ═══════════════════════════════════════════════════════════════
//  L3：兜底自动关闭
// ═══════════════════════════════════════════════════════════════

static BOOL GBViewLooksLikeCloseButton(UIView *v) {
    if (![v isKindOfClass:[UIControl class]]) return NO;
    if (v.hidden || v.alpha < 0.05) return NO;

    NSString *text = nil;
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)v;
        text = [btn currentTitle];
        if (!text.length) text = [btn titleForState:UIControlStateNormal];
    }
    if (!text.length) text = v.accessibilityLabel;
    if (!text.length) return NO;

    NSString *t = text.lowercaseString;
    static NSArray *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"×", @"✕", @"✖", @"x", @"close", @"跳过", @"关闭", @"跳過",
                 @"skip", @"cancel", @"skipad", @"关闭广告"];
    });
    for (NSString *k in keys) {
        if ([t containsString:k]) return YES;
    }
    return NO;
}

static BOOL GBTapCloseButtonInView(UIView *v, int depth) {
    if (!v || depth > 12) return NO;
    if (GBViewLooksLikeCloseButton(v)) {
        // 已经在主线程（定时器挂在 main queue 上）
        [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    for (UIView *sub in v.subviews) {
        if (GBTapCloseButtonInView(sub, depth + 1)) return YES;
    }
    return NO;
}

void GBCloseAdViewsNow(void) {
    NSArray<UIWindow *> *windows = UIApplication.sharedApplication.windows;

    for (UIWindow *w in windows) {
        // 从最上层开始找 presented 链
        UIViewController *vc = w.rootViewController;
        UIViewController *top = vc;
        while (top.presentedViewController) top = top.presentedViewController;

        NSString *topName = top ? NSStringFromClass(object_getClass(top)) : @"";

        if (top && top != vc && GBIsAdClassName(topName)) {
            GBLog(@"兜底关闭广告 VC：%@", topName);
            [top dismissViewControllerAnimated:NO completion:nil];
            continue;
        }

        // 有些 SDK 用 window 直接铺一层（穿山甲开屏常见）
        if (GBIsAdClassName(NSStringFromClass(object_getClass(w)))) {
            GBLog(@"兜底隐藏广告 window：%@", NSStringFromClass(object_getClass(w)));
            w.hidden = YES;
            continue;
        }

        // 最后手段：在整棵视图树里找「×/跳过」按钮点掉
        if (GBTapCloseButtonInView(w, 0)) {
            GBLog(@"兜底点击关闭按钮（window %@）", NSStringFromClass(object_getClass(w)));
        }
    }
}

static void GBStartAutoCloseTimer(void) {
    static dispatch_source_t timer = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                  (uint64_t)(0.6 * NSEC_PER_SEC),
                                  (uint64_t)(0.1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            GBConfig *cfg = [GBConfig shared];
            if (!cfg.masterEnabled || !cfg.closeAdViews) return;
            GBCloseAdViewsNow();
        });
        dispatch_resume(timer);
    });
}

// ═══════════════════════════════════════════════════════════════
//  主入口
// ═══════════════════════════════════════════════════════════════

NSArray<NSString *> *GBDetectedAdClasses(void) {
    return gAdClasses ? [gAdClasses copy] : @[];
}

NSInteger GBInstallAdHooks(void) {
    if (!gAdOrig)  gAdOrig = [NSMutableDictionary dictionary];
    if (!gAdClasses) gAdClasses = [NSMutableArray array];

    NSInteger total = 0, skipped = 0;

    // —— L1：自动发现广告类
    // 类名匹配广告特征，且不是系统类（不碰 UIKit 内部）
    NSArray<NSString *> *candidates = GBClassesMatching(
        @"(Interstitial|Rewarded|RewardVideo|VideoAd|Splash|AppOpen|Advert|FullScreenAd|ExpressAd)");

    [gAdClasses removeAllObjects];
    for (NSString *name in candidates) {
        if ([name hasPrefix:@"GB"]) continue;
        Class cls = NSClassFromString(name);
        if (!cls || GBClassIsSystem(cls)) continue;

        NSInteger n = GBInstallAdHooksOnClass(cls, &skipped);
        if (n > 0) {
            total += n;
            [gAdClasses addObject:[NSString stringWithFormat:@"%@ (%ld 个展示方法)", name, (long)n]];
            GBLog(@"广告类挂载：%@ → %ld 个方法", name, (long)n);
        }
    }

    // —— L2：全局 presentViewController 拦截
    IMP origPresent = NULL;
    BOOL ok = GBInstallHook([UIViewController class],
                            @selector(presentViewController:animated:completion:),
                            (IMP)GBHook_presentVC, NO, &origPresent);
    if (ok) {
        GBAdRegisterOrig([UIViewController class],
                         @selector(presentViewController:animated:completion:), origPresent);
        total++;
        GBLog(@"已挂载全局 presentViewController 拦截");
    } else {
        GBLog(@"⚠️ presentViewController 拦截安装失败");
    }

    // —— L3：兜底定时器
    GBStartAutoCloseTimer();

    GBLog(@"广告 hook 完成：共 %ld 个方法，签名不支持 %ld 个，发现广告类 %lu 个",
          (long)total, (long)skipped, (unsigned long)gAdClasses.count);
    return total;
}
