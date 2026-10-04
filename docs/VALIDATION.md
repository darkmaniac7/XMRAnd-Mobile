# Validation for 0.2.0-beta.1

This is a beta release. The October 4 standalone refresh removes app-detection integration and its associated tests/permissions. Android version code is 5; existing installations can update using the same release key. Download checksums changed. Test scope is explicit so a successful build is not mistaken for device JIT qualification.

| Check | Result |
|---|---|
| Android native engine | Built from this source with NDK 27.2.12479018, libuv 1.51.0 and OpenSSL 3.0.16; TLS enabled |
| Android unit tests | 28 passed, zero failures/errors/skips |
| Android physical ARM64 test | Persistence, rejected invalid saves, embedded guide, native engine `--dry-run`, service status/stop lifecycle passed under a disposable test app ID |
| Android release | Release packaging and required lint passed; dedicated Android signing and verification performed for the download |
| iOS miner | Full ARM64 iPhoneOS Release build with TLS/JIT, unsigned; refresh changes only the bundled guide, verified byte-for-byte unchanged executable |
| iOS configuration | 32 Foundation checks passed |
| iOS UI | 15 checks passed using the actual settings controller and mock engine callbacks in an iOS 26.5 simulator |
| Battery policy | Android tests and C++ iOS hysteresis boundary checks passed |
| Helper integration patch | Applies to the pinned StikDebug upstream source; the underlying helper integration previously passed unsigned helper builds |
| Source hygiene | Clean initial Git history; allowlisted source export; secret scan and private-input checks performed before publication |

## Not yet qualified

- Personal Apple development signing, pairing, physical-device JIT and accepted shares for this **public iOS build**.
- Continuous or long-duration mining, thermal/battery endurance and every OS/device/pool combination.
- A live-pool accepted-share run for the freshly rebuilt public Android native binary. The device smoke test used `--dry-run`, which does not connect or mine.
- Manual import/export through every Android document provider and iOS share destination.

No Apple developer account, development certificate, provisioning profile or device-pairing record was used for these builds/tests. Simulator signing was ad hoc. The Android release key is separate and is never included in this repository or release assets.

Do not treat the unsigned IPA as directly installable or assume a generic signing service preserves the capabilities needed for JIT. Follow the [iOS guide](IOS.md) with your own account.
