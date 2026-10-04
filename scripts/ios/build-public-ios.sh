#!/usr/bin/env bash
# No account, provisioning, keychain or signing operations.
set -euo pipefail
if [[ $# != 4 || ${1:-} == --help ]]; then
    echo 'Usage: build-public-ios.sh DEPS_PREFIX NEW_BUILD_DIR OUTPUT_DIR PERSONAL_BUNDLE_ID' >&2
    echo 'Requires macOS, Xcode, cmake, libuv/OpenSSL iPhoneOS dependencies. Produces an unsigned IPA.' >&2
    exit 2
fi
[[ $(uname -s) == Darwin ]] || { echo 'Run on macOS.' >&2; exit 2; }
repo=$(cd "$(dirname "$0")/../.." && pwd)
deps=$1; build=$2; output=$3; bundle=$4
[[ "$bundle" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$ ]] || { echo 'Use your own reverse-DNS bundle ID.' >&2; exit 2; }
[[ ! -e "$build" ]] || { echo 'Choose a new build directory to avoid stale signing inputs.' >&2; exit 2; }
for input in include/uv.h include/openssl/ssl.h lib/libuv.a lib/libssl.a lib/libcrypto.a; do
    [[ -f "$deps/$input" ]] || { echo "Missing dependency: $input" >&2; exit 2; }
done
mkdir -p "$build" "$output"
build=$(cd "$build" && pwd); output=$(cd "$output" && pwd)
cmake -S "$repo" -B "$build" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DOPENSSL_INCLUDE_DIR="$deps/include" -DOPENSSL_SSL_LIBRARY="$deps/lib/libssl.a" \
    -DOPENSSL_CRYPTO_LIBRARY="$deps/lib/libcrypto.a" -DUV_INCLUDE_DIR="$deps/include" -DUV_LIBRARY="$deps/lib/libuv.a" \
    -DXMRAND_IOS_BUNDLE_ID="$bundle" -DXMRAND_IOS_CALLBACK_SCHEME=xmrand \
    -DXMRAND_IOS_HELPER_SCHEME=xmrand-stikdebug -DXMRAND_IOS_SEED_CONFIG= \
    -DWITH_IOS_APP=ON -DWITH_IOS_JIT=ON -DWITH_IOS_TROLLSTORE_JIT=OFF \
    -DWITH_TLS=ON -DWITH_HTTP=OFF -DWITH_HWLOC=OFF -DWITH_DMI=OFF -DWITH_MSR=OFF \
    -DWITH_OPENCL=OFF -DWITH_CUDA=OFF -DWITH_ADL=OFF -DWITH_NVML=OFF \
    -DWITH_CN_LITE=OFF -DWITH_CN_HEAVY=OFF -DWITH_CN_PICO=OFF -DWITH_CN_FEMTO=OFF \
    -DWITH_KAWPOW=OFF -DWITH_GHOSTRIDER=OFF
cmake --build "$build" --parallel "${JOBS:-8}"
app="$build/xmrig.app"
[[ -x "$app/xmrig" && -f "$app/public-setup.html" ]] || { echo 'App or guide missing.' >&2; exit 1; }
python3 "$repo/scripts/ios/check-public-bundle.py" "$app"
mkdir "$build/Payload"
cp -R "$app" "$build/Payload/"
(cd "$build" && /usr/bin/zip -qry "$output/XMRAnd-unsigned.ipa" Payload)
echo "Unsigned IPA: $output/XMRAnd-unsigned.ipa"
echo 'Not installable until development-signed by the recipient. See the embedded public setup guide.'
