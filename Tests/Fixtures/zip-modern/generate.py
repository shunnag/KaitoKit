"""Fixture-only generator: Python 3.14 zipfile/lzma, 7zz, and OpenSSL.

The fixed salt/password below are public test data, never production encryption.
Specifications: PKWARE APPNOTE 4.4.5; WinZip AES specification 1.04.
No archive-engine source code is used.
"""
import base64
import hashlib
import hmac
import io
import json
import lzma
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile

DESTINATION = Path(__file__).resolve().parent
PASSWORD = 'KaitoFixture'
PAYLOAD = ('XZ and Zstandard ZIP interoperability 日本語\n' * 800).encode()


def check7zip(path, password=None):
    args = ['/opt/homebrew/bin/7zz', 'x', '-so', str(path), 'payload.txt']
    if password:
        args.insert(2, '-p' + password)
    result = subprocess.run(args, check=True, capture_output=True)
    assert result.stdout == PAYLOAD


def aes_zip(packed, method):
    salt = bytes(range(16))
    keys = hashlib.pbkdf2_hmac('sha1', PASSWORD.encode(), salt, 1000, 66)
    counters = b''.join(i.to_bytes(16, 'little') for i in range(1, (len(packed)+15)//16+1))
    mask = subprocess.run(['/usr/bin/openssl', 'enc', '-aes-256-ecb', '-K', keys[:32].hex(), '-nopad'],
                          input=counters, capture_output=True, check=True).stdout
    encrypted = bytes(a ^ b for a, b in zip(packed, mask))
    body = salt + keys[64:] + encrypted + hmac.new(keys[32:64], encrypted, 'sha1').digest()[:10]
    extra = struct.pack('<HHH2sBH', 0x9901, 7, 2, b'AE', 3, method)
    name = b'payload.txt'
    local = struct.pack('<IHHHHHIIIHH', 0x04034b50, 51, 1, 99, 0, 0x5022, 0,
                        len(body), len(PAYLOAD), len(name), len(extra)) + name + extra + body
    central = struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 51, 51, 1, 99, 0, 0x5022, 0,
                          len(body), len(PAYLOAD), len(name), len(extra), 0, 0, 0, 0, 0) + name + extra
    return local + central + struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 1, 1, len(central), len(local), 0)


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    fixtures = {}
    with tempfile.TemporaryDirectory(prefix='kaito-zip-modern-') as temporary:
        root = Path(temporary)
        source = root / 'payload.txt'
        source.write_bytes(PAYLOAD)
        os.utime(source, (1577923200, 1577923200))
        for name, encryption in [('xz', None), ('xz-aes', 'AES256'), ('xz-zipcrypto', 'ZipCrypto')]:
            archive = root / (name + '.zip')
            args = ['/opt/homebrew/bin/7zz', 'a', '-tzip', '-mm=XZ', '-bd', '-bb0', '-y', str(archive), 'payload.txt']
            if encryption:
                args[2:2] = ['-mem=' + encryption, '-p' + PASSWORD]
            subprocess.run(args, cwd=root, check=True, capture_output=True)
            check7zip(archive, PASSWORD if encryption else None)
            fixtures[name + '.zip'] = archive.read_bytes()
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_ZSTANDARD) as archive:
            archive.writestr('payload.txt', PAYLOAD)
        data = stream.getvalue()
        fixtures['zstd93.zip'] = data
        legacy = bytearray(data)
        central = legacy.index(b'PK\x01\x02')
        struct.pack_into('<H', legacy, 8, 20)
        struct.pack_into('<H', legacy, central + 10, 20)
        fixtures['zstd20.zip'] = bytes(legacy)
        with zipfile.ZipFile(io.BytesIO(fixtures['zstd93.zip'])) as reader:
            assert reader.read('payload.txt') == PAYLOAD
        with zipfile.ZipFile(io.BytesIO(data)) as reader:
            info = reader.infolist()[0]
            start = 30 + len(info.filename.encode()) + len(info.extra)
            packed = data[start:start+info.compress_size]
        for method in [93, 20]:
            fixtures[f'zstd-aes{method}.zip'] = aes_zip(packed, method)
        # 7-Zip 26.03 accepts 93 but rejects deprecated 20. The AES wrapper is
        # independently checked with method 93; only the actual-method field
        # differs in the 20 fixture. This host's Python 3.14.7 also rejects 20,
        # despite its documentation; do not claim a direct legacy-ZIP oracle.
        for name in ['zstd93.zip', 'zstd-aes93.zip']:
            path = root / name
            path.write_bytes(fixtures[name])
            check7zip(path, PASSWORD if '-aes' in name else None)
        filters = [{'id': lzma.FILTER_LZMA2, 'dict_size': 1 << 20}]
        fixtures['small-dictionary.xz'] = lzma.compress(PAYLOAD, filters=filters)
        fixtures['empty.xz'] = lzma.compress(b'', filters=filters)
    for name, data in fixtures.items():
        (DESTINATION / (name + '.b64')).write_bytes(base64.encodebytes(data))
    manifest = {'payload_size': len(PAYLOAD), 'payload_sha256': hashlib.sha256(PAYLOAD).hexdigest(),
                'password': PASSWORD, 'archives': {name: hashlib.sha256(data).hexdigest() for name, data in fixtures.items()}}
    (DESTINATION / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
