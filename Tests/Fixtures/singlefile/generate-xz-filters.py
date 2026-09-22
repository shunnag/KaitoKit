#!/usr/bin/env python3
"""自作 payload を xz の RISC-V / x86 filter で圧縮し、黒箱で復元を照合する。"""
import base64
import hashlib
import io
import json
import pathlib
import subprocess
import tarfile
import tempfile

HERE = pathlib.Path(__file__).resolve().parent


def main():
    payload = b"KaitoKit XZ filter fixture\n" * 64 + bytes(range(256))
    tar = io.BytesIO()
    with tarfile.open(fileobj=tar, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        entry = tarfile.TarInfo("payload.bin")
        entry.size = len(payload)
        entry.mode = 0o644
        archive.addfile(entry, io.BytesIO(payload))
    manifest = {"payload": {"size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}}
    with tempfile.TemporaryDirectory() as tmp:
        for name, data, filter_name in [
            ("riscv.xz", payload, "riscv"),
            ("riscv.tar.xz", tar.getvalue(), "riscv"),
            ("x86.xz", payload, "x86"),
        ]:
            path = pathlib.Path(tmp, name.removesuffix(".xz"))
            path.write_bytes(data)
            subprocess.run(["xz", "-k", "--threads=1", f"--{filter_name}", "--lzma2=preset=1", str(path)], check=True)
            compressed = pathlib.Path(str(path) + ".xz")
            decoded = subprocess.run(["xz", "-dc", str(compressed)], check=True, capture_output=True).stdout
            assert decoded == data, name
            encoded = compressed.read_bytes()
            (HERE / (name + ".b64")).write_bytes(base64.encodebytes(encoded))
            manifest[name] = {
                "size": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest(),
                "uncompressedSize": len(data), "uncompressedSHA256": hashlib.sha256(data).hexdigest(),
                "note": f"自作 payload、xz -k --{filter_name} --lzma2=preset=1、xz -dc で byte 一致",
            }
            print(f"xz -dc: {name}: {len(data)} bytes byte-identical; SHA-256 {hashlib.sha256(data).hexdigest()}")
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
