#!/usr/bin/env python3
"""GPU idle inside each RK stage, split by NVTX sub-range, from an nsys trace directory (harness/profile.sbatch TRACE=1).

  python3 tools/stage_idle.py results/prof/<trace dir> [rank ...]
Per rank: median over stages after the first step of COMPUTE-RHS wall time, GPU-busy time (union of kernel and memcpy
intervals), and the idle time that falls inside each direct child range (RHS-COMMUNICATION, RHS-RECONSTRUCTION, ...).
"""
import csv
import statistics as st
import sys
from collections import defaultdict

d = sys.argv[1]
ranks = sys.argv[2:] or ["0", "1", "2", "3"]


def busy_in(iv, a, b):
    tot, cur = 0, a
    for s, e in iv:
        if e <= cur or s >= b:
            continue
        s, e = max(s, cur), min(e, b)
        if e > s:
            tot += e - s
            cur = e
    return tot


for r in ranks:
    iv = sorted((int(x["Start (ns)"]), int(x["Start (ns)"]) + int(x["Duration (ns)"]))
                for x in csv.DictReader(open(f"{d}/nsys_rank{r}_cuda_gpu_trace.csv")))
    rows = list(csv.DictReader(open(f"{d}/nsys_rank{r}_nvtx_pushpop_trace.csv")))
    rhs = [x for x in rows if x["Name"] == ":COMPUTE-RHS"][3:]          # drop the first step's 3 stages
    kids = defaultdict(list)
    for x in rows:
        kids[x["ParentId"]].append(x)
    wall, busy, idle = [], [], defaultdict(list)
    for x in rhs:
        a, b = int(x["Start (ns)"]), int(x["End (ns)"])
        wall.append(b - a)
        busy.append(busy_in(iv, a, b))
        per = defaultdict(int)
        for c in kids[x["RangeId"]]:
            ca, cb = int(c["Start (ns)"]), int(c["End (ns)"])
            per[c["Name"]] += (cb - ca) - busy_in(iv, ca, cb)
        for k, v in per.items():
            idle[k].append(v)
    m = lambda v: st.median(v) / 1e6
    print(f"rank {r}: stages {len(rhs)}  wall {m(wall):.3f}  busy {m(busy):.3f}  idle {m(wall) - m(busy):.3f} ms")
    for k, v in sorted(idle.items(), key=lambda kv: -st.median(kv[1])):
        if st.median(v) > 2e4:
            print(f"    idle in {k:28s} {m(v):.3f} ms  (x{len(kids[rhs[0]['RangeId']]) and sum(1 for c in kids[rhs[0]['RangeId']] if c['Name'] == k)})")
