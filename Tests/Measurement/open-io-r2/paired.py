"""Replay saved release stages in alternating A/B order, with identical inputs."""
import json,pathlib,statistics,subprocess,sys,os
root=pathlib.Path('/private/tmp/kk-r2io')
cases=[]
for n in [10000,100000]:
 cases += [(14,f'zip-{n}-cp932.zip','before',[],'traits',[]),
           (15,f'zip64-{n}.zip','before',[],'shared',[]),
           (15,f'zip64-{n}.zip','before',['model'],'shared',['model']),
           (16,f'tar-{n}-cp932.tar','traits',['fixed'],'shared',['fixed']),
           (16,f'zip-{n}-cp932.zip','traits',['fixed'],'shared',['fixed']),
           (17,f'rar5-{n}.rar','before',[],'shared',[]),
           (17,f'7z-{n}.7z','before',[],'shared',[]),
           (18,f'tar-{n}.tar','before',[],'floor',[]),
           (18,f'rar5-{n}.rar','shared',[],'floor',[]),
           (19,f'tar-{n}.tar','before',['high'],'floor',['high']),
           (19,f'tar-{n}.tar','before',['high','model'],'floor',['high','model'])]
cases += [(19,'tar-sparse.tar','before',['high','model'],'floor',['high','model'])]
rows=[]
for candidate,file,left,lf,right,rf in cases:
 if len(sys.argv)>1 and str(candidate) not in sys.argv[1:]:continue
 runs={'before':[],'after':[]}
 for turn in range(int(os.environ.get("KK_R2IO_RUNS", "3"))):
  order=[('before',left,lf),('after',right,rf)]
  if turn%2:order.reverse()
  for label,stage,flags in order:
   runs[label].append(json.loads(subprocess.check_output([str(root/stage/'probe'),str(root/'corpus'/file)]+flags)))
 assert len({r['digest'] for v in runs.values() for r in v})==1,(candidate,file)
 row={'candidate':candidate,'file':file,'beforeStage':left,'beforeFlags':lf,'afterStage':right,'afterFlags':rf,'runs':runs}
 row['median']={label:{k:statistics.median(r[k] for r in v) for k in ['ms','allocations','allocatedBytes','reads','readBytes']} for label,v in runs.items()}
 rows.append(row)
 (root/os.environ.get('KK_R2IO_OUTPUT','paired-results.json')).write_text(json.dumps(rows,indent=2)+'\n')
 print(candidate,file,lf,row['median'],flush=True)
