#!/usr/bin/env python3
"""XPRESS の 4 / 64 KiB chunk を追加する。既存 fixture と manifest 行は保持する。"""
import json
import pathlib
import tempfile

from generate import HERE, add_chunk_size_fixtures


def main():
    manifest = json.loads((HERE / "manifest.json").read_text())
    with tempfile.TemporaryDirectory() as tmp:
        add_chunk_size_fixtures(manifest, pathlib.Path(tmp))
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
