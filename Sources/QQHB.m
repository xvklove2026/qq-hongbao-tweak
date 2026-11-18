#import <dlfcn.h>
#include <ctype.h>
#include <stdlib.h>
#include <unistd.h>
#import "QQHB.h"
#import "QQHBConfig.h"
#import "QQHBStats.h"

#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "dev"
#endif
#ifndef QQHB_GIT_REV
#define QQHB_GIT_REV "unknown"
#endif

static NSString *const kQQHBStatsFileName = @"stats.json";

#pragma mark - 基础工具

os_log_t QQHBLogHandle(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = os_log_create(QQHB_SUBSYSTEM, "engine"); });
    return handle;
}

void QQHBLogMsg(NSString *msg) {
    const char *s = msg.UTF8String ?: "";
    os_log(QQHBLogHandle(), "%{public}s", s);
}

NSString *QQHBSupportDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *home = NSHomeDirectory();
        dir = [home stringByAppendingPathComponent:@"Library/Application Support/QQHongbao"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
    });
    return dir;
}

NSString *QQHBConfigPath(void) {
    return [QQHBSupportDir() stringByAppendingPathComponent:@"config.json"];
}

NSString *QQHBStatsPath(void) {
    return [QQHBSupportDir() stringByAppendingPathComponent:kQQHBStatsFileName];
}

id QQHBKVCFirst(id obj, NSArray<NSString *> *keys) {
    if (!obj || obj == (id)[NSNull null]) return nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in keys) {
            id v = [(NSDictionary *)obj objectForKey:k];
            if (v) return v;
        }
        return nil;
    }
    for (NSString *k in keys) {
        @try {
            id v = [obj valueForKey:k];
            if (v) return v;
        } @catch (__unused NSException *e) {
        }
    }
    return nil;
}

NSString *QQHBStringOf(id value) {
    if (!value || value == (id)[NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) return nil;
    @try {
        return [value description];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

#pragma mark - 红包字段读取

static NSArray<NSString *> *QQHBUinKeys(void) {
    return @[@"senderUin", @"senderUinString", @"sendUin", @"sendUinString", @"senderQQ",
             @"sender", @"uin", @"peerUin", @"senderUid"];
}

static NSArray<NSString *> *QQHBNameKeys(void) {
    return @[@"senderName", @"senderNickName", @"sendNickName", @"senderNick", @"nickName",
             @"nick", @"senderDisplayName", @"name"];
}

static NSArray<NSString *> *QQHBTitleKeys(void) {
    return @[@"title", @"wishing", @"wish", @"message", @"wording", @"desc", @"subTitle",
             @"wishingText", @"content"];
}

static NSArray<NSString *> *QQHBAmountKeys(void) {
    return @[@"amount", @"money", @"grabAmount", @"totalAmount", @"redPackAmount",
             @"amountString", @"moneyString", @"grabAmountString"];
}

static NSArray<NSString *> *QQHBExclusiveFlagKeys(void) {
    return @[@"isExclusive", @"exclusive", @"isExclusiveRedPack", @"isExclusivePacket",
             @"exclusiveRedPack", @"isDedicated"];
}

static NSArray<NSString *> *QQHBSelfFlagKeys(void) {
    return @[@"isSelf", @"isMine", @"fromSelf", @"isSenderSelf", @"isMyRedPack", @"isSelfSend"];
}

static NSArray<NSString *> *QQHBTypeKeys(void) {
    return @[@"type", @"packetType", @"redPackType", @"redpackType", @"subType", @"hbType"];
}

static NSString *QQHBTitle(id obj) {
    return QQHBStringOf(QQHBKVCFirst(obj, QQHBTitleKeys()));
}

static NSNumber *QQHBTypeValue(id obj) {
    id v = QQHBKVCFirst(obj, QQHBTypeKeys());
    return [v isKindOfClass:[NSNumber class]] ? v : nil;
}

static BOOL QQHBTypeIsExclusive(id obj) {
    NSArray<NSNumber *> *types = [QQHBConfig shared].exclusiveTypes;
    if (types.count == 0) return NO;
    NSNumber *t = QQHBTypeValue(obj);
    return t ? [types containsObject:t] : NO;
}

static BOOL QQHBIsExclusiveFlag(id obj) {
    id v = QQHBKVCFirst(obj, QQHBExclusiveFlagKeys());
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO;
}

static BOOL QQHBIsSelfPacket(id obj) {
    id v = QQHBKVCFirst(obj, QQHBSelfFlagKeys());
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO;
}

#pragma mark - 判断是否跳过

static BOOL QQHBDecide(id packet, NSString **why) {
    QQHBConfig *cfg = [QQHBConfig shared];
    NSString *reason = nil;

    if (!cfg.enabled) reason = @"功能已关闭";
    if (!reason && cfg.skipExclusive && QQHBIsExclusiveFlag(packet)) reason = @"专属红包";
    if (!reason && cfg.skipExclusive && QQHBTypeIsExclusive(packet)) reason = @"专属红包(类型)";
    NSString *title = QQHBTitle(packet);
    if (!reason && [cfg shouldSkipTitle:title]) {
        reason = [NSString stringWithFormat:@"关键词「%@」", title];
    }
    if (!reason && ![cfg titleWanted:title]) reason = @"不匹配抢包关键词";
    if (!reason && !cfg.grabOwnPackets) {
        NSString *selfUin = cfg.selfUin;
        NSString *senderUin = QQHBStringOf(QQHBKVCFirst(packet, QQHBUinKeys()));
        if (selfUin.length && senderUin.length && [selfUin isEqualToString:senderUin]) {
            reason = @"自己发的红包(QQ号匹配)";
        } else if (QQHBIsSelfPacket(packet)) {
            reason = @"自己发的红包";
        }
    }

    if (why) *why = reason;
    return reason != nil;
}

static void QQHBRecordGrabbed(id packet, SEL sel) {
    NSString *uin = QQHBStringOf(QQHBKVCFirst(packet, QQHBUinKeys()));
    NSString *name = QQHBStringOf(QQHBKVCFirst(packet, QQHBNameKeys()));
    NSString *title = QQHBTitle(packet);
    id amount = QQHBKVCFirst(packet, QQHBAmountKeys());
    NSNumber *cents = nil;
    NSString *amountText = nil;
    if ([amount isKindOfClass:[NSNumber class]]) {
        cents = (NSNumber *)amount;
    } else if ([amount isKindOfClass:[NSString class]]) {
        amountText = (NSString *)amount;
    }
    [QQHBStats recordWithSenderName:name
                          senderUin:uin
                        amountCents:cents
                         amountText:amountText
                              title:title
                              extra:@{@"hook": NSStringFromSelector(sel),
                                      @"cls": NSStringFromClass([packet class]) ?: @""}];
}

#pragma mark - Hook 基础设施

static NSMutableDictionary<NSString *, id> *gOriginals;   /* 选择器名 -> NSValue(IMP) */
static NSMutableSet<NSString *> *gHooked;                  /* "类名|选择器" */
static void (*gMSHookMessageEx)(Class, SEL, IMP, IMP *);

static void QQHBResolveHookAPI(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gOriginals = [NSMutableDictionary dictionary];
        gHooked = [NSMutableSet set];
        gMSHookMessageEx = (void (*)(Class, SEL, IMP, IMP *))dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        if (!gMSHookMessageEx) {
            void *h = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
            if (h) gMSHookMessageEx = (void (*)(Class, SEL, IMP, IMP *))dlsym(h, "MSHookMessageEx");
            if (!gMSHookMessageEx) {
                h = dlopen("/usr/lib/libellekit.dylib", RTLD_NOW);
                if (h) gMSHookMessageEx = (void (*)(Class, SEL, IMP, IMP *))dlsym(h, "MSHookMessageEx");
            }
        }
        QQHBLog(@"MSHookMessageEx = %p", (void *)gMSHookMessageEx);
    });
}

/* 原始实现按「类名|选择器」存：同一个选择器可能挂在父类和子类上 */
static IMP QQHBOriginalFor(id self, SEL sel) {
    NSString *selName = NSStringFromSelector(sel);
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        NSString *key = [NSString stringWithFormat:@"%s|%@", class_getName(c), selName];
        NSValue *v = gOriginals[key];
        if (v) return (IMP)v.pointerValue;
    }
    NSValue *v = gOriginals[[NSString stringWithFormat:@"*|%@", selName]];
    return v ? (IMP)v.pointerValue : NULL;
}

