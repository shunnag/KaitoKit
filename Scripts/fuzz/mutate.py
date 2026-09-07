#!/usr/bin/env python3
"""シード書庫から決定論的な破損入力を生成する。"""

from __future__ import annotations

import argparse
import random
import struct
from pathlib import Path


DEFAULT_SEED = 20260906
DEFAULT_COUNT = 200
MAX_EMBEDDED_SIGNATURE_OFFSET = 1 * 1_024 * 1_024
MAX_LOCATOR_RECORDS = 1_000_000
MAX_LHA_EXTENSION_RECORDS = 65_536
MAX_LHA_SFX_CANDIDATES = 64


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


def _embedded_signature_offset(data: bytes, signature: bytes) -> int:
    search_end = min(
        len(data),
        MAX_EMBEDDED_SIGNATURE_OFFSET + len(signature),
    )
    offset = data.find(signature, 0, search_end)
    if 0 <= offset <= MAX_EMBEDDED_SIGNATURE_OFFSET:
        return offset
    return -1


def rar4_payload_ranges(data: bytes) -> list[tuple[int, int]]:
    """Return bounded compressed FILE_HEAD data ranges from a RAR4 archive."""
    signature = b"Rar!\x1a\x07\x00"
    signature_offset = _embedded_signature_offset(data, signature)
    if signature_offset < 0:
        return []

    ranges: list[tuple[int, int]] = []
    cursor = signature_offset + len(signature)
    records = 0
    while cursor < len(data) and records < MAX_LOCATOR_RECORDS:
        records += 1
        if len(data) - cursor < 7:
            break

        header_type = data[cursor + 2]
        flags = struct.unpack_from("<H", data, cursor + 3)[0]
        header_size = struct.unpack_from("<H", data, cursor + 5)[0]
        if header_size < 7 or header_size > len(data) - cursor:
            break
        header_end = cursor + header_size

        data_size = 0
        if flags & 0x8000:
            if header_size < 11:
                break
            data_size = struct.unpack_from("<I", data, cursor + 7)[0]

        if header_type == 0x74:  # FILE_HEAD
            if header_size < 32 or not flags & 0x8000:
                break
            packed_size = struct.unpack_from("<I", data, cursor + 7)[0]
            if flags & 0x0100:  # LARGE
                if header_size < 40:
                    break
                packed_size |= struct.unpack_from("<I", data, cursor + 32)[0] << 32
            data_size = packed_size
            method = data[cursor + 25]
            payload_end = header_end + packed_size
            if payload_end > len(data):
                break
            if 0x31 <= method <= 0x35 and packed_size > 0:
                ranges.append((header_end, payload_end))

        next_cursor = header_end + data_size
        if next_cursor <= cursor or next_cursor > len(data):
            break
        cursor = next_cursor

        # Subsequent RAR3 headers are AES-CBC records rather than FILE_HEAD
        # envelopes, so there is no plaintext packed range to locate here.
        if header_type == 0x73 and flags & 0x0080:
            break
        if header_type == 0x7B:  # ENDARC_HEAD
            break

    return ranges


def _rar5_vint(data: bytes, cursor: int, end: int) -> tuple[int, int] | None:
    value = 0
    for byte_index in range(10):
        if cursor >= end:
            return None
        byte = data[cursor]
        cursor += 1
        shift = byte_index * 7
        if shift < 64:
            useful_bits = min(7, 64 - shift)
            value |= (byte & ((1 << useful_bits) - 1)) << shift
        if byte & 0x80 == 0:
            return value, cursor
    return None


def _rar5_file_method(data: bytes, start: int, end: int) -> int | None:
    file_flags_result = _rar5_vint(data, start, end)
    if file_flags_result is None:
        return None
    file_flags, cursor = file_flags_result
    for _ in range(2):  # unpacked size and attributes
        result = _rar5_vint(data, cursor, end)
        if result is None:
            return None
        _, cursor = result
    if file_flags & 0x0002:  # Unix mtime
        if end - cursor < 4:
            return None
        cursor += 4
    if file_flags & 0x0004:  # data CRC32
        if end - cursor < 4:
            return None
        cursor += 4
    compression_result = _rar5_vint(data, cursor, end)
    if compression_result is None:
        return None
    compression, _ = compression_result
    return (compression >> 7) & 0x07


