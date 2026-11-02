#!/usr/bin/env python3
"""RAR13_FORMAT_SPECIFICATION.md から作る小さな RAR 1.3 標本。"""

import argparse
import base64
import hashlib
from pathlib import Path
import runpy
import struct
import subprocess
import tempfile


SHARED = runpy.run_path(str(Path(__file__).with_name('make-rar15.py')))
Encoder = SHARED['Encoder']
PHRASE = SHARED['PHRASE']


def checksum(data):
    value = 0
    for byte in data:
        value = (value + byte) & 0xFFFF
        value = ((value << 1) | (value >> 15)) & 0xFFFF
    return value


def archive(members, solid=False, per_file_solid=True):
    result = bytearray(b'RE~^' + struct.pack('<HB', 7, 0x08 if solid else 0))
    for index, (name, expected, packed, version, method, directory) in enumerate(members):
        flags = 0x10 if solid and per_file_solid and index > 0 else 0
        attributes = 0x10 if directory else 0x20
        result += struct.pack(
            '<IIHHIBBBBB', len(packed), len(expected), checksum(expected),
            21 + len(name), 0, attributes, flags, version, len(name), method
        )
        result += name + packed
    return bytes(result)


def generate(unrar):
    normal_members = []
    for name, data in [(b'stored.txt', PHRASE), (b'compressed.txt', PHRASE + PHRASE)]:
        encoder = Encoder()
        encoder.start_file()
        encoder.literals(PHRASE)
        packed = data
        if len(data) > len(PHRASE):
            encoder.short_match(len(PHRASE), len(PHRASE))
            packed = encoder.finish_file()
        normal_members.append((name, data, packed, 2 if len(data) > len(PHRASE) else 1, 3 if len(data) > len(PHRASE) else 0, False))

    encoder = Encoder()
    solid_members = []
    for index, name in enumerate([b'first.txt', b'second.txt']):
        encoder.start_file()
        if index == 0:
            encoder.literals(PHRASE)
        else:
            encoder.short_match(len(PHRASE), len(PHRASE))
        solid_members.append((name, PHRASE, encoder.finish_file(), 2, 3, False))

    archives = {}
    variants = [
        ('normal', normal_members, False, True),
        ('solid', solid_members, True, True),
        ('solid-main', solid_members, True, False),
    ]
    for name, members, solid, per_file_solid in variants:
        data = archive(members, solid=solid, per_file_solid=per_file_solid)
        archives[name] = data
        with tempfile.TemporaryDirectory(prefix='kaitokit-rar13-') as temporary:
            root = Path(temporary)
            source = root / (name + '.rar')
            source.write_bytes(data)
            subprocess.run([unrar, 't', '-idq', str(source)], check=True)
            destination = root / 'out'
            destination.mkdir()
            subprocess.run([unrar, 'x', '-idq', str(source), str(destination) + '/'], check=True)
            for member, expected, _, _, _, directory in members:
                if not directory:
                    actual = (destination / member.decode()).read_bytes()
                    assert actual == expected, (name, member, actual, expected)
    return archives


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--unrar', default='unrar')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[2] / 'Tests/Fixtures/rar13')
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)
    for name, data in generate(arguments.unrar).items():
        (arguments.output / (name + '.rar.b64')).write_text(base64.b64encode(data).decode() + '\n')
        print(name, hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    main()
