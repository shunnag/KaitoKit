#!/usr/bin/env python3
"""Alternate prebuilt release benchmarks, check outputs, record final medians.
Usage: compare.py BEFORE_BINARY AFTER_BINARY OUTPUT_JSON
"""
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys

before, after, destination = sys.argv[1:]
samples = {label: {} for label in ('before', 'after')}
outputs = {}
for cycle in range(3):
    for label, binary in [('before', before), ('after', after)]:
        run = subprocess.run([binary], text=True, capture_output=True, check=True)
        print(f'{label} cycle={cycle + 1}\n{run.stdout}', end='', flush=True)
        for line in run.stdout.splitlines():
            match = re.fullmatch(r'(\S+) bytes=(\d+) reps=(\d+) median_s=(\S+) GB/s=(\S+) result=(\S+)', line)
            assert match, line
            name, count, reps, seconds, rate, result = match.groups()
            signature = (count, reps, result)
            assert outputs.setdefault(name, signature) == signature, (name, label, signature)
            samples[label].setdefault(name, []).append(float(rate))
assert set(outputs) == {'BLAKE2sp', 'CRC64', 'ZipCrypto'}
summary = {}
for name in outputs:
    rates = {label: statistics.median(samples[label][name]) for label in samples}
    summary[name] = dict(before_GB_s=rates['before'], after_GB_s=rates['after'],
                         speedup=rates['after'] / rates['before'],
                         samples_GB_s={label: samples[label][name] for label in samples},
                         bytes=int(outputs[name][0]), repetitions=int(outputs[name][1]),
                         result=outputs[name][2])
Path(destination).write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2), flush=True)
