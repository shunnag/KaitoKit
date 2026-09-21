#!/usr/bin/env python3
"""ARJ fixtures written by a project-owned writer and verified with 7-Zip, deark and unar.

Container: ARJ TECHNOTE.TXT (ARJ 2.86 distribution, September 2005 text; the trailing find_header() C excerpt was
cut before reading — inbox/arj/technote-2012-prose.txt) and the CC0 Archive Team wiki page on ARJ. Method 1 data
is produced by an LZ77 + static-Huffman encoder written from the public description of the LHA lh5/lh6 bit
stream (the same one KaitoKit's LHA decoder was written from: 16-bit block code count, the 19-symbol code-length
tree with the 3-bit-plus-unary lengths and the 2-bit zero skip after the third symbol, the 510-symbol code tree
with zero-run symbols 0/1/2, the 16-symbol position tree, match length = symbol - 253, distance = position code +
extra bits + 1), because the Archive Team wiki states ARJ methods 1-3 are "essentially the same as LHA's lh6
method, but with the history window artificially limited to 26K". The encoder keeps distances <= 26624.
No ARJ writer is installed here and 7-Zip cannot write ARJ, so every archive is extracted with `7zz x` (and
`deark`, `unar` where noted) and compared with the payload before it is stored. No third-party ARJ / LHA
implementation source was consulted.
"""
import base64, hashlib, heapq, json, pathlib, struct, subprocess, tempfile, zlib
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent

# ------------------------------------------------------------------------------------------------ payload

def payload():
    text = b"".join(b"ARJ sample line %03d: the quick brown fox jumps over the lazy dog\r\n" % i for i in range(400))
    return {
        "README.TXT": text,                                                          # 27 KB, repetitive (method 1)
        "DATA/TABLE.BIN": bytes(((i * 17) ^ (i >> 6)) & 0xFF for i in range(30_000)),   # crosses the 26 KB window
        "DATA/SUB/DEEP.TXT": b"deep\r\n" * 50,
        "EMPTY.TXT": b"",
        "STORED.BIN": bytes(range(256)) * 3,                                          # method 0
        "\x93\xfa\x96\x7b\x8c\xea.TXT": "日本語の内容\r\n".encode("cp932") * 100,   # CP932 name (DOS host)
    }

# ------------------------------------------------------------------------------------------------ lh6 encoder

class Bits:
    def __init__(self): self.out = bytearray(); self.acc = 0; self.n = 0
    def put(self, value, width):
        assert 0 <= value < (1 << width) or width == 0, (value, width)
        for i in range(width - 1, -1, -1):
            self.acc = (self.acc << 1) | ((value >> i) & 1); self.n += 1
            if self.n == 8: self.out.append(self.acc); self.acc = 0; self.n = 0
    def finish(self):
        if self.n: self.out.append(self.acc << (8 - self.n)); self.acc = 0; self.n = 0
        return bytes(self.out)

def limited_lengths(freqs, limit):
    """Huffman code lengths capped at `limit` (package-merge would be exact; a simple rebalancing suffices here)."""
    symbols = [s for s, f in enumerate(freqs) if f]
    if not symbols: return [0] * len(freqs)
    if len(symbols) == 1: return [1 if s == symbols[0] else 0 for s in range(len(freqs))]
    heap = [(freqs[s], s, [s]) for s in symbols]; heapq.heapify(heap)
    lengths = [0] * len(freqs)
    while len(heap) > 1:
        f1, _, a = heapq.heappop(heap); f2, _, b = heapq.heappop(heap)
        for s in a + b: lengths[s] += 1
        heapq.heappush(heap, (f1 + f2, min(a + b), a + b))
    while max(lengths) > limit:
        # flatten: take the deepest symbol and the shallowest leaf that can be split
        deep = max(range(len(lengths)), key=lambda s: lengths[s])
        shallow = min((s for s in symbols if lengths[s] < limit - 1), key=lambda s: lengths[s], default=None)
        if shallow is None: raise ValueError("cannot limit code lengths")
        lengths[deep] -= 1; lengths[shallow] += 1
        # restore Kraft equality by shortening any symbol whose sibling slot is free
        while sum(2.0 ** -l for s, l in enumerate(lengths) if l) < 1.0:
            cand = max((s for s in symbols if lengths[s] > 1), key=lambda s: lengths[s])
            lengths[cand] -= 1
            if sum(2.0 ** -l for s, l in enumerate(lengths) if l) > 1.0: lengths[cand] += 1; break
    assert abs(sum(2.0 ** -l for l in lengths if l) - 1.0) < 1e-9, "Kraft"
    return lengths

