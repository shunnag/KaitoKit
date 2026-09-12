#!/usr/bin/env python3
# Ch.08 / Ch.42 の数式から作る独立 writer。復号器や他実装のソースは利用しない。
import argparse
import itertools
import json
from pathlib import Path
import random

ROOT = Path(__file__).resolve().parents[2]


class Bits:
    def __init__(self):
        self.data = bytearray()
        self.pending = self.width = 0

    def bit(self, value):
        self.pending |= value << self.width
        self.width += 1
        if self.width == 8:
            self.align()

    def align(self):
        if self.width:
            self.data.append(self.pending)
        self.pending = self.width = 0

    def p2(self, value):
        word = value + 1
        for _ in range(word.bit_count() - 1):
            self.bit(1)
        self.bit(0)
        for j in range(word.bit_length()):
            self.bit((word >> j) & 1)


class Intervals:
    def __init__(self):
        self.width = 0xffffffff
        self.decisions = []

    def select(self, start, frequency, total):
        quotient = self.width // total
        assert quotient and frequency
        self.width = quotient * frequency
        octets = 0
        while self.width < 0x1000000:
            self.width <<= 8
            octets += 1
        self.decisions.append((quotient * start, octets))

    def finish(self):
        # 最終区間内の code=0 から逆算し、正規化で流入する octet を決める。
        code = 0
        groups = []
        for delta, octets in reversed(self.decisions):
            groups.append((code & ((1 << (8 * octets)) - 1)).to_bytes(octets, 'big'))
            code = (code >> (8 * octets)) + delta
            assert code <= 0xffffffff
        return code.to_bytes(4, 'big') + b''.join(reversed(groups))


def sorted_column(source, st4):
    n = len(source)
    if st4:
        order = sorted(range(n), key=lambda i: tuple(source[(i - j) % n] for j in range(1, 5)))
        return bytes(source[i] for i in order), order.index(n - 1)
    order = sorted(range(n), key=lambda i: source[i:] + source[:i])
    return bytes(source[(i - 1) % n] for i in order), order.index(0)


def body(column, fancy, shifts=(2, 3, 4, 2, 3, 4), limits=(64, 64, 256)):
    coder = Intervals()
    weights = {}
    vectors = {}
    ranking = list(range(256))
    scores = [0] * 256
    selected_bytes = []
    previous_byte = previous_width = v_history = h_history = 0

    def binary(bit, a, sa, b=None, sb=None):
        wa = weights.get(a, 2048)
        wb = weights.get(b, 2048)
        weight = wa if b is None else (wa + wb) // 2
        coder.select(weight if bit else 0, 4096 - weight if bit else weight, 4096)
        weights[a] = wa - (wa >> sa) if bit else wa + ((4096 - wa) >> sa)
        if b is not None:
            weights[b] = wb - (wb >> sb) if bit else wb + ((4096 - wb) >> sb)

    for byte, group in itertools.groupby(column):
        length = sum(1 for _ in group)
        value = (ranking.index(byte) - 1) % 256
        cls = min(value, 3)
        keys = [('global',), ('byte', previous_byte), ('history', h_history % 4, v_history)]
        contributions = [vectors.setdefault(key, [1] * 4 if i == 0 else [0] * 4) for i, key in enumerate(keys)]
        frequencies = [sum(v[i] for v in contributions) for i in range(4)]
        coder.select(sum(frequencies[:cls]), frequencies[cls], sum(frequencies))
        for i, vector in enumerate(contributions):
            vector[cls] += 2
            if sum(vector) > limits[i]:
                vector[:] = [(f + (i == 0)) // 2 for f in vector]
        if cls == 3:
            leaf = value - 1
            k = leaf.bit_length() - 2
            for width in range(k + (k < 6)):
                binary(int(width < k), ('ba', width), shifts[0], ('bb', previous_width, width), shifts[1])
            node = 1
            for shift in reversed(range(k + 1)):
                bit = (leaf >> shift) & 1
                binary(bit, ('tree', k, node), shifts[2])
                node = node * 2 + bit
            previous_width = k
        ranking.remove(byte)
        ranking.insert(0, byte)
        if fancy:
            scores[byte] = (scores[byte] + 0x4000) & 0xffffffff
            t = len(selected_bytes)
            for lag in range(12):
                if t < 1 << lag:
                    continue
                old = selected_bytes[t - (1 << lag)]
                scores[old] = (scores[old] - (0x3801 if lag == 0 else 0x800 >> lag)) & 0xffffffff
                if old != byte:
                    p = ranking.index(old)
                    while p < 255 and scores[ranking[p + 1]] > scores[old]:
                        ranking[p], ranking[p + 1] = ranking[p + 1], ranking[p]
                        p += 1
        selected_bytes.append(byte)
        q = length.bit_length() - 1
        assert q < 24
        for width in range(q + 1):
            binary(int(width < q), ('ra', cls, h_history, width), shifts[3], ('rb', byte, width), shifts[4])
        for j in range(q):
            binary((length >> (q - 1 - j)) & 1, ('payload', q, j), shifts[5])
        v_history = (v_history * 4 + cls) % 256
        h_history = (h_history * 2) % 16 + int(q > 1)
        previous_byte = byte
    return b'\0' + coder.finish()


def stream(blocks, fancy, st4, exponents=(6, 6, 8), shifts=(2, 3, 4, 2, 3, 4)):
    writer = Bits()
    writer.bit(st4)
    writer.bit(fancy)
    for value in (*exponents, *shifts):
        writer.p2(value)
    writer.align()
    for raw, source in blocks:
        writer.bit(0)
        writer.p2(len(source))
        writer.bit(raw)
        if not raw:
            column, primary = sorted_column(source, st4)
            writer.p2(primary)
        writer.align()
        writer.data.extend(source if raw else body(column, fancy, shifts))
    writer.bit(1)
    writer.align()
    return bytes(writer.data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    old = json.loads((ROOT / 'Tests/Fixtures/stuffit/slice4-vectors.json').read_text())
    output = []
    for vector in old:
        if vector['method'] != 106:
            continue
        fancy, st4 = int(vector['name'].split('fancy')[1][0]), int(vector['name'][-1])
        source = bytes.fromhex(vector['output_hex'])
        encoded = stream([(False, source)], fancy, st4, (4, 5, 6))
        output.append(dict(name=vector['name'] + '-native', method=106, input_hex=encoded.hex(), output_hex=source.hex()))
    rng = random.Random(9406)
    source = bytes(rng.randrange(256) for _ in range(5000))
    for fancy, st4 in itertools.product(range(2), repeat=2):
        # 2048 run を超える履歴、反復 context、空 raw と複数 block を一緒に通す。
        blocks = [(True, b''), (False, source), (False, b'banana\0mississippi ' * 60), (True, b'raw'), (False, b'A' * 513)]
        encoded = stream(blocks, fancy, st4, (0x7fffffff, 0, 30), (1, 2, 15, 2, 3, 31))
        output.append(dict(name=f'iron-native-history-fancy{fancy}-st4{st4}', method=106, input_hex=encoded.hex(), output_hex=b''.join(s for _, s in blocks).hex()))
    path = ROOT / 'Tests/Fixtures/stuffit/slice4-iron-native-vectors.json'
    generated = json.dumps(output, indent=2) + '\n'
    if args.check:
        assert path.read_text() == generated
        print('Iron native vector 再生成一致: 8 本')
    else:
        path.write_text(generated)
        print(path.relative_to(ROOT))


if __name__ == '__main__':
    main()
