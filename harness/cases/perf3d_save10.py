#!/usr/bin/env python3
"""perf3d.py with a save every 10 steps (t_step_save = 10) instead of only at the end.

The run then continues after a save, so a bitwise final state also checks that a save leaves the GPU state as it was
(e.g. exp-savepack, which packs the output in the state's own storage and restores it). Correctness only, not a
benchmark. Same arguments as perf3d.py.
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
case["t_step_save"] = 10
print(json.dumps(case))
