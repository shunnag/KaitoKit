#!/usr/bin/env python3
"""WIM fixture generator (run by hand; the archives are checked in as base64).

Writes Windows Imaging files from a project-owned payload with three resource codings:
  - stored (RESHDR flags without COMPRESSED),
  - XPRESS（Microsoft [MS-XCA] LZ77+Huffman、4〜64 KiB chunk ごとに 1 block）、
  - LZX (the WIM variant of [MS-PATCH] LZX: no E8 header bit, E8 translation size 12,000,000,
    block header "type(3) + 1 bit default-size flag or 16-bit size", 32 KiB window, per-chunk streams;
    these WIM specifics were pinned black-box against a Microsoft-written boot.wim, see
    Documentation/verification/2026-09-21-wim.md).
The container layout follows the public Microsoft "Windows Imaging File Format (WIM)" whitepaper (2007)
plus the black-box details recorded in the verification note (102-byte DIRENTRY fixed part, stream
entries, stored chunks when compression does not help). Every image is verified by extracting it with
7-Zip (`7zz`), an independent reader, before it is written; the encoders here exist only to make
project-owned compressed samples and were written from the specifications' prose and pseudocode.
"""
import base64, hashlib, heapq, json, os, pathlib, shutil, struct, subprocess, tempfile

HERE = pathlib.Path(__file__).resolve().parent
CHUNK = 32768

# ----------------------------------------------------------------------------- payload

def payload_small():
    return {
        "readme.txt": b"WIM fixture readme\n" * 300,                       # 5,700 bytes
        "empty.bin": b"",
        "sub/nested/deep.txt": b"deep\n",
        "sub/日本語.txt": "nihongo\n".encode(),
        "same.txt": b"same content\n",
        "same-copy.txt": b"same content\n",                                 # duplicate resource
    }

def payload_compressed():
    import random
    rnd = random.Random(2026)
    e8 = bytearray()
    for i in range(5000):
        e8 += bytes([0xE8]) + struct.pack("<i", (i * 7919) % 200000 - 100000) + bytes([0x90, 0x55])
    text = b"".join(("The quick brown fox jumps over the lazy dog %d\n" % (i % 97)).encode() for i in range(1200))   # 56 KB, 2 chunks
    mixed = bytearray()
    for i in range(40000):
        mixed.append((i * 31 + (i >> 5)) & 0xFF if i % 500 < 480 else rnd.getrandbits(8))
    return {
        "text.txt": text,
        "e8.bin": bytes(e8),                                                # 35,000 bytes, E8 heavy, 2 chunks
        "mixed.bin": bytes(mixed),                                          # 40,000 bytes, 2 chunks
        "random.bin": bytes(rnd.getrandbits(8) for _ in range(1500)),       # incompressible chunk -> stored
        "sub/small.txt": b"small\n",
    }

# ----------------------------------------------------------------------------- Huffman helpers

