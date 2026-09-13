import importlib.util
from pathlib import Path
p=Path('inbox/stuffit/tools/stuffitx_jpeg_tables.py')
s=importlib.util.spec_from_file_location('jpeg_tables',p); m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
out=['// 利用者の独立実装 stuffitx_jpeg_tables.py から数値のみを転記。', '// 出自は vendor バイナリの測定値。詳細は design.md §10 と slice 7 検証記録。', 'enum StuffItXJPEGTables {']
for name,values in m.TABLES.items():
 out.append('    static let '+name+': [Int] = [')
 for i in range(0,len(values),16): out.append('        '+', '.join(map(str,values[i:i+16]))+',')
 out.append('    ]')
out.append('    static let scale: [Double] = ['+', '.join(map(repr,m.SCALE))+']')
out.append('    static let zigzag: [Int] = [')
order=[]
for d in range(15):
 g=[r*8+d-r for r in range(8) if 0<=d-r<8];order.extend(g if d&1 else reversed(g))
for i in range(0,64,16):out.append('        '+', '.join(map(str,order[i:i+16]))+',')
out+=['    ]','}']
Path('Sources/KaitoKit/Codecs/StuffItX/StuffItXJPEGTables.swift').write_text('\n'.join(out)+'\n')
