#!/usr/bin/env python3
# 差分固定値は支給された独立 Python 実装だけから生成する。
import hashlib, json, struct, sys
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'inbox/stuffit/tools'))
from stuffitx_jpeg import *
from stuffitx_jpeg_models import *
from stuffitx_jpeg_baseline import *
from stuffitx_jpeg_restore import *

def packed(values,width='i'):return struct.pack('<'+width*len(values),*values).hex()
def trace(name):
    data=(ROOT/'inbox/stuffit-corpus/jpeg'/name).read_bytes()
    prefix=decode_header(data)
    records=[]
    original=Blocks.block
    def block(self,*args,**kwargs):
        co=original(self,*args,**kwargs)
        records.append(dict(c=args[0],row=args[1],col=args[2],hint=args[5],profile=args[6],co=packed(co),code=self.decoder.code,range=self.decoder.range,position=self.decoder.source.position,rescales=self.model.rescales))
        return co
    Blocks.block=block
    decode_baseline(data)
    Blocks.block=original
    return dict(name=name,input=data.hex(),header=prefix.header.hex(),records=records)

# RangeDecoder の区間更新式の逆演算。検証入力の生成だけに使用する。
class Encoder:
    def __init__(self):self.low=0;self.range=(1<<32)-1;self.cache=0;self.pending=1;self.output=bytearray()
    def shift(self):
        low=self.low & 0xffffffff;carry=self.low>>32
        if low<0xff000000 or carry:
            value=self.cache
            for _ in range(self.pending):self.output.append((value+carry)&255);value=255
            self.cache=low>>24;self.pending=0
        self.pending+=1;self.low=(low<<8)&0xffffffff
    def value(self,f,s):
        assert 0<=s<len(f) and f[s]>0
        unit=self.range//sum(f);self.low+=sum(f[:s])*unit;self.range=f[s]*unit
        while self.range<1<<24:self.range<<=8;self.shift()
    def finish(self):
        for _ in range(5):self.shift()
        return bytes(self.output)
class Decisions:
    def __init__(self):self.encoder=Encoder();self.script=[]
    def value(self,f):
        s=self.script.pop(0) if self.script else 0
        self.encoder.value(f,s);return s

def segment(marker,body):return bytes([255,marker])+struct.pack('>H',len(body)+2)+bytes(body)
def synthetic(mode=2,progressive=False,rows=1,columns=1,restart=0,tail=b'',literal=False,interscan=False):
    d=Decisions();hm=HeaderModel()
    def header(data):
        for b in data:d.script=[b];assert hm.byte(d)==b
    n=3 if mode==1 else 1
    dc_counts=[0]*16;dc_counts[3]=12
    ac_values=[0,0xf0]+[r*16+s for r in range(16) for s in range(1,11)]+[i<<4 for i in range(1,15)]
    ac_counts=[0]*16;ac_counts[7]=len(ac_values)
    dht=segment(196,bytes([0]+dc_counts+list(range(12))+[16]+ac_counts+ac_values))
    q=segment(219,bytes([0]+[5]*64))
    sof=segment(194 if progressive else 192,bytes([8])+struct.pack('>HH',rows*8,columns*8)+bytes([n])+b''.join(bytes([i+1,17,0]) for i in range(n)))
    prefix=b'\xff\xd8'+q+sof+dht+(segment(221,struct.pack('>H',restart)) if restart else b'')
    sos=lambda ss,se,ah,al:segment(218,bytes([n])+b''.join(bytes([i+1,0]) for i in range(n))+bytes([ss,se,ah*16+al]))
    if literal:
        wire=b'\xff\xd8A\xff\xffB\xff\x00\xff\xd8'
        header(wire)
    elif progressive:
        header(prefix+sos(0,0,0,0));header(bytes([255]))
        if interscan:header(dht+segment(254,b'first')+segment(219,bytes([0]+[15]*64))+segment(221,b'\x00\x02')+dht)
        header(sos(1,63,0,0));header(bytes([127]))
        if interscan:header(dht+segment(254,b'last'))
        header(b'\xff\xd9')
        b=Blocks(d);tables=Tables(decode_header(write_wz(0)+write_wz(len(prefix+sos(0,0,0,0)))+prefix+sos(0,0,0,0)))
        quant=tables.scaled(0)
        for row in range(rows):
            for col in range(columns):b.block(0,row,col,columns,quant,1,tables.frame_profiles[0])
    else:
        header(prefix+sos(0,63,0,0))
        b=Mode1Blocks(d) if mode==1 else Blocks(d)
        raw=prefix+sos(0,63,0,0);tables=Tables(decode_header(write_wz(0)+write_wz(len(raw))+raw))
        entropy=EntropyWriter();previous=[0]*n;restarts=0
        for row in range(rows):
            for col in range(columns):
                for c in range(n):
                    if mode==1:
                        d.script=[17] if col else [18] if row else [0,20]
                        co,_=b.block(c,row,col,columns)
                    else:co=b.block(c,row,col,columns,tables.scaled(0),1,tables.frame_profiles[c])
                    entropy.block(co,previous[c],tables.huffman[0],tables.huffman[16]);previous[c]=co[0]
                unit=row*columns+col+1
                if restart and unit<rows*columns and unit%restart==0:
                    entropy.finish();entropy.output.extend((255,208+restarts%8));restarts+=1;previous=[0]*n
        for _ in range(-entropy.count%8):d.value([1,1])
        header(b'\xff\x00Z\xff\xff'+segment(254,b'comment')+b'\xff\xd8')
    for pos in range(0,len(tail),255):part=tail[pos:pos+255];header(bytes([len(part)])+part)
    header(b'\x00')
    wire=write_wz(mode)+write_wz((1<<64)-1)+d.encoder.finish()
    result=restore_jpeg(wire,limits=JpegLimits(64*1024*1024,1048576))
    return dict(name=f'mode{mode}-prog{int(progressive)}-{rows}x{columns}-rst{restart}-literal{int(literal)}-inter{int(interscan)}',input=wire.hex(),output=result.data.hex(),metadata=result.metadata)

