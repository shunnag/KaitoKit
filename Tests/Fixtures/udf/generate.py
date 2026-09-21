#!/usr/bin/env python3
"""UDF fixture generator (run by hand on macOS; the images are checked in as gzip + base64).

Writers are macOS's own tools, used as black boxes:
  - hdiutil makehybrid -udf (UDF 1.02 / 1.50, 2048-byte blocks; -iso -joliet for the hybrid)
  - hdiutil create -fs UDF (newfs_udf 2.01, 512-byte blocks, extended file entries, named streams)
  - newfs_udf -r 2.50 / 2.60 -b 2048 on an attached raw image (metadata partition)
The payload is small and deterministic so every image compresses to well under 40 KB.
SHA-256 digests of the payload files are written to manifest.json; the images were read back
through the macOS UDF driver (hdiutil attach) before being checked in.

Three more images are derived from pure150.iso by patching its volume structures (UDF 2.60 §2.2.9,
§2.2.12, §2.2.8, §2.2.11 and UDF 1.50 §2.2.10), because newfs_udf cannot produce mountable
packet-written media on a plain image:
  - sparable150-relocated.iso: type 2 sparable partition map with a sparing table that relocates
    partition packet 0 (FSD, ICBs, directory data, readme.txt) to a spare packet; the original
    packet is wiped, so the files are readable only through the table.
  - vat150.iso: type 2 virtual partition map; the FSD and the root directory ICB are addressed
    through virtual blocks 0 and 1 of a UDF 1.50 style VAT (entries, then the
    "*UDF Virtual Alloc Tbl" trailer; VAT ICB file type 0) at the last sector.
  - vat2x.iso: the same with a UDF 2.x style VAT (152-byte header; VAT ICB file type 248).
All three mounted read-only with hdiutil and returned the payload digests before being checked in.

Two more derived images cover ICB extents with more than one entry (ECMA-167 4/8.10, 4/14.7, 4/14.8):
  - icb-two-entries.iso: readme.txt's ICB is two blocks, a direct entry followed by a Terminal Entry
    (strategy 4). macOS mounts it and reads readme.txt.
  - icb-chain-4096.iso: readme.txt's ICB is [stale direct entry (10 bytes), Indirect Entry] -> a second
    ICB [current direct entry, Terminal Entry], strategy 4096 (UDF 2.60 §6.6). macOS's UDF driver
    rejects strategy 4096 file entries (the file disappears from the mounted volume), so this image
    pins KaitoKit's spec-derived behaviour (the newest direct entry wins) without an independent oracle.
"""
import base64, gzip, hashlib, json, os, pathlib, struct, subprocess, tempfile

HERE = pathlib.Path(__file__).resolve().parent

def payload(root: pathlib.Path):
    (root / "sub" / "deeper").mkdir(parents=True)
    (root / "readme.txt").write_text("UDF fixture\n" * 240)          # 2,880 bytes, > 1 block of 2048
    (root / "sub" / "small.bin").write_bytes(bytes(range(256)) * 9)   # 2,304 bytes
    (root / "sub" / "deeper" / "empty").write_bytes(b"")
    (root / "sub" / "deeper" / "one.txt").write_bytes(b"1")
    (root / "日本語 名前.txt").write_text("nihongo\n")
    os.symlink("readme.txt", root / "link-to-readme")
    os.symlink("sub/deeper/one.txt", root / "sub" / "link-up")
    rsrc = root / "forked.txt"
    rsrc.write_text("data fork\n")
    (rsrc / "..namedfork" / "rsrc").write_bytes(b"RSRC-FORK-CONTENT-0123456789")
    subprocess.run(["xattr", "-w", "com.apple.metadata:kMDItemComment", "fixture note", str(rsrc)], check=True)
    os.chmod(root / "sub" / "small.bin", 0o755)
    subprocess.run(["chflags", "hidden", str(root / "sub" / "deeper" / "one.txt")], check=True)

