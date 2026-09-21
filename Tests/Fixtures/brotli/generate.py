#!/usr/bin/env python3
"""Project-owned brotli fixtures written by the brotli CLI (Google, MIT) and decoded back with it.

The stream format is RFC 7932 (plus the RFC 9841 large-window header for `large-window.br`).
KaitoKit decodes brotli with Apple Compression; the CLI is the independent writer / reader oracle.
"""
import base64
import hashlib
import io
import json
import pathlib
import random
import subprocess
import tarfile

BROTLI = '/opt/homebrew/bin/brotli'

root = pathlib.Path(__file__).resolve().parent
rng = random.Random(7932)

text = ''.join(rng.choice('abcdefghijklmnop \n') for _ in range(24_000)).encode()
binary = bytes((i * 73 + 41) & 255 for i in range(20_000)) + bytes(range(256)) * 8
random_bytes = bytes(rng.getrandbits(8) for _ in range(8_192))

cases = {
    'text-q1.br': (text, ['-q', '1']),
    'text-q11.br': (text, ['-q', '11']),
    'binary-q5.br': (binary, ['-q', '5']),
    'random-q5.br': (random_bytes, ['-q', '5']),
    'window-10.br': (text, ['-q', '9', '-w', '10']),
    'window-16.br': (text, ['-q', '9', '-w', '16']),
    'window-17.br': (text, ['-q', '9', '-w', '17']),
    'large-window.br': (text, ['-q', '9', '--large_window=30']),
    'empty.br': (b'', []),
    'one.br': (b'\x2a', []),
}

buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode='w', format=tarfile.USTAR_FORMAT) as tar:
    for name, data in (('a.txt', text[:5_000]), ('b.bin', binary[:3_000])):
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mtime = 1_600_000_000
        tar.addfile(info, io.BytesIO(data))
cases['bundle.tar.br'] = (buffer.getvalue(), ['-q', '5'])

version = subprocess.run([BROTLI, '--version'], check=True, capture_output=True, text=True).stdout.strip()
manifest = {'writer': version, 'reader': version + ' (-d)', 'fixtures': []}
for name, (data, options) in cases.items():
    blob = subprocess.run([BROTLI, '-c', *options], input=data, check=True, capture_output=True).stdout
    decoded = subprocess.run([BROTLI, '-d', '-c'], input=blob, check=True, capture_output=True).stdout
    assert decoded == data, name
    (root / (name + '.b64')).write_bytes(base64.encodebytes(blob))
    manifest['fixtures'].append({
        'file': name + '.b64', 'size': len(blob), 'sha256': hashlib.sha256(blob).hexdigest(),
        'dataSize': len(data), 'dataSHA256': hashlib.sha256(data).hexdigest(),
        'options': options, 'firstByte': f'{blob[0]:02x}',
    })
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
