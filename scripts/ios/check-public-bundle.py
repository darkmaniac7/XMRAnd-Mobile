#!/usr/bin/env python3
"""Reject private inputs in an unsigned public app; this is not a full secret scanner."""
import pathlib, sys
root = pathlib.Path(sys.argv[1])
bad = []
for p in root.rglob('*'):
    name = p.name.lower()
    if p.is_file() and (name.endswith(('.p12', '.p8', '.mobileprovision', '.pem', '.key'))
                       or 'pairing' in name or name == 'config.seed.json' or name == 'idevice_log.txt'):
        bad.append(str(p.relative_to(root)))
if bad:
    raise SystemExit('Private build inputs detected: ' + ', '.join(bad))
print('Public bundle input check PASS')
