//
//  GBRewardHooks.m
//

#import "GBRewardHooks.h"
#import "GBConfig.h"
#import "GBLog.h"
#import "GBRuntime.h"
#import <objc/runtime.h>

// ═══════════════════════════════════════════════════════════════
//  原实现登记表
// ═══════════════════════════════════════════════════════════════

static NSMutableDictionary<NSString *, NSValue *> *gOrig = nil;   // "Class::sel" -> IMP

static void GBRegisterOrig(Class cls, SEL sel, IMP imp) {
    if (!imp || !cls || !sel) return;
    NSString *key = [NSString stringWithFormat:@"%s::%s",
                     class_getName(cls), sel_getName(sel)];
    @synchronized (gOrig) { gOrig[key] = [NSValue valueWithPointer:imp]; }
}

// 4 项极简缓存：同一发奖方法会被高频调用，避免每次都拼字符串。
// 注意：整表读写都在 @synchronized(gOrig) 里面完成 —— 24 字节结构体的
// 无锁并发读写是数据竞争，最坏情况会读到撕裂的 IMP 指针然后跳到野地址崩掉。
typedef struct { Class cls; SEL sel; IMP imp; } GBCacheSlot;
static GBCacheSlot gCache[4];
static int gCacheSlot = 0;

static IMP GBLookupOrig(Class startCls, SEL sel) {
    @synchronized (gOrig) {
        for (int i = 0; i < 4; i++) {
            if (gCache[i].cls == startCls && gCache[i].sel == sel && gCache[i].imp) {
                return gCache[i].imp;
            }
        }

        IMP found = NULL;
        for (Class c = startCls; c != Nil; c = class_getSuperclass(c)) {
            if (c == [NSObject class]) break;
            NSString *key = [NSString stringWithFormat:@"%s::%s",
                             class_getName(c), sel_getName(sel)];
            NSValue *v = gOrig[key];
            if (v) { found = (IMP)v.pointerValue; break; }
        }

        if (found) {
            gCache[gCacheSlot] = (GBCacheSlot){ startCls, sel, found };
            gCacheSlot = (gCacheSlot + 1) & 3;
        }
        return found;
    }
}

// ═══════════════════════════════════════════════════════════════
//  统一日志（限流，避免刷爆日志面板 / 拖慢主线程）
// ═══════════════════════════════════════════════════════════════
//
//  限流是全局的，不是 per-selector：游戏一帧里可能连着命中十几个发奖方法，
//  每条都走 NSLog + 落盘就会变成「点一下卡一下」。这里统一压到 ~6 条/秒。

static BOOL GBHitLogAllowed(void) {
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.15) return NO;
    last = now;
    return YES;
}

static void GBLogGrant(id self, SEL _cmd, double vin, double vout, NSInteger mult) {
    if (!GBHitLogAllowed()) return;

    NSString *cls = NSStringFromClass(object_getClass(self));
    if (mult > 1) {
        GBLog(@"翻倍  %@ -[%@]  %.6g → %.6g  (x%ld)",
              cls, NSStringFromSelector(_cmd), vin, vout, (long)mult);
    } else {
        GBLog(@"命中  %@ -[%@]  参数 %.6g（未改写）",
              cls, NSStringFromSelector(_cmd), vin);
    }
}

// ═══════════════════════════════════════════════════════════════
//  按签名分桶的 hook 模板
// ═══════════════════════════════════════════════════════════════

#define GB_TMPL_VOID_NUM(NAME, TYPE)                                                \
static void GBHook_##NAME(id self, SEL _cmd, TYPE a) {                              \
    IMP orig = GBLookupOrig(object_getClass(self), _cmd);                           \
    NSInteger mult = [GBConfig shared].effectiveMultiplier;                         \
    double vin = (double)a, vout = vin;                                             \
    if (mult > 1) vout = vin * (double)mult;                                        \
    GBLogGrant(self, _cmd, vin, vout, mult);                                        \
    if (orig) ((void (*)(id, SEL, TYPE))orig)(self, _cmd, (TYPE)vout);              \
}

#define GB_TMPL_RET_NUM(NAME, RET, TYPE)                                            \
static RET GBHook_##NAME(id self, SEL _cmd, TYPE a) {                               \
    IMP orig = GBLookupOrig(object_getClass(self), _cmd);                           \
    NSInteger mult = [GBConfig shared].effectiveMultiplier;                         \
    double vin = (double)a, vout = vin;                                             \
    if (mult > 1) vout = vin * (double)mult;                                        \
    GBLogGrant(self, _cmd, vin, vout, mult);                                        \
    if (!orig) return (RET)0;                                                       \
    return ((RET (*)(id, SEL, TYPE))orig)(self, _cmd, (TYPE)vout);                  \
}

