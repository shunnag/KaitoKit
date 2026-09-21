#!/usr/bin/env python3
"""Project-owned lzip fixtures.

Members are framed by this script from draft-diaz-lzip §2 (header `LZIP` + version 1 +
coded dictionary size, LZMA-302eos stream, trailer CRC32 / data size / member size) around a
raw LZMA1 stream produced by Python's standard `lzma` module (lc=3, lp=0, pb=2, end marker).
The `bundle.tar.lz` variant is written by libarchive's `bsdtar --lzip` instead. Every fixture
is decoded by `xz -d --format=lzip` (XZ Utils, an independent reader) and compared with the
original bytes before it is stored. No lzip / plzip / third-party decoder source is used.
"""
import base64
import hashlib
import json
import lzma
import pathlib
import random
import struct
import subprocess
import tarfile
import tempfile
import zlib

XZ = '/opt/homebrew/bin/xz'
BSDTAR = '/usr/bin/bsdtar'

root = pathlib.Path(__file__).resolve().parent
rng = random.Random(0x4C5A4950)  # "LZIP"

def coded_dictionary(size):
    """DS byte for an exact dictionary size: base 2^e minus n/16 of it (§2)."""
    for exponent in range(12, 30):
        base = 1 << exponent
        for numerator in range(8):
            if base - numerator * (base // 16) == size:
                return (numerator << 5) | exponent
    raise ValueError(size)

def member(data, dictionary=1 << 20, version=1):
    stream = lzma.compress(data, format=lzma.FORMAT_RAW, filters=[
        {'id': lzma.FILTER_LZMA1, 'dict_size': dictionary, 'lc': 3, 'lp': 0, 'pb': 2},
    ])
    body = b'LZIP' + bytes([version, coded_dictionary(dictionary)]) + stream
    return body + struct.pack('<IQQ', zlib.crc32(data) & 0xFFFFFFFF, len(data), len(body) + 20)

text = ''.join(rng.choice('abcdefghijklmnop \n') for _ in range(24_000)).encode()
binary = bytes((i * 73 + 41) & 255 for i in range(20_000)) + bytes(range(256)) * 8
random_bytes = bytes(rng.getrandbits(8) for _ in range(8_192))
one = b'\x2a'

payloads = {
    'text.lz': [(text, 1 << 20)],
    'binary.lz': [(binary, 1 << 16)],
    'random.lz': [(random_bytes, 4_096)],           # smallest dictionary (DS 0x0C)
    'fraction.lz': [(binary, (1 << 19) - 6 * (1 << 15))],  # DS 0xD3 = 320 KiB from §2's example
    'empty.lz': [(b'', 1 << 20)],
    'one.lz': [(one, 1 << 20)],
    'multi.lz': [(text, 1 << 20), (binary, 1 << 16), (one, 4_096)],
}

manifest = {'writer': 'Python lzma FORMAT_RAW FILTER_LZMA1 + this script (framing); bsdtar for bundle.tar.lz',
            'reader': 'xz -d --format=lzip (XZ Utils 5.8.4)', 'fixtures': []}

def store(name, blob, expected, extra):
    decoded = subprocess.run([XZ, '-d', '--format=lzip', '-c'], input=blob, check=True, capture_output=True).stdout
    assert decoded == expected, name
    (root / (name + '.b64')).write_bytes(base64.encodebytes(blob))
    manifest['fixtures'].append({'file': name + '.b64', 'size': len(blob), 'sha256': hashlib.sha256(blob).hexdigest(),
                                 'dataSize': len(expected), 'dataSHA256': hashlib.sha256(expected).hexdigest(), **extra})

for name, parts in payloads.items():
    blob = b''.join(member(data, dictionary) for data, dictionary in parts)
    store(name, blob, b''.join(data for data, _ in parts),
          {'members': [{'dataSize': len(d), 'dictionary': dic} for d, dic in parts]})

with tempfile.TemporaryDirectory(prefix='kaito-lzip-') as temporary:
    work = pathlib.Path(temporary)
    (work / 'a.txt').write_bytes(text[:5_000])
    (work / 'b.bin').write_bytes(binary[:3_000])
    archive = work / 'bundle.tar.lz'
    subprocess.run([BSDTAR, '--lzip', '-cf', str(archive), 'a.txt', 'b.bin'], cwd=work, check=True)
    blob = archive.read_bytes()
    expected = subprocess.run([XZ, '-d', '--format=lzip', '-c'], input=blob, check=True, capture_output=True).stdout
    with tarfile.open(fileobj=__import__('io').BytesIO(expected)) as tar:
        names = tar.getnames()
        assert names == ['a.txt', 'b.bin'], names
        assert tar.extractfile('a.txt').read() == text[:5_000]
        assert tar.extractfile('b.bin').read() == binary[:3_000]
    store('bundle.tar.lz', blob, expected, {'members': 'bsdtar --lzip', 'tarEntries': names,
                                            'entrySHA256': {'a.txt': hashlib.sha256(text[:5_000]).hexdigest(),
                                                            'b.bin': hashlib.sha256(binary[:3_000]).hexdigest()}})

(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