def model_vectors():
    co=[i16((i*811)%7001-3500) for i in range(64)];dq=[i16(n*(i%19+1)) for i,n in enumerate(co)]
    q=[i%11+1 for i in range(64)];up=[-711,931,-17,2011,0,-51,3123,91];left=[233,0,33,-1271,431,-511,119,17]
    ln=list(reversed(co));un=co[32:]+co[:32];urn=co[16:]+co[:16];sizes=[cat4(n) for n in co]
    zx=list(range(8));zy=list(reversed(zx));m=Model()
    m.statistics[:]=bytes((i*13+i//257)%127 for i in range(len(m.statistics)))
    m.sign_statistics[:]=bytes((i*7+i//19)%50 for i in range(len(m.sign_statistics)))
    out=[]
    def add(name,args,result):
        keys,f=result
        out.append(dict(name=name,args=args,keys=keys,frequencies=packed(f)))
        m.update(keys,1,6,129)
    add('dc',[2,7,3,[-811,1021,-313,700]],m.dc_dist(2,7,3,[-811,1021,-313,700]))
    add('h',[2,-719,19,43,27,[1,2,3,4]],m.h_dist(2,-719,up,left,19,43,27,[1,2,3,4]))
    add('v',[2,19,43,5,27,[1,2,3,4]],m.v_dist(2,up,left,19,43,5,27,[1,2,3,4]))
    for c in range(3):
        for pos in range(1,64):
            add('ac',[pos,c],m.ac_dist(pos,dq,c,co,up,left,q,63,1,0,zx,zy,sizes,ln,un,urn))
            add('sign',[pos,c],m.sign_dist(pos,co,c,1,up,left,q,ln,un))
    predictors=[]
    for present in range(16):
        for quant in [1,7,37]:
            args=[dq if present&1 else None,ln if present&2 else None,un if present&4 else None,urn if present&8 else None,57,quant]
            p,contexts=dc_prediction(*args);predictors.append(dict(present=present,q=quant,pred=p,contexts=contexts))
    return dict(co=packed(co),dq=packed(dq,'h'),q=packed(q),up=packed(up),left=packed(left),ln=packed(ln),un=packed(un),urn=packed(urn),sizes=packed(sizes),distributions=out,predictors=predictors,directional=[directional_prediction(dq,i,8,p) for p in [0,1,5] for i in range(8)])

def generate():
    fixture=ROOT/'Tests/Fixtures/stuffit/slice7-jpeg-vectors.json'
    cases=[synthetic(),synthetic(rows=3,columns=3,restart=2,tail=bytes(range(256))*2),synthetic(mode=1,rows=3,columns=3,restart=2),synthetic(progressive=True),synthetic(progressive=True,rows=2,columns=3,restart=2),synthetic(literal=True),synthetic(mode=1,literal=True),synthetic(progressive=True,rows=2,columns=3,interscan=True)]
    block=trace('IMG_0243-240-gray.p20.jc');block['records']=block['records'][:64]
    # ヘッダーと最初の 64 ブロックが参照する範囲だけを固定する。
    block['input']=block['input'][:block['records'][-1]['position']*2]
    source=bytes((i*73+i//11+37)&255 for i in range(4096))
    r=RangeDecoder(Bytes(source));m=HeaderModel();head=bytes(m.byte(r) for _ in range(1000))
    header=dict(input=source[:r.source.position].hex(),output=head.hex(),code=r.code,range=r.range,rescales=m.rescales)
    fixture.write_text(json.dumps(dict(cases=cases,models=model_vectors(),blocks=block,header=header,mode1blocks=mode1_trace(),mode1=mode1_vectors(),scans=scan_vectors(cases[0])),sort_keys=True,indent=2)+'\n')
    print(fixture,fixture.stat().st_size)


def mode1_vectors():
    source=Decisions();m=Mode1Blocks(source);operations=[]
    for i in range(120):
        c=i%2;context=[0,1,63,64,80][i%5];s=[0,1,5,16,17,18][i%6]
        source.script=[s]+([j%2 for j in range(s-1)]+[i%2] if 1<=s<=16 else [])
        value=m.dc(c,context);operations.append(dict(kind='dc',c=c,context=context,value=value))
        context=i%36;pos=i%63+1;s=[0,1,2,3,4,10,18,19,20,21,22,23,24][i%13]
        source.script=[s];value=m.ac(c,context,pos);operations.append(dict(kind='ac',c=c,context=context,pos=pos,value=value))
    for i in range(240):
        c=i%2;context=1376 if i%3 else 0;source.script=[1];value=m.sign(c,context)
        operations.append(dict(kind='sign',c=c,context=context,value=value))
    wire=source.encoder.finish();r=RangeDecoder(Bytes(wire));m=Mode1Blocks(r)
    for op in operations:
        c=op['c'];context=op['context']
        if op['kind']=='dc':value=m.dc(c,context);rows=[m.dcrow(c,context),m.dcrow(c,80)]
        elif op['kind']=='ac':value=m.ac(c,context,op['pos']);rows=[m.acrow(c,36*op['pos']+context),m.acrow(c,2304+op['pos']),m.acrow(c,2368+context)]
        else:value=m.sign(c,context);rows=[m.signrows[c,context]]
        assert value==op['value'];op.update(code=r.code,range=r.range,rows=[packed(row) for row in rows])
    return dict(input=wire.hex(),operations=operations)
def scan_vectors(case):
    prefix=decode_header(bytes.fromhex(case['input']));tables=Tables(prefix)
    values=[]
    for kind,scan,co,repeat in [
        ('dc',dict(components=[(1,0)],ss=0,se=0,ah=0,al=1),[-17]+[0]*63,2),
        ('dc_refine',dict(components=[(1,0)],ss=0,se=0,ah=1,al=0),[-17]+[0]*63,2),
        ('first',dict(components=[(1,0)],ss=1,se=63,ah=0,al=1),[(-1 if i%2 else 1)*(i%17) for i in range(64)],4),
        ('refine',dict(components=[(1,0)],ss=1,se=63,ah=1,al=0),[(-1 if i%2 else 1)*(i%4) for i in range(64)],4),
        ('correction_boundary',dict(components=[(1,0)],ss=1,se=63,ah=1,al=0),[2]*64,17),
        ('eob_boundary',dict(components=[(1,0)],ss=1,se=63,ah=0,al=0),[0]*64,32768)]:
        e=ScanEncoder(scan,tables)
        for _ in range(repeat):e.block(co,0,0)
        out,events=e.finish(255)
        values.append(dict(name=kind,scan=scan,co=packed(co),repeat=repeat,output=out.hex(),events=events))
    return values

def mode1_trace():
    data=(ROOT/'inbox/stuffit-corpus/jpeg/IMG_0243-240-b420q75.p10.jc').read_bytes();records=[]
    original=Mode1Blocks.block
    def block(self,*args):
        co,old=original(self,*args)
        records.append(dict(c=args[0],row=args[1],col=args[2],override=args[4],old=old,co=packed(co),code=self.decoder.code,range=self.decoder.range,position=self.decoder.source.position))
        return co,old
    Mode1Blocks.block=block
    decode_mode1(data)
    Mode1Blocks.block=original
    records=records[:96]
    return dict(input=data[:records[-1]['position']].hex(),records=records)
if __name__=='__main__':generate()

