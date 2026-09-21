#!/usr/bin/env python3
"""Compound File Binary ([MS-CFB]) fixtures written by a project-owned writer and verified with 7-Zip.

The writer follows [MS-CFB] v20240423 (inbox/cfb/MS-CFB.pdf) §2.2 (header), §2.3 (FAT), §2.4 (mini FAT and the
mini stream held by the root entry), §2.5 (DIFAT in the header and, for large files, in DIFAT sectors), §2.6
(128-byte directory entries, red-black sibling trees; every node is written black, which the specification
allows) and §2.7 (stream sector chains). Streams below the 4096-byte cutoff live in the mini stream (64-byte
mini sectors), the others in normal sectors. `interleave=True` writes the sectors of the large streams round-robin
so their chains are fragmented. No CFB writer is installed here and 7-Zip cannot write CFB, so every archive is
extracted with `7zz x` and compared with the payload before it is stored. 7-Zip renames a stream whose name
starts with a control character (`\\x05SummaryInformation` is listed as `[5]SummaryInformation`), which is also
how KaitoKit publishes such names. No third-party CFB implementation source was consulted.
"""
import base64, gzip, hashlib, json, pathlib, shutil, struct, subprocess, tempfile

HERE = pathlib.Path(__file__).resolve().parent
ENDOFCHAIN, FREESECT, FATSECT, DIFSECT, NOSTREAM = 0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFD, 0xFFFFFFFC, 0xFFFFFFFF

# ------------------------------------------------------------------------------------------------ payload

def payload():
    text = b"".join(b"compound file stream line %03d\n" % i for i in range(200))          # 6,200 bytes (normal)
    return {
        "small.txt": b"tiny stream in the mini stream\n",                                   # mini
        "exactly4095.bin": bytes((i * 7) & 0xFF for i in range(4095)),                       # mini (largest)
        "exactly4096.bin": bytes((i * 11) & 0xFF for i in range(4096)),                      # normal (cutoff)
        "large-a.bin": bytes(((i * 13) ^ (i >> 5)) & 0xFF for i in range(20_000)),          # normal, interleaved
        "large-b.txt": text * 3,                                                             # normal, interleaved
        "empty.txt": b"",
        "Storage One/inner.txt": b"nested stream\n",
        "Storage One/Deeper/deepest.bin": bytes(range(256)) * 2,
        "Storage One/Deeper/" + "n" * 31: b"thirty-one character name\n",
        "\x05SummaryInformation": b"property set placeholder " * 4,
        "日本語ストレージ/名前.txt": "日本語の内容\n".encode(),
    }

# ------------------------------------------------------------------------------------------------ writer

class Node:
    def __init__(self, name, kind, data=b"", clsid=bytes(16), modified=0):
        self.name = name; self.kind = kind; self.data = data; self.clsid = clsid; self.modified = modified
        self.children = []; self.sid = None; self.start = ENDOFCHAIN; self.left = self.right = self.child = NOSTREAM

def build_tree(files):
    root = Node("Root Entry", 5)
    for path, data in files.items():
        parts = path.split("/")
        node = root
        for part in parts[:-1]:
            found = next((c for c in node.children if c.name == part), None)
            if found is None:
                found = Node(part, 1, clsid=hashlib.md5(part.encode()).digest(), modified=0x01D9_0000_0000_0000 + len(part))
                node.children.append(found)
            node = found
        node.children.append(Node(parts[-1], 2, data))
    return root

