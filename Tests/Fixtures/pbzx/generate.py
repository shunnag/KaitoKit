#!/usr/bin/env python3
"""pbzx fixtures: Payload streams carved from flat packages written by macOS `pkgbuild`.

`pkgbuild --compression latest` wraps the cpio payload in a pbzx container of xz chunks. The
package is a xar; `xar -xf` extracts the Payload, which is stored here as base64. The chunked
structure is verified independently: each chunk is decoded with the `xz` CLI (or copied when it
is stored raw), the concatenation must be an odc cpio that `bsdtar` lists and extracts to the
original bytes. A small raw-chunk variant is synthesized by re-wrapping the same cpio with this
script's own writer (same layout, one stored chunk) and is also fed through `bsdtar` after
manual unwrapping. Nothing here reads Apple documentation or third-party pbzx sources; the layout
comes from black-box observation of pkgbuild output (Documentation/verification/2026-09-20-pbzx.md).
"""
import base64
import hashlib
import io
import json
import pathlib
import random
import struct
import subprocess
import tarfile
import tempfile

PKGBUILD = '/usr/bin/pkgbuild'
XAR = '/usr/bin/xar'
XZ = '/opt/homebrew/bin/xz'
BSDTAR = '/usr/bin/bsdtar'

root = pathlib.Path(__file__).resolve().parent
rng = random.Random(0x7062)  # "pb"

files = {
    'usr/local/share/kaito/text.txt': ''.join(rng.choice('pbzx payload text \n') for _ in range(18_000)).encode(),
    'usr/local/share/kaito/random.bin': bytes(rng.getrandbits(8) for _ in range(3_000)),
    'usr/local/bin/kaito-hello': b'#!/bin/sh\necho hello\n',
    'usr/local/share/kaito/empty': b'',
}

def unwrap(blob):
    assert blob[:4] == b'pbzx', blob[:4]
    chunk_size = struct.unpack_from('>Q', blob, 4)[0]
    pos, out, chunks = 12, b'', []
    while pos < len(blob):
        unpacked, stored = struct.unpack_from('>QQ', blob, pos)
        body = blob[pos + 16:pos + 16 + stored]
        if body[:6] == bytes.fromhex('fd377a585a00'):
            data = subprocess.run([XZ, '-d', '-c'], input=body, check=True, capture_output=True).stdout
            kind = 'xz'
        else:
            assert stored == unpacked
            data, kind = body, 'raw'
        assert len(data) == unpacked and unpacked <= chunk_size
        chunks.append({'kind': kind, 'unpacked': unpacked, 'stored': stored})
        out += data
        pos += 16 + stored
    assert pos == len(blob)
    return chunk_size, chunks, out

def check_cpio(cpio):
    with tempfile.TemporaryDirectory(prefix='kaito-pbzx-cpio-') as temporary:
        path = pathlib.Path(temporary) / 'payload.cpio'
        path.write_bytes(cpio)
        listing = subprocess.run([BSDTAR, '-tf', str(path)], check=True, capture_output=True, text=True).stdout.split()
        for name, data in files.items():
            member = './' + name
            assert member in listing, (member, listing)
            extracted = subprocess.run([BSDTAR, '-xOf', str(path), member], check=True, capture_output=True).stdout
            assert extracted == data, name

manifest = {'writer': 'macOS pkgbuild (--compression latest --min-os-version 10.10) + xar', 'oracles': ['xz -d per chunk', 'bsdtar on the concatenated cpio'],
            'files': {name: {'size': len(d), 'sha256': hashlib.sha256(d).hexdigest()} for name, d in files.items()}, 'fixtures': []}

with tempfile.TemporaryDirectory(prefix='kaito-pbzx-') as temporary:
    work = pathlib.Path(temporary)
    src = work / 'root'
    for name, data in files.items():
        path = src / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (src / 'usr/local/bin/kaito-hello').chmod(0o755)
    pkg = work / 'fixture.pkg'
    subprocess.run([PKGBUILD, '--root', str(src), '--identifier', 'jp.nagashi.kaito.fixture', '--version', '1.0',
                    '--install-location', '/', '--compression', 'latest', '--min-os-version', '10.10', str(pkg)],
                   check=True, capture_output=True)
    out = work / 'x'
    out.mkdir()
    subprocess.run([XAR, '-xf', str(pkg), '-C', str(out)], check=True)
    payload = (out / 'Payload').read_bytes()
    chunk_size, chunks, cpio = unwrap(payload)
    check_cpio(cpio)
    (root / 'payload-xz.pbzx.b64').write_bytes(base64.encodebytes(payload))
    manifest['fixtures'].append({'file': 'payload-xz.pbzx.b64', 'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest(),
                                 'chunkSize': chunk_size, 'chunks': chunks, 'cpioSize': len(cpio), 'cpioSHA256': hashlib.sha256(cpio).hexdigest()})
    # Synthetic variant: the same cpio as one raw (stored) chunk followed by one xz chunk of the tail.
    split = len(cpio) // 2
    tail_xz = subprocess.run([XZ, '-z', '-c', '-6'], input=cpio[split:], check=True, capture_output=True).stdout
    raw = b'pbzx' + struct.pack('>Q', 1 << 24) + struct.pack('>QQ', split, split) + cpio[:split] \
        + struct.pack('>QQ', len(cpio) - split, len(tail_xz)) + tail_xz
    chunk_size2, chunks2, cpio2 = unwrap(raw)
    assert cpio2 == cpio
    check_cpio(cpio2)
    (root / 'payload-raw-xz.pbzx.b64').write_bytes(base64.encodebytes(raw))
    manifest['fixtures'].append({'file': 'payload-raw-xz.pbzx.b64', 'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                                 'chunkSize': chunk_size2, 'chunks': chunks2, 'cpioSize': len(cpio2), 'cpioSHA256': hashlib.sha256(cpio2).hexdigest(),
                                 'note': 'synthesized by generate.py from the pkgbuild cpio (raw chunk + xz chunk)'})
    # A non-cpio pbzx: the same text wrapped as two xz chunks (single-file exposure path).
    text = files['usr/local/share/kaito/text.txt']
    half = len(text) // 2
    parts = [subprocess.run([XZ, '-z', '-c'], input=part, check=True, capture_output=True).stdout for part in (text[:half], text[half:])]
    plain = b'pbzx' + struct.pack('>Q', 1 << 20)
    for part, data in zip(parts, (text[:half], text[half:])):
        plain += struct.pack('>QQ', len(data), len(part)) + part
    _, chunks3, text2 = unwrap(plain)
    assert text2 == text
    (root / 'text.pbzx.b64').write_bytes(base64.encodebytes(plain))
    manifest['fixtures'].append({'file': 'text.pbzx.b64', 'size': len(plain), 'sha256': hashlib.sha256(plain).hexdigest(),
                                 'chunkSize': 1 << 20, 'chunks': chunks3, 'dataSize': len(text), 'dataSHA256': hashlib.sha256(text).hexdigest(),
                                 'note': 'synthesized: two xz chunks of text.txt, not a cpio'})

(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
