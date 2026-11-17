#import <Foundation/Foundation.h>

@interface QQHBStats : NSObject

/* 记录一次抢到：发送者 QQ、昵称、金额（分）、标题、时间、来源类/方法 */
+ (void)recordWithSenderName:(NSString *)name
                    senderUin:(NSString *)uin
                  amountCents:(NSNumber *)cents
                   amountText:(NSString *)amountText
                        title:(NSString *)title
                        extra:(NSDictionary *)extra;

+ (NSArray<NSDictionary *> *)records;

@end
