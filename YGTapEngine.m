//
//  YGTapEngine.m — 循环点击引擎
//
//  为什么不用 NSTimer / CADisplayLink：
//    * NSTimer 挂在主 runloop，App 忙(掉帧)时漂移严重；某些 App 会长时间改
//      runloop mode（滚动/拖拽期间是 UITrackingRunLoopMode），default mode 的
//      timer 直接被掐停 —— 表现为「滑一下就不点了」。
//    * CADisplayLink 跟屏幕刷新率绑定，120Hz 下等于 8.3ms 一次，纯属浪费。
//
//  这里用 dispatch_source_t(DISPATCH_SOURCE_TYPE_TIMER) 挂在私有串行队列上：
//    * 不受 runloop mode 影响；
//    * leeway 给 2ms，省电；
//    * 用「重入标志」防止 backpressure 堆积 —— 上一 tick 还没点完就跳过本 tick，
//      绝不排队（排队会导致间隔漂移越来越大，最后像连点一样乱）。
//

#import "YGCore.h"
#import "YGPrivateAPI.h"

#import <mach/mach_time.h>

/*
 * 运行标志的跨线程可见性。
 *
 * gYGRunning 由 start/stop 写（主线程），由 tick 读（引擎队列），
 * 而 YGOverlayWindow 的 hitTest 也会从主线程读它来决定是否让行。
 * 用普通 BOOL 的话编译器有权把这个读提到循环外面 —— 表现是
 * 「停止后 hitTest 还在让行」或者相反。这里用 __atomic 收口。
 */
static volatile int32_t gYGRunning = 0;

static inline BOOL YGEngineRunningFlag(void) {
    return __atomic_load_n(&gYGRunning, __ATOMIC_SEQ_CST) != 0;
}

static inline void YGEngineSetRunningFlag(BOOL v) {
    __atomic_store_n(&gYGRunning, v ? 1 : 0, __ATOMIC_SEQ_CST);
}

@interface YGTapEngine ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) BOOL ticking;      // 重入保护
@end

@implementation YGTapEngine {
    NSUInteger _ticks;
    NSUInteger _fails;
    /// 下面两个只通过 __atomic_* 访问，所以不加 volatile：
    /// 加了会让 &_x 变成 volatile T*，在部分 clang 版本上
    /// __atomic_* 内置函数的参数类型推导会报「无法用 volatile T* 初始化 T*」。
    int32_t _consecutiveFails;
    /// 每次 start/stop 自增。restartIfRunning 里延迟重启前要对比它，
    /// 否则「用户在这 60ms 内手动停止」会被那次延迟 start 重新拉起来。
    int32_t _generation;
}

+ (instancetype)shared {
    static YGTapEngine *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [YGTapEngine new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.yg.autotapper.engine",
                                       DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        _ticking = NO;
        YGEngineSetRunningFlag(NO);
    }
    return self;
}

- (BOOL)isRunning { return YGEngineRunningFlag(); }
- (NSUInteger)ticks { return __atomic_load_n(&_ticks, __ATOMIC_RELAXED); }
- (NSUInteger)fails { return __atomic_load_n(&_fails, __ATOMIC_RELAXED); }

#pragma mark - 启停

- (void)start {
    YGConfig *cfg = YGConfig.shared;

    if (!cfg.hasTarget) {
        YGLOG(@"start 被拒：还没标记目标点");
        // 回主线程提示（面板/日志）
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:YGTapEngineDidFailStartNotification object:nil];
        });
        return;
    }
    if (YGEngineRunningFlag()) { YGLOG(@"start 忽略：已在运行"); return; }

    // 夹紧参数，防止用户把 interval 拖到 0 把设备点死
    CGFloat interval = cfg.interval;
    if (interval < 0.02) interval = 0.02;
    if (interval > 60.0) interval = 60.0;

    YGEngineSetRunningFlag(YES);
    __atomic_store_n(&_ticks, (NSUInteger)0, __ATOMIC_RELAXED);
    __atomic_store_n(&_fails, (NSUInteger)0, __ATOMIC_RELAXED);
    __atomic_store_n(&_consecutiveFails, 0, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_generation, 1, __ATOMIC_SEQ_CST);

    YGLOG(@"engine START at (%.1f,%.1f) interval=%.3fs backend=%@",
          cfg.targetPoint.x, cfg.targetPoint.y, interval,
          [YGInjector shared].activeBackendName);

    uint64_t intervalNs = (uint64_t)(interval * NSEC_PER_SEC);
    uint64_t leewayNs   = (uint64_t)MIN(2.0 * NSEC_PER_MSEC, intervalNs / 10);

    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                   0, 0, _queue);
    dispatch_source_set_timer(src,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNs),
                              intervalNs,
                              leewayNs);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(src, ^{
        [weakSelf tick];
    });
    self.timer = src;
    dispatch_resume(src);
}

