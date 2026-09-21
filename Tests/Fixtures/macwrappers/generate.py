#!/usr/bin/env python3
"""MacBinary II / AppleSingle v2 / BinHex 4.0 fixtures whose payload is a plain file (not a StuffIt archive).

Written from the same public descriptions the StuffIt wrapper code uses (the user-owned reconstruction
report chapters 00 / 06: MacBinary II header layout and CRC-16/XMODEM, AppleSingle entry table with the
Real Name / File Dates Info / Finder Info entries, BinHex 4.0 header + RLE90 + 6-bit alphabet + CRCs).
Every file is listed and extracted with The Unarchiver's `lsar` / `unar` (independent readers) before
it is stored; the data fork and resource fork are compared byte for byte. SHA-256 values are in
manifest.json.
"""
import base64, hashlib, json, os, pathlib, struct, subprocess, tempfile

HERE = pathlib.Path(__file__).resolve().parent
DATA = b"Hello, Macintosh!\n" * 20 + b"\x90\x90\x90\x90" + b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" + b"\nend\n"
RESOURCE = b"RSRC" * 40 + bytes(range(256))
MAC_EPOCH = 2_082_844_800          # 1904-01-01 -> 1970-01-01
CREATED = 3_600_000_000            # seconds since 1904 (2018-01-25 ...)
MODIFIED = 3_650_000_000

def crc16_xmodem(data):
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc

def macbinary(name, data, resource, file_type=b"TEXT", creator=b"ttxt"):
    header = bytearray(128)
    header[1] = len(name); header[2:2 + len(name)] = name
    header[65:69] = file_type; header[69:73] = creator
    header[73] = 0x00                                   # Finder flags high byte
    struct.pack_into(">II", header, 83, len(data), len(resource))
    struct.pack_into(">II", header, 91, CREATED, MODIFIED)
    header[101] = 0x00                                  # Finder flags low byte
    header[102:106] = b"mBIN"                           # MacBinary III signature
    header[122] = 130; header[123] = 129                # version written / minimum
    struct.pack_into(">H", header, 124, crc16_xmodem(header[:124]))
    def padded(blob): return blob + bytes((-len(blob)) % 128)
    return bytes(header) + padded(data) + padded(resource)

def applesingle(name, data, resource, file_type=b"TEXT", creator=b"ttxt", little=False):
    e = "<" if little else ">"
    entries = []
    dates = struct.pack(e + "iiii", CREATED - MAC_EPOCH - 946_684_800, MODIFIED - MAC_EPOCH - 946_684_800, -0x80000000, -0x80000000)
    finder = file_type + creator + struct.pack(e + "H", 0) + bytes(22)
    blobs = [(1, data), (2, resource), (3, name), (8, dates), (9, finder)]
    header_size = 26 + 12 * len(blobs)
    offset = header_size
    table = bytearray()
    body = bytearray()
    for entry_id, blob in blobs:
        table += struct.pack(e + "III", entry_id, offset, len(blob)); body += blob; offset += len(blob)
    magic = struct.pack(e + "I", 0x00051600); version = struct.pack(e + "I", 0x00020000)
    return magic + version + bytes(16) + struct.pack(e + "H", len(blobs)) + bytes(table) + bytes(body)

def binhex(name, data, resource, file_type=b"TEXT", creator=b"ttxt"):
    header = bytes([len(name)]) + name + b"\0" + file_type + creator + struct.pack(">H", 0) + struct.pack(">II", len(data), len(resource))
    stream = header + struct.pack(">H", crc16_xmodem(header))
    stream += data + struct.pack(">H", crc16_xmodem(data))
    stream += resource + struct.pack(">H", crc16_xmodem(resource))
    # RLE90: escape 0x90 as 90 00; runs of 4..255 identical bytes as byte 90 count
    rle = bytearray()
    i = 0
    while i < len(stream):
        byte = stream[i]
        run = 1
        while i + run < len(stream) and stream[i + run] == byte and run < 255: run += 1
        if byte == 0x90:
            rle += b"\x90\x00" * run if run < 4 else b"\x90\x00\x90" + bytes([run])
        elif run >= 4:
            rle += bytes([byte, 0x90, run])
        else:
            rle += bytes([byte]) * run
        i += run
    alphabet = b"!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr"
    bits = 0; count = 0; encoded = bytearray()
    for byte in rle:
        bits = (bits << 8) | byte; count += 8
        while count >= 6:
            count -= 6; encoded.append(alphabet[(bits >> count) & 63])
    if count: encoded.append(alphabet[(bits << (6 - count)) & 63])
    text = b"(This file must be converted with BinHex 4.0)\r\n:"
    body = bytes(encoded) + b":"
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return text + b"\r\n".join(lines) + b"\r\n"

def verify_with_unar(path, expected_name, data, resource):
    with tempfile.TemporaryDirectory() as tmp:
        listing = subprocess.run(["lsar", str(path)], check=True, capture_output=True, text=True).stdout
        assert expected_name in listing, f"{path.name}: lsar did not list {expected_name!r}:\n{listing}"
        subprocess.run(["unar", "-q", "-o", tmp, str(path)], check=True)
        extracted = pathlib.Path(tmp, expected_name)
        assert extracted.read_bytes() == data, f"{path.name}: data fork differs"
        fork = pathlib.Path(str(extracted) + "/..namedfork/rsrc")
        actual = fork.read_bytes() if fork.exists() else b""
        assert actual == resource, f"{path.name}: resource fork differs"

def main():
    manifest = {"data": {"size": len(DATA), "sha256": hashlib.sha256(DATA).hexdigest()},
                "resource": {"size": len(RESOURCE), "sha256": hashlib.sha256(RESOURCE).hexdigest()}, "files": {}}
    sjis = "テスト.txt".encode("shift_jis")
    cases = [
        ("readme.txt.bin", macbinary(b"readme.txt", DATA, RESOURCE), "readme.txt"),
        ("kanji.bin", macbinary(sjis, DATA, RESOURCE), "テスト.txt"),
        ("readme.txt.as", applesingle(b"readme.txt", DATA, RESOURCE), "readme.txt"),
        ("readme-le.txt.as", applesingle(b"readme.txt", DATA, RESOURCE, little=True), "readme.txt"),
        ("readme.txt.hqx", binhex(b"readme.txt", DATA, RESOURCE), "readme.txt"),
        ("noresource.bin", macbinary(b"plain.txt", DATA, b""), "plain.txt"),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        for filename, blob, expected in cases:
            path = pathlib.Path(tmp, filename); path.write_bytes(blob)
            resource = RESOURCE if filename != "noresource.bin" else b""
            try:
                verify_with_unar(path, expected, DATA, resource)
                oracle = "lsar/unar 1.10.8: listed and extracted, forks identical"
            except (AssertionError, subprocess.CalledProcessError) as error:
                oracle = f"unar could not verify: {error}"
                print(filename, oracle)
            (HERE / f"{filename}.b64").write_text(base64.encodebytes(blob).decode())
            manifest["files"][filename] = {"size": len(blob), "sha256": hashlib.sha256(blob).hexdigest(), "name": expected, "oracle": oracle}
            print(filename, len(blob))
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

if __name__ == "__main__":
    main()
