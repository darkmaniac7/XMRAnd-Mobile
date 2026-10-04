# Changelog

## 0.2.0-beta.1

First public Android/iOS source and download release.

- Editable wallets/accounts, pools, backup pools, worker/TLS, CPU/memory and power controls.
- Persistent authoritative configuration with advanced JSON import/export.
- No seeded wallet or automatic mining on fresh install; explicit iOS interpreter opt-in.
- Separate platform setup guides, personal iOS signing/pairing instructions and foreground requirements.
- Signed Android APK under package `io.xmrand.mobile`; unsigned iOS IPA under `org.xmrand.mobile`.
- Public source/dependency builds, configuration tests and source-check CI.

The public iOS build is not yet qualified for physical-device signing/JIT. See `docs/VALIDATION.md` for the tested scope. No App Store/TestFlight distribution is provided.
