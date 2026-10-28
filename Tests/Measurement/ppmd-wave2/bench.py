#!/usr/bin/env python3
"""Warm, alternating PPMd A/B process and in-process extraction measurements."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('root', type=Path)
parser.add_argument('before')
parser.add_argument('after')
parser.add_argument('--rounds', type=int, default=5)
parser.add_argument('--reps', type=int, default=3)
parser.add_argument('--sink', action='store_true', help='time whole-process sha --sink, like 7zz t')
parser.add_argument('--archives', nargs='+', help='restrict diagnostic runs to named archives')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
with args.output.open('w') as output:
    for kind in ['text', 'color', 'jpeg']:
        for extension in ['7z', 'zip']:
            archive = args.root / (kind + '.' + extension)
            if args.archives and archive.name not in args.archives:
                continue
            archive.read_bytes()
            samples = {'before': [], 'after': [], '7zz': []}
            for round in range(args.rounds):
                order = [('before', args.before), ('after', args.after)]
                if round % 2: order.reverse()
                for side, binary in order + [('7zz', '7zz')]:
                    command = ([binary, 't', '-mmt=1', str(archive)] if side == '7zz' else
                               [binary, 'sha', '--sink', '--threads', '1', str(archive)] if args.sink else
                               [binary, 'bench', '--threads', '1', str(archive), str(args.reps)])
                    start = time.perf_counter()
                    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    wall = (time.perf_counter() - start) * 1000
                    row = dict(archive=archive.name, side=side, round=round, command=command,
                               exit=result.returncode, wall_ms=wall, stdout=result.stdout)
                    if side != '7zz' and not args.sink and result.returncode == 0:
                        values = dict(line.split('\t') for line in result.stdout.splitlines())
                        row['extract_ms'] = float(values['extract-median-ms'])
                        row['bytes'] = int(values['bytes'])
                    output.write(json.dumps(row, sort_keys=True) + '\n'); output.flush()
                    if result.returncode: raise SystemExit(row)
                    samples[side].append(row.get('extract_ms', wall))
            print(archive.name, {side: statistics.median(values) for side, values in samples.items()}, flush=True)