static NSInteger QQHBRandomDelay(void) {
    QQHBConfig *cfg = [QQHBConfig shared];
    NSInteger lo = cfg.delayMs, hi = cfg.delayMaxMs;
    if (hi <= lo) return lo;
    return lo + (NSInteger)arc4random_uniform((uint32_t)(hi - lo + 1));
}

static void QQHBAppendText(NSString *file, NSString *line) {
    static NSUInteger counter = 0;
    NSString *path = [QQHBSupportDir() stringByAppendingPathComponent:file];
    NSFileManager *fm = [NSFileManager defaultManager];
    /* 每 100 次才检查一次大小，避免频繁取文件属性 */
    if ((counter++ % 100) == 0) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
        if ([attrs[NSFileSize] unsignedLongLongValue] > 256 * 1024) {
            [fm removeItemAtPath:path error:NULL];
        }
    }
    NSString *text = [line stringByAppendingString:@"\n"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
    } @catch (__unused NSException *e) {
    }
    [fh closeFile];
}

static NSMutableSet<NSString *> *gDumpedClasses;

/* 打印对象所有属性的值（观察型钩子用） */
static void QQHBDumpAllValues(const char *tag, id obj) {
    if (!obj) return;
    Class cls = object_getClass(obj);
    unsigned int pcount = 0;
    objc_property_t *plist = class_copyPropertyList(cls, &pcount);
    if (!plist) return;
    NSMutableArray *parts = [NSMutableArray array];
    for (unsigned int i = 0; i < pcount && parts.count < 60; i++) {
        NSString *key = [NSString stringWithUTF8String:property_getName(plist[i])];
        id v = nil;
        @try { v = [obj valueForKey:key]; } @catch (__unused NSException *e) {}
        NSString *s = QQHBStringOf(v);
        if (!s || s.length == 0) continue;
        if (s.length > 120) s = [s substringToIndex:120];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, s]];
    }
    free(plist);
    if (parts.count == 0) return;
    NSString *line = [NSString stringWithFormat:@"%s 全部: %@", tag,
                      [parts componentsJoinedByString:@" | "]];
    QQHBLog(@"%@", line);
    QQHBAppendText(@"structure.txt", line);
}
static void QQHBDumpValues(const char *tag, id obj, NSArray<NSString *> *keys) {
    if (!obj) return;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in keys) {
        id v = nil;
        @try { v = [obj valueForKey:k]; } @catch (__unused NSException *e) {}
        if (!v) continue;
        NSString *s = QQHBStringOf(v);
        if (!s) continue;
        if (s.length > 200) s = [s substringToIndex:200];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, s]];
    }
    if (parts.count == 0) return;
    NSString *line = [NSString stringWithFormat:@"%s 值: %@", tag,
                      [parts componentsJoinedByString:@" | "]];
    QQHBLog(@"%@", line);
    QQHBAppendText(@"structure.txt", line);
}