def digests(root: pathlib.Path):
    result = {}
    for path in sorted(root.rglob("*")):
        rel = str(path.relative_to(root))
        if path.is_symlink():
            result[rel] = {"kind": "symlink", "target": os.readlink(path)}
        elif path.is_dir():
            result[rel] = {"kind": "directory"}
        else:
            result[rel] = {"kind": "file", "size": path.stat().st_size,
                           "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    return result

def store(name: str, image: pathlib.Path, manifest: dict, note: str):
    raw = image.read_bytes()
    encoded = base64.encodebytes(gzip.compress(raw, 9)).decode()
    (HERE / f"{name}.gz.b64").write_text(encoded)
    manifest[name] = {"rawSize": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
                      "encodedSize": len(encoded), "writer": note}
    print(f"{name}: raw {len(raw)} bytes, encoded {len(encoded)} bytes")

def newfs_image(out: pathlib.Path, megabytes: int, src: pathlib.Path, *newfs_args: str):
    with out.open("wb") as handle:
        handle.truncate(megabytes * 1024 * 1024)
    def attach(*extra):
        text = subprocess.run(["hdiutil", "attach", *extra, "-imagekey", "diskimage-class=CRawDiskImage", str(out)],
                              check=True, capture_output=True, text=True).stdout
        return text.strip().splitlines()[-1].split()
    device = attach("-nomount")[0]
    subprocess.run(["newfs_udf", *newfs_args, device], check=True, capture_output=True)
    subprocess.run(["hdiutil", "detach", "-quiet", device], check=True)
    mount = attach("-readwrite", "-nobrowse")[-1]
    try:
        subprocess.run(["cp", "-R", f"{src}/.", mount], check=True)
        # cp -R does not carry the hidden flag; set it on the mounted copy as well.
        subprocess.run(["chflags", "hidden", f"{mount}/sub/deeper/one.txt"], check=False)
    finally:
        subprocess.run(["hdiutil", "detach", "-quiet", mount], check=True)

def crc16(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc

def seal(image: bytearray, offset: int):
    """Recompute a descriptor tag's CRC (ECMA-167 3/7.2.6) and checksum (3/7.2.3)."""
    crc_length = image[offset + 10] | image[offset + 11] << 8
    struct.pack_into("<H", image, offset + 8, crc16(image[offset + 16:offset + 16 + crc_length]))
    image[offset + 4] = (sum(image[offset:offset + 4]) + sum(image[offset + 5:offset + 16])) & 0xFF

def regid(identifier: bytes, suffix: bytes = b"\x50\x01\x00\x00\x00\x00\x00\x00") -> bytes:
    return bytes([0]) + identifier.ljust(23, b"\0") + suffix

def volume_descriptors(image: bytearray, block_size: int):
    """Return (partition descriptor offsets, logical volume descriptor offsets) of both sequences."""
    anchor = 256 * block_size
    partitions, logicals = [], []
    for location in struct.unpack_from("<I", image, anchor + 20)[0], struct.unpack_from("<I", image, anchor + 28)[0]:
        for index in range(16):
            offset = (location + index) * block_size
            tag = struct.unpack_from("<H", image, offset)[0]
            if tag == 5: partitions.append(offset)
            if tag == 6: logicals.append(offset)
    return partitions, logicals

def sparable(source: bytes) -> bytes:
    block_size, packet, table_sector, spare_sector = 2048, 32, 310, 340
    image = bytearray(source)
    partitions, logicals = volume_descriptors(image, block_size)
    start = struct.unpack_from("<I", image, partitions[0] + 188)[0]
    # relocate partition packet 0 and wipe the original
    image[spare_sector * block_size:(spare_sector + packet) * block_size] = image[start * block_size:(start + packet) * block_size]
    image[start * block_size:(start + packet) * block_size] = bytes(packet * block_size)
    table = bytearray(16) + regid(b"*UDF Sparing Table") + struct.pack("<HHI", 1, 0, 1) + struct.pack("<II", 0, spare_sector)
    struct.pack_into("<HH", table, 0, 0, 2)
    struct.pack_into("<H", table, 10, len(table) - 16)
    struct.pack_into("<I", table, 12, table_sector)
    image[table_sector * block_size:table_sector * block_size + len(table)] = table
    seal(image, table_sector * block_size)
    for offset in logicals:
        struct.pack_into("<II", image, offset + 264, 64, 1)
        entry = bytearray(64)
        entry[0], entry[1] = 2, 64
        entry[4:36] = regid(b"*UDF Sparable Partition")
        struct.pack_into("<HHHBB", entry, 36, 1, 0, packet, 1, 0)
        struct.pack_into("<II", entry, 44, len(table), table_sector)
        image[offset + 440:offset + 504] = entry
        struct.pack_into("<H", image, offset + 10, 504 - 16)
        seal(image, offset)
    return bytes(image)

def virtual(source: bytes, style: str) -> bytes:
    block_size = 2048
    image = bytearray(source)
    last = len(image) // block_size - 1
    partitions, logicals = volume_descriptors(image, block_size)
    start = struct.unpack_from("<I", image, partitions[0] + 188)[0]
    for offset in partitions:              # the partition must cover the VAT ICB at the last sector
        struct.pack_into("<I", image, offset + 192, last - start + 1)
        seal(image, offset)
    fsd = start * block_size
    root = struct.unpack_from("<I", image, fsd + 404)[0]
    struct.pack_into("<IH", image, fsd + 404, 1, 1)      # root ICB via virtual block 1
    seal(image, fsd)
    struct.pack_into("<I", image, (start + root) * block_size + 12, 1)   # root FE tag location = virtual 1
    seal(image, (start + root) * block_size)
    for offset in logicals:
        struct.pack_into("<IIH", image, offset + 248, block_size, 0, 1)  # FSD via virtual block 0
        struct.pack_into("<II", image, offset + 264, 70, 2)
        entry = bytearray(64)
        entry[0], entry[1] = 2, 64
        entry[4:36] = regid(b"*UDF Virtual Partition")
        struct.pack_into("<HH", entry, 36, 1, 0)
        image[offset + 446:offset + 510] = entry
        struct.pack_into("<H", image, offset + 10, 510 - 16)
        seal(image, offset)
    table = list(range(28))
    table[1] = root
    entries = b"".join(struct.pack("<I", value) for value in table)
    if style == "150":
        vat, file_type = entries + regid(b"*UDF Virtual Alloc Tbl") + struct.pack("<I", 0xFFFFFFFF), 0
    else:
        volume_id = bytearray(128); volume_id[0] = 8; volume_id[1:9] = b"KAITOUDF"; volume_id[127] = 9
        header = struct.pack("<HH", 152, 0) + bytes(volume_id) + struct.pack("<IIIHHHH", 0xFFFFFFFF, 6, 3, 0x0150, 0x0150, 0x0150, 0)
        vat, file_type = header + entries, 248
    entry = bytearray(176 + len(vat))
    struct.pack_into("<HH", entry, 0, 261, 2)
    struct.pack_into("<I", entry, 12, last - start)
    struct.pack_into("<IHHHBB", entry, 16, 0, 4, 0, 1, 0, file_type)
    struct.pack_into("<H", entry, 34, 3)
    struct.pack_into("<III", entry, 36, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    struct.pack_into("<H", entry, 48, 1)
    struct.pack_into("<Q", entry, 56, len(vat))
    struct.pack_into("<I", entry, 108, 1)
    struct.pack_into("<II", entry, 168, 0, len(vat))
    entry[176:] = vat
    struct.pack_into("<H", entry, 10, len(entry) - 16)
    image[last * block_size:(last + 1) * block_size] = bytes(entry) + bytes(block_size - len(entry))
    seal(image, last * block_size)
    return bytes(image)

def find_root_fid(image: bytearray, block_size: int, start: int, name: bytes) -> int:
    """Offset of the FID for `name` in the root directory data (partition block 3 of the pure150 image)."""
    root = (start + 3) * block_size
    offset = 0
    while offset < 304:
        name_length = image[root + offset + 19]
        use_length = struct.unpack_from("<H", image, root + offset + 36)[0]
        if bytes(image[root + offset + 38 + use_length:root + offset + 38 + use_length + name_length]) == name:
            return root + offset
        offset += (38 + use_length + name_length + 3) // 4 * 4
    raise ValueError(name)

def icb_variants(source: bytes):
    block_size = 2048
    def prepare():
        image = bytearray(source)
        partitions, _ = volume_descriptors(image, block_size)
        start = struct.unpack_from("<I", image, partitions[0] + 188)[0]
        for offset in partitions:            # grow the partition so blocks 30..33 are inside it
            struct.pack_into("<I", image, offset + 192, 60)
            seal(image, offset)
        fid = find_root_fid(image, block_size, start, b"\x08readme.txt")
        old = struct.unpack_from("<I", image, fid + 24)[0]
        entry = bytes(image[(start + old) * block_size:(start + old + 1) * block_size])
        return image, start, fid, entry
    def place(image, start, block, blob):
        image[(start + block) * block_size:(start + block + 1) * block_size] = blob + bytes(block_size - len(blob))
        struct.pack_into("<I", image, (start + block) * block_size + 12, block)
        seal(image, (start + block) * block_size)
    def terminal(strategy, prior):
        blob = bytearray(36)
        struct.pack_into("<HH", blob, 0, 260, 2)
        struct.pack_into("<H", blob, 10, 20)
        struct.pack_into("<IHHHBB", blob, 16, prior, strategy, 1 if strategy == 4096 else 0, 2, 0, 11)
        return bytes(blob)
    # (a) strategy 4, ICB of two blocks: direct entry + terminal entry
    image, start, fid, entry = prepare()
    direct = bytearray(entry)
    struct.pack_into("<H", direct, 24, 2)
    place(image, start, 30, bytes(direct))
    place(image, start, 31, terminal(4, 1))
    struct.pack_into("<II", image, fid + 20, 2 * block_size, 30)
    seal(image, fid)
    two_entries = bytes(image)
    # (b) strategy 4096 chain: [stale DE, IE] -> [current DE, TE]
    image, start, fid, entry = prepare()
    stale = bytearray(entry)
    struct.pack_into("<HHH", stale, 20, 4096, 1, 2)
    struct.pack_into("<Q", stale, 56, 10)
    ea_length = struct.unpack_from("<I", entry, 168)[0]
    struct.pack_into("<I", stale, 176 + ea_length, 10)
    place(image, start, 30, bytes(stale))
    indirect = bytearray(52)
    struct.pack_into("<HH", indirect, 0, 259, 2)
    struct.pack_into("<H", indirect, 10, 36)
    struct.pack_into("<IHHHBB", indirect, 16, 1, 4096, 1, 2, 0, 3)
    struct.pack_into("<IIH", indirect, 36, 2 * block_size, 32, 0)
    place(image, start, 31, bytes(indirect))
    current = bytearray(entry)
    struct.pack_into("<IHHH", current, 16, 1, 4096, 1, 2)
    place(image, start, 32, bytes(current))
    place(image, start, 33, terminal(4096, 2))
    struct.pack_into("<II", image, fid + 20, 2 * block_size, 30)
    seal(image, fid)
    return two_entries, bytes(image)

def main():
    manifest = {}
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        src = tmp / "src"; src.mkdir()
        payload(src)
        manifest["payload"] = digests(src)
        subprocess.run(["hdiutil", "makehybrid", "-quiet", "-iso", "-joliet", "-udf", "-udf-version", "1.02",
                        "-udf-volume-name", "KAITOUDF", "-o", str(tmp / "hybrid102.iso"), str(src)], check=True)
        store("hybrid102.iso", tmp / "hybrid102.iso", manifest, "hdiutil makehybrid -iso -joliet -udf -udf-version 1.02")
        subprocess.run(["hdiutil", "makehybrid", "-quiet", "-udf", "-udf-version", "1.50",
                        "-udf-volume-name", "KAITOUDF", "-o", str(tmp / "pure150.iso"), str(src)], check=True)
        store("pure150.iso", tmp / "pure150.iso", manifest, "hdiutil makehybrid -udf -udf-version 1.50")
        pure150 = (tmp / "pure150.iso").read_bytes()
        for name, image, note in [
            ("sparable150-relocated.iso", sparable(pure150), "pure150.iso + sparable partition map with a relocated packet (synthetic)"),
            ("vat150.iso", virtual(pure150, "150"), "pure150.iso + virtual partition map with a UDF 1.50 style VAT (synthetic)"),
            ("vat2x.iso", virtual(pure150, "2x"), "pure150.iso + virtual partition map with a UDF 2.x style VAT (synthetic)"),
            ("icb-two-entries.iso", icb_variants(pure150)[0], "pure150.iso + two-block ICB (direct entry, terminal entry), strategy 4 (synthetic)"),
            ("icb-chain-4096.iso", icb_variants(pure150)[1], "pure150.iso + strategy 4096 chain (stale DE, IE -> current DE, TE); macOS rejects strategy 4096 (synthetic, no oracle)"),
        ]:
            (tmp / name).write_bytes(image)
            store(name, tmp / name, manifest, note)
        subprocess.run(["hdiutil", "create", "-quiet", "-fs", "UDF", "-volname", "KAITOUDF", "-layout", "NONE",
                        "-format", "UDTO", "-srcfolder", str(src), str(tmp / "udf201")], check=True)
        store("udf201-512.img", tmp / "udf201.cdr", manifest, "hdiutil create -fs UDF (newfs_udf 2.01, 512-byte blocks)")
        newfs_image(tmp / "udf260.img", 8, src, "-b", "2048", "-r", "2.60", "-v", "KAITOUDF")
        store("udf260-meta.img", tmp / "udf260.img", manifest, "newfs_udf -b 2048 -r 2.60 (metadata partition)")
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

if __name__ == "__main__":
    main()
