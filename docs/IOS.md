# XMRAnd for iPhone and iPad

[← Choose a platform](../README.md) · [Download unsigned IPA](https://github.com/darkmaniac7/XMRAnd-Mobile/releases/download/v0.2.0-beta.1/XMRAnd-iOS-unsigned.ipa)

**This is the advanced installation route.** The IPA is unsigned, requires your own development signing, and needs a working StikDebug/LocalDevVPN JIT setup. It is not an App Store/TestFlight app. Physical-device JIT has not yet been qualified for this public build.

## Before you begin

- Miner: iOS/iPadOS 16+. The pinned helper workflow requires **17.4+**.
- Your own Mac with Xcode, an unlocked device, USB cable and Developer Mode.
- Your own Apple account/certificate/profile capable of the helper VPN entitlements. Free accounts may not provide those capabilities. Check current Apple/upstream requirements before purchasing anything.
- Never use a publisher's account, certificate, profile or device-pairing file. No shared signing service is supplied.

## 1. Choose matching app identifiers

The downloadable IPA uses `org.xmrand.mobile` as a placeholder. Choose your own unique reverse-DNS identifier, such as `org.example.personal.xmrand`. You can change the unsigned app's identifier before signing using the commands below; rebuilding is not required. Your development profile and prepared helpers must match the **installed** bundle ID exactly. [Building from source](BUILDING.md#ios) is also supported.

Prepare the matching helper sources from this repository:

```sh
python3 scripts/ios/prepare-public-helpers.py \
  --app-id org.example.personal.xmrand \
  --prefix org.example.personal \
  --output "$HOME/xmrand-helpers"
```

Replace the example prefix with your own, and `--app-id` with your actual miner ID. The preparer downloads pinned helper sources and personalizes IDs, app groups and URL schemes. It does not access Apple accounts or keys.

## 2. Sign and install using your own Mac

1. Open Xcode → Settings → Accounts and add **your own** account.
2. Enable Developer Mode on your device under Settings → Privacy & Security. Restart and confirm when prompted.
3. Open the prepared `StikDebug.xcodeproj` and `LocalDevVPN.xcodeproj`. Choose your team in each target's **Signing & Capabilities**. Register the generated StikDebug App Group under your team; preserve the helper capabilities.
4. LocalDevVPN's app and tunnel extension need `packet-tunnel-provider`; its app also needs `allow-vpn`. If your account cannot provision them, stop and consult official helper support. A generic IPA signer may drop these capabilities.
5. Build/install the helpers with your own development signing. The matching copies use `xmrand-stikdebug` and `xmrand-localdevvpn` URL schemes; keep only one matching copy of each.
6. Create an **iOS App Development** profile for your miner ID and device, using your Apple Development certificate. Confirm `get-task-allow=true` and that the application identifier matches. Distribution signing generally removes debugger access.

For manual miner signing on **your own Mac**, unzip the IPA into a new directory and use your matching profile and existing development identity:

```sh
mkdir "$HOME/xmrand-signing"
unzip XMRAnd-iOS-unsigned.ipa -d "$HOME/xmrand-signing"
APP="$HOME/xmrand-signing/Payload/xmrig.app"
BUNDLE_ID="org.example.personal.xmrand" # replace with your own ID
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $BUNDLE_ID" "$APP/Info.plist"
PROFILE="/private/path/YOUR_DEVELOPMENT_PROFILE.mobileprovision"

security cms -D -i "$PROFILE" -o "$HOME/xmrand-signing/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' \
  "$HOME/xmrand-signing/profile.plist" > "$HOME/xmrand-signing/entitlements.plist"
# Inspect team, application-identifier, device list and get-task-allow first.
cp "$PROFILE" "$APP/embedded.mobileprovision"
codesign --force --sign 'Apple Development: YOUR NAME (YOUR ID)' \
  --entitlements "$HOME/xmrand-signing/entitlements.plist" \
  --timestamp=none "$APP"
codesign --verify --strict --deep "$APP"
```

Install the signed `.app` using Xcode → Window → Devices and Simulators. Trust your own developer profile in Settings → General → VPN & Device Management if requested. Keep the signing directory private and remove temporary profile copies afterward. Renew with your own account before the profile expires.

## 3. Create your private pairing record

1. Connect your unlocked device to **your Mac** by USB and accept Trust This Computer.
2. Install compatible upstream [idevice tools](https://github.com/jkcoxson/idevice), or build the pinned version with `bash scripts/ios/build-idevice-tools.sh`. The latter requires Rust/Cargo and prints its output path.
3. Find the UDID in Xcode's Devices window, then run:

```sh
umask 077
idevice-tools --udid YOUR_DEVICE_UDID rppairing pair \
  YOUR_COMPUTER_NAME /private/path/pairing.plist
```

Use the full printed path to `idevice-tools` if it is not on your PATH. Keep the device unlocked and accept new Trust prompts. Check the tool's `--help` if your installed version differs.

4. Transfer the record privately to that device and import it in matching StikDebug. **A pairing file is a credential. Never post it to Discord/GitHub, upload it to a pairing website, or share it.**
5. Open matching LocalDevVPN once and approve its local VPN configuration. Complete StikDebug's first-run setup; disable conflicting VPNs if its local tunnel fails.

## 4. Start JIT mining

1. Open XMRAnd and enter your own pool and public wallet/account, matching password and TLS settings. Use `rx/0` for Monero and start with 1–2 threads.
2. Save and Start. XMRAnd opens matching StikDebug → LocalDevVPN → returns to the miner.
3. Confirm **Mining with JIT**, then verify pool jobs and accepted shares. On iOS 26, ordinary debugger attachment alone does not satisfy this app's JIT path.
4. Keep XMRAnd **visible, foregrounded and unlocked**. It keeps the display awake while actively mining. Switching apps, system overlays or locking pauses mining; iOS can suspend or terminate it.

Slow interpreter fallback is **off by default** and requires an explicit choice. There is no supported promise of continuous background/locked-screen iOS mining.

## Troubleshooting

**JIT unavailable:** check matching IDs, Developer Mode, development profile/get-task-allow, expiry, helper approvals, local VPN and current pairing. Return to XMRAnd, Stop and Start again. Reboots, OS updates or trust resets may require setup again.

**App closes or gets hot:** reduce threads, let it cool and try light memory mode. Fast RandomX needs roughly 2 GB plus overhead; iOS can terminate it under memory pressure.

**No shares:** check the pool's account format, port/TLS, algorithm and log. Shares depend on difficulty and hashrate; use a suitable pool.

[Configuration](CONFIGURATION.md) · [Build instructions](BUILDING.md) · [Validation limits](VALIDATION.md)
