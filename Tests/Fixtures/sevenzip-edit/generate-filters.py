#!/usr/bin/env python3
"""Rebuild the three project-owned filter fixtures with 7-Zip 26.03.

Only these archives and their structural/AES goldens are updated. Public values
are frozen separately by SevenZipPublicValueGoldenTests (see README.md).
The small parser below deliberately accepts only this corpus's plain headers,
one solid folder, three streamed files, and internal all-defined properties.
It does not import KaitoKit or any third-party archiver implementation.
"""

import argparse
import hashlib
import json
import lzma
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib


ROOT = Path(__file__).resolve().parent
NAMES = ("cat", "ls", "t.txt")
SIZES = (184336, 252512, 50000)
EPOCH = 1672531200  # 2023-01-01 00:00:00 UTC
FILETIME = (EPOCH + 11644473600) * 10000000
METHODS = {"21": "LZMA2", "030101": "LZMA", "03030103": "BCJ",
           "0303011b": "BCJ2", "030401": "PPMD"}
PROPERTIES = {0x19: "kDummy", 0x11: "kName", 0x12: "kCTime",
              0x13: "kATime", 0x14: "kMTime", 0x15: "kWinAttributes"}
COMMON = ["a", "-t7z", "-y", "-bd", "-mmt=1", "-ms=on", "-mhc=off", "-mtm=on"]
RECIPES = {
    "bcj.7z": ["-m0=BCJ", "-m1=LZMA2:d=19", "-mtc=on", "-mta=on"],
    "bcj2.7z": ["-m0=LZMA2:d=19", "-mf=BCJ2", "-mtc=on", "-mta=on"],
    "ppmd.7z": ["-m0=PPMd:o=6:mem=23", "-mtc=off", "-mta=off"],
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def payloads():
    """Fresh seeded noise in every record plus E8/E9 rel32, never host bytes."""
    result = []
    for name, size in zip(NAMES[:2], SIZES[:2]):
        seed = ("KaitoKit 0.11.0 synthetic x86 " + name).encode("ascii")
        noise = hashlib.shake_256(seed).digest(((size + 63) // 64) * 4)
        data = bytearray()
        for index, position in enumerate(range(0, size, 64)):
            record = bytearray(b"\x90" * 64)
            record[:4] = noise[index * 4:index * 4 + 4]
            # Both forward and backward targets, always inside this file.
            for at, opcode, bias in ((16, 0xE8, 1024), (40, 0xE9, 32768)):
                target = (index * 256 + bias) % size
                record[at] = opcode
                struct.pack_into("<i", record, at + 1, target - (position + at + 5))
            data.extend(record)
        result.append(bytes(data[:size]))
    text = b"".join(
        (f"KaitoKit project-owned PPMd text {i:04d}: call, jump, read, repeat.\n").encode("ascii")
        for i in range(1000)
    )
    result.append(text[:SIZES[2]])
    require(tuple(map(len, result)) == SIZES, "payload size mismatch")
    return dict(zip(NAMES, result))


class Cursor:
    def __init__(self, data, offset=0):
        self.data, self.offset = data, offset

    def take(self, count):
        end = self.offset + count
        require(end <= len(self.data), "truncated header")
        value = self.data[self.offset:end]
        self.offset = end
        return value

    def byte(self):
        return self.take(1)[0]

    def expect(self, value):
        require(self.byte() == value, f"unexpected property at {self.offset - 1}")

    def number(self):
        first, value = self.byte(), 0
        for index in range(8):
            mask = 0x80 >> index
            if not first & mask:
                return value | ((first & (mask - 1)) << (8 * index))
            value |= self.byte() << (8 * index)
        return value


def inspect(data):
    """Read fresh archive bytes into the existing structural golden schema."""
    require(data[:6] == b"7z\xbc\xaf\x27\x1c", "bad signature")
    start_crc, next_offset, next_size, next_crc = struct.unpack_from("<IQQI", data, 8)
    require(start_crc == zlib.crc32(data[12:32]), "bad start CRC")
    start = 32 + next_offset
    header = data[start:start + next_size]
    require(start + next_size == len(data), "unexpected trailing bytes")
    require(zlib.crc32(header) == next_crc, "bad next header CRC")
    c = Cursor(header)
    c.expect(1)  # Header
    c.expect(4)  # MainStreamsInfo
    c.expect(6)  # PackInfo
    pack_pos, pack_count = c.number(), c.number()
    c.expect(9)
    lengths = [c.number() for _ in range(pack_count)]
    c.expect(0)  # No pack CRCs
    packs, offset = [], 32 + pack_pos
    for index, length in enumerate(lengths):
        packs.append(dict(index=index, range=dict(offset=offset, length=length),
                          crc32=None, sha256=sha(data[offset:offset + length])))
        offset += length
    require(offset == start, "unexpected header or pack gap")
    c.expect(7)  # UnpackInfo
    c.expect(0x0B)
    require(c.number() == 1, "expected one solid folder")
    c.expect(0)  # Internal folders
    coders = []
    inputs = outputs = 0
    for _ in range(c.number()):
        flags = c.byte()
        require(flags & 0xC0 == 0, "unexpected coder flags")
        method = c.take(flags & 15).hex()
        complex_coder, has_properties = bool(flags & 0x10), bool(flags & 0x20)
        ni, no = (c.number(), c.number()) if complex_coder else (1, 1)
        properties = c.take(c.number()).hex() if has_properties else None
        coders.append(dict(methodIDHex=method, method=METHODS[method], numInputs=ni,
                           numOutputs=no, isComplex=complex_coder,
                           hasProperties=has_properties, propertiesHex=properties))
        inputs += ni
        outputs += no
    binds = [dict(inputIndex=c.number(), outputIndex=c.number()) for _ in range(outputs - 1)]
    require(inputs - len(binds) == pack_count, "packed input count mismatch")
    if pack_count == 1:
        packed_inputs = [i for i in range(inputs) if i not in {b['inputIndex'] for b in binds}]
    else:
        packed_inputs = [c.number() for _ in range(pack_count)]
    c.expect(0x0C)
    unpack_sizes = [c.number() for _ in range(outputs)]
    c.expect(0)  # No folder CRC (three substream CRCs instead)
    c.expect(8)  # SubStreamsInfo
    c.expect(0x0D)
    require(c.number() == 3, "expected three substreams")
    c.expect(9)
    sizes = [c.number(), c.number()]
    sizes.append(unpack_sizes[-1] - sum(sizes))
    c.expect(0x0A)
    c.expect(1)  # All CRCs defined
    crcs = struct.unpack("<3I", c.take(12))
    c.expect(0)
    c.expect(0)
    folder = dict(index=0, coders=coders, binds=binds, packedInputs=packed_inputs,
                  packIndices=list(range(pack_count)), numOutputsTotal=outputs,
                  unpackSizes=unpack_sizes, unpackSize=unpack_sizes[-1], crc32=None,
                  substreams=[dict(index=i, size=s, crc32=crc) for i, (s, crc) in enumerate(zip(sizes, crcs))])
    c.expect(5)  # FilesInfo
    require(c.number() == 3, "expected three files")
    properties, time_offsets = [], []
    files = [dict(index=i, name=name, nameRawHex=name.encode("utf-16le").hex(),
                  emptyStream=False, emptyFile=False, anti=False, creationTime=None,
                  accessTime=None, modificationTime=None, attributes=None, startPos=None,
                  folderIndex=0, substreamIndex=i) for i, name in enumerate(NAMES)]
    while (pid := c.byte()) != 0:
        length = c.number()
        prop_start = start + c.offset
        raw = c.take(length)
        properties.append(dict(id=f"0x{pid:02x}", name=PROPERTIES[pid], length=length, dataHex=raw.hex()))
        if pid == 0x11:
            expected_names = b"\0" + b"".join(n.encode("utf-16le") + b"\0\0" for n in NAMES)
            require(raw == expected_names, "entry names/order changed")
        elif pid in (0x12, 0x13, 0x14, 0x15):
            require(raw[:2] == b"\1\0", "expected internal all-defined property")
            key = {0x12: "creationTime", 0x13: "accessTime", 0x14: "modificationTime", 0x15: "attributes"}[pid]
            values = struct.unpack("<3I" if pid == 0x15 else "<3Q", raw[2:])
            for file, value in zip(files, values):
                file[key] = value if pid == 0x15 else str(value)
            if pid != 0x15:
                time_offsets.extend(prop_start + 2 + 8 * i for i in range(3))
        else:
            require(pid == 0x19 and not any(raw), "unexpected dummy property")
    c.expect(0)
    require(c.offset == len(header), "unparsed header bytes")
    value = dict(size=len(data), sha256=sha(data), baseOffset=0, version=list(data[6:8]),
                 startHeaderCRC32=start_crc, startHeaderCRCValid=True, nextHeaderOffset=next_offset,
                 nextHeaderRange=dict(offset=start, length=next_size), nextHeaderCRC32=next_crc,
                 nextHeaderCRCValid=True, headerEncoding="plain", nextHeaderSHA256=sha(header),
                 plaintextHeader=dict(length=len(header), sha256=sha(header)), packPos=pack_pos,
                 mainPackEnd=offset, main=dict(packPos=pack_pos, packs=packs, folders=[folder]),
                 additional=None, encodedHeader=None, headerPropertyOrder=["0x04", "0x05"],
                 archivePropertiesHex=None, archiveProperties=[],
                 filePropertyOrder=[p["id"] for p in properties], fileProperties=properties, files=files,
                 prototypeAdapter="none")
    return value, time_offsets


def normalize_times(data):
    value, offsets = inspect(data)
    data = bytearray(data)
    for offset in offsets:
        struct.pack_into("<Q", data, offset, FILETIME)
    struct.pack_into("<I", data, 28, zlib.crc32(data[value["nextHeaderRange"]["offset"]:]))
    struct.pack_into("<I", data, 8, zlib.crc32(data[12:32]))
    return bytes(data)


def verify_contract(name, value, original, content, data):
    """Preserve coverage independently of the sizes/hashes being regenerated."""
    old_folder = original["main"]["folders"][0]
    folder = value["main"]["folders"][0]
    for key in ("coders", "binds", "packedInputs", "packIndices", "numOutputsTotal"):
        require(folder[key] == old_folder[key], f"{name}: changed {key}")
    require(value["filePropertyOrder"] == original["filePropertyOrder"], "file property order changed")
    for file, old in zip(value["files"], original["files"]):
        for key in ("name", "attributes", "emptyStream", "emptyFile", "anti", "folderIndex", "substreamIndex"):
            require(file[key] == old[key], f"{name}: changed file {key}")
        for key in ("creationTime", "accessTime", "modificationTime"):
            require((file[key] is None) == (old[key] is None), f"{name}: changed timestamp presence")
    for substream, body in zip(folder["substreams"], content.values()):
        require(substream["size"] == len(body) and substream["crc32"] == zlib.crc32(body), "substream mismatch")
    if name == "bcj.7z":
        pack = value["main"]["packs"][0]["range"]
        filtered = lzma.decompress(data[pack["offset"]:pack["offset"] + pack["length"]],
                                   format=lzma.FORMAT_RAW, filters=[dict(id=lzma.FILTER_LZMA2, dict_size=1 << 19)])
        require(len(filtered) == sum(SIZES) and filtered != b"".join(content.values()), "BCJ did not transform data")
    if name == "bcj2.7z":
        require(len(value["main"]["packs"]) == 4, "BCJ2 needs four packed streams")
        require(all(p["range"]["length"] > 0 for p in value["main"]["packs"]), "empty BCJ2 packed stream")
        require(folder["unpackSizes"][0] > 0 and folder["unpackSizes"][1] > 0,
                "BCJ2 call/jump side streams must both contain transformed targets")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sevenzip", default="/opt/homebrew/bin/7zz")
    parser.add_argument("--check", action="store_true", help="regenerate and compare without writing")
    args = parser.parse_args()
    env = dict(os.environ, TZ="UTC", LC_ALL="C")
    version = subprocess.check_output([args.sevenzip, "i"], env=env, text=True).splitlines()[1]
    require("26.03" in version, "pinned 7-Zip 26.03 required")
    print(version)
    expected_path = ROOT / "expected-structures.json"
    expected = json.loads(expected_path.read_text())
    content = payloads()
    with tempfile.TemporaryDirectory(prefix="kaitokit-filters-") as temporary:
        work = Path(temporary)
        for name, body in content.items():
            path = work / name
            path.write_bytes(body)
            path.chmod(0o644 if name == "t.txt" else 0o755)
            os.utime(path, (EPOCH, EPOCH))
        for name, recipe in RECIPES.items():
            archive = work / name
            command = [args.sevenzip, *COMMON, *recipe, str(archive), *NAMES]
            subprocess.run(command, cwd=work, env=env, check=True, stdout=subprocess.PIPE)
            data = normalize_times(archive.read_bytes())
            archive.write_bytes(data)
            value, _ = inspect(data)
            verify_contract(name, value, expected["archives"][name], content, data)
            subprocess.run([args.sevenzip, "t", "-t7z", str(archive)], env=env, check=True, stdout=subprocess.PIPE)
            for entry, body in content.items():
                extracted = subprocess.check_output([args.sevenzip, "x", "-so", str(archive), entry], env=env)
                require(extracted == body, f"{name}/{entry}: round trip differs")
            value["baselineReaders"] = expected["archives"][name]["baselineReaders"]
            # Reader observations are checked again by the release's kaito sha and golden tests.
            expected["archives"][name] = value
            if args.check:
                require(data == (ROOT / name).read_bytes(), f"{name}: archive differs")
            else:
                (ROOT / name).write_bytes(data)
            print(f"{sha(data)}  {name} ({len(data)} bytes)")
    expected["_meta"]["regeneratedFilters"] = dict(
        date="2026-09-27", archives=list(RECIPES), generator="generate-filters.py",
        writer="7-Zip 26.03", payload="Project-authored SHAKE-256 noise, synthetic x86 rel32, and text (MIT)",
        structures="Parsed independently from the regenerated plain headers by generate-filters.py; other records unchanged.",
        readerObservations="Regenerated fixtures rechecked with KaitoKit 823ad46 and 7zz 26.03.")
    decrypted_path = ROOT / "expected-decrypted.json"
    decrypted = json.loads(decrypted_path.read_text())
    for name in RECIPES:
        require(decrypted["archives"][name] == [], "unexpected AES expectation")
    decrypted["_meta"]["regeneratedFilters"] = dict(
        date="2026-09-27", archives=list(RECIPES), generator="generate-filters.py",
        verification="Regenerated coder graphs contain no AES; their expected decrypted-stream arrays remain empty.")
    for path, value in ((expected_path, expected), (decrypted_path, decrypted)):
        encoded = (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()
        if args.check:
            require(encoded == path.read_bytes(), f"{path.name}: golden differs")
        else:
            path.write_bytes(encoded)


if __name__ == "__main__":
    main()
