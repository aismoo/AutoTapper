//
//  YGTouchInjector.m — 注入后端链（YGInjector）
//
//  后端优先级（auto 模式）：
//    1) HID      : IOHIDEvent + IOHIDEventSystemClientDispatchEvent
//                  ★ 唯一能「从 SpringBoard 打到前台任意 App」的路径
//    2) SPRINGHID: IOHIDEvent + -[UIApplication _enqueueHIDEvent:]
//                  SpringBoard 内部事件队列，iOS 15/16 上常见，iOS 17 部分机型仍在
//    3) UITOUCH  : 伪造 UITouch/UIEvent + -[UIApplication _dispatchTouches:event:]
//                  只在「被注入的进程」内生效（App 注入场景可用，SpringBoard 下发不到 App）
//    4) SENDEVENT: 伪造 UIEvent + -[UIApplication sendEvent:]（公开 API）
//                  连 _dispatchTouches: 都没有时的最后一条路
//    5) GSEVENT  : 仅 iOS 13/14，需 -DYG_ENABLE_GSEVENT=1
//
//  每个后端都「真的会失败」，所以 auto 模式是逐级尝试 + 记住上次成功的那个。
//

#import "YGCore.h"
#import "YGPrivateAPI.h"

#import <objc/message.h>
#import <math.h>
#import <unistd.h>

#pragma mark - 私有 selector 声明

@interface UIApplication (YGPrivateInject)
- (void)_enqueueHIDEvent:(id)event;
- (void)_dispatchTouches:(NSSet *)touches event:(id)event;
- (void)handleEvent:(id)event;          // 部分版本替代 _enqueueHIDEvent:
- (void)_handleHIDEvent:(id)event;
@end

@interface UIWindow (YGPrivateInject)
- (void)_sendTouchesForEvent:(id)event;
@end

#pragma mark - YGInjector

static BOOL gProbed = NO;
static BOOL gHIDOK = NO;
static BOOL gSpringHIDOK = NO;
static BOOL gUITouchOK = NO;
static BOOL gSendEventOK = NO;
static BOOL gGSOK = NO;
static NSString *gLastUsed = @"none";
static YGInjectBackend gPreferred = YGInjectBackendAuto;

/// 私有方法前向声明（实现分散在下面，便于阅读；不声明会报
/// "no visible @interface declares the selector"）
@interface YGInjector (YGInternal)
- (BOOL)_tapAtScreenPointInner:(CGPoint)pt;
- (BOOL)_tapOnMainThread:(CGPoint)pt preferred:(YGInjectBackend)b;
@end

@implementation YGInjector

+ (instancetype)shared {
    static YGInjector *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [YGInjector new]; });
    return s;
}

#pragma mark 探测

- (void)probe {
    if (gProbed) return;

    UIApplication *app = UIApplication.sharedApplication;
    /*
     * ★ 不要在 UIApplication 还不存在时把 probe 结果「锁死」：
     *   %ctor 阶段 UIApplication.sharedApplication 可能是 nil，
     *   一旦 gProbed=YES，SpringHID/UITOUCH/SENDEVENT 就永久被判为不可用，
     *   之后哪怕 SpringBoard 起来了也不会重试 —— 表现为「只有 HID 能用，
     *   切到其他后端全失败」。
     *   HID 那部分不依赖 UIApplication，可以照常算出来，但整体不落锁。
     */
    BOOL appReady = (app != nil);
    if (appReady) gProbed = YES;

    YGHIDResolve();

    // 1) HID：需要「能造 finger 事件」+「能 dispatch」
    gHIDOK = YGHIDCanCreateEvent() && YGHIDCanDispatch();

    // 2) SpringBoard 内部 HID 队列
    BOOL hasEnqueue = NO, hasHandle = NO, hasHandleHID = NO;
    if (app) {
        hasEnqueue   = [app respondsToSelector:NSSelectorFromString(@"_enqueueHIDEvent:")];
        hasHandle    = [app respondsToSelector:NSSelectorFromString(@"handleEvent:")];
        hasHandleHID = [app respondsToSelector:NSSelectorFromString(@"_handleHIDEvent:")];
    }
    gSpringHIDOK = YGHIDCanCreateEvent() && (hasEnqueue || hasHandle || hasHandleHID);

    // 3) UITouch 直投
    gUITouchOK = app && [app respondsToSelector:NSSelectorFromString(@"_dispatchTouches:event:")];

    // 4) sendEvent:（公开，永远在）
    gSendEventOK = (app != nil);

    // 5) GSEvent
    gGSOK = YGGSIsAvailable();

    YGLOG(@"probe: app=%@ HID=%d SPRINGHID=%d(enq=%d handle=%d handleHID=%d) UITOUCH=%d SENDEVENT=%d GS=%d",
          appReady ? @"ready" : @"nil(稍后重试)",
          gHIDOK, gSpringHIDOK, hasEnqueue, hasHandle, hasHandleHID,
          gUITouchOK, gSendEventOK, gGSOK);

    if (!gHIDOK && !gSpringHIDOK && !gUITouchOK) {
        YGLOG(@"probe: ⚠️ 没有可用后端 —— 检查是否注入了 SpringBoard（filter plist）");
    }
}

