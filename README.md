# AutoTapper

iOS 全局定点自动循环点击 tweak（Theos 注入式 dylib）。

- 目标设备：iPhone 13 Pro / iOS 17.0，arm64 + arm64e
- 越狱环境：rootless（palera1n / Dopamine / XinaA15 等）
- 包名：`com.yg.autotapper`
- 注入进程：**只注入 SpringBoard**，通过 SpringBoard 在系统层覆盖前台任意 App

---

## 1. 功能与操作

| 操作 | 效果 |
|---|---|
| 拖拽悬浮球 | 移动球到顺手的位置，松手自动吸附最近左右边缘 |
| 单击悬浮球 | 展开 / 收起控制面板 |
| **双击悬浮球** | 快速开始 / 停止循环点击 |
| 拖拽准星 | 实时移动目标点，松手保存 |
| 单击准星 | 确认（仅收起坐标提示） |
| 音量减键 | 停止循环点击（硬件拦截，不会真的调音量到 0 卡死） |
| 面板「停止」按钮 | 停止循环点击 |

面板里可调：

- 点击间隔 `0.02 s ~ 5.0 s`
- 单次按压时长 `0.02 s ~ 0.30 s`（有些 App 需要按久一点才认）
- 微调步长 `1 / 5 / 10 pt`
- 9 宫格方向键（`⊙` = 直接设到屏幕正中）
- 注入后端：`自动 / HID / SB-HID / UITouch`
- 音量减停止开关、准星显隐开关
- 运行日志（最后 40 行，完整日志见文件路径）

配置持久化：`<HOME>/Documents/AutoTapper.json`
运行日志：`<HOME>/Documents/AutoTapper.log`

> SpringBoard 侧 `HOME` = `/var/mobile`，即
> `/var/mobile/Documents/AutoTapper.json`。
> rootless 环境下这个路径**不带** `/private/preBoot` 前缀，它是用户数据目录。

---

## 2. 编译（Windows / macOS / Linux 通用）

### 2.1 一次性准备 Theos

**macOS / Linux**

