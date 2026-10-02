//
//  GBAdHooks.m
//

#import "GBAdHooks.h"
#import "GBConfig.h"
#import "GBLog.h"
#import "GBRuntime.h"
#import "GBOverlay.h"
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

// ── 广告类名判定：强 / 弱两档，不能混用 ──────────────────────────
//
//  v1.2 的关键改动。
//  旧版只有一份 allow 列表，里面塞了 "splash"、"appopen"、"advert"、"adscene"
//  这些**弱特征**词，而匹配方式是 substring。结果：游戏自己的
//  SplashViewController / LoadingViewController（很多游戏真就叫这个名）
//  会被当成广告 VC 拦掉 → 点一下之后界面永远出不来 = 卡住。
//
//  现在分开：
//    强特征 → 只可能是 SDK 的广告对象，用于「拦截 / 隐藏 / 自动点击」这类有副作用的动作；
//    弱特征 → 只在用户显式打开「拦截弹窗广告」时才参与判定。

static NSArray<NSString *> *GBAdDenyTokens(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = @[@"banner", @"adapter", @"admanager", @"adconfiguration",
              @"adrequest", @"adloader", @"adcache", @"adconfig",
              @"adloader", @"testad", @"adpreload"];
    });
    return v;
}

/// 强特征：出现这些词基本可以断定是广告 SDK 的对象
static NSArray<NSString *> *GBStrongAdTokens(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = @[@"interstitial", @"rewarded", @"rewardvideo",
              @"fullscreenad", @"expressad", @"adviewcontroller",
              @"adplayer", @"videoad", @"splashad", @"adsplash",
              @"appopenad", @"adfullscreen", @"advert",
              @"launchad", @"openad", @"adshow"];
    });
    return v;
}

/// 弱特征：可能是广告，也可能是游戏自己的界面（必须由用户显式开启才用）
static NSArray<NSString *> *GBWeakAdTokens(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = @[@"splash", @"appopen", @"adscene", @"admodal", @"advertise"];
    });
    return v;
}

static BOOL GBNameHitsAny(NSString *lower, NSArray<NSString *> *tokens) {
    for (NSString *t in tokens) {
        if ([lower containsString:t]) return YES;
    }
    return NO;
}

/// 强判定：只认强特征，且不在排除表里。有副作用的动作一律走这里。
static BOOL GBIsStrongAdClass(NSString *name) {
    if (!name.length) return NO;
    NSString *s = name.lowercaseString;
    if ([s hasPrefix:@"gb"]) return NO;                 // 绝不碰自己的类
    if (GBNameHitsAny(s, GBAdDenyTokens())) return NO;
    return GBNameHitsAny(s, GBStrongAdTokens());
}

/// 弹窗拦截判定：强特征 + （用户已开启时才用的）弱特征
static BOOL GBIsAdClassForPresent(NSString *name) {
    if (GBIsStrongAdClass(name)) return YES;
    if (!name.length) return NO;
    NSString *s = name.lowercaseString;
    if ([s hasPrefix:@"gb"]) return NO;
    if (GBNameHitsAny(s, GBAdDenyTokens())) return NO;
    return GBNameHitsAny(s, GBWeakAdTokens());
}

// ═══════════════════════════════════════════════════════════════
//  补触发回调：广告 SDK 的 delegate 通知
// ═══════════════════════════════════════════════════════════════

