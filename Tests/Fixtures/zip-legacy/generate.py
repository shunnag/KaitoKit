#!/usr/bin/env python3
"""ZIP fixtures with the legacy PKZIP methods Shrink (1), Reduce (2-5) and Implode (6).

The encoders are written from PKWARE's APPNOTE.TXT 6.3.10 §5.1-5.3 (inbox/zip-legacy/APPNOTE.TXT) plus
two conventions APPNOTE leaves implicit and which the independent readers confirmed black-box: bits are
packed LSB-first within each byte (as for Deflate), and the stream simply ends when the declared
uncompressed size has been produced. Every archive is verified before it is stored:
  - Shrink and Implode: Info-ZIP `unzip -t`, 7-Zip `7zz t` and deark `-l` / extraction
  - Reduce: deark (unzip on macOS is built without UNREDUCE and 7-Zip has no Reduce decoder). deark
    refuses Reduce copies whose distance is shorter than their length, so the Reduce fixtures avoid
    overlapping copies; a 3-byte copy at a distance below 256 cannot be encoded at all because its V
    byte would be 0, the literal-DLE code.
  - Reduce B(1): APPNOTE defines B(N) as "the minimal number of bits required to encode N-1", which for a
    one-element follower set is 0 or 1 depending on reading. deark decodes only the 1-bit form (checked
    2026-09-21 with sets of size 1 and 2 present, 206 / 435 uses), so the encoder and KaitoKit use 1 bit.
  - Shrink partial clear (256,2): APPNOTE does not say what happens to the code emitted just before the
    clear. Three encoder variants were tried black-box (2026-09-21): (A) free every leaf including that
    code, then register "previous + next byte" under the lowest freed code with the freed code as its
    prefix; (A2) protect that code from the clear; (B) register nothing for the step after the clear.
    unzip, 7-Zip and deark all accept only variant A, so the encoder below and KaitoKit's decoder use it.
    Under A an entry whose prefix was freed by the clear can never be reconstructed by a decoder (its prefix
    is later re-used for another string), so the encoder keeps such an entry in its tree, where it occupies
    a code and pins its prefix until a later clear frees it, but never emits it; a 2 MB sweep with 149 clears
    (experiments/stress.py) then decodes identically in all three readers and KaitoKit. shrink-clear.zip
    carries a 70 KB payload that forces three clears; the other payloads never fill the table.
Nothing here comes from a third-party decoder's source.
"""
import base64, hashlib, json, os, pathlib, struct, subprocess, tempfile, zlib

HERE = pathlib.Path(__file__).resolve().parent

# ----------------------------------------------------------------------------- payload

def payload():
    import random
    rnd = random.Random(7)
    text = b"".join(("line %d: the quick brown fox jumps over the lazy dog\n" % (i % 50)).encode() for i in range(600))
    dle = b"ab" + b"\x90" * 300 + b"cd" + b"\x90" + b"ef" + bytes(range(256)) * 4 + b"\x90\x90"
    runs = b"".join(bytes([b]) * n for b, n in [(0x41, 1000), (0x42, 5), (0x90, 3), (0x43, 130), (0x00, 300)]) + b"tail"
    mixed = bytearray()
    for i in range(20000):
        mixed.append((i * 7 + (i >> 3)) & 0xFF if i % 300 < 260 else rnd.getrandbits(8))
    return {
        "text.txt": text,                 # 33 KB, highly repetitive
        "dle.bin": dle,                   # exercises the DLE (0x90) escapes of Reduce
        "runs.bin": runs,                 # long runs (Reduce RLE length overflow, Implode long matches)
        "mixed.bin": bytes(mixed),        # 20 KB semi-random
        "empty.txt": b"",
        "one.txt": b"x",
    }

def clear_payload():
    """Random words from a 400-word vocabulary: fills the 8192-entry LZW table three times."""
    import random
    rnd = random.Random(11)
    alphabet = b"abcdefghijklmnop"
    words = [bytes(rnd.choice(alphabet) for _ in range(rnd.randint(2, 7))) for _ in range(400)]
    return {"words.txt": b" ".join(rnd.choice(words) for _ in range(14000))[:70000]}

# ----------------------------------------------------------------------------- bit writer (LSB first)

class BitWriter:
    def __init__(self): self.out = bytearray(); self.acc = 0; self.n = 0
    def write(self, value, count):
        for i in range(count):
            self.acc |= ((value >> i) & 1) << self.n; self.n += 1
            if self.n == 8: self.out.append(self.acc); self.acc = 0; self.n = 0
    def finish(self):
        if self.n: self.out.append(self.acc)
        return bytes(self.out)

# ----------------------------------------------------------------------------- LZ77 matcher

