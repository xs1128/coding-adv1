#!/usr/bin/env python3
"""GPU idle per step (steps 2..N), split into inside / outside COMPUTE-RHS, from an nsys trace dir (profile.sbatch TRACE=1).

  python3 tools/step_idle.py results/prof/<trace dir>
"""
import csv,sys,statistics as st
d=sys.argv[1]
def busy(iv,a,b):
    t=0;cur=a
    for s,e in iv:
        if e<=cur or s>=b: continue
        s,e=max(s,cur),min(e,b)
        if e>s: t+=e-s;cur=e
    return t
for r in "0123":
    iv=[]
    for x in csv.DictReader(open(f"{d}/nsys_rank{r}_cuda_gpu_trace.csv")):
        s=int(x["Start (ns)"]);iv.append((s,s+int(x["Duration (ns)"])))
    iv.sort()
    # merge
    m=[]
    for s,e in iv:
        if m and s<=m[-1][1]: m[-1][1]=max(m[-1][1],e)
        else: m.append([s,e])
    nv=list(csv.DictReader(open(f"{d}/nsys_rank{r}_nvtx_pushpop_trace.csv")))
    steps=sorted((int(x["Start (ns)"]),int(x["End (ns)"])) for x in nv if x["Name"].lstrip(":")=="TIMESTEP")[1:]
    rhs=sorted((int(x["Start (ns)"]),int(x["End (ns)"])) for x in nv if x["Name"].lstrip(":")=="COMPUTE-RHS")
    W=[];I=[];IR=[];GAP=[]
    for a,b in steps:
        w=b-a;i=w-busy(m,a,b)
        ir=sum((rb-ra)-busy(m,ra,rb) for ra,rb in rhs if ra>=a and rb<=b)
        W.append(w);I.append(i);IR.append(ir)
        # list idle gaps outside rhs > 5us
        ins=[(ra,rb) for ra,rb in rhs if ra>=a and rb<=b]
        cur=a
        for s,e in m:
            if e<=a or s>=b: continue
            if s>cur and s-cur>5000:
                g0,g1=cur,s
                if not any(ra<=g0 and g1<=rb for ra,rb in ins): GAP.append(g1-g0)
            cur=max(cur,e)
    print(f"rank {r}: step {st.median(W)/1e6:.3f} ms  idle {st.median(I)/1e6:.3f}  in RHS {st.median(IR)/1e6:.3f}  outside {st.median([i-j for i,j in zip(I,IR)])/1e6:.3f}  gaps>5us outside RHS per step: n={len(GAP)/len(steps):.1f} sum={sum(GAP)/len(steps)/1e6:.3f} ms")
