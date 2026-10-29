#!/usr/bin/env python3
"""Verify synthetic R3 workloads against their inputs, HEAD, candidate and unrar."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--before',required=True)
p.add_argument('--after',required=True)
p.add_argument('--workloads',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args()
rows=[]
for item in json.loads((a.workloads/'manifest.json').read_text())['archives']:
    archive=a.workloads/item['path']
    expected={e['path']:(e['bytes'],e['sha256']) for e in item['entries']}
    for label,binary in [('before',a.before),('after',a.after)]:
        cmd=[binary,'sha','--threads','1',str(archive)]
        r=subprocess.run(cmd,text=True,capture_output=True)
        actual={parts[3]:(int(parts[1]),parts[2]) for line in r.stdout.splitlines() if len(parts:=line.split('\t'))==4 and parts[0].isdigit()}
        row=dict(archive=item['path'],label=label,command=cmd,exit=r.returncode,stdout=r.stdout,stderr=r.stderr,matched=actual==expected)
        rows.append(row);a.out.write_text(json.dumps(rows,indent=2)+'\n')
        if r.returncode or actual!=expected: raise RuntimeError(row)
    for name,(size,sha) in expected.items():
        cmd=['/opt/homebrew/bin/unrar','p','-inul','-p-',str(archive),name]
        r=subprocess.run(cmd,capture_output=True)
        row=dict(archive=item['path'],label='unrar',entry=name,command=cmd,exit=r.returncode,bytes=len(r.stdout),sha256=hashlib.sha256(r.stdout).hexdigest(),stderr=r.stderr.decode(errors='replace'))
        row['matched']=r.returncode==0 and (row['bytes'],row['sha256'])==(size,sha)
        rows.append(row);a.out.write_text(json.dumps(rows,indent=2)+'\n')
        if not row['matched']: raise RuntimeError(row)
print(f"matched {len(rows)} archive/tool or entry/tool comparisons")
