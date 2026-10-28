#!/usr/bin/env python3
"""RAR 6.x の黒箱出力から RAR4 filter / solid PPMd 標本を作り、3 reader で照合する。

再生成: python3 Scripts/fixtures/make-rar4.py --kaito .build/release/kaito
corpus 照合: python3 Scripts/fixtures/make-rar4.py --verify-manifest /tmp/corpus/manifest.json
参照は KaitoKit のみ。rar / unrar / bsdtar は CLI の入出力だけを使う。
"""

import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SEEDS = {"image": 2026102801, "audio": 2026102802, "x86": 2026102803}
RAR4_FLAGS = ["-ma4", "-m3", "-cfg-", "-idq", "-mt1", "-tsc-", "-tsa-"]
FILTERS = {"rgb": "-mcC+", "delta": "-mc4D+", "e8": "-mcE+", "audio": "-mc4A+"}


def rar4_tool():
    candidates = [os.environ.get("RAR4_TOOL"), shutil.which("rar6"),
                  str(Path.home() / ".local/opt/rar-6.24/rar")]
    for candidate in candidates:
        if not candidate:
            continue
        executable = shutil.which(candidate)
        if not executable:
            continue
        try:
            version = subprocess.run([executable, "-iver"], check=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()
        except (OSError, subprocess.CalledProcessError, UnicodeError) as error:
            print(f"warning: cannot query {candidate}: {error}", file=sys.stderr)
            continue
        if version.startswith("6."):
            return str(Path(executable).absolute()), version
        print(f"warning: {candidate} is RAR {version}, not 6.x; skipping candidate", file=sys.stderr)
    return None, None


def image_bmp(width, height, page=0):
    """24-bit BGR の色付き page。勾配・紙の粒・模擬文字・図版を含む。"""
    rng = random.Random(SEEDS["image"] + page)
    stride = (width * 3 + 3) & ~3
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            grain = rng.randrange(-7, 8)
            ink = 65 if y % 43 in range(17, 22) and x % 37 < 27 else 0
            panel = 35 if (x // 97 + y // 83 + page) % 5 == 0 else 0
            red = 35 + 170 * x // width + 25 * y // height - ink + grain
            green = 45 + 155 * y // height + panel - ink + grain
            blue = 75 + 100 * (x + y) // (width + height) - panel - ink + grain
            pixels.extend(max(0, min(255, value)) for value in (blue, green, red))
        pixels.extend(bytes(stride - width * 3))
    header = b"BM" + struct.pack("<IHHI", 54 + len(pixels), 0, 0, 54)
    header += struct.pack("<IiiHHIIiiII", 40, width, height, 1, 24, 0,
                          len(pixels), 2835, 2835, 0, 0)
    return header + pixels


def pcm_wave(frames):
    """44.1 kHz、16-bit stereo PCM。複数の倍音・包絡・独立した小振幅 noise。"""
    rng = random.Random(SEEDS["audio"])
    pcm = bytearray()
    for frame in range(frames):
        phase = frame / 44100
        envelope = 0.6 + 0.35 * math.sin(2 * math.pi * 0.7 * phase)
        left = envelope * (14000 * math.sin(2 * math.pi * 220 * phase)
                           + 4000 * math.sin(2 * math.pi * 659 * phase))
        right = envelope * (13000 * math.sin(2 * math.pi * 277 * phase)
                            + 3500 * math.sin(2 * math.pi * 831 * phase))
        pcm.extend(struct.pack("<hh", int(left) + rng.randrange(-32, 33),
                               int(right) + rng.randrange(-32, 33)))
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, 2, 44100, 176400, 4, 16)
            + b"data" + struct.pack("<I", len(pcm)) + pcm)


def x86_code(size):
    """system binary を使わず、prologue / call / jump / 即値の x86_64 風 bytes を作る。"""
    rng = random.Random(SEEDS["x86"])
    code = bytearray()
    while len(code) < size:
        offset = len(code)
        target = rng.randrange(256) * 32
        code.extend(b"\x55\x48\x89\xe5\xe8" + struct.pack("<i", target - offset - 9))
        code.extend(b"\xb8" + struct.pack("<I", rng.randrange(1024)))
        code.extend(b"\x48\x83\xc0\x01\xe9" + struct.pack("<i", target - offset - 23))
        code.extend(b"\x5d\xc3" + b"\x90" * 7)
    return bytes(code[:size])


def digest(data):
    return hashlib.sha256(data).hexdigest()


def entry_record(path, data):
    return {"path": path, "size": len(data), "sha256": digest(data)}


