#!/bin/zsh
# Finder-style ZIP (ditto --sequesterRsrc) and macOS tar with AppleDouble sidecars. Run by hand on macOS.
# Payload: folder and folder/sub carry an xattr (bsdtar writes ._folder and folder/._sub; ditto --keepParent writes only __MACOSX/folder/._sub), folder/plain.txt (xattr only), folder/rsrc.txt (resource fork "RSRC-DATA-1234\n"),
# folder/sub/deep.txt (resource fork "DEEP-RSRC"). Both tools are used as black boxes.
set -e
cd "$(dirname "$0")"
work=$(mktemp -d)
mkdir -p "$work/folder/sub"
printf 'plain\n' > "$work/folder/plain.txt"
printf 'with rsrc\n' > "$work/folder/rsrc.txt"
printf 'RSRC-DATA-1234\n' > "$work/folder/rsrc.txt/..namedfork/rsrc"
xattr -w com.apple.metadata:kMDItemComment "fixture note" "$work/folder/plain.txt"
xattr -w com.apple.metadata:kMDItemComment "folder note" "$work/folder"
xattr -w com.apple.metadata:kMDItemComment "sub note" "$work/folder/sub"
printf 'deep\n' > "$work/folder/sub/deep.txt"
printf 'DEEP-RSRC' > "$work/folder/sub/deep.txt/..namedfork/rsrc"
(cd "$work" && ditto -c -k --sequesterRsrc --keepParent folder finder.zip && env -u COPYFILE_DISABLE tar -cf mac.tar folder)
base64 -i "$work/finder.zip" -o finder.zip.b64
base64 -i "$work/mac.tar" -o mac.tar.b64
shasum -a 256 "$work/finder.zip" "$work/mac.tar" | sed "s|$work/||" > SHA256SUMS
rm -rf "$work"
