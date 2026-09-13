#!/usr/bin/env python3
# 支給 Python だけを差分オラクルとして使い、同一ストリームの結果を再利用する。
import argparse, concurrent.futures, hashlib, json, os, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT/'inbox/stuffit/tools'))
from stuffitx_jpeg_restore import restore_jpeg, JpegLimits
from stuffitx_jpeg import JpegError

def check(item):
    folder = ROOT/'inbox/stuffit-corpus/jpeg'
    start = time.monotonic()
    result = dict(stream=item['stream'], stream_sha256=item['stream_sha256'])
    try:
        restored = restore_jpeg((folder/item['stream']).read_bytes(), limits=JpegLimits(64*1024*1024,1048576))
        expected = (folder/item['source']).read_bytes()
        result.update(status='match' if restored.data == expected else 'mismatch',
                      sha256=hashlib.sha256(restored.data).hexdigest(), metadata=restored.metadata)
    except JpegError as error:
        result.update(status='unsupported', reason=str(error))
    except Exception as error:
        result.update(status='error', reason=str(error))
    result['seconds'] = time.monotonic()-start
    return result

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--workers', type=int, default=3)
    parser.add_argument('--filter', default='')
    parser.add_argument('--swift-report', type=Path)
    args=parser.parse_args()
    manifest=json.loads((ROOT/'inbox/stuffit-corpus/jpeg/manifest.json').read_text())
    items=[x for x in manifest if x['status']=='ok' and args.filter in x['stream']]
    checked=set()
    for item in items:
        for name,digest in [(item['stream'],item['stream_sha256']),(item['source'],item['source_sha256'])]:
            if name not in checked:
                actual=hashlib.sha256((ROOT/'inbox/stuffit-corpus/jpeg'/name).read_bytes()).hexdigest()
                if actual!=digest:raise ValueError('SHA256 mismatch: '+name)
                checked.add(name)
    target=ROOT/'.build/jpeg-oracle.jsonl'
    cache={}
    if target.exists():
        for line in target.read_text().splitlines():
            x=json.loads(line);cache[x['stream_sha256']]=x
    unique={x['stream_sha256']:x for x in items if x['stream_sha256'] not in cache}
    with target.open('a') as output, concurrent.futures.ProcessPoolExecutor(max_workers=args.workers) as pool:
        futures=[pool.submit(check,x) for x in unique.values()]
        for future in concurrent.futures.as_completed(futures):
            result=future.result();cache[result['stream_sha256']]=result
            output.write(json.dumps(result,sort_keys=True)+'\n');output.flush()
            print(result['stream'],result['status'],round(result['seconds'],3),result.get('reason',''),flush=True)
    records=[dict(cache[x['stream_sha256']],stream=x['stream'],mode=x['mode'],second=x['second']) for x in items]
    (ROOT/'.build/jpeg-oracle-expanded.json').write_text(json.dumps(records,indent=2,sort_keys=True)+'\n')
    summary={s:sum(x['status']==s for x in records) for s in ('match','unsupported','mismatch','error')}
    if args.swift_report:
        swift={x['stream']:x for x in json.loads(args.swift_report.read_text())}
        differences=[]
        for x in records:
            y=swift.get(x['stream'],{})
            ok=(x['status']=='match' and y.get('status')=='match' and x['sha256']==y.get('sha256')) or (x['status']=='unsupported' and y.get('status')=='unsupported' and x['reason'] in y.get('error',''))
            if not ok:differences.append(x['stream'])
        summary['swift_differences']=differences
    print(json.dumps(summary,indent=2))
    return int(bool(summary['mismatch'] or summary['error'] or summary.get('swift_differences')))
if __name__=='__main__':sys.exit(main())
