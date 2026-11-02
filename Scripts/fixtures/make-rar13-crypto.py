#!/usr/bin/env python3
"""RAR 1.3 の暗号・solid・comment 標本を生成し UNRAR で照合する。"""

import argparse
import base64
import hashlib
from pathlib import Path
import runpy
import struct
import subprocess
import tempfile


BASE = runpy.run_path(str(Path(__file__).with_name('make-rar13.py')))
Encoder = BASE['Encoder']
PHRASE = BASE['PHRASE']
PASSWORD = b'password'
ARCHIVE_COMMENT = b'RAR 1.3 comment.\r\n'
FILE_COMMENT = b'note\r\n'


def password_key(password):
    key = [0, 0, 0]
    for byte in password:
        key[0] = (key[0] + byte) & 0xFF
        key[1] ^= byte
        key[2] = (key[2] + byte) & 0xFF
        key[2] = ((key[2] << 1) | (key[2] >> 7)) & 0xFF
    return key


def encrypt(data, key):
    key = list(key)
    result = bytearray()
    for byte in data:
        key[1] = (key[1] + key[2]) & 0xFF
        key[0] = (key[0] + key[1]) & 0xFF
        result.append((byte + key[0]) & 0xFF)
    return bytes(result)


def archive(members, solid=False, encrypted=False, archive_comment=None):
    main_flags = 0x08 if solid else 0
    extension = b''
    if archive_comment is not None:
        main_flags |= 0x12
        packed, unpacked = archive_comment
        extension = struct.pack('<HH', len(packed) + 2, len(unpacked)) + packed
    result = bytearray(b'RE~^' + struct.pack('<HB', 7 + len(extension), main_flags) + extension)
    for index, (name, expected, packed, version, method, file_comment) in enumerate(members):
        flags = (0x10 if solid and index > 0 else 0) | (0x04 if encrypted else 0)
        if file_comment is not None:
            flags |= 0x08
        result += struct.pack(
            '<IIHHIBBBBB', len(packed), len(expected), BASE['checksum'](expected),
            21 + len(name) + (2 + len(file_comment) if file_comment is not None else 0),
            0, 0x20, flags, version, len(name), method
        )
        result += name
        if file_comment is not None:
            result += struct.pack('<H', len(file_comment)) + file_comment
        if encrypted:
            packed = encrypt(packed, password_key(PASSWORD))
        result += packed
    return bytes(result)


def solid_members():
    encoder = Encoder()
    members = []
    for index, name in enumerate([b'first.txt', b'second.txt']):
        encoder.start_file()
        if index == 0:
            encoder.literals(PHRASE)
        else:
            encoder.short_match(len(PHRASE), len(PHRASE))
        members.append((name, PHRASE, encoder.finish_file(), 2, 3, None))
    return members


def generate(unrar):
    encrypted_members = []
    for name, data in [(b'stored.txt', PHRASE), (b'compressed.txt', PHRASE + PHRASE)]:
        encoder = Encoder()
        encoder.start_file()
        encoder.literals(PHRASE)
        packed = data
        if len(data) > len(PHRASE):
            encoder.short_match(len(PHRASE), len(PHRASE))
            packed = encoder.finish_file()
        encrypted_members.append((name, data, packed, 2 if len(data) > len(PHRASE) else 1, 3 if len(data) > len(PHRASE) else 0, None))

    encoder = Encoder()
    encoder.start_file()
    encoder.literals(ARCHIVE_COMMENT)
    archive_comment = (encrypt(encoder.finish_file(), [0, 7, 77]), ARCHIVE_COMMENT)
    comment_members = [(b'stored.txt', PHRASE, PHRASE, 1, 0, FILE_COMMENT)]
    archives = {
        'encrypted': archive(encrypted_members, encrypted=True),
        'solid-encrypted': archive(solid_members(), solid=True, encrypted=True),
        'comments': archive(comment_members, archive_comment=archive_comment),
    }
    for name, data in archives.items():
        encrypted = name != 'comments'
        with tempfile.TemporaryDirectory(prefix='kaitokit-rar13-crypto-') as temporary:
            root = Path(temporary)
            source = root / (name + '.rar')
            source.write_bytes(data)
            password_option = ['-p' + PASSWORD.decode()] if encrypted else []
            subprocess.run([unrar, 't', '-idq', *password_option, str(source)], check=True)
            destination = root / 'out'
            destination.mkdir()
            subprocess.run([unrar, 'x', '-idq', *password_option, str(source), str(destination) + '/'], check=True)
            members = comment_members if name == 'comments' else (solid_members() if name == 'solid-encrypted' else encrypted_members)
            for member, expected, _, _, _, _ in members:
                actual = (destination / member.decode()).read_bytes()
                assert actual == expected, (name, member, actual, expected)
            if name == 'comments':
                shown = subprocess.run([unrar, 'v', str(source)], check=True, stdout=subprocess.PIPE).stdout
                assert ARCHIVE_COMMENT.decode() in shown.decode(errors='replace'), shown
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