/* 把一个对象的结构打印出来：类名、属性名、description，用来找真实字段名 */
static void QQHBDumpObject(const char *tag, id obj) {
    if (!obj) return;
    Class cls = object_getClass(obj);
    if (!cls) return;
    if (!gDumpedClasses) gDumpedClasses = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%s|%s", tag, class_getName(cls)];
    if ([gDumpedClasses containsObject:key]) return;
    [gDumpedClasses addObject:key];

    NSMutableArray *props = [NSMutableArray array];
    unsigned int pcount = 0;
    objc_property_t *plist = class_copyPropertyList(cls, &pcount);
    for (unsigned int i = 0; i < pcount; i++) {
        [props addObject:[NSString stringWithUTF8String:property_getName(plist[i])]];
    }
    if (plist) free(plist);

    NSString *desc = nil;
    @try { desc = [obj description]; } @catch (__unused NSException *e) {}
    if (desc.length > 400) desc = [desc substringToIndex:400];

    NSString *line = [NSString stringWithFormat:@"%s %s 属性: %@\n    description: %@",
                      tag, class_getName(cls),
                      [props componentsJoinedByString:@","], desc ?: @"(nil)"];
    QQHBLog(@"%@", line);
    QQHBAppendText(@"structure.txt", line);

    /* ivar 里往往藏着 reserve data / 单号 */
    unsigned int icount = 0;
    Ivar *ivars = class_copyIvarList(cls, &icount);
    if (ivars) {
        NSMutableArray *items = [NSMutableArray array];
        for (unsigned int i = 0; i < icount && items.count < 40; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            NSString *val = @"";
            if (type && type[0] == '@') {
                id v = object_getIvar(obj, ivars[i]);
                NSString *s = QQHBStringOf(v);
                if (s.length) {
                    if (s.length > 200) s = [s substringToIndex:200];
                    val = [NSString stringWithFormat:@"=%@", s];
                }
            }
            [items addObject:[NSString stringWithFormat:@"%s%s", name ?: "?", val.UTF8String]];
        }
        free(ivars);
        QQHBAppendText(@"structure.txt", [NSString stringWithFormat:@"%s ivar: %@", tag,
                                          [items componentsJoinedByString:@" | "]]);
    }
}

/* 返回 YES 表示允许原方法继续（即真的去抢） */
static BOOL QQHBBefore(id target, SEL sel, id arg) {
    QQHBConfig *cfg = [QQHBConfig shared];
    NSString *why = nil;
    id packet = arg ?: target;
    /* 观察型钩子：只记录，绝不拦 */
    if ([cfg isObserveSelector:sel]) {
        if (cfg.diagnose) {
            QQHBDumpObject("observe", arg);
            QQHBDumpAllValues("observe", arg);
        }
        return YES;
    }

    if (cfg.diagnose) {
        QQHBAppendText(@"trace.txt", [NSString stringWithFormat:@"%@ -[%s %s] arg=%@",
                                      [NSDate date],
                                      class_getName([target class]),
                                      sel_getName(sel),
                                      arg ? NSStringFromClass([arg class]) : @"nil"]);
    }

    BOOL detailed = [cfg isConfiguredSelector:sel] || [cfg isObserveSelector:sel];
    if (cfg.diagnose && detailed) {
        QQHBDumpObject("target", target);
        QQHBDumpObject("arg", arg);
        QQHBDumpValues("arg", arg, @[@"selfUin", @"selfName", @"senderUin", @"senderName",
                                     @"hbFlag", @"hbFrom", @"hbFromType", @"groupType",
                                     @"payFlag", @"msgId", @"extParam", @"answer",
                                     @"skinType", @"comeFrom", @"qrData"]);
        QQHBLog(@"[诊断] -[%@ %@] 标题=%@ QQ=%@ 类型=%@",
                NSStringFromClass([target class]), NSStringFromSelector(sel),
                QQHBTitle(packet) ?: @"(无)",
                QQHBStringOf(QQHBKVCFirst(packet, QQHBUinKeys())) ?: @"(无)",
                QQHBTypeValue(packet) ?: @"(无)");
    }
    if (QQHBDecide(packet, &why)) {
        QQHBLog(@"[跳过] -[%@ %@] 原因:%@ 标题:%@", NSStringFromClass([target class]),
                NSStringFromSelector(sel), why, QQHBTitle(packet) ?: @"(无)");
        QQHBAppendText(@"skips.txt", [NSString stringWithFormat:@"%@  %@  %@  %@",
                                      [NSDate date], why,
                                      QQHBTitle(packet) ?: @"(无标题)",
                                      NSStringFromSelector(sel)]);
        return NO;
    }
    return YES;
}

static void QQHBAfter(id target, SEL sel, id arg, id result) {
    (void)result;
    QQHBRecordGrabbed(arg ?: target, sel);
}

/* 各种签名对应的跳板 */
static void QQHBT_void_0(id self, SEL _cmd) {
    if (!QQHBBefore(self, _cmd, nil)) return;
    IMP o = QQHBOriginalFor(self, _cmd); if (o) ((void (*)(id, SEL))o)(self, _cmd);
    QQHBAfter(self, _cmd, nil, nil);
}

@protocol QQHBGrabCommitting <NSObject>
- (void)grabRedPack:(id)pack params:(id)params completion:(id)completion;
- (void)grabHB:(id)pack params:(id)params completion:(id)completion;
@end

static NSMutableSet<NSString *> *gAutoGrabbed;

