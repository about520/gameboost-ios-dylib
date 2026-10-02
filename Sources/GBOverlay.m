//
//  GBOverlay.m
//

#import "GBOverlay.h"
#import "GBConfig.h"
#import "GBLog.h"
#import "GBAdHooks.h"
#import "GBRewardHooks.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static UIWindow *gOverlayWindow = nil;

// ═══════════════════════════════════════════════════════════════
//  点击穿透容器
// ═══════════════════════════════════════════════════════════════

@interface GBPassthroughView : UIView
@end

@implementation GBPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    // 命中自己 = 落在空白区域 → 返回 nil，事件透传给下层游戏
    return (v == self) ? nil : v;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *sub in self.subviews) {
        if (!sub.hidden && sub.alpha > 0.01 &&
            [sub pointInside:[sub convertPoint:point fromView:self] withEvent:event]) {
            return YES;
        }
    }
    return NO;
}
@end

// ═══════════════════════════════════════════════════════════════
//  悬浮球
// ═══════════════════════════════════════════════════════════════

@interface GBBallView : UIView
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation GBBallView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:0.10 green:0.55 blue:0.98 alpha:0.92];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 6;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;

        UILabel *icon = [[UILabel alloc] initWithFrame:self.bounds];
        icon.text = @"🎮";
        icon.font = [UIFont systemFontOfSize:24];
        icon.textAlignment = NSTextAlignmentCenter;
        icon.userInteractionEnabled = NO;
        [self addSubview:icon];

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)handleTap {
    if (self.onTap) self.onTap();
}

@end

// ═══════════════════════════════════════════════════════════════
//  控制面板
// ═══════════════════════════════════════════════════════════════

@interface GBPanelView : UIView
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UISwitch  *swMaster;
@property (nonatomic, strong) UISwitch  *swSkip;
@property (nonatomic, strong) UISwitch  *swSim;
@property (nonatomic, strong) UISwitch  *swClose;
@property (nonatomic, strong) UISwitch  *swEnforce;
@property (nonatomic, strong) UISwitch  *swRepeat;
@property (nonatomic, strong) UISlider  *slider;
@property (nonatomic, strong) UILabel   *sliderLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSTimer   *logTimer;
- (void)rebuild;
- (void)refreshFromConfig;
- (void)refreshLog;
@end

@implementation GBPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.94];
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        self.clipsToBounds = YES;

        _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
        _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_scroll];

        [self rebuild];
    }
    return self;
}

- (UILabel *)titleLabel:(NSString *)text y:(CGFloat)y {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, y, self.bounds.size.width - 28, 22)];
    l.text = text;
    l.textColor = [UIColor colorWithWhite:1 alpha:0.95];
    l.font = [UIFont boldSystemFontOfSize:15];
    [_scroll addSubview:l];
    return l;
}

- (UILabel *)sectionLabel:(NSString *)text y:(CGFloat)y {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, y, self.bounds.size.width - 28, 20)];
    l.text = text;
    l.textColor = [UIColor colorWithRed:0.35 green:0.78 blue:1 alpha:1];
    l.font = [UIFont boldSystemFontOfSize:12];
    [_scroll addSubview:l];
    return l;
}

- (UISwitch *)addSwitchRow:(NSString *)title
                    detail:(NSString *)detail
                         y:(CGFloat)y
                    action:(SEL)action
                    isOn:(BOOL)isOn {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, y, self.bounds.size.width - 90, 20)];
    l.text = title;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:14];
    [_scroll addSubview:l];

    if (detail.length) {
        UILabel *d = [[UILabel alloc] initWithFrame:CGRectMake(14, y + 18, self.bounds.size.width - 90, 16)];
        d.text = detail;
        d.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        d.font = [UIFont systemFontOfSize:11];
        d.numberOfLines = 2;
        [_scroll addSubview:d];
    }

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(self.bounds.size.width - 66, y + 2, 51, 31)];
    sw.on = isOn;
    sw.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:sw];

    return sw;
}

- (UIButton *)button:(NSString *)title y:(CGFloat)y action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(14, y, self.bounds.size.width - 28, 34);
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    b.layer.cornerRadius = 8;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:b];
    return b;
}

