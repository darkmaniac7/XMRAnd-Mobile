#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.16}"
OPENSSL_SHA256="${OPENSSL_SHA256:-57e03c50feab5d31b152af2b764f10379aecd8ee92f16c985983ce4a99f7ef86}"
DEPS_DIR="${XMRAND_DEPS_DIR:-$ROOT_DIR/../deps/iphoneos}"
SRC_DIR="${XMRAND_DEPS_SOURCE_DIR:-$ROOT_DIR/build/deps-src}"
SOURCE_DIR="$SRC_DIR/openssl-${OPENSSL_VERSION}"
BUILD_DIR="$SRC_DIR/openssl-${OPENSSL_VERSION}-iphoneos-arm64-build"
TARBALL="$SRC_DIR/openssl-${OPENSSL_VERSION}.tar.gz"
SOURCE_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
DOWNLOAD_TMP=""

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
    local actual
    actual="$(sha256_file "$1")"
    [[ "$actual" == "$OPENSSL_SHA256" ]] || \
        die "SHA-256 mismatch for $1 (expected $OPENSSL_SHA256, got $actual)"
}

cleanup() {
    [[ -z "$DOWNLOAD_TMP" ]] || rm -f "$DOWNLOAD_TMP"
}
trap cleanup EXIT

[[ "$OPENSSL_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || \
    die "OPENSSL_VERSION must be a numeric release such as 3.0.16"
[[ "$OPENSSL_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
    die "OPENSSL_SHA256 must be a lowercase 64-character digest"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"

need awk
need curl
need make
need perl
need tar
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
    "$SRC_DIR"/openssl-"$OPENSSL_VERSION") ;;
    *) die "refusing to clear unexpected OpenSSL source directory: $SOURCE_DIR" ;;
esac
case "$BUILD_DIR" in
    "$SRC_DIR"/openssl-"$OPENSSL_VERSION"-iphoneos-arm64-build) ;;
    *) die "refusing to clear unexpected OpenSSL build directory: $BUILD_DIR" ;;
esac
rm -rf "$SOURCE_DIR" "$BUILD_DIR"
tar -xzf "$TARBALL" -C "$SRC_DIR"
[[ -f "$SOURCE_DIR/Configure" ]] || die "OpenSSL source did not extract to $SOURCE_DIR"
cp -a "$SOURCE_DIR" "$BUILD_DIR"

(
    cd "$BUILD_DIR"
    CROSS_TOP="$(xcrun --sdk iphoneos --show-sdk-platform-path)/Developer"
    SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
    CROSS_SDK="$(basename "$SDKROOT")"
    export CROSS_TOP CROSS_SDK SDKROOT

    ./Configure ios64-xcrun \
        --prefix="$DEPS_DIR" \
        --openssldir="$DEPS_DIR/ssl" \
        no-shared \
        no-tests \
        no-ui-console \
        no-dso \
        no-comp \
        no-legacy \
        no-async

    make -j"$JOBS"
    make install_sw
)

echo "OPENSSL_VERSION=$OPENSSL_VERSION"
echo "OPENSSL_SHA256=$OPENSSL_SHA256"
echo "OUTPUT=$DEPS_DIR"
