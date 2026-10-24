//
//  YGVolumeButton.m — 音量减键监听（三层兜底）
//
//  ================== iOS 15 / iOS 16 / iOS 17 可用性结论 ==================
//
//  L1  IOHIDEventSystemClient + keyboard usage 0xEA 监听
//      ✅ iOS 13 ~ 17.0 全版本可用（SpringBoard 进程内）
//      这是唯一「音量已经静音到底了再按还能收到」的层，也是唯一不受
//      通话/锁屏/静音开关影响的一层。缺点：需要 IOKit 符号齐全，
//      且回调在非主线程（本文件已 hop 回主线程）。
//
//  L2  AVSystemController_SystemVolumeDidChangeNotification
//      ✅ iOS 15/16/17 仍会随实体按键触发（SpringBoard 进程内可收）
//      ⚠️ 两个坑：
//         a) 音量已经是 0 时再按「减」，音量不变 → **不发通知**；
//         b) 通话中/蓝牙耳机接管时，音量走的是另一条 route，通知可能不触发。
//      因此它只能当 L1 的备份，不能单独用。
//
//  L3  MediaRemote
//      ⚠️ MRMediaRemoteRegisterForNowPlayingNotifications 只给「播放状态」，
//         拿不到音量键；MRMediaRemoteSendCommand 是「发命令」不是「收命令」。
//         真正能收按键的 MediaRemote 私有回调（MRMediaRemoteSetCanBeNowPlayingApplication
//         + 硬编码 command 通道）在 iOS 16 起被收紧，不稳定。
//      ➜ 所以这里用与 L2 等价的、但更贴近 SpringBoard 的替代：
//         SBVolumeHardwareButton / SBVolumeControl 的 -_changeVolumeBy: 动态 swizzle。
//         它比 MediaRemote 可靠得多，且不需要任何 framework 符号。
//
//  ======================================================================
//
//  三层统一 300ms 去抖：一次物理按键会被多层同时看到，只算一次。
//

#import "YGCore.h"
#import "YGPrivateAPI.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - 状态

static BOOL gAVOK = NO;
static BOOL gMediaOK = NO;
static BOOL gKBOK = NO;
static BOOL gSBOK = NO;

static id   gVolumeObserver = nil;
static float gLastVolume = -1.0f;
static NSTimeInterval gLastFire = 0;
static void (^gHandler)(void) = NULL;
static BOOL gInstalled = NO;

static const NSTimeInterval kYGDebounce = 0.30;

#pragma mark - 触发（去抖）

static void YGFireVolumeDown(NSString *source) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - gLastFire < kYGDebounce) {
        return;   // 多层重复触发，忽略
    }
    gLastFire = now;

    YGLOG(@"volume-down 命中 (来源:%@)", source);

    void (^h)(void) = gHandler;
    if (!h) return;
    if (NSThread.isMainThread) h();
    else dispatch_async(dispatch_get_main_queue(), h);
}

#pragma mark - L1：IOHID keyboard

static void YGVolHIDCallback(uint32_t page, uint32_t usage, BOOL down) {
    if (usage != kYGHIDUsageVolumeDecrement) return;
    if (!down) return;              // 只看按下，忽略抬起
    YGFireVolumeDown(@"IOHID-keyboard");
}

#pragma mark - L2：AVSystemController

/*
 * AVSystemController 在 MediaExperience.framework 里（iOS 13+）。
 * SpringBoard 本来就加载了它（音量 HUD 用它），但注入早期可能还没加载，
 * 所以先 dlopen 一遍兜底。
 */
static BOOL YGLoadMediaExperience(void) {
    static BOOL s = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (NSClassFromString(@"AVSystemController")) { s = YES; return; }
        const char *paths[] = {
            "/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience",
            "/System/Library/PrivateFrameworks/Celestial.framework/Celestial",  // iOS 12 及更早
            NULL
        };
        for (int i = 0; paths[i]; i++) {
            dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
            if (NSClassFromString(@"AVSystemController")) break;
        }
        s = (NSClassFromString(@"AVSystemController") != nil);
        YGLOG(@"AVSystemController 可用: %d", s);
    });
    return s;
}

static BOOL YGInstallAVSystem(void) {
    if (!YGLoadMediaExperience()) return NO;

    Class cls = NSClassFromString(@"AVSystemController");
    if (!cls) return NO;

    // +sharedAVSystemController
    id ctrl = nil;
    SEL sharedSel = NSSelectorFromString(@"sharedAVSystemController");
    if ([cls respondsToSelector:sharedSel]) {
        ctrl = ((id (*)(id, SEL))objc_msgSend)(cls, sharedSel);
    }
    if (!ctrl) return NO;

    // 读一次当前音量，作为「降」判据的基线
    SEL volSel = NSSelectorFromString(@"getVolume:forCategory:");
    if ([ctrl respondsToSelector:volSel]) {
        float v = 0;
        BOOL ok = ((BOOL (*)(id, SEL, float *, NSString *))objc_msgSend)(
                      ctrl, volSel, &v, @"Audio/Video");
        if (ok) gLastVolume = v;
    }

    NSString *name = @"AVSystemController_SystemVolumeDidChangeNotification";
    gVolumeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:name
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        NSDictionary *ui = note.userInfo;
        NSString *reason = ui[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"];

        // 只有「用户显式按键」才处理；铃声/静音切换/蓝牙路由变化都会发这条通知
        if (reason && ![reason isEqualToString:@"ExplicitVolumeChange"]) return;

        float newVol = gLastVolume;
        id v = ui[@"AVSystemController_AudioVolumeNotificationParameter"];
        if ([v respondsToSelector:@selector(floatValue)]) newVol = [v floatValue];

        BOOL decreased = (gLastVolume >= 0) && (newVol < gLastVolume - 0.0001f);
        gLastVolume = newVol;

        if (decreased) {
            YGFireVolumeDown(@"AVSystemController");
        }
        // 注意：newVol == 0 且原本就是 0 时 decreased 为 NO，
        // 这条就是「音量到底了收不到」的坑，由 L1/L3 兜住。
    }];

    YGLOG(@"AVSystemController 监听已装");
    return YES;
}

