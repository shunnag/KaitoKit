#!/usr/bin/env bash
# Apple disk image fixtures: an HFS+ volume written by macOS (hdiutil / the HFS+ driver / ditto) around a
# project-owned payload, converted by hdiutil into every UDIF compression, plus an ISO 9660 image wrapped in
# UDIF and an APFS image. hdiutil, the HFS+ driver and 7-Zip are used only as black-box writers / readers.
#
# Payload: text files in nested directories, an empty file, an executable, a symbolic link, a hard link pair,
# a resource fork (xattr com.apple.ResourceFork), a decomposed Japanese name, a 200 KB file that is forced
# into 40+ extents (so the extents overflow B-tree is used) and a decmpfs-compressed file (ditto
# --hfsCompression). Every image is mounted read-only with hdiutil and its tree compared with the payload;
# the compressed variants are also extracted with 7-Zip.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kaito-dmg-fixtures.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PAYLOAD="$WORK/payload"
mkdir -p "$PAYLOAD/sub/deeper"
printf 'hello dmg\n' > "$PAYLOAD/readme.txt"
python3 -c "open('$PAYLOAD/data.bin','wb').write(bytes(((i * 13) ^ (i >> 7)) & 0xFF for i in range(20_000)))"
printf 'nested\n' > "$PAYLOAD/sub/nested.txt"
printf 'deep\n' > "$PAYLOAD/sub/deeper/deep.txt"
: > "$PAYLOAD/empty.txt"
printf '#!/bin/sh\necho hi\n' > "$PAYLOAD/script.sh"; chmod 755 "$PAYLOAD/script.sh"
(cd "$PAYLOAD" && ln -s sub/nested.txt link-to-nested && ln readme.txt hardlink-to-readme)
printf '日本語の内容\n' > "$PAYLOAD/日本語.txt"
xattr -w com.apple.ResourceFork "RSRC-FORK-0123456789" "$PAYLOAD/readme.txt"
python3 -c "open('$PAYLOAD/fragmented.bin','wb').write(bytes(((i * 7) ^ (i >> 5)) & 0xFF for i in range(200_000)))"
python3 -c "open('$WORK/compressed.txt','w').write('compress me please ' * 3000)"

# A read-write HFS+ volume: copy the payload, then fragment fragmented.bin by filling the volume with 4 KiB
# files, deleting every other one and rewriting fragmented.bin into the holes.
hdiutil create -quiet -megabytes 8 -fs HFS+ -volname KaitoTest -type UDIF -layout GPTSPUD "$WORK/rw.dmg" 2>/dev/null
hdiutil attach -nobrowse -readwrite -plist "$WORK/rw.dmg" > "$WORK/attach.plist" 2>/dev/null
MNT="$(python3 -c "import plistlib,sys; p=plistlib.load(open(sys.argv[1],'rb')); print([e['mount-point'] for e in p['system-entities'] if 'mount-point' in e][0])" "$WORK/attach.plist")"
test -d "$MNT" && test "$MNT" != "/"
cp -R "$PAYLOAD/." "$MNT"/
# cp turns the hard link pair into two files; recreate the link on the volume itself.
rm "$MNT/hardlink-to-readme" && ln "$MNT/readme.txt" "$MNT/hardlink-to-readme"
ditto --hfsCompression "$WORK/compressed.txt" "$MNT/compressed.txt"
python3 - "$MNT" "$PAYLOAD/fragmented.bin" <<'PY'
import os, sys
mount, source = sys.argv[1], sys.argv[2]
os.remove(f"{mount}/fragmented.bin")
count = 0
try:
    while count < 5000:
        with open(f"{mount}/filler{count:05d}", "wb") as f: f.write(bytes([count & 0xFF]) * 4096)
        count += 1
except OSError:
    pass