// 第一个参数是整数类型（NSInteger/long long 在 arm64 上都是 'q'）
GB_TMPL_VOID_NUM(v_q, long long)
GB_TMPL_VOID_NUM(v_i, int)
GB_TMPL_VOID_NUM(v_I, unsigned int)
GB_TMPL_VOID_NUM(v_Q, unsigned long long)
GB_TMPL_VOID_NUM(v_s, short)
GB_TMPL_VOID_NUM(v_d, double)
GB_TMPL_VOID_NUM(v_f, float)
GB_TMPL_VOID_NUM(v_B, BOOL)

GB_TMPL_RET_NUM(B_q, BOOL, long long)
GB_TMPL_RET_NUM(B_i, BOOL, int)
GB_TMPL_RET_NUM(B_d, BOOL, double)
GB_TMPL_RET_NUM(B_B, BOOL, BOOL)
GB_TMPL_RET_NUM(d_d, double, double)
GB_TMPL_RET_NUM(q_q, long long, long long)

// 无参数的发奖方法（例如 -[Wallet claimDailyReward]）
static void GBHook_none(id self, SEL _cmd) {
    IMP orig = GBLookupOrig(object_getClass(self), _cmd);
    NSInteger mult = [GBConfig shared].effectiveMultiplier;
    BOOL repeat = [GBConfig shared].repeatNoArgGrants && mult > 1;

    if (GBHitLogAllowed()) {
        GBLog(@"命中  %@ -[%@]  无参数%@",
              NSStringFromClass(object_getClass(self)),
              NSStringFromSelector(_cmd),
              repeat ? [NSString stringWithFormat:@"，重复 %ld 次", (long)mult] : @"（未改写）");
    }

    if (!orig) return;
    NSInteger times = repeat ? mult : 1;
    for (NSInteger i = 0; i < times; i++) {
        ((void (*)(id, SEL))orig)(self, _cmd);
    }
}

static BOOL GBHook_none_B(id self, SEL _cmd) {
    IMP orig = GBLookupOrig(object_getClass(self), _cmd);
    NSInteger mult = [GBConfig shared].effectiveMultiplier;
    BOOL repeat = [GBConfig shared].repeatNoArgGrants && mult > 1;

    if (GBHitLogAllowed()) {
        GBLog(@"命中  %@ -[%@]  无参数(%@)",
              NSStringFromClass(object_getClass(self)),
              NSStringFromSelector(_cmd),
              repeat ? @"重复调用" : @"未改写");
    }

    if (!orig) return NO;
    BOOL r = NO;
    NSInteger times = repeat ? mult : 1;
    for (NSInteger i = 0; i < times; i++) {
        r = ((BOOL (*)(id, SEL))orig)(self, _cmd);
    }
    return r;
}

// ═══════════════════════════════════════════════════════════════
//  签名 → 模板 派发表
// ═══════════════════════════════════════════════════════════════

typedef struct {
    char ret;          // 0 表示不关心返回类型（仅 none 场景用）
    char arg;          // 0 表示无参数
    IMP  imp;
    const char *label;
} GBHookEntry;

static GBHookEntry kEntries[] = {
    { 'v', 'q', (IMP)GBHook_v_q, "void(long long)"  },
    { 'v', 'i', (IMP)GBHook_v_i, "void(int)"        },
    { 'v', 'I', (IMP)GBHook_v_I, "void(unsigned)"   },
    { 'v', 'Q', (IMP)GBHook_v_Q, "void(u long long)"},
    { 'v', 's', (IMP)GBHook_v_s, "void(short)"      },
    { 'v', 'd', (IMP)GBHook_v_d, "void(double)"     },
    { 'v', 'f', (IMP)GBHook_v_f, "void(float)"      },
    { 'v', 'B', (IMP)GBHook_v_B, "void(BOOL)"       },
    { 'B', 'q', (IMP)GBHook_B_q, "BOOL(long long)"  },
    { 'B', 'i', (IMP)GBHook_B_i, "BOOL(int)"        },
    { 'B', 'd', (IMP)GBHook_B_d, "BOOL(double)"     },
    { 'B', 'B', (IMP)GBHook_B_B, "BOOL(BOOL)"       },
    { 'd', 'd', (IMP)GBHook_d_d, "double(double)"   },
    { 'q', 'q', (IMP)GBHook_q_q, "long long(long long)" },
    { 'v',  0,  (IMP)GBHook_none,   "void()"        },
    { 'B',  0,  (IMP)GBHook_none_B, "BOOL()"        },
};
static const int kEntryCount = (int)(sizeof(kEntries) / sizeof(kEntries[0]));

static GBHookEntry *GBFindEntry(char ret, char arg) {
    for (int i = 0; i < kEntryCount; i++) {
        if (kEntries[i].ret == ret && kEntries[i].arg == arg) return &kEntries[i];
    }
    return NULL;
}

// ═══════════════════════════════════════════════════════════════
//  发奖方法识别
// ═══════════════════════════════════════════════════════════════

