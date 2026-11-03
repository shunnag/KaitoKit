#!/usr/bin/env python3
"""Measure KaitoKit and black-box reference decoders with the decode-ab timing backend."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys

import ab


def reference_tools():
    names = ("7zz", "unrar", "bsdtar", "gzip", "bzip2", "xz", "zstd", "lz4")
    return {name: shutil.which(name) for name in names}


def kaito_command(kaito, archive, record, threads):
    command = [str(kaito), "sha", "--sink", "--threads", threads, str(archive)]
    if "password" in record:
        command += ["-p", record["password"]]
    return command


def reference_command(tools, archive, record, threads, parallel_stream, reference_kaito=None):
    if reference_kaito is not None:
        return kaito_command(reference_kaito, archive, record, threads)
    path = str(archive)
    name = archive.name.lower()
    if name.endswith(".rar"):
        password = record.get("password", "-")
        return [tools["unrar"], "t", "-idq", "-p" + password, path]
    if name.endswith((".7z", ".zip", ".lzh", ".cab", ".chm", ".arj", ".wim", ".dmg", ".msi", ".iso", ".xls", ".doc", ".cfb", ".img")):
        command = [tools["7zz"], "t", "-bd", "-bso0", "-bsp0", "-mmt=" + ("0" if threads == "auto" else threads)]
        if "password" in record:
            command.append("-p" + record["password"])
        return command + [path]
    if ".tar." in name:
        return [tools["bsdtar"], "-xOf", path]
    if name.endswith(".gz"):
        return [tools["gzip"], "-dc", path]
    if name.endswith(".bz2"):
        return [tools["bzip2"], "-dc", path]
    if name.endswith(".xz"):
        return [tools["xz"], "-dc", "-T" + ("0" if parallel_stream else "1"), path]
    if name.endswith(".zst"):
        return [tools["zstd"], "-dc", "-q", "-T" + ("0" if parallel_stream else "1"), path]
    if name.endswith(".lz4"):
        return [tools["lz4"], "-dc", "-q", path]
    raise ValueError("No reference decoder for {}".format(name))


def required_tools(record):
    name = Path(record["path"]).name.lower()
    if name.endswith(".rar"):
        return ("unrar",)
    if name.endswith((".7z", ".zip", ".lzh", ".cab", ".chm", ".arj", ".wim", ".dmg", ".msi", ".iso", ".xls", ".doc", ".cfb", ".img")):
        return ("7zz",)
    if ".tar." in name:
        return ("bsdtar",)
    if name.endswith(".gz"):
        return ("gzip",)
    if name.endswith(".bz2"):
        return ("bzip2",)
    if name.endswith(".xz"):
        return ("xz",)
    if name.endswith(".zst"):
        return ("zstd",)
    if name.endswith(".lz4"):
        return ("lz4",)
    raise ValueError("No reference decoder for {}".format(name))


def run(args):
    if platform.system() != "Darwin":
        raise ValueError("This harness requires macOS")
    kaito = Path(args.kaito).resolve()
    manifest_path = Path(args.manifest).resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    records = [item for item in manifest["archives"]
               if not args.select or any(text in item["path"] for text in args.select)]
    if not records:
        raise ValueError("No archives selected")
    reference_kaito = Path(args.reference_kaito).resolve() if args.reference_kaito else None
    tools = reference_tools()
    missing = [] if reference_kaito else sorted(
        {name for item in records for name in required_tools(item) if not tools[name]})
    if missing:
        raise ValueError("Missing reference tools: " + ", ".join(missing))
    backend, reason = ab.timing_backend()
    if reference_kaito:
        tool_info = {"reference_kaito": {"path": str(reference_kaito), "sha256": ab.sha256(reference_kaito)}}
    else:
        selected_tools = sorted({name for item in records for name in required_tools(item)})
        tool_info = {name: {"path": tools[name], "sha256": ab.sha256(Path(tools[name]))}
                     for name in selected_tools}
    config = {"version": 1, "manifest": str(manifest_path),
              "manifest_sha256": ab.sha256(manifest_path), "select": args.select,
              "kaito": {"path": str(kaito), "sha256": ab.sha256(kaito), "revision": args.revision},
              "threads": args.threads, "parallel_stream": args.parallel_stream,
              "reference_tools": tool_info, "timing_backend": backend}
    output = Path(args.out).resolve()
    saved = ab.load_records(output, repair=True)
    if saved and (saved[0].get("type") != "machine" or saved[0].get("config") != config):
        raise ValueError("Resume configuration changed; use a new --out file")
    samples = {(row["archive"], row["round"], row["side"]): row
               for row in saved if row.get("type") == "sample"}
    failed = False
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("a", encoding="utf-8") as stream:
        if not saved:
            ab.append_record(stream, {"type": "machine", "created_utc": datetime.now(timezone.utc).isoformat(),
                                      "machine": ab.machine_info(), "config": config,
                                      "time_l_unavailable": reason})
        for item in records:
            archive = (manifest_path.parent / item["path"]).resolve()
            if archive.stat().st_size != item["size"] or ab.sha256(archive) != item["sha256"]:
                raise ValueError("Archive differs from manifest: {}".format(archive))
            commands = {
                "kaito": kaito_command(kaito, archive, item, args.threads),
                "reference": reference_command(tools, archive, item, args.threads, args.parallel_stream,
                                                reference_kaito),
            }
            print(archive.name, flush=True)
            for round_index in range(args.rounds):
                order = ("kaito", "reference") if round_index % 2 == 0 else ("reference", "kaito")
                if all((item["path"], round_index, side) in samples for side in order):
                    failed |= any(samples[(item["path"], round_index, side)]["exit_code"] != 0
                                  for side in order)
                    continue
                ab.warm(archive)
                for position, side in enumerate(order):
                    key = (item["path"], round_index, side)
                    if key in samples:
                        failed |= samples[key]["exit_code"] != 0
                        continue
                    command = commands[side]
                    result = ab.measure(command[0], command[1:], backend)
                    row = {"type": "sample", "archive": item["path"], "round": round_index,
                           "side": side, "position": position, "order": list(order),
                           "command": command, **result}
                    ab.append_record(stream, row)
                    samples[key] = row
                    failed |= result["exit_code"] != 0
                    print("  {} {}: {:.6f}s exit={}".format(
                        round_index + 1, side, result["wall"], result["exit_code"]), flush=True)
    return 1 if failed else 0


def summary(path):
    records = ab.load_records(Path(path))
    if not records or records[0].get("type") != "machine":
        raise ValueError("Missing machine record")
    groups = {}
    failed = False
    for row in records:
        if row.get("type") != "sample":
            continue
        failed |= row["exit_code"] != 0
        groups.setdefault(row["archive"], {}).setdefault(row["round"], {})[row["side"]] = row
    print("archive\tpairs\tkaito-median\treference-median\tkaito/reference\tround-kaito/reference")
    for archive, rounds in sorted(groups.items()):
        pairs = [(index, sides) for index, sides in sorted(rounds.items())
                 if "kaito" in sides and "reference" in sides
                 and sides["kaito"]["exit_code"] == 0 and sides["reference"]["exit_code"] == 0]
        if not pairs:
            continue
        before = [sides["reference"]["wall"] for _, sides in pairs]
        after = [sides["kaito"]["wall"] for _, sides in pairs]
        ratios = [sides["kaito"]["wall"] / sides["reference"]["wall"] for _, sides in pairs]
        print("{}\t{}\t{:.6f}\t{:.6f}\t{:.4f}\t{}".format(
            archive, len(pairs), statistics.median(after), statistics.median(before),
            statistics.median(ratios), ",".join("{:.4f}".format(value) for value in ratios)))
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kaito")
    parser.add_argument("--revision", default="unknown")
    parser.add_argument("--manifest")
    parser.add_argument("--out")
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--threads", choices=("1", "auto"), default="1")
    parser.add_argument("--reference-kaito", help="use a second kaito binary as the reference side")
    parser.add_argument("--parallel-stream", action="store_true")
    parser.add_argument("--select", action="append", help="only paths containing this text; repeatable")
    parser.add_argument("--summary", metavar="JSONL")
    args = parser.parse_args()
    if not args.summary and (not args.kaito or not args.manifest or not args.out or args.rounds < 1):
        parser.error("--kaito, --manifest, --out and positive --rounds are required")
    try:
        return summary(args.summary) if args.summary else run(args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("error: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