- (void)rebuild {
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];

    GBConfig *cfg = [GBConfig shared];
    CGFloat w = self.bounds.size.width;
    CGFloat y = 10;

    [self titleLabel:@"GameBoost  v1.0" y:y]; y += 26;
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(14, y, w - 28, 16)];
    sub.text = @"长按小球拖动 · 点击小球折叠";
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    sub.font = [UIFont systemFontOfSize:10];
    [_scroll addSubview:sub];
    y += 24;

    // —— 广告
    [self sectionLabel:@"广告" y:y]; y += 22;
    self.swMaster  = [self addSwitchRow:@"插件总开关" detail:@"关掉后所有 hook 直接透传原实现"
                                      y:y action:@selector(onMaster:) isOn:cfg.masterEnabled]; y += 46;
    self.swSkip    = [self addSwitchRow:@"跳过广告" detail:@"拦截展示，不发广告请求"
                                      y:y action:@selector(onSkipAds:) isOn:cfg.skipAds]; y += 46;
    self.swSim     = [self addSwitchRow:@"补发奖励回调" detail:@"模拟 已发奖 / 已关闭 通知给游戏"
                                      y:y action:@selector(onSimReward:) isOn:cfg.simulateRewardCallback]; y += 46;
    self.swClose   = [self addSwitchRow:@"兜底关闭广告" detail:@"定时轮询，自动点掉 × / 跳过"
                                      y:y action:@selector(onCloseAd:) isOn:cfg.closeAdViews]; y += 50;

    // —— 奖励
    [self sectionLabel:@"奖励翻倍" y:y]; y += 22;
    self.swEnforce = [self addSwitchRow:@"启用改写数值" detail:@"默认只记录不修改，确认目标后再开"
                                      y:y action:@selector(onEnforce:) isOn:cfg.enforceReward]; y += 52;
    self.swRepeat  = [self addSwitchRow:@"无参发奖重复调用" detail:@"-claimReward 这类无参方法按倍率重复调"
                                      y:y action:@selector(onRepeat:) isOn:cfg.repeatNoArgGrants]; y += 50;

    _sliderLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y, w - 28, 18)];
    _sliderLabel.text = [NSString stringWithFormat:@"倍率：x%ld", (long)cfg.multiplier];
    _sliderLabel.textColor = UIColor.whiteColor;
    _sliderLabel.font = [UIFont systemFontOfSize:13];
    [_scroll addSubview:_sliderLabel]; y += 20;

    _slider = [[UISlider alloc] initWithFrame:CGRectMake(14, y, w - 28, 28)];
    _slider.minimumValue = 2;
    _slider.maximumValue = 20;
    _slider.value = cfg.multiplier;
    _slider.continuous = NO;
    [_slider addTarget:self action:@selector(onSlider:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:_slider]; y += 40;

    // —— 操作
    [self sectionLabel:@"操作" y:y]; y += 22;
    [self button:@"重新扫描并挂载 hook" y:y action:@selector(onRescan:)]; y += 40;
    [self button:@"立即关闭当前广告" y:y action:@selector(onCloseNow:)]; y += 40;
    [self button:@"输出诊断信息" y:y action:@selector(onDiag:)]; y += 40;
    [self button:@"清空日志" y:y action:@selector(onClearLog:)]; y += 44;

    // —— 日志
    [self sectionLabel:@"运行日志" y:y]; y += 20;
    _logView = [[UITextView alloc] initWithFrame:CGRectMake(12, y, w - 24, 200)];
    _logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _logView.textColor = [UIColor colorWithRed:0.6 green:0.95 blue:0.6 alpha:1];
    _logView.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    _logView.editable = NO;
    _logView.scrollEnabled = YES;
    _logView.layer.cornerRadius = 8;
    [_scroll addSubview:_logView];
    y += 210;

    _scroll.contentSize = CGSizeMake(w, y);

    [self refreshFromConfig];
    [self refreshLog];
}

- (void)refreshFromConfig {
    GBConfig *cfg = [GBConfig shared];
    self.swMaster.on  = cfg.masterEnabled;
    self.swSkip.on    = cfg.skipAds;
    self.swSim.on     = cfg.simulateRewardCallback;
    self.swClose.on   = cfg.closeAdViews;
    self.swEnforce.on = cfg.enforceReward;
    self.swRepeat.on  = cfg.repeatNoArgGrants;
    self.slider.value = cfg.multiplier;
    self.sliderLabel.text = [NSString stringWithFormat:@"倍率：x%ld", (long)cfg.multiplier];
}

