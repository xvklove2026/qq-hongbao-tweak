#import "QQHB.h"
#import "QQHBConfig.h"

static NSDictionary *QQHBDefaultConfig(void) {
    return @{
        @"enabled": @YES,
        // 诊断模式：只把 QQ 里疑似红包的类和方方法打印到日志，不做拦截
        @"diagnose": @YES,
        // 自己发的红包也抢
        @"grabOwnPackets": @YES,
        // 专属红包不抢
        @"skipExclusive": @YES,
        // 标题/祝福语命中这些词就不抢
        @"skipTitleKeywords": @[@"专属", @"测试"],
        // 非空时：标题必须命中其中之一才抢
        @"grabKeywords": @[],
        // 抢之前的人为延迟（毫秒）：取 delayMs ~ delayMaxMs 之间的随机值
        @"delayMs": @0,
        @"delayMaxMs": @0,
        // 自己的 QQ 号；senderUin 与之相同视为自己发的
        @"selfUin": @"",
        // 这些数字类型值视为专属红包
        @"exclusiveTypes": @[],
        // 真正生效的抢包方法：@[ @{@"class": @"...", @"selector": @"..."} ]
        @"grabHooks": @[]
    };
}

@implementation QQHBConfig {
    NSDictionary *_dict;
}

+ (instancetype)shared {
    static QQHBConfig *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[QQHBConfig alloc] init]; [c reload]; });
    return c;
}

- (void)reload {
    NSDictionary *defaults = QQHBDefaultConfig();
    NSString *path = QQHBConfigPath();
    NSDictionary *loaded = nil;
    if (path) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) loaded = obj;
        }
    }
    if (!loaded) {
        // 首次运行：写出默认配置，方便用户编辑
        loaded = defaults;
        NSData *out = [NSJSONSerialization dataWithJSONObject:defaults
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:NULL];
        [out writeToFile:path atomically:YES];
        QQHBLog(@"已写入默认配置: %@", path);
    }
    NSMutableDictionary *merged = [defaults mutableCopy];
    [merged addEntriesFromDictionary:loaded];
    _dict = merged;
}

- (BOOL)boolForKey:(NSString *)k dflt:(BOOL)d {
    id v = _dict[k];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : d;
}

- (BOOL)enabled { return [self boolForKey:@"enabled" dflt:YES]; }
- (BOOL)diagnose { return [self boolForKey:@"diagnose" dflt:YES]; }
- (BOOL)grabOwnPackets { return [self boolForKey:@"grabOwnPackets" dflt:YES]; }
- (BOOL)skipExclusive { return [self boolForKey:@"skipExclusive" dflt:YES]; }

- (NSInteger)delayMs {
    id v = _dict[@"delayMs"];
    return [v isKindOfClass:[NSNumber class]] ? [v integerValue] : 0;
}

- (NSInteger)delayMaxMs {
    id v = _dict[@"delayMaxMs"];
    NSInteger max = [v isKindOfClass:[NSNumber class]] ? [v integerValue] : 0;
    return MAX(max, self.delayMs);
}

- (NSString *)selfUin {
    id v = _dict[@"selfUin"];
    return [v isKindOfClass:[NSString class]] ? [v stringByTrimmingCharactersInSet:
                                                [NSCharacterSet whitespaceCharacterSet]] : @"";
}

- (NSArray<NSNumber *> *)exclusiveTypes {
    id v = _dict[@"exclusiveTypes"];
    if (![v isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in (NSArray *)v) {
        if ([item isKindOfClass:[NSNumber class]]) [out addObject:item];
    }
    return out;
}

- (NSArray<NSString *> *)stringArrayForKey:(NSString *)key {
    id v = _dict[key];
    if (![v isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in (NSArray *)v) {
        if ([item isKindOfClass:[NSString class]]) [out addObject:item];
    }
    return out;
}

- (NSArray<NSString *> *)skipTitleKeywords { return [self stringArrayForKey:@"skipTitleKeywords"]; }
- (NSArray<NSString *> *)grabKeywords { return [self stringArrayForKey:@"grabKeywords"]; }

- (NSArray<NSDictionary *> *)grabHooks {
    id v = _dict[@"grabHooks"];
    NSMutableArray *out = [NSMutableArray array];
    if ([v isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)v) {
            if ([item isKindOfClass:[NSDictionary class]]) [out addObject:item];
        }
    }
    if (out.count == 0) {
        /* 9.3.x 上诊断出来的真实入口：QQWallet 的抢包 API */
        return @[
            @{@"class": @"QQWallet",
              @"selector": @"grabRedPack:params:completion:"},
            @{@"class": @"QQWallet",
              @"selector": @"grabHB:params:completion:"},
            @{@"class": @"QQWalletGrapHBService",
              @"selector": @"buildPreGrabReqWithAIOData:"}
        ];
    }
    return out;
}

- (BOOL)containsAny:(NSArray<NSString *> *)words in:(NSString *)text {
    if (text.length == 0) return NO;
    for (NSString *w in words) {
        if (w.length && [text rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

- (BOOL)shouldSkipTitle:(NSString *)title {
    return [self containsAny:self.skipTitleKeywords in:title];
}

- (BOOL)titleWanted:(NSString *)title {
    NSArray *want = self.grabKeywords;
    if (want.count == 0) return YES;
    return [self containsAny:want in:title];
}

@end
