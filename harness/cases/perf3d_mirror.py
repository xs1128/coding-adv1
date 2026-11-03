#!/usr/bin/env python3
"""perf3d.py with each direction's boundaries swapped: CBC (-6) at the beginning, reflective (-2) at the end.

perf3d has CBC at the end of each direction only, so it never takes the CBC code paths for cbc_loc = -1. This case
checks them (bitwise A/B, e.g. for exp-cbcdirect). Correctness only, not a benchmark. Same arguments as perf3d.py.
"""
import json
import os
import subprocess
import sys

# run.sbatch copies the case file into the run folder, so look next to it, then in the repo
cands = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf3d.py"),
         os.path.join(os.environ.get("ROOT", "/work/u1131128/coding-adv1"), "harness/cases/perf3d.py")]
base = next(c for c in cands if os.path.isfile(c))
out = subprocess.run([sys.executable, base, *sys.argv[1:]],
                     check=True, capture_output=True, text=True).stdout
case = json.loads(out)
for d in "xyz":
    case[f"bc_{d}%beg"], case[f"bc_{d}%end"] = -6, -2
print(json.dumps(case))
