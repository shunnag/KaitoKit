#!/usr/bin/env python3
"""Alternate warmed single-thread kaito bench processes; retain every command/result."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--before', required=True)
p.add_argument('--after', required=True)
p.add_argument('--workloads', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--rounds', type=int, default=5)
p.add_argument('--reps', type=int, default=7)
a = p.parse_args()
rows = []
for round in range(a.rounds):
    for archive in sorted((a.workloads / 'archives').glob('*.rar')):
        archive.read_bytes()
        for label, binary in ([('before', a.before), ('after', a.after)] if round % 2 == 0 else [('after', a.after), ('before', a.before)]):
            cmd = [binary, 'bench', '--threads', '1', str(archive), str(a.reps)]
            start = time.perf_counter()
            r = subprocess.run(cmd, text=True, capture_output=True)
            row = dict(round=round, archive=archive.name, label=label, command=cmd,
                       wall_ms=1000*(time.perf_counter()-start), exit=r.returncode, stdout=r.stdout, stderr=r.stderr)
            if r.returncode == 0:
                fields = dict(line.split('\t', 1) for line in r.stdout.splitlines() if '\t' in line)
                row['extract_ms'] = float(fields['extract-median-ms'])
                row['bytes'] = int(fields['bytes'])
            rows.append(row)
            with a.out.open('a') as f: f.write(json.dumps(row) + '\n')
            r.check_returncode()
        cmd = [a.after, 'sha', '--sink', '--threads', '1', str(archive)]
        start = time.perf_counter()
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        row = dict(round=round, archive=archive.name, label='after-sink', command=cmd,
                   wall_ms=1000*(time.perf_counter()-start), exit=r.returncode, stderr=r.stderr.decode(errors='replace'))
        rows.append(row)
        with a.out.open('a') as f: f.write(json.dumps(row) + '\n')
        r.check_returncode()
        cmd = ['/opt/homebrew/bin/unrar', 'p', '-inul', '-p-', str(archive)]
        start = time.perf_counter()
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        row = dict(round=round, archive=archive.name, label='unrar', command=cmd,
                   wall_ms=1000*(time.perf_counter()-start), exit=r.returncode, stderr=r.stderr.decode(errors='replace'))
        rows.append(row)
        with a.out.open('a') as f: f.write(json.dumps(row) + '\n')
        r.check_returncode()
summary = []
for archive in sorted({r['archive'] for r in rows}):
    medians = {label: statistics.median(r['wall_ms'] if label in ['unrar','after-sink'] else r['extract_ms'] for r in rows if r['archive'] == archive and r['label'] == label) for label in ['before','after','unrar','after-sink']}
    paired = [next(r['extract_ms'] for r in rows if r['archive']==archive and r['label']=='after' and r['round']==i) / next(r['extract_ms'] for r in rows if r['archive']==archive and r['label']=='before' and r['round']==i) for i in range(a.rounds)]
    summary.append(dict(archive=archive, **medians, paired_ratio_median=statistics.median(paired), paired_ratios=paired))
a.out.with_suffix('.summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
