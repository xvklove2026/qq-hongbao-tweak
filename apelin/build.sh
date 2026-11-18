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

# Linux 上用哪个链接器由外部决定：Theos 镜像里自带 ld64
LD_FLAGS="${APELIN_LD_FLAGS:-}"

stage="$(mktemp -d "${TMPDIR:?}stage.XXXXXX")"
work="$(mktemp -d "${TMPDIR:?}work.XXXXXX")"
trap 'rm -rf -- "${stage:?}" "${work:?}"' EXIT

cd "${APELIN_PROJECT_ROOT:?}"

SOURCES="Sources/QQHB.m Sources/QQHBConfig.m Sources/QQHBStats.m"
COMMON="-fobjc-arc -Os -Wall -Wno-unused-parameter -fvisibility=hidden -I Sources"
COMMON="$COMMON -DAPELIN_BUILD_ID=\"\\\"$APELIN_BUILD_ID\\\"\""
COMMON="$COMMON -DQQHB_SUBSYSTEM=\"\\\"$PACKAGE\\\"\""

mkdir -p "${APELIN_PACKAGE_DIR:?}"

# .tbd 需要 ld64 的 TAPI 支持；自编的 ld64 没有时改用动态查找
LINK_EXTRA=""
FRAMEWORKS="-framework Foundation"
if [ "${APELIN_UNDEFINED_LOOKUP:-0}" = "1" ]; then
    LINK_EXTRA="-Wl,-undefined,dynamic_lookup"
    FRAMEWORKS=""
    echo "mode: undefined dynamic lookup (no framework at link time)"
fi

echo "SYSROOT=$SYSROOT"
if [ -n "$SYSROOT" ]; then
    echo "frameworks:"; ls "$SYSROOT/System/Library/Frameworks" 2>/dev/null | head -8
    ls "$SYSROOT/System/Library/Frameworks/Foundation.framework" 2>/dev/null | head -8
fi

run_clang() {
    arch="$1"; out="$2"; shift 2
    if [ -n "$SYSROOT" ]; then
        echo "+ clang -target $arch-apple-ios16.0 -isysroot $SYSROOT $LD_FLAGS $LINK_EXTRA $*"
        clang -target "$arch-apple-ios16.0" -isysroot "$SYSROOT" $LD_FLAGS \
            -F"$SYSROOT/System/Library/Frameworks" -L"$SYSROOT/usr/lib" \
            "$@" $LINK_EXTRA -dynamiclib $FRAMEWORKS -o "$out"
    else
        echo "+ clang -target $arch-apple-ios16.0 $LD_FLAGS $LINK_EXTRA $*"
        clang -target "$arch-apple-ios16.0" $LD_FLAGS "$@" $LINK_EXTRA \
            -dynamiclib $FRAMEWORKS -o "$out"
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
