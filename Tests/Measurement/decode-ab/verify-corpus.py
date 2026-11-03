#!/usr/bin/env python3
"""Compare every entry in a decode-ab corpus with its deterministic source input."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import ab


def digest(path):
    return ab.sha256(path)


def expected_entries(root, record, cache):
    if "entries" in record:
        return [(item["path"], item["size"], item["sha256"]) for item in record["entries"]]
    name = Path(record["path"]).name
    if name.startswith("text"):
        key = "text"
    elif name.startswith("random"):
        key = "random"
    elif name.startswith("small"):
        key = "small"
    else:
        raise ValueError("Cannot determine source for {}".format(name))
    if key not in cache:
        source = root / "inputs" / (key + (".txt" if key == "text" else ".bin") if key != "small" else key)
        paths = sorted(item for item in source.rglob("*") if item.is_file()) if source.is_dir() else [source]
        cache[key] = [(item.relative_to(root / "inputs").as_posix(), item.stat().st_size, digest(item))
                      for item in paths]
    return cache[key]


def run(args):
    kaito = Path(args.kaito).resolve()
    manifest_path = Path(args.manifest).resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    records = [item for item in manifest["archives"]
               if not args.select or any(text in item["path"] for text in args.select)]
    if not records:
        raise ValueError("No archives selected")
    config = {"version": 1, "kaito": str(kaito), "kaito_sha256": ab.sha256(kaito),
              "manifest": str(manifest_path), "manifest_sha256": ab.sha256(manifest_path),
              "threads": args.threads, "select": args.select}
    output = Path(args.out).resolve()
    saved = ab.load_records(output, repair=True)
    if saved and (saved[0].get("type") != "configuration" or saved[0].get("config") != config):
        raise ValueError("Resume configuration changed; use a new --out file")
    outcomes = {row["archive"]: row for row in saved if row.get("type") == "outcome"}
    cache = {}
    failed = False
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("a", encoding="utf-8") as stream:
        if not saved:
            ab.append_record(stream, {"type": "configuration", "config": config})
        for record in records:
            if record["path"] in outcomes:
                failed |= not outcomes[record["path"]]["matched"]
                continue
            archive = (manifest_path.parent / record["path"]).resolve()
            if archive.stat().st_size != record["size"] or ab.sha256(archive) != record["sha256"]:
                raise ValueError("Archive differs from manifest: {}".format(archive))
            expected = expected_entries(manifest_path.parent, record, cache)
            if "ditto" in record["path"] and not record["path"].startswith("archives/small-"):
                expected = [("inputs/" + name, size, sha256) for name, size, sha256 in expected]
            command = [str(kaito), "sha", "--threads", args.threads, str(archive)]
            if "password" in record:
                command += ["-p", record["password"]]
            result = subprocess.run(command, capture_output=True, check=False)
            actual = []
            errors = []
            for line in result.stdout.decode("utf-8", errors="replace").splitlines():
                fields = line.split("\t", 3)
                if len(fields) == 4 and fields[0].isdigit():
                    name = fields[3]
                    if name.endswith("/") or (record["path"].startswith("archives/small-") and name == "small"):
                        continue
                    actual.append((name, int(fields[1]), fields[2]))
            expected_canonical = sorted(expected)
            actual_canonical = sorted(actual)
            matched = result.returncode == 0 and actual_canonical == expected_canonical
            if not matched:
                failed = True
                if result.returncode != 0:
                    errors.append("exit={}".format(result.returncode))
                if result.stderr:
                    errors.append(result.stderr.decode("utf-8", errors="replace"))
                for index in range(max(len(expected_canonical), len(actual_canonical))):
                    before = expected_canonical[index] if index < len(expected_canonical) else None
                    after = actual_canonical[index] if index < len(actual_canonical) else None
                    if before != after:
                        errors.append("first difference: expected={!r} actual={!r}".format(before, after))
                        break
            outcome = {"type": "outcome", "archive": record["path"], "matched": matched,
                       "entries": len(actual), "bytes": sum(item[1] for item in actual),
                       "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(), "errors": errors}
            ab.append_record(stream, outcome)
            print("{}: {} entries; {}".format(record["path"], len(actual), "matched" if matched else errors),
                  flush=True)
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kaito", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--threads", choices=("1", "3", "16", "auto"), default="auto")
    parser.add_argument("--select", action="append")
    args = parser.parse_args()
    try:
        return run(args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("error: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
