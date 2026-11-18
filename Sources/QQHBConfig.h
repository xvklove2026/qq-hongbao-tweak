#import <Foundation/Foundation.h>

@interface QQHBConfig : NSObject

+ (instancetype)shared;
- (void)reload;

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL diagnose;
@property (nonatomic, readonly) BOOL grabOwnPackets;
@property (nonatomic, readonly) BOOL skipExclusive;
@property (nonatomic, readonly) NSInteger delayMs;
@property (nonatomic, readonly) NSInteger delayMaxMs;
@property (nonatomic, readonly) NSString *selfUin;
@property (nonatomic, readonly) NSArray<NSNumber *> *exclusiveTypes;
@property (nonatomic, readonly) NSArray<NSString *> *skipTitleKeywords;
@property (nonatomic, readonly) NSArray<NSString *> *grabKeywords;
@property (nonatomic, readonly) NSArray<NSDictionary *> *grabHooks;

- (BOOL)isObserveSelector:(SEL)sel;

- (BOOL)shouldSkipTitle:(NSString *)title;
- (BOOL)titleWanted:(NSString *)title;

@end
