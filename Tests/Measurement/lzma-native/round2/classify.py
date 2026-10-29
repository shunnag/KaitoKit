#!/usr/bin/env python3
"""自身の DWARF の leaf/inline frame を優先し、重複しない sample 分類を作る。"""
from pathlib import Path
from collections import Counter
import json,re,sys
w=Path(sys.argv[1]);results={}
def own_category(text):
    for frame in text.split(' | '):
        if any(s in frame for s in ['copyLZMA','applyLZMAMatchGroup','emitLZMAMatch']): return 'match_copy_window'
        if any(s in frame for s in ['LZMAHotRangeState.','decodeLZMAPlainLiteral','decodeLZMABitTree','decodeLZMAReverseBitTree','decodeLZMALength','decodeLZMADistance','decodeLZMANewMatchCore']): return 'range_trees'
        if 'decodeLZMARepeatedMatchSymbol' in frame:return 'range_trees'
        if 'decodeLZMALiteralRun' in frame:
            m=re.search(r'LZMADecoder.swift:(\d+)',frame);line=int(m[1]) if m else 0
            if 1539<=line<=1548:return 'match_copy_window'
            if line in [1512,1513,1515,1516,1517,1518,1519,1520,1523,1529,1570,1571,1572,1573,1574]:return 'range_trees'
            return 'state_call_overhead'
        if 'decodeLZMANewMatchRun' in frame:
            m=re.search(r'LZMADecoder.swift:(\d+)',frame);line=int(m[1]) if m else 0
            if line==1180 or 1158<=line<=1179:return 'range_trees'
            return 'state_call_overhead'
        if 'flushLZMAWindow' in frame:return 'output_delivery_check'
        if 'CRC32' in frame or 'CRC64' in frame:return 'output_delivery_check'
        if 'refillInput' in frame or 'beginLZMA2Chunk' in frame or 'ByteReader.' in frame or 'FileByteSource.read' in frame:return 'input_refill'
        if 'LZMADecoder.read' in frame or 'LZMA2Decoder.read' in frame:return 'state_call_overhead'
        if 'readAll' in frame or 'EntryStream.read' in frame or 'ArchiveReader.read' in frame:return 'output_delivery_check'
    return None
for case in ['jpeg.7z','jpeg.xz','text.7z','text.xz']:
    d=json.loads((w/(case+'.profile.json')).read_text());counts=Counter();detail=Counter()
    for stack in d['stacks']:
        label=None;via=''
        for i,a in enumerate(stack):
            key=f'{int(a,16)-(4 if i else 0):x}'
            text=d['own_symbols'].get(key)
            if text:
                label=own_category(text)
                if label:via=text;break
            ext=d['external_symbols'].get(a,['',''])
            if i==0 and ('crc32' in ext[-1].lower() or 'crc64' in ext[-1].lower()):
                label='output_delivery_check';via=ext[-1];break
        label=label or 'other_startup_allocation'
        counts[label]+=1;detail[(label,via)]+=1
    results[case]=dict(samples=d['samples'],other_thread_samples=d['other_thread_samples'],counts=dict(counts),percent={k:100*n/d['samples'] for k,n in counts.items()},details=[dict(category=k[0],symbol=k[1],samples=n) for k,n in detail.most_common()])
    print(case,json.dumps(results[case]['percent']),flush=True)
(w/'profile-summary.json').write_text(json.dumps(results,indent=2)+'\n')
