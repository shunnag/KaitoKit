#!/usr/bin/env python3
"""Encode project-owned inputs with the public LZ4 CLI; never reads codec sources."""
import base64
import hashlib
import io
import json
import pathlib
import shutil
import subprocess
import tarfile
import tempfile

root = pathlib.Path(__file__).resolve().parent
executable = shutil.which("lz4")
if executable is None:
    raise SystemExit("The LZ4 command-line tool is required to regenerate these fixtures")

def patterned(count):
    pattern = bytes(((i * 73 + i // 31) * 41) & 255 for i in range(4093))
    return (pattern * ((count + len(pattern) - 1) // len(pattern)))[:count]

def incompressible(count):
    state = 0x12345678
    output = bytearray()
    for _ in range(count):
        state ^= (state << 13) & 0xffffffff
        state ^= state >> 17
        state ^= (state << 5) & 0xffffffff
        output.append(state & 255)
    return bytes(output)

def archive():
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as writer:
        for name, payload in [("folder/first.bin", patterned(131_083)), ("note.txt", b"LZ4 frame fixture\n"), ("empty", b"")]:
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mode = 0o644
            info.mtime = 0
            writer.addfile(info, io.BytesIO(payload))
    return output.getvalue()

cases = [
    ("empty", b"", ["-B4", "-BI", "-BX", "--content-size"]),
    ("tiny", patterned(1033), ["-B4", "-BI", "-BX", "--content-size"]),
    ("independent-64k", patterned(262403), ["-B4", "-BI", "-BX", "--content-size"]),
    ("linked-64k", patterned(262403), ["-B4", "-BD", "-BX", "--content-size"]),
    ("independent-256k", patterned(524399), ["-B5", "-BI", "--content-size"]),
    ("independent-1m", patterned(1048699), ["-B6", "-BI", "--content-size"]),
    ("independent-4m", patterned(4194389), ["-B7", "-BI", "--content-size"]),
    ("stored", incompressible(65587), ["-B4", "-BI", "-BX", "--content-size"]),
    ("no-checksum", patterned(262403), ["-B4", "-BD", "--no-frame-crc"]),
    ("tar-linked", archive(), ["-B4", "-BD", "-BX", "--content-size"]),
    ("legacy-empty", b"", ["-l"]),
    ("legacy-tiny", patterned(1033), ["-l"]),
    ("legacy-8m-exact", patterned(8388608), ["-l"]),
    ("legacy-8m-tail", patterned(8388661), ["-l"]),
    ("legacy-incompressible", incompressible(65587), ["-l"]),
    ("legacy-tar", archive(), ["-l"]),
]
manifest = {
    "tool": subprocess.run([executable, "--version"], capture_output=True, text=True, check=True).stdout.strip(),
    "specifications": ["https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md", "https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md", "https://github.com/Cyan4973/xxHash/blob/release/doc/xxhash_spec.md"],
    "fixtures": [], "xxh32_vectors": []
}
with tempfile.TemporaryDirectory(prefix="kaito-lz4-fixtures-") as temporary:
    work = pathlib.Path(temporary)
    for name, payload, options in cases:
        source, destination = work / "input", work / "output.lz4"
        source.write_bytes(payload)
        arguments = ["-T1", "-q", "-f", *options]
        subprocess.run([executable, *arguments, str(source), str(destination)], check=True)
        encoded = destination.read_bytes()
        decoded = subprocess.run([executable, "-d", "-c", "-q", str(destination)], check=True, capture_output=True).stdout
        if decoded != payload:
            raise RuntimeError("The independent CLI round trip did not match: " + name)
        (root / (name + ".lz4.b64")).write_bytes(base64.encodebytes(encoded))
        manifest["fixtures"].append({"name": name, "arguments": arguments, "size": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest(), "decoded_size": len(payload), "decoded_sha256": hashlib.sha256(payload).hexdigest()})
    for length in [0, 1, 3, 15, 16, 17, 31, 32, 33, 255, 65536, 65539]:
        payload = bytes((i * 73 + 19) & 255 for i in range(length))
        encoded = subprocess.run([executable, "-z", "-c", "-q"], input=payload, check=True, capture_output=True).stdout
        if not encoded[4] & 4:
            raise RuntimeError("The CLI omitted the content checksum")
        checksum = int.from_bytes(encoded[-4:], "little")
        manifest["xxh32_vectors"].append({"length": length, "xxh32": f"{checksum:08x}"})
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