/* 从红包消息模型直接抢：params = [model grapRedPacketParams]，再调 QQWallet */
static void QQHBAutoGrabFromModel(id model) {
    QQHBConfig *cfg = [QQHBConfig shared];
    if (!model) return;
    if (cfg.diagnose) {
        QQHBDumpObject("msgmodel", model);
        QQHBDumpAllValues("msgmodel", model);
    }
    if (!cfg.enabled) return;

    id openState = nil, isSelf = nil, msgId = nil;
    @try { openState = [model valueForKey:@"openState"]; } @catch (__unused NSException *e) {}
    @try { isSelf = [model valueForKey:@"isSelfMsg"]; } @catch (__unused NSException *e) {}
    @try { msgId = [model valueForKey:@"billNo"]; } @catch (__unused NSException *e) {}
    if ([openState isKindOfClass:[NSNumber class]] && [openState integerValue] != 0) return;
    if ([isSelf isKindOfClass:[NSNumber class]] && [isSelf boolValue] && !cfg.grabOwnPackets) {
        QQHBLog(@"[跳过] 自己发的红包");
        return;
    }

    NSString *key = QQHBStringOf(msgId);
    if (!key.length) key = [NSString stringWithFormat:@"%p", model];
    if (!gAutoGrabbed) gAutoGrabbed = [NSMutableSet set];
    if ([gAutoGrabbed containsObject:key]) return;
    [gAutoGrabbed addObject:key];

    NSString *why = nil;
    if (QQHBDecide(model, &why)) {
        QQHBLog(@"[跳过] 消息模型 原因:%@", why);
        QQHBAppendText(@"skips.txt", [NSString stringWithFormat:@"%@  模型  %@", [NSDate date], why]);
        return;
    }

    SEL paramsSel = NSSelectorFromString(@"grapRedPacketParams");
    if (![model respondsToSelector:paramsSel]) {
        QQHBLog(@"[抢] 模型没有 grapRedPacketParams");
        return;
    }
    id params = nil;
    @try { params = [model performSelector:paramsSel]; } @catch (__unused NSException *e) {}
    QQHBLog(@"[抢] 抢包参数: %@", QQHBStringOf(params));

    Class wallet = objc_getClass("QQWallet");
    if (!wallet) {
        QQHBLog(@"[抢] QQWallet 未加载");
        return;
    }
    id walletObj = nil;
    @try { walletObj = [wallet performSelector:NSSelectorFromString(@"sharedInstance")]; } @catch (__unused NSException *e) {}
    if (!walletObj) {
        @try { walletObj = [[wallet alloc] init]; } @catch (__unused NSException *e) {}
    }
    if (!walletObj) {
        QQHBLog(@"[抢] 拿不到 QQWallet 实例");
        return;
    }

    SEL grabSel = NSSelectorFromString(@"grabRedPack:params:completion:");
    if (![walletObj respondsToSelector:grabSel]) {
        QQHBLog(@"[抢] QQWallet 没有 grabRedPack:params:completion:");
        return;
    }
    QQHBLog(@"[抢] 调用 grabRedPack 参数=%@", QQHBStringOf(params));
    QQHBAppendText(@"structure.txt", [NSString stringWithFormat:@"%@ 自动抢 %@",
                                      [NSDate date], key]);
    [(id<QQHBGrabCommitting>)walletObj grabRedPack:model params:params completion:nil];
}

@interface QQHBTouchButton : NSObject
- (void)sendActionsForControlEvents:(unsigned long)events;
@end

@protocol QQHBTailClickable <NSObject>
- (void)tailButtonClicked:(id)sender;
@end

static void QQHBScheduleTaps(id view, id model, int left);

/* 兜底：不依赖 UI，直接调 QQWallet 的抢包接口 */
static void QQHBForceGrab(id model) {
    QQHBAppendText(@"structure.txt", @"[抢] 尝试直接调钱包接口");
    id params = nil;
    for (NSString *selName in @[@"grabHBParam", @"grapRedPacketParams"]) {
        SEL s = NSSelectorFromString(selName);
        if (![model respondsToSelector:s]) continue;
        @try { params = [model performSelector:s]; } @catch (__unused NSException *e) {}
        if (params) break;
    }
    if (!params) {
        QQHBAppendText(@"structure.txt", @"[抢] 模型没有抢包参数");
        return;
    }
    Class walletClass = objc_getClass("QQWallet");
    if (!walletClass) return;
    id wallet = nil;
    @try { wallet = [walletClass performSelector:NSSelectorFromString(@"sharedInstance")]; } @catch (__unused NSException *e) {}
    if (!wallet) return;
    SEL grab = NSSelectorFromString(@"grabHB:params:completion:");
    if (![wallet respondsToSelector:grab]) return;
    QQHBAppendText(@"structure.txt", [NSString stringWithFormat:@"[抢] 调用 grabHB params=%@",
                                      QQHBStringOf(params)]);
    @try {
        [(id<QQHBGrabCommitting>)wallet grabHB:model params:params completion:nil];
    } @catch (__unused NSException *e) {
        QQHBAppendText(@"structure.txt", @"[抢] grabHB 抛异常");
    }
}

static void QQHBTapOnce(id view, id model, const char *tag) {
    id openState = nil;
    @try { openState = [model valueForKey:@"openState"]; } @catch (__unused NSException *e) {}
    if ([openState isKindOfClass:[NSNumber class]] && [openState integerValue] != 0) return;

    /* 优先调卡片自己的点击处理（QQ 用的是手势/卡片回调，不是按钮 action） */
    if ([view respondsToSelector:NSSelectorFromString(@"tailButtonClicked:")]) {
        [(id<QQHBTailClickable>)view tailButtonClicked:nil];
        QQHBAppendText(@"structure.txt", [NSString stringWithFormat:@"[抢] %s call tailButtonClicked:", tag]);
        return;
    }

    id button = nil;
    @try { button = [view valueForKey:@"openButton"]; } @catch (__unused NSException *e) {}
    SEL sel = NSSelectorFromString(@"sendActionsForControlEvents:");
    if (button && [button respondsToSelector:sel]) {
        [(QQHBTouchButton *)button sendActionsForControlEvents:(1UL << 6)];
        QQHBAppendText(@"structure.txt", [NSString stringWithFormat:@"[抢] %s click openButton", tag]);
        return;
    }
    id shade = nil;
    @try { shade = [view valueForKey:@"openShadeView"]; } @catch (__unused NSException *e) {}
    if (shade && [shade respondsToSelector:sel]) {
        [(QQHBTouchButton *)shade sendActionsForControlEvents:(1UL << 6)];
        QQHBAppendText(@"structure.txt", [NSString stringWithFormat:@"[抢] %s click openShadeView", tag]);
        return;
    }
    if ([view respondsToSelector:NSSelectorFromString(@"tailButtonClicked:")]) {
        [(id<QQHBTailClickable>)view tailButtonClicked:nil];
        QQHBAppendText(@"structure.txt", [NSString stringWithFormat:@"[抢] %s call tailButtonClicked:", tag]);
        return;
    }
    QQHBAppendText(@"structure.txt", [NSString stringWithFormat:@"[抢] %s 无可点击入口", tag]);
}

static void QQHBScheduleTaps(id view, id model, int left) {
    if (left <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        QQHBTapOnce(view, model, "retry");
        if (left == 1) {
            /* 点开都没成功，最后尝试直接调钱包接口 */
            QQHBForceGrab(model);
        }
        QQHBScheduleTaps(view, model, left - 1);
    });
}