def rar5_payload_ranges(data: bytes) -> list[tuple[int, int]]:
    """Return bounded compressed file data areas from a RAR5 archive."""
    signature = b"Rar!\x1a\x07\x01\x00"
    signature_offset = _embedded_signature_offset(data, signature)
    if signature_offset < 0:
        return []

    ranges: list[tuple[int, int]] = []
    cursor = signature_offset + len(signature)
    records = 0
    while cursor < len(data) and records < MAX_LOCATOR_RECORDS:
        records += 1
        if len(data) - cursor < 5:
            break

        header_size_start = cursor + 4
        header_size_result = _rar5_vint(data, header_size_start, len(data))
        if header_size_result is None:
            break
        header_size, body_start = header_size_result
        if body_start - header_size_start > 3 or header_size < 2:
            break
        if header_size > len(data) - body_start:
            break
        body_end = body_start + header_size

        type_result = _rar5_vint(data, body_start, body_end)
        if type_result is None:
            break
        header_type, body_cursor = type_result
        flags_result = _rar5_vint(data, body_cursor, body_end)
        if flags_result is None:
            break
        flags, body_cursor = flags_result

        extra_size = 0
        if flags & 0x0001:
            result = _rar5_vint(data, body_cursor, body_end)
            if result is None:
                break
            extra_size, body_cursor = result
        data_size = 0
        if flags & 0x0002:
            result = _rar5_vint(data, body_cursor, body_end)
            if result is None:
                break
            data_size, body_cursor = result
        if extra_size > body_end - body_cursor:
            break
        specific_end = body_end - extra_size
        data_end = body_end + data_size
        if data_end <= cursor or data_end > len(data):
            break

        if header_type == 2 and data_size > 0:
            method = _rar5_file_method(data, body_cursor, specific_end)
            if method is not None and 1 <= method <= 5:
                ranges.append((body_end, data_end))

        cursor = data_end
        # Type 4 switches the remaining header stream to encrypted blocks.
        if header_type == 4 or header_type == 5:
            break

    return ranges


def _lha_method(data: bytes, start: int) -> bytes | None:
    if start < 0 or len(data) - start < 7:
        return None
    method = data[start + 2 : start + 7]
    if method[0] != 0x2D or method[4] != 0x2D:
        return None
    if method[1:3] not in (b"lh", b"lz", b"pm"):
        return None
    return method


def _lha_extension_chain(
    data: bytes,
    cursor: int,
    first_size: int,
    size_width: int,
    upper_bound: int,
) -> tuple[int, int | None] | None:
    current_size = first_size
    packed_size64: int | None = None
    records = 0
    envelope_size = 1 + size_width
    while current_size != 0:
        if records >= MAX_LHA_EXTENSION_RECORDS:
            return None
        if current_size < envelope_size:
            return None
        if cursor > upper_bound or current_size > upper_bound - cursor:
            return None
        record_end = cursor + current_size
        data_start = cursor + 1
        data_end = record_end - size_width
        if data[cursor] == 0x42:
            if data_end - data_start != 16:
                return None
            packed_size64 = struct.unpack_from("<Q", data, data_start)[0]
        if size_width == 2:
            current_size = struct.unpack_from("<H", data, data_end)[0]
        else:
            current_size = struct.unpack_from("<I", data, data_end)[0]
        cursor = record_end
        records += 1

    return cursor, packed_size64


def _lha_level1_extensions(
    data: bytes,
    cursor: int,
    first_size: int,
    skip_size: int,
) -> tuple[int, int, int | None] | None:
    current_size = first_size
    packed_size64: int | None = None
    total_size = 0
    records = 0
    while current_size != 0:
        if records >= MAX_LHA_EXTENSION_RECORDS or current_size < 3:
            return None
        if current_size > skip_size - total_size:
            return None
        if cursor > len(data) or current_size > len(data) - cursor:
            return None
        record_size = current_size
        record_end = cursor + current_size
        if data[cursor] == 0x42:
            if record_end - 2 - (cursor + 1) != 16:
                return None
            packed_size64 = struct.unpack_from("<Q", data, cursor + 1)[0]
        current_size = struct.unpack_from("<H", data, record_end - 2)[0]
        cursor = record_end
        total_size += record_size
        records += 1
    return cursor, total_size, packed_size64


