# XMRAnd for Android

[← Choose a platform](../README.md) · [Download signed APK](https://github.com/darkmaniac7/XMRAnd-Mobile/releases/download/v0.2.0-beta.1/XMRAnd-Android-arm64.apk)

## Install

1. Use an **ARM64 Android 8 or newer** device. Download `XMRAnd-Android-arm64.apk` from this repository's release page.
2. If Android asks, allow your browser/file manager to install this APK. You can turn that permission off afterward.
3. Open XMRAnd. Allow notifications so mining status remains visible.
4. Tap **Setup and how-to** for the full guide.

The APK is signed with XMRAnd Mobile's dedicated Android release certificate. The release includes its SHA-256 certificate fingerprint and file checksums. Source builds and unrelated APKs may use different certificates; export your configuration before changing installation sources. The public app ID is `io.xmrand.mobile`.

## Configure and start

1. Get a public receiving address from your own wallet. **Never enter the wallet's seed phrase or private key.**
2. Copy your pool's exact host, port, account format, password and TLS requirement. Enter the pool as `host:port`.
3. Use `rx/0` for Monero. Start with 1–2 threads and memory mode `auto`; reduce threads or try `light` if memory or heat is a problem.
4. Tap **Start / apply and restart**. Watch the log for pool jobs and accepted shares, and check your pool dashboard. Shares can take time depending on difficulty and hashrate.

Mining runs as a foreground service with a notification. If Android stops the app, use its **Battery optimization settings** button and choose unrestricted battery use. Automatic start is optional and means opening the app, not boot-time mining.

## Power and controls

- **Save:** persist settings. **Start / apply:** restart with the saved settings. **Stop:** cancel mining and any pending start.
- **Charging-only:** wait until external power is connected.
- **Wait for idle:** additionally wait for screen-off or external power.
- **Battery:** pause at/below your threshold, resume at/above the higher threshold.
- **Temperature:** pause at the limit and resume after cooling by 3°C.

[Advanced configuration and import/export](CONFIGURATION.md) · [Build your own APK](BUILDING.md#android)

## Troubleshooting

**No accepted shares:** check pool account format, algorithm, port/TLS, jobs and rejection messages. Hashrate alone does not prove successful mining.

**App stops or gets hot:** lower threads, allow unrestricted battery use if desired, try light memory mode, and let the device cool. Stop if it becomes uncomfortable to touch.

**Cannot install:** confirm ARM64, Android 8+, sufficient free storage and that the APK came from this repository. Do not disable device security globally. Signature mismatch means the existing app came from a different signing key.