```bash
export THEOS=$HOME/theos
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

**Windows**：装 WSL2（Ubuntu 22.04+），在上面那套命令里跑。本项目所有路径都是相对路径，把整个
`AutoTapper` 目录拷进 WSL 的 `~/AutoTapper` 再编译即可。

编译还需要 iOS SDK。Theos 的 `install-theos` 会把 SDK 放到 `$THEOS/sdks/`
（本工程用 `iphone:clang:latest:13.0`，会自动挑最新的 iOS SDK，13.0 是最低部署版本）。

### 2.2 编译

一键（推荐，先跑离线自检再编，缺 SDK 会直接给出修复命令）：

```bash
cd ~/AutoTapper
export THEOS=$HOME/theos
./build.sh            # 自检 + make package FINALPACKAGE=1
./build.sh dylib      # 只要 dylib
./build.sh check      # 只跑自检，不需要 Theos
./build.sh clean      # 清 .theos / packages
```

手动等价命令：

```bash
cd ~/AutoTapper
export THEOS=$HOME/theos
make clean
make package FINALPACKAGE=1
```

### 2.2.1 云端编译（本机没有 macOS / Theos 时）

`.github/workflows/build.yml` 会在 GitHub 的 macOS runner 上装 Theos + iOS SDK、
跑三个离线自检、编包，然后把 `deb` 和 `dylib` 作为 Artifacts 上传（保留 30 天）。

**本仓库已经跑通**：<https://github.com/aismoo/AutoTapper>

| 项 | 值 |
|---|---|
| 工作流 | `.github/workflows/build.yml` |
| 触发 | push 到 `main`/`master`（改 `.md` 不触发）、PR、手动 `workflow_dispatch` |
| runner | `macos-14` |
| Theos | 固定 commit `304e0799973e8145f32e4ca2de6c747a84b758ce`（可复现，不跟 master 漂） |
| 已验证运行 | run `40086681950` → `success`，11 个 step 全绿 |

第一次运行（`40086136526`）是 **failure**，原因是 `YGHID.m` 里
`static id sKeyBlock` 只赋值不读取，被 Theos 默认的 `-Werror` 判为
`unused-but-set-variable`。该问题已修（见 git 记录 `61ae8ce`），
同时把 block 注册的解注册路径也一并纠正了。

推送方式（用你自己的仓库地址）：

```bash
git init && git add -A && git commit -m "AutoTapper"
git remote add origin git@github.com:<你>/AutoTapper.git
git push -u origin main
```

push 之后进仓库的 **Actions → build → 最新一次运行 → Artifacts** 下载
`AutoTapper-deb` / `AutoTapper-dylib`。也可以在 Actions 页面点
**Run workflow** 手动触发（`workflow_dispatch`）。

> runner 是 macOS 14，`install-theos` 会自带一套命令行工具链；
> 如果 `make` 报找不到 SDK，检查 workflow 里 `theos/sdks` 那步是否成功
> （它会 clone theos/sdks 的完整仓库，其中含最新的 iOS 17/18 SDK）。

用命令行拉产物时有个坑：`GET /repos/{o}/{r}/actions/artifacts/{id}/zip`
会 302 到 Azure Blob 预签名 URL，**若跟随重定向仍带 `Authorization` 头，
Azure 直接返回 401**。本仓库的 `tools/fetch_artifact.py` 用自定义
`HTTPRedirectHandler` 在重定向时剥掉该头：

```bash
python tools/fetch_artifact.py <artifact_id> AutoTapper-deb
python tools/fetch_artifact.py <artifact_id> AutoTapper-dylib
```

产物（CI Artifacts 内）：

```
AutoTapper-deb.zip    → com.yg.autotapper_1.0.0_iphoneos-arm64.deb  (~61 KB)
AutoTapper-dylib.zip  → AutoTapper.dylib（fat, arm64 + arm64e, ~362 KB）
                        arm64/AutoTapper.dylib  (~164 KB)
                        arm64e/AutoTapper.dylib (~163 KB)
```

**只要 dylib 不要 deb**（给第 4 节的两种落地方式用）：

```bash
make FINALPACKAGE=1
ls -l .theos/obj/arm64/AutoTapper.dylib
ls -l .theos/obj/arm64e/AutoTapper.dylib
```

> `ARCHS = arm64 arm64e` 会产出两个 slice 再 `lipo` 合成一个 fat dylib，
> 最终文件通常在 `.theos/obj/AutoTapper.dylib`。用
> `file .theos/obj/AutoTapper.dylib` 确认是 `Mach-O universal binary ... 2 architectures`。

### 2.3 常用变体

```bash
# 打开 GSEvent 后备后端（默认关闭，见第 6 节说明）
make package ADDITIONAL_CFLAGS=-DYG_ENABLE_GSEVENT=1

# 只编 rootful 包（老越狱用）
make package THEOS_PACKAGE_SCHEME= ARCHS=arm64

# 调试版（带符号、不 strip）
make package DEBUG=1
```

---

### 2.4 直接在真机上装 CI 产物

从 Actions Artifacts 拿到的 `com.yg.autotapper_1.0.0_iphoneos-arm64.deb` 是 rootless 包，
装法任选：

```bash
# USB / SSH 到设备
scp com.yg.autotapper_1.0.0_iphoneos-arm64.deb root@<device_ip>:/var/mobile/
ssh root@<device_ip>
dpkg -i /var/mobile/com.yg.autotapper_1.0.0_iphoneos-arm64.deb
killall -9 SpringBoard
```

或用 Filza 点开 deb 安装，或 `sileo` / `zebra` 本地导入。

装完确认文件到位（rootless 一律在 `/var/jb` 下）：

```bash
ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/AutoTapper.*
```

应该看到 `AutoTapper.dylib` 和 `AutoTapper.plist` 两个文件。
plist 的 `Filter.Bundles` 只有 `com.apple.springboard` —— 这是设计如此，
只注入 SpringBoard 才能覆盖前台任意 App（原因见第 5 节）。

重启 SpringBoard 后，屏幕右侧出现悬浮球即注入成功。

---

## 3. 安装（越狱设备，正常路径）

```bash
# 设备已开 SSH（默认 root@<IP>，密码 alpine）
export THEOS_DEVICE_IP=192.168.1.23
export THEOS_DEVICE_PORT=22

