//
//  YGHID.m — IOHIDEvent 私有 API：点击注入 + 硬件音量键监听
//
//  ============================ iOS 17 rootless 可用性结论 ============================
//
//  | 符号                                              | iOS 17.0 | 说明 |
//  |---------------------------------------------------|----------|------|
//  | IOHIDEventCreateDigitizerFingerEvent               |  ✅ 在    | IOKit 私有，未被移除 |
//  | IOHIDEventCreateDigitizerEvent                     |  ✅ 在    | 用于包一层 hand |
//  | IOHIDEventSystemClientCreate                       |  ✅ 在    | |
//  | IOHIDEventSystemClientCreateWithType               |  ✅ 在    | type=1 (Inject) 最稳 |
//  | IOHIDEventSystemClientDispatchEvent                |  ✅ 在    | 关键：仍需在 SpringBoard 里调用 |
//  | IOHIDEventSetIntegerValue / SetFloatValue          |  ✅ 在    | |
//  | IOHIDEventSystemClientRegisterEventCallback        |  ✅ 在    | 音量键硬件监听 |
//  | GSSendEvent / GSEventRecord                        |  ⚠️ 失效   | iOS 15 起 purple port 拒收进程外事件 |
//
//  结论：**IOHIDEvent 系列在 iOS 17 rootless 上依然可用**，这是本插件的主路径。
//        GSEvent 已死，因此只保留为 #if YG_ENABLE_GSEVENT 的考古分支。
//
//  为什么一定要在 SpringBoard 进程里 dispatch：
//    IOHIDEventSystemClientDispatchEvent 把事件交给本进程的 HID event system
//    再走 IOHIDEventSystem → backboardd → 前台 App 的链。
//    只有 SpringBoard（有 backboard 相关 entitlement）这条路能穿透到前台 App；
//    注入到某个 App 内部时，事件只在该 App 自己的 HID 栈里打转（甚至没有 client）。
//
// ==================================================================================
//

#import "YGCore.h"
#import "YGPrivateAPI.h"

#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>
#import <pthread.h>
#import <unistd.h>

#pragma mark - 符号表

static PfnCreateDigitizerFinger   pCreateFinger    = NULL;
static PfnCreateDigitizer         pCreateDigitizer = NULL;
static PfnCreateClient            pCreateClient    = NULL;
static PfnCreateClientWithType    pCreateClientTyped = NULL;
static PfnDispatchEvent           pDispatch        = NULL;
static PfnSetIntValue             pSetInt          = NULL;
static PfnSetFloatValue           pSetFloat        = NULL;
static PfnGetIntValue             pGetInt          = NULL;
static PfnAppendEvent             pAppend          = NULL;
static PfnGetType                 pGetType         = NULL;

static PfnSetClientMatching       pSetMatching     = NULL;
static PfnRegisterEventCallback   pRegisterCB      = NULL;
static PfnScheduleWithRunLoop     pScheduleRL      = NULL;
static PfnUnscheduleFromRunLoop   pUnscheduleRL    = NULL;

static void *pRegisterCBBlock = NULL;   /* IOHIDEventSystemClientRegisterEventBlock */
static void *pUnregisterCB    = NULL;

static IOHIDEventSystemClientRef gEventClient = NULL;   /* 注入用 client */
static int   gClientType      = -2;                     /* 实际用到的 client type */
static BOOL  gResolved        = NO;
static BOOL  gInjectClientOK  = NO;

static uint64_t YGNow(void) { return (uint64_t)mach_absolute_time(); }

#pragma mark - 符号解析

static void *YGDlopenIOKit(void) {
    static void *h = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *paths[] = {
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            "/usr/lib/libIOKit.dylib",
            NULL
        };
        for (int i = 0; paths[i]; i++) {
            h = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
            if (h) break;
        }
        if (!h) h = dlopen(NULL, RTLD_NOW);   // 全局符号表兜底
    });
    return h;
}

