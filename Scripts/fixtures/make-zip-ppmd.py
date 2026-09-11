#!/usr/bin/env python3
"""ZIP PPMd fixture を決定的な入力から生成する（cooViewer-th30）。

Python 標準ライブラリと 7zz の圧縮機能だけを使用する。
乱数 fixture は一様乱数の接頭部と反復する末尾を持ち、Store への切替を防ぐ。
期待 SHA-256 は圧縮前の入力から計算する。各 .b64 は 40 KiB 以下とする。
"""

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tempfile
import zipfile
import zlib

SEED = 0x50504D49


def payload(kind, size):
    rng = random.Random(SEED)
    if kind == "random":
        return bytes(rng.getrandbits(8) for _ in range(size))
    if kind == "repetitive":
        return (b"KaitoKit PPMd var.I revision 1\n" * (size // 29 + 1))[:size]
    result = bytearray()
    while len(result) < size:
        if kind == "text":
            result.extend((f"record {rng.randrange(1000):04d}: "
                           f"the archive contains {rng.choice(['green', 'blue', 'red'])} "
                           f"pages and {rng.randrange(32)} pictures.\n").encode())
        elif kind == "binary":
            result.extend(struct.pack("<IHH8s", len(result) // 16,
                                      rng.randrange(32), rng.randrange(8), b"KAITOKIT"))
        else:
            raise ValueError(kind)
    return bytes(result[:size])


def packed_entries(archive):
    result = []
    with zipfile.ZipFile(io.BytesIO(archive)) as reader:
        for entry in reader.infolist():
            start = entry.header_offset
            name_len, extra_len = struct.unpack_from("<HH", archive, start + 26)
            start += 30 + name_len + extra_len
            packed = archive[start:start + entry.compress_size]
            word = struct.unpack_from("<H", packed)[0] if entry.compress_type == 98 else None
            result.append((entry, packed, word))
    return result


def write_zip(entries):
    # 空の PPMd entry も扱える最小の非暗号化 ZIP を組み立てる。
    result = bytearray()
    central = bytearray()
    for name, method, data, packed in entries:
        name = name.encode()
        crc = zlib.crc32(data)
        offset = len(result)
        result.extend(struct.pack("<IHHHHHIIIHH", 0x04034B50, 63, 0, method,
                                  0, 0x2821, crc, len(packed), len(data), len(name), 0))
        result.extend(name)
        result.extend(packed)
        central.extend(struct.pack("<I6H3I5H2I", 0x02014B50, 63, 63, 0, method,
                                   0, 0x2821, crc, len(packed), len(data),
                                   len(name), 0, 0, 0, 0, 0, offset))
        central.extend(name)
    start = len(result)
    result.extend(central)
    result.extend(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries),
                              len(entries), len(central), start, 0))
    return bytes(result)


def compress(seven_zip, directory, label, data, options, entry_name="payload.bin"):
    source = directory / entry_name
    source.write_bytes(data)
    os.utime(source, (946684800, 946684800))
    archive = directory / (label + ".zip")
    subprocess.run([seven_zip, "a", "-tzip", "-mm=PPMd" + options, "-bd", "-bb0", "-y",
                    str(archive), entry_name], cwd=directory, check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return archive.read_bytes()


def save(output, name, archive, inputs):
    encoded = base64.encodebytes(archive)
    if len(encoded) > 40 * 1024:
        raise ValueError(f"{name}: base64 exceeds 40 KiB ({len(encoded)})")
    (output / (name + ".zip.b64")).write_bytes(encoded)
    rows = []
    for entry, packed, word in packed_entries(archive):
        data = inputs[entry.filename]
        if entry.file_size != len(data) or entry.CRC != zlib.crc32(data):
            raise ValueError("ZIP metadata disagrees with input")
        row = dict(name=entry.filename, size=len(data), crc32=f"{entry.CRC:08x}",
                   sha256=hashlib.sha256(data).hexdigest(), method=entry.compress_type)
        if word is not None:
            row.update(order=(word & 15) + 1, memMB=((word >> 4) & 255) + 1,
                       restore=(word >> 12) & 3)
        rows.append(row)
    print(json.dumps(dict(fixture=name, base64Bytes=len(encoded), entries=rows), ensure_ascii=False))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parents[2] / "Tests/Fixtures/zip-ppmd")
    parser.add_argument("--seven-zip", default=shutil.which("7zz"), help="7zz バイナリのパス")
    args = parser.parse_args()
    if not args.seven_zip:
        parser.error("7zz が見つかりません")
    args.output.mkdir(parents=True, exist_ok=True)
    text = payload("text", 32 * 1024)
    binary = payload("binary", 32 * 1024) * 8
    random_data = payload("random", 12 * 1024) * 2 + payload("repetitive", 32 * 1024)
    fixtures = [
        ("text-o8-default", text, "", 8, 0),
        ("text-o2-mem1m", text, ":o=2:mem=1m", 2, 0),
        ("text-o16-mem1m", text, ":o=16:mem=1m", 16, 0),
        ("binary-o6-mem4m", binary, ":o=6:mem=4m", 6, 0),
        ("random-o16-mem1m-restart", random_data, ":o=16:mem=1m:a=0", 16, 0),
        ("random-o16-mem1m-cutoff", random_data, ":o=16:mem=1m:a=1", 16, 1),
    ]
    manifest = {}
    with tempfile.TemporaryDirectory(prefix="kaitokit-zip-ppmd-") as temporary:
        directory = Path(temporary)
        for name, data, options, order, restore in fixtures:
            archive = compress(args.seven_zip, directory, name, data, options)
            entries = packed_entries(archive)
            if len(entries) != 1 or entries[0][0].compress_type != 98:
                raise ValueError(f"{name}: 7zz selected Store instead of PPMd")
            word = entries[0][2]
            if (word & 15) + 1 != order or (word >> 12) & 3 != restore:
                raise ValueError(f"{name}: unexpected PPMd parameters {word:04x}")
            expected_memory = 4 if name.startswith("binary") else 1
            if options and ((word >> 4) & 255) + 1 != expected_memory:
                raise ValueError(f"{name}: unexpected dictionary size")
            manifest[name] = save(args.output, name, archive, {"payload.bin": data})
        empty = compress(args.seven_zip, directory, "empty-probe", b"", ":o=8:mem=1m", "empty.bin")
        print("7zz empty entry method:", packed_entries(empty)[0][0].compress_type)
        ppmd = packed_entries(compress(args.seven_zip, directory, "mixed-text", text,
                                      ":o=8:mem=1m", "text.txt"))[0][1]
        stored = b"stored alongside PPMd\n"
        entries = [("stored.txt", 0, stored, stored), ("text.txt", 98, text, ppmd),
                   ("empty-stored.bin", 0, b"", b""),
                   ("empty-ppmd.bin", 98, b"", b"\x07\x00\x00\x00\x00\x00")]
        manifest["mixed"] = save(args.output, "mixed", write_zip(entries),
                                 {name: data for name, _, data, _ in entries})
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