make package install FINALPACKAGE=1
```

`Makefile` 里已带 `after-install:: install.exec "sbreload || killall -9 SpringBoard"`，
装完会自动刷新 SpringBoard。

手动装 deb：

```bash
scp packages/com.yg.autotapper_1.0.0_iphoneos-arm64.deb root@192.168.1.23:/tmp/
ssh root@192.168.1.23
# 设备上：
dpkg -i /tmp/com.yg.autotapper_1.0.0_iphoneos-arm64.deb
# rootless 的 dpkg 可能需要 -i --force-depends，或改用 Sileo/Filza 安装
sbreload
```

装完之后应该**立刻**看到悬浮球出现在屏幕边缘。看不到就去
`/var/mobile/Documents/AutoTapper.log` 看日志。

---

## 4. 两种落地方式

### 方式 A：sideload 进 IPA（无越狱也能用，推荐给单 App 场景）

把 dylib 塞进目标 App 的 IPA 里，重签名后侧载。**此时插件只在那一个 App 里工作**。

```bash
# 1) 准备一个干净的目标 IPA（App Store 解密版 / 你自己的开发包）
cp Target.ipa work.ipa
mkdir -p Payload && cd Payload && unzip -o ../work.ipa && cd ..

# 2) 把 dylib 拷进 .app 目录
APP=$(ls -d Payload/*.app | head -1)
cp .theos/obj/AutoTapper.dylib "$APP/Frameworks/"    # 没有 Frameworks 就先 mkdir -p

# 3) 给主二进制加一条 LC_LOAD_DYLIB
#    工具：insert_dylib（https://github.com/tyilo/insert_dylib）
insert_dylib --strip-codesig --inplace \
    '@executable_path/Frameworks/AutoTapper.dylib' \
    "$APP/$(defaults read "$PWD/$APP/Info" CFBundleExecutable)"

# 4) 重新打包
zip -qr ../patched.ipa Payload

# 5) 重签名 + 侧载
#    图形工具：Sideloadly / AltStore / TrollStore
#    命令行：codesign -f -s "Apple Development: you@example.com" ... 后 ipa 重打包
```

要点：

- **必须重签名**，改过二进制后原签名一定失效，否则装不上。
- 免费开发者账号签名 7 天过期，需要重签。
- iOS 17 + 免费证书 + 带额外 dylib 的 IPA，成功率取决于目标 App 是否有
  `get-task-allow` 之外的限制；TrollStore（若设备支持）不需要重签，直接装。
- sideload 版本里 `NSHomeDirectory()` 是 **App 沙盒**，所以配置和日志会写到
  `<App沙盒>/Documents/`，与 SpringBoard 侧不共享。这是预期行为。
- sideload 版本 `.plist` 的 Filter 不起作用（没有 Substrate），
  dylib 是被 `LC_LOAD_DYLIB` 强制加载的。

### 方式 B：dylib 注入到目标 App（越狱设备，需要 Substrate/ellekit）

目标 App 有反注入检测、或者 HID 后端被过滤时使用。**在已越狱设备上**操作：

**B-1 只给某个 App 注（推荐）**

编辑 `AutoTapper.plist`，把 App 的 Bundle ID 加进 `Bundles`：

```xml
Bundles = (
    "com.apple.springboard",
    "com.tencent.xin"
);
```

重新 `make package install`，然后 `sbreload`。之后该 App 每次启动都会被注入。

**B-2 手工放置 dylib（不改 deb，临时试验）**

```bash
# rootless 的 tweak 注入目录
scp .theos/obj/AutoTapper.dylib root@192.168.1.23:/var/jb/usr/lib/TweakInject/
ssh root@192.168.1.23
# 设备上：让注入器认领它（ellekit / Substitute 会扫这个目录）
ls -l /var/jb/usr/lib/TweakInject/
# 文件名需与 plist 同名：AutoTapper.dylib + AutoTapper.plist
killall -9 SpringBoard
```

rootful 设备路径是 `/Library/MobileSubstrate/DynamicLibraries/`。

**B-3 单 App 用 `DYLD_INSERT_LIBRARIES` 强注（调试用，不持久）**

```bash
ssh root@192.168.1.23
# 找到 App 的可执行文件路径
APP_PATH=$(ls -d /var/containers/Bundle/Application/*/Target.app | head -1)
# 直接带 dylib 启动（需要 App 未运行）
killall -9 Target 2>/dev/null
DYLD_INSERT_LIBRARIES=/var/jb/usr/lib/TweakInject/AutoTapper.dylib \
    "$APP_PATH/Target" &
