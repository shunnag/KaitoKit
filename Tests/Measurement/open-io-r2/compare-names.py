"""Byte-compare detection outputs for the authored 736 rows and 74 archive groups."""
import collections, hashlib, json, pathlib, subprocess, sys
root=pathlib.Path('/private/tmp/kk-r2io'); source=pathlib.Path('Tests/Fixtures/encoding/names-multilingual.tsv')
lines=source.read_text().splitlines(); groups=collections.defaultdict(list)
for line in lines[1:]:
 f=line.split('\t'); groups[(f[1],f[2])].append(f[3])
p=root/'authored-archives.tsv'
p.write_text('group\tlang\ttruth_iana\tk\thex1,hex2,...\n'+''.join(f'{lang}/{enc}\t{lang}\t{enc}\t{len(names)}\t{",".join(names)}\n' for (lang,enc),names in sorted(groups.items())))
rows=[]
for mode,path in [([],source),(['--archive'],p)]:
 for prior in [[],['--no-language'],['--language','zh']]:
  outputs=[subprocess.check_output([str(root/label/'kaito'),'detect-encoding']+mode+prior+[str(path)]) for label in sys.argv[1:]]
  assert all(o==outputs[0] for o in outputs), (mode,prior)
  rows.append({'mode':mode,'prior':prior,'bytes':len(outputs[0]),'sha256':hashlib.sha256(outputs[0]).hexdigest()})
(root/'name-equivalence.json').write_text(json.dumps({'rows':len(lines)-1,'groups':len(groups),'variants':sys.argv[1:],'outputs':rows},indent=2)+'\n')
print('identical',len(lines)-1,'rows',len(groups),'groups',len(rows),'commands per binary')
