#!/usr/bin/env python3
"""KaitoKit 自身の test header と標準 compressor の黒箱 API で corpus を作る。"""
import hashlib
import json
import lzma
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys
import zlib

root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
if any(p.name != 'text.bin' for p in root.iterdir()):
    raise SystemExit('corpus directory must be empty')

def guard():
    if shutil.disk_usage('/System/Volumes/Data').free < 25 * 1024**3:
        raise SystemExit('less than 25 GiB free')
    if sum(p.stat().st_blocks * 512 for p in root.parent.rglob('*') if p.is_file()) >= 3_000_000_000:
        raise SystemExit('scratch exceeds 3 GB')

def number(n):
    for i in range(8):
        if n < 1 << (7 * (i + 1)):
            return bytes([((0xff << (8 - i)) & 255) | (n >> (8 * i))]) + n.to_bytes(8, 'little')[:i]
    return b'\xff' + struct.pack('<Q', n)

def archive(data, name, lzma1=False):
    filt = {'id': lzma.FILTER_LZMA1 if lzma1 else lzma.FILTER_LZMA2,
            'dict_size': 8 * 1024**2, 'lc': 3, 'lp': 0, 'pb': 2, 'preset': 6}
    packed = lzma.compress(data, format=lzma.FORMAT_RAW, filters=[filt])
    coder = b'\x23\x03\x01\x01\x05\x5d\x00\x00\x80\x00' if lzma1 else b'\x21\x21\x01\x16'
    header = b'\x01\x04\x06\x00\x01\x09' + number(len(packed)) + b'\x00'
    header += b'\x07\x0b\x01\x00\x01' + coder + b'\x0c' + number(len(data))
    header += b'\x0a\x01' + struct.pack('<I', zlib.crc32(data)) + b'\x00\x00'
    names = b'\x00' + (name + '\0').encode('utf-16le')
    header += b'\x05\x01\x11' + number(len(names)) + names + b'\x00\x00'
    start = struct.pack('<QQI', len(packed), len(header), zlib.crc32(header))
    return b'7z\xbc\xaf\x27\x1c\x00\x04' + struct.pack('<I', zlib.crc32(start)) + start + packed + header

size = 64 * 1024**2
rng = random.Random(20261030)
words = (b'archive reader entry stream buffer checksum decode file directory metadata '
         b'window block table symbol length distance offset byte count format header '
         b'compression measurement sample round baseline branch identity timestamp ').split()
text = bytearray()
while len(text) < size:
    text.extend(b' '.join(rng.choices(words, k=1024)) + b'\n')
(root / 'text.bin').write_bytes(text[:size])

# 各 page の紙面色・罫線・粒を変える。JPEG は sips の入出力だけを利用する。
images = bytearray()
page = 0
while len(images) < size:
    guard()
    ppm = root / 'page.ppm'
    with ppm.open('wb') as f:
        f.write(b'P6\n1024 1024\n255\n')
        for y in range(1024):
            base = 70 + ((y // 43 + page) % 4) * 32
            table = bytes(base + v % 32 for v in range(256))
            row = rng.randbytes(3072).translate(table)
            f.write(row)
    jpg = root / 'page.jpg'
    subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '85', str(ppm), '--out', str(jpg)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    images.extend(jpg.read_bytes())
    page += 1
ppm.unlink(); jpg.unlink()
(root / 'jpeg.bin').write_bytes(images)
manifest = {'jpeg_pages': page, 'seed': 20261030, 'cases': []}
for kind in ['jpeg', 'text']:
    data = (root / (kind + '.bin')).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    for codec in ['lzma2', 'lzma1', 'xz']:
        guard()
        output = root / (kind + ('-lzma.7z' if codec == 'lzma1' else '.7z' if codec == 'lzma2' else '.xz'))
        encoded = (lzma.compress(data, format=lzma.FORMAT_XZ, filters=[{'id': lzma.FILTER_LZMA2, 'dict_size': 8 * 1024**2, 'preset': 6}])
                   if codec == 'xz' else archive(data, kind + '.bin', codec == 'lzma1'))
        output.write_bytes(encoded)
        manifest['cases'].append({'path': output.name, 'bytes': len(data), 'sha256': digest,
                                  'archive_bytes': len(encoded), 'archive_sha256': hashlib.sha256(encoded).hexdigest()})
        print(output.name, len(data), len(encoded), flush=True)
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
