#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: build-libuv-arm64.sh

Build and install the pinned libuv static library for iPhoneOS arm64.

Environment:
  XMRAND_DEPS_DIR         Install prefix (default: <repo>/../deps/iphoneos)
  XMRAND_DEPS_SOURCE_DIR  Download/source/build cache (default: <repo>/build/deps-src)
  JOBS                    Parallel build jobs (default: detected CPU count)
  UV_VERSION              libuv version (default: 1.51.0)
  UV_SHA256               Source archive SHA-256 (default: pinned 1.51.0 hash)
  IOS_DEPLOYMENT_TARGET   Minimum iOS version (default: 16.0)
USAGE
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UV_VERSION="${UV_VERSION:-1.51.0}"
UV_SHA256="${UV_SHA256:-5f0557b90b1106de71951a3c3931de5e0430d78da1d9a10287ebc7a3f78ef8eb}"
DEPS_DIR="${XMRAND_DEPS_DIR:-$ROOT_DIR/../deps/iphoneos}"
SRC_DIR="${XMRAND_DEPS_SOURCE_DIR:-$ROOT_DIR/build/deps-src}"
SOURCE_DIR="$SRC_DIR/libuv-v${UV_VERSION}"
BUILD_DIR="$SRC_DIR/libuv-v${UV_VERSION}-iphoneos-arm64-build"
TARBALL="$SRC_DIR/libuv-v${UV_VERSION}.tar.gz"
SOURCE_URL="https://dist.libuv.org/dist/v${UV_VERSION}/libuv-v${UV_VERSION}.tar.gz"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
DOWNLOAD_TMP=""
VERIFY_DIR=""
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"

die() {
    echo "error: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die "missing required SHA-256 command: shasum or sha256sum"
    fi
}

verify_tarball() {
    local path="$1"
    local actual
    actual="$(sha256_file "$path")"
    [[ "$actual" == "$UV_SHA256" ]] || die \
        "SHA-256 mismatch for $path (expected $UV_SHA256, got $actual)"
}

cleanup() {
    [[ -z "$DOWNLOAD_TMP" ]] || rm -f "$DOWNLOAD_TMP"
    [[ -z "$VERIFY_DIR" ]] || rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT

[[ "$UV_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "UV_VERSION must be a numeric release such as 1.51.0"
[[ "$UV_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "UV_SHA256 must be a 64-character lowercase hexadecimal digest"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
[[ "$IOS_DEPLOYMENT_TARGET" =~ ^[0-9]+[.][0-9]+$ ]] || \
    die "IOS_DEPLOYMENT_TARGET must be a major.minor version such as 16.0"

need ar
need awk
need cmake
need curl
need lipo
need tar
need xcodebuild
need xcrun

mkdir -p "$SRC_DIR" "$DEPS_DIR"

if [[ ! -f "$TARBALL" ]]; then
    DOWNLOAD_TMP="${TARBALL}.part.$$"
    curl -fL --retry 3 --retry-delay 2 "$SOURCE_URL" -o "$DOWNLOAD_TMP"
    verify_tarball "$DOWNLOAD_TMP"
    mv "$DOWNLOAD_TMP" "$TARBALL"
    DOWNLOAD_TMP=""
fi
verify_tarball "$TARBALL"

case "$SOURCE_DIR" in
    "$SRC_DIR"/libuv-v"$UV_VERSION") ;;
    *) die "refusing to clear unexpected libuv source directory: $SOURCE_DIR" ;;
esac
case "$BUILD_DIR" in
    "$SRC_DIR"/libuv-v"$UV_VERSION"-iphoneos-arm64-build) ;;
    *) die "refusing to clear unexpected libuv build directory: $BUILD_DIR" ;;
esac
rm -rf "$SOURCE_DIR" "$BUILD_DIR"
tar -xzf "$TARBALL" -C "$SRC_DIR"
[[ -f "$SOURCE_DIR/CMakeLists.txt" ]] || die "libuv source did not extract to $SOURCE_DIR"

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_INSTALL_PREFIX="$DEPS_DIR" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLIBUV_BUILD_SHARED=OFF \
    -DLIBUV_BUILD_TESTS=OFF

cmake --build "$BUILD_DIR" --config Release --target install --parallel "$JOBS"

LIBUV_ARCHIVE="$DEPS_DIR/lib/libuv.a"
VERSION_HEADER="$DEPS_DIR/include/uv/version.h"
IFS=. read -r UV_MAJOR UV_MINOR UV_PATCH <<< "$UV_VERSION"
[[ -f "$LIBUV_ARCHIVE" ]] || die "installed libuv archive not found at $LIBUV_ARCHIVE"
xcrun ranlib -D "$LIBUV_ARCHIVE"
[[ -f "$DEPS_DIR/include/uv.h" ]] || die "installed public header not found at $DEPS_DIR/include/uv.h"
[[ -f "$VERSION_HEADER" ]] || die "installed version header not found at $VERSION_HEADER"
[[ "$(lipo -archs "$LIBUV_ARCHIVE")" == "arm64" ]] || \
    die "installed libuv archive is not arm64-only: $(lipo -archs "$LIBUV_ARCHIVE")"
grep -Eq "^#define UV_VERSION_MAJOR[[:space:]]+$UV_MAJOR$" "$VERSION_HEADER" || die "unexpected libuv major version"
grep -Eq "^#define UV_VERSION_MINOR[[:space:]]+$UV_MINOR$" "$VERSION_HEADER" || die "unexpected libuv minor version"
grep -Eq "^#define UV_VERSION_PATCH[[:space:]]+$UV_PATCH$" "$VERSION_HEADER" || die "unexpected libuv patch version"

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/libuv-minos.XXXXXX")"
(
    cd "$VERIFY_DIR"
    ar -x "$LIBUV_ARCHIVE"
)
VERIFY_OBJECT="$(find "$VERIFY_DIR" -type f -print -quit)"
[[ -n "$VERIFY_OBJECT" ]] || die "installed libuv archive contains no object files"
ACTUAL_MINOS="$(xcrun vtool -show-build "$VERIFY_OBJECT" | awk '/^[[:space:]]+minos / { print $2; exit }')"
[[ "$ACTUAL_MINOS" == "$IOS_DEPLOYMENT_TARGET" ]] || \
    die "libuv minimum iOS mismatch: expected $IOS_DEPLOYMENT_TARGET, got ${ACTUAL_MINOS:-missing}"

echo "UV_VERSION=$UV_VERSION"
echo "UV_SHA256=$UV_SHA256"
echo "OUTPUT=$DEPS_DIR"
echo "IOS_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET"