void YGHIDResolve(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = YGDlopenIOKit();
        if (!h) {
            YGLOG(@"HID: dlopen IOKit 失败");
            gResolved = YES;
            return;
        }

        pCreateFinger     = (PfnCreateDigitizerFinger)dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
        pCreateDigitizer  = (PfnCreateDigitizer)dlsym(h, "IOHIDEventCreateDigitizerEvent");
        pCreateClient     = (PfnCreateClient)dlsym(h, "IOHIDEventSystemClientCreate");
        pCreateClientTyped= (PfnCreateClientWithType)dlsym(h, "IOHIDEventSystemClientCreateWithType");
        pDispatch         = (PfnDispatchEvent)dlsym(h, "IOHIDEventSystemClientDispatchEvent");
        pSetInt           = (PfnSetIntValue)dlsym(h, "IOHIDEventSetIntegerValue");
        pSetFloat         = (PfnSetFloatValue)dlsym(h, "IOHIDEventSetFloatValue");
        pGetInt           = (PfnGetIntValue)dlsym(h, "IOHIDEventGetIntegerValue");
        pAppend           = (PfnAppendEvent)dlsym(h, "IOHIDEventAppendEvent");
        pGetType          = (PfnGetType)dlsym(h, "IOHIDEventGetType");

        pSetMatching      = (PfnSetClientMatching)dlsym(h, "IOHIDEventSystemClientSetMatching");
        pRegisterCB       = (PfnRegisterEventCallback)dlsym(h, "IOHIDEventSystemClientRegisterEventCallback");
        pScheduleRL       = (PfnScheduleWithRunLoop)dlsym(h, "IOHIDEventSystemClientScheduleWithRunLoop");
        pUnscheduleRL     = (PfnUnscheduleFromRunLoop)dlsym(h, "IOHIDEventSystemClientUnscheduleFromRunLoop");
        pRegisterCBBlock  = dlsym(h, "IOHIDEventSystemClientRegisterEventBlock");
        pUnregisterCB     = dlsym(h, "IOHIDEventSystemClientUnregisterEventCallback");

        gResolved = YES;
        YGLOG(@"HID symbols: finger=%p digitizer=%p client=%p clientTyped=%p dispatch=%p",
              pCreateFinger, pCreateDigitizer, pCreateClient, pCreateClientTyped, pDispatch);
        YGLOG(@"HID symbols: setInt=%p setFloat=%p append=%p getInt=%p getType=%p",
              pSetInt, pSetFloat, pAppend, pGetInt, pGetType);
        YGLOG(@"HID symbols: setMatching=%p regCB=%p regCBBlock=%p schedRL=%p",
              pSetMatching, pRegisterCB, pRegisterCBBlock, pScheduleRL);
    });
}

BOOL YGHIDCanCreateEvent(void)  { YGHIDResolve(); return pCreateFinger != NULL; }
BOOL YGHIDCanGetSystemClient(void) { YGHIDResolve(); return (pCreateClientTyped != NULL || pCreateClient != NULL); }
BOOL YGHIDCanDispatch(void)     { YGHIDResolve(); return pDispatch != NULL; }

#pragma mark - client

/*
 * IOHIDEventSystemClientType（IOKit 私有枚举，各版本数值不完全一致）：
 *   iOS 12/13:  0 = Unknown, 1 = Monitor, 2 = Inject, 3 = Administrator
 *   iOS 14+:    0 = Unknown, 1 = Monitor, 2 = Inject, 3 = Administrator, 4 = Simple
 *
 * ⚠️ 这里不能硬编码某个数字就当 Inject 用 —— 传错值时
 *    IOHIDEventSystemClientCreateWithType 有两种失败模式：
 *      a) 返回 NULL（好情况，能发现）
 *      b) 返回一个 Monitor 类型的 client（坏情况）：创建成功、dispatch 也不报错，
 *         但事件被当作「监听输出」而不是「注入输入」，backboardd 直接丢弃 →
 *         表现就是「代码全跑通，屏幕没反应」。
 *
 * 所以做法是：从 Inject(2) 开始逐个尝试，谁建成功用谁，
 * 并且把实际用的 type 打进日志，方便出问题时一眼看出踩了哪个分支。
 */
