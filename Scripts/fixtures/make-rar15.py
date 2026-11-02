#!/usr/bin/env python3
"""RAR13_FORMAT_SPECIFICATION.md §6 から作る小さな RAR 1.5 標本。"""

import argparse
import base64
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib


HF0 = (4, [0x8000, 0xC000, 0xE000, 0xF200, 0xF200, 0xF200, 0xF200, 0xF200, 0xFFFF],
       [0, 0, 0, 0, 0, 8, 16, 24, 33, 33, 33, 33, 33])
HF1 = (5, [0x2000, 0xC000, 0xE000, 0xF000, 0xF200, 0xF200, 0xF7E0, 0xFFFF],
       [0, 0, 0, 0, 0, 0, 4, 44, 60, 76, 80, 80, 127])
HF2 = (5, [0x1000, 0x2400, 0x8000, 0xC000, 0xFA00, 0xFFFF, 0xFFFF, 0xFFFF],
       [0, 0, 0, 0, 0, 0, 2, 7, 53, 117, 233, 0, 0])
HF3 = (6, [0x0800, 0x2400, 0xEE00, 0xFE80, 0xFFFF, 0xFFFF, 0xFFFF],
       [0, 0, 0, 0, 0, 0, 0, 2, 16, 218, 251, 0, 0])
HF4 = (8, [0xFF00, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF],
       [0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0])
SHORT_XOR = [0x00, 0xA0, 0xD0, 0xE0, 0xF0, 0xF8, 0xFC, 0xFE,
             0xFF, 0xC0, 0x80, 0x90, 0x98, 0x9C, 0xB0]
SHORT_LEN = [1, 3, 4, 4, 5, 6, 7, 8, 8, 4, 4, 5, 6, 6, 4, 0]
PHRASE = b"RAR15!\r\n"


def encoding(table):
    start, decisions, positions = table
    result = {}
    for field in range(0, 0x10000, 16):
        width, index = start, 0
        while decisions[index] <= field:
            width += 1
            index += 1
        base = decisions[index - 1] if index else 0
        code = (field - base) >> (16 - width)
        value = code + positions[width]
        result.setdefault(value, (field >> (16 - width), width))
    return result


ENCODINGS = {id(table): encoding(table) for table in [HF0, HF1, HF2, HF3, HF4]}