def canonical(lengths):
    if (only := constant_symbol(lengths)) is not None: return {only: (0, 0)}
    codes = {}; code = 0
    for length in range(1, 17):
        for s, l in enumerate(lengths):
            if l == length: codes[s] = (code, length); code += 1
        code <<= 1
    return codes

def find_matches(data, window=26624, max_length=256, min_length=3):
    """Greedy LZ77 with 3-byte hash chains; yields (literal) or (length, distance)."""
    head = {}; prev = [-1] * len(data); tokens = []; i = 0; n = len(data)
    def insert(pos):
        if pos + 2 < n:
            key = data[pos:pos + 3]; prev[pos] = head.get(key, -1); head[key] = pos
    while i < n:
        best_len, best_dist = 0, 0
        if i + 2 < n:
            cand = head.get(data[i:i + 3], -1); tries = 0
            while cand >= 0 and i - cand <= window and tries < 48:
                l = 0
                while l < max_length and i + l < n and data[cand + l] == data[i + l]: l += 1
                if l > best_len: best_len, best_dist = l, i - cand
                cand = prev[cand]; tries += 1
        if best_len >= min_length:
            tokens.append((best_len, best_dist))
            for k in range(best_len): insert(i + k)
            i += best_len
        else:
            tokens.append((data[i],)); insert(i); i += 1
    return tokens

def position_code(distance):
    offset = distance - 1
    if offset == 0: return 0, 0, 0
    p = offset.bit_length()                 # p >= 1; extra bits = p - 1
    return p, offset - (1 << (p - 1)), p - 1

def constant_symbol(lengths):
    """If exactly one symbol is used, the tree is written as `0, symbol` and its code is empty (0 bits)."""
    used = [s for s, l in enumerate(lengths) if l]
    return used[0] if len(used) == 1 else None

def write_pt_lengths(bits, lengths, nbit, special):
    """read_pt_len counterpart: count, then 3-bit lengths (7 + unary above 6), with a 2-bit zero skip after index `special`."""
    n = len(lengths)
    while n > 0 and lengths[n - 1] == 0: n -= 1
    if n == 0 or constant_symbol(lengths) is not None:
        bits.put(0, nbit); bits.put(constant_symbol(lengths) or 0, nbit); return
    bits.put(n, nbit)
    i = 0
    while i < n:
        l = lengths[i]
        if l < 7: bits.put(l, 3)
        else: bits.put(7, 3); bits.put((1 << (l - 7)) - 1, l - 7); bits.put(0, 1)
        i += 1
        if i == special:
            zeros = 0
            while i + zeros < n and lengths[i + zeros] == 0 and zeros < 3: zeros += 1
            bits.put(zeros, 2); i += zeros

def write_c_lengths(bits, c_lengths, pt_codes):
    """read_c_len counterpart: 9-bit count, then symbols of the pt tree (0/1/2 = zero runs, else length + 2)."""
    n = len(c_lengths)
    while n > 0 and c_lengths[n - 1] == 0: n -= 1
    if n == 0 or constant_symbol(c_lengths) is not None:
        bits.put(0, 9); bits.put(constant_symbol(c_lengths) or 0, 9); return
    bits.put(n, 9)
    i = 0
    while i < n:
        if c_lengths[i] == 0:
            run = 0
            while i + run < n and c_lengths[i + run] == 0 and run < 20 + 511: run += 1
            # symbol 0 = one zero, symbol 1 = 3..18 zeros (4 bits), symbol 2 = 20..531 zeros (9 bits); 19 is split.
            if run <= 2:
                for _ in range(run): bits.put(*pt_codes[0])
            elif run <= 18:
                bits.put(*pt_codes[1]); bits.put(run - 3, 4)
            elif run == 19:
                bits.put(*pt_codes[1]); bits.put(15, 4); bits.put(*pt_codes[0])
            else:
                bits.put(*pt_codes[2]); bits.put(run - 20, 9)
            i += run
        else:
            bits.put(*pt_codes[c_lengths[i] + 2]); i += 1

