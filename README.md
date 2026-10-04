# XMRAnd Mobile

**Monero / RandomX CPU mining for Android, iPhone and iPad.**

XMRAnd adds mobile controls to the [XMRig](https://github.com/xmrig/xmrig) engine: your own wallet and pools, backup pools, CPU/memory tuning, battery controls and JSON import/export. New installations contain no mining account and do not start automatically.

| | Android | iPhone / iPad |
|---|---|---|
| Get the app | [Signed Android APK](https://github.com/darkmaniac7/XMRAnd-Mobile/releases/download/v0.2.0-beta.1/XMRAnd-Android-arm64.apk) | [Unsigned iOS IPA](https://github.com/darkmaniac7/XMRAnd-Mobile/releases/download/v0.2.0-beta.1/XMRAnd-iOS-unsigned.ipa) |
| Setup | **[Android installation and mining →](docs/ANDROID.md)** | **[Personal signing, pairing and JIT →](docs/IOS.md)** |
| Requirements | Android 8+, ARM64 | Miner: iOS 16+; helper workflow: iOS 17.4+, Mac/Xcode and suitable personal development signing |
| Operation | User-started foreground service | App visible and device unlocked; JIT helper setup required |
| Source | [`android-app/`](android-app/) | [`ios-app/`](ios-app/) |

**Beta release:** Android has configuration, service and native-engine smoke coverage. iOS builds and settings are tested without a developer account; personal signing and physical-device JIT still need validation for this public build. The iOS download is not ready to install until you sign it yourself. There is no App Store or TestFlight version.

## Start here

1. Choose your platform above and follow its setup instructions.
2. Enter **your** pool host/port, public wallet address or pool account, password and TLS setting. Never enter a wallet seed phrase or private key.
3. Start with 1–2 CPU threads. Save and Start; check for jobs and **accepted shares**.
4. Watch temperature and power use. On iOS, keep XMRAnd foregrounded and unlocked.

The built-in **Setup and how-to** contains the same instructions, including troubleshooting and configuration privacy. Mining profitability, payout thresholds and pool account requirements depend on your pool and hardware.

## What is editable?

Wallet/account, pool address, password, worker name, TLS, backups, algorithm, threads, priority, RandomX memory mode, donation, charging-only, battery pause/resume and automatic start. Android also exposes a battery-temperature threshold; iOS uses system thermal state. Advanced JSON supports additional options compiled into the engine and independent backup credentials. Import disables automatic start.

- [Build from source](docs/BUILDING.md)
- [Configuration reference](docs/CONFIGURATION.md)
- [Release validation and limitations](docs/VALIDATION.md)
- [Release files, checksums and corresponding source](https://github.com/darkmaniac7/XMRAnd-Mobile/releases)
- [Report a bug](https://github.com/darkmaniac7/XMRAnd-Mobile/issues/new/choose)

## Privacy and signing

No publisher Apple account, signing certificate, provisioning profile, wallet or pairing file is provided. iOS users sign and pair locally with their own accounts and devices. Never upload pairing records, signing keys or private configuration to an issue or chat. Android uses a project-specific release certificate; its public fingerprint accompanies the release.

This repository contains both platforms and the shared engine. You do not need a second iOS repository. Public Android uses package `io.xmrand.mobile`.

## License and credits

XMRAnd Mobile is based on XMRig and distributed under **GPL-3.0-or-later**. Preserve [LICENSE](LICENSE), upstream copyright notices and required corresponding source when redistributing. See [NOTICE](NOTICE) for dependencies and helper licenses. XMRig's default developer donation is 1%; this is separate from your pool fees.