```

注意：iOS 上 `DYLD_INSERT_LIBRARIES` 对带 `platform-application` 之外的
硬化二进制会被 dyld 拒绝；越狱环境下多数 App 可以成功。

---

## 5. 注入后端与 iOS 17 可用性

点击注入按优先级自动降级，也可在面板里手动锁定。

| 后端 | 实现 | iOS 17 rootless | 说明 |
|---|---|---|---|
| **HID** | `IOHIDEventCreateDigitizerFingerEventWithQuality` + `IOHIDEventSystemClientDispatchEvent` | **可用** | 首选。事件由 `backboardd` 分发，对前台任意 App 生效；不需要目标 App 里有代码在跑 |
| SB-HID | `[UIApplication _enqueueHIDEvent:]` | 可用 | HID 的进程内变体，需在 SpringBoard 里；某些系统版本对 `_enqueueHIDEvent:` 改名 |
| UITouch | `[UIApplication _dispatchTouches:event:]` | 可用 | 纯 UIKit 私有方法，只能作用于**本进程**的窗口 |
| SENDEVENT | `[UIWindow _sendTouchesForEvent:]` | 可用 | 同上，需要构造 `UIEvent`，兼容性最广但最容易漏事件 |
| GSEVENT | `GSSendEvent()` | **已失效** | iOS 15+ 需要 `purple` 端口权限，普通进程拿不到，默认编译期关闭（`-DYG_ENABLE_GSEVENT=1` 才编进去） |

### 为什么 HID 在 iOS 17 仍然可用

`IOHIDEventCreateDigitizerFingerEventWithQuality` /
`IOHIDEventCreateDigitizerEvent` / `IOHIDEventSystemClientDispatchEvent` 都是
**IOKit 的动态导出符号**，至今仍在 `/System/Library/Frameworks/IOKit.framework/IOKit`。
iOS 15 之后新增了两处校验，本工程已处理：

1. `IOHIDEventSetIntegerValue(event, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1)`
   —— 不设这个字段，backboardd 会丢弃事件（表现为「点了但没反应」）。
2. `IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, type, NULL)`
   —— 用 **Inject** 类型创建客户端。这个枚举的数值各版本不完全一致
   （iOS 12/13 与 14+ 都出现过 `1`/`2` 的差异），而且传错值时
   `CreateWithType` 有两种失败方式：返回 `NULL`（能发现），或者
   **返回一个 Monitor 类型的 client**（创建成功、`Dispatch` 不报错，
   但事件被当作监听输出、backboardd 直接丢弃 → 「代码全跑通，屏幕没反应」）。
   所以本工程**不硬编码**：从 `2`(Inject) 开始逐个候选尝试，
   谁建成功用谁，并把实际 type 打进日志。符号不在时回落到
   旧的 `IOHIDEventSystemClientCreate`。

   监听的键盘路径用 `type = 1`(Monitor)，同理有回落。

另外 `IOHIDEventAppendEvent` 包一层 `kIOHIDDigitizerTransducerTypeHand`：
部分 Unity / UE 手游只认顶层 hand 事件的 phase，裸 finger 事件会被忽略。

### fallback 链

`YGInjector` 的 `auto` 模式在启动时 `probe`，依次尝试
`HID → SPRINGHID → UITOUCH → SENDEVENT`，选第一个可用的。
运行中某个后端连续失败 **10 次**会自动 `stop`（防空转烧电），
日志里会写明失败后端名。

GSEvent 的 fallback 已实现符号探测（`YGGSIsAvailable`），
但**不构造 record**：iOS 15+ 的 `GSSendEvent` 需要 `purple` 端口，
普通注入进程调用只会返回 `EPERM`，做了也没用。
真要试，用 `make package ADDITIONAL_CFLAGS=-DYG_ENABLE_GSEVENT=1`。

---

## 6. 音量减键：三层实现与降级

需求里问「AVSystemController 和 MediaRemote 哪个在 iOS 15+/17 还能用」，结论：

### L1（首选，一定可用）：IOHID 键盘 usage 监听

```objc
// YGHID.m 里的 YGHIDStartKeyMonitor
matching = @{ @"PrimaryUsagePage": @(0x0C /* Consumer */),
              @"PrimaryUsage":     @(0xEA /* Volume Decrement */) };
