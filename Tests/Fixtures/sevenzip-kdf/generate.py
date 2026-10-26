#!/usr/bin/env python3
"""自作 7zAES folder。標準ライブラリと OpenSSL の AES primitive だけを使う。"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import zlib


def number(value):
    for count in range(8):
        if value < 1 << (7 + 7 * count):
            return bytes([(0xff << (8 - count) & 0xff) | (value >> (8 * count))]) + value.to_bytes(8, 'little')[:count]
    return b'\xff' + struct.pack('<Q', value)


def archive(folders, power=8, shared=False, opaque=False):
    packed, coders, names = bytearray(), bytearray(), bytearray(b'\0')
    plaintext = b'Kaito KDF test!\n'
    for index in range(folders):
        salt = (0 if shared else index).to_bytes(16, 'little')
        if opaque:
            ciphertext = bytes(16)
        else:
            sha = hashlib.sha256()
            for counter in range(1 << power):
                sha.update(salt + 'anypw'.encode('utf-16le') + struct.pack('<Q', counter))
            ciphertext = subprocess.run(['openssl', 'enc', '-aes-256-cbc', '-K', sha.hexdigest(),
                                         '-iv', '00' * 16, '-nopad'], input=plaintext + bytes(-len(plaintext) % 16),
                                        capture_output=True, check=True).stdout
        packed += ciphertext
        coders += bytes([1, 0x24, 6, 0xf1, 7, 1, 18, 0x80 | power, 0xf0]) + salt
        names += (f'f{index:03}' + '\0').encode('utf-16le')
    header = bytearray(b'\x01\x04\x06\x00') + number(folders) + b'\x09' + number(16) * folders + b'\x00'
    header += b'\x07\x0b' + number(folders) + b'\x00' + coders + b'\x0c' + number(len(plaintext)) * folders
    if not opaque:
        header += b'\x0a\x01' + struct.pack('<I', zlib.crc32(plaintext)) * folders
    header += b'\x00\x00\x05' + number(folders) + b'\x11' + number(len(names)) + names + b'\x00\x00'
    start = struct.pack('<QQI', len(packed), len(header), zlib.crc32(header))
    return b'7z\xbc\xaf\x27\x1c\x00\x04' + struct.pack('<I', zlib.crc32(start)) + start + packed + header


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--folders', type=int, default=33)
    parser.add_argument('--power', type=int, default=8)
    parser.add_argument('--opaque', action='store_true', help='計測用。導出せず CRC なしの暗号文を置く')
    args = parser.parse_args()
    if args.output:
        args.output.write_bytes(archive(args.folders, args.power, opaque=args.opaque))
    else:
        root = Path(__file__).parent
        fixtures = []
        for name, count, shared in [('distinct', 33, False), ('shared', 2, True)]:
            data = archive(count, shared=shared)
            filename = name + '.7z.b64'
            (root / filename).write_bytes(base64.encodebytes(data))
            fixtures.append(dict(file=filename, sha256=hashlib.sha256(data).hexdigest(), folders=count,
                                 cyclesPower=8, sharedSalt=shared))
        (root / 'manifest.json').write_text(json.dumps(dict(writer='project-owned Python + OpenSSL AES-256-CBC',
            password='anypw', plaintext='Kaito KDF test!\n', fixtures=fixtures), indent=2) + '\n')
