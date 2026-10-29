#!/usr/bin/env python3
"""time -l の原文と、同じ子プロセスの Darwin カウンタを全標本に保存する。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

binary, collector, corpus, output = map(Path,sys.argv[1:5])
sides=["swift","native","7zz"] if "--candidate" in sys.argv[5:] else ["swift","7zz"]
cases=[c for c in json.loads((corpus/'manifest.json').read_text())['cases'] if '-lzma.' not in c['path']]
records=[]
with output.open('x') as log:
    for case in cases:
        path=corpus/case['path']; path.read_bytes()
        for backend in (b for b in sides if b!='7zz'):
            checked=subprocess.run([str(binary),'sha','--threads','1',str(path)],
                env=dict(os.environ,KAITOKIT_LZMA_BACKEND=backend),capture_output=True,text=True,check=True)
            assert case['sha256'] in checked.stdout,checked.stdout
        for round_ in range(5):
            order=sides[round_%len(sides):]+sides[:round_%len(sides)]
            for backend in order:
                if shutil.disk_usage('/System/Volumes/Data').free<25*1024**3:
                    raise SystemExit('less than 25 GiB free')
                raw=output.parent/f"counter-{case['path']}-{backend}-{round_}.json"
                command=([str(binary),'bench','--threads','1',str(path),'1'] if backend!='7zz'
                         else [shutil.which('7zz'),'x','-so','-mmt=1','-bd','-bb0',str(path)])
                env=dict(os.environ,KAITOKIT_LZMA_BACKEND=backend)
                r=subprocess.run(['/usr/bin/time','-l',str(collector),str(raw),*command],env=env,
                    stdout=subprocess.PIPE if backend!='7zz' else subprocess.DEVNULL,
                    stderr=subprocess.PIPE,text=True)
                sample=json.loads(raw.read_text()); assert sample['exit']==0,sample
                assert sample['rusage_result']==0 and sample['instructions']>0 and sample['cycles']>0,sample
                if backend!='7zz': assert f"bytes\t{case['bytes']}\n" in r.stdout,r.stdout
                sample.update(case=case['path'],backend=backend,round=round_+1,output_bytes=case['bytes'],command=command,
                    time_exit=r.returncode,time_stderr=r.stderr,stdout=r.stdout,
                    instructions_per_byte=sample['instructions']/case['bytes'],cycles_per_byte=sample['cycles']/case['bytes'],ipc=sample['instructions']/sample['cycles'])
                records.append(sample); log.write(json.dumps(sample)+'\n'); log.flush()
        best={b:min((s for s in records if s['case']==case['path'] and s['backend']==b),key=lambda s:s['wall_ns']) for b in sides}
        print(case['path'],json.dumps({b:{k:s[k] for k in ['wall_ns','instructions_per_byte','cycles_per_byte','ipc','peak_rss_bytes']} for b,s in best.items()}),flush=True)
