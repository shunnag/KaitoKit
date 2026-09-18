#!/usr/bin/env python3
"""Project-owned inputs, encoded and independently extracted by the 7-Zip CLI."""
import base64
import hashlib
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent
payloads = {
    'first.bin': bytes(range(256)) * 1025 + bytes([17, 31, 127]),
    'second.bin': bytes((i * 73 + 41) & 255 for i in range(1027)),
    'empty': b'',
}
manifest = {'tool': '7-Zip 26.03 (arm64)', 'password': 'KaitoFixture',
            'source': 'https://github.com/ip7z/7zip/blob/main/DOC/Methods.txt',
            'entries': {name: {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                        for name, data in payloads.items()}, 'fixtures': []}
with tempfile.TemporaryDirectory(prefix='kaito-swap-fixtures-') as temporary:
    work = pathlib.Path(temporary)
    for name, data in payloads.items():
        (work / name).write_bytes(data)
    for width in (2, 4):
        for encrypted in (False, True):
            name = f'swap{width}-' + ('aes' if encrypted else 'plain') + '.7z'
            archive = work / name
            options = [f'-m0=Swap{width}', '-m1=LZMA2', '-ms=on', '-mhc=off']
            if encrypted:
                options += ['-pKaitoFixture', '-mhe=on']
            args = ['a', '-bd', '-y', '-t7z', *options, str(archive), *payloads]
            subprocess.run(['/opt/homebrew/bin/7zz', *args], cwd=work, check=True, stdout=subprocess.DEVNULL)
            listing = subprocess.run(['/opt/homebrew/bin/7zz', 'l', '-slt', '-pKaitoFixture', str(archive)],
                                     check=True, capture_output=True, text=True).stdout
            assert f'Swap{width}' in listing and 'Solid = +' in listing
            for entry, expected in payloads.items():
                decoded = subprocess.run(['/opt/homebrew/bin/7zz', 'x', '-so', '-bd', '-y', '-pKaitoFixture',
                                          str(archive), entry], check=True, capture_output=True).stdout
                assert decoded == expected
            data = archive.read_bytes()
            (root / (name + '.b64')).write_bytes(base64.encodebytes(data))
            manifest['fixtures'].append({'file': name + '.b64', 'sha256': hashlib.sha256(data).hexdigest(),
                                         'method': f'Swap{width}', 'encrypted': encrypted, 'arguments': args[0:-4] + ['ARCHIVE', *payloads]})
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