- (void)refreshLog {
    NSArray<NSString *> *lines = GBLogSnapshot();
    NSUInteger from = lines.count > 120 ? lines.count - 120 : 0;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = from; i < lines.count; i++) {
        [s appendString:lines[i]];
        [s appendString:@"\n"];
    }
    _logView.text = s;
    if (s.length > 0) {
        [_logView scrollRangeToVisible:NSMakeRange(s.length - 1, 1)];
    }
}

// —— actions

- (void)onMaster:(UISwitch *)sw   { [GBConfig shared].masterEnabled = sw.on; GBLog(@"总开关：%@", sw.on ? @"开" : @"关"); }
- (void)onSkipAds:(UISwitch *)sw  { [GBConfig shared].skipAds = sw.on; GBLog(@"跳过广告：%@", sw.on ? @"开" : @"关"); }
- (void)onSimReward:(UISwitch *)sw{ [GBConfig shared].simulateRewardCallback = sw.on; GBLog(@"补发回调：%@", sw.on ? @"开" : @"关"); }
- (void)onCloseAd:(UISwitch *)sw  { [GBConfig shared].closeAdViews = sw.on; GBLog(@"兜底关闭：%@", sw.on ? @"开" : @"关"); }
- (void)onEnforce:(UISwitch *)sw  { [GBConfig shared].enforceReward = sw.on; GBLog(@"奖励改写：%@", sw.on ? @"开" : @"关"); }
- (void)onRepeat:(UISwitch *)sw   { [GBConfig shared].repeatNoArgGrants = sw.on; GBLog(@"无参重复：%@", sw.on ? @"开" : @"关"); }

- (void)onSlider:(UISlider *)s {
    NSInteger m = (NSInteger)lroundf(s.value);
    [GBConfig shared].multiplier = m;
    _sliderLabel.text = [NSString stringWithFormat:@"倍率：x%ld", (long)m];
    GBLog(@"倍率设为 x%ld", (long)m);
}

- (void)onRescan:(UIButton *)b {
    GBLog(@"手动重新扫描……");
    b.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        GBInstallAdHooks();
        GBInstallRewardHooks();
        dispatch_async(dispatch_get_main_queue(), ^{ b.enabled = YES; });
    });
}

- (void)onCloseNow:(UIButton *)b     { GBLog(@"手动关闭广告"); GBCloseAdViewsNow(); }

- (void)onDiag:(UIButton *)b {
    GBConfig *cfg = [GBConfig shared];
    GBLog(@"———— 诊断 ————");
    GBLog(@"开关：master=%d skipAds=%d simReward=%d closeAd=%d enforce=%d repeat=%d x%ld",
          (int)cfg.masterEnabled, (int)cfg.skipAds, (int)cfg.simulateRewardCallback,
          (int)cfg.closeAdViews, (int)cfg.enforceReward, (int)cfg.repeatNoArgGrants,
          (long)cfg.multiplier);
    GBLog(@"广告类 %lu 个：", (unsigned long)GBDetectedAdClasses().count);
    for (NSString *s in GBDetectedAdClasses()) GBLog(@"  · %@", s);
    GBLog(@"已挂载奖励方法 %lu 个：", (unsigned long)cfg.hookedRewardMethods.count);
    for (NSString *s in cfg.hookedRewardMethods) GBLog(@"  · %@", s);
    GBLog(@"———— 诊断结束 ————");
}

- (void)onClearLog:(UIButton *)b { GBLogClear(); [self refreshLog]; }

@end

// ═══════════════════════════════════════════════════════════════
//  根控制器
// ═══════════════════════════════════════════════════════════════

@interface GBRootViewController : UIViewController
@property (nonatomic, strong) GBBallView  *ball;
@property (nonatomic, strong) GBPanelView *panel;
@property (nonatomic, assign) BOOL expanded;
@end

@implementation GBRootViewController

