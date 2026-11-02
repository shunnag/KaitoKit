#!/usr/bin/env python3
"""通常の RAR 1.3 fixture から old multi-volume 標本を作る。"""

import argparse
import base64
import hashlib
from pathlib import Path
import runpy
import struct
import subprocess
import tempfile


BASE = runpy.run_path(str(Path(__file__).with_name('make-rar13.py')))


def entries(data):
    result = []
    offset = struct.unpack_from('<H', data, 4)[0]
    while offset < len(data):
        packed = struct.unpack_from('<I', data, offset)[0]
        size = struct.unpack_from('<H', data, offset + 10)[0]
        result.append({
            'header': bytearray(data[offset:offset + size]),
            'payload': data[offset + size:offset + size + packed],
        })
        offset += size + packed
    return result


def volume(parts, solid=False):
    result = bytearray(b'RE~^' + struct.pack('<HB', 7, 0x89 if solid else 0x81))
    for header, payload in parts:
        result += header + payload
    return bytes(result)


def split_entry(entry, cut):
    first_header = bytearray(entry['header'])
    second_header = bytearray(entry['header'])
    first_header[17] |= 0x02
    second_header[17] |= 0x01
    struct.pack_into('<I', first_header, 0, cut)
    struct.pack_into('<I', second_header, 0, len(entry['payload']) - cut)
    return (first_header, entry['payload'][:cut]), (second_header, entry['payload'][cut:])


def generate(unrar):
    archives = BASE['generate'](unrar)
    original = entries(archives['normal'])
    stored_first, stored_second = split_entry(original[0], 3)
    compressed_first, compressed_second = split_entry(original[1], 3)
    outputs = {
        'split.rar': volume([(original[0]['header'], original[0]['payload']), compressed_first]),
        'split.r00': volume([compressed_second]),
        'stored-split.rar': volume([stored_first]),
        'stored-split.r00': volume([stored_second]),
    }
    for variant in ['solid', 'solid-main']:
        solid_entries = entries(archives[variant])
        first, second = split_entry(solid_entries[1], 3)
        outputs[variant + '-split.rar'] = volume([
            (solid_entries[0]['header'], solid_entries[0]['payload']), first,
        ], solid=True)
        outputs[variant + '-split.r00'] = volume([second], solid=True)
    with tempfile.TemporaryDirectory(prefix='kaitokit-rar13-volumes-') as temporary:
        root = Path(temporary)
        for name, data in outputs.items():
            (root / name).write_bytes(data)
        for name in ['split', 'stored-split', 'solid-split', 'solid-main-split']:
            archive = root / (name + '.rar')
            subprocess.run([unrar, 't', '-idq', str(archive)], check=True)
            destination = root / name
            destination.mkdir()
            subprocess.run([unrar, 'x', '-idq', str(archive), str(destination) + '/'], check=True)
            expected = original[1:] if name == 'split' else original[:1]
            if name in ['solid-split', 'solid-main-split']:
                expected = entries(archives[name.removesuffix('-split')])
            for entry in expected:
                name_bytes = entry['header'][21:]
                actual = (destination / name_bytes.decode()).read_bytes()
                assert actual == BASE['PHRASE'] * (2 if name_bytes == b'compressed.txt' else 1)
    return outputs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--unrar', default='unrar')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[2] / 'Tests/Fixtures/rar13')
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)
    for name, data in generate(arguments.unrar).items():
        (arguments.output / (name + '.b64')).write_text(base64.b64encode(data).decode() + '\n')
        print(name, hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    main()
