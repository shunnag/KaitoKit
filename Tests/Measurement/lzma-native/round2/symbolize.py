#!/usr/bin/env python3
"""Kaito 自身の PC だけを自分たちの DWARF で解決する。"""
import json
from pathlib import Path
import subprocess
import sys
w=Path(sys.argv[1]); binary=w/'bin/profile'
for case in ['jpeg.7z','jpeg.xz','text.7z','text.xz']:
    lines=(w/(case+'.sample.tsv')).read_text().splitlines()
    meta=lines[0].split('\t');load=meta[1]
    samples=[l.split('\t')[1:] for l in lines if l.startswith('S\t')]
    symbols={parts[1]:parts[2:] for l in lines if l.startswith('D\t') for parts in [l.split('\t')]}
    own={int(a,16) for a,d in symbols.items() if d and d[0]==str(binary)}
    addresses=sorted(own | {a-4 for a in own})
    inp=w/(case+'.addresses');inp.write_text(''.join(f'0x{a:x}\n' for a in addresses))
    r=subprocess.run(['xcrun','atos','-o',str(binary),'-l',load,'-arch','arm64','-fullPath','-inlineFrames','-d',' | ','-f',str(inp)],capture_output=True,text=True,check=True)
    (w/(case+'.symbols.txt')).write_text(r.stdout)
    resolved=[" | ".join(b.strip().splitlines()) for b in r.stdout.split("\n | \n") if b.strip()];assert len(resolved)==len(addresses),(len(resolved),len(addresses),r.stderr)
    mapping={f'{a:x}':s for a,s in zip(addresses,resolved)}
    result=dict(load=load,slide=meta[2],samples=len(samples),other_thread_samples=int(meta[4]),stacks=samples,external_symbols=symbols,own_symbols=mapping)
    (w/(case+'.profile.json')).write_text(json.dumps(result))
    print(case,len(samples),len(addresses),flush=True)
