"""Project-owned synthetic containers, using Python's ZIP/tar writers and RAR5 header grammar."""
import io, pathlib, struct, tarfile, zipfile, zlib, subprocess, shutil
assert shutil.disk_usage('/System/Volumes/Data').free >= 25 * 1024**3, 'disk floor'
root=pathlib.Path('/private/tmp/kk-r2io/corpus'); root.mkdir(parents=True,exist_ok=True)
def vint(n):
 b=bytearray()
 while n>=128: b.append((n&127)|128); n>>=7
 b.append(n); return b
def block(t,s,data=b''):
 body=vint(t)+vint(2 if data else 0)+(vint(len(data)) if data else b'')+s
 body=vint(len(body))+body
 return struct.pack('<I',zlib.crc32(body))+body+data
class SJIS(zipfile.ZipInfo):
 def _encodeFilenameFlags(self): return self.filename.encode('cp932'), self.flag_bits & ~0x800
for count in [10000,100000]:
 for legacy in [False,True]:
  with zipfile.ZipFile(root/f'zip-{count}-{"cp932" if legacy else "ascii"}.zip','w') as z:
   for i in range(count):
    name=f'書庫/第{i:06d}頁.jpg' if legacy else f'pages/page-{i:06d}.jpg'
    z.writestr(SJIS(name) if legacy else name,b'')
 with zipfile.ZipFile(root/f'zip64-{count}.zip','w',allowZip64=True) as z:
  for i in range(count): z.writestr(f'page-{i:06d}',b'x'*2048)
 # Force ZIP64 end records even for 10k (central entries still fit ZIP32).
 p=root/f'zip64-{count}.zip'; b=p.read_bytes(); end=len(b)-22
 if b[end:end+4]==b'PK\x05\x06' and b[end-20:end-16]!=b'PK\x06\x07':
  cdsize,cdoff=struct.unpack_from('<II',b,end+12)
  rec=struct.pack('<IQHHIIQQQQ',0x06064b50,44,45,45,0,0,count,count,cdsize,cdoff)
  loc=struct.pack('<IIQI',0x07064b50,0,end,1)
  eocd=struct.pack('<IHHHHIIH',0x06054b50,0,0,65535,65535,0xffffffff,0xffffffff,0)
  p.write_bytes(b[:end]+rec+loc+eocd)
 for legacy in [False,True]:
  suffix='-cp932' if legacy else ''
  with tarfile.open(root/f'tar-{count}{suffix}.tar','w',format=tarfile.USTAR_FORMAT,encoding='cp932' if legacy else 'utf-8') as t:
   for i in range(count):
    name=f'画像/ページ{i}.jpg' if legacy else f'pages/page-{i:06d}.jpg'
    x=tarfile.TarInfo(name); x.size=16; t.addfile(x,io.BytesIO(b'x'*16))
 with (root/f'rar5-{count}.rar').open('wb') as f:
  f.write(b'Rar!\x1a\x07\x01\x00'+block(1,vint(0)))
  for i in range(count):
   name=f'pages/page-{i:06d}.jpg'.encode(); payload=b'x'*16
   s=vint(4)+vint(16)+vint(0o100644)+struct.pack('<I',zlib.crc32(payload))+vint(0)+vint(1)+vint(len(name))+name
   f.write(block(2,s,payload))
  f.write(block(5,vint(0)))
 # Only this corpus uses CLI generation; executables are black boxes.
 files=root/'files'; files.mkdir(exist_ok=True)
 for i in range(count):
  (files/f'p{i:06d}').write_bytes(b'x')
 subprocess.run(['7zz','a','-t7z','-mx=0','-ms=off','-mhc=off','-mtc=off','-mta=off',str(root/f'7z-{count}.7z'),'.'],cwd=files,stdout=subprocess.DEVNULL,check=True)
 shutil.rmtree(files)
with tarfile.open(root/'tar-sparse.tar','w',format=tarfile.USTAR_FORMAT) as t:
 for i in range(202):
  x=tarfile.TarInfo(f'page-{i:06d}'); x.size=256*1024; t.addfile(x,io.BytesIO(b'x'*x.size))
print('corpus bytes',sum(p.stat().st_size for p in root.iterdir()))
