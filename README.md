# QQ 抢红包 tweak

注入 iPhone QQ（`com.tencent.mqq`）的越狱插件：自动抢红包，自己发的也抢，专属红包和关键词命中的不抢，
每次抢到都记下发送者 QQ、昵称、金额和时间。

## 安装

从 [Actions](../../actions) 下载 `qqhongbao-roothide` 或 `qqhongbao-rootless` 的 deb，用 Sileo / Filza 安装。
roothide 越狱装 roothide 包，rootless（Dopamine 等）装 rootless 包。

## 配置

装上后在 QQ 沙盒的配置文件里改：

```
<QQ 容器>/Library/Application Support/QQHongbao/config.json
```

| 字段 | 说明 |
| --- | --- |
| `enabled` | 总开关 |
| `diagnose` | 诊断模式：把疑似红包的类/方法打进日志，默认开 |
| `grabOwnPackets` | 自己发的红包也抢 |
| `skipExclusive` | 专属红包不抢 |
| `skipTitleKeywords` | 标题含这些词就不抢，默认 `["专属","测试"]` |
| `grabKeywords` | 非空时标题必须命中其中之一才抢 |
| `delayMs` / `delayMaxMs` | 抢之前随机延迟（毫秒） |
| `selfUin` | 自己的 QQ 号，用于识别自己发的包 |
| `exclusiveTypes` | 这些类型值视为专属红包 |
| `grabHooks` | 真正拦截的方法：`[{"class":"...","selector":"..."}]` |

记录写在同目录：`stats.json`、`stats.txt`（可读账本）、`skips.txt`（跳过原因）。

## 状态

`grabHooks` 默认为空——QQ 的红包类名/方法名随版本变化，需要先看诊断日志再填，否则不会真的抢。
日志 subsystem 是 `com.yg.qqhongbao`。

## 构建

```
bash apelin/build.sh
```

需要的环境变量见脚本开头；CI 用 `.github/workflows/build.yml`（macOS runner + ldid + dpkg-deb）。