def sort_key(node):
    # §2.6.4: shorter names (in UTF-16 bytes, including the terminator) first, then uppercased UTF-16 code units.
    upper = node.name.upper().encode("utf-16-le")
    return (len(node.name.encode("utf-16-le")) + 2, list(struct.unpack("<%dH" % (len(upper) // 2), upper)))

def balanced(nodes):
    """Return the root of a balanced binary tree over the sorted nodes, wiring left/right."""
    if not nodes: return None
    mid = len(nodes) // 2
    node = nodes[mid]
    left = balanced(nodes[:mid]); right = balanced(nodes[mid + 1:])
    node.left = left.sid if left else NOSTREAM
    node.right = right.sid if right else NOSTREAM
    return node

def write_cfb(files, version=3, interleave=False):
    sector_size = 512 if version == 3 else 4096
    fat_per_sector = sector_size // 4
    root = build_tree(files)
    # assign stream IDs depth-first in creation order (root = 0)
    order = []
    def collect(node):
        node.sid = len(order); order.append(node)
        for child in node.children: collect(child)
    collect(root)
    for node in order:
        if node.children:
            kids = sorted(node.children, key=sort_key)
            node.child = balanced(kids).sid

    sectors = {}                                   # sector number -> bytes
    fat = []                                       # entries; extended as sectors are allocated
    def alloc():
        n = len(fat); fat.append(FREESECT); return n
    def write_chain(data, mark=None):
        if not data: return ENDOFCHAIN
        count = (len(data) + sector_size - 1) // sector_size
        numbers = [alloc() for _ in range(count)]
        for i, n in enumerate(numbers):
            sectors[n] = data[i * sector_size:(i + 1) * sector_size].ljust(sector_size, b"\0")
            fat[n] = numbers[i + 1] if i + 1 < count else ENDOFCHAIN
        return numbers[0]

    # mini stream: gather small streams
    mini = bytearray(); minifat = []
    for node in order:
        if node.kind == 2 and 0 < len(node.data) < 4096:
            count = (len(node.data) + 63) // 64
            node.start = len(minifat)
            for i in range(count):
                mini += node.data[i * 64:(i + 1) * 64].ljust(64, b"\0")
                minifat.append(len(minifat) + 1 if i + 1 < count else ENDOFCHAIN)
    # large streams, optionally interleaved sector by sector
    large = [n for n in order if n.kind == 2 and len(n.data) >= 4096]
    if interleave and len(large) > 1:
        pieces = {n.sid: [n.data[i:i + sector_size] for i in range(0, len(n.data), sector_size)] for n in large}
        prev = {}
        round_index = 0
        while any(pieces.values()):
            for n in large:
                if not pieces[n.sid]: continue
                s = alloc(); sectors[s] = pieces[n.sid].pop(0).ljust(sector_size, b"\0"); fat[s] = ENDOFCHAIN
                if n.sid in prev: fat[prev[n.sid]] = s
                else: n.start = s
                prev[n.sid] = s
            round_index += 1
    else:
        for n in large: n.start = write_chain(n.data)
    root.start = write_chain(bytes(mini)); root.data = bytes(mini)
    minifat_start = ENDOFCHAIN; minifat_sectors = 0
    if minifat:
        raw = b"".join(struct.pack("<I", v) for v in minifat)
        raw = raw.ljust(((len(raw) + sector_size - 1) // sector_size) * sector_size, b"\xff")
        minifat_start = write_chain(raw); minifat_sectors = len(raw) // sector_size
    # directory
    entries = bytearray()
    for node in order:
        name = node.name.encode("utf-16-le") + b"\0\0"
        size = len(node.data) if node.kind in (2, 5) else 0
        entries += name.ljust(64, b"\0")
        entries += struct.pack("<HBBIII", len(name), node.kind, 1, node.left, node.right, node.child)
        entries += (node.clsid if node.kind in (1, 5) else bytes(16))
        entries += struct.pack("<IQQIQ", 0, 0, node.modified if node.kind == 1 else 0, node.start if node.kind in (2, 5) else 0, size)
    while len(entries) % sector_size: entries += bytes(64) + struct.pack("<HBBIII", 0, 0, 0, NOSTREAM, NOSTREAM, NOSTREAM) + bytes(16 + 4 + 8 + 8 + 4 + 8)
    dir_start = write_chain(bytes(entries)); dir_sectors = len(entries) // sector_size
    # FAT + DIFAT sizing (iterate until stable)
    fat_sector_count = 0; difat_sector_count = 0
    while True:
        total = len(fat) + fat_sector_count + difat_sector_count
        need_fat = (total + fat_per_sector - 1) // fat_per_sector
        need_difat = 0 if need_fat <= 109 else (need_fat - 109 + (fat_per_sector - 1) - 1) // (fat_per_sector - 1)
        if need_fat == fat_sector_count and need_difat == difat_sector_count: break
        fat_sector_count, difat_sector_count = need_fat, need_difat
    fat_numbers = [alloc() for _ in range(fat_sector_count)]
    for n in fat_numbers: fat[n] = FATSECT
    difat_numbers = [alloc() for _ in range(difat_sector_count)]
    for n in difat_numbers: fat[n] = DIFSECT
    while len(fat) % fat_per_sector: fat.append(FREESECT)
    assert len(fat) == fat_sector_count * fat_per_sector
    for i, n in enumerate(fat_numbers):
        sectors[n] = b"".join(struct.pack("<I", v) for v in fat[i * fat_per_sector:(i + 1) * fat_per_sector])
    header_difat = fat_numbers[:109] + [FREESECT] * (109 - min(109, len(fat_numbers)))
    rest = fat_numbers[109:]
    for i, n in enumerate(difat_numbers):
        chunk = rest[i * (fat_per_sector - 1):(i + 1) * (fat_per_sector - 1)]
        chunk += [FREESECT] * (fat_per_sector - 1 - len(chunk))
        nxt = difat_numbers[i + 1] if i + 1 < len(difat_numbers) else ENDOFCHAIN
        sectors[n] = b"".join(struct.pack("<I", v) for v in chunk + [nxt])
    header = struct.pack("<8s16sHHHHH6sIIIIIIIII",
                         bytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]), bytes(16), 0x3E, version, 0xFFFE,
                         9 if version == 3 else 12, 6, bytes(6),
                         dir_sectors if version == 4 else 0, fat_sector_count, dir_start, 0, 4096,
                         minifat_start, minifat_sectors, difat_numbers[0] if difat_numbers else ENDOFCHAIN, difat_sector_count)
    header += b"".join(struct.pack("<I", v) for v in header_difat)
    assert len(header) == 512
    header = header.ljust(sector_size, b"\0")
    # §2.3: the file ends after the last non-free FAT entry (7-Zip warns about sectors past that point).
    last = max(n for n, v in enumerate(fat) if v != FREESECT)
    out = bytearray(header)
    for n in range(last + 1):
        out += sectors.get(n, bytes(sector_size))
    return bytes(out)

# ------------------------------------------------------------------------------------------------ MSI names

# Windows Installer packs table and stream names into UTF-16 units U+3800..U+4840 (no public specification).
# The mapping below was derived black-box on 2026-09-21 from 7-Zip 26.03's listing of a real MSI (23 names)
# and of hand-made compound files probing digits, '.', '_', lone '!' units, U+47FF, and out-of-range units:
# a unit in U+3800..U+47FF carries two characters (low 6 bits first), U+4800..U+483F one character, U+4840 is
# '!', anything else passes through, and 7-Zip decodes every such unit regardless of the root CLSID.
MSI_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._"

def msi_encode(name):
    out = ""; i = 0
    while i < len(name):
        if name[i] == "!": out += chr(0x4840); i += 1; continue
        a = MSI_ALPHABET.index(name[i])
        if i + 1 < len(name) and name[i + 1] in MSI_ALPHABET:
            out += chr(0x3800 + a + 64 * MSI_ALPHABET.index(name[i + 1])); i += 2
        else:
            out += chr(0x4800 + a); i += 1
    return out

def msi_decode(name):
    out = ""
    for ch in name:
        u = ord(ch)
        if 0x3800 <= u <= 0x47FF: v = u - 0x3800; out += MSI_ALPHABET[v % 64] + MSI_ALPHABET[v // 64]
        elif 0x4800 <= u <= 0x483F: out += MSI_ALPHABET[u - 0x4800]
        elif u == 0x4840: out += "!"
        else: out += ch
    return out

def msi_payload():
    # the two alphabets get distinct suffixes: extracting both onto a case-insensitive file system would otherwise
    # make 7-Zip ask whether to overwrite
    names = ["!_Tables", "!_StringPool", "Binary.WrappedExe", "setup.cab", "0123456789", "ABCDEFGHIJKLMNOPQRSTUVWXYZ.1",
             "abcdefghijklmnopqrstuvwxyz.2", "ABCXYZabcxyz._", "odd", "!!5", "Mixed_Name.9"]
    files = {msi_encode(n): f"content of {n}\n".encode() for n in names}
    assert all(msi_decode(k) == n for k, n in zip(files, names))
    files[chr(0x4841) + chr(0x4802)] = b"unit U+4841 is outside the packed range\n"   # 7-Zip: "\u4841" + "2"
    files["plain-name.txt"] = b"plain\n"
    return files

# ------------------------------------------------------------------------------------------------ verification

def published(path):
    """7-Zip's spelling of a stream path: packed MSI units decoded, control characters as [n]."""
    return "/".join("".join(f"[{ord(c)}]" if ord(c) < 0x20 else c for c in msi_decode(part)) for part in path.split("/"))

def verify_with_7zz(archive, files):
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp, "f.cfb"); path.write_bytes(archive)
        out = pathlib.Path(tmp, "x")
        subprocess.run(["7zz", "x", "-bso0", "-bsp0", "-o" + str(out), str(path)], check=True)
        for name, data in files.items():
            candidate = out / published(name)
            assert candidate.exists(), f"7zz did not extract {name!r} as {published(name)!r}"
            assert candidate.read_bytes() == data, f"7zz content differs for {name}"

def store(name, data, manifest, note):
    encoded = base64.encodebytes(gzip.compress(data, mtime=0)).decode()
    (HERE / f"{name}.gz.b64").write_text(encoded)
    manifest[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "note": note}
    print(f"{name}: {len(data)} bytes -> {len(encoded)} b64 chars")

def main():
    files = payload()
    # A 7.2 MB stream pushes the FAT past the 109 header DIFAT entries, so the DIFAT continues in a DIFAT sector
    # (§2.5). Orphan sectors (allocated in the FAT but referenced by no stream) were tried first for this and
    # 7-Zip refuses to open such a file, so the growth comes from a real stream.
    difat_files = dict(files); difat_files["filler.bin"] = bytes(7_200_000)
    manifest = {"payload": {k: {"size": len(v), "sha256": hashlib.sha256(v).hexdigest(), "published": published(k)}
                            for k, v in {**difat_files, **msi_payload()}.items()}}
    for name, kwargs, contents, note in [
        ("v3.cfb", dict(version=3), files, "version 3 (512-byte sectors), mini stream, nested storages"),
        ("v3-interleaved.cfb", dict(version=3, interleave=True), files, "version 3 with the large streams' sectors interleaved"),
        ("v4.cfb", dict(version=4), files, "version 4 (4096-byte sectors, 64-bit sizes)"),
        ("v3-difat.cfb", dict(version=3), difat_files, "version 3 with 112 FAT sectors: the DIFAT continues in a DIFAT sector"),
        ("msi-names.cfb", dict(version=3), msi_payload(), "stream names packed the Windows Installer way (root CLSID zero); 7-Zip decodes them"),
    ]:
        archive = write_cfb(contents, **kwargs)
        verify_with_7zz(archive, contents)
        store(name, archive, manifest, note)
        manifest[name]["files"] = sorted(contents)
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

if __name__ == "__main__":
    main()
