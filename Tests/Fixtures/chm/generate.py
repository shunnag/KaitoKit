#!/usr/bin/env python3
"""HTML Help (.chm, ITSF) fixtures written by a project-owned writer and verified with 7-Zip.

Container layout follows Matthew Russotto's "Microsoft's HTML Help (.chm) format" (inbox/chm/chmformat-wayback.html:
ITSF header, header sections, ITSP directory with PMGL listing / PMGI index chunks, ENCINTs, the NameList,
ControlData, SpanInfo, Transform/List and ResetTable files) with the details of the Wise / Wing "Unofficial CHM
Specification" (inbox/chm/chmspec). The compressed section reuses the CAB LZX encoder of
Scripts/fixtures/make-cab-lzx.py (written from [MS-PATCH]): every reset interval starts a fresh encoder (full
LZX state reset, E8 header bit written again), every 0x8000 bytes of output the bit stream is realigned to 16
bits (one CAB frame), the uncompressed section is padded to a 0x8000 boundary, and the ResetTable records the
compressed offset of every 0x8000 block. No CHM writer is installed here and 7-Zip cannot write CHM, so every
archive is extracted with `7zz x` and compared with the payload before it is stored. A version 2 header
(`build_chm(version=2)`, content directly after the directory, as Russotto describes) is refused by 7-Zip as
"Is not archive", so no version 2 fixture is stored. No third-party CHM implementation source was consulted.
"""
import base64, gzip, hashlib, importlib.util, json, pathlib, struct, subprocess, tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
spec = importlib.util.spec_from_file_location("cablzx", ROOT / "Scripts" / "fixtures" / "make-cab-lzx.py")
cablzx = importlib.util.module_from_spec(spec); spec.loader.exec_module(cablzx)

BLOCK = 0x8000
GUID1 = bytes.fromhex("10FD017CAA7BD0119E0C00A0C922E6EC")
GUID2 = bytes.fromhex("11FD017CAA7BD0119E0C00A0C922E6EC")
GUID_DIR = bytes.fromhex("6A92025D2E21D0119DF900A0C922E6EC")
TRANSFORM = "{7FC28940-9D31-11D0-9B27-00A0C91E9C7C}"

# ------------------------------------------------------------------------------------------------ payload

def payload():
    page = lambda i: (f"<html><head><title>Page {i}</title></head><body>\n" + "".join(f"<p>Paragraph {j} of page {i}: the quick brown fox jumps over the lazy dog.</p>\n" for j in range(30)) + "</body></html>\n").encode()
    files = {
        "/index.htm": page(0),
        "/topics/chapter1.htm": page(1),
        "/topics/chapter2.htm": page(2),
        "/topics/sub/deep.htm": page(3),
        "/日本語/目次.htm": ("<html><body>" + "日本語の本文。" * 200 + "</body></html>\n").encode(),
        "/images/logo.bin": bytes(((i * 31) ^ (i >> 7)) & 0xFF for i in range(70_000)),          # spans block boundaries
        "/style.css": b"body { font-family: sans-serif; }\n" * 40,
        "/empty.txt": b"",
        "/script.js": b"function f(x) { return x * 2; }\n" * 60,
    }
    return files

def system_files():
    # small format-related files that hh.exe writes into section 0 (contents are placeholders)
    return {"/#SYSTEM": struct.pack("<II", 3, 0) + b"\x00" * 60, "/#ITBITS": b""}

# ------------------------------------------------------------------------------------------------ writer

def encint(value):
    out = bytearray([value & 0x7F]); value >>= 7
    while value:
        out.insert(0, 0x80 | (value & 0x7F)); value >>= 7
    return bytes(out)

