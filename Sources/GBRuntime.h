//
//  GBRuntime.h
//
//  ObjC runtime 工具：类枚举、安全 swizzle、类型编码解析。
//
//  重要设计决定：
//  本插件**不依赖 CydiaSubstrate / libhooker / ellekit**。
//  免越狱环境下这些库根本不存在，直接 %hook 会因为找不到 substrate 而崩。
//  这里全部用 method_setImplementation / class_addMethod 手写 swizzle，
//  零外部依赖，重签后即可加载。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// 列出进程内全部已加载类名
NSArray<NSString *> *GBAllClassNames(void);

/// 按正则筛选类名
NSArray<NSString *> *GBClassesMatching(NSString *pattern);

/// 类是否实现了某 selector（含继承）
BOOL GBClassHasSelector(Class cls, SEL sel, BOOL isClassMethod);

/// 类是否来自系统库（避免去 hook UIKit/Foundation 内部）
BOOL GBClassIsSystem(Class cls);

/// 取类所在的镜像路径，用于判断归属
NSString *_Nullable GBImagePathForClass(Class cls);

/// 查询方法类型编码；返回 NULL 表示不存在
const char *_Nullable GBTypeEncoding(Class cls, SEL sel, BOOL isClassMethod);

/// 解析「第一个参数」的类型编码字符（不含 self/_cmd）。
/// 返回 0 表示没有参数或解析失败。
char GBFirstArgType(const char *enc);

/// 解析第 index 个参数的类型编码字符（index 0 = 第一个真实参数）。
/// 返回 0 表示该位置没有参数或解析失败。
char GBArgType(const char *enc, int index);

/// 解析「返回类型」字符
char GBReturnType(const char *enc);

/**
 * 安装 hook，正确处理「继承方法」的情况：
 *  - 若方法在父类上，用 class_addMethod 在本类新增一份，不改父类；
 *  - 若方法在本类上，直接 method_setImplementation。
 *
 *  ★ 幂等 ★：同一个 (cls, sel) 只会真正替换一次实现。
 *  第二次调用直接把首次登记的原实现回填到 outOrig 并返回 YES，不改动 IMP。
 *  这条保护是必须的 —— 否则二次挂载时 old 会拿到「我们自己的 hook」，
 *  存进原实现表后 hook 调用 orig 就变成调用自己，无限递归直接卡死主线程。
 *
 *  @param outOrig 输出原实现（无论哪种情况都能拿到）
 *  @return 是否安装成功（已装过也算成功）
 */
BOOL GBInstallHook(Class cls, SEL sel, IMP newImp, BOOL isClassMethod, IMP _Nullable *outOrig);

/// 本插件已挂载的 hook 数量
NSUInteger GBInstalledHookCount(void);

/// 把本插件挂过的所有 hook 全部还原成原实现（面板上的「一键还原」用）
NSUInteger GBUninstallAllHooks(void);

NS_ASSUME_NONNULL_END