def lh6_pt_symbols(c_lengths):
    """The symbols the code-length (pt) tree must carry for `c_lengths`."""
    n = len(c_lengths)
    while n > 0 and c_lengths[n - 1] == 0: n -= 1
    freqs = [0] * 19; i = 0
    while i < n:
        if c_lengths[i] == 0:
            run = 0
            while i + run < n and c_lengths[i + run] == 0 and run < 20 + 511: run += 1
            if run <= 2: freqs[0] += run
            elif run <= 18: freqs[1] += 1
            elif run == 19: freqs[1] += 1; freqs[0] += 1
            else: freqs[2] += 1
            i += run
        else:
            freqs[c_lengths[i] + 2] += 1; i += 1
    return freqs

def lh6_compress(data, block_codes=4096):
    tokens = find_matches(data)
    bits = Bits()
    for start in range(0, max(len(tokens), 1), block_codes):
        block = tokens[start:start + block_codes]
        c_freq = [0] * 510; p_freq = [0] * 16
        for t in block:
            if len(t) == 1: c_freq[t[0]] += 1
            else:
                c_freq[t[0] + 253] += 1
                p_freq[position_code(t[1])[0]] += 1
        c_len = limited_lengths(c_freq, 16); p_len = limited_lengths(p_freq, 16)
        t_len = limited_lengths(lh6_pt_symbols(c_len), 16)
        c_codes, p_codes, t_codes = canonical(c_len), canonical(p_len), canonical(t_len)
        bits.put(len(block), 16)
        write_pt_lengths(bits, t_len, 5, 3)
        write_c_lengths(bits, c_len, t_codes)
        write_pt_lengths(bits, p_len, 5, -1)
        for t in block:
            if len(t) == 1: bits.put(*c_codes[t[0]])
            else:
                bits.put(*c_codes[t[0] + 253])
                p, extra, width = position_code(t[1])
                bits.put(*p_codes[p])
                if width: bits.put(extra, width)
    return bits.finish()

# ------------------------------------------------------------------------------------------------ ARJ writer

