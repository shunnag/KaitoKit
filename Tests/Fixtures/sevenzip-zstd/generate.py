#!/usr/bin/env python3
"""Project-owned inputs written as zstd-in-7z by libarchive's bsdtar and checked with zstd / 7zz."""
import base64
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile

BSDTAR = '/opt/homebrew/opt/libarchive/bin/bsdtar'   # Homebrew libarchive 3.8.x (7zip:compression=zstd)
SEVENZIP = '/opt/homebrew/bin/7zz'                   # 7-Zip 26.03: lists the coder, cannot decode it
ZSTD = '/opt/homebrew/bin/zstd'                      # zstd 1.5.7: decodes the carved packed stream

root = pathlib.Path(__file__).resolve().parent
payloads = {
    'first.bin': bytes(range(256)) * 1025 + bytes([17, 31, 127]),
    'second.bin': bytes((i * 73 + 41) & 255 for i in range(1027)),
    'empty': b'',
}
manifest = {
    'writer': subprocess.run([BSDTAR, '--version'], check=True, capture_output=True, text=True).stdout.strip(),
    'oracles': ['7zz 26.03 (listing only)', 'zstd 1.5.7 (carved packed stream)', 'bsdtar (extraction)'],
    'method': '04 F7 11 01 (Methods.txt: 04 F7 11 xx reserved for Tino Reichardt; 01 = ZSTD)',
    'entries': {name: {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                for name, data in payloads.items()},
    'fixtures': [],
}
solid = payloads['first.bin'] + payloads['second.bin']
with tempfile.TemporaryDirectory(prefix='kaito-7z-zstd-') as temporary:
    work = pathlib.Path(temporary)
    for name, data in payloads.items():
        (work / name).write_bytes(data)
    for level in (1, 19):
        name = f'zstd-l{level}.7z'
        archive = work / name
        options = f'7zip:compression=zstd,7zip:compression-level={level}'
        args = ['--format', '7zip', '--options', options, '-cf', str(archive), *payloads]
        subprocess.run([BSDTAR, *args], cwd=work, check=True)
        listing = subprocess.run([SEVENZIP, 'l', '-slt', str(archive)], check=True,
                                 capture_output=True, text=True).stdout
        assert 'Method = 04F71101' in listing and 'Solid = +' in listing
        packed_size = int(re.search(r'Packed Size = (\d+)', listing).group(1))
        data = archive.read_bytes()
        # packed stream of the single solid folder starts right after the 32-byte start header
        carved = data[32:32 + packed_size]
        decoded = subprocess.run([ZSTD, '-d', '-c'], input=carved, check=True, capture_output=True).stdout
        assert decoded == solid, name
        for entry, expected in payloads.items():
            extracted = subprocess.run([BSDTAR, '-xOf', str(archive), entry], check=True,
                                       capture_output=True).stdout
            assert extracted == expected, (name, entry)
        (root / (name + '.b64')).write_bytes(base64.encodebytes(data))
        manifest['fixtures'].append({
            'file': name + '.b64', 'sha256': hashlib.sha256(data).hexdigest(), 'level': level,
            'packedSize': packed_size, 'arguments': args[:-len(payloads) - 1] + ['ARCHIVE', *payloads],
        })
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
