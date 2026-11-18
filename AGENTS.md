# QQ开包（QQ 抢红包 tweak）

## 这是什么
注入 iPhone QQ（com.tencent.mqq）的 tweak：自动抢红包，支持「自己发的也抢」「专属红包不抢」
「关键词黑名单不抢」，并把每次抢到的发送者 QQ、昵称、金额、时间记到 JSON 里。

## 目录
- `Sources/QQHB.h` 公共工具与日志
- `Sources/QQHBConfig.h/.m` 配置（config.json 读写、关键词判断）
- `Sources/QQHBStats.h/.m` 抢包记录
- `Sources/QQHB.m` 引擎：类扫描、MSHookMessageEx 装钩子、跳过判断、记录
- `Resources/QQHongbao.plist` 过滤 plist（Bundle 过滤）
- `Resources/config.example.json` 配置样例
- `apelin/build.sh` 外部构建脚本（clang 编译 + ldid 签名 + dpkg-deb 打包）

## 构建
`apelin_project_build` 会跑 `apelin/build.sh`，产物落在 Apelin 的 build 目录。
脚本从环境变量取 `APELIN_PROJECT_ROOT / APELIN_PREFIX / APELIN_ARCHITECTURE /
APELIN_BOOTSTRAP / APELIN_BUILD_ID / APELIN_PACKAGE_DIR`，不要给这些变量传空值。

**本机（iPhone10,3，iOS 16.7.16）无法构建**：Apelin 列出的每个 CLT 都要求
FEAT_LRCPC，这颗 A11 没有；`apelin_toolchain_list` 里全部标 unavailable，
`clang` 不存在，`apelin/build.sh` 第 28 行以 127 退出。

## GitHub Actions（仓库 xvklove2026/qq-hongbao-tweak）
`.github/workflows/build.yml`：ubuntu-latest → 装 clang/llvm → 编 ldid →
sparse 检出 theos 的 iPhoneOS16.5.sdk → 跑 `apelin/build.sh` 出两个 deb。
失败时把 `/tmp/build.log` 推到 `ci-log-<bootstrap>` 分支，可从 raw 读。

2026-11-18 状态：源码编译通过，链接仍未通：
- `-F` 已确认传对，SDK 里 Foundation.framework 只有 `Foundation.tbd`；
  自编 ld64 没有 TAPI，读不了 .tbd → `framework not found Foundation`。
- 已改试 `-undefined dynamic_lookup`（不链 framework）+ `-fno-autolink`
  （`-fmodules` 会自动给 clang 塞 `-framework Foundation`），仍未通过，
  精简日志 `ci-log-errors.txt` 里只剩 `clang: error: linker command failed`，
  ld 的具体报错不在过滤结果里，需要看原始 `ci-log.txt` 尾部。
- macOS 原生构建不存在这些问题（Xcode 的 ld 支持 tbd），优先走 Mac。

CI 失败时会把 `/tmp/build.log` 尾部 20KB 推到 `ci-log-<bootstrap>` 分支。

可行出路：在 Mac 上用 Xcode 的 clang 编译（最稳），或继续把 cctools 的
libdispatch 依赖处理掉。

## 运行期
- 包 ID `com.yg.qqhongbao`，dylib `QQHongbao.dylib`。
- 配置：QQ 沙盒内 `Library/Application Support/QQHongbao/config.json`
  （首次载入自动写默认值）。字段：
  `enabled`、`diagnose`、`grabOwnPackets`、`skipExclusive`、
  `skipTitleKeywords`、`grabKeywords`、`delayMs`/`delayMaxMs`（随机延迟）、
  `selfUin`（自己的 QQ 号）、`exclusiveTypes`（视为专属的类型值）、`grabHooks`。
- 记录：同目录 `stats.json`（最多 2000 条，最新在后）、`stats.txt`（可读账本）、
  `skips.txt`（跳过原因，超 256KB 自动清空）。
- 日志 subsystem `com.yg.qqhongbao`，用 `apelin_log_read` 读。

## 关键未完成项
`grabHooks` 默认为空。QQ 的红包类/方法名随版本变化，代码里没有写死：
`diagnose: true` 时会把所有名字含 RedPack/Hongbao/Envelope 的类及其
grab/open/receive 候选方法与类型编码打进日志，看到日志后再把它们填进
`config.json` 的 `grabHooks`，引擎才真正开始拦截和抢包。

## 当前状态（2026-11-18 12:00）
- 能装、能注入（fat dylib 必须）、能生成 config.json。
- **手动点开红包时可以记录**：发送者昵称、QQ 号、时间（`stats.txt`），金额还没接上。
- 自动抢**未成功**（QQ 9.3.80）：
  - `QQWallet -grabHB:params:completion:` / `grabRedPack:params:completion:` 是点击后的底层接口，
    自动调用返回 `user cancel`。
  - 卡片类 `QQWalletRedPacketMsgView`（及 Specify/Festival 子类）的
    `updateViewWithRedPacketMsgModel:` / `setRedPacketMsgModel:` 能钩到（模型是
    `QQWalletNTRedPackMsgModel`），但 `openButton` 的 `sendActionsForControlEvents:` 和
    `tailButtonClicked:` 都不会真正触发抢包。
  - 直接调 `grabHB` 兜底时拿不到 params（模型的 `grabHBParam` 没返回可用值）。
- 结论：要全自动，需要对 QQ 做动态追踪（frida 类工具）抓「用户点开红包」那一刻的方法调用链，
  或者构造 AIOData 走 `QQWalletGrapHBService -grapHBProcess:...`。

## 踩过的坑（roothide 注入）
- 瘦 `arm64e` 的 dylib（`cffaedfe`，cpusubtype 0x80000002）ElleKit **不会加载**，
  日志里连错误都没有。可加载的 tweak（QQRecallGuard、QQNotiAvatar）都是
  fat 二进制（`cafebabe`，arm64 + arm64e 两个 slice）。所以 `apelin/build.sh`
  对 roothide 也必须 lipo 成 fat。
- 过滤 plist 用 XML 格式（与设备上其它 tweak 一致），OpenStep 格式未验证。
- roothide 的 `DynamicLibraries` 与 `/usr/lib/TweakInject` 是同一批文件（inode 相同），
  改一处即另一处。
- 排查手段：`icli log syslog --process QQ` 抓启动日志；
  崩溃报告 `usedImages` 里能直接看到被注入的 dylib 路径。
