#!/usr/bin/env python3
"""Join ncu per-instruction counts (ncu --page source --print-source sass --csv) to source lines from nvdisasm -g.
Usage: ncu_line_join.py SRC.fpp DIR/ (with DIR/sass.csv) KERNEL.sass (nvdisasm -g -c of the same kernel variant)."""
import csv,re,sys,collections
D=sys.argv[2]
# lineinfo: offset -> (line, text)
cur=None; li={}
for l in open(sys.argv[3]):
    m=re.search(r'File "[^"]*/([^/"]+)", line (\d+)',l) if '//##' in l else None
    if m: cur=(m.group(1),int(m.group(2))); continue
    m=re.match(r'\s*/\*([0-9a-f]{4,})\*/\s+(.*?)\s*;',l)
    if m: li[int(m.group(1),16)]=(cur,m.group(2))
rows=list(csv.reader(open(D+'sass.csv')))
kern=[i for i,r in enumerate(rows) if r and r[0]=='Kernel Name']
print('kernels in csv',[rows[i][1] for i in kern], 'li insts',len(li))
h=rows[kern[0]+1]; ie=h.index('Instructions Executed'); ss=h.index('Warp Stall Sampling (All Samples)')
end=kern[1] if len(kern)>1 else len(rows)
body=[r for r in rows[kern[0]+2:end] if len(r)>ie]
a0=int(body[0][0],16)
mis=0; byline=collections.Counter(); bys=collections.Counter(); byop=collections.defaultdict(collections.Counter)
T=S=0
for r in body:
    off=int(r[0],16)-a0; v=float(r[ie] or 0); s=float(r[ss] or 0); T+=v; S+=s
    t=r[1].strip(); op=re.sub(r'^@!?U?P\w+\s+','',t).split()[0] if t else '?'
    ln,lt=li.get(off,(None,''))
    if re.sub(r'\s+',' ',lt)!=re.sub(r'\s+',' ',t.rstrip(' ;')): mis+=1
    byline[ln]+=v; bys[ln]+=s; byop[ln][op.split('.')[0]]+=v
print('insts',len(body),'mismatch',mis,'total exec',T)
src=open(sys.argv[1]).read().split('\n')
for ln,v in byline.most_common(30):
    ops=', '.join(f"{o}{100*c/v:.0f}" for o,c in byop[ln].most_common(4))
    print(f"{100*v/T:5.1f}% st{100*bys[ln]/S:5.1f}% L{ln} [{ops}] {(src[ln[1]-1].strip()[:90] if ln and ln[0]=='m_riemann_solver_hllc.fpp' else '')}")
