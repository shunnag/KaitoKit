#!/usr/bin/env python3
"""Read the P3 prototype corpus without changing it; print its 63 + 12 splice manifest.

Usage: python3 Tests/Measurement/tar-splice/make-tar-splice-manifest.py <scratchpad>/p3val > <tmp>/splice-manifest.json
The original results.jsonl, maps, chain.py algorithm and output bytes are the oracle.
"""
import bisect
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
sys.dont_write_bytecode = True
sys.path.insert(0, str(root / "tools"))
from p3lib import bz_map, gz_map, parse_tar, xz_map  # noqa: E402

extensions = {"gz": "tgz", "bz": "tbz", "xz": "txz"}
items = []


def item(corpus, edit, codec, base, output, chunks, first, reuse, produced=None):
    # s1/s2 は圧縮済みファイルの実際の区切り。header / Index / footer は manifest の外。
    old = base.read_bytes()
    new = output.read_bytes()
    start = {"gz": 10, "bz": 0, "xz": 12}[codec]
    end = len(old) - 8 if codec == "gz" else xz_map(old)[1]["index_start"] if codec == "xz" else len(old)
    new_end = len(new) - 8 if codec == "gz" else xz_map(new)[1]["index_start"] if codec == "xz" else len(new)
    c1 = chunks[first]["c0"]
    c2 = chunks[reuse]["c0"] if reuse is not None else end
    generated = new_end - c1 - (end - c2)
    if produced is not None:
        assert generated == produced
    segments = []
    if c1 > start:
        assert new[start:c1] == old[start:c1]
        segments.append(dict(kind="reused", output=[start, c1], base=[start, c1]))
    if generated:
        segments.append(dict(kind="encoded", output=[c1, c1 + generated]))
    if c2 < end:
        assert new[c1 + generated:new_end] == old[c2:end]
        segments.append(dict(kind="reused", output=[c1 + generated, new_end], base=[c2, end]))
    assert segments and segments[-1]["output"][1] == new_end
    return dict(corpus=corpus, codec=extensions[codec], edit=edit, base=str(base), output=str(output),
                hint="splice." + extensions[codec], segments=segments)


for row in map(json.loads, (root / "results.jsonl").read_text().splitlines()):
    corpus, edit, codec = (row[key] for key in ("corpus", "edit", "codec"))
    chunks = json.loads((root / "map" / (corpus + ".chunks.json")).read_text())[codec]
    items.append(item(corpus, edit, codec, root / "arc" / (corpus + "." + extensions[codec]),
                      root / "out" / (corpus + "-" + edit + "." + extensions[codec]), chunks,
                      row["first_chunk"], row["reuse_chunk"], row["produced_c"]))
assert len(items) == 63

for name in ["headers-rename-diff", "mixed-delete-mid"]:
    image = (root / "out" / (name + ".intended.tar")).read_bytes()
    members, eof = parse_tar(image)
    gzip_chunks, _ = gz_map(str(root / "out" / (name + ".tgz")), str(root / "out" / (name + ".gzmap.tsv")))
    gzip_chunks[-1]["u1"] = len(image)
    small = min(gzip_chunks[:-1], key=lambda c: c["u1"] - c["u0"])
    member = next(m for m in members if m["type"] == "0" and m["start"] >= small["u0"])
    edits = [("chain-delete", member["start"], member["end"]), ("chain-append", eof, len(image))]
    for codec in extensions:
        base = root / "out" / (name + "." + extensions[codec])
        if codec == "gz":
            chunks = gzip_chunks
        elif codec == "bz":
            chunks, decoded = bz_map(base.read_bytes())
            assert decoded == image
            del decoded
        else:
            chunks, _ = xz_map(base.read_bytes())
        for edit, a, b in edits:
            first = bisect.bisect_right([c["u0"] for c in chunks], a) - 1
            reuse = next((i for i, c in enumerate(chunks) if c["u0"] >= b + (32768 if codec == "gz" else 0) and c["u0"] > 0), None)
            if reuse is not None and reuse <= first:
                reuse = None
            items.append(item(name, edit, codec, base, root / "out" / (name + "-" + edit + "." + extensions[codec]), chunks, first, reuse))
assert len(items) == 75
json.dump(items, sys.stdout, indent=2)
print()
