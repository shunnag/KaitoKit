from pathlib import Path
import argparse, gzip, io, json, statistics, struct, subprocess, tarfile, zipfile

def crc16(data):
    value=0
    for b in data:
        value ^= b
        for _ in range(8): value=(value >> 1) ^ (0xA001 if value & 1 else 0)
    return value

def make_inputs(root):
    root.mkdir(parents=True,exist_ok=True)
    payload=bytes(range(64)); crc=crc16(payload)
    for level,encoding in [(0,'ascii'),(0,'cp932'),(2,'ascii')]:
        archive=bytearray()
        for i in range(10000):
            name=(f'pages/page-{i:05d}.jpg' if encoding=='ascii' else f'書庫/第{i:05d}頁.jpg').encode(encoding)
            date=((2024-1980)<<25)|(2<<21)|(29<<16)|(12<<11)
            common=b'-lh0-'+struct.pack('<III',len(payload),len(payload),date if level==0 else 1709164800)+bytes([0x20,level])
            if level==0:
                body=common+bytes([len(name)])+name+struct.pack('<H',crc)+b'M'
                header=bytes([len(body),sum(body)&255])+body
            else:
                extension=b'\x01'+name+b'\0\0'
                header=struct.pack('<H',26+len(extension))+common+struct.pack('<H',crc)+b'M'+struct.pack('<H',len(extension))+extension
            archive.extend(header); archive.extend(payload)
        archive.append(0)
        (root/f'lha-{level}-{encoding}.lzh').write_bytes(archive)
    buf=io.BytesIO()
    with tarfile.open(fileobj=buf,mode='w',format=tarfile.USTAR_FORMAT) as archive:
        for i in range(10000):
            info=tarfile.TarInfo(f'pages/page-{i:05d}.jpg');info.size=len(payload);info.mtime=1709164800
            archive.addfile(info,io.BytesIO(payload))
    (root/'tar-10000.tar').write_bytes(buf.getvalue())
    (root/'tar-10000.tar.gz').write_bytes(gzip.compress(buf.getvalue(),mtime=0))
    page=bytes((i*17+(i>>4))&255 for i in range(65536))
    for compression,name in [(zipfile.ZIP_STORED,'stored'),(zipfile.ZIP_DEFLATED,'deflate')]:
        with zipfile.ZipFile(root/f'zip-{name}.zip','w',compression=compression) as archive:
            for i in range(200):archive.writestr(f'page-{i:03d}.jpg',page)

def bench(before,after,inputs,output):
    report={'before':before,'after':after,'cases':[]}
    for path in sorted(inputs.iterdir()):
        shas=[subprocess.check_output([exe,'sha',str(path)]) for exe in [before,after]]
        if shas[0]!=shas[1]:raise RuntimeError('SHA difference: '+str(path))
        measures={variant: {'open':[],'extract':[]} for variant in ['before','after']}
        for turn in range(6):
            order=[('before',before),('after',after)]
            if turn%2:order.reverse()
            for variant,exe in order:
                result=subprocess.check_output([exe,'bench',str(path),'5'],text=True)
                for line in result.splitlines():
                    key,value=line.split('\t',1)
                    if key in ['open-median-ms','extract-median-ms']:
                        measures[variant]['open' if key.startswith('open') else 'extract'].append(float(value))
        case={'input':path.name,'sha_matches':True,'measurements':measures}
        for metric in ['open','extract']:
            old=statistics.median(measures['before'][metric]);new=statistics.median(measures['after'][metric])
            case[metric]={'before_median_ms':old,'after_median_ms':new,'ratio':new/old}
        report['cases'].append(case)
        output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(path.name,json.dumps({metric:case[metric] for metric in ['open','extract']}),flush=True)

parser=argparse.ArgumentParser()
parser.add_argument('mode',choices=['generate','compare']);parser.add_argument('directory',type=Path)
parser.add_argument('--before');parser.add_argument('--after');parser.add_argument('--output',type=Path)
args=parser.parse_args()
if args.mode=='generate':make_inputs(args.directory)
else:bench(args.before,args.after,args.directory,args.output)
