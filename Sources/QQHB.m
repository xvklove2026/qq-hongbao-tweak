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

static IMP QQHBOriginalFor(SEL sel) {
    NSValue *v = gOriginals[NSStringFromSelector(sel)];
    return v ? (IMP)v.pointerValue : NULL;
}

static NSInteger QQHBRandomDelay(void) {
    QQHBConfig *cfg = [QQHBConfig shared];
    NSInteger lo = cfg.delayMs, hi = cfg.delayMaxMs;
    if (hi <= lo) return lo;
    return lo + (NSInteger)arc4random_uniform((uint32_t)(hi - lo + 1));
}

static void QQHBAppendText(NSString *file, NSString *line) {
    NSString *path = [QQHBSupportDir() stringByAppendingPathComponent:file];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if ([attrs[NSFileSize] unsignedLongLongValue] > 256 * 1024) {
        [fm removeItemAtPath:path error:NULL];
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

/* 返回 YES 表示允许原方法继续（即真的去抢） */
static BOOL QQHBBefore(id target, SEL sel, id arg) {
    QQHBConfig *cfg = [QQHBConfig shared];
    NSString *why = nil;
    id packet = target ?: arg;
    if (cfg.diagnose) {
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
    QQHBRecordGrabbed(target ?: arg, sel);
}

/* 各种签名对应的跳板 */
static void QQHBT_void_0(id self, SEL _cmd) {
    if (!QQHBBefore(self, _cmd, nil)) return;
    IMP o = QQHBOriginalFor(_cmd); if (o) ((void (*)(id, SEL))o)(self, _cmd);
    QQHBAfter(self, _cmd, nil, nil);
}

static void QQHBT_void_1(id self, SEL _cmd, id a1) {
    if (!QQHBBefore(self, _cmd, a1)) return;
    QQHBConfig *cfg = [QQHBConfig shared];
    IMP o = QQHBOriginalFor(_cmd);
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
    if (!QQHBBefore(self, _cmd, a1)) return nil;
    IMP o = QQHBOriginalFor(_cmd);
    id r = o ? ((id (*)(id, SEL, id))o)(self, _cmd, a1) : nil;
    QQHBAfter(self, _cmd, a1, r);
    return r;
}

static BOOL QQHBT_bool_1(id self, SEL _cmd, id a1) {
    if (!QQHBBefore(self, _cmd, a1)) return NO;
    IMP o = QQHBOriginalFor(_cmd);
    BOOL r = o ? ((BOOL (*)(id, SEL, id))o)(self, _cmd, a1) : NO;
    QQHBAfter(self, _cmd, a1, nil);
    return r;
}

static long long QQHBT_int_1(id self, SEL _cmd, id a1) {
    if (!QQHBBefore(self, _cmd, a1)) return 0;
    IMP o = QQHBOriginalFor(_cmd);
    long long r = o ? ((long long (*)(id, SEL, id))o)(self, _cmd, a1) : 0;
    QQHBAfter(self, _cmd, a1, nil);
    return r;
}

static void QQHBT_void_2(id self, SEL _cmd, id a1, id a2) {
    if (!QQHBBefore(self, _cmd, a1)) return;
    IMP o = QQHBOriginalFor(_cmd); if (o) ((void (*)(id, SEL, id, id))o)(self, _cmd, a1, a2);
    QQHBAfter(self, _cmd, a1, nil);
}

static id QQHBT_id_2(id self, SEL _cmd, id a1, id a2) {
    if (!QQHBBefore(self, _cmd, a1)) return nil;
    IMP o = QQHBOriginalFor(_cmd);
    id r = o ? ((id (*)(id, SEL, id, id))o)(self, _cmd, a1, a2) : nil;
    QQHBAfter(self, _cmd, a1, r);
    return r;
}

static void QQHBT_void_3(id self, SEL _cmd, id a1, id a2, id a3) {
    if (!QQHBBefore(self, _cmd, a1)) return;
    IMP o = QQHBOriginalFor(_cmd);
    if (o) ((void (*)(id, SEL, id, id, id))o)(self, _cmd, a1, a2, a3);
    QQHBAfter(self, _cmd, a1, nil);
}

static id QQHBT_id_3(id self, SEL _cmd, id a1, id a2, id a3) {
    if (!QQHBBefore(self, _cmd, a1)) return nil;
    IMP o = QQHBOriginalFor(_cmd);
    id r = o ? ((id (*)(id, SEL, id, id, id))o)(self, _cmd, a1, a2, a3) : nil;
    QQHBAfter(self, _cmd, a1, r);
    return r;
}

static void QQHBT_void_4(id self, SEL _cmd, id a1, id a2, id a3, id a4) {
    /* grabHBParams:password:checkInfo:redPack: —— 红包对象在最后一个参数 */
    if (!QQHBBefore(self, _cmd, a4 ?: a1)) return;
    IMP o = QQHBOriginalFor(_cmd);
    if (o) ((void (*)(id, SEL, id, id, id, id))o)(self, _cmd, a1, a2, a3, a4);
    QQHBAfter(self, _cmd, a4 ?: a1, nil);
}

static id QQHBT_id_4(id self, SEL _cmd, id a1, id a2, id a3, id a4) {
    if (!QQHBBefore(self, _cmd, a4 ?: a1)) return nil;
    IMP o = QQHBOriginalFor(_cmd);
    id r = o ? ((id (*)(id, SEL, id, id, id, id))o)(self, _cmd, a1, a2, a3, a4) : nil;
    QQHBAfter(self, _cmd, a4 ?: a1, r);
    return r;
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
        if (expectRet) { ret = c; expectRet = NO; continue; }
        [types addObject:@(c)];
    }
    /* types[0] 是 self(@)，types[1] 是 _cmd(:) */
    NSUInteger argc = types.count > 2 ? types.count - 2 : 0;
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
    if (orig) gOriginals[NSStringFromSelector(sel)] = [NSValue valueWithPointer:orig];
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
        }
    }
    if (classes) free(classes);
    QQHBLog(@"[诊断] 扫描完成，候选类 %lu 个，共 %lu 行。把含 RedPack/红包 的几行配置到 grabHooks 里。",
            (unsigned long)candidates.count, (unsigned long)logged);
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

void QQHBStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        QQHBResolveHookAPI();
        [QQHBConfig shared];

        __block void (^attempt)(int);
        attempt = ^(int left) {
            if (left <= 0) return;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                QQHBInstallConfiguredHooks();
                attempt(left - 1);
            });
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [QQHBConfig shared];
            if ([[QQHBConfig shared] diagnose]) QQHBDiagnoseScan();
            QQHBInstallConfiguredHooks();
            attempt(12);
        });
    });
}

__attribute__((constructor)) static void QQHBInit(void) {
    QQHBLog(@"ApelinLoaded %s", APELIN_BUILD_ID);
    QQHBLog(@"QQ抢红包载入 pid=%d", (int)getpid());
    dispatch_async(dispatch_get_main_queue(), ^{ QQHBStart(); });
}
