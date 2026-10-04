#!/usr/bin/env python3
"""Small repository guard; run a full secret scanner before publishing releases."""
import pathlib, re, subprocess, sys
root=pathlib.Path(__file__).resolve().parents[1]
paths=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).decode().split('\0')
bad=[]
for name in sorted(set(filter(None,paths))):
    p=root/name
    lower=name.lower()
    if lower.endswith(('.p12','.p8','.jks','.keystore','.mobileprovision','.ipa','.apk','.env','.pass')) or 'pairing' in p.name.lower() or p.name=='config.seed.json':
        bad.append(name+': private/release artifact filename'); continue
    if p.is_symlink(): bad.append(name+': unexpected symlink'); continue
    if not p.is_file(): continue
    data=p.read_bytes()
    if re.search(rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----',data):
        bad.append(name+': private key material')
    if re.search(rb'(?:/' + rb'Users/[^/\s"\']+|/' + rb'root/(?:Infrastructure|\.ssh|\.claude|\.codex))/',data):
        bad.append(name+': private machine path')
if bad:
    print('\n'.join(bad)); sys.exit(1)
print('Public source filename/private-key/path checks PASS')
