#!/usr/bin/env python3
"""GPU idle gaps (>3 us, all streams merged) per step, grouped by (op before, op after, innermost NVTX range).

  python3 tools/step_gaps.py results/prof/<trace dir> <rank>
"""
import csv,sys,collections
d,r=sys.argv[1],sys.argv[2]
k=[]
for x in csv.DictReader(open(f"{d}/nsys_rank{r}_cuda_gpu_trace.csv")):
    s=int(x["Start (ns)"]);k.append((s,s+int(x["Duration (ns)"]),(x.get("Name") or "")[:60],x.get("Strm","")))
k.sort()
nv=list(csv.DictReader(open(f"{d}/nsys_rank{r}_nvtx_pushpop_trace.csv")))
steps=sorted((int(x["Start (ns)"]),int(x["End (ns)"])) for x in nv if x["Name"].lstrip(":")=="TIMESTEP")[1:]
leaf=[(int(x["Start (ns)"]),int(x["End (ns)"]),x["Name"].lstrip(":"),int(x["Lvl"])) for x in nv]
def where(t):
    c=[l for l in leaf if l[0]<=t<l[1]]
    return max(c,key=lambda l:l[3])[2] if c else "-"
agg=collections.defaultdict(lambda:[0,0])
for a,b in steps:
    cur=a;prev="start"
    for s,e,n,st in k:
        if e<=a or s>=b: continue
        if s-cur>3000:
            key=(prev[:45],n[:45],where(cur+1))
            agg[key][0]+=1;agg[key][1]+=s-cur
        if e>cur: cur=e;prev=n
nst=len(steps)
for key,(c,t) in sorted(agg.items(),key=lambda x:-x[1][1])[:14]:
    print(f"{t/nst/1e3:7.1f} us/step  n={c/nst:4.1f}  after {key[0]!r} -> {key[1]!r}  in {key[2]}")
