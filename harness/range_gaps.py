#!/usr/bin/env python3
"""Per-NVTX-range wall vs GPU-busy time and CUDA API calls per RK stage, from a TRACE=1 profile (rank 0).

  harness/range_gaps.py results/<LABEL> [--prefix RHS]

Steady state only (from the 2nd TIMESTEP on). wall - gpu = host gaps (launch/sync round trips).
"""
import argparse
import collections
import csv

ap = argparse.ArgumentParser()
ap.add_argument("dir")
ap.add_argument("--prefix", default="RHS")
a = ap.parse_args()
nv = list(csv.DictReader(open(f"{a.dir}/nsys_rank0_nvtx_pushpop_trace.csv")))
api = list(csv.DictReader(open(f"{a.dir}/nsys_rank0_cuda_api_trace.csv")))
gpu = list(csv.DictReader(open(f"{a.dir}/nsys_rank0_cuda_gpu_trace.csv")))
for r in api + gpu:
    r["s"] = int(r["Start (ns)"]); r["e"] = r["s"] + int(r["Duration (ns)"])
steps = [(int(r["Start (ns)"]), int(r["End (ns)"])) for r in nv if r["Name"].lstrip(":") == "TIMESTEP"]
t0, nst = steps[1][0], (len(steps) - 1) * 3
agg = collections.defaultdict(lambda: [0, 0, collections.Counter()])
for r in nv:
    n, s, e = r["Name"].lstrip(":"), int(r["Start (ns)"]), int(r["End (ns)"])
    if s < t0 or not n.startswith(a.prefix):
        continue
    x = agg[n]
    x[0] += e - s
    x[1] += sum(min(e, g["e"]) - max(s, g["s"]) for g in gpu if g["e"] > s and g["s"] < e)
    for c in api:
        if c["s"] >= s and c["e"] <= e:
            x[2][c["Name"].replace("_v2", "")] += 1
print(f"steps ms: {[round((e - s) / 1e6, 2) for s, e in steps]}")
print(f"{'range':28s} {'wall/stage':>11s} {'gpu/stage':>10s} {'gap/stage':>10s}  calls/stage")
for n, (w, g, cnt) in sorted(agg.items(), key=lambda kv: -kv[1][0]):
    print(f"{n:28s} {w / nst / 1e6:9.3f}ms {g / nst / 1e6:8.3f}ms {(w - g) / nst / 1e6:8.3f}ms  "
          + ", ".join(f"{k}:{v / nst:.0f}" for k, v in cnt.most_common(5)))
