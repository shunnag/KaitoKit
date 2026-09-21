#!/usr/bin/env python3
"""Raw-sector CD images (BIN/CUE, .img, .mdf layouts) wrapped around the project-owned ISO 9660 fixture
`../iso/rr-joliet.iso.gz.b64` (38 sectors, written by xorriso) and the pure UDF fixture `../udf/pure150.iso.gz.b64`.

Sector framing follows ECMA-130 §14 (inbox/bincue/ecma-130.pdf): 12-byte sync (00 FF×10 00), a 4-byte header
(minute / second / frame of the absolute address in BCD, counted from 00:02:00 for sector 0, then the Sector
Mode byte), the 2048 user-data bytes and the 288-byte EDC / intermediate / ECC trailer. KaitoKit never reads the
trailer, so the generator writes it as zeros (or, in the `garbage` variant, as seeded pseudo-random bytes to
prove the reader's independence from it); the EDC / ECC values are therefore NOT valid and these images are
fixtures for the user-data mapping only. The Mode 2 variant inserts an opaque 8-byte sub-header before the user
data, the 2448 variant appends 96 bytes of sub-channel data after each sector, and the 2336 variant drops the
sync and header. No tool installed here reads raw-sector images (7-Zip, bsdtar and hdiutil were tried), so the
oracle is the unwrapped ISO itself: `unwrap()` strips the framing back and asserts byte equality with the source
image before anything is written.
"""
import base64, gzip, hashlib, json, pathlib, random

HERE = pathlib.Path(__file__).resolve().parent
SYNC = b"\x00" + b"\xff" * 10 + b"\x00"

def load(relative):
    return gzip.decompress(base64.b64decode((HERE / relative).read_text()))

def bcd(value):
    return ((value // 10) << 4) | (value % 10)

def header(sector, mode):
    lba = sector + 150                                  # sector 0 sits at absolute time 00:02:00
    return bytes([bcd(lba // (60 * 75)), bcd((lba // 75) % 60), bcd(lba % 75), mode])

def wrap(iso, *, sector_size=2352, mode=1, subheader=False, garbage=False):
    assert len(iso) % 2048 == 0
    rnd = random.Random(2352)
    out = bytearray()
    for index in range(len(iso) // 2048):
        user = iso[index * 2048:(index + 1) * 2048]
        sub = bytes([0, 0, 0x08, 0, 0, 0, 0x08, 0]) if subheader else b""
        trailer_size = 2352 - 16 - len(sub) - 2048
        trailer = bytes(rnd.getrandbits(8) for _ in range(trailer_size)) if garbage else bytes(trailer_size)
        if sector_size == 2336:
            sector = sub + user + trailer                # no sync / header
        else:
            sector = SYNC + header(index, mode) + sub + user + trailer
            if sector_size == 2448:
                sector += bytes(rnd.getrandbits(8) for _ in range(96)) if garbage else bytes(96)
        assert len(sector) == sector_size
        out += sector
    return bytes(out)

def unwrap(raw, sector_size, user_offset):
    return b"".join(raw[i * sector_size + user_offset:i * sector_size + user_offset + 2048] for i in range(len(raw) // sector_size))

def store(name, data, manifest, note):
    encoded = base64.encodebytes(gzip.compress(data, mtime=0)).decode()
    (HERE / f"{name}.gz.b64").write_text(encoded)
    manifest[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "note": note}
    print(f"{name}: {len(data)} bytes -> {len(encoded)} b64 chars")

def main():
    iso = load("../iso/rr-joliet.iso.gz.b64")
    udf = load("../udf/pure150.iso.gz.b64")
    manifest = {"source": {"rr-joliet.iso": hashlib.sha256(iso).hexdigest(), "pure150.iso": hashlib.sha256(udf).hexdigest()}}
    variants = [
        ("mode1.bin", dict(), 2352, 16, "Mode 1, 2352-byte sectors, zero EDC/ECC"),
        ("mode1-garbage.bin", dict(garbage=True), 2352, 16, "Mode 1 with pseudo-random trailer bytes"),
        ("mode2-subheader.bin", dict(mode=2, subheader=True), 2352, 24, "Mode 2 with an 8-byte sub-header (CD-ROM XA style)"),
        ("mode2-plain.bin", dict(mode=2, subheader=False), 2352, 16, "Mode 2 without a sub-header (user data at 16)"),
        ("mode1-2448.bin", dict(sector_size=2448, garbage=True), 2448, 16, "Mode 1 followed by 96 bytes of sub-channel data per sector"),
        ("mode2-2336.bin", dict(sector_size=2336, subheader=True), 2336, 8, "2336-byte sectors: sub-header + user data + trailer, no sync/header"),
    ]
    for name, kwargs, sector_size, user_offset, note in variants:
        raw = wrap(iso, **kwargs)
        assert unwrap(raw, sector_size, user_offset) == iso, name
        store(name, raw, manifest, note)
    raw = wrap(udf)
    assert unwrap(raw, 2352, 16) == udf
    store("udf-mode1.bin", raw, manifest, "pure UDF 1.50 image in Mode 1 sectors")
    # A truncated image: the last sector is cut in the middle of its trailer.
    truncated = wrap(iso)[:-100]
    store("mode1-truncated.bin", truncated, manifest, "mode1.bin missing the last 100 bytes (incomplete final sector)")
    (HERE / "mode1.cue").write_text('FILE "mode1.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
    (HERE / "multi.cue").write_text('REM COMMENT "two files, audio first"\r\nFILE "audio.wav" WAVE\r\n  TRACK 01 AUDIO\r\n    INDEX 01 00:00:00\r\n'
                                    'FILE C:\\IMAGES\\mode2-subheader.bin BINARY\r\n  TRACK 02 MODE2/2352\r\n    INDEX 01 00:00:00\r\n')
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

if __name__ == "__main__":
    main()
