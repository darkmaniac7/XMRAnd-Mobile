#!/usr/bin/env python3
"""Prepare pinned, personally identified helper sources. Never reads signing inputs."""
import argparse, pathlib, re, subprocess
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app-id', required=True, help='The exact personal XMRAnd bundle ID')
p.add_argument('--prefix', required=True, help='Personal reverse DNS prefix for helper IDs')
p.add_argument('--output', required=True, type=pathlib.Path, help='New local directory')
a = p.parse_args()
for value in (a.app_id, a.prefix):
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+', value):
        p.error('Identifiers must be reverse DNS using letters, numbers, dots and hyphens.')
if a.output.exists(): p.error('Choose a new directory; existing sources are never overwritten.')
a.output.mkdir(parents=True)
root = pathlib.Path(__file__).resolve().parents[2]
for name, url, commit in (
    ('StikDebug', 'https://github.com/StephenDev0/StikDebug.git', '7f2808bfb5be63aee2af9e1542b5baef6e591661'),
    ('LocalDevVPN', 'https://github.com/jkcoxson/LocalDevVPN.git', 'c4566ce08931cef414c9f656e7e33c66bdb2454e')):
    dest = a.output / name
    subprocess.run(['git', 'clone', '--quiet', url, str(dest)], check=True)
    subprocess.run(['git', '-C', str(dest), 'checkout', '--quiet', '--detach', commit], check=True)
    if name == 'StikDebug':
        subprocess.run(['git', '-C', str(dest), 'apply', str(root/'scripts/ios/patches/stikdebug-3.1.6-xmrand.patch')], check=True)
    for f in dest.rglob('*'):
        if '.git' in f.parts or f.suffix not in ('.swift', '.plist', '.pbxproj', '.entitlements'): continue
        s = f.read_text()
        s = s.replace('org.xmrand.mobile', a.app_id).replace('org.xmrand.stikdebug', a.prefix+'.stikdebug')
        # Personal helper schemes avoid taking over upstream helper installations.
        s = s.replace('stikdebug://', 'xmrand-stikdebug://')
        s = s.replace('group.com.stik.stikdebug', 'group.'+a.prefix+'.stikdebug').replace('group.com.stik.sj', 'group.'+a.prefix+'.stikdebug')
        s = s.replace('localdevvpn://', 'xmrand-localdevvpn://').replace('scheme=stikdebug', 'scheme=xmrand-stikdebug')
        s = s.replace('"stikdebug"', '"xmrand-stikdebug"').replace('<string>stikdebug</string>', '<string>xmrand-stikdebug</string>')
        s = s.replace('"localdevvpn"', '"xmrand-localdevvpn"').replace('<string>localdevvpn</string>', '<string>xmrand-localdevvpn</string>')
        if f.suffix == '.pbxproj':
            s = re.sub(r'DEVELOPMENT_TEAM = [^;]*;', 'DEVELOPMENT_TEAM = "";', s)
            if name == 'StikDebug':
                s = s.replace('com.stik.stikdebug', a.prefix+'.stikdebug')
            else:
                s = s.replace('com.jkcoxson.LocalDevVPN', a.prefix+'.localdevvpn')
        f.write_text(s)
print('Prepared sources:', a.output)
print('Target XMRAnd:', a.app_id)
print('Helper IDs:', a.prefix+'.stikdebug', a.prefix+'.localdevvpn', a.prefix+'.localdevvpn.TunnelProv')
print('No Apple account or signing operations were performed. Open the projects on your own Mac to configure your own team.')
