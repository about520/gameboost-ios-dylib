//
//  GBRuntime.m
//

#import "GBRuntime.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>

NSArray<NSString *> *GBAllClassNames(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        const char *n = class_getName(classes[i]);
        if (n && n[0]) [out addObject:[NSString stringWithUTF8String:n]];
    }
    if (classes) free(classes);
    return out;
}

NSArray<NSString *> *GBClassesMatching(NSString *pattern) {
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:NSRegularExpressionCaseInsensitive
                                                                         error:&err];
    if (!re) return @[];

    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in GBAllClassNames()) {
        NSRange r = NSMakeRange(0, name.length);
        if ([re firstMatchInString:name options:0 range:r]) {
            [out addObject:name];
        }
    }
    return out;
}

BOOL GBClassHasSelector(Class cls, SEL sel, BOOL isClassMethod) {
    if (!cls || !sel) return NO;
    if (isClassMethod) return class_getClassMethod(cls, sel) != NULL;
    return class_getInstanceMethod(cls, sel) != NULL;
}

NSString *GBImagePathForClass(Class cls) {
    if (!cls) return nil;
    const char *img = class_getImageName(cls);
    if (!img) return nil;
    return [NSString stringWithUTF8String:img];
}

BOOL GBClassIsSystem(Class cls) {
    NSString *p = GBImagePathForClass(cls);
    if (!p) return YES;   // 拿不到归属，保守当作系统类
    // 系统 dyld 共享缓存里的类 image 名形如
    // /System/Library/Frameworks/UIKitCore.framework/UIKitCore
    static NSString *const kSys = @"/System/Library/";
    static NSString *const kUsr = @"/usr/lib/";
    if ([p hasPrefix:kSys] || [p hasPrefix:kUsr]) {
        // 例外：游戏常见的第三方 SDK 不会在这里，直接判系统
        return YES;
    }
    return NO;
}

const char *GBTypeEncoding(Class cls, SEL sel, BOOL isClassMethod) {
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    return method_getTypeEncoding(m);
}

// ———————————————————————————————————————————————
// 类型编码解析
// 编码串形如：  v24@0:8q16      → 返回 void，参数 (self, _cmd, long long)
//              q16@0:8         → 返回 long long，参数 (self, _cmd)
//              @24@0:8@16      → 返回 id，参数 (self, _cmd, id)
// ———————————————————————————————————————————————

static const char *GBSkipType(const char *p) {
    if (!p || !*p) return p;
    // 跳过限定符
    while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' ||
           *p == 'R' || *p == 'V') {
        p++;
    }
    switch (*p) {
        case '^':                 // 指针：递归吃掉指向的类型
            return GBSkipType(p + 1);
        case '{': case '(': case '[': {
            char open = *p;
            char close = (open == '{') ? '}' : (open == '(') ? ')' : ']';
            int depth = 1;
            p++;
            while (*p && depth > 0) {
                if (*p == open) depth++;
                else if (*p == close) depth--;
                p++;
            }
            return p;
        }
        case 'b': {                 // 位域 b<offset><bits>
            p++;
            while (*p && isdigit((unsigned char)*p)) p++;
            while (*p && isdigit((unsigned char)*p)) p++;
            return p;
        }
        default:
            if (*p) p++;
            return p;
    }
}

/// 在编码串里前进一个「类型 + 偏移数字」单元
static const char *GBNextUnit(const char *p) {
    // 先跳过前置的数字（上一单元的偏移）
    while (*p && isdigit((unsigned char)*p)) p++;
    if (!*p) return p;
    char t = *p;
    p = GBSkipType(p);
    (void)t;
    return p;
}

char GBReturnType(const char *enc) {
    if (!enc || !*enc) return 0;
    const char *p = enc;
    while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' ||
           *p == 'R' || *p == 'V') {
        p++;
    }
    return *p;
}

char GBFirstArgType(const char *enc) {
    return GBArgType(enc, 0);
}

char GBArgType(const char *enc, int index) {
    if (!enc || !*enc || index < 0) return 0;
    const char *p = enc;

    p = GBNextUnit(p);                 // 0: 返回类型
    for (int i = 0; i < index + 3; i++) {
        if (!*p) return 0;
        p = GBNextUnit(p);             // 1: self, 2: _cmd, 3+: 真实参数
    }

    while (*p && isdigit((unsigned char)*p)) p++;
    if (!*p) return 0;
    while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' ||
           *p == 'R' || *p == 'V') {
        p++;
    }
    return *p;
}

BOOL GBInstallHook(Class cls, SEL sel, IMP newImp, BOOL isClassMethod, IMP *outOrig) {
    if (!cls || !sel || !newImp) return NO;

    // 类方法的实现挂在 metaclass 上，必须分开取，否则会把类方法挂成实例方法
    Class target = isClassMethod ? object_getClass(cls) : cls;

    Method m = class_getInstanceMethod(target, sel);
    if (!m) return NO;

    const char *types = method_getTypeEncoding(m);
    IMP old = method_getImplementation(m);

    // class_addMethod 成功 → 该方法原本是从父类/父元类继承的，
    // 于是新实现只挂到 target 上，父类纹丝不动。
    // 失败 → 方法本来就定义在 target 上，直接替换实现。
    if (class_addMethod(target, sel, newImp, types)) {
        if (outOrig) *outOrig = old;
        return YES;
    }

    method_setImplementation(m, newImp);
    if (outOrig) *outOrig = old;
    return YES;
}