os.sync()
for index in range(0, count, 2): os.remove(f"{mount}/filler{index:05d}")
os.sync()
with open(f"{mount}/fragmented.bin", "wb") as f: f.write(open(source, "rb").read())
os.sync()
for index in range(1, count, 2): os.remove(f"{mount}/filler{index:05d}")
os.sync()
PY
ls -lO "$MNT/compressed.txt" | grep -q compressed
hdiutil detach -quiet "$MNT"

# Truth: the payload plus compressed.txt (which KaitoKit lists but cannot read).
python3 - "$PAYLOAD" "$WORK/compressed.txt" "$WORK/manifest.json" <<'PY'
import hashlib, json, os, sys
payload, compressed, out = sys.argv[1:4]
files = {}
for root, dirs, names in os.walk(payload):
    for name in names:
        path = os.path.join(root, name); rel = os.path.relpath(path, payload)
        if os.path.islink(path): files[rel] = {"symlink": os.readlink(path)}
        else: files[rel] = {"size": os.path.getsize(path), "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()}
files["readme.txt/..namedfork/rsrc"] = {"size": 20, "sha256": hashlib.sha256(b"RSRC-FORK-0123456789").hexdigest()}
files["hardlink-to-readme/..namedfork/rsrc"] = files["readme.txt/..namedfork/rsrc"]
for name in ("readme.txt", "hardlink-to-readme"): files[name]["hardlink"] = True    # both names are HFS+ hard links
files["compressed.txt"] = {"size": os.path.getsize(compressed), "sha256": hashlib.sha256(open(compressed, "rb").read()).hexdigest(), "decmpfs": True}
json.dump({"payload": files, "images": {}}, open(out, "w"), indent=2, ensure_ascii=False)
PY

convert() {   # name format
    hdiutil convert -quiet -format "$2" -o "$WORK/$1" "$WORK/rw.dmg" 2>/dev/null
}
convert hfs-zlib.dmg UDZO
convert hfs-bzip2.dmg UDBZ
convert hfs-lzfse.dmg ULFO
convert hfs-lzma.dmg ULMO
convert hfs-adc.dmg UDCO
# A raw (UDRO) image of a small folder: uncompressed chunks, no fragmentation.
mkdir -p "$WORK/small/sub"; cp "$PAYLOAD/readme.txt" "$WORK/small/"; cp "$PAYLOAD/sub/nested.txt" "$WORK/small/sub/"
hdiutil create -quiet -srcfolder "$WORK/small" -volname KaitoRaw -fs HFS+ -format UDRO "$WORK/hfs-raw.dmg" 2>/dev/null
# The same small folder with an Apple Partition Map (SPUD) and with no partition map at all (bare volume).
hdiutil create -quiet -srcfolder "$WORK/small" -volname KaitoAPM -fs HFS+ -layout SPUD -format UDZO "$WORK/hfs-apm-zlib.dmg" 2>/dev/null
hdiutil create -quiet -srcfolder "$WORK/small" -volname KaitoBare -fs HFS+ -layout NONE -format UDZO "$WORK/hfs-bare-zlib.dmg" 2>/dev/null
# ISO 9660 inside UDIF (hdiutil makehybrid writes the ISO, convert wraps it).
hdiutil makehybrid -quiet -iso -joliet -o "$WORK/small.iso" "$WORK/small" 2>/dev/null
hdiutil convert -quiet -format UDZO -o "$WORK/iso-zlib.dmg" "$WORK/small.iso" 2>/dev/null
# APFS: listed as unsupported.
hdiutil create -quiet -megabytes 2 -fs APFS -volname KaitoAPFS -type UDIF -layout GPTSPUD "$WORK/apfs-rw.dmg" 2>/dev/null
hdiutil convert -quiet -format UDZO -o "$WORK/apfs-zlib.dmg" "$WORK/apfs-rw.dmg" 2>/dev/null

verify_mount() {   # image: mount read-only and compare with the payload
    hdiutil attach -nobrowse -readonly -plist "$WORK/$1" > "$WORK/attach.plist" 2>/dev/null
    local mnt; mnt="$(python3 -c "import plistlib,sys; p=plistlib.load(open(sys.argv[1],'rb')); print([e['mount-point'] for e in p['system-entities'] if 'mount-point' in e][0])" "$WORK/attach.plist")"
    python3 - "$mnt" "$WORK/manifest.json" <<'PY'
import hashlib, json, os, sys
mount, manifest = sys.argv[1], sys.argv[2]
files = json.load(open(manifest))["payload"]
for rel, want in files.items():
    if "/..namedfork/" in rel: continue
    path = os.path.join(mount, rel)
    if "symlink" in want: assert os.readlink(path) == want["symlink"], rel
    else: assert hashlib.sha256(open(path, "rb").read()).hexdigest() == want["sha256"], rel
PY
    hdiutil detach -quiet "$mnt"
}
verify_7zz() {   # image: 7-Zip extracts the HFS+ volume (it skips decmpfs data but lists the file)
    rm -rf "$WORK/7z"; mkdir "$WORK/7z"
    7zz x -bso0 -bsp0 -o"$WORK/7z" "$WORK/$1" >/dev/null 2>&1 || true
    python3 - "$WORK/7z" "$WORK/manifest.json" <<'PY'
import hashlib, json, os, sys
root, manifest = sys.argv[1], sys.argv[2]
volume = os.path.join(root, os.listdir(root)[0])
files = json.load(open(manifest))["payload"]
for rel, want in files.items():
    # 7-Zip writes resource forks as xattrs, cannot read decmpfs data and extracts HFS+ hard links as empty
    # files (it exposes the private iNode files instead), so those members are checked by the mount only.
    if "/..namedfork/" in rel or want.get("decmpfs") or want.get("hardlink") or "symlink" in want: continue
    path = os.path.join(volume, rel)
    assert os.path.exists(path), f"7zz did not extract {rel}"
    assert hashlib.sha256(open(path, "rb").read()).hexdigest() == want["sha256"], rel
PY
}
for image in hfs-zlib.dmg hfs-bzip2.dmg hfs-lzfse.dmg hfs-lzma.dmg hfs-adc.dmg; do
    verify_mount "$image"
    verify_7zz "$image"
done

python3 - "$WORK" "$HERE" <<'PY'
import base64, gzip, hashlib, json, os, sys
work, here = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(work, "manifest.json")))
notes = {
    "hfs-zlib.dmg": "UDZO: zlib chunks; the fragmented file uses the extents overflow B-tree; compressed.txt is decmpfs",
    "hfs-bzip2.dmg": "UDBZ: bzip2 chunks (the file starts with a BZh magic)",
    "hfs-lzfse.dmg": "ULFO: lzfse chunks",
    "hfs-lzma.dmg": "ULMO: lzma chunks (xz containers; the file starts with the xz magic)",
    "hfs-adc.dmg": "UDCO: ADC chunks, which KaitoKit does not decode (unsupportedMethod)",
    "hfs-raw.dmg": "UDRO from a small folder: raw and zero-fill chunks only",
    "hfs-apm-zlib.dmg": "the small folder behind an Apple Partition Map (hdiutil -layout SPUD)",
    "hfs-bare-zlib.dmg": "the small folder as a bare HFS+ volume without a partition map (hdiutil -layout NONE)",
    "iso-zlib.dmg": "an ISO 9660 / Joliet image (hdiutil makehybrid) wrapped in UDZO",
    "apfs-zlib.dmg": "an APFS volume in UDZO: unsupportedMethod",
}
for name, note in notes.items():
    data = open(os.path.join(work, name), "rb").read()
    encoded = base64.encodebytes(gzip.compress(data, mtime=0)).decode()
    open(os.path.join(here, name + ".gz.b64"), "w").write(encoded)
    manifest["images"][name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "note": note}
    print(f"{name}: {len(data)} bytes -> {len(encoded)} b64 chars")
json.dump(manifest, open(os.path.join(here, "manifest.json"), "w"), indent=2, ensure_ascii=False)
PY
echo "generated into $HERE"
