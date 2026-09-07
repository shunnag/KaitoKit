#!/usr/bin/env python3
"""シード書庫から決定論的な破損入力を生成する。"""

from __future__ import annotations

import argparse
import random
import struct
from pathlib import Path


DEFAULT_SEED = 20260906
DEFAULT_COUNT = 200


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate deterministic archive mutants."
    )
    parser.add_argument("seeds", nargs="+", type=Path, help="seed archive(s)")
    parser.add_argument("-o", "--output", required=True, type=Path)
    parser.add_argument("--count", type=int, default=DEFAULT_COUNT)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument(
        "--require-payload-ranges",
        action="store_true",
        help="fail when any seed has no recognized compressed payload range",
    )
    return parser.parse_args()


def mutate_flip(data: bytes, rng: random.Random) -> bytes:
    result = bytearray(data)
    changes = rng.randint(1, min(16, max(1, len(result))))
    for _ in range(changes):
        position = rng.randrange(len(result))
        result[position] ^= 1 << rng.randrange(8)
    return bytes(result)


def mutate_overwrite(data: bytes, rng: random.Random) -> bytes:
    result = bytearray(data)
    width = rng.randint(1, min(32, len(result)))
    position = rng.randrange(len(result) - width + 1)
    value = rng.randrange(256)
    result[position : position + width] = bytes([value]) * width
    return bytes(result)


def mutate_truncate(data: bytes, rng: random.Random) -> bytes:
    # 0 バイトと末尾 1 バイト欠落も定期的に含める。
    choices = [0, max(0, len(data) - 1), rng.randrange(len(data))]
    return data[: rng.choice(choices)]


def mutate_insert(data: bytes, rng: random.Random) -> bytes:
    position = rng.randrange(len(data) + 1)
    width = rng.randint(1, 64)
    inserted = bytes(rng.randrange(256) for _ in range(width))
    return data[:position] + inserted + data[position:]


def _zip64_values(
    extra: bytes,
    uncompressed_size: int,
    compressed_size: int,
    local_offset: int,
) -> tuple[int, int]:
    cursor = 0
    while cursor + 4 <= len(extra):
        field_id, field_size = struct.unpack_from("<HH", extra, cursor)
        cursor += 4
        end = cursor + field_size
        if end > len(extra):
            break
        if field_id == 0x0001:
            values = extra[cursor:end]
            value_cursor = 0

            def next_uint64() -> int | None:
                nonlocal value_cursor
                if value_cursor + 8 > len(values):
                    return None
                value = struct.unpack_from("<Q", values, value_cursor)[0]
                value_cursor += 8
                return value

            if uncompressed_size == 0xFFFFFFFF and next_uint64() is None:
                return compressed_size, local_offset
            if compressed_size == 0xFFFFFFFF:
                resolved = next_uint64()
                if resolved is None:
                    return compressed_size, local_offset
                compressed_size = resolved
            if local_offset == 0xFFFFFFFF:
                resolved = next_uint64()
                if resolved is None:
                    return compressed_size, local_offset
                local_offset = resolved
            return compressed_size, local_offset
        cursor = end
    return compressed_size, local_offset


def zip_payload_ranges(data: bytes) -> list[tuple[int, int]]:
    """Return compressed member ranges from ordinary ZIP/CBZ seeds."""
    if len(data) < 30:
        return []

    # ZIP offsets are relative to the first local header. Derive that base for
    # self-extracting seeds from the last internally consistent ZIP32 EOCD.
    archive_base = 0
    eocd = data.rfind(b"PK\x05\x06")
    if eocd >= 0 and eocd + 22 <= len(data):
        comment_size = struct.unpack_from("<H", data, eocd + 20)[0]
        directory_size = struct.unpack_from("<I", data, eocd + 12)[0]
        directory_offset = struct.unpack_from("<I", data, eocd + 16)[0]
        if eocd + 22 + comment_size <= len(data):
            candidate = eocd - directory_size - directory_offset
            if candidate >= 0:
                archive_base = candidate

    supported_methods = {8, 9, 12, 14, 99}  # Deflate, Deflate64, BZip2, LZMA, AES.
    ranges: list[tuple[int, int]] = []
    cursor = 0
    while True:
        central = data.find(b"PK\x01\x02", cursor)
        if central < 0:
            break
        cursor = central + 4
        if central + 46 > len(data):
            continue
        method = struct.unpack_from("<H", data, central + 10)[0]
        compressed_size = struct.unpack_from("<I", data, central + 20)[0]
        uncompressed_size = struct.unpack_from("<I", data, central + 24)[0]
        name_size, extra_size, comment_size = struct.unpack_from(
            "<HHH", data, central + 28
        )
        local_offset = struct.unpack_from("<I", data, central + 42)[0]
        record_end = central + 46 + name_size + extra_size + comment_size
        if record_end > len(data):
            continue
        extra_start = central + 46 + name_size
        compressed_size, local_offset = _zip64_values(
            data[extra_start : extra_start + extra_size],
            uncompressed_size,
            compressed_size,
            local_offset,
        )
        if method not in supported_methods or compressed_size in (0, 0xFFFFFFFF):
            continue

        local = archive_base + local_offset
        if local < 0 or local + 30 > len(data) or data[local : local + 4] != b"PK\x03\x04":
            # Markerless ZIP64 end records can make the ZIP32 base derivation
            # unsuitable even though central local offsets remain direct.
            local = local_offset
        if local < 0 or local + 30 > len(data) or data[local : local + 4] != b"PK\x03\x04":
            continue
        local_name_size, local_extra_size = struct.unpack_from("<HH", data, local + 26)
        start = local + 30 + local_name_size + local_extra_size
        end = start + compressed_size
        if start < end <= len(data):
            ranges.append((start, end))
    return ranges