IOHIDEventSystemClientRegisterEventCallback(client, cb, NULL, NULL);
```

- **全版本可用**，iOS 17 也照旧。
- 直接收硬件 usage，**音量已经为 0 时仍然能收到**（这点最关键）。
- 需要一条专用线程跑 `CFRunLoopRunInMode`，已实现。

### L2（降级）：AVSystemController 通知

```objc
AVSystemController_SystemVolumeDidChangeNotification
  → userInfo[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"]
    必须等于 @"ExplicitVolumeChange"
  → 对比 AVSystemController_AudioVolumeNotificationParameter 与上次值判断"降"
```

- iOS 15 / 16 / 17 **仍会触发**。
- 但有个硬伤：**音量已经是 0 的时候不会再发通知** —— 用户连着按减键，
  第二下就没反应了。所以它只能当降级，且需要有 L1 兜底。
- 框架：`MediaExperience.framework`（iOS 13+），更早的版本在 `Celestial.framework`，
  本工程两个都尝试 `dlopen`。

### L3（最后降级）：swizzle SpringBoard 音量按钮方法

```objc
SBVolumeControl        -_changeVolumeBy:(float)delta      // delta < 0 视为按下减键
SBVolumeHardwareButton -_volumeDownButtonDown             // 无参版本
```

- **替代 MediaRemote**：MediaRemote 只能**发送**音量命令，
  收不到按键事件；iOS 16 起对外部进程的限制更严，用它做监听是走不通的。
- 运行时探测（`class_getInstanceMethod` + 签名校验）后才挂，
  并且**一定调用原实现**，否则用户音量键彻底失效。
- 精度最好（一次按键一次回调，无去抖问题），但依赖 SpringBoard 私有类名。

三层全部用同一个 300 ms 去抖（`kYGDebounce`），避免一次物理按键触发多次停止。

三层**全部失败**时，日志会写明「只剩悬浮球停止按钮可用」——不会静默失效。

---

## 7. 全局悬浮窗：多场景要点

1. **iOS 13+ 没有 `app.keyWindow`**。本工程 `YGActiveWindowScene()` 遍历
   `UIApplication.sharedApplication.connectedScenes`，按
   `activationState` 打分（`ForegroundActive` +100 / `Inactive` +50 /
   `Background` +1，主屏再 +20），选最高分那个 `UIWindowScene`。
2. **`UIWindow.windowScene` 是只读的**，换场景必须销毁重建窗口。
   `YGOverlayController -rebindScene` 的做法：同场景只更新 frame，
   不同场景 `uninstall` + `install`，并保留 `ballCenter` 与面板可见性。
3. **`windowLevel`** 用 `UIWindowLevelAlert + 2000`（= 4000），
   高于 Alert 层（来电、Face ID 提示），低于 `UIWindowLevelStatusBar` 之上
   不可见的层。`Tweak.xm` 的 A 组会监听 `makeKeyAndVisible`，
   发现有系统窗口层级更高时**只往上抬不往下压**（`ensureTopmostLevel:`）。
4. **触摸穿透**：`YGOverlayRootView` 重写 `hitTest:withEvent:`，
   只放行 `tag == kYGTouchableTag` 且在 frame 内的子视图，其余返回 `nil`
   —— 这样悬浮窗全屏覆盖但只有球和面板可交互，下面的 App 正常收点击。
5. **不 becomeKeyWindow / makeKeyAndVisible**：否则会抢走第一响应者，
   输入框全部失焦、键盘弹不出来。本工程只设 `hidden = NO`。
6. 面板上挂 `UIPanGestureRecognizer` 用于拖动，但
   `gestureRecognizerShouldBegin:` 里命中 `UIControl / UITextView / UIScrollView`
   时返回 `NO`，否则会抢走滑块/开关的拖动。

---

## 8. 文件结构

```
AutoTapper/
├── Makefile                     # Theos 构建（rootless, arm64+arm64e）
├── control                      # deb 元信息
├── AutoTapper.plist             # Substrate 注入过滤器（只注 SpringBoard）
├── AutoTapper.xm                # 生命周期：%ctor / SpringBoard hook → 引导启动
├── Tweak.xm                     # 系统行为层：窗口层级 / 前台切换 / 锁屏安全阀
├── YGCore.h                     # 公共声明（含设计决策注释）
├── YGCore.m                     # 日志 / 屏幕几何 / 窗口查找 / swizzle 助手
├── YGConfig.m                   # JSON 配置持久化
├── YGPrivateAPI.h               # IOHIDEvent 私有 API 声明与函数指针 typedef
├── YGHID.m                      # HID 事件构造与分发 + 键盘 usage 监听
├── YGTouchInjector.m            # 多后端注入器（HID/SB-HID/UITouch/SendEvent/GSEvent）
├── YGTapEngine.m                # 循环定时器（dispatch_source，非 NSTimer）
├── YGVolumeButton.m             # 音量减三层监听
├── YGOverlayWindow.m            # 悬浮窗 / 准星 / 悬浮球绘制
├── YGOverlayController.m        # 面板 UI + 手势 + 场景重绑
├── build.sh                     # 一键自检 + 编译（Windows WSL/macOS/Linux）
├── tools/                       # 离线静态自检（不依赖 Theos）
│   ├── balance_check.py         # 括号/接口实现配对平衡
│   ├── sel_check.py             # YG* 类选择子是否都有声明
│   └── sym_check.py             # 跨文件符号/宏重复与缺失
└── .github/workflows/build.yml  # macOS runner 云端编包，产出 deb + dylib
```

### 离线自检做了什么

本机（Windows）没有 clang / Theos，所以把「能在没有编译器时验证的东西」抽成了
三个脚本，`build.sh` 与 CI 都会先跑它们：

| 脚本 | 检查内容 |
|---|---|
| `tools/balance_check.py` | 每个文件的 `{} () []` 配平，`@interface`/`@implementation`/`@end` 配对 |
| `tools/sel_check.py` | 所有 `[YGxxx sel]` 消息发送，其选择子在工程内存在声明（含 `@property` getter，`alloc/new/init/class` 等 NSObject 继承方法在白名单里跳过） |
| `tools/sym_check.py` | 12 个文件中声明的函数/宏/`@interface` 去重，抓「同名不同签名」「声明了没实现」 |

它们**不能替代编译**：类型错误、Logos 展开问题、链接错误只有真编译器能发现。


### 几个实现选择的原因

- **定时器用 `dispatch_source`，不用 `NSTimer` / `CADisplayLink`**
  `NSTimer` 挂在主 runloop 的 `NSDefaultRunLoopMode`，App 滚动的瞬间会切到
  `UITrackingRunLoopMode`，定时器被掐停 —— 表现就是「滑一下就不点了」。
  `CADisplayLink` 120 Hz 纯属浪费电。
  `dispatch_source` 跑在私有串行队列，`leeway` 设为
  `min(2ms, interval/10)`，既不漂移也不吵醒 CPU。

- **`_ticking` 重入标志：上一 tick 没完成就跳过本 tick**
  不排队。排队会让间隔越积越大（比如注入卡了 200 ms，后续会连续补点 4 次）。

- **同一个 `identity` 对应 down / up 两个事件**
  每次点击用一个自增 identity（`%1000 + 1`），down 和 up 必须同 identity，
  否则目标 App 会认为手指一直按着不放。

- **`YGAbsoluteTime` 必须是 8 字节 `uint64_t`**
  `IOHIDEventCreateDigitizerFingerEventWithQuality` 的 `timeStamp` 是
  `AbsoluteTime`（64 位）。写成 `{uint32 hi; uint32 lo;}` 的结构体会让
  AAPCS64 的参数寄存器整体错位，表现为「点击坐标全乱、点到屏幕外」。

---

## 9. 故障排查

先看日志：

```bash
ssh root@192.168.1.23
tail -f /var/mobile/Documents/AutoTapper.log
```

| 现象 | 排查 |
|---|---|
| 装完没有悬浮球 | 看日志有没有 `overlay installed`；没有就是注入失败，检查 `AutoTapper.plist` 是否被拷到 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`（rootless）或 `/Library/MobileSubstrate/DynamicLibraries/`（rootful） |
| 悬浮球在但点击无反应 | 面板里把后端改成 `HID` 看日志；若 HID 报 `probe failed`，逐个试 SB-HID / UITouch |
| 点击位置偏移 | 检查是否横屏；`YGScreenBounds()` 用的是前台窗口 bounds，多窗口/分屏下可能不是你以为的那块屏 |
| 音量减键不停止 | 日志看三层各自状态：`volume 监听: L1=… L2=… L3=…` |
| 点着点着自己停了 | 后端连续失败 10 次会自动停；日志会写 `连续失败` |
| SpringBoard 进安全模式 | `make package DEBUG=1` 看 crash log；最常见是某个 `%hook` 的签名校验被绕过了（改 `YGHookObjectArg` 的 `strncmp` 前缀即可） |

卸载：

```bash
ssh root@192.168.1.23
dpkg -r com.yg.autotapper
# 或 Sileo/Filza 里卸载
rm -f /var/mobile/Documents/AutoTapper.{json,log}
sbreload
```

---

## 10. 已知限制

- **无法跨 App 保持「精确到某个控件」**：坐标是屏幕绝对坐标，
  App 内布局变化（滚动、弹窗、切 tab）后目标点会指到别的东西上。
  这不是 bug，是定点点击的固有属性。
- **HID 事件对某些应用无效**：带反作弊 / 反自动化的 App（银行、部分手游）
  会校验 `IOHIDEvent` 的 `senderID` 或时间戳规律，可能直接忽略。
  此时只能退进程内后端，且大概率也会被检测。
- **rootless 路径**：本工程按 rootless 打包（`THEOS_PACKAGE_SCHEME=rootless`），
  安装目标是 `/var/jb/...`。rootful 设备需要去掉这个变量重新编。
- **iOS 17 上 `sbreload` 可能不存在**，`Makefile` 里已做
  `sbreload || killall -9 SpringBoard` 兜底。
- **无 Preferences 面板**：按需求「可选」，未实现。所有设置都在悬浮球面板里，
  面板关闭后配置已落盘，无需 Settings.bundle。
