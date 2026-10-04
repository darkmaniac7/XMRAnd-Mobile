#!/usr/bin/env bash
set -euo pipefail
[[ $(uname -s) == Darwin && $# == 1 ]] || { echo 'Usage on macOS: test-public-settings.sh NEW_OUTPUT_DIR' >&2; exit 2; }
repo=$(cd "$(dirname "$0")/../.." && pwd); out=$1
[[ ! -e "$out" ]] || { echo 'Choose a new output directory.' >&2; exit 2; }
mkdir -p "$out"; out=$(cd "$out" && pwd)
xcrun --sdk macosx clang++ -fobjc-arc -std=c++17 -framework Foundation \
    "$repo/ios-app/MinerConfiguration.mm" "$repo/ios-app/tests/ConfigurationTests.mm" -o "$out/config-tests"
"$out/config-tests" | tee "$out/config-results.txt"
app="$out/SettingsTests.app"; mkdir "$app"
xcrun --sdk iphonesimulator clang++ -fobjc-arc -std=c++17 -target arm64-apple-ios16.0-simulator \
    -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -framework Foundation -framework UIKit -framework WebKit -framework UniformTypeIdentifiers \
    "$repo/ios-app/MinerConfiguration.mm" "$repo/ios-app/MinerSettingsViewController.mm" \
    "$repo/ios-app/tests/SettingsHarness.mm" -o "$app/SettingsTests"
cp "$repo/docs/public-assets/public-setup.html" "$app/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.xmrand.settingstests</string>
<key>CFBundleExecutable</key><string>SettingsTests</string>
<key>CFBundleName</key><string>SettingsTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
# Ad-hoc simulator signature has no Apple identity/profile or developer account.
codesign --force --sign - "$app"
device=$(xcrun simctl create XMRAndSettingsTests com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max)
printf '%s\n' "$device" > "$out/simulator-id.txt"
cleanup() { xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b > "$out/simulator-boot.log"
xcrun simctl install "$device" "$app"
xcrun simctl launch "$device" org.xmrand.settingstests
container=$(xcrun simctl get_app_container "$device" org.xmrand.settingstests data)
for ((n=0; n<60; n++)); do
    if [[ -f "$container/Documents/test-result.txt" ]]; then
        cp "$container/Documents/test-result.txt" "$out/ui-results.txt"
        cat "$out/ui-results.txt"
        grep -q '^PASS' "$out/ui-results.txt"
        exit $?
    fi
    sleep 1
done
echo 'Simulator tests did not produce results.' >&2; exit 1