static IOHIDEventSystemClientRef YGInjectClient(void) {
    YGHIDResolve();
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (pCreateClientTyped) {
            // 候选顺序：2(Inject，iOS13/14+ 正确值) → 1(Monitor，某些旧版本 Inject 在 1)
            const int candidates[] = { 2, 1 };
            for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
                gEventClient = pCreateClientTyped(kCFAllocatorDefault,
                                                  candidates[i], NULL);
                if (gEventClient) {
                    gClientType = candidates[i];
                    YGLOG(@"HID client 类型 %d 创建成功", candidates[i]);
                    break;
                }
                YGLOG(@"HID client 类型 %d 创建失败，试下一个", candidates[i]);
            }
        }
        if (!gEventClient && pCreateClient) {
            gEventClient = pCreateClient(kCFAllocatorDefault);
            gClientType = -1;   // 未指定类型的老 API
            YGLOG(@"HID client 走无类型老 API");
        }
        gInjectClientOK = (gEventClient != NULL) && (pDispatch != NULL);
        YGLOG(@"HID inject client = %p type=%d ok=%d", gEventClient, gClientType, gInjectClientOK);
    });
    return gEventClient;
}

#pragma mark - 事件构造

IOHIDEventRef YGHIDCreateFingerEvent(CGPoint pt, uint32_t identity, BOOL touching) {
    YGHIDResolve();
    if (!pCreateFinger) return NULL;
    if (isnan(pt.x) || isnan(pt.y)) return NULL;

    // range | touch | position
    //   kIOHIDDigitizerEvent_Range    = 0x01
    //   kIOHIDDigitizerEvent_Touch    = 0x02
    //   kIOHIDDigitizerEvent_Position = 0x04
    uint32_t mask = touching ? 0x07 : 0x03;

    IOHIDEventRef finger = pCreateFinger(
        kCFAllocatorDefault,
        YGNow(),
        0,                                   // index
        identity,                            // identity（同一指必须一致）
        mask,
        (IOHIDFloat)pt.x,
        (IOHIDFloat)pt.y,
        0.0,                                 // z
        touching ? 1.0 : 0.0,                // tipPressure
        0.0,                                 // twist
        touching,                            // range
        touching,                            // touch
        0);                                  // options

    if (!finger) return NULL;

    if (pSetInt) {
        pSetInt(finger, kYGHIDFieldDigitizerEventMask, (int32_t)mask);
        pSetInt(finger, kYGHIDFieldDigitizerRange, touching ? 1 : 0);
        pSetInt(finger, kYGHIDFieldDigitizerTouch, touching ? 1 : 0);
        // iOS 15+ 的 backboardd 会校验 display integrated，置 1 才能落到前台 App
        pSetInt(finger, kYGHIDFieldDigitizerIsDisplayIntegrated, 1);
    }
    if (pSetFloat) {
        pSetFloat(finger, kYGHIDFieldDigitizerPressure, touching ? 1.0 : 0.0);
    }
    return finger;
}

void YGHIDRelease(IOHIDEventRef ev) {
    if (ev) CFRelease(ev);
}