/* 红包卡片出现时：判断该不该抢，然后模拟点击「开」按钮 */
static void QQHBAutoGrab(id view, id model) {
    QQHBConfig *cfg = [QQHBConfig shared];
    if (!cfg.enabled) return;

    if (cfg.diagnose) {
        QQHBDumpObject("model", model);
        QQHBDumpAllValues("model", model);
    }

    /* 已经拆开的不处理 */
    id openState = nil;
    @try { openState = [model valueForKey:@"openState"]; } @catch (__unused NSException *e) {}
    if ([openState isKindOfClass:[NSNumber class]] && [openState integerValue] != 0) return;

    /* 同一个红包只抢一次 */
    id msgId = nil;
    @try { msgId = [model valueForKey:@"msgId"]; } @catch (__unused NSException *e) {}
    NSString *key = msgId ? QQHBStringOf(msgId) : [NSString stringWithFormat:@"%p", model];
    if (!key.length) key = [NSString stringWithFormat:@"%p", model];
    if (!gAutoGrabbed) gAutoGrabbed = [NSMutableSet set];
    if ([gAutoGrabbed containsObject:key]) return;
    [gAutoGrabbed addObject:key];

    NSString *why = nil;
    if (QQHBDecide(model, &why)) {
        QQHBLog(@"[跳过] 红包卡片 原因:%@", why);
        QQHBAppendText(@"skips.txt", [NSString stringWithFormat:@"%@  卡片  %@", [NSDate date], why]);
        return;
    }

    NSInteger delay = QQHBRandomDelay();
    QQHBLog(@"[抢] 卡片出现，%ldms 后点开", (long)delay);
    QQHBAppendText(@"structure.txt", [NSString stringWithFormat:@"%@ [抢] 卡片出现 %@",
                                      [NSDate date], NSStringFromClass([view class])]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        QQHBTapOnce(view, model, "first");
        QQHBScheduleTaps(view, model, 8);
    });
}

static __thread int gHookDepth;

static void QQHBT_void_1(id self, SEL _cmd, id a1) {
    NSString *selName = NSStringFromSelector(_cmd);
    if ([selName isEqualToString:@"updateViewWithRedPacketMsgModel:"] ||
        [selName isEqualToString:@"setRedPacketMsgModel:"]) {
        /* 防递归：父类/子类都挂了同一个选择器时会互相回调 */
        if (gHookDepth > 0) {
            IMP oo = QQHBOriginalFor(self, _cmd);
            if (oo) ((void (*)(id, SEL, id))oo)(self, _cmd, a1);
            return;
        }
        gHookDepth++;
        @try {
            QQHBAutoGrab(self, a1);
        } @catch (__unused NSException *e) {
        }
        IMP o = QQHBOriginalFor(self, _cmd);
        if (o) ((void (*)(id, SEL, id))o)(self, _cmd, a1);
        gHookDepth--;
        return;
    }
    if (!QQHBBefore(self, _cmd, a1)) return;
    QQHBConfig *cfg = [QQHBConfig shared];
    IMP o = QQHBOriginalFor(self, _cmd);
    NSInteger d = cfg.delayMs > 0 ? QQHBRandomDelay() : 0;
    if (d > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            if (o) ((void (*)(id, SEL, id))o)(self, _cmd, a1);
            QQHBAfter(self, _cmd, a1, nil);
        });
        return;
    }
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, a1);
    QQHBAfter(self, _cmd, a1, nil);
}

static id QQHBT_id_1(id self, SEL _cmd, id a1) {
    NSString *selName = NSStringFromSelector(_cmd);
    if ([selName isEqualToString:@"initWithRedPacketInfo:"]) {
        IMP o0 = QQHBOriginalFor(self, _cmd);
        id r0 = o0 ? ((id (*)(id, SEL, id))o0)(self, _cmd, a1) : nil;
        QQHBAutoGrabFromModel(r0 ?: self);
        return r0;
    }
    if (!QQHBBefore(self, _cmd, a1)) return nil;
    IMP o = QQHBOriginalFor(self, _cmd);
    id r = o ? ((id (*)(id, SEL, id))o)(self, _cmd, a1) : nil;
    QQHBAfter(self, _cmd, a1, r);
    return r;
}

static BOOL QQHBT_bool_1(id self, SEL _cmd, id a1) {
    if (!QQHBBefore(self, _cmd, a1)) return NO;
    IMP o = QQHBOriginalFor(self, _cmd);
    BOOL r = o ? ((BOOL (*)(id, SEL, id))o)(self, _cmd, a1) : NO;
    QQHBAfter(self, _cmd, a1, nil);
    return r;
}

static long long QQHBT_int_1(id self, SEL _cmd, id a1) {
    if (!QQHBBefore(self, _cmd, a1)) return 0;
    IMP o = QQHBOriginalFor(self, _cmd);
    long long r = o ? ((long long (*)(id, SEL, id))o)(self, _cmd, a1) : 0;
    QQHBAfter(self, _cmd, a1, nil);
    return r;
}

static void QQHBT_void_2(id self, SEL _cmd, id a1, id a2) {
    if (!QQHBBefore(self, _cmd, a1)) return;
    IMP o = QQHBOriginalFor(self, _cmd); if (o) ((void (*)(id, SEL, id, id))o)(self, _cmd, a1, a2);
    QQHBAfter(self, _cmd, a1, nil);
}

static id QQHBT_id_2(id self, SEL _cmd, id a1, id a2) {
    if (!QQHBBefore(self, _cmd, a1)) return nil;
    IMP o = QQHBOriginalFor(self, _cmd);
    id r = o ? ((id (*)(id, SEL, id, id))o)(self, _cmd, a1, a2) : nil;
    QQHBAfter(self, _cmd, a1, r);
    return r;
}

typedef void (^QQHBGrabCompletion)(int, id);

/* 打印字典内容（params 就是字典） */
static void QQHBDumpDict(const char *tag, id obj) {
    if (![obj isKindOfClass:[NSDictionary class]]) return;
    NSMutableArray *parts = [NSMutableArray array];
    [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        NSString *s = QQHBStringOf(v);
        if (!s || s.length == 0) return;
        if (s.length > 100) s = [s substringToIndex:100];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, s]];
        if (parts.count >= 40) *stop = YES;
    }];
    if (parts.count == 0) return;
    QQHBAppendText(@"structure.txt", [NSString stringWithFormat:@"%s dict: %@", tag,
                                      [parts componentsJoinedByString:@" | "]]);
}

