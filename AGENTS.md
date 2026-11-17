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

2026-11-18 状态：源码编译通过，链接阶段还在啃：
- `ld64.lld` 对 clang 21 生成的 ObjC 字符串段报 `INVALID relocation has width 8 bytes`。
- 改为在 CI 里自编 cctools-port 的 ld64（需要先编 swift-corelibs-libdispatch，
  用 `-DCMAKE_C_COMPILER=clang`），已装成 `/usr/local/bin/aarch64-apple-darwin-ld`，
  通过 `APELIN_LD_FLAGS="--ld-path=..."` 传给 clang。
- 当前报 `ld: framework not found Foundation`；`apelin/build.sh` 已补
  `-F"$SYSROOT/System/Library/Frameworks" -L"$SYSROOT/usr/lib"`，尚未确认生效。
- 本账号拿不到 macOS runner：`macos-14` 报 configuration not supported，`macos-13` 排不到。

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
