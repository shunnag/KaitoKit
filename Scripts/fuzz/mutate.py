#!/usr/bin/env python3
"""シード書庫から決定論的な破損入力を生成する。"""

from __future__ import annotations

import argparse
import random
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