static void QQHBT_void_3(id self, SEL _cmd, id a1, id a2, id a3) {
    QQHBDumpObject("v3-arg1", a1);
    QQHBDumpObject("v3-arg2", a2);
    QQHBDumpObject("v3-arg3", a3);
    QQHBDumpDict("v3-arg2", a2);
    if (!QQHBBefore(self, _cmd, a1)) return;
    IMP o = QQHBOriginalFor(self, _cmd);
    if (!o) return;

    /* grabRedPack:params:completion: —— 把 completion 包一层，抓抢包结果（金额） */
    NSString *selName = NSStringFromSelector(_cmd);
    if ([selName isEqualToString:@"grabRedPack:params:completion:"] ||
        [selName isEqualToString:@"grabHB:params:completion:"]) {
        QQHBGrabCompletion orig = (QQHBGrabCompletion)a3;
        if (orig) {
            QQHBGrabCompletion wrapper = ^(int code, id resp) {
                NSString *line = [NSString stringWithFormat:
                    @"grab结果 %@ code=%d resp=%@", selName, code, resp];
                QQHBLog(@"%@", line);
                QQHBAppendText(@"structure.txt", line);
                orig(code, resp);
            };
            ((void (*)(id, SEL, id, id, id))o)(self, _cmd, a1, a2, (id)wrapper);
            QQHBAfter(self, _cmd, a1, nil);
            return;
        }
    }

    ((void (*)(id, SEL, id, id, id))o)(self, _cmd, a1, a2, a3);
    QQHBAfter(self, _cmd, a1, nil);
}

static id QQHBT_id_3(id self, SEL _cmd, id a1, id a2, id a3) {
    if (!QQHBBefore(self, _cmd, a1)) return nil;
    IMP o = QQHBOriginalFor(self, _cmd);
    id r = o ? ((id (*)(id, SEL, id, id, id))o)(self, _cmd, a1, a2, a3) : nil;
    QQHBAfter(self, _cmd, a1, r);
    return r;
}

static void QQHBT_void_4(id self, SEL _cmd, id a1, id a2, id a3, id a4) {
    /* grabHBParams:password:checkInfo:redPack: —— 红包对象在最后一个参数 */
    QQHBDumpObject("v4-arg1", a1);
    QQHBDumpObject("v4-arg4", a4);
    if (!QQHBBefore(self, _cmd, a4 ?: a1)) return;
    IMP o = QQHBOriginalFor(self, _cmd);
    if (o) ((void (*)(id, SEL, id, id, id, id))o)(self, _cmd, a1, a2, a3, a4);
    QQHBAfter(self, _cmd, a4 ?: a1, nil);
}

static id QQHBT_id_4(id self, SEL _cmd, id a1, id a2, id a3, id a4) {
    if (!QQHBBefore(self, _cmd, a4 ?: a1)) return nil;
    IMP o = QQHBOriginalFor(self, _cmd);
    id r = o ? ((id (*)(id, SEL, id, id, id, id))o)(self, _cmd, a1, a2, a3, a4) : nil;
    QQHBAfter(self, _cmd, a4 ?: a1, r);
    return r;
}

/* -onGrabFinish:errorCode: 这类 (对象, 整数) 的 void 方法 */
static void QQHBT_void_id_q(id self, SEL _cmd, id a1, long long a2) {
    if (!QQHBBefore(self, _cmd, a1)) return;
    IMP o = QQHBOriginalFor(self, _cmd);
    if (o) ((void (*)(id, SEL, id, long long))o)(self, _cmd, a1, a2);
    QQHBAfter(self, _cmd, a1, nil);
}

/* 按类型编码挑跳板：无法安全处理就返回 NULL，宁可不 hook 也不搞乱返回寄存器 */
static IMP QQHBTrampolineFor(Method m) {
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return NULL;

    char ret = 0;
    NSMutableArray *types = [NSMutableArray array];
    BOOL expectRet = YES;
    for (const char *p = enc; *p; p++) {
        char c = *p;
        if (isdigit((unsigned char)c) || c == '-' || c == '+' || c == 'r' || c == 'n' || c == 'N' ||
            c == 'o' || c == 'O' || c == 'R' || c == 'V') {
            continue;
        }
        if (c == '@' && p[1] == '?') {
            /* block：@? 是一个整体 */
            if (expectRet) { ret = '@'; expectRet = NO; }
            else { [types addObject:@('@')]; }
            p++;
            continue;
        }
        if (expectRet) { ret = c; expectRet = NO; continue; }
        [types addObject:@(c)];
    }
    /* types[0] 是 self(@)，types[1] 是 _cmd(:) */
    NSUInteger argc = types.count > 2 ? types.count - 2 : 0;

    /* (对象, 整数) 的 void 方法，比如 -onGrabFinish:errorCode: */
    if (ret == 'v' && argc == 2 && types.count >= 4) {
        char t1 = (char)[types[2] charValue];
        char t2 = (char)[types[3] charValue];
        if (t1 == '@' && (t2 == 'q' || t2 == 'i' || t2 == 'l')) {
            return (IMP)QQHBT_void_id_q;
        }
    }

    BOOL argsOk = YES;
    for (NSUInteger i = 2; i < types.count; i++) {
        char c = (char)[types[i] charValue];
        if (c != '@' && c != '^') argsOk = NO;
    }
    if (!argsOk) return NULL;

    if (ret == 'v') {
        if (argc == 0) return (IMP)QQHBT_void_0;
        if (argc == 1) return (IMP)QQHBT_void_1;
        if (argc == 2) return (IMP)QQHBT_void_2;
        if (argc == 3) return (IMP)QQHBT_void_3;
        if (argc == 4) return (IMP)QQHBT_void_4;
        return NULL;
    }
    if (ret == '@') {
        if (argc == 1) return (IMP)QQHBT_id_1;
        if (argc == 2) return (IMP)QQHBT_id_2;
        if (argc == 3) return (IMP)QQHBT_id_3;
        if (argc == 4) return (IMP)QQHBT_id_4;
        return NULL;
    }
    if (ret == 'B' || ret == 'c') {
        if (argc == 1) return (IMP)QQHBT_bool_1;
        return NULL;
    }
    if (ret == 'q' || ret == 'Q' || ret == 'i' || ret == 'I' || ret == 'l' || ret == 'L') {
        if (argc == 1) return (IMP)QQHBT_int_1;
        return NULL;
    }
    return NULL;
}

