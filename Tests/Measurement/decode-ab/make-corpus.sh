#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <new-or-empty-dir> [--scale <factor>]"
    echo "DECODE_AB_SCALE defaults to 1 (256 MiB text + 256 MiB random + 50,000 small files)."
    echo "RAR4 adds three 12 MiB color pages, 24 MiB stereo PCM, and 12 MiB synthetic x86 code."
}

if [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]]; then usage; exit 0; fi
if [[ $# -ne 1 && $# -ne 3 ]]; then usage >&2; exit 1; fi
destination=$1
scale=${DECODE_AB_SCALE:-1}
if [[ $# -eq 3 ]]; then
    if [[ $2 != --scale ]]; then usage >&2; exit 1; fi
    scale=$3
fi

# ZIP の DOS timestamp は local time。入力と writer の時刻を UTC に揃える。
export TZ=UTC LC_ALL=C COPYFILE_DISABLE=1 ZERO_AR_DATE=1
umask 022
available_tools=()
for tool in ditto zip bsdtar xz zstd lzip lz4 7zz lha rar bzip2 gzip; do
    if command -v "$tool" >/dev/null 2>&1; then
        available_tools+=("$tool")
    else
        echo "warning: $tool is missing; skipping its archives" >&2
    fi
done

fixture_generator="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../Scripts/fixtures" && pwd)/make-rar4.py"
python3 - "$destination" "$scale" "$fixture_generator" "${available_tools[@]}" <<'PY'
import hashlib
import importlib.util
import json
import math
import platform
from pathlib import Path
import random
import shutil
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
scale = float(sys.argv[2])
if not math.isfinite(scale) or scale <= 0:
    sys.exit("scale must be a positive finite number")
if root.exists() and (not root.is_dir() or any(root.iterdir())):
    sys.exit("Refusing non-empty destination: {}".format(root))
spec = importlib.util.spec_from_file_location("rar4_fixtures", sys.argv[3])
rar4 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rar4)
tools = {name: shutil.which(name) for name in sys.argv[4:]}
rar4_path, rar4_version = rar4.rar4_tool()
if rar4_path:
    tools["rar4"] = rar4_path
else:
    print("warning: RAR 6.x is missing; skipping RAR4 archives "
          "(set RAR4_TOOL or install rar6)", file=sys.stderr)
source = root / "inputs"
archives = root / "archives"
logs = root / "logs"
work = root / ".work"
for directory in (source, archives, logs, work):
    directory.mkdir(parents=True)

size = max(1, int(256 * 1024 * 1024 * scale))
small_count = max(1, int(50_000 * scale))
chunk_size = 1024 * 1024
seeds = {"text": 20260924, "random": 20260925, "small": 20260926, **rar4.SEEDS}
password = "decode-ab-password"
# OS の辞書に依存しない固定語彙。GyoshukuKit と同じ MT19937 / 1 MiB block 方式。
words = [word + b" " for word in (
    b"archive reader entry stream buffer checksum decode file directory metadata "
    b"window block table symbol length distance offset byte count format header "
    b"compression measurement sample round baseline branch identity timestamp "
    b"deterministic input output random text small large quick brown fox jumps "
    b"over the lazy dog alpha beta gamma delta one two three four five six seven "
    b"eight nine zero repeat release performance memory process warm cache"
).split()]


def word_block(rng, length):
    data = bytearray()
    while len(data) < length:
        data.extend(rng.choice(words))
    return data[:length]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(chunk_size), b""):
            digest.update(block)
    return digest.hexdigest()


for name, seed in (("text.txt", seeds["text"]), ("random.bin", seeds["random"])):
    rng = random.Random(seed)
    with (source / name).open("xb") as stream:
        remaining = size
        while remaining:
            length = min(remaining, chunk_size)
            block = (word_block(rng, length) if name == "text.txt"
                     else rng.getrandbits(length * 8).to_bytes(length, "little"))
            stream.write(block)
            remaining -= length
(source / "small").mkdir()
rng = random.Random(seeds["small"])
for index in range(small_count):
    (source / "small" / "{:05d}.txt".format(index)).write_bytes(
        word_block(rng, rng.randint(1024, 4096)))

# 通常は 12 MiB の 24-bit BMP を 3 page、24 MiB の PCM、12 MiB の模擬 code。
# scale は画素数・sample 数・code 長に掛け、smoke でも有効な header を残す。
dimension = max(32, int(2048 * math.sqrt(scale)))
image_names = ["page-{:02d}.bmp".format(index + 1) for index in range(3)]
for index, name in enumerate(image_names):
    (source / name).write_bytes(rar4.image_bmp(dimension, dimension, index))
(source / "stereo.wav").write_bytes(rar4.pcm_wave(max(32, int(6 * 1024 * 1024 * scale))))
(source / "x86-code.bin").write_bytes(rar4.x86_code(max(32, int(12 * 1024 * 1024 * scale))))

inputs = sorted(source.rglob("*"))
for item in inputs:
    item.chmod(0o755 if item.is_dir() else 0o644)
# touch -t で固定 mtime / atime を設定する。directory は作成済みの子と共に設定する。
for offset in range(0, len(inputs), 200):
    subprocess.run(["touch", "-t", "202311142213.20"] +
                   [str(item) for item in inputs[offset:offset + 200]], check=True)
subprocess.run(["touch", "-t", "202311142213.20", str(source)], check=True)

manifest = {
    "version": 1, "scale": scale, "python": platform.python_version(),
    "generator": "MT19937; fixed vocabulary; random getrandbits little endian; 1 MiB blocks",
    "seeds": seeds, "mtime_utc": "2023-11-14T22:13:20Z", "tools": tools,
    "inputs": {"big_file_bytes": size, "small_files": small_count},
    "rar4": {"version": rar4_version, "image_dimensions": [dimension, dimension],
             "x86_input": "synthetic x86_64-like bytes; no system binary"},
    "archives": [], "skipped": [],
}
print("inputs: {} bytes each text/random, {} small files".format(size, small_count), flush=True)


def create(name, command, to_stdout=False, encrypted=False, publish=True, metadata=None):
    output = archives / name if publish else work / name
    partial = output.with_name(".tmp-" + output.name)
    # Writer が拡張子から形式を推測しないよう、出力の形式は command で指定する。
    argv = [str(partial) if arg == "{output}" else str(arg) for arg in command]
    with (logs / (name + ".log")).open("wb") as log:
        if to_stdout:
            with partial.open("xb") as stream:
                result = subprocess.run(argv, cwd=source, stdout=stream, stderr=log)
        else:
            result = subprocess.run(argv, cwd=source, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode != 0 or not partial.is_file():
        partial.unlink(missing_ok=True)
        manifest["skipped"].append({"path": name, "exit_code": result.returncode})
        print("warning: {} failed (exit {}); see logs/{}.log".format(
            name, result.returncode, name), file=sys.stderr)
        return None
    partial.replace(output)
    if publish:
        record = {"path": output.relative_to(root).as_posix(),
                  "size": output.stat().st_size, "sha256": sha256(output)}
        if encrypted:
            record["password"] = password
        if metadata:
            record.update(metadata)
        manifest["archives"].append(record)
        print("{}: {} bytes".format(name, record["size"]), flush=True)
    return output


def create_rar4(name, members, switches, solid=False):
    files = []
    for member in members:
        path = source / member
        files.extend(sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [path])
    entries = [{"path": path.relative_to(source).as_posix(), "size": path.stat().st_size,
                "sha256": sha256(path)} for path in files]
    flags = rar4.RAR4_FLAGS + ["-r"] + switches
    return create(name, [rar4_path, "a"] + flags + ["{output}"] + members,
                  metadata={"format": "rar4", "rar_version": rar4_version,
                            "switches": flags, "solid": solid, "entries": entries})


for corpus, item in (("text", "text.txt"), ("random", "random.bin"), ("small", "small")):
    if "ditto" in tools:
        create(corpus + "-ditto.zip", [tools["ditto"], "-c", "-k", "--keepParent",
               "--norsrc", "--noextattr", item, "{output}"])
    if "zip" in tools:
        create(corpus + "-zip6.zip", [tools["zip"], "-6", "-X", "-q", "-r", "{output}", item])
    if "bsdtar" in tools:
        for extension, flag in (("gz", "-czf"), ("bz2", "-cjf")):
            create(corpus + ".tar." + extension,
                   [tools["bsdtar"], "--format=ustar", flag, "{output}", item])
        tar = create(corpus + ".tar", [tools["bsdtar"], "--format=ustar", "-cf",
                     "{output}", item], publish=False)
        if tar:
            for extension, tool, flags in (
                ("multi.tar.xz", "xz", ["-6", "-T0", "--block-size=1MiB", "-c"]),
                ("single.tar.xz", "xz", ["-6", "-T1", "-c"]),
                ("tar.zst", "zstd", ["-3", "-T0", "-q", "-c"]),
                ("tar.lz", "lzip", ["-6", "-c"]),
                ("tar.lz4", "lz4", ["-q", "-c"]),
            ):
                if tool in tools:
                    create(corpus + "." + extension, [tools[tool]] + flags + [tar], to_stdout=True)
    if "7zz" in tools:
        for suffix, flags in (("solid", ["-ms=on"]), ("nonsolid", ["-ms=off"]),
                              ("aes", ["-ms=on", "-mhe=on", "-p" + password])):
            create(corpus + "-" + suffix + ".7z", [tools["7zz"], "a", "-t7z", "-mx6",
                   "-mtc=off", "-mta=off", "-bso0", "-bsp0"] + flags + ["{output}", item],
                   encrypted=suffix == "aes")
    if "lha" in tools:
        # lhasa の lha は reader 専用なので、存在しても a が失敗したら警告して skip。
        create(corpus + ".lzh", [tools["lha"], "a", "{output}", item])
    if "rar" in tools:
        for suffix, flags in (("rar5", []), ("rar5-blake2", ["-htb"])):
            create(corpus + "-" + suffix + ".rar", [tools["rar"], "a", "-ma5", "-m3",
                   "-r", "-cfg-", "-idq", "-tsc-", "-tsa-"] + flags + ["{output}", item])
    if rar4_path:
        create_rar4(corpus + "-rar4.rar", [item], ["-s-"])
        create_rar4(corpus + "-rar4-solid.rar", [item], ["-s"], solid=True)

if rar4_path:
    create_rar4("text-rar4-ppmd.rar", ["text.txt"], ["-s-", "-mc-", "-mc8:16T+"])
    filtered_inputs = [(name, kind) for name in image_names for kind in ("rgb", "delta")]
    filtered_inputs += [("stereo.wav", "audio"), ("stereo.wav", "delta"), ("x86-code.bin", "e8")]
    for name, kind in filtered_inputs:
        for enabled in (True, False):
            switch = rar4.FILTERS[kind] if enabled else rar4.FILTERS[kind][:-1] + "-"
            create_rar4("{}-rar4-{}-{}.rar".format(Path(name).stem, kind, "on" if enabled else "off"),
                        [name], ["-s-", "-mc-", switch])

for extension, tool, flags in (
    ("xz", "xz", ["-6", "-T0", "--block-size=1MiB", "-c"]),
    ("bz2", "bzip2", ["-6", "-c"]),
    ("zst", "zstd", ["-3", "-T0", "-q", "-c"]),
    ("gz", "gzip", ["-n", "-6", "-c"]),
):
    if tool in tools:
        create("text.txt." + extension, [tools[tool]] + flags + ["text.txt"], to_stdout=True)

shutil.rmtree(work)
(root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                    encoding="utf-8")
print("manifest: {} ({} archives)".format(root / "manifest.json", len(manifest["archives"])))
if not manifest["archives"]:
    sys.exit("No archives were created")
PY