/// 把 finger 包进 hand 事件。部分 App（尤其 Unity/UE 手游）只认顶层 hand 的 phase，
/// 直接用裸 finger 会被它们的输入层忽略。包一层能显著提高兼容率。
static IOHIDEventRef YGWrapInHand(IOHIDEventRef finger, CGPoint pt, BOOL touching) {
    if (!pCreateDigitizer || !pAppend || !finger) return NULL;

    IOHIDEventRef hand = pCreateDigitizer(
        kCFAllocatorDefault,
        YGNow(),
        kYGHIDDigitizerHand,                 // transducerType
        0,                                   // index
        0,                                   // identity
        touching ? 0x07 : 0x03,               // eventMask
        0,                                   // buttonMask
        (IOHIDFloat)pt.x,
        (IOHIDFloat)pt.y,
        0.0,
        touching ? 1.0 : 0.0,
        0.0,
        touching,
        touching,
        0);
    if (!hand) return NULL;

    if (pSetInt) {
        pSetInt(hand, kYGHIDFieldDigitizerIsDisplayIntegrated, 1);
    }
    pAppend(hand, finger);
    return hand;
}

#pragma mark - 点击

BOOL YGHIDDispatchTap(CGPoint pt, CGFloat holdSeconds) {
    IOHIDEventSystemClientRef client = YGInjectClient();
    if (!client || !pDispatch) {
        YGLOG(@"HID: no client / no dispatch");
        return NO;
    }

    // 固定 identity：同一次点击的 down/up 必须共用，否则系统会当成两根不同的手指，
    // 表现是「有的 App 只收到 touchDown 没有 touchUp」→ 界面卡在按下态。
    static uint32_t sIdentity = 1;
    uint32_t identity = sIdentity;
    sIdentity = (sIdentity % 1000) + 1;

    IOHIDEventRef fingerDown = YGHIDCreateFingerEvent(pt, identity, YES);
    if (!fingerDown) {
        YGLOG(@"HID: createFinger(down) 失败");
        return NO;
    }

    @try {
        IOHIDEventRef handDown = YGWrapInHand(fingerDown, pt, YES);
        if (handDown) {
            // hand 持有 finger（append 内部 retain），释放 hand 即可
            pDispatch(client, handDown);
            CFRelease(handDown);
        } else {
            pDispatch(client, fingerDown);
        }
    } @catch (NSException *e) {
        YGLOG(@"HID: dispatch(down) 抛异常 %@", e.reason);
        CFRelease(fingerDown);
        return NO;
    }
    CFRelease(fingerDown);

    if (holdSeconds > 0.001) {
        // 在调用方的串行队列上睡，**不占主线程**
        usleep((useconds_t)(holdSeconds * 1000000.0));
    }

    IOHIDEventRef fingerUp = YGHIDCreateFingerEvent(pt, identity, NO);
    if (!fingerUp) return YES;   // down 已经成功，至少算「点到了」

    @try {
        IOHIDEventRef handUp = YGWrapInHand(fingerUp, pt, NO);
        if (handUp) {
            pDispatch(client, handUp);
            CFRelease(handUp);
        } else {
            pDispatch(client, fingerUp);
        }
    } @catch (NSException *e) {
        YGLOG(@"HID: dispatch(up) 抛异常 %@", e.reason);
    }
    CFRelease(fingerUp);

    return YES;
}

#pragma mark - 硬件音量键监听

typedef struct {
    IOHIDEventSystemClientRef client;
    CFRunLoopRef              runloop;
    NSThread                 *thread;
    volatile BOOL             running;
    volatile BOOL             scheduled;
} YGKeyMonitor;

static YGKeyMonitor gKeyMon = { NULL, NULL, NULL, NO, NO };
static YGHIDKeyCallback gKeyCB = NULL;
static pthread_mutex_t gKeyLock = PTHREAD_MUTEX_INITIALIZER;

