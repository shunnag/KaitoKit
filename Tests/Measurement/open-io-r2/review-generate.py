"""Tar adversarial-review corpora; native tar is used only as a black box."""
import io,json,os,pathlib,plistlib,shutil,subprocess,tarfile,sys
root=pathlib.Path('/private/tmp/kk-r2io'); corpus=root/'corpus'
assert shutil.disk_usage('/System/Volumes/Data').free >= 25 * 1024**3, 'disk floor'
corpus.mkdir(parents=True,exist_ok=True)
def add(t,name,size=16,pax=None):
 info=tarfile.TarInfo(name);info.size=size;info.mtime=1700000000
 if pax:info.pax_headers=pax
 t.addfile(info,io.BytesIO(bytes(size)))
if '--native-only' not in sys.argv:
 with tarfile.open(corpus/'tar-tiny-metadata.tar','w',format=tarfile.USTAR_FORMAT) as t:
  for i in range(100):add(t,f'page-{i}')
 for n in [1,2,3]:
  with tarfile.open(corpus/f'tar-mixed-{n}.tar','w',format=tarfile.USTAR_FORMAT) as t:
   for group in range(40):
    for small in range(n):add(t,f'small-{group}-{small}')
    add(t,f'large-{group}',4<<20)
 with tarfile.open(corpus/'tar-pax-sidecar-like.tar','w',format=tarfile.PAX_FORMAT) as t:
  for i in range(40):
   add(t,f'._page-{i}',700,{'path':f'._page-{i}','comment':'q'*700})
   add(t,f'page-{i}',4<<20,{'path':f'page-{i}'})
inputs=root/'native-pax-input';inputs.mkdir(exist_ok=True)
where=plistlib.dumps(['https://example.invalid/archive-review'])
for i in range(40):
 p=inputs/f'page-{i:03d}.bin'
 with p.open('wb') as f:f.write(bytes(range(256))*((4<<20)//256))
 for key,value in [('com.apple.quarantine',b'0083;671f0000;KaitoKit;'),('com.apple.metadata:kMDItemWhereFroms',where)]:
  subprocess.run(['/usr/bin/xattr','-wx',key,value.hex(),str(p)],check=True)
  actual=subprocess.check_output(['/usr/bin/xattr','-px',key,str(p)],text=True)
  assert bytes.fromhex(actual)==value
command=['/usr/bin/tar','--format','pax','-cf',str(corpus/'tar-native-pax-xattrs.tar'),'-C',str(inputs),'.']
env=os.environ.copy()
for key in ['COPYFILE_DISABLE','COPY_EXTENDED_ATTRIBUTES_DISABLE']:env.pop(key,None)
subprocess.run(command,env=env,check=True)
shutil.rmtree(inputs)
assert (corpus/'tar-native-pax-xattrs.tar').stat().st_size > 160 * (1<<20), 'native fixture must contain physical, non-sparse payloads'
(root/'review-generation.json').write_text(json.dumps({'nativeTarCommand':command,'nativeFiles':40,'nativeMemberSize':4<<20,'nativeXattrs':['com.apple.quarantine','com.apple.metadata:kMDItemWhereFroms']},indent=2)+'\n')
print('review corpus bytes',sum(p.stat().st_size for p in corpus.iterdir()))
