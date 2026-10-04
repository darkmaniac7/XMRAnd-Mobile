#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
[[ $(uname -s) == Linux ]] || { echo 'Use Linux (or WSL) for the Android native build.' >&2; exit 2; }
export XMRAND_WITH_TLS=ON XMRAND_WITH_HTTP=OFF
export JOBS=${JOBS:-4}
export XMRAND_BUILD_DIR=${XMRAND_BUILD_DIR:-$repo/build/android-public}
# Keep machine-specific source paths out of distributed binaries.
export XMRAND_EXTRA_C_FLAGS="-ffile-prefix-map=$repo=/build/xmrand-mobile"
export XMRAND_EXTRA_CXX_FLAGS="$XMRAND_EXTRA_C_FLAGS"
bash "$repo/scripts/android/build-xmrig-arm64.sh"
mkdir -p "$repo/android-app/app/src/main/jniLibs/arm64-v8a"
cp "$XMRAND_BUILD_DIR/xmrig" "$repo/android-app/app/src/main/jniLibs/arm64-v8a/libxmrig.so"
echo 'Native miner staged. Build the APK with the Gradle commands in docs/BUILDING.md.'
