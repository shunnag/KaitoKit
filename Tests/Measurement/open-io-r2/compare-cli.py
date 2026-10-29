"""Compare raw listings and extracted-content SHA output from saved CLI stages."""
import hashlib,json,pathlib,subprocess
root=pathlib.Path('/private/tmp/kk-r2io'); rows=[]
for name in ['zip-10000-cp932.zip','zip64-10000.zip','rar5-10000.rar','7z-10000.7z','tar-10000.tar','tar-10000-cp932.tar']:
 for command in [['list','--raw'],['sha']]:
  outputs=[subprocess.check_output([str(root/v/'kaito')]+command+[str(root/'corpus'/name)]) for v in ['before','floor']]
  assert outputs[0]==outputs[1],(name,command)
  rows.append({'archive':name,'command':command,'bytes':len(outputs[0]),'sha256':hashlib.sha256(outputs[0]).hexdigest()})
  print(name,command,'identical',flush=True)
(root/'cli-equivalence.json').write_text(json.dumps(rows,indent=2)+'\n')
