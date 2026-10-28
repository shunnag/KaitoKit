import bisect, collections, subprocess, sys
from pathlib import Path
binary=sys.argv[1]
symbols=[]
for line in subprocess.check_output(['nm','-n',binary],text=True).splitlines():
    parts=line.split()
    if len(parts)==3 and parts[1].lower()=='t': symbols.append((int(parts[0],16),parts[2]))
addresses=[a for a,_ in symbols]
for file in sys.argv[2:]:
    counts=collections.Counter()
    for line in Path(file).read_text().splitlines():
        name,offset=line.split('\t')
        if Path(name).name!=Path(binary).name: counts[name]+=1; continue
        pc=int(offset,16)+0x100000000
        idx=bisect.bisect_right(addresses,pc)-1
        counts[symbols[idx][1]]+=1
    total=sum(counts.values()); print(Path(file).name,'total samples',total)
    top=counts.most_common(20)
    names=subprocess.check_output(['swift','demangle','--compact'],input='\n'.join(n.removeprefix('_') for n,c in top),text=True).splitlines()
    for (n,c),name in zip(top,names): print(f'{c:6} {100*c/total:5.1f}% {name}')
