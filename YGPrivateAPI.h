//
//  YGPrivateAPI.h — 私有 API 声明与运行时探测接口
//
//  为什么全部手写 typedef / dlsym：
//    1) iOS SDK 里没有 IOHIDEventCreateDigitizerFingerEvent 的公开头文件；
//    2) 私有 framework (IOKit / GraphicsServices / MediaRemote) 静态链接会让
//       链接期就报 undefined symbol，而且把 dylib 变脆（换个 iOS 版本就崩）；
//    3) dlsym 拿不到就说明这个系统上真的没有，可以干净回退。
//
//  ★ AbsoluteTime 在 arm64 上就是 uint64_t。
//    绝对不要写成 {uint64_t hi; uint64_t lo;} —— 那是 16 字节，
//    AAPCS64 下按值传递会吃掉 x2 寄存器，后面所有参数整体错位，
//    表现为「点击坐标全乱 / 点击落在左上角」。
//

#ifndef YG_PRIVATE_API_H
#define YG_PRIVATE_API_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - 基础类型

typedef struct __IOHIDEvent        *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

typedef unsigned int IOOptionBits;
typedef double       IOHIDFloat;
typedef uint64_t     YGAbsoluteTime;      // arm64: mach_absolute_time()

#pragma mark - IOHIDDigitizerTransducerType

#define kYGHIDDigitizerFinger       2
#define kYGHIDDigitizerHand         3

#pragma mark - IOHIDEventType

#define kYGHIDEventTypeDigitizer    4
#define kYGHIDEventTypeKeyboard     3

#pragma mark - IOHIDEventField（IOHIDEventTypes.h 的枚举值，硬编码避免缺头文件）

/* Digitizer 字段 */
#define kYGHIDFieldDigitizerEventMask            2
#define kYGHIDFieldDigitizerX                    3
#define kYGHIDFieldDigitizerY                    4
#define kYGHIDFieldDigitizerZ                    5
#define kYGHIDFieldDigitizerRange                11
#define kYGHIDFieldDigitizerTouch                12
#define kYGHIDFieldDigitizerPressure             13
#define kYGHIDFieldDigitizerIdentity             22
#define kYGHIDFieldDigitizerIsDisplayIntegrated  34

/* Keyboard 字段 = IOHIDEventFieldBase(kIOHIDEventTypeKeyboard) | n
   IOHIDEventFieldBase(type) = (type << 16)，type=3 → 0x00030000 */
#define kYGHIDFieldKeyboardUsagePage   0x00030000
#define kYGHIDFieldKeyboardUsage       0x00030001
#define kYGHIDFieldKeyboardDown        0x00030002

/* HID usage page / usage */
#define kYGHIDPageConsumer             0x0C
#define kYGHIDUsageVolumeDecrement     0xEA      /* 音量减 */

#pragma mark - 函数指针类型

typedef IOHIDEventRef (*PfnCreateDigitizerFinger)(
    CFAllocatorRef allocator,
    YGAbsoluteTime timeStamp,
    uint32_t       index,
    uint32_t       identity,
    uint32_t       eventMask,
    IOHIDFloat     x,
    IOHIDFloat     y,
    IOHIDFloat     z,
    IOHIDFloat     tipPressure,
    IOHIDFloat     twist,
    bool           range,
    bool           touch,
    IOOptionBits   options);

typedef IOHIDEventRef (*PfnCreateDigitizer)(
    CFAllocatorRef allocator,
    YGAbsoluteTime timeStamp,
    uint32_t       transducerType,
    uint32_t       index,
    uint32_t       identity,
    uint32_t       eventMask,
    uint32_t       buttonMask,
    IOHIDFloat     x,
    IOHIDFloat     y,
    IOHIDFloat     z,
    IOHIDFloat     tipPressure,
    IOHIDFloat     barrelPressure,
    bool           range,
    bool           touch,
    IOOptionBits   options);

typedef IOHIDEventSystemClientRef (*PfnCreateClient)(CFAllocatorRef allocator);
typedef IOHIDEventSystemClientRef (*PfnCreateClientWithType)(CFAllocatorRef allocator,
                                                             int clientType,
                                                             CFDictionaryRef properties);
typedef void (*PfnDispatchEvent)(IOHIDEventSystemClientRef client, IOHIDEventRef event);
typedef void (*PfnSetClientMatching)(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
typedef void (*PfnRegisterEventCallback)(IOHIDEventSystemClientRef client,
                                         void *callback,
                                         void *target,
                                         void *refcon);
typedef void (*PfnScheduleWithRunLoop)(IOHIDEventSystemClientRef client,
                                       CFRunLoopRef runLoop,
                                       CFStringRef mode);
typedef void (*PfnUnscheduleFromRunLoop)(IOHIDEventSystemClientRef client,
                                         CFRunLoopRef runLoop,
                                         CFStringRef mode);
typedef void (*PfnSetIntValue)(IOHIDEventRef event, uint32_t field, int32_t value);
typedef void (*PfnSetFloatValue)(IOHIDEventRef event, uint32_t field, IOHIDFloat value);
typedef int32_t  (*PfnGetIntValue)(IOHIDEventRef event, uint32_t field);
typedef void (*PfnAppendEvent)(IOHIDEventRef parent, IOHIDEventRef child);
typedef int    (*PfnGetType)(IOHIDEventRef event);

#pragma mark - 句柄探测

/// 解析所有 IOHID* 符号（幂等，内部 dispatch_once）
void YGHIDResolve(void);

#pragma mark - 点击

/// 用 IOHIDEventSystemClientDispatchEvent 在屏幕全局坐标（竖屏固定 point 系）点一次。
BOOL YGHIDDispatchTap(CGPoint pt, CGFloat holdSeconds);

/// 构造一个 finger 事件（调用方负责 CFRelease）。拒绝落点/参数非法时返回 NULL。
IOHIDEventRef YGHIDCreateFingerEvent(CGPoint pt, uint32_t identity, BOOL touching);

/// 释放事件
void YGHIDRelease(IOHIDEventRef ev);

/// 三个能力位
BOOL YGHIDCanCreateEvent(void);
BOOL YGHIDCanGetSystemClient(void);
BOOL YGHIDCanDispatch(void);

#pragma mark - 音量减（硬件级监听）

/// 回调在专用线程上触发（不是主线程），实现方自己 hop 回主线程。
typedef void (*YGHIDKeyCallback)(uint32_t usagePage, uint32_t usage, BOOL down);

/// 启动键盘 usage 监听。返回 NO 表示客户端创建/注册失败。
BOOL YGHIDStartKeyMonitor(YGHIDKeyCallback cb);

/// 停止并释放
void YGHIDStopKeyMonitor(void);

/// 是否正在监听
BOOL YGHIDKeyMonitorRunning(void);

#pragma mark - 旧 GSEvent（iOS 13/14 兜底，iOS 15+ 默认不启用）

/// GraphicsServices 里 GSSendEvent 是否可用
BOOL YGGSIsAvailable(void);

/// 用 GSEvent 点一次（需要 #define YG_ENABLE_GSEVENT 1 才有实现体）
BOOL YGGSSendTap(CGPoint pt);

#ifdef __cplusplus
}
#endif

#endif /* YG_PRIVATE_API_H */