def dos_time(year=2001, month=9, day=18, hour=12, minute=34, second=56):
    return ((year - 1980) << 25) | (month << 21) | (day << 16) | (hour << 11) | (minute << 5) | (second // 2)

def header(first, name, comment=b"", extended=()):
    basic = first + name + b"\0" + comment + b"\0"
    out = b"\x60\xea" + struct.pack("<H", len(basic)) + basic + struct.pack("<I", zlib.crc32(basic))
    for body in extended:
        out += struct.pack("<H", len(body)) + body + struct.pack("<I", zlib.crc32(body))
    return out + b"\0\0"

def main_header(archive_name=b"FIXTURE.ARJ", comment=b"", flags=0x10, host=0, version=11):
    first = struct.pack("<BBBBBBBBIIIIHHBB", 34, version, 1, host, flags, 2, 2, 0, dos_time(), dos_time(), 0, 0, 0, 0, 0, 0)
    first += struct.pack("<BBH", 0, 0, 0)      # extra data: protection factor, second flags, spare
    assert len(first) == 34
    return header(first, archive_name, comment)

def file_header(name, original, compressed, method, file_type=0, flags=0x10, host=0, comment=b"", extra=b"", garbled=False, extended=()):
    first_size = 30 + len(extra)
    first = struct.pack("<BBBBBBBBIIIIHHBB", first_size, 11, 1, host, flags | (0x01 if garbled else 0), method, file_type, 0,
                        dos_time(), len(compressed), len(original), zlib.crc32(original) if file_type != 3 else 0, 0, 0x20, 1, 1) + extra
    return header(first, name, comment, extended)

def build_arj(files, method=1, host=0, pathsym=True, sfx=None, comment=b"", garbled_name=None, extended=False, no_data=False):
    flags = 0x10 if pathsym else 0
    out = bytearray(sfx or b"")
    out += main_header(comment=comment, host=host, flags=flags)
    dirs = sorted({"/".join(n.split("/")[:i]) for n in files for i in range(1, len(n.split("/")))})
    sep = b"/" if pathsym else b"\\"
    for d in dirs:
        out += file_header(sep.join(d.encode("latin-1").split(b"/")), b"", b"", 0, file_type=3, flags=flags, host=host)
    for name, data in files.items():
        raw = sep.join(name.encode("latin-1").split(b"/"))
        m = 0 if name.startswith("STORED") or not data else method
        body = data if m == 0 else lh6_compress(data)
        if garbled_name == name:
            body = bytes(b ^ 0x5A for b in body)
        ext = (b"extended header payload",) if extended and name == "README.TXT" else ()
        out += file_header(raw, data, body, m, flags=flags, host=host, garbled=garbled_name == name,
                           comment=b"has an extended header" if ext else b"", extended=ext)
        out += body
    if no_data:
        out += file_header(b"NODATA.TXT", b"", b"", 9, flags=flags, host=host)
    out += b"\x60\xea\0\0"
    return bytes(out)

# ------------------------------------------------------------------------------------------------ verification

def verify(archive, files, readers=("7zz", "deark", "unar"), suffix=".arj"):
    with tempfile.TemporaryDirectory() as tmp:
        # 7-Zip picks the handler from the extension first: an SFX must be verified under its .exe name.
        path = pathlib.Path(tmp, "f" + suffix); path.write_bytes(archive)
        for reader in readers:
            out = pathlib.Path(tmp, reader); out.mkdir()
            if reader == "7zz": subprocess.run(["7zz", "x", "-bso0", "-bsp0", "-o" + str(out), str(path)], check=True)
            elif reader == "deark": subprocess.run(["deark", "-q", "-od", str(out), "-o", "x", str(path)], check=True)
            else: subprocess.run(["unar", "-q", "-D", "-o", str(out), str(path)], check=True)
            extracted = {p: p.read_bytes() for p in out.rglob("*") if p.is_file()}
            for name, data in files.items():
                direct = out / name
                if direct.is_file():
                    assert direct.read_bytes() == data, f"{reader} differs on {name!r}"
                    continue
                # deark prefixes names and the readers spell the CP932 name differently (7-Zip keeps the raw bytes,
                # unar decodes it as CP1252): match those members by content.
                leaf = name.split("/")[-1]
                hits = [p for p, content in extracted.items() if content == data and (p.name.endswith(leaf) or not leaf.isascii())]
                if data == b"" and reader == "deark": continue          # deark skips empty members
                assert hits, f"{reader} wrote no member matching {name!r}"

def store(name, data, manifest, note, readers):
    (HERE / f"{name}.b64").write_text(base64.encodebytes(data).decode())
    manifest[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "note": note, "verifiedBy": list(readers)}
    print(f"{name}: {len(data)} bytes, verified by {', '.join(readers)}")

def main():
    files = payload()
    manifest = {"payload": {k.encode("latin-1").decode("cp932"): {"size": len(v), "sha256": hashlib.sha256(v).hexdigest()} for k, v in files.items()}}
    # a small MZ stub: 'MZ' + zeros + text, long enough to exercise the header search
    stub = b"MZ" + bytes(510) + b"This program requires ARJ. " * 40 + b"\x60\xea\x0b\x00garbage"     # fake id with bad CRC
    for name, kwargs, note, readers in [
        ("basic.arj", dict(), "method 1 (lh6-equivalent) + stored, directories, CP932 name, PATHSYM names", ("7zz", "deark", "unar")),
        ("backslash.arj", dict(pathsym=False), "DOS names with backslash separators (no PATHSYM flag)", ("7zz", "deark", "unar")),
        ("sfx.exe", dict(sfx=stub, comment=b"self-extracting fixture"), "ARJ main header after an MZ stub and a decoy header id", ("7zz", "unar")),
    ]:
        archive = build_arj(files, **kwargs)
        verify(archive, files, readers, suffix=pathlib.Path(name).suffix)
        store(name, archive, manifest, note, readers)
    # An extended header (size, body, CRC; technote: "currently not used") written on README.TXT is accepted by 7-Zip
    # but rejected by unar ("Data is corrupted"), and no real archive carries one, so no such fixture is stored.
    # method 9 (no data): 7-Zip reports "Unsupported Method" for that member, so the other members are verified and
    # NODATA.TXT is only checked by KaitoKit's own tests.
    archive = build_arj(files, no_data=True)
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp, "f.arj"); path.write_bytes(archive)
        listing = subprocess.run(["7zz", "l", "-slt", str(path)], capture_output=True, text=True).stdout
        assert "Path = NODATA.TXT" in listing
    store("nodata.arj", archive, manifest, "a method 9 (no data, size 0) member after the payload; 7-Zip lists it but cannot extract it", ("7zz (listing only)",))
    # garbled: the reader must refuse; 7-Zip lists the file as encrypted (not verified by extraction)
    archive = build_arj(files, garbled_name="README.TXT")
    store("garbled.arj", archive, manifest, "README.TXT flagged garbled (bytes xor 0x5A); readers refuse it", ())
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

if __name__ == "__main__":
    main()