def longest_match(data, i, window, max_length, chains, min_length):
    """Best (length, back distance) for position i using 3-byte hash chains limited to `window`."""
    n = len(data)
    if i + min_length > n: return 0, 0
    key = data[i:i + 3] if i + 3 <= n else data[i:]
    best_len, best_dist = 0, 0
    for j in reversed(chains.get(key, ())[-64:]):
        if i - j > window: break
        length = 0
        while i + length < n and length < max_length and data[j + length] == data[i + length]:
            length += 1
        if length > best_len: best_len, best_dist = length, i - j
        if best_len >= max_length: break
    return best_len, best_dist

def add_chain(data, i, chains):
    if i + 3 <= len(data): chains.setdefault(data[i:i + 3], []).append(i)

# ----------------------------------------------------------------------------- Shrink (APPNOTE 5.1)

def shrink(data):
    """Dynamic LZW, 9..13 bits, with 256,1 (grow) and 256,2 (partial clear) escapes."""
    w = BitWriter()
    MAXBITS = 13
    table = {bytes([i]): i for i in range(256)}     # string -> code
    parent = {}                                      # code -> (prefix code, byte)
    code_size = 9
    next_code = 257
    free = []                                        # codes reclaimed by a partial clear, lowest first
    def allocate(seq, prefix_code, byte, reachable=True):
        nonlocal next_code
        if free:
            code = free.pop(0)
        elif next_code < (1 << MAXBITS):
            code = next_code; next_code += 1
        else:
            return False
        # The decoder registers the entry either way; when its prefix code was just freed by the clear the
        # entry can never be reconstructed, so keep it in the tree (it occupies a code and pins its prefix
        # until the next clear frees it) but never emit it.
        if reachable: table[seq] = code
        parent[code] = (prefix_code, byte)
        return code
    def partial_clear():
        # free every leaf (a code that is not the prefix of another table entry)
        used_as_prefix = {p for (p, _) in parent.values()}
        leaves = sorted(code for code in parent if code not in used_as_prefix)
        for code in leaves:
            p, b = parent.pop(code)
            seq = [k for k, v in table.items() if v == code]
            for k in seq: del table[k]
        free.extend(leaves)
    i = 0
    current = bytes([data[0]]) if data else b""
    i = 1
    emitted = 0
    while i <= len(data):
        if i < len(data) and current + bytes([data[i]]) in table:
            current += bytes([data[i]]); i += 1; continue
        code = table[current]
        w.write(code, code_size); emitted += 1
        if i == len(data): break
        # add current + next byte
        while True:
            added = allocate(current + bytes([data[i]]), code, data[i], reachable=(code < 256 or code in parent))
            if added is not False: break
            # table full: partial clear (256,2)
            w.write(256, code_size); w.write(2, code_size)
            partial_clear()
            if not free: break
        # grow the code size when the highest code no longer fits (256,1)
        if code_size < MAXBITS and (next_code > (1 << code_size) or (added is not False and added >= (1 << code_size))):
            w.write(256, code_size); w.write(1, code_size); code_size += 1
        current = bytes([data[i]]); i += 1
    return w.finish()

# ----------------------------------------------------------------------------- Reduce (APPNOTE 5.2)

def reduce_rle(data, factor):
    """Stage 1: RLE with DLE 0x90 (the state machine of 5.2.5 run backwards): DLE 0 = literal 0x90;
    DLE V [C] D = copy Len+3 bytes from back distance D(V,C). V must be non-zero, so a 3-byte match at
    a distance below 256 is emitted as literals."""
    lbits = [7, 6, 5, 4][factor - 1]
    lmax = (1 << lbits) - 1
    dbits = 8 - lbits
    dmax = ((1 << dbits) - 1) * 256 + 255 + 1
    out = bytearray()
    chains = {}
    i = 0
    n = len(data)
    while i < n:
        best_len, best_dist = longest_match(data, i, dmax, lmax + 3 + 255, chains, 3)
        # deark (the only Reduce reader at hand) rejects copies that overlap their own output (distance <
        # length), so the fixtures never emit them; KaitoKit's decoder still copies byte by byte per APPNOTE.
        if best_dist and best_len > best_dist: best_len = best_dist
        length = best_len - 3
        distance = best_dist - 1
        if best_len >= 3 and ((distance >> 8) != 0 or min(length, lmax) != 0):
            v = (distance >> 8) << lbits | min(length, lmax)
            out += bytes([0x90, v])
            if min(length, lmax) == lmax:
                out.append(length - lmax)
            out.append(distance & 0xFF)
            for k in range(best_len): add_chain(data, i + k, chains)
            i += best_len
        else:
            if data[i] == 0x90: out += b"\x90\x00"
            else: out.append(data[i])
            add_chain(data, i, chains)
            i += 1
    return bytes(out)

