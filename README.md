# GameBoost —— iOS 免越狱注入型 dylib

悬浮窗 + 广告跳过 + 奖励翻倍。纯 Objective-C，**不依赖 CydiaSubstrate / libhooker / ellekit**，重签后即可在未越狱设备加载。

```
IOS-GameBoost/
├── Sources/                 源码
│   ├── GBConfig.h/.m        开关与倍率，NSUserDefaults 持久化
│   ├── GBLog.h/.m           环形日志（免越狱没法 attach lldb，日志面板是唯一调试手段）
│   ├── GBRuntime.h/.m       类枚举 / 安全 swizzle / ObjC 类型编码解析
│   ├── GBAdHooks.h/.m       三层广告拦截
│   ├── GBRewardHooks.h/.m   发奖方法识别 + 数值翻倍
│   ├── GBOverlay.h/.m       悬浮球 + 控制面板（点击穿透）
│   └── GBEntry.m            constructor 入口 + 启动轮询
├── tools/
│   ├── inject_dylib.sh      把 dylib 注入 IPA 并重签名（macOS）
│   └── find_targets.js      Frida 侦察：列出目标里像广告的类和像发奖的方法
├── build_dylib.sh           macOS 本地编译
├── Makefile                 可选，给用 Theos 的人
└── .github/workflows/build.yml   借 GitHub 的 macOS runner 云端编译
```

---

## 1. 编译

**Windows 上编不出 iOS dylib**，二选一：

### A. 云端编译（推荐，你在 Windows 也能用）

dylib 是编译产物，**必须在带 iOS SDK 的 macOS 上生成**。借 GitHub 的免费 macOS runner，不需要自己有 Mac。

**A-1 网页上传版（不用装 git）**

1. 打开 https://github.com/new ，建一个仓库（Public 即可，名字随便如 `gameboost`），**不要**勾选 "Add a README"
2. 进入空仓库页面 → 点 **uploading an existing file**
3. 把 `GameBoost-ios-dylib-source.zip` **先解压**，全选里面 22 个文件/目录一起拖进上传框
   （注意：`.github` 是隐藏目录，Windows 资源管理器要开「查看 → 隐藏的项目」，否则工作流不会被上传）
4. 点 **Commit changes**
5. 仓库顶部 **Actions** 标签 → 左侧 `build-ios-dylib` → 会自动开始跑（约 1–2 分钟）
6. 跑完点进那次运行 → 页面底部 **Artifacts** → 下载 `GameBoost.dylib`

**A-2 命令行版**

```bash
cd IOS-GameBoost
git remote add origin https://github.com/你的用户名/gameboost.git
git branch -M main
git push -u origin main
```

**A-3 如果 Actions 没自动触发**

进 Actions → 左侧 `build-ios-dylib` → 右侧 **Run workflow** 手动跑一次。

**A-4 全自动一条命令（装了 GitHub CLI 的话）**

```bash
gh auth login            # 只需授权一次：勾 repo + workflow 权限
cd IOS-GameBoost
chmod +x tools/gh_build.sh
./tools/gh_build.sh mygameboost
```

这条脚本会自动：本地提交 → 建仓库 → 推送 → 等 Actions 跑完 → **把 `GameBoost.dylib` 下载到 `build/`**；
如果编译失败，它会把失败日志尾部打出来，方便直接贴给我改。

> 推送 `.github/workflows/*.yml` 需要 token 带 `workflow` 权限。`gh auth login` 默认已包含；
> 如果手工建 PAT，Classic token 要同时勾 `repo` + `workflow`，否则 push 会被拒。

> 本工程已带 `.gitattributes` 锁定 LF 行尾。Windows 的 git 默认 autocrlf 会把 `.sh` 转成 CRLF，到 macOS runner 上会直接 `bad interpreter: /bin/bash^M`，所以这一步不能省。

### B. macOS 本地编译

```bash
cd IOS-GameBoost
chmod +x build_dylib.sh
./build_dylib.sh            # arm64 + arm64e，合并 universal
./build_dylib.sh arm64      # 只编 arm64（arm64e 编不过时用这个）
```

产物：`build/GameBoost.dylib`

---

## 2. 注入

### 前提：IPA 必须**已砸壳**

App Store 直接下载的 IPA 里二进制是 FairPlay 加密的（`cryptid=1`），`__TEXT` 段解不了密。注入 + 重签后装上去会闪退。先砸壳：

- 越狱设备：`frida-ios-dump`、`flexdecrypt`
- 非越狱：`TrollDecrypt`（TrollStore 设备）、`iMazing` 导出的部分 App 已解密
- 社区渠道的「已砸壳 IPA」

### 方式一：用现成工具（Windows 也能做，最省事）

- **TrollStore**（iOS 14.0–17.0）：支持 `.ipa` 注入 dylib，永久签名，不用证书
- **ESign / Scarlet / Feather**：手机上直接选 IPA → 「注入 dylib」→ 贴入 `GameBoost.dylib` → 用你的证书签 → 安装
- **Sideloadly**（Windows/macOS）：勾选 `Inject dylibs/frameworks`，选 `GameBoost.dylib`，侧载

