#!/usr/bin/env python3
"""Run the spec's kaito bench/sha comparisons; retain complete output in JSONL.
Usage: python3 Tests/Benchmarks/CRC16Compare.py bench|sha|sha-lha BEFORE AFTER SCRATCH
"""
import json
import pathlib
import statistics
import subprocess
import sys

mode, before, after, scratch = sys.argv[1:]
scratch = pathlib.Path(scratch)

def run(binary, command, archive, *args):
    p = subprocess.run([binary, command, str(archive), *args], capture_output=True)
    return dict(binary=binary, archive=str(archive), code=p.returncode,
                stdout=p.stdout.decode(), stderr=p.stderr.decode())

if mode == 'bench':
    for archive in [scratch / 'bench3/lhastore/store.lzh',
                    scratch / 'bench-work/corpus/archives/book-tiff-lh7.lzh']:
        timings = {'before': [], 'after': []}
        for cycle in range(3):
            for label, binary in [('before', before), ('after', after)]:
                row = run(binary, 'bench', archive, '3')
                row.update(label=label, cycle=cycle)
                assert row['code'] == 0, row
                ms = float(next(s.split('\t')[1] for s in row['stdout'].splitlines()
                                if s.startswith('extract-median-ms\t')))
                row['ms'] = ms
                timings[label].append(ms)
                print(json.dumps(row), flush=True)
        print(json.dumps(dict(archive=str(archive), medians={k: statistics.median(v)
                         for k, v in timings.items()}, samples=timings)), flush=True)
elif mode in ('sha', 'sha-lha'):
    mismatches = 0
    successes = 0
    count = 0
    directories = ['lha-corpus'] if mode == 'sha-lha' else ['bench-work/corpus/archives', 'lha-corpus']
    for directory in directories:
        root = scratch / directory
        files = root.rglob('*') if mode == 'sha-lha' else root.iterdir()
        for archive in sorted(files):
            if not archive.is_file():
                continue
            old, new = run(before, 'sha', archive), run(after, 'sha', archive)
            equal = all(old[k] == new[k] for k in ['code', 'stdout', 'stderr'])
            count += 1
            mismatches += not equal
            successes += old['code'] == 0 and new['code'] == 0
            print(json.dumps(dict(equal=equal, old=old, new=new)), flush=True)
    print(json.dumps(dict(files=count, successful=successes, mismatches=mismatches)), flush=True)
    sys.exit(bool(mismatches))
else:
    raise SystemExit('mode must be bench, sha, or sha-lha')