- (void)stop {
    if (!YGEngineRunningFlag()) return;
    // 先落标志：正在跑的 tick 里的 tapAtScreenPoint 会读它提前退出，
    // 也让 hitTest 立刻恢复正常交互（不必等定时器取消完成）。
    YGEngineSetRunningFlag(NO);
    __atomic_add_fetch(&_generation, 1, __ATOMIC_SEQ_CST);

    dispatch_source_t src = self.timer;
    self.timer = nil;
    if (src) {
        dispatch_source_cancel(src);
    }

    YGLOG(@"engine STOP  ticks=%lu fails=%lu",
          (unsigned long)__atomic_load_n(&_ticks, __ATOMIC_RELAXED),
          (unsigned long)__atomic_load_n(&_fails, __ATOMIC_RELAXED));

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:YGTapEngineDidStopNotification object:nil];
    });
}

#pragma mark - 单次 tick

- (void)tick {
    if (!YGEngineRunningFlag()) return;
    if (_ticking) return;            // 上一 tick 还没跑完 → 跳过，不排队
    _ticking = YES;

    @autoreleasepool {
        YGConfig *cfg = YGConfig.shared;
        CGPoint pt = cfg.targetPoint;

        // 屏幕旋转/尺寸变化后目标点可能落在界外，夹回可视区
        CGSize size = YGScreenSize();
        if (pt.x < 1 || pt.y < 1 || pt.x > size.width - 1 || pt.y > size.height - 1) {
            pt.x = MIN(MAX(pt.x, 1), size.width  - 1);
            pt.y = MIN(MAX(pt.y, 1), size.height - 1);
        }

        BOOL ok = [[YGInjector shared] tapAtScreenPoint:pt];

        NSUInteger n = __atomic_add_fetch(&_ticks, (NSUInteger)1, __ATOMIC_RELAXED);
        if (ok) {
            __atomic_store_n(&_fails, (NSUInteger)0, __ATOMIC_RELAXED);
            __atomic_store_n(&_consecutiveFails, 0, __ATOMIC_RELAXED);
            cfg.tapCount = (NSInteger)n;
        } else {
            __atomic_add_fetch(&_fails, (NSUInteger)1, __ATOMIC_RELAXED);
            int32_t cf = __atomic_add_fetch(&_consecutiveFails, 1, __ATOMIC_RELAXED);
            // 连续失败 10 次基本可以断定后端挂了（例如 App 切前台后 HID 被拒），
            // 自动停，避免空转烧电。
            if (cf >= 10) {
                YGLOG(@"engine 连续失败 %d 次，自动停止", (int)cf);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[YGTapEngine shared] stop];
                });
            }
        }
    }

    _ticking = NO;
}

#pragma mark - 配置变更时重建定时器

- (void)restartIfRunning {
    if (!YGEngineRunningFlag()) return;
    YGLOG(@"engine 配置变化 → 重启定时器");
    int32_t gen = __atomic_load_n(&_generation, __ATOMIC_SEQ_CST);
    [self stop];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        // 60ms 内用户按了停止 / 音量键 → generation 已经变了，不能再拉起来。
        if (__atomic_load_n(&_generation, __ATOMIC_SEQ_CST) != gen + 1) {
            YGLOG(@"engine 重启被取消（期间发生了 stop/start）");
            return;
        }
        [[YGTapEngine shared] start];
    });
}

@end