def seven_zip_payload_ranges(data: bytes) -> list[tuple[int, int]]:
    """Return the packed-stream area preceding a 7z next header."""
    signature = data.find(b"7z\xbc\xaf'\x1c", 0, min(len(data), 1_048_576))
    if signature < 0 or signature + 32 > len(data):
        return []
    next_header_offset = struct.unpack_from("<Q", data, signature + 12)[0]
    start = signature + 32
    end = start + next_header_offset
    if start < end <= len(data):
        return [(start, end)]
    return []


def compressed_payload_ranges(data: bytes) -> list[tuple[int, int]]:
    return zip_payload_ranges(data) + seven_zip_payload_ranges(data)


def mutate_payload_flip(data: bytes, rng: random.Random) -> bytes:
    ranges = compressed_payload_ranges(data)
    if not ranges:
        return mutate_flip(data, rng)
    start, end = rng.choice(ranges)
    result = bytearray(data)
    changes = rng.randint(1, min(16, end - start))
    for _ in range(changes):
        position = rng.randrange(start, end)
        result[position] ^= 1 << rng.randrange(8)
    return bytes(result)


def mutate_payload_overwrite(data: bytes, rng: random.Random) -> bytes:
    ranges = compressed_payload_ranges(data)
    if not ranges:
        return mutate_overwrite(data, rng)
    start, end = rng.choice(ranges)
    width = rng.randint(1, min(32, end - start))
    position = rng.randrange(start, end - width + 1)
    value = rng.randrange(256)
    result = bytearray(data)
    result[position : position + width] = bytes([value]) * width
    return bytes(result)


def max_field_offsets(data: bytes) -> list[tuple[int, int, bytes]]:
    """書庫で長さになりやすい位置と形式固有の長さ欄を返す。"""
    candidates: list[tuple[int, int, bytes]] = []
    for offset in (0, 2, 4, 6, 8, 12, 16, 18, 22, 24, 28, 32, 42, 48):
        for width in (2, 4, 8):
            if offset + width <= len(data):
                candidates.append((offset, width, b"\xff" * width))

    # tar の size と mtime は ASCII 8 進数なので、構文として有効な最大値にする。
    if len(data) >= 148:
        candidates.append((124, 12, b"7" * 11 + b"\x00"))
        candidates.append((136, 12, b"7" * 11 + b"\x00"))
    return candidates


def mutate_max_length(data: bytes, rng: random.Random) -> bytes:
    result = bytearray(data)
    # tar はチェックサムも更新し、長さ検証まで到達する mutant にする。
    if len(result) >= 512 and result[257:262] == b"ustar":
        offset = rng.choice((124, 136))
        result[offset : offset + 12] = b"7" * 11 + b"\x00"
        result[148:156] = b" " * 8
        checksum = sum(result[:512])
        checksum_text = f"{checksum:06o}".encode("ascii")
        if len(checksum_text) == 6:
            result[148:156] = checksum_text + b"\x00 "
        return bytes(result)

    candidates = max_field_offsets(data)
    if candidates:
        offset, width, replacement = rng.choice(candidates)
        result[offset : offset + width] = replacement
    else:
        result[:] = b"\xff" * len(result)
    return bytes(result)


MUTATORS = (
    ("flip", mutate_flip),
    ("overwrite", mutate_overwrite),
    ("payload-flip", mutate_payload_flip),
    ("payload-overwrite", mutate_payload_overwrite),
    ("truncate", mutate_truncate),
    ("insert", mutate_insert),
    ("maxlen", mutate_max_length),
)


def main() -> int:
    args = arguments()
    if args.count <= 0:
        raise SystemExit("--count must be greater than zero")

    seeds: list[tuple[Path, bytes]] = []
    for path in args.seeds:
        data = path.read_bytes()
        if not data:
            raise SystemExit(f"seed is empty: {path}")
        if args.require_payload_ranges and not compressed_payload_ranges(data):
            raise SystemExit(f"seed has no recognized compressed payload range: {path}")
        seeds.append((path, data))

    args.output.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    for index in range(args.count):
        seed_index = index % len(seeds)
        path, data = seeds[seed_index]
        kind, mutator = MUTATORS[index % len(MUTATORS)]
        mutant = mutator(data, rng)
        name = f"{index:04d}-{seed_index:02d}-{path.name}.{kind}"
        (args.output / name).write_bytes(mutant)

    print(f"generated {args.count} mutants from {len(seeds)} seed(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
