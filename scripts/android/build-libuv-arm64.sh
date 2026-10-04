#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/27.2.12479018}}"
UV_VERSION="${UV_VERSION:-1.51.0}"
ABI="${ANDROID_ABI:-arm64-v8a}"
PLATFORM="${ANDROID_PLATFORM:-android-26}"
DEPS_DIR="${XMRAND_DEPS_DIR:-$ROOT_DIR/deps/android-arm64}"
SRC_DIR="$ROOT_DIR/build/deps-src"
BUILD_DIR="$SRC_DIR/libuv-v${UV_VERSION}-${ABI}-build"
TARBALL="$SRC_DIR/libuv-v${UV_VERSION}.tar.gz"

die() {
    echo "error: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need cmake
need curl
need ninja
need tar

TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
[[ -f "$TOOLCHAIN" ]] || die "Android NDK toolchain not found at $TOOLCHAIN"

mkdir -p "$SRC_DIR" "$DEPS_DIR"

if [[ ! -f "$TARBALL" ]]; then
    curl -fL --retry 3 "https://dist.libuv.org/dist/v${UV_VERSION}/libuv-v${UV_VERSION}.tar.gz" -o "$TARBALL"
fi

EXPECTED_SHA256="${UV_SHA256:-5f0557b90b1106de71951a3c3931de5e0430d78da1d9a10287ebc7a3f78ef8eb}"
[[ $(sha256sum "$TARBALL" | awk '{print $1}') == "$EXPECTED_SHA256" ]] || die "Source checksum mismatch"

if [[ ! -d "$SRC_DIR/libuv-v${UV_VERSION}" ]]; then
    tar -xzf "$TARBALL" -C "$SRC_DIR"
fi

cmake -S "$SRC_DIR/libuv-v${UV_VERSION}" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="$PLATFORM" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLIBUV_BUILD_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX="$DEPS_DIR"

cmake --build "$BUILD_DIR" --target install --parallel "${JOBS:-4}"

echo "$DEPS_DIR"