def reduce(data, factor, use_followers=True):
    stream = reduce_rle(data, factor)
    # stage 2: follower sets (up to 32 most frequent followers per byte)
    followers = [[] for _ in range(256)]
    if use_followers and len(stream) > 1:
        counts = [dict() for _ in range(256)]
        last = 0
        for byte in stream:
            counts[last][byte] = counts[last].get(byte, 0) + 1; last = byte
        for j in range(256):
            ranked = sorted(counts[j].items(), key=lambda kv: (-kv[1], kv[0]))
            followers[j] = [b for b, _ in ranked[:32]]
    w = BitWriter()
    for j in range(255, -1, -1):
        w.write(len(followers[j]), 6)
        for byte in followers[j]: w.write(byte, 8)
    # B(N) = bits needed for N-1; deark reads 1 bit (not 0) for a single-element set, see the module docstring.
    def bits_for(n): return max(1, (n - 1).bit_length())
    last = 0
    for byte in stream:
        s = followers[last]
        if not s:
            w.write(byte, 8)
        elif byte in s:
            w.write(0, 1); w.write(s.index(byte), bits_for(len(s)))
        else:
            w.write(1, 1); w.write(byte, 8)
        last = byte
    return w.finish()

# ----------------------------------------------------------------------------- Implode (APPNOTE 5.3)

def sf_lengths(freqs, limit=16):
    import heapq
    freqs = list(freqs)
    while True:
        symbols = [(f, i) for i, f in enumerate(freqs)]
        heap = [(max(f, 1), [i]) for f, i in symbols]      # every symbol gets a code (the tree must be complete)
        heapq.heapify(heap)
        lengths = [0] * len(freqs)
        while len(heap) > 1:
            f1, s1 = heapq.heappop(heap); f2, s2 = heapq.heappop(heap)
            for s in s1 + s2: lengths[s] += 1
            heapq.heappush(heap, (f1 + f2, s1 + s2))
        if max(lengths) <= limit: return lengths
        freqs = [max(1, f // 2) for f in freqs]

def sf_codes(lengths):
    """APPNOTE 5.3.8: stable sort by length, assign from the longest, reverse the 16-bit code."""
    order = sorted(range(len(lengths)), key=lambda i: lengths[i])          # stable
    code = 0; increment = 0; last = 0
    codes = [0] * len(lengths)
    for i in range(len(order) - 1, -1, -1):
        code += increment
        length = lengths[order[i]]
        if length != last:
            last = length; increment = 1 << (16 - last)
        codes[order[i]] = int(format(code, "016b")[::-1], 2)
    return codes

def sf_tree_bytes(lengths):
    """5.3.7: runs of (count, length) as (count-1)<<4 | (length-1); first byte = byte count - 1."""
    out = bytearray()
    i = 0
    while i < len(lengths):
        run = 1
        while i + run < len(lengths) and lengths[i + run] == lengths[i] and run < 16: run += 1
        out.append((run - 1) << 4 | (lengths[i] - 1)); i += run
    return bytes([len(out) - 1]) + bytes(out)

def implode(data, big_window, literal_tree):
    window = 8192 if big_window else 4096
    minimum = 3 if literal_tree else 2
    items = []
    chains = {}
    i = 0; n = len(data)
    while i < n:
        best_len, best_dist = longest_match(data, i, window, 63 + minimum + 255, chains, minimum)
        if best_len >= minimum and best_dist - 1 < window:
            items.append(("M", best_len, best_dist - 1))
            for k in range(best_len): add_chain(data, i + k, chains)
            i += best_len
        else:
            items.append(("L", data[i])); add_chain(data, i, chains); i += 1
    lit_freq = [0] * 256; len_freq = [0] * 64; dist_freq = [0] * 64
    for item in items:
        if item[0] == "L": lit_freq[item[1]] += 1
        else:
            length, distance = item[1], item[2]
            len_freq[min(length - minimum, 63)] += 1
            dist_freq[distance >> (7 if big_window else 6)] += 1
    trees = []
    lit_lengths = sf_lengths(lit_freq) if literal_tree else None
    len_lengths = sf_lengths(len_freq); dist_lengths = sf_lengths(dist_freq)
    w = BitWriter()
    header = bytearray()
    if literal_tree: header += sf_tree_bytes(lit_lengths)
    header += sf_tree_bytes(len_lengths) + sf_tree_bytes(dist_lengths)
    lit_codes = sf_codes(lit_lengths) if literal_tree else None
    len_codes = sf_codes(len_lengths); dist_codes = sf_codes(dist_lengths)
    low_bits = 7 if big_window else 6
    for item in items:
        if item[0] == "L":
            w.write(1, 1)
            if literal_tree: w.write(lit_codes[item[1]], lit_lengths[item[1]])
            else: w.write(item[1], 8)
        else:
            length, distance = item[1], item[2]
            w.write(0, 1)
            w.write(distance & ((1 << low_bits) - 1), low_bits)
            upper = distance >> low_bits
            w.write(dist_codes[upper], dist_lengths[upper])
            symbol = min(length - minimum, 63)
            w.write(len_codes[symbol], len_lengths[symbol])
            if symbol == 63: w.write(length - minimum - 63, 8)
    return bytes(header) + w.finish()

# ----------------------------------------------------------------------------- ZIP container

def zip_archive(members):
    """members: list of (name, method, flags, compressed, original)."""
    out = bytearray(); central = bytearray()
    for name, method, flags, compressed, original in members:
        crc = zlib.crc32(original) & 0xFFFFFFFF
        encoded = name.encode()
        local_offset = len(out)
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, flags, method, 0, 0x5C21, crc, len(compressed), len(original), len(encoded), 0)
        out += encoded + compressed
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, flags, method, 0, 0x5C21, crc, len(compressed), len(original),
                               len(encoded), 0, 0, 0, 0, 0, local_offset) + encoded
    cd_offset = len(out)
    out += central
    out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(members), len(members), len(central), cd_offset, 0)
    return bytes(out)

