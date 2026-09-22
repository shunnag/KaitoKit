#!/usr/bin/env bash
# decmpfs fixture。hdiutil / ditto / HFS+ driver / Apple Compression は黒箱のみ。
# 原本は自作の決定的な text。既存 image と manifest.json は変更しない。
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS が必要' >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kaito-decmpfs.XXXXXX")"
MNT=''
cleanup() {
    if [[ -n "$MNT" ]]; then
        hdiutil detach "$MNT" || return
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'printf "失敗: %s (exit %s)\n" "$BASH_COMMAND" "$?" >&2' ERR
command -v 7zz >/dev/null
mkdir "$WORK/payload"
python3 - "$WORK" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]) / "payload"
pattern = b"KaitoKit decmpfs fixture: project-owned text 0123456789.\n"
for name, size in {
    "ditto7.txt": 20_000, "ditto8.txt": 300_000,
    "inline1.bin": 840, "inline3.bin": 840, "inline9.bin": 840, "inline11.bin": 840,
    "empty1.bin": 0, "empty-compressed": 0,
    "zlib4.bin": 300_000, "lzfse12.bin": 300_000, "raw10.bin": 300_000,
    "type5.bin": 840, "type13.bin": 840,
}.items():
    (root / name).write_bytes((pattern * ((size + len(pattern) - 1) // len(pattern)))[:size])
PY

hdiutil create -size 12m -fs HFS+ -volname KaitoDecmpfs -type UDIF -layout GPTSPUD "$WORK/rw.dmg"
hdiutil attach -nobrowse -readwrite -plist "$WORK/rw.dmg" > "$WORK/attach.plist"
MNT="$(python3 - "$WORK/attach.plist" <<'PY'
import plistlib, sys
entities = plistlib.load(open(sys.argv[1], "rb"))["system-entities"]
mounts = [e["mount-point"] for e in entities if "mount-point" in e]
if len(mounts) != 1:
    raise SystemExit("hdiutil attach: no unique mount point")
print(mounts[0])
PY
)"
[[ -d "$MNT" && "$MNT" != / ]]
ditto --hfsCompression "$WORK/payload/ditto7.txt" "$MNT/ditto7.txt"
ditto --hfsCompression "$WORK/payload/ditto8.txt" "$MNT/ditto8.txt"

python3 - "$WORK" "$MNT" <<'PY'
import ctypes, errno, hashlib, json, os, pathlib, struct, subprocess, sys, zlib
work, mount = map(pathlib.Path, sys.argv[1:])
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
lib.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
lib.getxattr.restype = ctypes.c_ssize_t
lib.setxattr.argtypes = lib.getxattr.argtypes
lib.setxattr.restype = ctypes.c_int
lib.chflags.argtypes = [ctypes.c_char_p, ctypes.c_uint32]
lib.chflags.restype = ctypes.c_int
compression = ctypes.CDLL("/usr/lib/libcompression.dylib")
compression.compression_encode_buffer.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_uint32]
compression.compression_encode_buffer.restype = ctypes.c_size_t

def check(result, operation):
    if result < 0:
        error = ctypes.get_errno()
        raise OSError(error, f"{operation}: {os.strerror(error)}")
    return result

def get_attr(path, name):
    count = check(lib.getxattr(os.fsencode(path), name, None, 0, 0, 0x20), f"getxattr({path}, {name!r}, XATTR_SHOWCOMPRESSION)")
    data = ctypes.create_string_buffer(count)
    actual = check(lib.getxattr(os.fsencode(path), name, data, count, 0, 0x20), f"getxattr({path}, {name!r}, XATTR_SHOWCOMPRESSION)")
    return data.raw[:actual]

def set_attr(path, name, value):
    data = ctypes.create_string_buffer(value)
    check(lib.setxattr(os.fsencode(path), name, data, len(value), 0, 0x20), f"setxattr({path}, {name!r}, XATTR_SHOWCOMPRESSION)")

def lzfse(raw):
    out = ctypes.create_string_buffer(len(raw) + 4096)
    src = ctypes.create_string_buffer(raw)
    count = compression.compression_encode_buffer(out, len(out), src, len(raw), None, 0x801)
    assert count > 0, "compression_encode_buffer(COMPRESSION_LZFSE)"
    return out.raw[:count]

def offset_fork(chunks):
    offset = 4 * (len(chunks) + 1)
    offsets = [offset]
    for chunk in chunks:
        offset += len(chunk)
        offsets.append(offset)
    return struct.pack("<" + "I" * len(offsets), *offsets) + b"".join(chunks)

def zlib_fork(chunks):
    offset = 4 + len(chunks) * 8
    descriptors = bytearray()
    for chunk in chunks:
        descriptors += struct.pack("<II", offset, len(chunk))
        offset += len(chunk)
    data = struct.pack("<I", len(chunks)) + descriptors + b"".join(chunks)
    data = struct.pack(">I", len(data)) + data
    # HFS+ driver が受理した cmpf resource map（黒箱観察）。
    footer = bytes(25) + bytes.fromhex("1c00320000") + b"cmpf" + bytes.fromhex("0000000a0001ffff") + bytes(8)
    assert len(footer) == 50
    header = struct.pack(">IIII", 0x100, 0x100 + len(data), len(data), len(footer))
    return header + bytes(0x100 - len(header)) + data + footer

types = {"ditto7.txt": 7, "ditto8.txt": 8, "inline1.bin": 1, "inline3.bin": 3,
         "inline9.bin": 9, "inline11.bin": 11, "empty1.bin": 1, "empty-compressed": 1,
         "zlib4.bin": 4, "lzfse12.bin": 12, "raw10.bin": 10, "type5.bin": 5, "type13.bin": 13}
files = {}
for name, kind in types.items():
    raw = (work / "payload" / name).read_bytes()
    path = mount / name
    if name not in ("ditto7.txt", "ditto8.txt"):
        payload, fork = b"", None
        chunks = [raw[i:i + 65536] for i in range(0, len(raw), 65536)]
        if kind == 1: payload = raw
        elif kind == 9: payload = b"\xcc" + raw
        elif kind == 3: payload = zlib.compress(raw)
        elif kind == 11: payload = lzfse(raw)
        elif kind == 4:
            # chunk 0 は Adler-32 付き、1 / 3 / 4 は無し、2 は raw。
            fork = zlib_fork([b"\xff" + chunk if i == 2 else zlib.compress(chunk) if i == 0 else zlib.compress(chunk)[:-4]
                              for i, chunk in enumerate(chunks)])
        elif kind == 12: fork = offset_fork([lzfse(chunk) for chunk in chunks])
        elif kind == 10: fork = offset_fork([b"\xcc" + chunk for chunk in chunks])
        elif kind == 5: payload = struct.pack("<III", 1, 0, 0)
        elif kind == 13: payload = bytes(range(16))
        path.write_bytes(b"")
        try:
            if fork is not None: set_attr(path, b"com.apple.ResourceFork", fork)
            set_attr(path, b"com.apple.decmpfs", b"fpmc" + struct.pack("<IQ", kind, len(raw)) + payload)
            check(lib.chflags(os.fsencode(path), 0x20), f"chflags({path}, UF_COMPRESSED)")
        except OSError as error:
            if name != "empty-compressed" or error.errno != errno.EINVAL: raise
            check(lib.chflags(os.fsencode(path), 0), f"chflags({path}, 0)")
            path.unlink()
            print("empty-compressed: driver が EINVAL で拒否、省略")
            continue
    attr = get_attr(path, b"com.apple.decmpfs")
    assert attr[:4] == b"fpmc" and len(attr) >= 16, name
    actual, size = struct.unpack_from("<IQ", attr, 4)
    assert actual == kind and size == len(raw), (name, actual, kind, size, len(raw))
    assert os.stat(path).st_flags & 0x20, (name, "UF_COMPRESSED が無い")
    if name == "ditto8.txt":
        first = struct.unpack_from("<I", get_attr(path, b"com.apple.ResourceFork"))[0]
        assert first // 4 - 1 == 5, (name, first)
    if kind not in (5, 13):
        subprocess.run(["cmp", str(work / "payload" / name), str(path)], check=True)
    files[name] = {"size": len(raw), "sha256": hashlib.sha256(raw).hexdigest(), "decmpfsType": kind}
    print(f"{name}: type {kind}, {len(raw)} bytes, " + ("一覧のみ" if kind in (5, 13) else "cmp OK"))
(work / "manifest-decmpfs.json").write_text(json.dumps({"payload": files, "images": {}}, indent=2) + "\n")
PY
ls -lO "$MNT"
hdiutil detach "$MNT"
MNT=''
convert() {
    hdiutil convert -format "$2" -o "$WORK/$1" "$WORK/rw.dmg"
}
convert hfs-decmpfs.dmg UDZO
7zz l "$WORK/hfs-decmpfs.dmg" > "$WORK/7zz-list.txt"
cat "$WORK/7zz-list.txt"
python3 - "$WORK" "$HERE" <<'PY'
import base64, gzip, hashlib, json, pathlib, subprocess, sys
work, here = map(pathlib.Path, sys.argv[1:])
manifest = json.loads((work / "manifest-decmpfs.json").read_text())
listing = (work / "7zz-list.txt").read_text()
for name in manifest["payload"]:
    assert name in listing, f"7zz l: {name} が無い"
# 7-Zip 26.03 の黒箱照合。対応する 5 type だけを展開し、未対応 type の空 file は真値にしない。
selected = [name for name, info in manifest["payload"].items() if info["decmpfsType"] in (3, 4, 7, 8, 9)]
extracted = work / "7zz"
extracted.mkdir()
subprocess.run(["7zz", "x", "-y", f"-o{extracted}", str(work / "hfs-decmpfs.dmg")]
               + [f"-ir!{name}" for name in selected], check=True)
for name, info in manifest["payload"].items():
    info["sevenZipVerified"] = False
    if name not in selected: continue
    matches = [path for path in extracted.rglob(name) if path.is_file()]
    assert len(matches) == 1, (name, "7zz 展開先が一意でない", matches)
    subprocess.run(["cmp", str(work / "payload" / name), str(matches[0])], check=True)
    info["sevenZipVerified"] = True
    print(f"{name}: 7zz x / cmp OK")
name = "hfs-decmpfs.dmg"
data = (work / name).read_bytes()
encoded = base64.encodebytes(gzip.compress(data, mtime=0))
assert len(encoded) < 200_000, len(encoded)
manifest["images"][name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                            "note": "UDZO / GPTSPUD / HFS+。decmpfs 1/3/4/7/8/9/10/11/12、一覧のみ 5/13"}
(here / (name + ".gz.b64")).write_bytes(encoded)
(here / "manifest-decmpfs.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
print(f"{name}: {len(data)} bytes -> {len(encoded)} b64 bytes")
PY