// 回调分成两组，这很关键：
//
//   发奖组（grant）—— 告诉游戏「奖励到账」。开不开由用户决定。
//   结束组（close）—— 告诉游戏「广告播完了 / 关掉了」。
//
//   ★ 结束组是**必须发**的 ★
//   游戏几乎都是「展示广告 → 等结束回调 → 继续流程」。我们把展示吞掉之后
//   如果不发结束通知，游戏就会一直停在加载页等 —— 用户看到的正是
//   「点一下卡住」。所以拦截时无条件补发结束组，发奖组才跟开关走。
//
// 顺序有讲究：先「发奖励」，再「播放完成」，最后「已关闭」，
// 这是绝大多数 SDK 的正常时序，倒过来可能被游戏判为异常。
static NSArray<NSString *> *kGrantSelectors(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = @[
            // 穿山甲 / Pangle / BUAdSDK
            @"rewardedVideoAdServerRewardDidSucceed:verify:",
            // 优量汇 GDT
            @"gdt_rewardVideoAdDidRewardEffective:",
            // Unity Ads
            @"onRewardedVideoAdRewarded:",
            // AppLovin / MAX
            @"didReceiveRewardForPlacement:",
            // 快手 / 百度 / 通用命名
            @"onAdRewarded:",
            @"onAdReward:",
            @"onRewardVerify",
        ];
    });
    return v;
}

