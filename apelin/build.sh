#!/bin/sh
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build, or set it (CI wrapper does)}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}"

NAME=QQHongbao
PACKAGE=com.yg.qqhongbao
VERSION=0.1.0
PREFIX="${APELIN_PREFIX:-}"

# Apelin 通过 SDKROOT 给 SDK；Mac / GitHub runner 上没有，用 xcrun 取
SYSROOT="${SDKROOT:-}"
if [ -z "$SYSROOT" ] && command -v xcrun >/dev/null 2>&1; then
    SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
fi

# Linux 交叉编译用 lld 的 Mach-O 模式
LD_FLAGS=""
if [ "$(uname -s)" = "Linux" ]; then
    LD_FLAGS="-fuse-ld=lld"
fi

stage="$(mktemp -d "${TMPDIR:?}stage.XXXXXX")"
work="$(mktemp -d "${TMPDIR:?}work.XXXXXX")"
trap 'rm -rf -- "${stage:?}" "${work:?}"' EXIT

cd "${APELIN_PROJECT_ROOT:?}"

SOURCES="Sources/QQHB.m Sources/QQHBConfig.m Sources/QQHBStats.m"
COMMON="-fobjc-arc -Os -Wall -Wno-unused-parameter -fvisibility=hidden -fmodules -I Sources"
# ld64.lld 不支持常量 CFString 段的重定位，改为运行期构造
COMMON="$COMMON -fno-constant-cfstrings"
COMMON="$COMMON -DAPELIN_BUILD_ID=\"\\\"$APELIN_BUILD_ID\\\"\""
COMMON="$COMMON -DQQHB_SUBSYSTEM=\"\\\"$PACKAGE\\\"\""

mkdir -p "${APELIN_PACKAGE_DIR:?}"

run_clang() {
    arch="$1"; out="$2"; shift 2
    if [ -n "$SYSROOT" ]; then
        clang -target "$arch-apple-ios16.0" -isysroot "$SYSROOT" $LD_FLAGS "$@" \
            -dynamiclib -framework Foundation -o "$out"
    else
        clang -target "$arch-apple-ios16.0" $LD_FLAGS "$@" \
            -dynamiclib -framework Foundation -o "$out"
    fi
}

if [ "$APELIN_BOOTSTRAP" = "roothide" ]; then
    run_clang arm64e "${work:?}/$NAME.dylib" $COMMON -DAPELIN_BOOTSTRAP_ROOTHIDE=1 $SOURCES
else
    COMMON="$COMMON -DAPELIN_BOOTSTRAP_ROOTLESS=1"
    run_clang arm64 "${work:?}/$NAME.arm64.dylib" $COMMON $SOURCES
    run_clang arm64e "${work:?}/$NAME.arm64e.dylib" $COMMON $SOURCES
    lipo -create "${work:?}/$NAME.arm64.dylib" "${work:?}/$NAME.arm64e.dylib" \
        -output "${work:?}/$NAME.dylib"
fi

ldid -S "${work:?}/$NAME.dylib"

LIBDIR="$stage$PREFIX/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "${LIBDIR:?}" "$stage$PREFIX/DEBIAN"
cp "${work:?}/$NAME.dylib" "${LIBDIR:?}/$NAME.dylib"
cp "Resources/$NAME.plist" "${LIBDIR:?}/$NAME.plist"

cat > "$stage$PREFIX/DEBIAN/control" <<EOF
Package: $PACKAGE
Name: QQ 抢红包
Version: $VERSION
Architecture: $APELIN_ARCHITECTURE
Author: YG
Section: Tweaks
Depends: firmware (>= 16.0), mobilesubstrate
Description: QQ 自动抢红包：可抢自己发的，专属红包不抢，关键词黑名单不抢，并记录发送者 QQ、昵称、金额与时间。
EOF

dpkg-deb -b --root-owner-group "${stage:?}" "${APELIN_PACKAGE_DIR:?}/" >/dev/null
ls -1 "${APELIN_PACKAGE_DIR:?}"
