#!/usr/bin/env python3
"""Generate additional deterministic codec variants from a completed decode-ab corpus."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import ab


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="completed make-corpus.sh directory")
    parser.add_argument("output", type=Path, help="new or empty output directory")
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError("Refusing non-empty output: {}".format(output))
    if not (source / "manifest.json").is_file():
        raise ValueError("Source corpus has no manifest")
    tools = {"7zz": shutil.which("7zz"),
             "lha": os.environ.get("LHA_TOOL") or shutil.which("lha-unix")}
    missing = [name for name, path in tools.items() if not path]
    if missing:
        raise ValueError("Missing writers: " + ", ".join(missing))
    inputs = source / "inputs"
    archives = output / "archives"
    archives.mkdir(parents=True, exist_ok=True)
    (output / "logs").mkdir()
    (output / "inputs").symlink_to(inputs, target_is_directory=True)
    manifest = {"version": 1, "source_manifest": str(source / "manifest.json"),
                "source_manifest_sha256": ab.sha256(source / "manifest.json"),
                "tools": tools, "archives": []}

    def create(name, command, members):
        archive = archives / name
        with (output / "logs" / (name + ".log")).open("wb") as log:
            result = subprocess.run(command + [str(archive)] + members, cwd=inputs,
                                    stdout=log, stderr=subprocess.STDOUT, check=False)
        if result.returncode != 0:
            raise ValueError("Writer failed for {}: exit {}".format(name, result.returncode))
        entries = [{"path": member, "size": (inputs / member).stat().st_size,
                    "sha256": ab.sha256(inputs / member)} for member in members]
        record = {"path": "archives/" + name, "size": archive.stat().st_size,
                  "sha256": ab.sha256(archive), "entries": entries}
        manifest["archives"].append(record)
        print("{}: {} bytes".format(name, record["size"]), flush=True)

    for container, method in (("7z", "-m0=PPMd"), ("zip", "-mm=PPMd")):
        create("text-ppmd." + container,
               [tools["7zz"], "a", "-t" + container, method, "-mmt=1", "-bso0", "-bsp0"], ["text.txt"])
        create("color-ppmd." + container,
               [tools["7zz"], "a", "-t" + container, method, "-mmt=1", "-bso0", "-bsp0"],
               ["page-01.bmp", "page-02.bmp", "page-03.bmp"])
    for name, container, method in (("deflate64", "7z", "-m0=Deflate64"),
                                    ("deflate64", "zip", "-mm=Deflate64"),
                                    ("lzma", "7z", "-m0=LZMA"),
                                    ("bzip2", "7z", "-m0=BZip2"),
                                    ("bzip2", "zip", "-mm=BZip2")):
        create("text-{}.".format(name) + container,
               [tools["7zz"], "a", "-t" + container, method, "-mmt=1", "-bso0", "-bsp0"], ["text.txt"])
    for method in (5, 6, 7):
        create("text-lh{}.lzh".format(method),
               [tools["lha"], "a", "-q2", "-o{}".format(method)], ["text.txt"])
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                          encoding="utf-8")
    print("manifest: {} ({} archives)".format(output / "manifest.json", len(manifest["archives"])))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("error: {}".format(error), file=sys.stderr)
        sys.exit(2)
