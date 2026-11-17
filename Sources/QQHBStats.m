#import "QQHB.h"
#import "QQHBStats.h"

static NSString *const kQQHBStatsFile = @"stats.json";
static const NSUInteger kQQHBStatsMax = 2000;

@implementation QQHBStats

+ (NSArray<NSDictionary *> *)records {
    NSString *path = QQHBStatsPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @[];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:[NSArray class]] ? obj : @[];
}

+ (void)recordWithSenderName:(NSString *)name
                   senderUin:(NSString *)uin
                 amountCents:(NSNumber *)cents
                  amountText:(NSString *)amountText
                       title:(NSString *)title
                       extra:(NSDictionary *)extra {
    NSMutableDictionary *rec = [NSMutableDictionary dictionary];
    rec[@"time"] = ({
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        [f stringFromDate:[NSDate date]];
    });
    rec[@"senderUin"] = uin.length ? uin : @"";
    rec[@"senderName"] = name.length ? name : @"";
    rec[@"title"] = title.length ? title : @"";
    if (cents) {
        rec[@"amountCents"] = cents;
        rec[@"amount"] = [NSString stringWithFormat:@"%.2f", cents.doubleValue / 100.0];
    } else if (amountText.length) {
        rec[@"amount"] = amountText;
    }
    if (extra.count) {
        NSMutableDictionary *safe = [NSMutableDictionary dictionary];
        [extra enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            if ([k isKindOfClass:[NSString class]] &&
                ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]])) {
                safe[k] = v;
            } else if ([k isKindOfClass:[NSString class]] && v) {
                safe[k] = [v description];
            }
        }];
        if (safe.count) rec[@"extra"] = safe;
    }

    NSMutableArray *all = [[self records] mutableCopy];
    [all addObject:rec];
    if (all.count > kQQHBStatsMax) {
        [all removeObjectsInRange:NSMakeRange(0, all.count - kQQHBStatsMax)];
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:all options:0 error:NULL];
    [out writeToFile:QQHBStatsPath() atomically:YES];

    QQHBLog(@"[抢到] %@(%@) %@ 元  「%@」 %@",
            rec[@"senderName"], rec[@"senderUin"], rec[@"amount"] ?: @"?", rec[@"title"], rec[@"time"]);

    /* 同时写一行人可读账本，方便直接翻文件看 */
    NSString *txtPath = [QQHBSupportDir() stringByAppendingPathComponent:@"stats.txt"];
    NSString *line = [NSString stringWithFormat:@"%@  %@  QQ:%@  %@元  「%@」\n",
                      rec[@"time"], rec[@"senderName"], rec[@"senderUin"],
                      rec[@"amount"] ?: @"?", rec[@"title"]];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:txtPath];
    if (!fh) {
        [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:txtPath atomically:YES];
    } else {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (__unused NSException *e) {
        }
        [fh closeFile];
    }
}

@end