- (BOOL)hidAvailable        { [self probe]; return gHIDOK; }
- (BOOL)springHIDAvailable  { [self probe]; return gSpringHIDOK; }
- (BOOL)uiTouchAvailable    { [self probe]; return gUITouchOK; }
- (BOOL)gsEventAvailable    { [self probe]; return gGSOK; }

- (void)setBackend:(YGInjectBackend)b {
    gPreferred = b;
    YGConfig.shared.backend = b;
    [YGConfig.shared save];
    YGLOG(@"backend set -> %ld", (long)b);
}
- (YGInjectBackend)backend {
    if (gPreferred == YGInjectBackendAuto) gPreferred = YGConfig.shared.backend;
    return gPreferred;
}

- (NSString *)activeBackendName {
    switch ([self backend]) {
        case YGInjectBackendHID:       return @"HID";
        case YGInjectBackendSpringHID: return @"SPRINGHID";
        case YGInjectBackendUITouch:   return @"UITOUCH";
        case YGInjectBackendGSEvent:   return @"GSEVENT";
        default:
            if ([gLastUsed isEqualToString:@"none"]) {
                [self probe];
                if (gHIDOK) return @"AUTO(HID)";
                if (gSpringHIDOK) return @"AUTO(SPRINGHID)";
                if (gUITouchOK) return @"AUTO(UITOUCH)";
                return @"AUTO(none)";
            }
            return [NSString stringWithFormat:@"AUTO(%@)", gLastUsed];
    }
}

#pragma mark 后端 1：HID dispatch

- (BOOL)_tapHID:(CGPoint)pt {
    if (!gHIDOK) return NO;
    return YGHIDDispatchTap(pt, YGConfig.shared.holdDuration);
}

#pragma mark 后端 2：_enqueueHIDEvent:

- (BOOL)_tapSpringHID:(CGPoint)pt {
    if (!gSpringHIDOK) return NO;
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return NO;

    IOHIDEventRef down = YGHIDCreateFingerEvent(pt, 1, YES);
    if (!down) return NO;

    SEL enq = NSSelectorFromString(@"_enqueueHIDEvent:");
    SEL hdl = NSSelectorFromString(@"handleEvent:");
    SEL hh  = NSSelectorFromString(@"_handleHIDEvent:");
    SEL use = nil;
    if ([app respondsToSelector:enq]) use = enq;
    else if ([app respondsToSelector:hh]) use = hh;
    else if ([app respondsToSelector:hdl]) use = hdl;
    if (!use) { CFRelease(down); return NO; }

    BOOL ok = YES;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(app, use, (__bridge id)(void *)down);
    } @catch (NSException *e) {
        YGLOG(@"SPRINGHID down 抛异常: %@", e.reason);
        ok = NO;
    }
    CFRelease(down);

    if (ok && YGConfig.shared.holdDuration > 0.001) {
        usleep((useconds_t)(YGConfig.shared.holdDuration * 1e6));
    }

    IOHIDEventRef up = YGHIDCreateFingerEvent(pt, 1, NO);
    if (up) {
        if (ok) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(app, use, (__bridge id)(void *)up);
            } @catch (__unused NSException *e) {}
        }
        CFRelease(up);
    }
    return ok;
}