- (void)loadView {
    self.view = [[GBPassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor = UIColor.clearColor;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    CGFloat side = 56;
    CGRect screen = UIScreen.mainScreen.bounds;
    GBConfig *cfg = [GBConfig shared];

    CGPoint c = cfg.hasBallCenter ? cfg.ballCenter
                                  : CGPointMake(screen.size.width - side / 2 - 8,
                                                screen.size.height * 0.45);
    self.ball = [[GBBallView alloc] initWithFrame:CGRectMake(c.x - side / 2,
                                                             c.y - side / 2,
                                                             side, side)];
    __weak typeof(self) wself = self;
    self.ball.onTap = ^{ [wself togglePanel]; };
    [self.view addSubview:self.ball];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.ball addGestureRecognizer:pan];

    CGRect pv = CGRectMake(0, 0, 300, MIN(520, screen.size.height - 60));
    self.panel = [[GBPanelView alloc] initWithFrame:pv];
    self.panel.hidden = YES;
    [self.view addSubview:self.panel];
    [self layoutPanel];
}

- (void)layoutPanel {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat w = self.panel.bounds.size.width;
    CGFloat h = self.panel.bounds.size.height;

    // 面板贴着小球，且不出屏
    CGFloat x = self.ball.center.x + 40 + w > screen.size.width
                    ? self.ball.center.x - w - 40
                    : self.ball.center.x + 40;
    x = MAX(8, MIN(x, screen.size.width - w - 8));
    CGFloat y = MAX(40, MIN(self.ball.center.y - 40, screen.size.height - h - 30));
    self.panel.frame = CGRectMake(x, y, w, h);
}

- (void)togglePanel {
    self.expanded = !self.expanded;
    self.panel.hidden = !self.expanded;
    if (self.expanded) {
        [self layoutPanel];
        [self.panel refreshFromConfig];
        [self.panel refreshLog];
        if (!self.panel.logTimer) {
            __weak typeof(self) wself = self;
            self.panel.logTimer = [NSTimer scheduledTimerWithTimeInterval:0.7
                                                                  repeats:YES
                                                                    block:^(NSTimer *t) {
                __strong typeof(wself) sself = wself;
                if (!sself || sself.panel.hidden) return;
                [sself.panel refreshLog];
            }];
        }
    } else {
        [self.panel.logTimer invalidate];
        self.panel.logTimer = nil;
    }
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:self.view];
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.view];

    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat half = v.bounds.size.width / 2;
    c.x = MAX(half + 4, MIN(c.x, screen.size.width - half - 4));
    c.y = MAX(half + 30, MIN(c.y, screen.size.height - half - 30));
    v.center = c;

    if (self.expanded) [self layoutPanel];

    if (g.state == UIGestureRecognizerStateEnded) {
        GBConfig *cfg = [GBConfig shared];
        cfg.ballCenter = c;
        cfg.hasBallCenter = YES;
        [cfg saveBallCenter];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.expanded) [self layoutPanel];
}

@end

// ═══════════════════════════════════════════════════════════════
//  对外接口
// ═══════════════════════════════════════════════════════════════

static GBRootViewController *gRoot = nil;

static UIWindowScene *GBActiveScene(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)s;
        }
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

void GBOverlayShow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gOverlayWindow) {
            gOverlayWindow.hidden = NO;
            return;
        }

        UIWindowScene *scene = GBActiveScene();
        UIWindow *w = nil;
        if (scene) {
            w = [[UIWindow alloc] initWithWindowScene:scene];
        } else if (@available(iOS 13.0, *)) {
            GBLog(@"⚠️ 没有可用的 UIWindowScene，悬浮窗延后");
            return;
        } else {
            w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        }

        w.frame = UIScreen.mainScreen.bounds;
        w.windowLevel = UIWindowLevelAlert + 200;    // 盖住广告和游戏 UI
        w.backgroundColor = UIColor.clearColor;
        w.rootViewController = [[GBRootViewController alloc] init];
        w.hidden = NO;

        gOverlayWindow = w;
        gRoot = (GBRootViewController *)w.rootViewController;
        GBLog(@"悬浮窗已显示");
    });
}

void GBOverlayRefresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gRoot) [gRoot.panel refreshFromConfig];
    });
}

BOOL GBOverlayIsVisible(void) {
    return gOverlayWindow != nil && !gOverlayWindow.hidden;
}