# ----------------------------------------------------------------------------- verification

def verify(path, files, readers):
    for reader in readers:
        with tempfile.TemporaryDirectory() as tmp:
            if reader == "unzip":
                subprocess.run(["unzip", "-q", "-o", str(path), "-d", tmp], check=True)
            elif reader == "7zz":
                subprocess.run(["7zz", "x", "-bso0", "-bsp0", "-o" + tmp, str(path)], check=True)
            elif reader == "deark":
                subprocess.run(["deark", "-q", "-od", tmp, "-o", "x", str(path)], check=True)
            for name, data in files.items():
                if reader == "deark":
                    candidates = list(pathlib.Path(tmp).glob("*" + name))
                    if data == b"" and not candidates: continue          # deark skips empty members
                    assert candidates, f"{path.name}: deark wrote no {name}"
                    actual = candidates[0].read_bytes()
                else:
                    actual = pathlib.Path(tmp, name).read_bytes()
                assert actual == data, f"{path.name}: {reader} differs on {name}"

def store(name, data, manifest, note, readers):
    (HERE / f"{name}.b64").write_text(base64.encodebytes(data).decode())
    manifest[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "note": note, "verifiedBy": readers}
    print(f"{name}: {len(data)} bytes, verified by {', '.join(readers)}")

def main():
    files = payload()
    manifest = {"payload": {k: {"size": len(v), "sha256": hashlib.sha256(v).hexdigest()} for k, v in files.items()}}
    manifest["clearPayload"] = {k: {"size": len(v), "sha256": hashlib.sha256(v).hexdigest()} for k, v in clear_payload().items()}
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        def build(label, method_for, flags_for, encode, readers, note, files=files):
            members = []
            for name, data in files.items():
                method = method_for(name)
                compressed = encode(name, data) if method else data
                members.append((name, method, flags_for(name), compressed, data))
            archive = zip_archive(members)
            path = tmp / label; path.write_bytes(archive)
            verify(path, files, readers)
            store(label, archive, manifest, note, readers)
        build("shrink.zip", lambda n: 1, lambda n: 0, lambda n, d: shrink(d), ["unzip", "7zz", "deark"], "method 1 Shrink, own LZW encoder")
        build("shrink-clear.zip", lambda n: 1, lambda n: 0, lambda n, d: shrink(d), ["unzip", "7zz", "deark"],
              "method 1 Shrink with three partial clears (256,2)", files=clear_payload())
        for factor in range(1, 5):
            build(f"reduce{factor}.zip", lambda n: 1 + factor, lambda n: 0, lambda n, d: reduce(d, factor),
                  ["deark"], f"method {1 + factor} Reduce factor {factor}, follower sets + DLE RLE")
        build("reduce-empty-sets.zip", lambda n: 2, lambda n: 0, lambda n, d: reduce(d, 1, use_followers=False),
              ["deark"], "method 2 with every follower set empty")
        variants = [("implode-4k-2trees.zip", False, False), ("implode-8k-3trees.zip", True, True), ("implode-4k-3trees.zip", False, True), ("implode-8k-2trees.zip", True, False)]
        for label, big, literal in variants:
            flags = (2 if big else 0) | (4 if literal else 0)
            build(label, lambda n: 6, lambda n, f=flags: f, lambda n, d, b=big, l=literal: implode(d, b, l),
                  ["unzip", "7zz", "deark"], f"method 6 Implode, {'8K' if big else '4K'} window, {'3' if literal else '2'} trees")
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

if __name__ == "__main__":
    main()