def _lha_member_layout(
    data: bytes,
    start: int,
) -> tuple[bytes, int, int] | None:
    method = _lha_method(data, start)
    if method is None or len(data) - start < 21:
        return None
    level = data[start + 20]
    packed_size = struct.unpack_from("<I", data, start + 7)[0]

    if level in (0, 1):
        header_size = data[start] + 2
        minimum = 24 if level == 0 else 27
        if header_size < minimum or header_size > len(data) - start:
            return None
        header_end = start + header_size
        if sum(data[start + 2 : header_end]) & 0xFF != data[start + 1]:
            return None
        if level == 0:
            data_start = header_end
        else:
            first_extension_size = struct.unpack_from("<H", data, header_end - 2)[0]
            extension = _lha_level1_extensions(
                data,
                header_end,
                first_extension_size,
                packed_size,
            )
            if extension is None:
                return None
            data_start, extension_size, packed_size64 = extension
            if packed_size64 is None:
                if extension_size > packed_size:
                    return None
                packed_size -= extension_size
            else:
                packed_size = packed_size64
    elif level == 2:
        header_size = struct.unpack_from("<H", data, start)[0]
        if header_size < 26 or header_size > len(data) - start:
            return None
        declared_end = start + header_size
        upper_bound = declared_end
        if data[start + 23] == 0x4B and len(data) - declared_end >= 2:
            upper_bound += 2
        first_extension_size = struct.unpack_from("<H", data, start + 24)[0]
        extension = _lha_extension_chain(
            data,
            start + 26,
            first_extension_size,
            2,
            upper_bound,
        )
        if extension is None:
            return None
        extension_end, packed_size64 = extension
        if extension_end > declared_end:
            if (
                extension_end != declared_end + 2
                or data[start + 23] != 0x4B
                or data[declared_end:extension_end] != b"\x00\x00"
            ):
                return None
            data_start = extension_end
        else:
            data_start = declared_end
        if packed_size64 is not None:
            packed_size = packed_size64
    elif level == 3:
        if len(data) - start < 32 or struct.unpack_from("<H", data, start)[0] != 4:
            return None
        header_size = struct.unpack_from("<I", data, start + 24)[0]
        if header_size < 32 or header_size > len(data) - start:
            return None
        header_end = start + header_size
        first_extension_size = struct.unpack_from("<I", data, start + 28)[0]
        extension = _lha_extension_chain(
            data,
            start + 32,
            first_extension_size,
            4,
            header_end,
        )
        if extension is None:
            return None
        _, packed_size64 = extension
        data_start = header_end
        if packed_size64 is not None:
            packed_size = packed_size64
    else:
        return None

    data_end = data_start + packed_size
    if data_end < data_start or data_end > len(data):
        return None
    return method, data_start, data_end


def _lha_ranges_at(data: bytes, start: int) -> tuple[list[tuple[int, int]], bool]:
    compressed_methods = {
        b"-lh1-",
        b"-lh4-",
        b"-lh5-",
        b"-lh6-",
        b"-lh7-",
        b"-lhx-",
        b"-lz5-",
        b"-lzs-",
    }
    ranges: list[tuple[int, int]] = []
    cursor = start
    records = 0
    while cursor < len(data) and records < MAX_LOCATOR_RECORDS:
        if data[cursor] == 0:
            return ranges, records > 0
        layout = _lha_member_layout(data, cursor)
        if layout is None:
            return ranges, records > 0
        method, data_start, data_end = layout
        if method in compressed_methods and data_end > data_start:
            ranges.append((data_start, data_end))
        if data_end <= cursor:
            return ranges, records > 0
        cursor = data_end
        records += 1
    return ranges, records > 0


def lha_payload_ranges(data: bytes) -> list[tuple[int, int]]:
    """Return bounded compressed member ranges from native and SFX LHA files."""
    candidates = [0]
    search_end = min(len(data), MAX_EMBEDDED_SIGNATURE_OFFSET + 7)
    cursor = 2
    while (
        cursor < search_end
        and len(candidates) - 1 < MAX_LHA_SFX_CANDIDATES
    ):
        marker = data.find(b"-", cursor, search_end)
        if marker < 0:
            break
        candidate = marker - 2
        if candidate > 0 and _lha_method(data, candidate) is not None:
            candidates.append(candidate)
        cursor = marker + 1

    seen: set[int] = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        ranges, parsed_member = _lha_ranges_at(data, candidate)
        if parsed_member:
            return ranges
    return []


def compressed_payload_ranges(data: bytes) -> list[tuple[int, int]]:
    return (
        zip_payload_ranges(data)
        + seven_zip_payload_ranges(data)
        + rar4_payload_ranges(data)
        + rar5_payload_ranges(data)
        + lha_payload_ranges(data)
    )


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
