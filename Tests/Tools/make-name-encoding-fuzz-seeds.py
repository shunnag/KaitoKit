#!/usr/bin/env python3
"""自作の多言語名と不正 byte 列を、既存の敵対的入力ハーネス用 ZIP に包む。"""

import argparse
import csv
from collections import defaultdict
from pathlib import Path
import struct
import zlib


def archive(names):
    body = bytearray()
    central = bytearray()
    payload = b"name encoding seed\n"
    crc = zlib.crc32(payload)
    for name in names:
        offset = len(body)
        # UTF-8 宣言を付けず、生のファイル名で自動判定の入口を通す。
        body.extend(struct.pack("<I5H3I2H", 0x04034B50, 20, 0, 0, 0, 0,
                                crc, len(payload), len(payload), len(name), 0))
        body.extend(name)
        body.extend(payload)
        central.extend(struct.pack("<I6H3I5H2I", 0x02014B50, 20, 20, 0, 0, 0, 0,
                                   crc, len(payload), len(payload), len(name), 0,
                                   0, 0, 0, 0, offset))
        central.extend(name)
    offset = len(body)
    body.extend(central)
    body.extend(struct.pack("<I4H2IH", 0x06054B50, 0, 0, len(names), len(names),
                            len(central), offset, 0))
    return body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out_dir", type=Path)
    args = parser.parse_args()
    fixture = Path(__file__).resolve().parents[1] / "Fixtures/encoding/names-multilingual.tsv"
    groups = defaultdict(list)
    with fixture.open(encoding="utf-8") as source:
        for row in csv.DictReader(source, delimiter="\t"):
            groups[(row["lang"], row["truth_iana"])].append(bytes.fromhex(row["hex"]))
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for (language, encoding), names in sorted(groups.items()):
        (args.out_dir / f"{language}-{encoding}.zip").write_bytes(archive(names))
    # 全 byte・切断された多 byte 形・上限に近い名前を含める。
    malformed = [bytes(range(256)), b"\x81\x30\x81", b"\x8f\xa1",
                 b"\xff" * 4096, b"a" * 4096 + b"\x81", b"a\x00b\xff"]
    (args.out_dir / "malformed-names.zip").write_bytes(archive(malformed))
    print(f"{len(groups) + 1} seeds")


if __name__ == "__main__":
    main()
