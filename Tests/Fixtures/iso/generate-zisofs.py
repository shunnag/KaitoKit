#!/usr/bin/env python3
"""zisofs fixtures written by GNU xorriso (black-box writer) from project-owned inputs.

Each image is trimmed to the PVD volume space, gzipped with mtime=0 and base64 encoded like the
other ISO fixtures. Expected SHA-256 values of the inputs are printed for the tests / NOTICE.
"""
import base64
import gzip
import hashlib
import io
import pathlib
import random
import struct
import subprocess
import tempfile

XORRISO = '/opt/homebrew/bin/xorriso'
root = pathlib.Path(__file__).resolve().parent
rng = random.Random(0x5A46)  # "ZF"

inputs = {
    'text.txt': ''.join(f'zisofs block {i % 97:02d} line\n' for i in range(4_000)).encode(),  # 84,000 bytes, compressible
    'zeros.bin': bytes(70_000),                                    # every block is a zero pointer
    'mixed.bin': bytes(40_000) + bytes(rng.getrandbits(8) for _ in range(8_000)) + bytes(30_000),
    'small.txt': b'tiny',                                          # xorriso stores files this small uncompressed
    'empty': b'',
    'sub/deep.txt': b'deep ' * 3_000,
}
for name, data in inputs.items():
    print(f'{name}\t{len(data)}\t{hashlib.sha256(data).hexdigest()}')

for block in ('32k', '128k'):
    with tempfile.TemporaryDirectory(prefix='kaito-zisofs-') as temporary:
        work = pathlib.Path(temporary)
        src = work / 'src'
        for name, data in inputs.items():
            path = src / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        image = work / 'image.iso'
        subprocess.run([XORRISO, '-outdev', str(image), '-padding', '0', '-zisofs', f'level=9:block_size={block}',
                        '-map', str(src), '/', '-set_filter_r', '--zisofs', '/', '--', '-commit'],
                       check=True, capture_output=True)
        data = image.read_bytes()
        pvd = data[32768:32768 + 2048]
        blocks = struct.unpack_from('<I', pvd, 80)[0]
        block_size = struct.unpack_from('<H', pvd, 128)[0]
        data = data[:blocks * block_size]
        buffer = io.BytesIO()
        with gzip.GzipFile(fileobj=buffer, mode='wb', mtime=0) as archive:
            archive.write(data)
        encoded = base64.encodebytes(buffer.getvalue())
        (root / f'zisofs-{block}.iso.gz.b64').write_bytes(encoded)
        print(f'zisofs-{block}.iso\t{len(data)}\t{hashlib.sha256(data).hexdigest()}\tencoded {len(encoded)}')
