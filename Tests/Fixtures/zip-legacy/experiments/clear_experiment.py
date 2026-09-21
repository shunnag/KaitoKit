#!/usr/bin/env python3
"""Black-box experiment (2026-09-21): which Shrink partial-clear convention do unzip, 7-Zip and deark accept?

APPNOTE §5.1.3 says the decompressor clears every leaf on 256,2 and re-uses the freed codes lowest first, but
not what happens to the code emitted immediately before the clear. Three encoder variants are tried:
  A  free every leaf including that code, then register "previous + next byte" under the lowest freed code
     (its prefix therefore points at a freed code)                           -> accepted by all three readers
  A2 protect that code from the clear                                        -> rejected by all three
  B  register nothing for the step right after the clear                     -> rejected by all three
Run from the repository root; writes shrink-{A,A2,B}.zip into the given output directory (default: a temp dir).
"""
import sys, random, pathlib, tempfile, subprocess, hashlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import generate as g
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(tempfile.mkdtemp())

def shrink_variant(data, variant):
    """variant 'A': free every leaf incl. the just-emitted code, then add (C+next) with prefix C (current generator).
       'A2': protect the just-emitted code from clearing, then add (C+next).
       'B': clear, then skip adding the entry for this step (decoder must forget previous)."""
    w = g.BitWriter(); MAXBITS = 13
    table = {bytes([i]): i for i in range(256)}; parent = {}
    code_size = 9; next_code = 257; free = []
    stats = {"clears": 0, "protected": 0}
    def allocate(seq, prefix_code, byte):
        nonlocal next_code
        if free: code = free.pop(0)
        elif next_code < (1 << MAXBITS): code = next_code; next_code += 1
        else: return False
        table[seq] = code; parent[code] = (prefix_code, byte); return code
    def partial_clear(protect):
        used_as_prefix = {p for (p, _) in parent.values()}
        leaves = sorted(code for code in parent if code not in used_as_prefix and code != protect)
        if protect in parent and protect not in used_as_prefix: stats["protected"] += 1
        inv = {}
        for k, v in table.items(): inv.setdefault(v, []).append(k)
        for code in leaves:
            parent.pop(code)
            for k in inv.get(code, []): del table[k]
        free.extend(leaves); stats["clears"] += 1
    current = bytes([data[0]]); i = 1
    while i <= len(data):
        if i < len(data) and current + bytes([data[i]]) in table:
            current += bytes([data[i]]); i += 1; continue
        code = table[current]
        w.write(code, code_size)
        if i == len(data): break
        added = allocate(current + bytes([data[i]]), code, data[i])
        if added is False:
            w.write(256, code_size); w.write(2, code_size)
            if variant == "A": partial_clear(None); added = allocate(current + bytes([data[i]]), code, data[i])
            elif variant == "A2": partial_clear(code); added = allocate(current + bytes([data[i]]), code, data[i])
            else: partial_clear(None)  # B: no add this step
        if code_size < MAXBITS and (next_code > (1 << code_size) or (added is not False and added >= (1 << code_size))):
            w.write(256, code_size); w.write(1, code_size); code_size += 1
        current = bytes([data[i]]); i += 1
    return w.finish(), stats

rnd = random.Random(11)
alphabet = b"abcdefghijklmnop"
words = [bytes(rnd.choice(alphabet) for _ in range(rnd.randint(2, 7))) for _ in range(400)]
text = b" ".join(rnd.choice(words) for _ in range(14000))[:70000]
files = {"words.txt": text}
for variant in ("A", "A2", "B"):
    comp, stats = shrink_variant(text, variant)
    archive = g.zip_archive([("words.txt", 1, 0, comp, text)])
    results = {}
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp, f"shrink-{variant}.zip"); path.write_bytes(archive)
        (OUT / f"shrink-{variant}.zip").write_bytes(archive)
        for reader in ("unzip", "7zz", "deark"):
            try:
                g.verify(path, files, [reader]); results[reader] = "ok"
            except Exception as e:
                results[reader] = f"FAIL ({type(e).__name__})"
    print(variant, len(comp), stats, results)
