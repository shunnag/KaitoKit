#!/usr/bin/env python3
"""プロジェクト所有の入力を 7zz 26.03 で書き、同 CLI と原本で照合する。"""
import base64
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile
import zlib

SEVENZIP = '/opt/homebrew/bin/7zz'
root = pathlib.Path(__file__).resolve().parent

# 短周期を避けた 48,000 byte を反復し、32 KiB を超える距離を使わせる。
state = b'KaitoKit 7z Deflate64 long fixture'
pattern = bytearray()
while len(pattern) < 48_000:
    state = hashlib.sha256(state).digest()
    pattern.extend(state)
payloads = {
    'first.bin': bytes(range(256)) * 1025 + bytes([17, 31, 127]),
    'second.bin': bytes((i * 73 + 41) & 255 for i in range(1027)),
    'empty': b'',
    'long.bin': bytes(pattern[:48_000]) * 4,
}
version = subprocess.run([SEVENZIP, 'i'], check=True, capture_output=True, text=True).stdout
writer = next(line for line in version.splitlines() if line.startswith('7-Zip (z)'))
assert '26.03 ' in writer, writer
manifest = {
    'writer': writer,
    'oracles': ['7zz 26.03 (test, extraction, listing)', 'Python zlib (raw Deflate rejection)'],
    'method': '04 01 09 (Methods.txt: Deflate64)',
    'entries': {name: {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                for name, data in payloads.items()},
    'fixtures': [],
}
encoded_size = 0
with tempfile.TemporaryDirectory(prefix='kaito-7z-deflate64-') as temporary:
    work = pathlib.Path(temporary)
    for name, data in payloads.items():
        path = work / name
        path.write_bytes(data)
        path.chmod(0o644)
    # non-solid は元の 2 非空 entry を使い、指定どおり 2 folder にする。
    for solid, entries in [(True, list(payloads)), (False, ['first.bin', 'second.bin', 'empty'])]:
        name = 'deflate64-' + ('solid' if solid else 'non-solid') + '.7z'
        archive = work / name
        options = ['a', '-t7z', '-m0=Deflate64', '-ms=' + ('on' if solid else 'off'),
                   '-mhc=off', '-mtm=off', '-mta=off', '-mtc=off']
        subprocess.run([SEVENZIP, *options, str(archive), *entries], cwd=work,
                       check=True, capture_output=True)
        tested = subprocess.run([SEVENZIP, 't', str(archive)], check=True,
                                capture_output=True, text=True).stdout
        assert 'Everything is Ok' in tested, tested
        listing = subprocess.run([SEVENZIP, 'l', '-slt', str(archive)], check=True,
                                 capture_output=True, text=True).stdout
        archive_listing, member_listing = listing.split('\n----------\n', 1)
        method = re.search(r'^Method = (.+)$', archive_listing, re.MULTILINE).group(1)
        blocks = int(re.search(r'^Blocks = (\d+)$', archive_listing, re.MULTILINE).group(1))
        assert method == 'Deflate64' and blocks == (1 if solid else 2), listing
        assert 'Solid = ' + ('+' if solid else '-') in archive_listing, listing
        members = [dict(line.split(' = ', 1) for line in record.splitlines() if ' = ' in line)
                   for record in re.split(r'\n\n+', member_listing.strip())]
        assert {member['Path'] for member in members} == set(entries), listing
        for member in members:
            entry = member['Path']
            assert int(member['Size']) == len(payloads[entry]), (name, entry)
            if payloads[entry]:
                assert member['Method'] == 'Deflate64', (name, entry)
            extracted = subprocess.run([SEVENZIP, 'e', '-so', str(archive), entry],
                                       check=True, capture_output=True).stdout
            assert extracted == payloads[entry], (name, entry)

        data = archive.read_bytes()
        streams, offset = [], 32
        for block in range(blocks):
            group = [member for member in members if member.get('Block') == str(block)]
            packed_size = int(group[0]['Packed Size'])
            expected = b''.join(payloads[member['Path']] for member in group)
            stream = {'offset': offset, 'size': packed_size, 'unpackedSize': len(expected),
                      'entries': [member['Path'] for member in group]}
            if 'long.bin' in stream['entries']:
                # offset 32、7zz の Packed Size で切り出し、通常 Deflate との非互換を確認する。
                assert offset == 32
                inflater = zlib.decompressobj(-15)
                try:
                    decoded = inflater.decompress(data[offset:offset + packed_size]) + inflater.flush()
                except zlib.error as error:
                    stream['rawDeflate'] = str(error)
                else:
                    assert decoded != expected, 'long.bin must require Deflate64 distances'
                    stream['rawDeflate'] = 'decoded bytes differ from the original'
            streams.append(stream)
            offset += packed_size
        # header 圧縮を無効化したため、全 packed stream の直後が next header。
        assert offset == 32 + int.from_bytes(data[12:20], 'little')
        encoded = base64.encodebytes(data)
        encoded_size += len(encoded)
        (root / (name + '.b64')).write_bytes(encoded)
        manifest['fixtures'].append({
            'file': name + '.b64', 'sha256': hashlib.sha256(data).hexdigest(),
            'method': method, 'solid': solid, 'blocks': blocks,
            'entries': [member['Path'] for member in members], 'packedStreams': streams,
            'arguments': [*options, 'ARCHIVE', *entries],
        })
        print(f'{name}: 7zz t / e -so OK; Method = {method}; Blocks = {blocks}', flush=True)
        for stream in streams:
            if 'rawDeflate' in stream:
                print(f"raw Deflate: {stream['rawDeflate']}", flush=True)
assert encoded_size < 400_000, encoded_size
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'base64 total: {encoded_size} bytes')
print(json.dumps(manifest, indent=2))