/// 真实回调签名（C 函数指针版）：
///   void cb(void *target, void *refcon, IOHIDServiceClientRef service, IOHIDEventRef event)
static void YGKeyEventCallback(void *target, void *refcon,
                               IOHIDServiceClientRef service, IOHIDEventRef event) {
    if (!event || !gKeyCB) return;
    if (!pGetInt) return;

    // 只处理 keyboard 类型
    if (pGetType && pGetType(event) != kYGHIDEventTypeKeyboard) return;

    int32_t page  = pGetInt(event, kYGHIDFieldKeyboardUsagePage);
    int32_t usage = pGetInt(event, kYGHIDFieldKeyboardUsage);
    int32_t down  = pGetInt(event, kYGHIDFieldKeyboardDown);

    if (page != 0 && page != kYGHIDPageConsumer) {
        // 有些固件 page 报 0，只靠 usage 判断
    }
    if (usage != kYGHIDUsageVolumeDecrement) return;

    gKeyCB((uint32_t)(page ? page : kYGHIDPageConsumer),
           (uint32_t)usage,
           down ? YES : NO);
}

BOOL YGHIDStartKeyMonitor(YGHIDKeyCallback cb) {
    YGHIDResolve();
    if (!cb) return NO;
    if (!pCreateClient || !pSetMatching || (!pRegisterCB && !pRegisterCBBlock)) {
        YGLOG(@"HID key: 缺少 client/matching/callback 符号");
        return NO;
    }

    pthread_mutex_lock(&gKeyLock);
    if (gKeyMon.running) {
        gKeyCB = cb;
        pthread_mutex_unlock(&gKeyLock);
        return YES;
    }
    gKeyCB = cb;

    IOHIDEventSystemClientRef client = NULL;
    // 监听用 Monitor 类型（1）；建不出来就退回无类型老 API
    if (pCreateClientTyped) client = pCreateClientTyped(kCFAllocatorDefault, 1 /*Monitor*/, NULL);
    if (!client) client = pCreateClient(kCFAllocatorDefault);
    if (!client) {
        pthread_mutex_unlock(&gKeyLock);
        YGLOG(@"HID key: client 创建失败");
        return NO;
    }
    gKeyMon.client = client;

    // 只匹配 Consumer page 的 Volume Decrement 服务，减少无关事件洪泛
    NSDictionary *matching = @{
        @"PrimaryUsagePage" : @(kYGHIDPageConsumer),
        @"PrimaryUsage"     : @(kYGHIDUsageVolumeDecrement),
    };
    pSetMatching(client, (__bridge CFDictionaryRef)matching);

    if (pRegisterCB) {
        pRegisterCB(client, (void *)YGKeyEventCallback, NULL, NULL);
        YGLOG(@"HID key: 用 C callback 注册成功");
    } else {
        // 新版只暴露 block 版本。**必须 copy 到堆上**：
        // 栈 block 在函数返回后就失效，回调时是野指针（表现为偶发崩溃或按键失灵）。
        typedef void (*PfnRegBlock)(IOHIDEventSystemClientRef, id, void *, void *);
        PfnRegBlock fn = (PfnRegBlock)pRegisterCBBlock;
        id block = [^(void *target, void *refcon, IOHIDServiceClientRef service, IOHIDEventRef event) {
            YGKeyEventCallback(target, refcon, service, event);
        } copy];
        static id sKeyBlock = nil;
        sKeyBlock = block;      // 全局强引用，防止被释放
        fn(client, block, NULL, NULL);
        YGLOG(@"HID key: 用 block 注册成功");
    }

    // 专用线程跑 runloop —— 不污染 SpringBoard 主 runloop（主线程 mode 常被切换）
    gKeyMon.running = YES;
    __weak typeof(NSObject) *weakGuard = nil; (void)weakGuard;

    NSThread *th = [[NSThread alloc] initWithBlock:^{
        CFRunLoopRef rl = CFRunLoopGetCurrent();
        gKeyMon.runloop = (CFRunLoopRef)CFRetain(rl);
        if (pScheduleRL) {
            pScheduleRL(gKeyMon.client, rl, kCFRunLoopDefaultMode);
            gKeyMon.scheduled = YES;
        }
        YGLOG(@"HID key: runloop 线程启动");
        while (gKeyMon.running) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, true);
            }
        }
        if (gKeyMon.scheduled && pUnscheduleRL) {
            pUnscheduleRL(gKeyMon.client, rl, kCFRunLoopDefaultMode);
        }
        YGLOG(@"HID key: runloop 线程退出");
    }];
    th.name = @"AutoTapper.HIDKey";
    th.qualityOfService = NSQualityOfServiceUserInteractive;
    gKeyMon.thread = th;
    [th start];

    pthread_mutex_unlock(&gKeyLock);
    return YES;
}