def correct(chars, places):
    for index in range(256):
        chars[index] = (chars[index] & 0xFF00) | (7 - index // 32)
    places[:] = [0] * 256
    for rank in range(6, -1, -1):
        places[rank] = (7 - rank) * 32


def promote(chars, places, place, threshold):
    while True:
        current = chars[place]
        new_place = places[current & 0xFF]
        places[current & 0xFF] += 1
        current += 1
        if current & 0xFF == threshold:
            correct(chars, places)
        else:
            break
    chars[place] = chars[new_place]
    chars[new_place] = current


class Bits:
    def __init__(self):
        self.data = bytearray()
        self.value = 0
        self.count = 0

    def put(self, value, width):
        assert width > 0 and 0 <= value < (1 << width)
        self.value = (self.value << width) | value
        self.count += width
        while self.count >= 8:
            self.count -= 8
            self.data.append((self.value >> self.count) & 0xFF)
        self.value &= (1 << self.count) - 1

    def number(self, value, table):
        code, width = ENCODINGS[id(table)][value]
        self.put(code, width)

    def finish(self):
        if self.count:
            self.put(0, 8 - self.count)
        assert self.count == 0
        return bytes(self.data)


class Encoder:
    def __init__(self):
        self.chset = [i << 8 for i in range(256)]
        self.places = [0] * 256
        self.chset_a = list(range(256))
        self.chset_b = [i << 8 for i in range(256)]
        self.places_b = [0] * 256
        correct(self.chset_b, self.places_b)
        self.chset_c = [((256 - i) & 0xFF) << 8 for i in range(256)]
        self.places_c = [0] * 256
        self.avr_plc = 0x3500
        self.avr_plc_b = 0
        self.avr_ln1 = 0
        self.nlzb = self.nhfb = 0x80
        self.num_huf = 0
        self.old_distances = [-1] * 4
        self.old_distance_pointer = 0
        self.last_distance = -1
        self.last_length = 0
        self.l_count = 0
        self.st_mode = 0
        self.flags_count = 0
        self.bits = Bits()
        self.flag_bits = []

    def start_file(self):
        self.bits = Bits()
        self.flags_count = 0
        self.flag_bits = []
        self.st_mode = self.l_count = 0

    def flags(self, desired):
        if not self.flags_count:
            assert not self.flag_bits
            self.flag_bits = desired + [1] * (8 - len(desired))
            target = sum(bit << (7 - index) for index, bit in enumerate(self.flag_bits))
            place = next(i for i, entry in enumerate(self.chset_c) if entry >> 8 == target)
            self.bits.number(place, HF2)
            promote(self.chset_c, self.places_c, place, 0)
            self.flags_count = 8
        assert self.flags_count >= len(desired), "fixture command crosses a flag-byte boundary"
        assert self.flag_bits[:len(desired)] == desired
        self.flag_bits = self.flag_bits[len(desired):]
        self.flags_count -= len(desired)

    def literal(self, value):
        assert not self.st_mode, "these small fixtures stop before StMode"
        self.flags([0, 1] if self.nlzb > self.nhfb else [1])
        assert self.num_huf < 16 or self.flags_count != 0
        place = next(i for i, entry in enumerate(self.chset) if entry >> 8 == value)
        if self.avr_plc > 0x75FF:
            table = HF4
        elif self.avr_plc > 0x5DFF:
            table = HF3
        elif self.avr_plc > 0x35FF:
            table = HF2
        elif self.avr_plc > 0x0DFF:
            table = HF1
        else:
            table = HF0
        self.bits.number(place, table)
        self.avr_plc += place
        self.avr_plc -= self.avr_plc >> 8
        self.nhfb += 16
        if self.nhfb > 0xFF:
            self.nhfb = 0x90
            self.nlzb >>= 1
        promote(self.chset, self.places, place, 0xA2)
        self.num_huf += 1

    def literals(self, data):
        for value in data:
            self.literal(value)

    def short_match(self, distance, length):
        assert 1 <= distance <= 256 and 2 <= length <= 10
        self.flags([0, 0])
        self.num_huf = self.l_count = 0
        length_code = length - 2
        assert self.avr_ln1 < 37
        width = SHORT_LEN[length_code]
        self.bits.put(SHORT_XOR[length_code] >> (8 - width), width)
        place = self.chset_a.index(distance - 1)
        self.bits.number(place, HF2)
        if place:
            self.chset_a[place], self.chset_a[place - 1] = self.chset_a[place - 1], self.chset_a[place]
        self.avr_ln1 += length_code
        self.avr_ln1 -= self.avr_ln1 >> 4
        self.old_distances[self.old_distance_pointer] = distance
        self.old_distance_pointer = (self.old_distance_pointer + 1) & 3
        self.last_distance, self.last_length = distance, length

    def finish_file(self):
        return self.bits.finish()


def header(kind, flags, fields):
    body = struct.pack('<BHH', kind, flags, len(fields) + 7) + fields
    return struct.pack('<H', zlib.crc32(body) & 0xFFFF) + body


def file_header(name, packed, unpacked, solid):
    fields = struct.pack('<IIBII BBHI', len(packed), len(unpacked), 2,
                         zlib.crc32(unpacked), 0, 15, 0x33, len(name), 0x20)
    return header(0x74, 0x8020 | (0x10 if solid else 0), fields + name)


def archive(members, solid=False):
    result = bytearray(b'Rar!\x1A\x07\x00')
    result += header(0x73, 0x0008 if solid else 0, bytes(6))
    for index, (name, expected, packed) in enumerate(members):
        result += file_header(name, packed, expected, solid=solid and index > 0)
        result += packed
    result += header(0x7B, 0, b'')
    return bytes(result)


def generate(unrar):
    normal_members = []
    for name, data in [(b'literals.txt', PHRASE), (b'match.txt', PHRASE + PHRASE)]:
        encoder = Encoder()
        encoder.start_file()
        encoder.literals(PHRASE)
        if len(data) > len(PHRASE):
            encoder.short_match(len(PHRASE), len(PHRASE))
        normal_members.append((name, data, encoder.finish_file()))

    encoder = Encoder()
    solid_members = []
    for index, name in enumerate([b'first.txt', b'second.txt']):
        encoder.start_file()
        if index == 0:
            encoder.literals(PHRASE)
        else:
            encoder.short_match(len(PHRASE), len(PHRASE))
        solid_members.append((name, PHRASE, encoder.finish_file()))

    archives = {}
    for name, members in [('normal', normal_members), ('solid', solid_members)]:
        data = archive(members, solid=name == 'solid')
        archives[name] = data
        with tempfile.TemporaryDirectory(prefix='kaitokit-rar15-') as temporary:
            root = Path(temporary)
            source = root / (name + '.rar')
            source.write_bytes(data)
            subprocess.run([unrar, 't', '-idq', str(source)], check=True)
            destination = root / 'out'
            destination.mkdir()
            subprocess.run([unrar, 'x', '-idq', str(source), str(destination) + '/'], check=True)
            for member, expected, _ in members:
                actual = (destination / member.decode()).read_bytes()
                assert actual == expected, (name, member, actual, expected)
    return archives


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--unrar', default='unrar')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[2] / 'Tests/Fixtures/rar15')
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)
    for name, data in generate(arguments.unrar).items():
        (arguments.output / (name + '.rar.b64')).write_text(base64.b64encode(data).decode() + '\n')
        print(name, hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    main()