static BOOL QQHBInstallHook(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    NSString *key = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
    if ([gHooked containsObject:key]) return YES;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        if (class_getClassMethod(cls, sel)) {
            QQHBLog(@"[跳过 hook] 是类方法，暂不支持: +[%@ %@]", NSStringFromClass(cls),
                    NSStringFromSelector(sel));
        }
        return NO;
    }
    IMP tramp = QQHBTrampolineFor(m);
    if (!tramp) {
        QQHBLog(@"[跳过 hook] 签名不支持: -[%@ %@] %s", NSStringFromClass(cls),
                NSStringFromSelector(sel), method_getTypeEncoding(m));
        return NO;
    }
    if (!gMSHookMessageEx) return NO;

    IMP orig = NULL;
    gMSHookMessageEx(cls, sel, tramp, &orig);
    if (orig) {
        NSString *origKey = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
        gOriginals[origKey] = [NSValue valueWithPointer:orig];
        /* 兜底 key，供找不到精确类时使用 */
        NSString *fallback = [NSString stringWithFormat:@"*|%s", sel_getName(sel)];
        if (!gOriginals[fallback]) gOriginals[fallback] = [NSValue valueWithPointer:orig];
    }
    [gHooked addObject:key];
    QQHBLog(@"[已 hook] -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
    return YES;
}

#pragma mark - 诊断扫描

static NSArray<NSString *> *QQHBClassHints(void) {
    return @[@"RedPack", @"Redpack", @"RedPacket", @"RedEnvelope", @"Envelope",
             @"Hongbao", @"HongBao", @"HBPacket", @"GrabRed"];
}

static NSArray<NSString *> *QQHBMethodHints(void) {
    return @[@"grab", @"Grab", @"receive", @"Receive", @"open", @"Open", @"pick", @"Pick",
             @"click", @"Click", @"take", @"Take", @"lucky", @"Lucky", @"hongbao", @"Hongbao",
             @"redpack", @"RedPack", @"grabRedPack", @"handleRedPack"];
}

static void QQHBDiagnoseScan(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    NSArray *classHints = QQHBClassHints();
    NSArray *methodHints = QQHBMethodHints();
    NSUInteger logged = 0;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSMutableString *report = [NSMutableString string];

    for (unsigned int i = 0; i < count && logged < 200; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        NSString *clsName = [NSString stringWithUTF8String:name];
        if (!clsName) continue;
        BOOL hit = NO;
        for (NSString *h in classHints) {
            if ([clsName rangeOfString:h options:NSCaseInsensitiveSearch].location != NSNotFound) { hit = YES; break; }
        }
        if (!hit) continue;

        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(classes[i], &mcount);
        NSMutableArray<NSString *> *selNames = [NSMutableArray array];
        for (unsigned int j = 0; j < mcount && logged < 200; j++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[j]));
            for (NSString *h in methodHints) {
                if ([selName rangeOfString:h].location != NSNotFound) {
                    [selNames addObject:[NSString stringWithFormat:@"%@ %s", selName,
                                        method_getTypeEncoding(methods[j])]];
                    logged++;
                    break;
                }
            }
        }
        if (methods) free(methods);

        if (selNames.count) {
            QQHBLog(@"[诊断] 类 %@ 候选方法: %@", clsName, [selNames componentsJoinedByString:@" | "]);
            [candidates addObject:clsName];
            [report appendFormat:@"%@ :: %@\n", clsName, [selNames componentsJoinedByString:@" | "]];
        }
    }

    /* 第二遍：不管类名，凡是方法名里带 grab 的都记下来，写进文件 */
    [report appendString:@"\n=== 选择器含 grab 的方法 ===\n"];
    NSUInteger grabCount = 0;
    for (unsigned int i = 0; i < count && grabCount < 400; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        NSString *clsName = [NSString stringWithUTF8String:name];
        if (!clsName) continue;
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(classes[i], &mcount);
        for (unsigned int j = 0; j < mcount && grabCount < 400; j++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[j]));
            if ([selName rangeOfString:@"grab" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            [report appendFormat:@"%@ %@ %s\n", clsName, selName,
                                 method_getTypeEncoding(methods[j])];
            grabCount++;
        }
        if (methods) free(methods);
    }
    if (classes) free(classes);

    /* 第三遍：关键类的全部方法，用来找真正的入口 */
    [report appendString:@"\n=== 关键类全部方法 ===\n"];
    NSArray *focus = @[@"QQWalletGrapHBAIOData", @"QQWalletGrapHBService",
                       @"QQWalletRedPacketMsgView", @"QQWalletRedPacketMsgModel",
                       @"QQWalletNTRedPackMsgModel"];
    for (NSString *cn in focus) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) {
            [report appendFormat:@"\n-- %@ 未加载 --\n", cn];
            continue;
        }
        [report appendFormat:@"\n-- %@ --\n", cn];
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            [report appendFormat:@"  %s\n", sel_getName(method_getName(ms[j]))];
        }
        if (ms) free(ms);
    }

    /* 第四遍：方法名带 hb / redpack / envelope 的，找红包卡片点击入口 */
    [report appendString:@"\n=== 选择器含 hb/redpack/envelope 的方法 ===\n"];
    NSArray *uiHints = @[@"hb", @"redpack", @"envelope", @"hongbao", @"luckymoney"];
    unsigned int count2 = 0;
    Class *classes2 = objc_copyClassList(&count2);
    NSUInteger uiCount = 0;
    for (unsigned int i = 0; i < count2 && uiCount < 500; i++) {
        const char *cname = class_getName(classes2[i]);
        if (!cname) continue;
        NSString *clsName = [NSString stringWithUTF8String:cname];
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(classes[i], &mcount);
        for (unsigned int j = 0; j < mcount && uiCount < 500; j++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[j]));
            NSString *lower = selName.lowercaseString;
            BOOL hit = NO;
            for (NSString *h in uiHints) {
                if ([lower rangeOfString:h].location != NSNotFound) { hit = YES; break; }
            }
            if (!hit) continue;
            [report appendFormat:@"%@ %@\n", clsName, selName];
            uiCount++;
        }
        if (methods) free(methods);
    }
    if (classes2) free(classes2);

    NSString *path = [QQHBSupportDir() stringByAppendingPathComponent:@"diag.txt"];
    [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    QQHBLog(@"[诊断] 扫描完成，候选类 %lu 个，grab 方法 %lu 个，报告写在 %@",
            (unsigned long)candidates.count, (unsigned long)grabCount, path);
}