def huffman_lengths(freqs, limit):
    """Canonical Huffman code lengths limited to `limit` bits (frequencies are halved until they fit)."""
    freqs = list(freqs)
    while True:
        symbols = [(f, i) for i, f in enumerate(freqs) if f > 0]
        if not symbols:
            return [0] * len(freqs)
        if len(symbols) == 1:
            lengths = [0] * len(freqs); lengths[symbols[0][1]] = 1
            return lengths
        heap = [(f, [i]) for f, i in symbols]
        heapq.heapify(heap)
        lengths = [0] * len(freqs)
        while len(heap) > 1:
            f1, s1 = heapq.heappop(heap); f2, s2 = heapq.heappop(heap)
            for s in s1 + s2: lengths[s] += 1
            heapq.heappush(heap, (f1 + f2, s1 + s2))
        if max(lengths) <= limit:
            return lengths
        freqs = [max(1, f // 2) if f > 0 else 0 for f in freqs]

def canonical_codes(lengths):
    """Codes assigned by (length, symbol) order, as both LZX and XPRESS require."""
    codes = [0] * len(lengths)
    code = 0
    for length in range(1, max(lengths) + 1):
        for symbol, l in enumerate(lengths):
            if l == length:
                codes[symbol] = code; code += 1
        code <<= 1
    return codes

# ----------------------------------------------------------------------------- LZ77 matcher

def find_matches(data, max_length, max_distance):
    """Greedy matches: list of (position, length, distance) with a 3-byte hash chain."""
    table = {}
    matches = []
    i = 0
    n = len(data)
    while i + 3 <= n:
        key = data[i:i + 3]
        best = (0, 0)
        for candidate in table.get(key, ())[-8:]:
            if i - candidate > max_distance: continue
            length = 3
            while length < max_length and i + length < n and data[candidate + length] == data[i + length]:
                length += 1
            if length > best[0]: best = (length, i - candidate)
        table.setdefault(key, []).append(i)
        if best[0] >= 3:
            matches.append((i, best[0], best[1]))
            for k in range(1, best[0]):
                if i + k + 3 <= n: table.setdefault(data[i + k:i + k + 3], []).append(i + k)
            i += best[0]
        else:
            i += 1
    return matches

# ----------------------------------------------------------------------------- XPRESS (MS-XCA 2.1)

def xpress_compress(chunk):
    matches = find_matches(chunk, 65538, 65535)
    items = []          # ('L', byte) or ('M', length, distance)
    pos = 0
    for start, length, distance in matches:
        while pos < start: items.append(("L", chunk[pos])); pos += 1
        items.append(("M", length, distance)); pos += length
    while pos < len(chunk): items.append(("L", chunk[pos])); pos += 1
    def high_bit(d): return d.bit_length() - 1
    freqs = [0] * 512
    for item in items:
        if item[0] == "L": freqs[item[1]] += 1
        else: freqs[256 + min(item[1] - 3, 15) + 16 * high_bit(item[2])] += 1
    freqs[256] += 1                                    # EOF symbol
    lengths = huffman_lengths(freqs, 15)
    codes = canonical_codes(lengths)
    out = bytearray(256)
    for s in range(512):
        if s % 2 == 0: out[s // 2] |= lengths[s]
        else: out[s // 2] |= lengths[s] << 4
    # bit writer per §2.1.4.3 pseudocode
    state = {"free": 16, "word": 0, "p1": 256, "p2": 258}
    out += bytes(4)
    def write_bits(count, value):
        if state["free"] >= count:
            state["free"] -= count; state["word"] = (state["word"] << count) + value
        else:
            state["word"] = (state["word"] << state["free"]) + (value >> (count - state["free"]))
            state["free"] -= count
            out[state["p1"]] = state["word"] & 0xFF; out[state["p1"] + 1] = (state["word"] >> 8) & 0xFF
            state["p1"] = state["p2"]; state["p2"] = len(out); out.extend(bytes(2))
            state["free"] += 16; state["word"] = value & ((1 << count) - 1) if count else 0
    for item in items:
        if item[0] == "L":
            write_bits(lengths[item[1]], codes[item[1]]); continue
        length, distance = item[1], item[2]
        hb = high_bit(distance)
        symbol = 256 + min(length - 3, 15) + 16 * hb
        write_bits(lengths[symbol], codes[symbol])
        rest = length - 3
        if rest >= 15:
            rest -= 15
            if rest < 255: out.append(rest)
            else:
                out.append(255); rest += 15
                out += struct.pack("<H", rest)
        write_bits(hb, distance - (1 << hb))
    write_bits(lengths[256], codes[256])
    state["word"] <<= state["free"]
    out[state["p1"]] = state["word"] & 0xFF; out[state["p1"] + 1] = (state["word"] >> 8) & 0xFF
    out[state["p2"]] = 0; out[state["p2"] + 1] = 0
    return bytes(out)

# ----------------------------------------------------------------------------- LZX, WIM variant

FOOTER_BITS = [max(0, min(17, s // 2 - 1)) for s in range(50)]
BASE_POSITIONS = [0]
for _w in FOOTER_BITS[:-1]: BASE_POSITIONS.append(BASE_POSITIONS[-1] + (1 << _w))
E8_FILE_SIZE = 12_000_000
PRETREE_LENGTHS = [4] * 12 + [5] * 8            # fixed complete pretree (12/16 + 8/32 = 1)

class LZXBitWriter:
    def __init__(self):
        self.out = bytearray(); self.acc = 0; self.count = 0
    def write(self, count, value):
        for i in range(count - 1, -1, -1):
            self.acc = (self.acc << 1) | ((value >> i) & 1); self.count += 1
            if self.count == 16:
                self.out += struct.pack("<H", self.acc); self.acc = 0; self.count = 0
    def align16(self):
        if self.count: self.write(16 - self.count, 0)
    def raw(self, data):
        assert self.count == 0
        self.out += data
    def finish(self):
        self.align16(); return bytes(self.out)

def e8_preprocess(chunk, chunk_offset=0):
    b = bytearray(chunk)
    if chunk_offset < 0x40000000 and len(b) > 10:
        i = 0
        while i < len(b) - 10:
            if b[i] == 0xE8:
                pointer = chunk_offset + i
                displacement = struct.unpack_from("<i", b, i + 1)[0]
                target = pointer + displacement
                if 0 <= target < E8_FILE_SIZE + pointer:
                    if target >= E8_FILE_SIZE: target = displacement - E8_FILE_SIZE
                    struct.pack_into("<i", b, i + 1, target)
                i += 5
            else:
                i += 1
    return bytes(b)

def write_lengths(w, previous, lengths):
    """Pretree-coded delta lengths (MS-PATCH 2.3.2.3.1) with the fixed pretree and no run symbols."""
    codes = canonical_codes(PRETREE_LENGTHS)
    for l in PRETREE_LENGTHS: w.write(4, l)
    for prev, new in zip(previous, lengths):
        symbol = (prev - new) % 17
        w.write(PRETREE_LENGTHS[symbol], codes[symbol])

def position_slot(formatted):
    slot = 0
    while slot + 1 < len(BASE_POSITIONS) and BASE_POSITIONS[slot + 1] <= formatted: slot += 1
    return slot

def lzx_compress_chunk(chunk, block_type, raw_tail=0):
    """One WIM LZX chunk: one verbatim (1) or aligned (2) block covering the chunk minus `raw_tail`
    bytes, which are appended as an uncompressed block (type 3) without a trailing pad byte."""
    data = e8_preprocess(chunk)
    body = data[:len(data) - raw_tail]
    w = LZXBitWriter()
    if body:
        matches = find_matches(body, 257, 32768 - 3)
        items = []; pos = 0
        for start, length, distance in matches:
            while pos < start: items.append(("L", body[pos])); pos += 1
            items.append(("M", length, distance)); pos += length
        while pos < len(body): items.append(("L", body[pos])); pos += 1
        main_freq = [0] * (256 + 8 * 30); length_freq = [0] * 249; aligned_freq = [0] * 8
        for item in items:
            if item[0] == "L": main_freq[item[1]] += 1; continue
            length, distance = item[1], item[2]
            header = min(length - 2, 7)
            if header == 7: length_freq[length - 9] += 1
            slot = position_slot(distance + 2)
            main_freq[256 + slot * 8 + header] += 1
            if block_type == 2 and FOOTER_BITS[slot] >= 3: aligned_freq[(distance + 2 - BASE_POSITIONS[slot]) & 7] += 1
        main_len = huffman_lengths(main_freq, 16); main_codes = canonical_codes(main_len)
        length_len = huffman_lengths(length_freq, 16); length_codes = canonical_codes(length_len)
        w.write(3, block_type)
        if len(body) == CHUNK: w.write(1, 1)
        else: w.write(1, 0); w.write(16, len(body))
        if block_type == 2:
            aligned_len = huffman_lengths(aligned_freq, 7) if any(aligned_freq) else [0] * 8
            if any(aligned_freq) and sum(1 for l in aligned_len if l) == 1:      # a single symbol needs a partner for a full tree
                aligned_len = [1 if f or i == (aligned_len.index(1) ^ 1) else 0 for i, f in enumerate(aligned_freq)]
            aligned_codes = canonical_codes(aligned_len)
            for l in aligned_len: w.write(3, l)
        write_lengths(w, [0] * 256, main_len[:256])
        write_lengths(w, [0] * (len(main_len) - 256), main_len[256:])
        write_lengths(w, [0] * 249, length_len)
        for item in items:
            if item[0] == "L": w.write(main_len[item[1]], main_codes[item[1]]); continue
            length, distance = item[1], item[2]
            header = min(length - 2, 7)
            slot = position_slot(distance + 2)
            symbol = 256 + slot * 8 + header
            w.write(main_len[symbol], main_codes[symbol])
            if header == 7: w.write(length_len[length - 9], length_codes[length - 9])
            footer = distance + 2 - BASE_POSITIONS[slot]; bits = FOOTER_BITS[slot]
            if block_type == 2 and bits >= 3:
                w.write(bits - 3, footer >> 3); w.write(aligned_len[footer & 7], aligned_codes[footer & 7])
            else:
                w.write(bits, footer)
    if raw_tail:
        tail = data[len(data) - raw_tail:]
        w.write(3, 3)
        if raw_tail == CHUNK: w.write(1, 1)
        else: w.write(1, 0); w.write(16, raw_tail)
        w.align16()
        w.raw(struct.pack("<III", 1, 1, 1) + tail)      # R0..R2 then the bytes; no pad byte at the chunk end
        return bytes(w.out)
    return w.finish()

# ----------------------------------------------------------------------------- WIM container

FLAG_COMPRESSION, FLAG_XPRESS, FLAG_LZX = 0x2, 0x20000, 0x40000
RES_METADATA, RES_COMPRESSED = 0x02, 0x04
ATTR_DIRECTORY, ATTR_ARCHIVE, ATTR_REPARSE = 0x10, 0x20, 0x400
FILETIME = 133_800_000_000_000_000        # a fixed 2025 timestamp (100 ns since 1601)

def reshdr(size, flags, offset, original):
    return size.to_bytes(7, "little") + bytes([flags]) + struct.pack("<qq", offset, original)

def compress_resource(data, method, variant=0, chunk_size=CHUNK):
    """Returns (bytes, flags) for one resource."""
    if method == "stored" or not data:
        return data, 0
    chunks = [data[i:i + chunk_size] for i in range(0, len(data), chunk_size)]
    encoded = []
    for index, chunk in enumerate(chunks):
        if method == "xpress":
            c = xpress_compress(chunk)
        else:
            block_type = 2 if (index + variant) % 2 else 1
            raw_tail = 0
            if variant == 1 and index == 1: raw_tail = min(len(chunk), 5000) | 1     # odd raw tail, no pad byte
            c = lzx_compress_chunk(chunk, block_type, raw_tail=raw_tail if raw_tail < len(chunk) else 0)
        encoded.append(c if len(c) < len(chunk) else chunk)                            # stored chunk when not smaller
    entry = 8 if len(data) > 0xFFFFFFFF else 4
    table = bytearray(); total = 0
    for c in encoded[:-1]:
        total += len(c); table += struct.pack("<Q" if entry == 8 else "<I", total)
    return bytes(table) + b"".join(encoded), RES_COMPRESSED

def build_metadata(tree, hashes, hardlinks=None, ads=None, reparse=None):
    """tree: {name: bytes or dict}; returns the metadata resource (security block + DIRENTRY tree)."""
    hardlinks = hardlinks or {}; ads = ads or {}; reparse = reparse or {}
    out = bytearray(struct.pack("<II", 8, 0))          # SECURITYBLOCK_DISK: total length 8, no entries
    def dirent(name, attributes, hash20, subdir, hardlink=0, reparse_tag=0, streams=()):
        encoded = name.encode("utf-16-le")
        body = struct.pack("<IIQQQQQQ", attributes, 0xFFFFFFFF, subdir, 0, 0, FILETIME, FILETIME, FILETIME)
        body += hash20
        body += struct.pack("<II", reparse_tag, 0) if reparse_tag else struct.pack("<Q", hardlink)
        body += struct.pack("<IHHH", 0, len(streams), 0, len(encoded)) + encoded + (b"\0\0" if encoded else b"")
        length = (8 + len(body) + 7) // 8 * 8
        entry = struct.pack("<Q", length) + body
        entry += bytes(length - len(entry))
        for stream_name, stream_hash in streams:
            s = stream_name.encode("utf-16-le")
            sbody = struct.pack("<Q", 0) + stream_hash + struct.pack("<H", len(s)) + s + (b"\0\0" if s else b"")
            slength = (8 + len(sbody) + 7) // 8 * 8
            entry += struct.pack("<Q", slength) + sbody + bytes(slength - 8 - len(sbody))
        return entry
    def layout_with_paths(node, path):
        start = len(out)
        entries = []
        for name in sorted(node):
            value = node[name]
            full = (path + "/" + name) if path else name
            if isinstance(value, dict):
                e = dirent(name, ATTR_DIRECTORY, bytes(20), 0)
                entries.append((len(out), value, full)); out.extend(e)
            else:
                streams = tuple((s, hashes[full + ":" + s]) for s in ads.get(full, ()))
                if full in reparse:
                    e = dirent(name, ATTR_ARCHIVE | ATTR_REPARSE, hashes[full], 0, 0, reparse[full])
                else:
                    e = dirent(name, ATTR_ARCHIVE, hashes[full], 0, hardlinks.get(full, 0), 0, streams)
                out.extend(e)
        out.extend(bytes(8))
        for offset, child, full in entries:
            child_offset = layout_with_paths(child, full)
            struct.pack_into("<Q", out, offset + 16, child_offset)
        return start
    root_offset = len(out)
    out.extend(dirent("", ATTR_DIRECTORY, bytes(20), 0))
    out.extend(bytes(8))                                  # the root entry is a one-entry directory list, terminated too
    children = layout_with_paths(tree, "")
    struct.pack_into("<Q", out, root_offset + 16, children)
    return bytes(out)

def build_wim(images, method, resources_override=None, variant=0, chunk_size=CHUNK):
    """images: list of trees ({path: bytes|dict}); duplicate contents share one resource."""
    flags = 0x80 | (FLAG_COMPRESSION | (FLAG_LZX if method == "lzx" else FLAG_XPRESS) if method != "stored" else 0)
    blobs = {}       # sha1 -> data
    def collect(node):
        for value in node.values():
            if isinstance(value, dict): collect(value)
            else: blobs.setdefault(hashlib.sha1(value).digest(), value)
    for tree, extras in images:
        collect(tree)
        for extra in extras.get("ads", {}).values():
            for data in extra.values(): blobs.setdefault(hashlib.sha1(data).digest(), data)
        for data in extras.get("reparse_data", {}).values(): blobs.setdefault(hashlib.sha1(data).digest(), data)
    body = bytearray()
    lookup = []
    offset = 208
    for digest, data in blobs.items():
        if not data: continue
        encoded, rflags = compress_resource(data, method, variant, chunk_size)
        lookup.append(reshdr(len(encoded), rflags, offset, len(data)) + struct.pack("<HI", 1, 1) + digest)
        body += encoded; offset += len(encoded)
    metadata_entries = []
    for tree, extras in images:
        hashes = {}
        def walk(node, path):
            for name, value in node.items():
                full = (path + "/" + name) if path else name
                if isinstance(value, dict): walk(value, full)
                else: hashes[full] = hashlib.sha1(value).digest() if value else bytes(20)   # empty file: zero hash, no resource
        walk(tree, "")
        for full, streams in extras.get("ads", {}).items():
            for stream_name, data in streams.items(): hashes[full + ":" + stream_name] = hashlib.sha1(data).digest()
        ads = {full: list(streams) for full, streams in extras.get("ads", {}).items()}
        metadata = build_metadata(tree, hashes, extras.get("hardlinks"), ads, extras.get("reparse"))
        encoded, rflags = compress_resource(metadata, method, variant, chunk_size)
        metadata_entries.append(reshdr(len(encoded), RES_METADATA | rflags, offset, len(metadata))
                                + struct.pack("<HI", 1, 1) + hashlib.sha1(metadata).digest())
        body += encoded; offset += len(encoded)
    table = b"".join(metadata_entries + lookup)
    table_offset = offset; offset += len(table)
    xml = ("﻿<WIM><TOTALBYTES>%d</TOTALBYTES>" % (208 + len(body))
           + "".join('<IMAGE INDEX="%d"><NAME>image%d</NAME></IMAGE>' % (i + 1, i + 1) for i in range(len(images)))
           + "</WIM>").encode("utf-16-le")
    xml_offset = offset
    header = bytearray(208)
    header[0:8] = b"MSWIM\0\0\0"
    struct.pack_into("<IIII", header, 8, 208, 0x10D00, flags, chunk_size if method != "stored" else 0)
    header[24:40] = hashlib.md5(table).digest()
    struct.pack_into("<HHI", header, 40, 1, 1, len(images))
    # 7-Zip and Microsoft's own writer set the METADATA flag on the header's table / XML entries (black-box).
    header[48:72] = reshdr(len(table), RES_METADATA, table_offset, len(table))
    header[72:96] = reshdr(len(xml), RES_METADATA, xml_offset, len(xml))
    header[96:120] = bytes(24); struct.pack_into("<I", header, 120, 0); header[124:148] = bytes(24)
    return bytes(header) + bytes(body) + table + xml

# ----------------------------------------------------------------------------- verification & output

def verify_with_7zz(path, expected):
    """Extract with 7-Zip and compare every regular file."""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["7zz", "x", "-bso0", "-bsp0", "-o" + tmp, str(path)], check=True)
        for rel, data in expected.items():
            actual = pathlib.Path(tmp, rel).read_bytes()
            assert actual == data, f"{path.name}: {rel} differs after 7zz extraction"

def flatten(tree, path=""):
    result = {}
    for name, value in tree.items():
        full = (path + "/" + name) if path else name
        if isinstance(value, dict): result.update(flatten(value, full))
        else: result[full] = value
    return result

def nest(files):
    tree = {}
    for path, data in files.items():
        node = tree
        parts = path.split("/")
        for part in parts[:-1]: node = node.setdefault(part, {})
        node[parts[-1]] = data
    return tree

def store(name, data, manifest, note):
    (HERE / f"{name}.b64").write_text(base64.encodebytes(data).decode())
    manifest[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "note": note}
    print(f"{name}: {len(data)} bytes")

def add_chunk_size_fixtures(manifest, tmp):
    """既存 fixture に小さな 4 / 64 KiB XPRESS 標本を加える。"""
    payload = {
        "chunk-note.txt": b"KaitoKit XPRESS chunk sizes\n",
        "chunk-span.bin": (bytes(range(251)) * 50)[:12503],
        "chunk-large.bin": (bytes(range(251)) * 279)[:70001],
    }
    for name, data in payload.items():
        manifest["payload"][name] = {
            "size": len(data), "sha1": hashlib.sha1(data).hexdigest(),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
    for chunk_size in [4096, 65536]:
        name = f"xpress-{chunk_size // 1024}k.wim"
        data = build_wim([(nest(payload), {})], "xpress", chunk_size=chunk_size)
        path = tmp / name
        path.write_bytes(data)
        verify_with_7zz(path, payload)
        print(f"7zz x: {name}: {len(payload)} files byte-identical")
        store(name, data, manifest, f"自作 XPRESS encoder、{chunk_size} byte chunk、7zz x で全 file 一致")

def main():
    manifest = {"payload": {}}
    small = payload_small(); big = payload_compressed()
    for name, data in {**small, **big}.items():
        manifest["payload"][name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        # stored WIM with alternate data streams, a hard-link pair, an empty file and a reparse point
        ads = {"readme.txt": {"Zone.Identifier": b"[ZoneTransfer]\r\nZoneId=3\r\n"}}
        # [MS-FSCC] REPARSE_DATA_BUFFER with a relative SymbolicLinkReparseBuffer (7-Zip extracts it as `link -> readme.txt`)
        target = "readme.txt".encode("utf-16-le")
        symlink = struct.pack("<HHHHI", 0, len(target), len(target), len(target), 1) + target + target
        reparse_data = {"link": struct.pack("<IHH", 0xA000000C, len(symlink), 0) + symlink}
        tree = nest(small); tree["link"] = reparse_data["link"]
        stored = build_wim([(tree, {"ads": ads, "hardlinks": {"same.txt": 7, "same-copy.txt": 7},
                                    "reparse": {"link": 0xA000000C}, "reparse_data": reparse_data})], "stored")
        (tmp / "stored.wim").write_bytes(stored)
        verify_with_7zz(tmp / "stored.wim", {k: v for k, v in small.items()})
        store("stored.wim", stored, manifest, "own writer, stored resources, ADS on readme.txt, hard-link pair, symlink reparse point")
        # compressed WIMs
        for method, variant in [("xpress", 0), ("lzx", 0), ("lzx", 1)]:
            data = build_wim([(nest(big), {})], method, variant=variant)
            label = f"{method}{'-raw' if variant else ''}.wim"
            (tmp / label).write_bytes(data)
            verify_with_7zz(tmp / label, big)
            store(label, data, manifest, f"own {method.upper()} encoder" + (" with an odd-length uncompressed block at a chunk end" if variant else ""))
        # two images sharing resources
        two = build_wim([(nest(small), {}), (nest({"only-in-2.txt": b"second image\n", "readme.txt": small["readme.txt"]}), {})], "xpress")
        (tmp / "two-images.wim").write_bytes(two)
        with tempfile.TemporaryDirectory() as out:
            subprocess.run(["7zz", "x", "-bso0", "-bsp0", "-o" + out, str(tmp / "two-images.wim")], check=True)
            listing = sorted(str(p.relative_to(out)) for p in pathlib.Path(out).rglob("*") if p.is_file())
            manifest["two-images-7zz-paths"] = listing
        store("two-images.wim", two, manifest, "two images (XPRESS); 7-Zip lists them below 1/ and 2/")
        # 7-Zip's own writer (stored only) as an independent sample
        src = tmp / "src"
        for rel, data in small.items():
            (src / rel).parent.mkdir(parents=True, exist_ok=True); (src / rel).write_bytes(data)
        subprocess.run(["7zz", "a", "-twim", "-bso0", "-bsp0", str(tmp / "sevenzip.wim"), str(src) + "/*"], check=True)
        store("sevenzip-copy.wim", (tmp / "sevenzip.wim").read_bytes(), manifest, "7-Zip 26.03 `a -twim` (stored)")
        add_chunk_size_fixtures(manifest, tmp)
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

if __name__ == "__main__":
    main()