#pragma mark 后端 3/4：UITouch 伪造

/// 造一个 phase 阶段的 UITouch。UIKit 内部靠 ivar 读取坐标，
/// 因此必须 KVC 到 _locationInWindow / _window / _view，缺一个就会崩在
/// -[UITouch locationInView:] 里（2020 年后版本 _view 必须非 nil）。
static UITouch *YGMakeTouch(UIWindow *win, CGPoint pt, UITouchPhase phase, NSTimeInterval ts) {
    UITouch *t = [UITouch new];
    UIView *hit = win;

    @try {
        [t setValue:win forKey:@"_window"];
        [t setValue:hit forKey:@"_view"];
        [t setValue:[NSValue valueWithCGPoint:pt] forKey:@"_locationInWindow"];
        [t setValue:[NSValue valueWithCGPoint:pt] forKey:@"_preciseLocationInWindow"];
        [t setValue:@(phase) forKey:@"_phase"];
        [t setValue:@1 forKey:@"_tapCount"];
        [t setValue:@(ts) forKey:@"_timestamp"];
        [t setValue:@(0) forKey:@"_edgeType"];
    } @catch (NSException *e) {
        YGLOG(@"UITouch KVC 失败: %@", e.reason);
        return nil;
    }
    return t;
}

- (BOOL)_tapUITouch:(CGPoint)pt useSendEvent:(BOOL)useSendEvent {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *win = YGForegroundWindow();
    if (!app || !win) return NO;

    UIEvent *ev = [UIEvent new];
    NSTimeInterval ts = [[NSDate date] timeIntervalSince1970];

    UITouch *t = YGMakeTouch(win, pt, UITouchPhaseBegan, ts);
    if (!t) return NO;

    @try {
        [ev setValue:@(UIEventTypeTouches) forKey:@"_type"];
        [ev setValue:@(ts) forKey:@"_timestamp"];
        [ev setValue:[NSSet setWithObject:t] forKey:@"_touches"];
    } @catch (NSException *e) {
        YGLOG(@"UIEvent KVC 失败: %@", e.reason);
        return NO;
    }

    void (*dispatchFn)(id, SEL, NSSet *, UIEvent *) = NULL;
    SEL sel = NSSelectorFromString(@"_dispatchTouches:event:");
    if (!useSendEvent && [app respondsToSelector:sel]) {
        dispatchFn = (void (*)(id, SEL, NSSet *, UIEvent *))[app methodForSelector:sel];
    }

    BOOL ok = YES;
    @try {
        if (dispatchFn) {
            dispatchFn(app, sel, [NSSet setWithObject:t], ev);
            [t setValue:@(UITouchPhaseEnded) forKey:@"_phase"];
            [t setValue:@(ts + 0.03) forKey:@"_timestamp"];
            dispatchFn(app, sel, [NSSet setWithObject:t], ev);
        } else {
            // 公开 API sendEvent:，UIKit 自己会从 _touches 取事件
            [app sendEvent:ev];
        }
    } @catch (NSException *e) {
        YGLOG(@"UITOUCH 后端抛异常: %@", e.reason);
        ok = NO;
    }

    if (ok) {
        // 窗口级再补一刀：某些 App 的响应链绕过 UIApplication
        SEL wsel = NSSelectorFromString(@"_sendTouchesForEvent:");
        if ([win respondsToSelector:wsel]) {
            @try {
                [win setValue:@(UITouchPhaseEnded) forKey:@"_phase"];
                ((void (*)(id, SEL, id))objc_msgSend)(win, wsel, ev);
            } @catch (__unused NSException *e) {}
        }
    }
    return ok;
}

#pragma mark 对外：点击

