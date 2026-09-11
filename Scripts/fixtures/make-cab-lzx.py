#!/usr/bin/env python3
"""Microsoft 仕様から作る CAB/LZX 標本。全標本を cabextract で照合する。"""

import argparse
from array import array
from collections import Counter
import base64
import hashlib
import heapq
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tempfile


FRAME = 32768
SLOTS = {15: 30, 16: 32, 17: 34, 18: 36, 19: 38, 20: 42, 21: 50}
FOOTER = [max(0, min(17, (slot // 2) - 1)) for slot in range(50)]
BASE = [0]
for width in FOOTER[:-1]:
    BASE.append(BASE[-1] + (1 << width))


class Bits:
    def __init__(self):
        self.data = bytearray()
        self.word = 0
        self.used = 0

    def put(self, value, width):
        assert 0 <= value < (1 << width) if width else value == 0
        while width:
            count = min(16 - self.used, width)
            self.word = (self.word << count) | ((value >> (width - count)) & ((1 << count) - 1))
            self.used += count
            width -= count
            if self.used == 16:
                self.data.extend(struct.pack('<H', self.word))
                self.word = self.used = 0

    def align(self, force=False):
        if self.used or force:
            self.put(0, 16 - self.used)

    def raw(self, data):
        assert self.used == 0
        self.data.extend(data)

    def finish(self):
        self.align()
        result = bytes(self.data)
        self.data.clear()
        return result


def lengths(frequencies, count, maximum=16):
    """頻度順の木を作り、上限超過時は頻度順の完全な平衡木に制限する。"""
    weights = {s: f for s, f in frequencies.items() if f}
    if not weights:
        weights = {0: 1, 1: 1}
    if len(weights) == 1:
        weights[next(s for s in range(count) if s not in weights)] = 1
    heap = [(f, s, s) for s, f in sorted(weights.items())]
    heapq.heapify(heap)
    serial = count
    while len(heap) > 1:
        a, b = heapq.heappop(heap), heapq.heappop(heap)
        heapq.heappush(heap, (a[0] + b[0], serial, (a[2], b[2])))
        serial += 1
    result = [0] * count
    pending = [(heap[0][2], 0)]
    while pending:
        node, depth = pending.pop()
        if isinstance(node, int):
            result[node] = depth
        else:
            pending.extend((child, depth + 1) for child in node)
    if max(result) > maximum:
        ordered = sorted(weights, key=lambda s: (-weights[s], s))
        depth = len(ordered).bit_length() - 1
        short = (1 << (depth + 1)) - len(ordered)
        for i, symbol in enumerate(ordered):
            result[symbol] = depth if i < short else depth + 1
    assert max(result) <= maximum
    assert sum(1 << (maximum - x) for x in result if x) == (1 << maximum)
    return result


def codes(path_lengths):
    counts = Counter(path_lengths)
    counts[0] = 0
    next_code = {}
    value = 0
    for width in range(1, 17):
        value = (value + counts[width - 1]) << 1
        next_code[width] = value
    result = {}
    for symbol, width in enumerate(path_lengths):
        if width:
            result[symbol] = (next_code[width], width)
            next_code[width] += 1
    return result


def write_lengths(bits, previous, current, coverage):
    tokens = []
    index = 0
    while index < len(current):
        run = 1
        while index + run < len(current) and current[index + run] == current[index]:
            run += 1
        if current[index] == 0 and run >= 4:
            count = min(run, 51 if run >= 20 else 19)
            symbol, extra, width = (18, count - 20, 5) if count >= 20 else (17, count - 4, 4)
            tokens.append((symbol, extra, width, None))
        elif run >= 4:
            count = min(run, 5)
            tokens.append((19, count - 4, 1, (previous[index] - current[index]) % 17))
        else:
            count = 1
            tokens.append(((previous[index] - current[index]) % 17, 0, 0, None))
        index += count
    frequencies = Counter(t[0] for t in tokens)
    frequencies.update(t[3] for t in tokens if t[3] is not None)
    pre = lengths(frequencies, 20, 15)
    book = codes(pre)
    for width in pre:
        bits.put(width, 4)
    for symbol, extra, width, second in tokens:
        coverage['pretree'].add(symbol)
        bits.put(*book[symbol])
        bits.put(extra, width)
        if second is not None:
            bits.put(*book[second])


def e8_preprocess(data, size):
    result = bytearray(data)
    if not size:
        return bytes(result)
    for start in range(0, min(len(result), 0x40000000), FRAME):
        index, end = start, min(start + FRAME, len(result)) - 10
        while index < end:
            if result[index] == 0xE8:
                displacement = struct.unpack_from('<i', result, index + 1)[0]
                target = index + displacement
                if 0 <= target < size + index:
                    if target >= size:
                        target = displacement - size
                    struct.pack_into('<I', result, index + 1, target & 0xFFFFFFFF)
                index += 5
            else:
                index += 1
    return bytes(result)


class Encoder:
    def __init__(self, plain, window_bits, e8=0, forced=None):
        assert window_bits in SLOTS
        self.data = e8_preprocess(plain, e8)
        self.window_bits = window_bits
        self.window = (1 << window_bits) - 3
        self.e8 = e8
        self.forced = forced or {}
        self.head = [-1] * 65536
        self.chain = array('i', [-1]) * len(plain)
        self.repeated = [1, 1, 1]
        self.coverage = {key: set() for key in ('slots', 'lengths', 'pretree', 'aligned', 'main_tree_bits', 'raw_header_padding')}

    def remember(self, start, end):
        for pos in range(start, min(end, len(self.data) - 1)):
            key = (self.data[pos] << 8) | self.data[pos + 1]
            self.chain[pos] = self.head[key]
            self.head[key] = pos

    def match(self, offset, length, mode=None):
        if mode is None:
            mode = self.repeated.index(offset) if offset in self.repeated else -1
        if mode >= 0:
            assert self.repeated[mode] == offset
            slot, footer = mode, 0
            self.repeated[0], self.repeated[mode] = self.repeated[mode], self.repeated[0]
        else:
            formatted = offset + 2
            slot = max(s for s in range(SLOTS[self.window_bits]) if BASE[s] <= formatted)
            footer = formatted - BASE[slot]
            self.repeated = [offset, self.repeated[0], self.repeated[1]]
        self.coverage['slots'].add(slot)
        self.coverage['lengths'].add(length)
        return (256 + slot * 8 + min(length - 2, 7), length, slot, footer)

    def tokenize(self, start, end, literal_only=False):
        tokens = []
        pos = start
        force_points = sorted(p for p in self.forced if start <= p < end)
        force_index = 0
        while pos < end:
            limit = min(257, end - pos, FRAME - pos % FRAME)
            if force_index < len(force_points) and force_points[force_index] > pos:
                limit = min(limit, force_points[force_index] - pos)
            mode = None
            if pos in self.forced:
                offset, length, mode = self.forced[pos]
                assert 2 <= length <= limit and offset <= min(pos, self.window)
                assert all(self.data[pos + i] == self.data[pos + i - offset] for i in range(length))
                force_index += 1
            else:
                offset, length = 0, 1
                if not literal_only and limit >= 2:
                    key = (self.data[pos] << 8) | self.data[pos + 1]
                    candidate = self.head[key]
                    attempts = 0
                    while candidate >= max(0, pos - self.window) and attempts < 64:
                        count = 2
                        while count < limit and self.data[candidate + count] == self.data[pos + count]:
                            count += 1
                        if count > length:
                            offset, length = pos - candidate, count
                        if count == limit:
                            break
                        candidate = self.chain[candidate]
                        attempts += 1
            tokens.append(self.match(offset, length, mode) if length >= 2 else (self.data[pos], 1, 0, 0))
            self.remember(pos, pos + length)
            pos += length
        return tokens

    def encode(self, blocks, singleton=False, empty_length=False, empty_aligned=False):
        bits = Bits()
        bits.put(int(self.e8 != 0), 1)
        if self.e8:
            bits.put(self.e8 >> 16, 16)
            bits.put(self.e8 & 65535, 16)
        previous_main = [0] * (256 + 8 * SLOTS[self.window_bits])
        previous_length = [0] * 249
        frames, pos = [], 0
        for block in blocks:
            kind, size = block['type'], block['size']
            assert kind in (1, 2, 3) and 0 < size <= 0xFFFFFF
            end = pos + size
            assert end <= len(self.data)
            bits.put(kind, 3)
            bits.put(size, 24)
            if kind == 3:
                self.coverage['raw_header_padding'].add(16 - bits.used)
                bits.align(force=True)
                bits.raw(struct.pack('<III', *self.repeated))
                self.remember(pos, end)
                while pos < end:
                    count = min(end - pos, FRAME - pos % FRAME)
                    bits.raw(self.data[pos:pos + count])
                    pos += count
                    if pos == end and size & 1:
                        bits.raw(b'\0')
                    if pos % FRAME == 0:
                        frames.append((bits.finish(), FRAME))
                continue
            tokens = self.tokenize(pos, end, block.get('literal_only', False))
            main = lengths(Counter(t[0] for t in tokens), len(previous_main))
            length = lengths(Counter(t[1] - 9 for t in tokens if t[1] >= 9), 249)
            aligned = lengths(Counter(t[3] & 7 for t in tokens if t[0] >= 256 and FOOTER[t[2]] >= 3), 8, 7)
            if singleton:
                assert all(t[0] == 65 for t in tokens)
                main = [0] * len(main)
                main[65] = 1
            if empty_length:
                assert all(t[1] < 9 for t in tokens)
                length = [0] * 249
            if empty_aligned:
                assert all(t[0] < 256 or FOOTER[t[2]] < 3 for t in tokens)
                aligned = [0] * 8
            self.coverage['main_tree_bits'].update(main)
            main_codes, length_codes, aligned_codes = codes(main), codes(length), codes(aligned)
            if kind == 2:
                for width in aligned:
                    bits.put(width, 3)
            write_lengths(bits, previous_main[:256], main[:256], self.coverage)
            write_lengths(bits, previous_main[256:], main[256:], self.coverage)
            write_lengths(bits, previous_length, length, self.coverage)
            previous_main, previous_length = main, length
            for symbol, count, slot, footer in tokens:
                bits.put(*main_codes[symbol])
                if symbol >= 256:
                    if count >= 9:
                        bits.put(*length_codes[count - 9])
                    width = FOOTER[slot]
                    if kind == 2 and width >= 3:
                        bits.put(footer >> 3, width - 3)
                        bits.put(*aligned_codes[footer & 7])
                        self.coverage['aligned'].add(footer & 7)
                    else:
                        bits.put(footer, width)
                pos += count
                if pos % FRAME == 0:
                    frames.append((bits.finish(), FRAME))
            assert pos == end
        assert pos == len(self.data)
        if pos % FRAME:
            frames.append((bits.finish(), pos % FRAME))
        assert not bits.data and bits.used == 0
        return frames


def checksum(data, output_size):
    value = len(data) | (output_size << 16)
    end = len(data) & ~3
    for (word,) in struct.iter_unpack('<I', data[:end]):
        value ^= word
    return value ^ int.from_bytes(data[end:], 'big')


def cabinet(folders):
    file_table = bytearray()
    for index, folder in enumerate(folders):
        offset = 0
        for name, payload in folder['files']:
            file_table.extend(struct.pack('<IIHHHH', len(payload), offset, index, 0x5D2C, 0, 0xA0))
            file_table.extend(name.replace('/', '\\').encode('utf-8') + b'\0')
            offset += len(payload)
    data_offset = 36 + 8 * len(folders) + len(file_table)
    folder_table, data = bytearray(), bytearray()
    for folder in folders:
        frames = folder['frames']
        folder_table.extend(struct.pack('<IHH', data_offset + len(data), len(frames), 3 | (folder['window_bits'] << 8)))
        for packed, size in frames:
            assert len(packed) <= 65535
            data.extend(struct.pack('<IHH', checksum(packed, size), len(packed), size))
            data.extend(packed)
    header = struct.pack('<4sIIIIIBBHHHHH', b'MSCF', 0, data_offset + len(data), 0,
                         36 + 8 * len(folders), 0, 3, 1, len(folders),
                         sum(len(f['files']) for f in folders), 0, 0, 0)
    return header + folder_table + file_table + data


def folder(window_bits, data, blocks, files=None, e8=0, forced=None, **options):
    encoder = Encoder(data, window_bits, e8, forced)
    frames = encoder.encode(blocks, **options)
    return {'window_bits': window_bits, 'blocks': blocks, 'e8': e8, 'frames': frames,
            'files': files if files is not None else [('payload.bin', data)],
            'coverage': {key: sorted(value) for key, value in encoder.coverage.items()}}


def verify(cab_path, folders, oracle):
    with tempfile.TemporaryDirectory(prefix='kaito-cab-oracle-') as temp:
        completed = subprocess.run([oracle, '-q', '-d', temp, str(cab_path)],
                                   capture_output=True, text=True, timeout=120)
        if completed.returncode:
            raise RuntimeError(f'{cab_path.name}: cabextract exit {completed.returncode}: {completed.stdout}{completed.stderr}')
        expected = {name: payload for f in folders for name, payload in f['files']}
        actual = {p.relative_to(temp).as_posix(): p.read_bytes() for p in Path(temp).rglob('*') if p.is_file()}
        if expected != actual:
            differences = [name for name in expected.keys() | actual.keys() if expected.get(name) != actual.get(name)]
            raise RuntimeError(f'{cab_path.name}: cabextract payload mismatch: {differences}')
    print(f'cabextract OK {cab_path.name}: {len(expected)} files, {sum(map(len, expected.values()))} bytes', flush=True)


def fixed_cases():
    yield 'empty-unused-length', [folder(15, b'AB' * 16,
        [{'type': 2, 'size': 32, 'literal_only': True}], empty_length=True)]
    data, forced, repeated = bytearray(range(256)), {}, [1, 1, 1]
    for index, (offset, mode) in enumerate([(17, -1), (53, -1), (119, -1), (0, 0),
                                           (0, 1), (0, 2), (0, 1), (0, 2), (0, 0)]):
        if mode >= 0:
            offset = repeated[mode]
            repeated[0], repeated[mode] = repeated[mode], repeated[0]
        else:
            repeated = [offset, repeated[0], repeated[1]]
        length = [2, 8, 9, 257][index % 4]
        forced[len(data)] = (offset, length, mode)
        for _ in range(length):
            data.append(data[-offset])
    yield 'repeated-offsets', [folder(15, bytes(data), [{'type': 3, 'size': 256},
        {'type': 2, 'size': len(data) - 256}], forced=forced)]
    alignments = []
    for size in range(2, 18):
        data = (b'AB' * 9)[:size] + b'raw'
        alignments.append(folder(15, data, [{'type': 1, 'size': size, 'literal_only': True},
            {'type': 3, 'size': 3}], [(f'padding-{size}.bin', data)]))
    assert {p for f in alignments for p in f['coverage']['raw_header_padding']} == set(range(1, 17))
    yield 'raw-alignment', alignments
    data = (b'KaitoKit CAB LZX: project-owned payload.\n' + bytes(range(256))) * 360
    split = 40000
    yield 'verbatim-w15', [folder(15, data, [{'type': 1, 'size': split}, {'type': 1, 'size': len(data) - split}],
        [('first.txt', data[:12000]), ('empty', b''), ('sub/middle.bin', data[12000:70000]), ('last.bin', data[70000:])])]
    data = bytes(range(256)) * 512
    yield 'aligned-w16', [folder(16, data, [{'type': 2, 'size': FRAME}, {'type': 2, 'size': len(data) - FRAME}])]
    data = (b'raw odd block\n' * 1000)[:8195]
    yield 'raw-w17', [folder(17, data, [{'type': 3, 'size': 8193}, {'type': 1, 'size': 1}, {'type': 3, 'size': 1}],
        [('raw.bin', data[:8193]), ('tail.bin', data[8193:]), ('empty', b'')])]
    data = b'ABCDE' * 15000
    yield 'mixed-blocks', [folder(15, data, [{'type': 1, 'size': 1}, {'type': 3, 'size': 5},
        {'type': 2, 'size': FRAME - 6}, {'type': 3, 'size': 256}, {'type': 1, 'size': len(data) - FRAME - 256}])]
    # 全スロットを強制指定し、反復オフセットの選択を貪欲探索から独立して保証する。
    data = b'A' * ((1 << 21) + 4096)
    forced = {}
    pos = 1 << 21
    for slot in range(3, 50):
        offset = BASE[slot] - 2 + ((1 << FOOTER[slot]) - 1 if slot & 1 else 0)
        forced[pos] = (offset, [2, 8, 9, 257][slot % 4], -1)
        pos += forced[pos][1]
    repeated = [forced[p][0] for p in sorted(forced)[-3:]][::-1]
    for mode in [0, 1, 2]:
        forced[pos] = (repeated[mode], 8, mode)
        repeated[0], repeated[mode] = repeated[mode], repeated[0]
        pos += 8
    for low in range(8):
        forced[pos] = (14 + low, 8, -1)
        pos += 8
    data = b'A' * (pos + 6)
    yield 'slots-w21', [folder(21, data, [{'type': 1, 'size': 1 << 21}, {'type': 2, 'size': len(data) - (1 << 21)}], forced=forced)]
    for size in [1, 65536, 0x12345678]:
        data = bytearray(b'\x90' * (2 * FRAME + 37))
        for start in range(0, len(data), FRAME):
            for index, value in [(0, 5), (7, -7), (17, size - 1), (29, -start - 29),
                                 (45, -start - 46), (80, 0x7FFFFFFF), (FRAME - 11, -10), (FRAME - 10, 3)]:
                if start + index + 5 <= len(data):
                    data[start + index] = 0xE8
                    struct.pack_into('<i', data, start + index + 1, value)
        yield f'e8-{size:08x}', [folder(17, bytes(data), [{'type': 1, 'size': FRAME + 1},
            {'type': 2, 'size': len(data) - FRAME - 1}], e8=size)]
    yield 'multi-folder', [folder(15, b'small\n', [{'type': 3, 'size': 6}], [('a.txt', b'small\n')]),
        folder(21, b'B' * 70000, [{'type': 2, 'size': 70000}], [('b.bin', b'B' * 70000), ('empty', b'')]),
        folder(16, b'\xE8\0\0\0\0' * 17, [{'type': 1, 'size': 85}], [('e8-disabled.bin', b'\xE8\0\0\0\0' * 17)])]
    for count in [17, 20]:
        frequencies = [1, 1]
        while len(frequencies) < count:
            frequencies.append(sum(frequencies[-2:]))
        data = b''.join(bytes([symbol]) * amount for symbol, amount in enumerate(frequencies))
        yield f'huffman-{count}', [folder(15, data, [{'type': 1, 'size': len(data), 'literal_only': True}])]


def random_cases(seed, count):
    rng = random.Random(seed)
    for case in range(count):
        folders = []
        if case == 0:
            data = b'raw odd block\n' * 5000
            folders.append(folder(17, data, [{'type': 3, 'size': 65537}, {'type': 2, 'size': len(data) - 65537}],
                                  [('raw-cross-frame.bin', data)]))
        for f in range(rng.randint(1, 3)):
            size = rng.randint(80000, 230000)
            pattern = rng.randbytes(rng.randint(64, 3000))
            data = bytearray((pattern * ((size + len(pattern) - 1) // len(pattern)))[:size])
            for _ in range(50):
                index = rng.randrange(size - 100)
                data[index:index + 100] = rng.randbytes(100)
            blocks, remaining = [], size
            while remaining:
                amount = min(remaining, rng.randint(1, 60000))
                blocks.append({'type': rng.choice([1, 1, 2, 2, 3]), 'size': amount})
                remaining -= amount
            files, pos = [], 0
            for i in range(4):
                end = size if i == 3 else pos + rng.randint(0, (size - pos) // 2)
                files.append((f'folder{f}/file{i}.bin', bytes(data[pos:end])))
                pos = end
            files.append((f'folder{f}/empty', b''))
            folders.append(folder(rng.choice([15, 16, 17, 21]), bytes(data), blocks, files,
                                  e8=rng.choice([0, 0, 1000000])))
        yield f'random-{case:02d}', folders


def probes(oracle, directory):
    results = {}
    for name, options, payload in [('singleton-main-length1', {'singleton': True}, b'A' * 32),
                                   ('empty-unused-length', {'empty_length': True}, b'AB' * 16),
                                   ('empty-unused-aligned', {'empty_aligned': True}, b'AB' * 16)]:
        f = folder(15, payload, [{'type': 2, 'size': len(payload), 'literal_only': True}], **options)
        path = directory / (name + '.cab')
        path.write_bytes(cabinet([f]))
        try:
            verify(path, [f], oracle)
            results[name] = 'accepted'
        except RuntimeError as error:
            results[name] = 'rejected'
            print(f'cabextract probe {name}: {error}', flush=True)
        path.unlink()
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('Tests/Fixtures/cab-lzx'), help='出力先')
    parser.add_argument('--random', type=int, default=0, metavar='COUNT', help='固定 seed のランダム書庫数')
    parser.add_argument('--seed', type=int, default=20260912)
    parser.add_argument('--base64', action='store_true', help='CAB の代わりに 40 KB 以下の .cab.b64 を保存')
    parser.add_argument('--cabextract', default=shutil.which('cabextract') or '/opt/homebrew/bin/cabextract')
    parser.add_argument('--probes', action='store_true', help='単一要素の木と未使用の空 length tree を実測')
    parser.add_argument('--benchmark', action='store_true', help='10 MiB の性能測定用書庫を生成')
    args = parser.parse_args()
    if args.random < 0:
        parser.error('--random は 0 以上の書庫数です。')
    if not Path(args.cabextract).is_file():
        parser.error('cabextract が必要です。未検証の標本は保存しません。')
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = {'seed': args.seed, 'oracle': subprocess.check_output([args.cabextract, '--version'], text=True).strip(),
                'fixtures': []}
    if args.probes:
        manifest['probes'] = probes(args.cabextract, args.output)
    cases = random_cases(args.seed, args.random) if args.random else fixed_cases()
    if args.benchmark:
        data = (bytes(range(256)) + b'KaitoKit benchmark\n') * 40000
        data = (data * 2)[:10 * 1024 * 1024]
        cases = [('benchmark', [folder(21, data, [{'type': 1, 'size': len(data)}])])]
    for name, folders in cases:
        encoded = cabinet(folders)
        # 検証用の一時ファイルだけを先に書き、受理・一致した標本だけを出力先へ保存する。
        with tempfile.TemporaryDirectory(prefix='kaito-cab-encode-') as temp:
            cab_path = Path(temp) / (name + '.cab')
            cab_path.write_bytes(encoded)
            verify(cab_path, folders, args.cabextract)
        extension = '.cab.b64' if args.base64 else '.cab'
        result = base64.encodebytes(encoded) if args.base64 else encoded
        if args.base64 and len(result) > 40000:
            raise RuntimeError(f'{name}: base64 fixture exceeds 40 KB ({len(result)})')
        (args.output / (name + extension)).write_bytes(result)
        record = {'name': name, 'archive': name + extension, 'cab_sha256': hashlib.sha256(encoded).hexdigest(),
                  'cab_bytes': len(encoded), 'folders': [], 'files': []}
        for index, f in enumerate(folders):
            record['folders'].append({key: f[key] for key in ('window_bits', 'blocks', 'e8', 'coverage')})
            record['folders'][-1]['frame_sizes'] = [s for _, s in f['frames']]
            record['files'].extend({'name': n, 'size': len(p), 'sha256': hashlib.sha256(p).hexdigest(), 'folder': index}
                                   for n, p in f['files'])
        manifest['fixtures'].append(record)
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    print(f'verified {len(manifest["fixtures"])} archives', flush=True)


if __name__ == '__main__':
    main()
