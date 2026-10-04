#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/27.2.12479018}}"
ABI="${ANDROID_ABI:-arm64-v8a}"
PLATFORM="${ANDROID_PLATFORM:-android-26}"
DEPS_DIR="${XMRAND_DEPS_DIR:-$ROOT_DIR/deps/android-arm64}"
JOBS="${JOBS:-4}"
WITH_TLS="${XMRAND_WITH_TLS:-OFF}"
WITH_HTTP="${XMRAND_WITH_HTTP:-$WITH_TLS}"
BUILD_SUFFIX="${XMRAND_BUILD_SUFFIX:-}"
EXTRA_C_FLAGS="${XMRAND_EXTRA_C_FLAGS:-}"
EXTRA_CXX_FLAGS="${XMRAND_EXTRA_CXX_FLAGS:-}"
EXTRA_LINKER_FLAGS="${XMRAND_EXTRA_LINKER_FLAGS:-}"
PAGE_SIZE="${XMRAND_PAGE_SIZE:-16384}"
LTO="${XMRAND_LTO:-OFF}"
ARM8_FLAGS="${XMRAND_ARM8_FLAGS:-}"

die() {
    echo "error: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

cmake_bool() {
    case "${1,,}" in
        1|on|true|yes|y) echo "ON" ;;
        0|off|false|no|n) echo "OFF" ;;
        *) die "expected boolean value, got: $1" ;;
    esac
}

need cmake
need ninja

WITH_TLS="$(cmake_bool "$WITH_TLS")"
WITH_HTTP="$(cmake_bool "$WITH_HTTP")"
LTO="$(cmake_bool "$LTO")"
BUILD_DIR="${XMRAND_BUILD_DIR:-$ROOT_DIR/build/android-arm64-xmrig}"
if [[ "$WITH_TLS" == "ON" && -z "${XMRAND_BUILD_DIR:-}" ]]; then
    BUILD_DIR="$ROOT_DIR/build/android-arm64-xmrig-tls"
fi
if [[ -n "$BUILD_SUFFIX" && -z "${XMRAND_BUILD_DIR:-}" ]]; then
    safe_suffix="$(printf '%s' "$BUILD_SUFFIX" | tr -cd 'A-Za-z0-9_.-')"
    [[ -n "$safe_suffix" ]] || die "XMRAND_BUILD_SUFFIX produced an empty safe suffix"
    BUILD_DIR="${BUILD_DIR}-${safe_suffix}"
fi

TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
[[ -f "$TOOLCHAIN" ]] || die "Android NDK toolchain not found at $TOOLCHAIN"

if [[ ! -f "$DEPS_DIR/lib/libuv.a" || ! -f "$DEPS_DIR/include/uv.h" ]]; then
    "$ROOT_DIR/scripts/android/build-libuv-arm64.sh"
fi

if [[ "$WITH_TLS" == "ON" && ( ! -f "$DEPS_DIR/lib/libssl.a" || ! -f "$DEPS_DIR/lib/libcrypto.a" || ! -f "$DEPS_DIR/include/openssl/ssl.h" ) ]]; then
    "$ROOT_DIR/scripts/android/build-openssl-arm64.sh"
fi

CMAKE_ARGS=(
    -S "$ROOT_DIR"
    -B "$BUILD_DIR"
    -G Ninja
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="$PLATFORM" \
    -DCMAKE_BUILD_TYPE=Release \
    -DXMRIG_DEPS="$DEPS_DIR" \
    -DUV_INCLUDE_DIR="$DEPS_DIR/include" \
    -DUV_LIBRARY="$DEPS_DIR/lib/libuv.a" \
    -DWITH_HWLOC=OFF \
    -DWITH_TLS="$WITH_TLS" \
    -DWITH_OPENCL=OFF \
    -DWITH_CUDA=OFF \
    -DWITH_ADL=OFF \
    -DWITH_NVML=OFF \
    -DWITH_MSR=OFF \
    -DWITH_DMI=OFF \
    -DWITH_HTTP="$WITH_HTTP" \
    -DWITH_ASM=ON \
    -DARM_V8=ON \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION="$LTO"
)

if [[ -n "$ARM8_FLAGS" ]]; then
    CMAKE_ARGS+=(-DXMRIG_ARM8_FLAGS="$ARM8_FLAGS")
fi
if [[ -n "$EXTRA_C_FLAGS" ]]; then
    CMAKE_ARGS+=(-DCMAKE_C_FLAGS="$EXTRA_C_FLAGS")
fi
if [[ -n "$EXTRA_CXX_FLAGS" ]]; then
    CMAKE_ARGS+=(-DCMAKE_CXX_FLAGS="$EXTRA_CXX_FLAGS")
fi
if [[ -n "$PAGE_SIZE" ]]; then
    EXTRA_LINKER_FLAGS="-Wl,-z,max-page-size=$PAGE_SIZE ${EXTRA_LINKER_FLAGS}"
fi
if [[ -n "${EXTRA_LINKER_FLAGS// }" ]]; then
    CMAKE_ARGS+=(-DCMAKE_EXE_LINKER_FLAGS="$EXTRA_LINKER_FLAGS")
fi

if [[ "$WITH_TLS" == "ON" ]]; then
    CMAKE_ARGS+=(
        -DOPENSSL_ROOT_DIR="$DEPS_DIR"
        -DOPENSSL_INCLUDE_DIR="$DEPS_DIR/include"
        -DOPENSSL_SSL_LIBRARY="$DEPS_DIR/lib/libssl.a"
        -DOPENSSL_CRYPTO_LIBRARY="$DEPS_DIR/lib/libcrypto.a"
    )
fi

cmake "${CMAKE_ARGS[@]}" "$@"

cmake --build "$BUILD_DIR" -j"$JOBS"

if [[ "$WITH_TLS" == "ON" ]]; then
    echo "$BUILD_DIR/xmrig"
else
    echo "$BUILD_DIR/xmrig-notls"
fi
