#!/usr/bin/env python3
"""Add JPEG/color LZMA1/LZMA2 single-threaded cases to decode-ab's corpus."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
source = root / "inputs"
for bmp in sorted(source.glob("page-*.bmp")):
    subprocess.run(["sips", "-s", "format", "jpeg", str(bmp), "--out",
                    str(bmp.with_suffix(".jpg"))], check=True, stdout=subprocess.DEVNULL)
cases = []
for kind, extension in [("jpeg", "jpg"), ("color", "bmp")]:
    members = sorted(source.glob(f"page-*.{extension}"))
    assert len(members) == 3
    for codec in ["lzma", "lzma2"]:
        archive = root / "archives" / f"{kind}-7z-{codec}-mt1.7z"
        subprocess.run(["7zz", "a", "-t7z", f"-m0={codec}", "-mx6", "-mmt=1",
                        "-ms=on", "-mtc=off", "-mta=off", "-bso0", "-bsp0",
                        str(archive), *[p.name for p in members]], cwd=source, check=True)
        cases.append({"path": str(archive), "bytes": sum(p.stat().st_size for p in members)})
(root / "lzma-cases.json").write_text(json.dumps(cases, indent=2) + "\n")
