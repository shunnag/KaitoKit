#!/usr/bin/env python3
"""RAR 1.5 の solid 書庫から old multi-volume 標本を作り、UNRAR で照合する。"""

import argparse
import base64
import hashlib
from pathlib import Path
import runpy
import struct
import subprocess
import tempfile
import zlib


BASE = runpy.run_path(str(Path(__file__).with_name('make-rar15.py')))


def entries(data):
    result = []
    offset = 20
    while data[offset + 2] != 0x7B:
        head_size = struct.unpack_from('<H', data, offset + 5)[0]
        flags = struct.unpack_from('<H', data, offset + 3)[0]
        packed = struct.unpack_from('<I', data, offset + 7)[0]
        result.append({
            'flags': flags,
            'fields': data[offset + 7:offset + head_size],
            'payload': data[offset + head_size:offset + head_size + packed],
        })
        offset += head_size + packed
    return result


def generate(unrar):
    original = entries(BASE['generate'](unrar)['solid'])
    first = original[0]
    second = original[1]
    cut = 3
    first_fields = bytearray(second['fields'])
    second_fields = bytearray(second['fields'])
    struct.pack_into('<I', first_fields, 0, cut)
    struct.pack_into('<I', second_fields, 0, len(second['payload']) - cut)
    struct.pack_into('<I', first_fields, 9, zlib.crc32(second['payload'][:cut]))
    main = BASE['header'](0x73, 0x0009, bytes(6))
    outputs = {
        'solid-split.rar': b'Rar!\x1A\x07\x00' + main
            + BASE['header'](0x74, first['flags'], first['fields']) + first['payload']
            + BASE['header'](0x74, second['flags'] | 2, first_fields) + second['payload'][:cut],
        'solid-split.r00': b'Rar!\x1A\x07\x00' + main
            + BASE['header'](0x74, second['flags'] | 1, second_fields) + second['payload'][cut:]
            + BASE['header'](0x7B, 0, b''),
    }
    with tempfile.TemporaryDirectory(prefix='kaitokit-rar15-volumes-') as temporary:
        root = Path(temporary)
        for name, data in outputs.items():
            (root / name).write_bytes(data)
        archive = root / 'solid-split.rar'
        subprocess.run([unrar, 't', '-idq', str(archive)], check=True)
        subprocess.run([unrar, 'x', '-idq', str(archive), str(root) + '/'], check=True)
        for name in ['first.txt', 'second.txt']:
            assert (root / name).read_bytes() == BASE['PHRASE']
    return outputs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--unrar', default='unrar')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[2] / 'Tests/Fixtures/rar15')
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)
    for name, data in generate(arguments.unrar).items():
        (arguments.output / (name + '.b64')).write_text(base64.b64encode(data).decode() + '\n')
        print(name, hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    main()
