#!/usr/bin/env python3
"""Ch.1 の 22 バイト header + 112 バイト entry(method 0 = stored)で classic StuffIt を書く。
日本語(MacJapanese / Shift_JIS)ファイル名の検出確認用 fixture。"""
import struct, sys, pathlib
def crc16arc(data, crc=0):
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc
assert crc16arc(b"123456789") == 0xBB3D
def entry(name_bytes, data=b"", rsrc=b"", rmethod=0, dmethod=0, ftype=b"JPEG", creator=b"GKON"):
    h = bytearray(110)
    h[0] = rmethod; h[1] = dmethod; h[2] = len(name_bytes); h[3:3+len(name_bytes)] = name_bytes
    h[66:70] = ftype; h[70:74] = creator
    struct.pack_into(">II", h, 76, 0xB0000000, 0xB0000001)
    struct.pack_into(">IIII", h, 84, len(rsrc), len(data), len(rsrc), len(data))
    struct.pack_into(">HH", h, 100, crc16arc(rsrc), crc16arc(data))
    return bytes(h) + struct.pack(">H", crc16arc(bytes(h))) + rsrc + data
def folder_begin(name_bytes): return entry(name_bytes, rmethod=0x20, dmethod=0x20, ftype=b"fold", creator=b"MACS")
def folder_end(): return entry(b"", rmethod=0x21, dmethod=0x21, ftype=b"fold", creator=b"MACS")
def build(entries):
    body = b"".join(entries)
    hdr = b"SIT!" + struct.pack(">H", len(entries)) + struct.pack(">I", 22 + len(body)) + b"rLau" + bytes([1]) + bytes(7)
    return hdr + body
enc = sys.argv[2] if len(sys.argv) > 2 else "shift_jis"
def n(s): return s.encode(enc)
JPG = bytes.fromhex("ffd8ffe000104a46494600010100000100010000ffd9")
PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 8
entries = [
    entry(n("写真.jpg"), JPG),
    folder_begin(n("第１巻")),
    entry(n("ページ０１.jpg"), JPG + b"\x01"),
    entry(n("ページ０２.jpg"), JPG + b"\x02"),
    folder_end(),
    entry(n("〜テスト〜.txt"), "波ダッシュ\n".encode(enc), ftype=b"TEXT", creator=b"ttxt"),
    entry(n("Vol.1 表紙.png"), PNG, ftype=b"PNGf", creator=b"prvw"),
    entry(n("アイコン付き.jpg"), JPG + b"\x03", rsrc=b"\0" * 256 + b"ICN#" + b"\0" * 30),
]
if enc == "mac_japanese" or len(sys.argv) > 3:
    # MacJapanese 固有の 0xFF(…)、0xFD(©)、0x80(\)。CP932 では未定義
    entries.append(entry(b"\x83\x81\x83\x82" + b"\xff" + b".txt", b"ellipsis\n", ftype=b"TEXT", creator=b"ttxt"))  # メモ….txt
    entries.append(entry(b"\xfd" + b"\x83\x81\x83\x82" + b".txt", b"copyright\n", ftype=b"TEXT", creator=b"ttxt"))  # ©メモ.txt
pathlib.Path(sys.argv[1]).write_bytes(build(entries))
print("wrote", sys.argv[1], len(build(entries)), "bytes,", len(entries), "entries, enc", enc)
