//
//  YGConfig.m — 配置持久化
//
//  存到 SpringBoard 的 Documents（/var/mobile/Documents/AutoTapper.json）。
//  rootless 越狱下 /var/mobile 是可写的；如果目标 App 注入（非 SpringBoard），
//  HOME 会变成 App 的容器，配置不共享 —— 这是有意为之：
//  插件在 Apps 里只需要「执行点击」，坐标配置由 SpringBoard 侧统一下发/读取。
//

#import "YGCore.h"

@implementation YGConfig

+ (instancetype)shared {
    static YGConfig *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [YGConfig new];
        [s load];
    });
    return s;
}

- (NSString *)configPath {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [dir stringByAppendingPathComponent:@"AutoTapper.json"];
}

- (void)load {
    _hasTarget       = NO;
    _targetPoint     = CGPointZero;
    _interval        = 0.50;
    _holdDuration    = 0.05;
    _backend         = YGInjectBackendAuto;
    _ballCenter      = CGPointZero;   // 0,0 = 未定 → install 时放到右下角
    _ballAlpha       = 0.85;
    _showCrosshair   = YES;
    _volumeDownStops = YES;
    _ballHidden      = NO;
    _tapCount        = 0;

    NSData *d = [NSData dataWithContentsOfFile:[self configPath]];
    if (!d) return;

    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![j isKindOfClass:[NSDictionary class]]) return;

    if (j[@"x"] && j[@"y"]) {
        _targetPoint = CGPointMake([j[@"x"] doubleValue], [j[@"y"] doubleValue]);
        _hasTarget   = [j[@"hasTarget"] boolValue];
    }
    if (j[@"interval"])        _interval        = MAX(0.02, [j[@"interval"] doubleValue]);
    if (j[@"holdDuration"])    _holdDuration    = MIN(0.2, MAX(0.02, [j[@"holdDuration"] doubleValue]));
    if (j[@"backend"])         _backend         = [j[@"backend"] integerValue];
    if (j[@"ballX"] && j[@"ballY"]) {
        _ballCenter = CGPointMake([j[@"ballX"] doubleValue], [j[@"ballY"] doubleValue]);
    }
    if (j[@"ballAlpha"])       _ballAlpha       = [j[@"ballAlpha"] doubleValue];
    if (j[@"showCrosshair"])   _showCrosshair   = [j[@"showCrosshair"] boolValue];
    if (j[@"volumeDownStops"]) _volumeDownStops = [j[@"volumeDownStops"] boolValue];
    if (j[@"ballHidden"])      _ballHidden      = [j[@"ballHidden"] boolValue];
    if (j[@"tapCount"])        _tapCount        = [j[@"tapCount"] integerValue];

    YGLOG(@"config loaded: target=(%.1f,%.1f) has=%d interval=%.3f backend=%ld",
          _targetPoint.x, _targetPoint.y, _hasTarget, _interval, (long)_backend);
}

- (void)save {
    NSDictionary *j = @{
        @"x":               @(_targetPoint.x),
        @"y":               @(_targetPoint.y),
        @"hasTarget":       @(_hasTarget),
        @"interval":        @(_interval),
        @"holdDuration":    @(_holdDuration),
        @"backend":         @(_backend),
        @"ballX":           @(_ballCenter.x),
        @"ballY":           @(_ballCenter.y),
        @"ballAlpha":       @(_ballAlpha),
        @"showCrosshair":   @(_showCrosshair),
        @"volumeDownStops": @(_volumeDownStops),
        @"ballHidden":      @(_ballHidden),
        @"tapCount":        @(_tapCount),
        @"screenW":         @(YGScreenSize().width),
        @"screenH":         @(YGScreenSize().height),
        @"updated":         @([[NSDate date] timeIntervalSince1970]),
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:j
                                                options:NSJSONWritingPrettyPrinted
                                                  error:NULL];
    [d writeToFile:[self configPath] atomically:YES];
}

@end