/*
 * ★ 线程模型（这里踩过一次大坑，改法写在下面）：
 *
 *   旧实现：needsMain = (backend != HID)。而 auto 模式下 backend 恒为 Auto(0)，
 *   于是 auto 永远 needsMain=YES → dispatch_sync 到主线程 → 在**主线程**里跑
 *   HID 分支的 usleep(holdDuration)。
 *   后果：interval=0.5 时每次卡 SpringBoard 主线程 50ms；interval 调到 0.02 时
 *   变成「每 20ms 睡 50ms」，SpringBoard 直接卡死（掉帧→看门狗→可能重启）。
 *
 *   新实现：先把 auto 解析成「实际会用的后端」，再决定是否需要主线程。
 *   HID 分支永远在调用方自己的串行队列上跑（它不碰 UIKit，只碰 IOHID）。
 */

- (BOOL)tapAtScreenPoint:(CGPoint)pt {
    /*
     * 整窗穿透包住整个 tap：down 和 up 必须落在同一个穿透窗口内，
     * 否则 down 穿透、up 被准星吃掉 → 前台 App 卡在按下态（按钮高亮不弹回，
     * 有些列表会进入长按菜单）。
     * 计数器可重入，嵌套调用安全。
     */
    YGSetTapPassthrough(YES);
    @try {
        return [self _tapAtScreenPointInner:pt];
    } @finally {
        YGSetTapPassthrough(NO);
    }
}

- (BOOL)_tapAtScreenPointInner:(CGPoint)pt {
    CGSize size = YGScreenSize();
    if (pt.x < 0 || pt.y < 0 || pt.x > size.width || pt.y > size.height) {
        YGLOG(@"tap 拒绝：点 (%.1f,%.1f) 越界 (%.0fx%.0f)", pt.x, pt.y, size.width, size.height);
        return NO;
    }

    [self probe];
    YGInjectBackend b = [self backend];

    // HID 可以在任意线程跑（含内部 hold 的 usleep），且不碰 UIKit。
    // auto 模式下如果 HID 可用，就完全不需要主线程。
    BOOL hidPath = (b == YGInjectBackendHID) ||
                   (b == YGInjectBackendAuto && gHIDOK);

    if (hidPath) {
        BOOL ok = [self _tapHID:pt];
        gLastUsed = ok ? @"HID" : @"hid-fail";
        if (ok) return YES;
        if (b == YGInjectBackendHID) return NO;
        // auto 且 HID 失败 → 落到下面的 UIKit 后端链（需要主线程）
    }

    // 其余后端（SPRINGHID / UITOUCH / SENDEVENT / GSEVENT）都会碰 UIKit
    if (!NSThread.isMainThread) {
        __block BOOL r = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            r = [self _tapOnMainThread:pt preferred:b];
        });
        return r;
    }
    return [self _tapOnMainThread:pt preferred:b];
}

/// 只在主线程调用。包含 auto 的逐级回退链。
- (BOOL)_tapOnMainThread:(CGPoint)pt preferred:(YGInjectBackend)b {
    BOOL ok = NO;
    switch (b) {
        case YGInjectBackendSpringHID:
            ok = [self _tapSpringHID:pt]; gLastUsed = ok ? @"SPRINGHID" : @"spring-fail";
            break;
        case YGInjectBackendUITouch:
            ok = [self _tapUITouch:pt useSendEvent:NO]; gLastUsed = ok ? @"UITOUCH" : @"touch-fail";
            break;
        case YGInjectBackendGSEvent:
            ok = YGGSSendTap(pt); gLastUsed = ok ? @"GSEVENT" : @"gs-fail";
            break;
        default: {
            // auto：HID 已在调用方线程试过并失败，这里从 SPRINGHID 继续
            ok = [self _tapSpringHID:pt];
            if (ok) { gLastUsed = @"SPRINGHID"; break; }

            ok = [self _tapUITouch:pt useSendEvent:NO];
            if (ok) { gLastUsed = @"UITOUCH"; break; }

            ok = [self _tapUITouch:pt useSendEvent:YES];
            if (ok) { gLastUsed = @"SENDEVENT"; break; }

            gLastUsed = @"failed";
            break;
        }
    }

    if (!ok) YGLOG(@"tap(%.1f,%.1f) 失败 backend=%ld", pt.x, pt.y, (long)b);
    return ok;
}

@end
