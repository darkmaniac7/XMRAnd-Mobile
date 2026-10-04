# Build from source

Use the source tag matching the release. Keep signing credentials outside the checkout. Build scripts do not access an Apple account or supply a mining wallet.

## Android

Use Linux, Java 17+, Android SDK platform 35/build-tools 35.0.0, NDK **27.2.12479018**, CMake, Ninja, curl, Perl, Make and a C/C++ toolchain. Install those SDK packages using Android Studio or `sdkmanager`.

```sh
export ANDROID_HOME="$HOME/Android/Sdk"   # your SDK
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"
export JOBS=4
bash scripts/android/build-public-android.sh
cd android-app
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease --max-workers=4
```

The native build downloads checksum-verified libuv 1.51.0 and OpenSSL 3.0.16, enables TLS and stages `libxmrig.so`. APK packaging refuses to proceed if that binary is missing. Native binaries/build caches are not tracked in Git.

Outputs:

- `android-app/app/build/outputs/apk/debug/app-debug.apk` — development build, debug-signed locally.
- `android-app/app/build/outputs/apk/release/app-release-unsigned.apk` — unsigned release; sign with your own Android release key using Android SDK `zipalign` and `apksigner`. Never share the private key/password. The downloadable public APK uses the project's dedicated key.

For an isolated device configuration/service test, build with `-PxmrandTestApplicationId=io.xmrand.settingsqa` and tasks `:app:assembleDebug :app:assembleDebugAndroidTest`, install both test APKs, then run:

```sh
adb -s YOUR_DEVICE shell am instrument -w \
  io.xmrand.settingsqa.test/io.xmrand.wrapper.ConfigDeviceTest
```

This runner refuses the production app ID, uses placeholder credentials and an engine dry run, and stops its service afterward. It does not mine or test live pool shares. Remove only its two disposable test packages when finished.

## iOS

Use macOS with Xcode, command-line tools and CMake. Dependency builds need curl, Perl and Make. Simulator UI tests require an installed iOS runtime with the iPhone 17 Pro Max device type; model tests use Foundation.

```sh
export XMRAND_DEPS_DIR="$HOME/xmrand-deps/iphoneos"
export XMRAND_DEPS_SOURCE_DIR="$HOME/xmrand-dependency-sources"
export JOBS=4
bash scripts/ios/build-libuv-arm64.sh
bash scripts/ios/build-openssl-arm64.sh
bash scripts/ios/build-public-ios.sh \
  "$XMRAND_DEPS_DIR" "$HOME/xmrand-build" "$HOME/xmrand-output" \
  org.example.personal.xmrand
```

Replace the bundle ID with your own and use a new build directory. Output: `XMRAnd-unsigned.ipa`. It contains no provisioning profile, seed configuration or personal pairing file. Follow [personal signing and pairing](IOS.md) before installation.

```sh
bash scripts/ios/test-battery-hysteresis.sh
bash scripts/ios/test-public-settings.sh /path/to/new/test-output
```

The latter compiles/runs Foundation checks and the actual settings controller in a dedicated simulator with mock mining callbacks. Simulator signing is ad hoc and uses no Apple development identity. Tests do not establish physical-device JIT or signing success.

## Source and dependencies

The release includes this repository's matching source and the pristine libuv/OpenSSL source archives used by the dependency builders. `LICENSE` and `NOTICE` describe upstream licensing. Helper sources are fetched at pinned upstream commits by `prepare-public-helpers.py`; they are not embedded in the miner IPA and retain their own licenses.