### 方式二：macOS 脚本

```bash
cd IOS-GameBoost/tools
brew install insert_dylib        # 或 brew install optool
chmod +x inject_dylib.sh
./inject_dylib.sh ~/游戏.ipa ./GameBoost.dylib "Apple Development: 你的名字 (TEAMID)"
```

脚本会：解包 → **检查 cryptid 是否已砸壳** → 放 dylib 到 `Frameworks/` → 插 `LC_LOAD_DYLIB` → 清旧签名 → 重签 → 打包成 `游戏-boosted.ipa`。

> 注入这一步我没有自己手写 Mach-O 重写器 —— 那需要改 header 的 `sizeofcmds` 并平移后续所有段偏移，写错会把二进制搞坏，而我在当前环境无法验证结果。所以脚本依赖 `insert_dylib`/`optool`，或者你用现成工具做这一步。

---

## 3. 使用

装上后启动游戏，1–2 秒内左上区域会出现蓝色悬浮球 🎮。

- **拖动**：按住小球拖，位置会记住
- **点一下**：展开/收起面板
- 面板里每个开关都是**实时生效**，hook 内部每次调用都重读配置，不用重启

### 默认状态（保守，先探测再动手）

| 开关 | 默认 | 说明 |
|---|---|---|
| 插件总开关 | 开 | 关掉后所有 hook 直接透传原实现 |
| 跳过广告 | **开** | 拦截展示、不发广告请求 |
| 补发奖励回调 | **开** | 拦截时模拟「已发奖 / 已关闭」通知给游戏 |
| 兜底关闭广告 | 关 | 每秒轮询，自动点掉 ×/跳过 按钮 |
| **启用改写数值** | **关** | 默认只在日志里显示命中，**不改数值** |
| 无参发奖重复调用 | 关 | `-claimReward` 这类无参方法按倍率重复调 |
| 倍率 | x2 | 2–20 |

**为什么默认不改数值**：奖励翻倍是「猜目标」——扫描出来的方法名匹配不代表语义正确，误改可能污染存档。所以先开着日志跑一遍，看「运行日志」里哪些方法真被命中，确认过再打开改写。

### 游戏点不动 / 按钮点不了？（v1.1 已修）

如果**整个游戏界面都点不动**（比如登录按钮完全没反应），那是覆盖层的点击穿透没做全，
v1.1 已修复。原因是：

`UIView.hitTest` 在自己 `pointInside` 通过、但**没有任何子视图命中时会返回 `self`**。
而 `UIWindow` 的 bounds 就是整屏 —— 所以即使 rootView 返回了 nil，**窗口自己**仍会
成为命中目标，UIKit 认为这个窗口要接收触摸，游戏窗口永远收不到事件。

修法是两层都要拦：

| 层 | 类 | 作用 |
|---|---|---|
| 窗口层 | `GBPassthroughWindow` | hitTest 命中窗口自己 → 返回 nil（**关键**） |
| 根视图层 | `GBPassthroughView` | hitTest 命中自己 → 返回 nil |

修好后，覆盖层只有**悬浮球那 56×56 一块**会接收触摸，其余全屏透传。

### 如果悬浮球正好压住了某个按钮

面板的「操作」区新增两个应急按钮：

- **临时隐藏 15 秒** —— 折叠面板 + 整个窗口隐藏 15 秒后自动恢复。登录、授权弹窗被挡时用这个
- **悬浮球归位到屏幕右侧** —— 把球挪回屏幕右侧的安全位置（y ≈ 28% 处）并持久化

### 日志

面板里的「运行日志」实时显示最近 120 条，同时写到 App 沙盒 `Documents/GameBoost.log`（用 iMazing / 爱思助手 导出）。

---

## 4. 工作原理

### 广告跳过：三层，逐层兜底

| 层 | 手段 | 覆盖 |
|---|---|---|
| **L1 SDK 级** | 运行时扫描全部非系统类，类名匹配 `Interstitial / Rewarded / RewardVideo / VideoAd / Splash / AppOpen / Advert / ExpressAd`，再挂掉其 `show / present / play / load / request` 开头的方法 | AdMob、Unity Ads、AppLovin/MAX、穿山甲(BUAdSDK)、优量汇(GDT)、快手、百度 等 |
| **L2 通用级** | hook `-[UIViewController presentViewController:animated:completion:]`，凡是要弹出的 VC 类名像广告就拦住不弹 | 未知 SDK、自研广告 SDK |
| **L3 兜底级** | 定时扫窗口层级，找「×/✕/跳过/Close/Skip/关闭」按钮点掉；整层广告 window 直接隐藏 | 已经弹出来关不掉的、开屏广告 |