static NSArray<NSString *> *kCloseSelectors(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = @[
            // 穿山甲 / Pangle / BUAdSDK
            @"rewardedVideoAdDidPlayFinish:didFailWithError:",
            @"rewardedVideoAdDidClose:",
            @"rewardedVideoAdDidClose",
            // 优量汇 GDT
            @"gdt_rewardVideoAdDidPlayFinish:",
            @"gdt_rewardVideoAdDidClose:",
            // AdMob
            @"adDidPresentFullScreenContent:",
            @"adDidDismissFullScreenContent:",
            @"adDidDismissFullScreenContent",
            // Unity Ads
            @"onRewardedVideoAdClosed:",
            @"onUnityAdsDidFinish:withFinishState:",
            // AppLovin / MAX
            @"didHideAd:",
            // 快手 / 百度 / 通用命名
            @"onAdPlayFinish",
            @"onVideoEnd",
            @"onAdClose",
            @"onAdClosed",
            @"onAdPlayComplete",
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

    // 参数多于 2 个就不猜了：填错参数会让被调用方读到垃圾寄存器直接崩
    NSUInteger n = sig.numberOfArguments;
    if (n > 4) return NO;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = delegate;
    inv.selector = sel;

    // self(_cmd 之后) 的第 1 个参数：如果方法要参数，就把广告对象传进去
    if (n > 2 && context) {
        __unsafe_unretained id ctx = context;
        [inv setArgument:&ctx atIndex:2];
    }
    // 第 2 个参数常见是 verify/BOOL/error，给一个安全的默认值。
    // 统一用 8 字节槽位，避免对 1 字节的 BOOL 变量做越界读取。
    if (n > 3) {
        const char *t = [sig getArgumentTypeAtIndex:3];
        char kind = (t && t[0]) ? t[0] : 'q';
        if (kind == '@') {
            __unsafe_unretained id nilObj = nil;
            [inv setArgument:&nilObj atIndex:3];
        } else {
            long long slot = (kind == 'B' || kind == 'c') ? 1 : 0;
            [inv setArgument:&slot atIndex:3];
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

/// 已知选择器表全部没命中时的泛扫兜底。
///
/// 为什么需要：我们拦掉「展示」之后，游戏是在等「广告结束了」这类回调才继续走流程的。
/// 如果它用的是我们没收录的命名，就永远等不到 → 表现就是点一下之后卡在加载页。
/// 这里按生命周期关键词再扫一遍，只挑**无参或单参数、返回 void、名字以 on 开头
/// 或在 delegate 对象上**的方法，宁少不多。
static NSInteger GBFireGenericLifecycle(id adObject, NSArray *candidates,
                                        NSMutableSet<NSString *> *alreadyFired) {
    static NSArray *life = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        life = @[@"reward", @"finish", @"complete", @"close", @"dismiss",
                 @"skip", @"ended", @"fail"];
    });

    NSInteger fired = 0;
    for (id target in candidates) {
        if (fired >= 6) break;
        if (target == adObject) continue;        // 只在 delegate 侧泛扫，降低误伤

        unsigned int mc = 0;
        Method *ms = class_copyMethodList(object_getClass(target), &mc);
        if (!ms) continue;

        for (unsigned int i = 0; i < mc && fired < 6; i++) {
            SEL sel = method_getName(ms[i]);
            NSString *n = NSStringFromSelector(sel);
            if (!n.length || n.length > 60) continue;
            if ([alreadyFired containsObject:n]) continue;

            NSString *low = n.lowercaseString;
            if (![low hasPrefix:@"on"]) continue;      // 只认 delegate 风格命名

            BOOL hit = NO;
            for (NSString *k in life) {
                if ([low containsString:k]) { hit = YES; break; }
            }
            if (!hit) continue;

            const char *enc = method_getTypeEncoding(ms[i]);
            if (GBReturnType(enc) != 'v') continue;              // 只接 void
            char a0 = GBArgType(enc, 0);
            if (a0 != 0 && a0 != '@') continue;                  // 只接 无参 / 单对象参
            if (a0 == '@' && GBArgType(enc, 1) != 0) continue;   // 不能再有第二个参数

            if (GBInvokeDelegate(target, sel, adObject)) {
                fired++;
                GBLog(@"  泛扫补触发 → -[%@]", n);
            }
        }
        free(ms);
    }
    return fired;
}

/// 对广告对象（或其 delegate）补触发整套回调
///
/// includeGrant = NO 时仍然会发「结束组」—— 那是让游戏继续走下去的必要通知，
/// 只有在用户明确不想要假奖励时才不发「发奖组」。
static NSInteger GBFireAdCallbacks(id adObject, BOOL includeGrant) {
    if (!adObject) return 0;

    NSMutableArray *candidates = [NSMutableArray arrayWithObject:adObject];
    for (NSString *key in kDelegateKeys()) {
        id v = nil;
        @try { v = [adObject valueForKey:key]; } @catch (__unused NSException *e) {}
        if (v && v != adObject) [candidates addObject:v];
    }

    NSMutableArray<NSString *> *sequence = [NSMutableArray array];
    if (includeGrant) [sequence addObjectsFromArray:kGrantSelectors()];
    [sequence addObjectsFromArray:kCloseSelectors()];

    NSInteger fired = 0;
    NSMutableSet<NSString *> *done = [NSMutableSet set];
    for (id target in candidates) {
        for (NSString *selName in sequence) {
            SEL sel = NSSelectorFromString(selName);
            if (![target respondsToSelector:sel]) continue;
            if (GBInvokeDelegate(target, sel, adObject)) {
                fired++;
                [done addObject:selName];
                GBLog(@"  补触发 → %@ -[%@]",
                      NSStringFromClass(object_getClass(target)), selName);
            }
        }
    }

    // 两组选择器全军覆没 → 游戏用的多半是我们没收录的命名，起泛扫兜底
    if (fired == 0 && candidates.count > 1) {
        fired += GBFireGenericLifecycle(adObject, candidates, done);
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

    // ★ 无论开关如何都要补发「结束组」通知 ★
    //   游戏是在等「广告结束了」才继续走流程的；吞掉展示又不通知，
    //   它就会一直停在加载页 —— 这就是「点一下卡住」。
    //   发奖组才由 simulateRewardCallback 决定要不要发。
    NSInteger n = GBFireAdCallbacks(self, cfg.simulateRewardCallback);
    GBLog(@"  共补触发 %ld 个回调（%@发奖组）",
          (long)n, cfg.simulateRewardCallback ? @"" : @"仅结束组，未");

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

    // v1.2：只拦「展示」阶段，不再拦 load / request。
    // 拦加载阶段会让 SDK 的加载状态机停在半路，游戏等回调等到超时；
    // 广告照常下载但不播放，稳定性高得多。
    static NSArray *allow = nil;
    static dispatch_once_t o2;
    dispatch_once(&o2, ^{
        allow = @[@"show", @"present", @"display", @"play", @"render", @"open"];
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
//  L2：全局展示拦截（v1.2 起默认关闭，需手动开「拦截弹窗广告」）
// ═══════════════════════════════════════════════════════════════
//
//  为什么改成默认关：
//    这一层拦的是 -[UIViewController presentViewController:...]，它无法区分
//    「SDK 要弹的广告」和「游戏自己要弹的界面」—— 只要类名里有 splash /
//    appopen / advert 这类词就会被吞掉。表现就是：点一下，界面永远不出来。
//
//  另外删掉了原来那四行 beginAppearanceTransition / endAppearanceTransition：
//    对一个从未真正 present 过的 VC 手动跑一遍「出现→消失」时序，会让它的
//    _appearState 进入不一致状态；之后这个 VC（或它的同类实例）被正常弹出时
//    可能被 UIKit 静默拒绝 —— 又一个「卡住」的来源。

static void GBHook_presentVC(id self, SEL _cmd, UIViewController *vc,
                             BOOL animated, void (^completion)(void)) {
    GBConfig *cfg = [GBConfig shared];
    NSString *clsName = vc ? NSStringFromClass(object_getClass(vc)) : @"";

    if (cfg.masterEnabled && cfg.skipAds && cfg.interceptPresentVC &&
        GBIsAdClassForPresent(clsName)) {
        GBLog(@"拦截弹窗广告：%@（不展示）", clsName);

        // 同样必须补发「结束组」，否则游戏等回调等到超时
        NSInteger n = GBFireAdCallbacks(vc, cfg.simulateRewardCallback);
        GBLog(@"  共补触发 %ld 个回调", (long)n);
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

static NSMutableSet<NSValue *> *gTappedControls = nil;

static void GBMarkTapped(id view) {
    if (!gTappedControls) gTappedControls = [NSMutableSet set];
    if (gTappedControls.count > 200) [gTappedControls removeAllObjects];
    [gTappedControls addObject:[NSValue valueWithPointer:(const void *)view]];
}

static BOOL GBAlreadyTapped(id view) {
    if (!gTappedControls) return NO;
    return [gTappedControls containsObject:[NSValue valueWithPointer:(const void *)view]];
}

/// 沿响应链向上判断：这个控件是不是在广告容器里
static BOOL GBViewIsInAdContext(UIView *v) {
    if (!v) return NO;

    int depth = 0;
    for (UIView *cur = v; cur && depth < 24; cur = cur.superview, depth++) {
        if (GBIsStrongAdClass(NSStringFromClass(object_getClass(cur)))) return YES;
        UIResponder *r = cur.nextResponder;
        if ([r isKindOfClass:[UIViewController class]] &&
            GBIsStrongAdClass(NSStringFromClass(object_getClass(r)))) {
            return YES;
        }
    }

    UIWindow *w = v.window;
    if (!w) return NO;
    if (GBIsStrongAdClass(NSStringFromClass(object_getClass(w)))) return YES;

    UIViewController *top = w.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top && GBIsStrongAdClass(NSStringFromClass(object_getClass(top)))) return YES;

    return NO;
}

static BOOL GBViewLooksLikeCloseButton(UIView *v) {
    if (![v isKindOfClass:[UIControl class]]) return NO;
    if (v.hidden || v.alpha < 0.05) return NO;
    if (!v.window) return NO;

    // 绝不碰自己的悬浮窗 —— 面板里有个「立即关闭当前广告」按钮，
    // 旧版会被自己的扫描命中并回调进来，形成无限递归。
    UIWindow *mine = GBOverlayWindow();
    if (mine && v.window == mine) return NO;

    // 必须在强广告容器内，否则一律不动
    if (!GBViewIsInAdContext(v)) return NO;
    if (GBAlreadyTapped(v)) return NO;

    NSString *text = nil;
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)v;
        text = [btn currentTitle];
        if (!text.length) text = [btn titleForState:UIControlStateNormal];
    }
    if (!text.length) text = v.accessibilityLabel;
    if (!text.length) return NO;

    NSString *t = text.lowercaseString;
    if (t.length > 12) return NO;        // 关闭按钮文案都很短，长文案必是游戏 UI

    // ★ 去掉了单字符 "x" ★
    // 旧表里有 "x"，用 containsString: 匹配意味着任何含字母 x 的标题都会命中
    // （Next / Exit / Max / ×2 / Exp …），然后被自动点击，每 0.6 秒一次。
    static NSArray *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"×", @"✕", @"✖", @"╳", @"close", @"跳过", @"跳過",
                 @"关闭", @"关闭广告", @"skip", @"cancel"];
    });
    for (NSString *k in keys) {
        if ([t containsString:k]) return YES;
    }
    return NO;
}

static BOOL GBTapCloseButtonInView(UIView *v, int depth) {
    if (!v || depth > 12) return NO;
    if (GBViewLooksLikeCloseButton(v)) {
        GBMarkTapped(v);
        GBLog(@"兜底点击关闭按钮：%@", NSStringFromClass(object_getClass(v)));
        // 已经在主线程（定时器与面板按钮都挂在 main queue 上）
        [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    for (UIView *sub in v.subviews) {
        if (GBTapCloseButtonInView(sub, depth + 1)) return YES;
    }
    return NO;
}

/// deepScan = YES 时才会做「整棵视图树」的深扫。
/// 深扫要遍历所有 window 的全部子视图，放在游戏主线程上是有成本的，
/// 所以定时器里只每 5 个 tick 做一次；面板上的手动按钮则是立即深扫。
static void GBCloseAdViewsEx(BOOL deepScan) {
    // 重入保护：任何路径下都不允许自己套自己
    static BOOL running = NO;
    if (running) return;
    running = YES;

    UIWindow *mine = GBOverlayWindow();
    int tapped = 0;

    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (mine && w == mine) continue;           // 跳过自己的悬浮窗
        if (w.hidden || w.alpha < 0.01) continue;

        NSString *wName = NSStringFromClass(object_getClass(w));

        // 从最上层开始找 presented 链
        UIViewController *root = w.rootViewController;
        UIViewController *top = root;
        while (top.presentedViewController) top = top.presentedViewController;
        NSString *topName = top ? NSStringFromClass(object_getClass(top)) : @"";

        // 1) 顶层是强特征命中的广告 VC → dismiss
        if (top && top != root && GBIsStrongAdClass(topName)) {
            GBLog(@"兜底关闭广告 VC：%@", topName);
            [top dismissViewControllerAnimated:NO completion:nil];
            continue;
        }

        // 2) 整个 window 就是广告容器（开屏常见）→ 隐藏
        //    只在强特征下才动 —— 旧版含 "splash"，游戏自己的 SplashWindow 会被隐藏成黑屏
        if (GBIsStrongAdClass(wName)) {
            GBLog(@"兜底隐藏广告 window：%@", wName);
            w.hidden = YES;
            continue;
        }

        // 3) 兜底：在广告上下文里点掉「×/跳过/关闭」，一次调用最多点一个
        if (deepScan && tapped == 0 && GBTapCloseButtonInView(w, 0)) {
            tapped++;
        }
    }

    running = NO;
}

void GBCloseAdViewsNow(void) {
    GBCloseAdViewsEx(YES);
}

static void GBStartAutoCloseTimer(void) {
    static dispatch_source_t timer = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                  (uint64_t)(0.8 * NSEC_PER_SEC),
                                  (uint64_t)(0.15 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            GBConfig *cfg = [GBConfig shared];
            if (!cfg.masterEnabled || !cfg.closeAdViews) return;
            // 每 5 个 tick（约 4 秒）才做一次整树深扫，其余 tick 只做窗口/顶层 VC 判断
            static int tick = 0;
            tick++;
            GBCloseAdViewsEx((tick % 5) == 0);
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
    // v1.2：把裸的 Splash 换成 SplashAd。
    //   游戏自己的 SplashViewController / LaunchViewController 太常见了，
    //   旧正则会把它们一起收进来，再吞掉里面的 -startXxx / -showXxx，
    //   结果就是游戏卡在开屏界面进不去。
    NSArray<NSString *> *candidates = GBClassesMatching(
        @"(Interstitial|Rewarded|RewardVideo|VideoAd|SplashAd|AppOpenAd|Advert|FullScreenAd|ExpressAd|AdViewController|AdPlayer)");

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
