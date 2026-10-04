#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/27.2.12479018}}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.16}"
ABI="${ANDROID_ABI:-arm64-v8a}"
PLATFORM="${ANDROID_PLATFORM:-android-26}"
DEPS_DIR="${XMRAND_DEPS_DIR:-$ROOT_DIR/deps/android-arm64}"
SRC_DIR="$ROOT_DIR/build/deps-src"
SOURCE_DIR="$SRC_DIR/openssl-${OPENSSL_VERSION}"
BUILD_DIR="$SRC_DIR/openssl-${OPENSSL_VERSION}-${ABI}-build"
TARBALL="$SRC_DIR/openssl-${OPENSSL_VERSION}.tar.gz"
JOBS="${JOBS:-4}"

die() {
    echo "error: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

android_api() {
    local platform="$1"
    platform="${platform#android-}"
    [[ "$platform" =~ ^[0-9]+$ ]] || die "ANDROID_PLATFORM must look like android-26 or a numeric API level"
    echo "$platform"
}

openssl_target() {
    case "$ABI" in
        arm64-v8a) echo "android-arm64" ;;
        armeabi-v7a) echo "android-arm" ;;
        x86_64) echo "android-x86_64" ;;
        x86) echo "android-x86" ;;
        *) die "unsupported Android ABI for OpenSSL: $ABI" ;;
    esac
}

need curl
need make
need perl
need tar

TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
LLVM_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[[ -f "$TOOLCHAIN" ]] || die "Android NDK toolchain not found at $TOOLCHAIN"
[[ -d "$LLVM_BIN" ]] || die "Android NDK llvm toolchain not found at $LLVM_BIN"

mkdir -p "$SRC_DIR" "$DEPS_DIR"

if [[ ! -f "$TARBALL" ]]; then
    curl -fL --retry 3 "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" -o "$TARBALL"
fi

EXPECTED_SHA256="${OPENSSL_SHA256:-57e03c50feab5d31b152af2b764f10379aecd8ee92f16c985983ce4a99f7ef86}"
[[ $(sha256sum "$TARBALL" | awk '{print $1}') == "$EXPECTED_SHA256" ]] || die "Source checksum mismatch"

if [[ ! -d "$SOURCE_DIR" ]]; then
    tar -xzf "$TARBALL" -C "$SRC_DIR"
fi

case "$BUILD_DIR" in
    "$SRC_DIR"/openssl-"$OPENSSL_VERSION"-"$ABI"-build) ;;
    *) die "refusing to clear unexpected OpenSSL build directory: $BUILD_DIR" ;;
esac
rm -rf "$BUILD_DIR"
cp -a "$SOURCE_DIR" "$BUILD_DIR"

API="$(android_api "$PLATFORM")"
TARGET="$(openssl_target)"

(
    cd "$BUILD_DIR"
    export ANDROID_NDK_ROOT="$NDK"
    export PATH="$LLVM_BIN:$PATH"

    ./Configure "$TARGET" \
        -D__ANDROID_API__="$API" \
        --prefix="$DEPS_DIR" \
        --openssldir="$DEPS_DIR/ssl" \
        no-shared \
        no-tests \
        no-ui-console \
        no-dso \
        no-comp \
        no-legacy

    make -j"$JOBS"
    make install_sw
)

echo "$DEPS_DIR"
