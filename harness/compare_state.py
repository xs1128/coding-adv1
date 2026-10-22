#!/usr/bin/env python3
"""Compare the final conservative state of two MFC runs (parallel_io restart files, raw float64).

  harness/compare_state.py RUN_A RUN_B [--step N] [--rtol 1e-12] [--json out.json]

RUN_x is a run dir (runs/<LABEL>) containing restart_data/lustre_<N>.dat (parallel_io=T). The files are the
concatenated FP64 conservative variables of the whole domain; the layout is identical for runs with the same
grid regardless of rank count, so A/B across builds *and* rank counts is valid. Reports bitwise equality,
max |a-b|, max relative error (with an absolute floor at 1e-300 of the field scale) and relative L2.
Exit 1 if max relative error > rtol.  Same tolerance as `./mfc.sh test` (1e-12) by default — never loosen it.
"""
import argparse
import glob
import json
import os
import re
import sys

import numpy as np


def latest(run, step):
    files = glob.glob(os.path.join(run, "restart_data", "lustre_*.dat"))
    steps = {int(m.group(1)): f for f in files if (m := re.search(r"lustre_(\d+)\.dat$", f))}
    if not steps:
        raise SystemExit(f"no restart_data/lustre_<step>.dat in {run}")
    return steps[step] if step is not None else steps[max(steps)], (step if step is not None else max(steps))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--step", type=int)
    ap.add_argument("--rtol", type=float, default=1e-12)
    ap.add_argument("--json")
    o = ap.parse_args()
    fa, sa = latest(o.a, o.step)
    fb, sb = latest(o.b, o.step if o.step is not None else sa)
    a = np.fromfile(fa, dtype="<f8")
    b = np.fromfile(fb, dtype="<f8")
    res = {"a": fa, "b": fb, "step": sa, "n": int(a.size)}
    if a.size != b.size:
        res.update(status="FAIL", reason=f"size mismatch {a.size} vs {b.size}")
    else:
        d = np.abs(a - b)
        scale = np.maximum(np.abs(a), np.abs(b))
        floor = max(1e-300, 1e-14 * float(np.max(np.abs(a))))  # absolute floor for near-zero entries
        rel = d / np.maximum(scale, floor)
        res.update(
            bitwise=bool(np.array_equal(a.view("<u8"), b.view("<u8"))),
            nonfinite=int(np.count_nonzero(~np.isfinite(a)) + np.count_nonzero(~np.isfinite(b))),
            max_abs=float(d.max()),
            max_rel=float(rel.max()),
            l2_rel=float(np.linalg.norm(a - b) / max(np.linalg.norm(a), 1e-300)),
            rtol=o.rtol,
        )
        res["status"] = "PASS" if res["nonfinite"] == 0 and res["max_rel"] <= o.rtol else "FAIL"
    print(json.dumps(res, indent=1))
    if o.json:
        with open(o.json, "w") as f:
            json.dump(res, f, indent=1)
    sys.exit(0 if res["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
