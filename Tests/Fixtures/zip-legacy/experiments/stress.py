#!/usr/bin/env python3
"""Large-payload sweep (2026-09-21, not stored as fixtures): 400 KB word salad, 64 KB random bytes and 158 KB of
runs through Shrink, Reduce 1 / 4 and Implode 8K-3 / 4K-2, each checked against the black-box readers and
`.build/debug/kaito extract`. Run from the repository root after `swift build`."""
import sys, random, pathlib, tempfile, subprocess, hashlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import generate as g
S = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(tempfile.mkdtemp())
rnd = random.Random(23)
alphabet = b"abcdefghijklmnopqrstuvwxyz"
words = [bytes(rnd.choice(alphabet) for _ in range(rnd.randint(1, 9))) for _ in range(3000)]
cases = {
    "words400k.txt": b" ".join(rnd.choice(words) for _ in range(90000))[:400000],
    # 2 MB: ~150 Shrink partial clears with dozens of entries registered on a freed prefix; this is the case
    # that exposed the encoder emitting such entries (all three readers then fail too).
    "words2m.txt": b" ".join(rnd.choice(words) for _ in range(500000))[:2_000_000],
    "random64k.bin": bytes(rnd.getrandbits(8) for _ in range(65536)),
    "runs.bin": b"".join(bytes([rnd.getrandbits(8)]) * rnd.randint(1, 400) for _ in range(800)),
}
for name, data in cases.items():
    for label, method, flags, enc in [
        ("shrink", 1, 0, lambda d: g.shrink(d)),
        ("reduce4", 5, 0, lambda d: g.reduce(d, 4)),
        ("reduce1", 2, 0, lambda d: g.reduce(d, 1)),
        ("implode8k3", 6, 6, lambda d: g.implode(d, True, True)),
        ("implode4k2", 6, 0, lambda d: g.implode(d, False, False)),
    ]:
        comp = enc(data)
        archive = g.zip_archive([(name, method, flags, comp, data)])
        path = S / f"stress-{label}-{name}.zip"; path.write_bytes(archive)
        readers = ["deark"] if label.startswith("reduce") else ["unzip", "7zz", "deark"]
        results = {}
        for reader in readers:
            try: g.verify(path, {name: data}, [reader]); results[reader] = "ok"
            except Exception as e: results[reader] = "FAIL"
        with tempfile.TemporaryDirectory() as tmp:
            r = subprocess.run([".build/debug/kaito", "extract", str(path), "-o", tmp], capture_output=True, text=True)
            got = pathlib.Path(tmp, name)
            results["kaito"] = "ok" if r.returncode == 0 and got.exists() and got.read_bytes() == data else f"FAIL {r.stderr.strip()[:80]}"
        print(f"{label:11s} {name:15s} {len(data):7d} -> {len(comp):7d} {results}")