def verify_archive(archive, entries, kaito, unrar, bsdtar, solid=False):
    """entry 集合・長さ・SHA を原本と照合し、余分な entry も拒否する。"""
    expected = {item["path"]: (item["size"], item["sha256"]) for item in entries}
    results = {}
    with tempfile.TemporaryDirectory(prefix="kaito-rar4-oracles-") as temporary:
        for name, executable in (("unrar", unrar), ("bsdtar", bsdtar), ("kaito", kaito)):
            output = Path(temporary) / name
            output.mkdir()
            if name == "unrar":
                command = [executable, "x", "-idq", "-o+", str(archive), str(output) + "/"]
            elif name == "bsdtar":
                command = [executable, "-xf", str(archive), "-C", str(output)]
            else:
                command = [executable, "extract", str(archive), "-o", str(output)]
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            solid_diagnostic = b"bsdtar: RAR solid archive support unavailable"
            allowed_diagnostics = {solid_diagnostic, b"bsdtar: Error exit delayed from previous errors"}
            diagnostics = set(result.stderr.splitlines())
            if (name == "bsdtar" and solid and result.returncode == 1
                    and solid_diagnostic in diagnostics and diagnostics <= allowed_diagnostics):
                results[name] = "unsupported: RAR solid archive support unavailable"
                continue
            if result.returncode:
                raise ValueError(f"{archive.name}: {name} exit {result.returncode}: "
                                 + result.stderr.decode(errors="replace"))
            actual = {path.relative_to(output).as_posix(): (path.stat().st_size, digest(path.read_bytes()))
                      for path in output.rglob("*") if path.is_file()}
            if actual != expected:
                raise ValueError(f"{archive.name}: {name} differs from input: {actual}")
            results[name] = "matched"
    print(f"{archive.name}: {len(expected)} entries; {results}", flush=True)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "Tests/Fixtures/rar4")
    parser.add_argument("--kaito", type=Path, default=ROOT / ".build/release/kaito")
    parser.add_argument("--unrar", default="/opt/homebrew/bin/unrar")
    parser.add_argument("--bsdtar", default="/opt/homebrew/opt/libarchive/bin/bsdtar")
    parser.add_argument("--verify-manifest", type=Path)
    args = parser.parse_args()
    kaito = str(args.kaito.resolve())
    if args.verify_manifest:
        manifest = json.loads(args.verify_manifest.read_text())
        checked = 0
        for item in manifest["archives"]:
            if item.get("format") == "rar4":
                verify_archive(args.verify_manifest.resolve().parent / item["path"],
                               item["entries"], kaito, args.unrar, args.bsdtar,
                               solid=item.get("solid", False))
                checked += 1
        if not checked:
            parser.error("manifest contains no RAR4 archives")
        print(f"checked {checked} RAR4 archives")
        return

    tool, version = rar4_tool()
    if not tool:
        parser.error("RAR 6.x is required (RAR4_TOOL, rar6, or ~/.local/opt/rar-6.24/rar)")
    # -? の mc<par> と同梱 rar.txt の利用者向け switch 説明で A/C/D/E/T を確認した。
    subprocess.run([tool, "-?"], check=False, stdout=subprocess.PIPE)
    cases = [("rgb", {"page.bmp": image_bmp(128, 128)}),
             ("delta", {"stereo.wav": pcm_wave(8192)}),
             ("e8", {"code.bin": x86_code(48 * 1024)}),
             ("audio", {"stereo.wav": pcm_wave(8192)}),
             ("ppmd-solid", {f"text-{i}.txt": (f"KaitoKit solid member {i}\n".encode()
                            + b"archive reader window text model measurement\n" * 512)
                             for i in range(2)})]
    manifest = {"rar_version": version, "seeds": SEEDS,
                "x86_input": "synthetic x86_64-like bytes; no system binary", "archives": []}
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="kaito-rar4-fixtures-") as temporary:
        work = Path(temporary)
        for kind, members in cases:
            for name, data in members.items():
                path = work / name
                path.write_bytes(data)
                path.chmod(0o644)
                os.utime(path, (1700000000, 1700000000))
            switches = RAR4_FLAGS + ["-mc-"]
            switches += (["-s", "-ds", "-mc8:16T+"] if kind == "ppmd-solid"
                         else ["-s-", FILTERS[kind]])
            archive = work / f"r0-{kind}.rar"
            subprocess.run([tool, "a", *switches, str(archive), *members], cwd=work,
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env={**os.environ, "TZ": "UTC"})
            packed = archive.read_bytes()
            if len(packed) > 64 * 1024:
                raise ValueError(f"fixture exceeds 64 KiB: {archive.name}")
            entries = [entry_record(name, data) for name, data in members.items()]
            oracles = verify_archive(archive, entries, kaito, args.unrar, args.bsdtar,
                                     solid=kind == "ppmd-solid")
            (args.output / (archive.name + ".b64")).write_bytes(base64.encodebytes(packed))
            manifest["archives"].append({"path": archive.name, "kind": kind,
                "size": len(packed), "sha256": digest(packed), "switches": switches,
                "entries": entries, "oracles": oracles})
    (args.output / "r0-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