def chunk_entries(entries, chunk_size, density, tag, payload_of):
    """Pack entries into chunks (PMGL or PMGI); returns list of (chunk bytes, first name of chunk)."""
    n = 1 + (1 << density)
    chunks = []
    header = 0x14 if tag == b"PMGL" else 0x08
    pending = []
    def flush():
        body = b"".join(p for p, _ in pending)
        count = len(pending)
        quickref = struct.pack("<H", count)
        offsets = []
        pos = 0
        for i, (p, _) in enumerate(pending):
            if i and i % n == 0: offsets.append(pos)
            pos += len(p)
        for off in reversed(offsets): quickref = struct.pack("<H", off) + quickref
        free = chunk_size - header - len(body)
        assert free >= len(quickref)
        chunks.append((body, free, quickref, pending[0][1]))
        pending.clear()
    for name, value in entries:
        p = payload_of(name, value)
        used = sum(len(x) for x, _ in pending) + len(p)
        qr = 2 + 2 * ((len(pending) + 1 - 1) // n)
        if pending and header + used + qr > chunk_size: flush()
        pending.append((p, name))
    if pending: flush()
    return chunks

def build_directory(entries, chunk_size=4096, density=2, lcid=0x0411):
    """entries: dict name -> (section, offset, length). Returns the ITSP header + chunks."""
    ordered = sorted(entries.items(), key=lambda kv: kv[0].lower())
    listing = chunk_entries(ordered, chunk_size, density, b"PMGL",
                            lambda name, v: encint(len(name.encode())) + name.encode() + encint(v[0]) + encint(v[1]) + encint(v[2]))
    chunks = []
    for i, (body, free, quickref, _) in enumerate(listing):
        prev = i - 1 if i else -1
        nxt = i + 1 if i + 1 < len(listing) else -1
        c = b"PMGL" + struct.pack("<IIii", free, 0, prev, nxt) + body
        c = c.ljust(chunk_size - len(quickref), b"\0") + quickref
        assert len(c) == chunk_size
        chunks.append(c)
    depth, root = 1, -1
    if len(listing) > 1:
        index_entries = [(first, i) for i, (_, _, _, first) in enumerate(listing)]
        index = chunk_entries(index_entries, chunk_size, density, b"PMGI",
                              lambda name, v: encint(len(name.encode())) + name.encode() + encint(v))
        assert len(index) == 1, "fixture keeps a single index level"
        body, free, quickref, _ = index[0]
        c = (b"PMGI" + struct.pack("<I", free) + body).ljust(chunk_size - len(quickref), b"\0") + quickref
        chunks.append(c)
        depth, root = 2, len(listing)
    header = b"ITSP" + struct.pack("<IIIIIIiiiiI", 1, 0x54, 0x0A, chunk_size, density, depth, root, 0, len(listing) - 1, -1, len(chunks), )
    header += struct.pack("<I", lcid) + GUID_DIR + struct.pack("<Iiii", 0x54, -1, -1, -1)
    assert len(header) == 0x54
    return header + b"".join(chunks)

def compress_section(data, window_blocks, reset_blocks, e8=0, block_plan=None):
    """LZX-compress `data` the CHM way. Returns (compressed bytes, reset offsets, padded length)."""
    padded = data.ljust(((len(data) + BLOCK - 1) // BLOCK) * BLOCK, b"\0")
    window_bits = (window_blocks * BLOCK).bit_length() - 1
    out = bytearray(); offsets = []
    for start in range(0, len(padded), reset_blocks * BLOCK):
        piece = padded[start:start + reset_blocks * BLOCK]
        blocks = block_plan(len(piece)) if block_plan else [{"type": 1, "size": len(piece)}]
        encoder = cablzx.Encoder(piece, window_bits, e8)
        frames = encoder.encode(blocks)
        for packed, size in frames:
            offsets.append(len(out)); out += packed
    return bytes(out), offsets, len(padded)

def build_chm(files, system=None, version=3, window_blocks=2, reset_blocks=2, compress=True, e8=0, block_plan=None, lcid=0x0411):
    system = system or {}
    directory = {"/": (0, 0, 0)}
    # directories implied by paths
    for name in list(files) + list(system):
        parts = name.split("/")
        for i in range(2, len(parts)):
            directory["/".join(parts[:i]) + "/"] = (0, 0, 0)
    section0 = bytearray()
    def put0(name, data):
        directory[name] = (0, len(section0), len(data)); section0.extend(data)
    names = ["Uncompressed", "MSCompressed"] if compress else ["Uncompressed"]
    namelist = struct.pack("<H", 0) + struct.pack("<H", len(names))
    for n in names: namelist += struct.pack("<H", len(n)) + n.encode("utf-16-le") + b"\0\0"
    namelist = struct.pack("<H", len(namelist) // 2) + namelist[2:]
    put0("::DataSpace/NameList", namelist)
    for name, data in system.items(): put0(name, data)
    if compress:
        section1 = bytearray()
        for name, data in files.items():
            directory[name] = (1, len(section1), len(data)); section1.extend(data)
        compressed, offsets, padded = compress_section(bytes(section1), window_blocks, reset_blocks, e8, block_plan)
        base = f"::DataSpace/Storage/MSCompressed/"
        put0(base + "Transform/List", TRANSFORM[:19].encode("utf-16-le"))     # half a GUID string in wide chars, as observed
        put0(base + "SpanInfo", struct.pack("<Q", len(section1)))
        put0(base + "ControlData", struct.pack("<I4sIIIII", 6, b"LZXC", 2, reset_blocks, window_blocks, 1, 0))
        directory[base + f"Transform/{TRANSFORM}/InstanceData/"] = (0, 0, 0)
        table = struct.pack("<IIIIQQQ", 2, len(offsets), 8, 0x28, len(section1), len(compressed), BLOCK) + b"".join(struct.pack("<Q", o) for o in offsets)
        put0(base + f"Transform/{TRANSFORM}/InstanceData/ResetTable", table)
        put0(base + "Content", compressed)
    else:
        for name, data in files.items(): put0(name, data)
    dir_bytes = build_directory(directory, lcid=lcid)
    header_len = 0x60 if version == 3 else 0x58
    sec0_off = header_len; sec0_len = 0x18
    dir_off = sec0_off + sec0_len
    content_off = dir_off + len(dir_bytes)
    total = content_off + len(section0)
    header = b"ITSF" + struct.pack("<IIIII", version, header_len, 1, 0xDEADBEEF, lcid) + GUID1 + GUID2
    header += struct.pack("<QQQQ", sec0_off, sec0_len, dir_off, len(dir_bytes))
    if version == 3: header += struct.pack("<Q", content_off)
    assert len(header) == header_len
    sec0 = struct.pack("<IIQII", 0x01FE, 0, total, 0, 0)
    return header + sec0 + dir_bytes + bytes(section0)

# ------------------------------------------------------------------------------------------------ verification

def verify_with_7zz(archive, files, system):
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp, "f.chm"); path.write_bytes(archive)
        out = pathlib.Path(tmp, "x")
        subprocess.run(["7zz", "x", "-bso0", "-bsp0", "-o" + str(out), str(path)], check=True)
        for name, data in {**files, **system}.items():
            candidate = out / name[1:]
            assert candidate.exists(), f"7zz did not extract {name}"
            assert candidate.read_bytes() == data, f"7zz content differs for {name}"

def store(name, data, manifest, note):
    encoded = base64.encodebytes(gzip.compress(data, mtime=0)).decode()
    (HERE / f"{name}.gz.b64").write_text(encoded)
    manifest[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "note": note}
    print(f"{name}: {len(data)} bytes -> {len(encoded)} b64 chars")

def main():
    files, system = payload(), system_files()
    many = {f"/many/file{i:03d}.txt": f"file {i}\n".encode() * (i % 7 + 1) for i in range(300)}
    mixed_plan = lambda n: [{"type": 3, "size": min(n, 5000)}] + ([{"type": 2, "size": n - 5000}] if n > 5000 else [])
    e8_payload = dict(files); e8_payload["/code.bin"] = b"".join(b"\xE8" + struct.pack("<i", (i * 977) % 60000 - 30000) + bytes([i & 0xFF]) * 3 for i in range(3000))
    manifest = {"payload": {k: {"size": len(v), "sha256": hashlib.sha256(v).hexdigest()} for k, v in {**files, **system, **many, **e8_payload}.items()}}
    for name, kwargs, contents, note in [
        ("basic.chm", dict(), files, "version 3, LZX window 64 KiB, reset interval 2 blocks (like hh.exe output), 9 user files incl. Japanese names, directories, an empty file and a 70 KB file spanning blocks"),
        ("reset1-w17.chm", dict(window_blocks=4, reset_blocks=1), files, "window 128 KiB, LZX state reset every block"),
        ("mixed-blocks.chm", dict(block_plan=mixed_plan), files, "each reset interval starts with an uncompressed block and continues with an aligned-offset block"),
        ("e8.chm", dict(e8=0x12345678), e8_payload, "E8 translation enabled (header bit 1, translation size 0x12345678) with a payload full of E8 opcodes"),
        ("multi-chunk.chm", dict(), many, "300 files: several PMGL listing chunks plus a PMGI index chunk"),
        ("uncompressed.chm", dict(compress=False), files, "no MSCompressed section; every file stored in section 0"),
    ]:
        archive = build_chm(contents, system, **kwargs)
        verify_with_7zz(archive, contents, system)
        store(name, archive, manifest, note)
        manifest[name]["files"] = sorted(list(contents) + list(system))
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

if __name__ == "__main__":
    main()
