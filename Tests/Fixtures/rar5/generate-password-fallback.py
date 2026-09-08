#!/usr/bin/env python3
"""Project-owned synthetic RAR5 vectors; uses only KaitoKit's format/KDF rules.
Run from any directory with Python 3 and the OpenSSL command-line executable.
Passwords and payloads are deliberately public. No external decoder sources.
"""
import base64
import hashlib
from pathlib import Path
import struct
import subprocess
import zlib

ROOT = Path(__file__).resolve().parent
PASSWORD = ('e\u0301' * 65).encode('utf-8')  # 130 scalars, 65 graphemes
PAYLOAD = b'KaitoKit full UTF-8 password compatibility\n'


def vint(n):
    out = bytearray()
    while n >= 128:
        out.append((n & 127) | 128)
        n >>= 7
    out.append(n)
    return bytes(out)


def block(kind, specific, extra=b'', data=b''):
    flags = bool(extra) | (bool(data) << 1)
    body = vint(kind) + vint(flags)
    if extra:
        body += vint(len(extra))
    if data:
        body += vint(len(data))
    body += specific + extra
    covered = vint(len(body)) + body
    return struct.pack('<I', zlib.crc32(covered)) + covered, data


def keys(salt):
    key = hashlib.pbkdf2_hmac('sha256', PASSWORD, salt, 1)
    check = hashlib.pbkdf2_hmac('sha256', PASSWORD, salt, 33)
    folded = bytes(check[i] ^ check[i+8] ^ check[i+16] ^ check[i+24] for i in range(8))
    return key, folded + hashlib.sha256(folded).digest()[:4]


def encrypt(data, key, iv):
    data += bytes((-len(data)) % 16)
    return subprocess.run(['openssl', 'enc', '-aes-256-cbc', '-nopad',
                           '-K', key.hex(), '-iv', iv.hex()], input=data,
                          capture_output=True, check=True).stdout


for mode in ['p', 'hp']:
    blocks = [block(1, vint(0))]
    for i in range(2):
        salt, iv = bytes([i+1])*16, bytes([i+10])*16
        key, check = keys(salt)
        record = vint(1) + vint(0) + vint(1) + bytes([0]) + salt + iv + check
        extra = vint(len(record)) + record
        name = f'file{i}.txt'.encode()
        specific = vint(4) + vint(len(PAYLOAD)) + vint(0)
        specific += struct.pack('<I', zlib.crc32(PAYLOAD))
        specific += vint(0) + vint(1) + vint(len(name)) + name
        blocks.append(block(2, specific, extra, encrypt(PAYLOAD, key, iv)))
    blocks.append(block(5, vint(0)))
    archive = b'Rar!\x1a\x07\x01\x00'
    if mode == 'hp':
        salt = bytes([99])*16
        key, check = keys(salt)
        header, _ = block(4, vint(0) + vint(1) + bytes([0]) + salt + check)
        archive += header
        for i, (header, data) in enumerate(blocks):
            iv = bytes([20+i])*16
            archive += iv + encrypt(header, key, iv) + data
    else:
        archive += b''.join(header + data for header, data in blocks)
    (ROOT / f'password-full-{mode}.rar.b64').write_bytes(base64.encodebytes(archive))
    print(f'password-full-{mode}.rar.b64: {len(archive)} bytes; SHA-256 {hashlib.sha256(archive).hexdigest()}')