#pragma mark - L3：SpringBoard 内部 swizzle

/*
 * 动态 swizzle：不用 Logos（%hook 需要编译期类名，这几个类在不同 iOS 版本上
 * 名字/方法会变，运行时探测更稳）。
 *
 * 目标：
 *   SBVolumeHardwareButton  -_volumeDownButtonDown:   ← 最直接
 *   SBVolumeControl         -_changeVolumeBy:         ← delta < 0 视为音量减
 */

/*
 * SBVolumeControl -_changeVolumeBy:(float)delta
 *   delta < 0 → 音量减。这个方法在 iOS 13~17 一直存在（SpringBoard 里），
 *   比 AVSystemController 通知更早触发，且音量到底了仍然会被调用。
 * 注意：hook 里必须调用原实现，否则用户按音量键就彻底没声音了。
 */
typedef void (*YGChangeVolFn)(id, SEL, float);
static YGChangeVolFn gOrigChangeVolumeBy = NULL;

static void YGChangeVolumeByHook(id self, SEL _cmd, float delta) {
    if (delta < 0) YGFireVolumeDown(@"SBVolumeControl");
    if (gOrigChangeVolumeBy) gOrigChangeVolumeBy(self, _cmd, delta);
}

/*
 * 无参的 down 回调（某些版本签名是 -_volumeDownButtonDown 不带冒号）。
 * 用 C 函数 + 全局槽保存原 IMP，避免 block 参数签名不匹配。
 */
typedef void (*YGVoidFn)(id, SEL);
static YGVoidFn gOrigVolDownIMP = NULL;
static SEL      gVolDownSEL    = NULL;

static void YGVolDownHook(id self, SEL _cmd) {
    YGFireVolumeDown(@"SBVolumeHardwareButton");
    if (gOrigVolDownIMP) gOrigVolDownIMP(self, _cmd);
}

static BOOL YGInstallSpringBoardHooks(void) {
    BOOL any = NO;

    // --- SBVolumeControl -_changeVolumeBy: ---
    Class vc = NSClassFromString(@"SBVolumeControl");
    if (vc) {
        SEL s1 = NSSelectorFromString(@"_changeVolumeBy:");
        SEL s2 = NSSelectorFromString(@"changeVolumeBy:");
        SEL use = ([vc instancesRespondToSelector:s1] ? s1 :
                   ([vc instancesRespondToSelector:s2] ? s2 : (SEL)NULL));
        if (use) {
            Method m = class_getInstanceMethod(vc, use);
            if (m) {
                gOrigChangeVolumeBy = (YGChangeVolFn)method_getImplementation(m);
                method_setImplementation(m, (IMP)YGChangeVolumeByHook);
                YGLOG(@"L3 SBVolumeControl %@ hook 成功", NSStringFromSelector(use));
                any = YES;
            }
        }
    }

    // --- SBVolumeHardwareButton 无参 down 方法 ---
    Class hb = NSClassFromString(@"SBVolumeHardwareButton");
    if (hb) {
        NSArray<NSString *> *cands = @[ @"_volumeDownButtonDown", @"volumeDownButtonDown" ];
        for (NSString *n in cands) {
            SEL s = NSSelectorFromString(n);
            Method m = class_getInstanceMethod(hb, s);
            if (!m) continue;
            gOrigVolDownIMP = (YGVoidFn)method_getImplementation(m);
            gVolDownSEL = s;
            method_setImplementation(m, (IMP)YGVolDownHook);
            YGLOG(@"L3 SBVolumeHardwareButton %@ hook 成功", n);
            any = YES;
            break;
        }
        (void)gVolDownSEL;
    }

    if (!any) {
        YGLOG(@"L3 未命中：SBVolumeControl / SBVolumeHardwareButton 都不在（iOS 版本差异，正常）");
    }
    return any;
}

#pragma mark - YGVolumeButton

@implementation YGVolumeButton

+ (instancetype)shared {
    static YGVolumeButton *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [YGVolumeButton new]; });
    return s;
}

- (BOOL)avSystemOK   { return gAVOK; }
- (BOOL)mediaRemoteOK{ return gSBOK; }
- (BOOL)hidKeyboardOK{ return gKBOK; }

- (void)installWithHandler:(void (^)(void))handler {
    if (gInstalled) {
        gHandler = [handler copy];
        return;
    }
    gInstalled = YES;
    gHandler = [handler copy];

    YGHIDResolve();

    // L1 硬件层
    gKBOK = YGHIDStartKeyMonitor(YGVolHIDCallback);

    // L2 AVSystemController
    gAVOK = YGInstallAVSystem();

    // L3 SpringBoard 内部
    gSBOK = YGInstallSpringBoardHooks();

    YGLOG(@"volume 监听: HID=%d AVSystem=%d SB=%d", gKBOK, gAVOK, gSBOK);

    if (!gKBOK && !gAVOK && !gSBOK) {
        YGLOG(@"volume 监听: 三层全部失败 —— 只剩悬浮球停止按钮可用");
    }
}

- (void)uninstall {
    if (!gInstalled) return;
    gInstalled = NO;
    gHandler = NULL;

    YGHIDStopKeyMonitor();

    if (gVolumeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:gVolumeObserver];
        gVolumeObserver = nil;
    }
    YGLOG(@"volume 监听已卸载");
}

@end
