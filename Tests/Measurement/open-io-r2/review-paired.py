"""Replay all final open/IO workloads plus the adversarial tar layouts."""
import hashlib,json,pathlib,shutil,statistics,subprocess,os
root=pathlib.Path('/private/tmp/kk-r2io');cases=[]
for n in [10000,100000]:
 cases += [(f'zip-{n}-cp932.zip',[]),(f'zip-{n}-cp932.zip',['fixed']),
           (f'zip64-{n}.zip',[]),(f'zip64-{n}.zip',['model']),
           (f'rar5-{n}.rar',[]),(f'rar5-{n}.rar',['high']),
           (f'7z-{n}.7z',[]),(f'tar-{n}-cp932.tar',['fixed']),
           (f'tar-{n}-cp932.tar',['fixed','high']),
           (f'tar-{n}.tar',[]),(f'tar-{n}.tar',['high']),(f'tar-{n}.tar',['high','model'])]
cases += [('tar-sparse.tar',['high']),('tar-sparse.tar',['high','model'])]
for name in [f'tar-mixed-{n}.tar' for n in [1,2,3]]+['tar-pax-sidecar-like.tar','tar-native-pax-xattrs.tar']:
 cases += [(name,[]),(name,['high']),(name,['high','model'])]
for limit in [0,1,512]:
 cases += [('tar-tiny-metadata.tar',[f'metadata={limit}']),('tar-tiny-metadata.tar',['high',f'metadata={limit}'])]
selected=os.environ.get('KK_REVIEW_ONLY')
rows=json.loads((root/'review-measurements.json').read_text()) if selected else []
if selected:cases=[c for c in cases if c[0]==selected]
for name,flags in cases:
 assert shutil.disk_usage('/System/Volumes/Data').free >= 25 * 1024**3, 'disk floor'
 runs={'before':[],'after':[]}
 for turn in range(3):
  order=['before','after'] if turn%2==0 else ['after','before']
  for label in order:
   command=[str(root/f'review-{label}'/'probe'),str(root/'corpus'/name)]+flags
   runs[label].append(json.loads(subprocess.check_output(command)))
 assert len({r['digest'] for samples in runs.values() for r in samples})==1,(name,flags)
 row={'file':name,'flags':flags,'runs':runs}
 row['median']={label:{k:statistics.median(r[k] for r in samples) for k in ['ms','allocations','allocatedBytes','reads','readBytes']} for label,samples in runs.items()}
 row['analytic9ms30MBps']={label:v['reads']*9+v['readBytes']/30000 for label,v in row['median'].items()}
 rows=[r for r in rows if (r['file'],r['flags'])!=(name,flags)]
 rows.append(row)
 (root/'review-measurements.json').write_text(json.dumps(rows,indent=2)+'\n')
 print(name,flags,row['median'],flush=True)
print('all paired entry digests agree:',len(rows),'cases')
