#!/usr/bin/env python3
"""macOS decode A/B measurement (Python 3.9+, standard library only)."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import time


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command_info(argv):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, check=False)
        return {"exit_code": result.returncode, "stdout": result.stdout.strip(),
                "stderr": result.stderr.strip()}
    except OSError as error:
        return {"error": str(error)}


def machine_info():
    keys = ["hw.ncpu", "hw.memsize", "hw.nperflevels"]
    values = {key: command_info(["/usr/sbin/sysctl", "-n", key]) for key in keys}
    try:
        levels = int(values["hw.nperflevels"]["stdout"])
    except (KeyError, ValueError):
        levels = 2  # 制限環境でも perflevel の取得を試し、失敗を記録する。
    for level in range(levels):
        for field in ("physicalcpu", "name"):
            key = "hw.perflevel{}.{}".format(level, field)
            values[key] = command_info(["/usr/sbin/sysctl", "-n", key])
    return {"platform": platform.platform(), "architecture": platform.machine(),
            "python": platform.python_version(), "sysctl": values,
            "sw_vers": command_info(["/usr/bin/sw_vers"]),
            "xcodebuild": command_info(["/usr/bin/xcodebuild", "-version"])}


def timing_backend():
    probe = subprocess.run(["/usr/bin/time", "-l", "/usr/bin/true"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=False)
    diagnostics = probe.stderr.decode("utf-8", errors="replace")
    if probe.returncode == 0 and "maximum resident set size" in diagnostics:
        return "time-l", None
    if "sysctl kern.clockrate" in diagnostics:
        reason = diagnostics.strip()
        print("warning: time -l is unavailable; using perf_counter / wait4: " + reason,
              file=sys.stderr)
        return "wait4", reason
    raise ValueError("time -l probe failed: " + diagnostics)


def measure(binary, arguments, backend):
    argv = [str(binary)] + arguments
    if backend == "time-l":
        argv = ["/usr/bin/time", "-l"] + argv
    # stderr を file に送ることで pipe の容量に依存せず wait4 できる。
    with tempfile.TemporaryFile() as errors:
        started = time.perf_counter()
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=errors)
        _, status, usage = os.wait4(process.pid, 0)
        elapsed = time.perf_counter() - started
        process.returncode = os.waitstatus_to_exitcode(status)
        errors.seek(0)
        diagnostics = errors.read().decode("utf-8", errors="replace")
    wall_time_l = None
    counters = {"instructions": None, "cycles": None, "peak_footprint": None}
    if backend == "time-l":
        times = re.search(r"^\s*([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys\s*$",
                          diagnostics, re.MULTILINE)
        rss = re.search(r"^\s*(\d+)\s+maximum resident set size\s*$",
                        diagnostics, re.MULTILINE)
        if not times or not rss:
            raise ValueError("time -l metrics are missing: " + diagnostics)
        wall_time_l, user, system = map(float, times.groups())
        max_rss = int(rss.group(1))  # Darwin time(1) / wait4 とも bytes。
        for key, label in (("instructions", "instructions retired"),
                           ("cycles", "cycles elapsed"),
                           ("peak_footprint", "peak memory footprint")):
            value = re.search(r"^\s*(\d+)\s+" + re.escape(label) + r"\s*$",
                              diagnostics, re.MULTILINE)
            if value:
                counters[key] = int(value.group(1))
    else:
        user, system = usage.ru_utime, usage.ru_stime
        max_rss = usage.ru_maxrss
    result = {"wall": elapsed, "wall_time_l": wall_time_l,
              "user": user, "sys": system, "max_rss": max_rss, **counters,
              "exit_code": process.returncode, "timing_backend": backend}
    if process.returncode != 0:
        result["stderr"] = diagnostics
    return result


def load_records(path, repair=False):
    if not path.exists():
        return []
    data = path.read_bytes()
    records = []
    valid_end = 0
    for line in data.splitlines(keepends=True):
        try:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("JSONL records must be objects")
        except (ValueError, UnicodeDecodeError):
            if valid_end + len(line) == len(data) and not line.endswith(b"\n"):
                print("warning: ignoring interrupted last JSONL record", file=sys.stderr)
                if repair:
                    with path.open("r+b") as stream:
                        stream.truncate(valid_end)
                break
            raise ValueError("Invalid JSONL record at byte {}".format(valid_end))
        records.append(record)
        valid_end += len(line)
    if repair and valid_end == len(data) and data and not data.endswith(b"\n"):
        with path.open("ab") as stream:
            stream.write(b"\n")
    return records


def append_record(stream, record):
    stream.write(json.dumps(record, sort_keys=True, ensure_ascii=True) + "\n")
    stream.flush()
    os.fsync(stream.fileno())


def cli_arguments(mode, archive, record):
    arguments = ["list"] if mode == "list" else ["sha"]
    if mode == "sink":
        arguments.append("--sink")
    arguments.append(str(archive))
    if "password" in record:
        arguments += ["-p", record["password"]]
    return arguments


def identity_gate(base, branch, archive, record):
    arguments = cli_arguments("sha", archive, record)
    results = [subprocess.run([str(binary)] + arguments, capture_output=True, check=False)
               for binary in (base, branch)]
    before, after = results
    matched = before.returncode == after.returncode and before.stdout == after.stdout
    gate = {"type": "gate", "archive": record["path"], "matched": matched}
    for side, result in zip(("base", "branch"), results):
        gate[side] = {"exit_code": result.returncode,
                      "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
                      "stdout_bytes": len(result.stdout),
                      "stderr": result.stderr.decode("utf-8", errors="replace")}
    if not matched:
        before_lines, after_lines = before.stdout.splitlines(), after.stdout.splitlines()
        for index in range(max(len(before_lines), len(after_lines))):
            left = before_lines[index] if index < len(before_lines) else b""
            right = after_lines[index] if index < len(after_lines) else b""
            if left != right:
                gate["first_difference"] = {"line": index + 1,
                    "base": left.decode("utf-8", errors="replace"),
                    "branch": right.decode("utf-8", errors="replace")}
                break
    return gate


def warm(archive):
    with archive.open("rb") as stream:
        while stream.read(4 * 1024 * 1024):
            pass


def run(args):
    if platform.system() != "Darwin":
        raise ValueError("This harness requires macOS (/usr/bin/time -l)")
    base = Path(args.base).resolve()
    branch = base if args.same else Path(args.branch).resolve()
    for binary in (base, branch):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError("Not an executable: {}".format(binary))
    manifest_path = Path(args.manifest).resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    archives = manifest["archives"]
    if not archives or len({item["path"] for item in archives}) != len(archives):
        raise ValueError("Manifest must contain archives with unique paths")
    backend, reason = timing_backend()
    config = {"manifest": str(manifest_path), "manifest_sha256": sha256(manifest_path),
              "base": {"path": str(base), "revision": args.base_rev, "sha256": sha256(base)},
              "branch": {"path": str(branch),
                         "revision": args.base_rev if args.same else args.branch_rev,
                         "sha256": sha256(branch)},
              "same": args.same, "timing_backend": backend}
    output = Path(args.out).resolve()
    archive_paths = {(manifest_path.parent / item["path"]).resolve() for item in archives}
    if output in archive_paths or output in (manifest_path, base, branch):
        raise ValueError("Output must not overwrite archives, the manifest or binaries")
    records = load_records(output, repair=True)
    if records and (records[0].get("type") != "machine" or
                    records[0].get("version") != 1 or records[0].get("config") != config):
        raise ValueError("Resume configuration changed; use a new --out file")
    gates = {record["archive"]: record for record in records if record.get("type") == "gate"}
    samples = {(record["archive"], record["mode"], record["round"], record["side"]): record
               for record in records if record.get("type") == "sample"}
    failed = False
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("a", encoding="utf-8") as stream:
        if not records:
            append_record(stream, {"type": "machine", "version": 1,
                "created_utc": datetime.now(timezone.utc).isoformat(),
                "machine": machine_info(), "config": config, "time_l_unavailable": reason})
        for item in archives:
            archive = (manifest_path.parent / item["path"]).resolve()
            if archive == output:
                raise ValueError("Output must not overwrite an archive")
            if archive.stat().st_size != item["size"] or sha256(archive) != item["sha256"]:
                raise ValueError("Archive differs from manifest: {}".format(archive))
            gate = gates.get(item["path"])
            if gate is None:
                gate = identity_gate(base, branch, archive, item)
                append_record(stream, gate)
            if not gate["matched"]:
                print("MISMATCH: {}; timing skipped".format(item["path"]), file=sys.stderr)
                failed = True
                continue
            print("identity OK: {}".format(item["path"]), flush=True)
            for mode in ("list", "sink"):
                for round_index in range(args.rounds):
                    order = ("base", "branch") if round_index % 2 == 0 else ("branch", "base")
                    if all((item["path"], mode, round_index, side) in samples for side in order):
                        failed |= any(samples[(item["path"], mode, round_index, side)]["exit_code"] != 0
                                      for side in order)
                        continue
                    warm(archive)
                    for position, side in enumerate(order):
                        key = (item["path"], mode, round_index, side)
                        if key in samples:
                            failed |= samples[key]["exit_code"] != 0
                            continue
                        result = measure(base if side == "base" else branch,
                                         cli_arguments(mode, archive, item), backend)
                        sample = {"type": "sample", "archive": item["path"], "mode": mode,
                                  "round": round_index, "side": side, "position": position,
                                  "order": list(order), **result}
                        append_record(stream, sample)
                        samples[key] = sample
                        failed |= result["exit_code"] != 0
                        print("  {} round {} {}: {:.6f}s exit={}".format(
                            mode, round_index + 1, side, result["wall"], result["exit_code"]), flush=True)
    return 1 if failed else 0


def ratio(branch, base):
    return branch / base if branch is not None and base is not None and base > 0 else None


def number(value):
    return "n/a" if value is None else "{:.4f}".format(value)


def summary(path, metric):
    records = load_records(Path(path))
    if not records or records[0].get("type") != "machine":
        raise ValueError("Missing machine record")
    config = records[0]["config"]
    unit = ("bytes" if metric in ("max_rss", "peak_footprint") else
            "count" if metric in ("instructions", "cycles") else "seconds")
    print("metric={} ({}), backend={}, same={}".format(
        metric, unit, config["timing_backend"], config["same"]))
    groups = {}
    mismatches = set()
    failures = 0
    for record in records:
        if record.get("type") == "gate" and not record["matched"]:
            mismatches.add(record["archive"])
        if record.get("type") == "sample":
            if record["exit_code"] != 0:
                failures += 1
                continue
            group = groups.setdefault((record["archive"], record["mode"]), {})
            group.setdefault(record["round"], {})[record["side"]] = record.get(metric)
    print("archive\tmode\tpairs\tbase-best\tbase-median\tbranch-best\tbranch-median"
          "\tbest-B/A\tmedian-B/A\tround-B/A")
    for (archive, mode), rounds in sorted(groups.items()):
        # 再開途中の片側だけの sample は対比較へ混ぜない。
        pairs = [(index, sides) for index, sides in sorted(rounds.items())
                 if "base" in sides and "branch" in sides]
        if not pairs:
            continue
        available = [(index, sides) for index, sides in pairs
                     if sides["base"] is not None and sides["branch"] is not None]
        before = [sides["base"] for _, sides in available]
        after = [sides["branch"] for _, sides in available]
        base_best, branch_best = min(before, default=None), min(after, default=None)
        base_median = statistics.median(before) if before else None
        branch_median = statistics.median(after) if after else None
        per_round = ",".join("{}:{}".format(index + 1, number(ratio(sides["branch"], sides["base"])))
                             for index, sides in pairs)
        print("\t".join([archive, "sha --sink" if mode == "sink" else mode, str(len(available)),
              number(base_best), number(base_median), number(branch_best), number(branch_median),
              number(ratio(branch_best, base_best)), number(ratio(branch_median, base_median)),
              per_round]))
    for archive in sorted(mismatches):
        print("MISMATCH\t{}\ttiming skipped".format(archive))
    if failures:
        print("{} failed samples excluded".format(failures))
    return 1 if mismatches or failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="base release kaito binary")
    parser.add_argument("--branch", help="branch release kaito binary (optional with --same)")
    parser.add_argument("--base-rev", default="unknown", help="git revision of base binary")
    parser.add_argument("--branch-rev", default="unknown", help="git revision of branch binary")
    parser.add_argument("--same", action="store_true", help="compare base to itself for noise floor")
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--manifest", help="make-corpus.sh manifest.json")
    parser.add_argument("--out", help="resumable JSONL output")
    parser.add_argument("--summary", metavar="JSONL", help="print paired best / median / round ratios")
    parser.add_argument("--metric", choices=("wall", "user", "sys", "max_rss", "instructions",
                                           "cycles", "peak_footprint"), default="wall")
    args = parser.parse_args()
    if not args.summary:
        if not args.base or (not args.branch and not args.same) or not args.manifest or not args.out:
            parser.error("--base, --branch (or --same), --manifest and --out are required")
        if args.rounds < 1:
            parser.error("--rounds must be positive")
    try:
        return summary(args.summary, args.metric) if args.summary else run(args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("error: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