void YGHIDStopKeyMonitor(void) {
    pthread_mutex_lock(&gKeyLock);
    if (!gKeyMon.running && !gKeyMon.client) {
        pthread_mutex_unlock(&gKeyLock);
        return;
    }
    gKeyMon.running = NO;

    if (gKeyMon.client && pUnregisterCB) {
        typedef void (*PfnUnreg)(IOHIDEventSystemClientRef, void *);
        ((PfnUnreg)pUnregisterCB)(gKeyMon.client, (void *)YGKeyEventCallback);
    }

    CFRunLoopRef rl = gKeyMon.runloop;
    if (rl) {
        CFRunLoopStop(rl);
        CFRunLoopWakeUp(rl);
    }

    IOHIDEventSystemClientRef client = gKeyMon.client;
    gKeyMon.client = NULL;
    pthread_mutex_unlock(&gKeyLock);

    // 给线程 200ms 收尾，再放掉 runloop / client
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (rl) CFRelease(rl);
        if (client) CFRelease(client);
        gKeyMon.runloop = NULL;
        gKeyMon.scheduled = NO;
    });
}

BOOL YGHIDKeyMonitorRunning(void) {
    return gKeyMon.running;
}

#pragma mark - 旧 GSEvent（iOS 13/14 考古，默认不编译）

#if YG_ENABLE_GSEVENT

#import <sys/socket.h>

/*
 * iOS 15+ 已不可用：SpringBoard 通过 purple port 收事件，且对 GSEventRecord 做了
 * 签名/来源校验；进程内伪造的 record 会被直接丢弃（无报错，只是没反应）。
 * 保留仅为在 iOS 13/14 上做对照实验。
 */

typedef struct __GSEvent *GSEventRef;
typedef struct GSEventRecord GSEventRecord;

typedef GSEventRef (*PfnGSCreateGSEvent)(void *);
typedef void (*PfnGSSendEvent)(GSEventRecord *record, mach_port_t port);

static PfnGSSendEvent pGSSendEvent = NULL;
static BOOL gGSResolved = NO;

BOOL YGGSIsAvailable(void) {
    if (gGSResolved) return pGSSendEvent != NULL;
    gGSResolved = YES;
    void *h = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
                     RTLD_NOW);
    if (!h) return NO;
    pGSSendEvent = (PfnGSSendEvent)dlsym(h, "GSSendEvent");
    YGLOG(@"GSEvent: GSSendEvent=%p", pGSSendEvent);
    return pGSSendEvent != NULL;
}

BOOL YGGSSendTap(CGPoint pt) {
    if (!YGGSIsAvailable()) return NO;
    // 无公开的 record 构造函数，这里只做符号可用性探测；
    // 真正发事件需要按 iOS 版本匹配 GSEventRecord 二进制布局，风险高，不实现。
    YGLOG(@"GSEvent: 目标系统不支持构造 record，跳过 (%.1f,%.1f)", pt.x, pt.y);
    return NO;
}

#else

BOOL YGGSIsAvailable(void) {
    static BOOL s = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
                         RTLD_NOW);
        BOOL hasSend = h && dlsym(h, "GSSendEvent");
        YGLOG(@"GSEvent: 符号 %s（iOS 15+ 已不接收进程外伪造事件，仅用于探测）",
              hasSend ? "存在" : "缺失");
    });
    return s;
}

BOOL YGGSSendTap(CGPoint pt) { return NO; }

#endif
