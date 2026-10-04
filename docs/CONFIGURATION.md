# Configuration

Use the form for common settings, or **Advanced JSON** for additional engine options. The saved JSON is authoritative. **Save** persists it; Android **Start / apply** restarts with it, while iOS requires **Stop**, then **Start**.

| Setting | Meaning |
|---|---|
| Pool | `host:port`, or bracketed IPv6 `[address]:port`; no wallet embedded in the URL |
| Wallet / account | Public receiving address or the exact account format your pool requires |
| Password / worker / TLS | Follow your pool's documentation; TLS must match its port |
| Backup pools | Tried in order on failure; new backups inherit primary credentials |
| Algorithm | `rx/0` for Monero; other values must be compiled into the engine |
| Threads | `0` uses automatic engine configuration; a number sets that algorithm's profile; `custom` preserves advanced profiles |
| Priority | `0`–`5`, or `auto` for engine default; the OS may limit its effect |
| RandomX memory | `auto`, `fast` (~2 GB plus overhead), or `light` (less memory, much slower) |
| Donation | XMRig developer donation, minimum 1% in these builds |
| Charging / battery | Wait for power if selected; pause at/below threshold, resume at/above the higher threshold |
| Temperature | Android battery-temperature threshold with 3°C hysteresis; iOS uses system thermal state |
| Autostart | Optional start when the app opens; off initially |
| iOS interpreter | Explicit opt-in to slow mining when JIT is unavailable; off initially |

Advanced JSON preserves unknown engine options. Independent backup logins, per-pool enable flags and custom CPU profiles are editable there. Wrapper preferences are under `xmrand`. JSON cannot enable compiled-out features; public iOS disables HTTP control, GPU mining, MSR and huge pages. Desktop-specific options may not work on phones.

Import accepts one JSON object up to 256 KB, confirms replacement and disables autostart. Review the wallet and pools before starting. Export contains pool passwords and any advanced API tokens: keep it private. Never enter a wallet seed phrase or private spend key.

The runtime removes wrapper preferences, disables engine autosave/background mode and controls logging paths. The saved profile remains available for editing and export.