static NSArray<NSString *> *kVerbs(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // v1.2 收紧：删掉了 insert / put / update / increase / pay。
        // 这几个词太通用，会命中存档写入、UI 计数、扣款等逻辑；
        // 一旦用户打开「启用改写数值」，改这些方法最容易把游戏改崩。
        v = @[@"add", @"give", @"grant", @"reward", @"claim", @"receive", @"earn",
              @"gain", @"plus", @"multiply", @"double", @"bonus",
              @"collect", @"obtain", @"acquire", @"credit", @"deposit",
              @"发放", @"增加"];
    });
    return v;
}

static NSArray<NSString *> *kResources(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = @[@"coin", @"gold", @"money", @"cash", @"diamond", @"gem", @"jewel",
              @"credit", @"point", @"balance", @"reward", @"score", @"star",
              @"ticket", @"energy", @"life", @"hp", @"dollar", @"yuan", @"wallet",
              @"buck", @"voucher", @"coupon", @"bean", @"shell", @"fish",
              @"金币", @"钻石", @"奖励", @"红包"];
    });
    return v;
}

static NSArray<NSString *> *kDenyTokens(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 这些多半是查询/展示/样式相关，误改会崩或花屏
        v = @[@"did", @"will", @"should", @"perform", @"animation", @"animate",
              @"label", @"text", @"string", @"format", @"icon", @"image",
              @"color", @"font", @"frame", @"position", @"layer", @"display",
              @"notify", @"log", @"analytics", @"event", @"track", @"report",
              @"request", @"http", @"url", @"json", @"dict", @"array",
              @"callback", @"delegate", @"observer", @"bind", @"cell",
              @"init", @"alloc", @"copy", @"description", @"debug", @"test"];
    });
    return v;
}

static BOOL GBRewardSelectorMatches(NSString *selName) {
    if (selName.length < 6) return NO;
    NSString *s = selName.lowercaseString;

    for (NSString *deny in kDenyTokens()) {
        if ([s containsString:deny]) return NO;
    }

    BOOL hasVerb = NO;
    for (NSString *v in kVerbs()) {
        if ([s containsString:v]) { hasVerb = YES; break; }
    }
    if (!hasVerb) return NO;

    for (NSString *n in kResources()) {
        if ([s containsString:n]) return YES;
    }
    return NO;
}

// ═══════════════════════════════════════════════════════════════
//  主流程
// ═══════════════════════════════════════════════════════════════

static NSInteger gHookedCount = 0;

NSInteger GBHookCount(void) { return gHookedCount; }

NSInteger GBInstallRewardHooks(void) {
    if (!gOrig) gOrig = [NSMutableDictionary dictionary];

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();

    NSInteger installed = 0;
    NSInteger skippedSig = 0;
    NSMutableArray<NSString *> *matched = [NSMutableArray array];

    // 全量扫描在游戏里可能遍历上万个类，加个上限避免长时间占满一个核
    const NSInteger kMaxInstall = 800;

    for (NSString *clsName in GBAllClassNames()) {
        if (installed >= kMaxInstall) break;

        // 跳过自己的类、系统类、Swift 泛型占位
        if ([clsName hasPrefix:@"GB"]) continue;
        if ([clsName hasPrefix:@"_"] && [clsName containsString:@"Swift"]) continue;

        Class cls = NSClassFromString(clsName);
        if (!cls) continue;
        if (GBClassIsSystem(cls)) continue;

        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        if (!methods) continue;

        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *selName = NSStringFromSelector(sel);

            if (!GBRewardSelectorMatches(selName)) continue;

            const char *enc  = method_getTypeEncoding(methods[i]);
            char ret = GBReturnType(enc);
            char arg = GBFirstArgType(enc);

            GBHookEntry *e = GBFindEntry(ret, arg);
            if (!e) {
                skippedSig++;
                continue;   // 签名不支持：只跳过，绝不硬挂（会崩）
            }

            IMP orig = NULL;
            if (GBInstallHook(cls, sel, e->imp, NO, &orig)) {
                GBRegisterOrig(cls, sel, orig);
                installed++;
                if (matched.count < 200) {
                    [matched addObject:[NSString stringWithFormat:@"%@ -[%@]  %s",
                                        clsName, selName, e->label]];
                }
            }
        }
        free(methods);
    }

    gHookedCount = installed;

    // 写进配置，供悬浮窗诊断页展示
    GBConfig *cfg = [GBConfig shared];
    @synchronized (cfg) {
        [cfg.hookedRewardMethods removeAllObjects];
        [cfg.hookedRewardMethods addObjectsFromArray:matched];
    }

    CFAbsoluteTime cost = CFAbsoluteTimeGetCurrent() - t0;
    GBLog(@"奖励扫描完成：挂载 %ld 个，签名不支持跳过 %ld 个，耗时 %.2fs",
          (long)installed, (long)skippedSig, cost);
    for (NSString *line in matched) {
        GBLog(@"  · %@", line);
    }
    return installed;
}