#pragma mark - 启动

static void QQHBInstallConfiguredHooks(void) {
    QQHBConfig *cfg = [QQHBConfig shared];
    NSArray *hooks = cfg.grabHooks;
    if (hooks.count == 0) {
        QQHBLog(@"[绑定] config.json 的 grabHooks 还是空的，先看诊断日志");
        return;
    }
    for (NSDictionary *h in hooks) {
        NSString *clsName = h[@"class"];
        NSString *selName = h[@"selector"];
        if (![clsName isKindOfClass:[NSString class]] || ![selName isKindOfClass:[NSString class]]) continue;
        Class cls = objc_getClass(clsName.UTF8String);
        if (!cls) {
            QQHBLog(@"[绑定] 类 %@ 还没加载，稍后重试", clsName);
            continue;
        }
        QQHBInstallHook(cls, NSSelectorFromString(selName));
    }
}

static void (*gOrigPost3)(id, SEL, id, id, id);
static void (*gOrigPost2)(id, SEL, id, id);

static void QQHBHookPost3(id self, SEL _cmd, id name, id object, id userInfo) {
    NSString *n = QQHBStringOf(name);
    if (n.length) {
        BOOL hit = ([n rangeOfString:@"HB" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                   ([n rangeOfString:@"Red" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                   ([n rangeOfString:@"Wallet" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                   ([n rangeOfString:@"Grab" options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (hit) {
            NSString *line = [NSString stringWithFormat:@"%@  %@  object=%@  info=%@",
                              [NSDate date], n, NSStringFromClass([object class]),
                              QQHBStringOf(userInfo)];
            QQHBAppendText(@"notify.txt", line);
        }
    }
    if (gOrigPost3) gOrigPost3(self, _cmd, name, object, userInfo);
}

static void QQHBHookPost2(id self, SEL _cmd, id name, id object) {
    NSString *n = QQHBStringOf(name);
    if (n.length && [n rangeOfString:@"HB" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        QQHBAppendText(@"notify.txt", [NSString stringWithFormat:@"%@  %@  object=%@",
                                       [NSDate date], n, NSStringFromClass([object class])]);
    }
    if (gOrigPost2) gOrigPost2(self, _cmd, name, object);
}

static void QQHBInstallNotificationHooks(void) {
    static BOOL done;
    if (done) return;
    Class nc = objc_getClass("NSNotificationCenter");
    if (!nc || !gMSHookMessageEx) return;
    IMP o3 = NULL;
    gMSHookMessageEx(nc, NSSelectorFromString(@"postNotificationName:object:userInfo:"),
                     (IMP)QQHBHookPost3, &o3);
    gOrigPost3 = (void (*)(id, SEL, id, id, id))o3;
    IMP o2 = NULL;
    gMSHookMessageEx(nc, NSSelectorFromString(@"postNotificationName:object:"),
                     (IMP)QQHBHookPost2, &o2);
    gOrigPost2 = (void (*)(id, SEL, id, id))o2;
    done = YES;
    QQHBLog(@"[通知] 已挂上 NSNotificationCenter 观察");
}

static void QQHBInstallTraceHooks(void) {
    static BOOL done;
    if (done) return;
    done = YES;

    NSArray *classes = @[@"QQWallet",
                         @"QQWalletRedPacketMsgView",
                         @"QQWalletRedPacketSpecifyMsgView",
                         @"QQWalletRedPacketFestivalMsgView",
                         @"QQWalletGrapHBService",
                         @"QQWalletRedPacketMsgModel",
                         @"QQWalletNTRedPackMsgModel",
                         @"QQWalletRedPackManager"];
    NSArray *keywords = @[@"grab", @"Grab", @"open", @"Open", @"click", @"Click",
                          @"tap", @"Tap", @"tail", @"Tail", @"handle", @"Handle",
                          @"send", @"Send", @"request", @"Request", @"start", @"Start"];
    NSUInteger installed = 0;
    for (NSString *clsName in classes) {
        Class cls = objc_getClass(clsName.UTF8String);
        if (!cls) continue;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count && installed < 300; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            BOOL hit = NO;
            for (NSString *k in keywords) {
                if ([selName rangeOfString:k].location != NSNotFound) { hit = YES; break; }
            }
            if (!hit) continue;
            if (QQHBInstallHook(cls, method_getName(methods[i]))) installed++;
        }
        if (methods) free(methods);
    }
    QQHBLog(@"[追踪] 已挂 %lu 个方法", (unsigned long)installed);
}

void QQHBStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        QQHBResolveHookAPI();
        [QQHBConfig shared];

        /* 立刻装一批，然后每 3 秒重试一次，持续两分钟（QQ 的类经常是懒加载的） */
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([[QQHBConfig shared] diagnose]) QQHBDiagnoseScan();
            QQHBInstallConfiguredHooks();
            QQHBInstallNotificationHooks();
            if ([[QQHBConfig shared] diagnose]) QQHBInstallTraceHooks();
        });
        for (int i = 1; i <= 40; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                QQHBInstallConfiguredHooks();
            });
        }
    });
}

__attribute__((constructor)) static void QQHBInit(void) {
    QQHBLog(@"ApelinLoaded %s", APELIN_BUILD_ID);
    QQHBLog(@"QQ抢红包载入 pid=%d rev=%s", (int)getpid(), QQHB_GIT_REV);
    dispatch_async(dispatch_get_main_queue(), ^{ QQHBStart(); });
}