拦截后会**补触发回调链**：`rewardedVideoAdServerRewardDidSucceed:verify:` → `rewardedVideoAdDidPlayFinish:didFailWithError:` → `rewardedVideoAdDidClose:`（穿山甲命名）等，共 20+ 个常见 selector，用 `NSInvocation` 按真实签名安全调用。这一步是「跳过广告但仍拿奖励」的关键——游戏是靠这些回调发奖的。

AdMob 那种 `presentFromRootViewController:userDidEarnRewardHandler:` 的形式，直接调用那个 block 就等于立即发奖。

### 奖励翻倍：按签名分桶

ObjC 没法写一个「万能 IMP」接任意签名的方法 —— 签名对不上（比如返回 BOOL 却按 void 处理），调用方会读到垃圾寄存器然后崩。

所以流程是：扫描非系统类的全部实例方法 → 用「动词 + 资源名词」筛（`add/give/grant/claim/reward/...` × `coin/gold/diamond/point/balance/...`）→ 解析 `method_getTypeEncoding` → 按 `(返回类型, 第一个参数类型)` 查模板表 → 命中才挂，不命中只记录。

已覆盖的签名：

```
v 返回: (long long) (int) (unsigned) (u long long) (short) (double) (float) (BOOL) ()
BOOL 返回: (long long) (int) (double) (BOOL) ()
其它: double(double)  long long(long long)
```

改写逻辑：整数/浮点型的发奖方法把第一个参数乘以倍率；无参的 `-claimReward` 这类，可选按倍率重复调用。

---

## 5. 调优：让它命中你的目标

默认关键词表是通用的，遇到「广告类名完全不相关」或「发奖方法名不认识」的 App，用附带的 Frida 脚本侦察：

```bash
frida -U -f com.example.game -l tools/find_targets.js --no-pause
```

输出两份清单：
- **疑似广告类**：类名 + 展示方法 + 完整类型编码
- **疑似发奖方法**：类名 + selector + 类型编码（默认最多 300 条）

拿到清单后：

| 想改什么 | 改哪 |
|---|---|
| 广告类名规则 | `GBAdHooks.m` 的 `GBIsAdClassName()`，两个数组 `deny` / `allow` |
| 广告展示方法规则 | `GBAdHooks.m` 的 `GBIsShowSelector()` |
| 要补触发的回调名 | `GBAdHooks.m` 的 `kRewardSelectors()` |
| 发奖方法关键词 | `GBRewardHooks.m` 的 `kVerbs()` / `kResources()` / `kDenyTokens()` |
| 走私有字段直接改数值 | 在 `find_targets.js` 输出里找到目标类，自行用 `GBInstallHook` 加针对性 hook |

改完在面板点「重新扫描并挂载 hook」即可生效，不用重启（换关键词表需要重新编译）。

面板里的「输出诊断信息」会把当前挂载结果全打到日志，方便核对。

---

## 6. 必须先看的现实限制

写之前该说清楚，免得白折腾：

1. **奖励走服务端校验就翻不了。** 现在正规一点的 iOS 游戏，广告奖励都是客户端上报 + 服务端签发。客户端 hook 改数字，服务端不认，界面闪一下又变回去。这种情况下「跳过广告」通常仍然有效（因为很多游戏是客户端信任「广告已看完」这个信号再请求发奖），但「翻倍」拿不到真钱。

2. **这是「玩小游戏赚钱」类 App 的灰产场景，风险自负。** 这类 App 的提现环节全部有风控：异常广告完成率、设备指纹、IP、行为序列。改客户端最坏的结果不是封号，是提现被拒/账号被清。真要靠这个赚钱，投入产出比极低。

3. **微信/抖音里的小游戏做不了。** 那些是运行在微信/抖音宿主里的小程序，不是独立 App 进程。往宿主注入 dylib 会波及整个微信，且微信本身有完整性和反调试校验，不可行，也不该做。**只对独立的游戏 App 有效。**

4. **签名有效期。** 免费 Apple ID 侧载 7 天要重签；TrollStore 永久但只支持 iOS 14.0–17.0。

5. **不要在主力机上试。** 建议用备用机 / 测试机，或先在本机装个无害的 App 验证注入链路通了，再上目标。

---

## 7. 已知未验证项（诚实标注）

以下内容**没有在本机执行过**，因为编译 iOS dylib 需要 macOS + Xcode，当前是 Windows 环境：

- 编译：`build_dylib.sh` 未在 macOS 上跑过，语法按 Xcode 15 / iphoneos SDK 写
- 注入：`inject_dylib.sh` 未实跑；依赖 `insert_dylib` 的 `--strip-codesig --add-original` 参数形式
- 运行：任何 hook 都未在真机验证过 —— 目标类名/方法名是基于主流 SDK 的公开接口写的，实际 App 可能需要按第 5 节调优
- 需要你在 macOS 或 GitHub Actions 上跑一次编译，先把「能编出来」这一步打通，再谈注入和命中

编译报错的话把完整报错贴给我，我按报错改。
