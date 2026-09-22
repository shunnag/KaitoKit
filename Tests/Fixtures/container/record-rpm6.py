#!/usr/bin/env python3
"""黒箱の出力を保存する。実装 source は読まない。"""
import base64
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys


def run(args, data=None):
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    if result.stderr:
        sys.stderr.buffer.write(result.stderr)
    return result.stdout


def sha(data):
    return hashlib.sha256(data).hexdigest()


def header(blob):
    def word(at):
        return struct.unpack_from('>I', blob, at)[0]
    end = 112 + word(104) * 16 + word(108)
    main = (end + 7) // 8 * 8
    store = main + 16 + word(main + 8) * 16
    tags = {}
    for at in range(main + 16, store, 16):
        tag, kind, offset, count = struct.unpack_from('>4I', blob, at)
        at = store + offset
        if kind in (3, 4, 5):
            tags[tag] = list(struct.unpack_from('>' + {3: 'H', 4: 'I', 5: 'Q'}[kind] * count, blob, at))
        elif kind in (6, 8, 9):
            tags[tag] = [s.decode('utf-8') for s in blob[at:].split(b'\0', count)[:count]]
    return tags, store + word(main + 12)


def newc_rows(data):
    rows = []
    at = 0
    while True:
        assert data[at:at + 6] == b'070701'
        fields = [int(data[pos:pos + 8], 16) for pos in range(at + 6, at + 110, 8)]
        size, namesize = fields[6], fields[11]
        name = data[at + 110:at + 110 + namesize - 1].decode('utf-8')
        body = (at + 110 + namesize + 3) // 4 * 4
        end = (body + size + 3) // 4 * 4
        assert end <= len(data)
        if name == 'TRAILER!!!':
            assert not any(data[end:])
            return rows
        rows.append(dict(name=name, mode=oct(fields[1]), nlink=fields[4], ino=fields[0],
                         dev=(fields[7] << 32) | fields[8], size=size, sha256=sha(data[body:body + size])))
        at = end


def stripped_rows(data, tags):
    groups = {}
    for i, mode in enumerate(tags[1030]):
        if mode & 0o170000 == 0o100000 and not tags[1037][i] & 0x40:
            groups.setdefault((tags[1095][i], tags[1096][i]), []).append(i)
    rows = []
    at = 0
    while data[at:at + 6] == b'07070X':
        i = int(data[at + 6:at + 14], 16)
        assert data[at + 14:at + 16] == b'\0\0'
        mode = tags[1030][i] & 0o170000
        assert not tags[1037][i] & 0x40
        size = tags.get(5008, tags.get(1028))[i] if mode in (0o100000, 0o120000) else 0
        if mode == 0o100000 and i != max(groups[(tags[1095][i], tags[1096][i])]):
            size = 0
        body = at + 16
        end = (body + size + 3) // 4 * 4
        assert end <= len(data) and not any(data[body + size:end])
        name = tags[1118][tags[1116][i]] + tags[1117][i]
        rows.append(dict(index=i, name=name, headerOffset=at, dataOffset=body, size=size,
                         sha256=sha(data[body:body + size])))
        at = end
    assert newc_rows(data[at:]) == []
    return dict(rows=rows, trailerOffset=at, trailerBytes=len(data) - at, payloadSize=len(data))


work, destination = map(Path, sys.argv[1:])
query = '[%{FILENAMES} %{FILEMODES:octal} %{LONGFILESIZES} %{FILEINODES} %{FILEDEVICES} %{FILELINKTOS} %{FILEFLAGS} %{FILEDIGESTS}\n]'
manifest = dict(generator=run(['rpmbuild', '--version']).decode().strip() + ' / 自作 rpm-stripped.spec',
                query=query, packages={})
packages = [f'rpm-stripped-{version}-{codec}' for version, codec in [('v6', 'zstd'), ('v6', 'gzip'), ('v4', 'gzip')]]
packages.append('rpm-v6')
for name in packages:
    package = work / (name + '.rpm')
    if name == 'rpm-v6':
        package.write_bytes(base64.b64decode((destination / (name + '.rpm.b64')).read_bytes()))
    blob = package.read_bytes()
    assert len(blob) < 40_000
    tags, payload_start = header(blob)
    rpm_query = ['rpm', '--dbpath', str(work / 'rpmdb'), '--define', f'_keyringpath {work / "keys"}', '-qp', '--qf']
    query_output = run(rpm_query + [query, str(package)]).decode('utf-8')
    scalar_output = run(rpm_query + ['%{RPMFORMAT} %{PAYLOADCOMPRESSOR} %{PAYLOADFLAGS} %{FILEDIGESTALGO}\n',
                                    str(package)]).decode('utf-8')
    cpio = run(['rpm2cpio', str(package)])
    listing = run(['bsdtar', '-tvf', '-'], cpio).decode('utf-8')
    rows = newc_rows(cpio)
    extracted = {}
    for row in rows:
        if int(row['mode'], 8) & 0o170000 == 0o100000:
            data = run(['bsdtar', '-xOf', '-', row['name']], cpio)
            extracted[row['name']] = dict(size=len(data), sha256=sha(data))
            assert len(data) == row['size'] and sha(data) == row['sha256']
    entry = dict(size=len(blob), sha256=sha(blob), rpmQuery=query_output, bsdtarListing=listing,
                 scalarQuery=scalar_output, payloadRows=rows, bsdtarExtracted=extracted)
    if tags.get(5114) == [6]:
        codec = tags[1125][0]
        payload = run([{'gzip': 'gzip', 'zstd': 'zstd'}[codec], '-dc'], blob[payload_start:])
        entry['stripped'] = stripped_rows(payload, tags)
        assert [(r['size'], r['sha256']) for r in entry['stripped']['rows']] == [(r['size'], r['sha256']) for r in rows]
        assert ['.' + r['name'] for r in entry['stripped']['rows']] == [r['name'] for r in rows]
    manifest['packages'][name] = entry
    if name != 'rpm-v6':
        (destination / (name + '.rpm.b64')).write_bytes(base64.encodebytes(blob))
    print(f'{name}.rpm: {len(blob)} bytes, {len(rows)} entries, SHA-256 {sha(blob)}')
    print(listing, end='')
(destination / 'rpm-stripped-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
