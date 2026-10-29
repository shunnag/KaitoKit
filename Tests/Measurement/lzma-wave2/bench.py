#!/usr/bin/env python3
"""Warm, alternating kaito bench pairs; save every process's stdout and result."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess

p = argparse.ArgumentParser()
p.add_argument("baseline")
p.add_argument("candidate")
p.add_argument("cases")
p.add_argument("output")
p.add_argument("--rounds", type=int, default=7)
p.add_argument("--reps", type=int, default=9)
args = p.parse_args()
cases = json.loads(Path(args.cases).read_text())
rows = []
with Path(args.output).open("x") as output:
    for round_index in range(args.rounds):
        for case in cases:
            # Fully warm the identical archive before each pair.
            Path(case["path"]).read_bytes()
            for side in (["A", "B"] if round_index % 2 == 0 else ["B", "A"]):
                binary = args.baseline if side == "A" else args.candidate
                command = [binary, "bench", "--threads", "1", case["path"], str(args.reps)]
                result = subprocess.run(command, text=True, capture_output=True)
                row = {"round": round_index + 1, "case": Path(case["path"]).name,
                       "side": side, "command": command, "exit": result.returncode,
                       "stdout": result.stdout, "stderr": result.stderr}
                output.write(json.dumps(row, sort_keys=True) + "\n")
                output.flush()
                assert result.returncode == 0, row
                values = dict(line.split("\t", 1) for line in result.stdout.splitlines())
                assert int(values["bytes"]) == case["bytes"], row
                row["ms"] = float(values["extract-median-ms"])
                rows.append(row)
    for case in cases:
        name = Path(case["path"]).name
        pairs = [{r["side"]: r["ms"] for r in rows
                  if r["case"] == name and r["round"] == i + 1}
                 for i in range(args.rounds)]
        ratios = [pair["B"] / pair["A"] for pair in pairs]
        print(name, json.dumps({"A_ms": statistics.median(p["A"] for p in pairs),
                               "B_ms": statistics.median(p["B"] for p in pairs),
                               "paired_ratio": statistics.median(ratios),
                               "ratio_range": [min(ratios), max(ratios)],
                               "ratios": ratios}))
