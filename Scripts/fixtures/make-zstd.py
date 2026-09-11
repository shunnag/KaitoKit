#!/usr/bin/env python3
"""RFC 8878 decoder の fixture を生成する（cooViewer-c1vj.3）。

Python 標準ライブラリと zstd CLI だけで生成し、zstd / 7zz をブラックボックスとして照合する。
実装ソースや外部ライブラリは参照しない。固定 fixture の各 .b64 は 40,000 バイト以下。
--matrix はテスト時に 80 通りの圧縮データと元入力を一時ディレクトリへ出力する。
"""

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tarfile
import tempfile
import zlib


ROOT = Path(__file__).resolve().parents[2]
SEED = 8878


def payload(kind, size):
    rng = random.Random(SEED)
    if kind == "empty":
        return b""
    if kind == "one":
        return b"Z"
    if kind == "random":
        return rng.randbytes(size)
    if kind == "repetitive":
        return (b"KaitoKit Zstandard RFC 8878\n" * (size // 27 + 1))[:size]
    if kind == "zeros":
        return bytes(size)
    result = bytearray()
    while len(result) < size:
        if kind == "text":
            result.extend((f"record {rng.randrange(256):03d}: "
                           f"the {rng.choice(['green', 'blue', 'red', 'white'])} archive "
                           f"contains {rng.randrange(16)} pictures and text.\n").encode())
        elif kind == "binary":
            result.extend(struct.pack("<IHH8s", len(result) // 16,
                                      rng.randrange(32), rng.randrange(8), b"KAITOKIT"))
        elif kind == "mixed":
            result.extend(rng.randbytes(1024))
            result.extend(b"compressed mixed section\n" * 128)
            result.extend(bytes(range(256)) * 4)
        elif kind == "reuse":
            result.extend((b"KaitoKit text archive RFC8878 " * 2)[:31])
            result.append(rng.randrange(8))
        else:
            raise ValueError(kind)
    return bytes(result[:size])


def compress(zstd, directory, data, options):
    source = directory / "input.bin"
    source.write_bytes(data)
    return subprocess.run([zstd, "-q", "-c", *options, str(source)], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def inspect_frames(data):
    # RFC の frame / block / literals header のみを読む。圧縮データは復号しない。
    cursor = 0
    sizes = []
    features = set()
    while cursor < len(data):
        magic = int.from_bytes(data[cursor:cursor + 4], "little")
        cursor += 4
        if 0x184D2A50 <= magic <= 0x184D2A5F:
            size = int.from_bytes(data[cursor:cursor + 4], "little")
            cursor += 4 + size
            features.add("skippable")
            continue
        assert magic == 0xFD2FB528
        descriptor = data[cursor]
        cursor += 1
        single = bool(descriptor & 32)
        features.add("single-segment" if single else "window-descriptor")
        if not single:
            value = data[cursor]
            base = 1 << (10 + (value >> 3))
            features.add(f"window-{base + (base >> 3) * (value & 7)}")
            cursor += 1
        dictionary_bytes = [0, 1, 2, 4][descriptor & 3]
        if dictionary_bytes:
            features.add("dictionary")
        cursor += dictionary_bytes
        size_bytes = [int(single), 2, 4, 8][descriptor >> 6]
        size = int.from_bytes(data[cursor:cursor + size_bytes], "little") if size_bytes else None
        if size_bytes == 2:
            size += 256
        sizes.append(size)
        cursor += size_bytes
        while True:
            block = int.from_bytes(data[cursor:cursor + 3], "little")
            cursor += 3
            kind = (block >> 1) & 3
            count = block >> 3
            features.add(["raw", "rle", "compressed", "reserved"][kind])
            if kind == 2:
                first = data[cursor]
                literals = first & 3
                form = (first >> 2) & 3
                features.add(["raw-literals", "rle-literals", "huffman", "treeless"][literals])
                if literals < 2:
                    n = [1, 2, 1, 3][form]
                    value = int.from_bytes(data[cursor:cursor + n], "little")
                    literal_size = value >> (3 if n == 1 else 4)
                    packed_size = 1 if literals == 1 else literal_size
                else:
                    n = [3, 3, 4, 5][form]
                    width = [10, 10, 14, 18][form]
                    value = int.from_bytes(data[cursor:cursor + n], "little")
                    packed_size = value >> (4 + width)
                    features.add("four-streams" if form else "one-stream")
                    if literals == 2:
                        features.add("direct-weights" if data[cursor + n] >= 128 else "fse-weights")
                seq = cursor + n + packed_size
                first_seq = data[seq]
                if first_seq:
                    mode = data[seq + (1 if first_seq < 128 else 3 if first_seq == 255 else 2)]
                    for shift in [6, 4, 2]:
                        features.add(["predefined-fse", "rle-fse", "compressed-fse", "repeat-fse"][(mode >> shift) & 3])
            cursor += 1 if kind == 1 else count
            if block & 1:
                break
        if descriptor & 4:
            features.add("checksum")
            cursor += 4
    assert cursor == len(data)
    if len(sizes) > 1:
        features.add("concatenated")
    return (sum(sizes) if all(size is not None for size in sizes) else None), sorted(features)


def zip93(data, packed):
    # 既存 make-zip-ppmd.py と同じ最小 ZIP envelope。圧縮 method だけを 93 にする。
    name = b"payload.bin"
    crc = zlib.crc32(data)
    local = struct.pack("<IHHHHHIIIHH", 0x04034B50, 63, 0, 93, 0, 0x2821,
                        crc, len(packed), len(data), len(name), 0) + name + packed
    central = struct.pack("<I6H3I5H2I", 0x02014B50, 63, 63, 0, 93, 0, 0x2821,
                          crc, len(packed), len(data), len(name), 0, 0, 0, 0, 0, 0) + name
    return local + central + struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1,
                                         len(central), len(local), 0)


def row(name, data):
    return dict(name=name, size=len(data), sha256=hashlib.sha256(data).hexdigest())


def oracle(executable, archive, expected, zstd=False):
    command = [executable, "-q", "-d", "-c", str(archive)] if zstd else [
        executable, "x", "-so", "-bd", str(archive)]
    actual = subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    if actual != expected:
        raise ValueError(f"oracle mismatch: {archive.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "Tests/Fixtures/zstd", help="生成先")
    parser.add_argument("--zstd", default=shutil.which("zstd") or "/opt/homebrew/bin/zstd", help="zstd CLI のパス")
    parser.add_argument("--seven-zip", default=shutil.which("7zz") or "/opt/homebrew/bin/7zz", help="7zz oracle のパス")
    parser.add_argument("--matrix", action="store_true", help="テスト用 80 通りを生成（base64 にしない）")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = []
    with tempfile.TemporaryDirectory(prefix="kaitokit-zstd-") as temporary:
        work = Path(temporary)
        if args.matrix:
            for kind, size in [("text", 200 * 1024), ("binary", 256 * 1024), ("random", 64 * 1024),
                               ("repetitive", 1024 * 1024), ("mixed", 512 * 1024)]:
                data = payload(kind, size)
                (args.output / (kind + ".bin")).write_bytes(data)
                for level in [1, 3, 9, 19]:
                    for checksum in [False, True]:
                        for content_size in [False, True]:
                            options = [f"-{level}", "--single-thread", "-C" if checksum else "--no-check"]
                            if not content_size:
                                options.append("--no-content-size")
                            packed = compress(args.zstd, work, data, options)
                            name = f"{kind}-{level}-{int(checksum)}-{int(content_size)}.zst"
                            (args.output / name).write_bytes(packed)
                            manifest.append(dict(file=name, input=kind + ".bin", size=len(data), known=content_size))
            (args.output / "matrix.json").write_text(json.dumps(manifest, indent=2) + "\n")
            print(f"matrix: {len(manifest)} cases")
            return

        def save(name, packed, data, entries=None, fmt="zstd", options=None, unsupported=False):
            encoded = base64.encodebytes(packed)
            if len(encoded) > 40000:
                raise ValueError(f"{name}: base64 too large ({len(encoded)})")
            (args.output / (name + ".b64")).write_bytes(encoded)
            archive = work / name
            archive.write_bytes(packed)
            size, features = inspect_frames(packed) if name.endswith(".zst") else (None, [])
            if not unsupported and name.endswith(".zst"):
                oracle(args.zstd, archive, data, zstd=True)
                oracle(args.seven_zip, archive, data)
            if name.endswith(".zip"):
                oracle(args.seven_zip, archive, data)
            item = dict(file=name, format=fmt, contentSize=size, features=features,
                        entries=entries if entries is not None else [row(name.removesuffix(".zst"), data)],
                        decodedSize=len(data), decodedSHA256=hashlib.sha256(data).hexdigest(),
                        options=options or [], unsupported=unsupported)
            manifest.append(item)

        inputs = [("text", 48 * 1024), ("binary", 32 * 1024), ("random", 16 * 1024),
                  ("repetitive", 1024 * 1024), ("empty", 0), ("one", 1)]
        for kind, size in inputs:
            data = payload(kind, size)
            for level in [1, 3, 9, 19, 22]:
                options = [f"-{level}", "--single-thread", "-C"] + (["--ultra"] if level == 22 else [])
                save(f"{kind}-l{level}.zst", compress(args.zstd, work, data, options), data, options=options)
        variants = [
            ("no-check", payload("text", 48 * 1024), ["-3", "--no-check"]),
            ("unknown-size", payload("text", 48 * 1024), ["-3", "-C", "--no-content-size"]),
            ("threaded", payload("repetitive", 4 * 1024 * 1024), ["-3", "-T4", "-C"]),
            ("rsyncable", payload("repetitive", 4 * 1024 * 1024), ["-3", "-T4", "--rsyncable", "-C"]),
            ("long-window", payload("repetitive", 2 * 1024 * 1024), ["-3", "--long=20", "--no-content-size", "-C"]),
            ("zero-blocks", payload("zeros", 512 * 1024), ["-3", "-C"]),
            ("table-reuse", payload("reuse", 512 * 1024), ["-9", "-C"]),
        ]
        for name, data, options in variants:
            save(name + ".zst", compress(args.zstd, work, data, options), data, options=options)
        first = payload("text", 24 * 1024)
        second = payload("binary", 16 * 1024)
        a = compress(args.zstd, work, first, ["-3", "-C"])
        b = compress(args.zstd, work, second, ["-9", "-C"])
        unknown = compress(args.zstd, work, second, ["-9", "--no-content-size"])
        skip = struct.pack("<II", 0x184D2A5F, 17) + b"KaitoKit metadata"
        save("concatenated.zst", a + b, first + second)
        save("concat-unknown.zst", a + unknown, first + second)
        save("skippable.zst", skip + a + skip + b + skip, first + second)
        save("skippable-only.zst", skip, b"")

        samples = work / "samples"
        samples.mkdir()
        for i in range(64):
            (samples / str(i)).write_bytes(payload("text", 2048) + f"sample {i}\n".encode())
        dictionary = work / "dictionary"
        subprocess.run([args.zstd, "-q", "--train", "--dictID=8878", "--maxdict=2048",
                        *map(str, sorted(samples.iterdir())), "-o", str(dictionary)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        data = payload("text", 4096)
        save("dictionary.zst", compress(args.zstd, work, data, ["-3", "-D", str(dictionary)]),
             data, unsupported=True)

        members = {"hello.txt": b"KaitoKit Zstandard tar\n", "sub/data.bin": bytes(range(256)) * 4}
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, data in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mtime = 0
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))
        data = buffer.getvalue()
        save("bundle.tar.zst", compress(args.zstd, work, data, ["-3", "-C"]), data,
             entries=[row(name, content) for name, content in members.items()], fmt="tar")
        save("method93.zip", zip93(first, a), first, entries=[row("payload.bin", first)], fmt="zip")
        save("method93-concat.zip", zip93(first + second, a + skip + b), first + second,
             entries=[row("payload.bin", first + second)], fmt="zip")

        # 既存の stored RPM fixture の envelope と cpio を再利用し、payload を CLI で圧縮する。
        rpm = base64.b64decode((ROOT / "Tests/Fixtures/container/rpm-none.rpm.b64").read_bytes())
        be = lambda at: int.from_bytes(rpm[at:at + 4], "big")
        sig_end = 96 + 16 + be(104) * 16 + be(108)
        main_header = (sig_end + 7) & ~7
        start = main_header + 16 + be(main_header + 8) * 16 + be(main_header + 12)
        data = rpm[start:]
        packed = compress(args.zstd, work, data, ["-3", "-C"])
        # cpio の各 entry の期待値は元 payload の newc header から採取する。
        cursor = 0
        entries = []
        while True:
            assert data[cursor:cursor + 6] == b"070701"
            size = int(data[cursor + 54:cursor + 62], 16)
            name_size = int(data[cursor + 94:cursor + 102], 16)
            name = data[cursor + 110:cursor + 110 + name_size - 1].decode()
            cursor = (cursor + 110 + name_size + 3) & ~3
            content = data[cursor:cursor + size]
            cursor = (cursor + size + 3) & ~3
            if name == "TRAILER!!!":
                break
            entries.append(row(name, content))
        save("payload.rpm", rpm[:start] + packed, data, entries=entries, fmt="rpm")
        all_features = set().union(*(item["features"] for item in manifest if not item["unsupported"]))
        required = {"raw", "rle", "four-streams", "treeless", "repeat-fse", "single-segment",
                    "window-descriptor", "window-1048576", "fse-weights", "concatenated", "skippable"}
        if not required <= all_features:
            raise ValueError(f"missing coverage: {required - all_features}")
        (args.output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        print(f"fixed fixtures: {len(manifest)}; features: {', '.join(sorted(all_features))}")


if __name__ == "__main__":
    main()
