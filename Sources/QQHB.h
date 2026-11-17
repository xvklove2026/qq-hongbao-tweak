#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

#ifndef QQHB_SUBSYSTEM
#define QQHB_SUBSYSTEM "com.yg.qqhongbao"
#endif

os_log_t QQHBLogHandle(void);
void QQHBLogMsg(NSString *msg);
#define QQHBLog(...) QQHBLogMsg([NSString stringWithFormat:__VA_ARGS__])

/* QQ 沙盒内的配置/记录目录 */
NSString *QQHBSupportDir(void);
NSString *QQHBConfigPath(void);
NSString *QQHBStatsPath(void);

/* 读取任意对象的候选 KVC 字段（不抛异常） */
id QQHBKVCFirst(id obj, NSArray<NSString *> *keys);
NSString *QQHBStringOf(id value);
