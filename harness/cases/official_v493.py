#!/usr/bin/env python3
# Upstream v4.9.3 examples/3D_performance_test, unchanged except run_time_info=F (as in the v5.7.0 case),
# so v4.9.3 and v5.7.0 run the same configuration. The official v4.9.3 case itself is run from the worktree.
import json
import subprocess

up = "/work/u1131128/coding-adv1/mfc-v4.9.3/examples/3D_performance_test/case.py"
case = json.loads(subprocess.run(["python3", up], capture_output=True, text=True, check=True).stdout)
case["run_time_info"] = "F"
print(json.dumps(case))
