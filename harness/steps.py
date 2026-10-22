#!/usr/bin/env python3
"""Per-rank step-time statistics from nsys `nvtx_pushpop_trace` CSV exports (written by harness/run.sbatch).

  harness/steps.py RUN_DIR      (reads RUN_DIR/steps_rank<r>_nvtx_pushpop_trace.csv)

Prints a TSV: one row per rank plus a final 'all' row (max over ranks of each statistic, since the slowest
rank sets the pace). Columns, in ms: first TIMESTEP, median/min/max TIMESTEP over steps 2..N, and per-stage
medians of COMPUTE-RHS and RHS-COMMUNICATION. The first step is reported separately because it carries
one-off costs (e.g. CUDA IPC handle setup with rdma_mpi=T: ~175 ms).
"""
import csv
import glob
import re
import statistics
import sys


def load(path):
    with open(path, newline="") as f:
        lines = [l for l in f if l.strip() and not l.startswith(("Processing", "NOTICE", "WARNING"))]
    rows = list(csv.DictReader(lines))
    out = {}
    for r in rows:
        name = (r.get("Name") or r.get("Range") or "").lstrip(":")
        try:
            start, dur = float(r["Start (ns)"]), float(r["Duration (ns)"])
        except (KeyError, ValueError):
            continue
        out.setdefault(name, []).append((start, dur / 1e6))
    for k in out:
        out[k].sort()
    return out


def med(v):
    return statistics.median(v) if v else float("nan")


def main():
    run = sys.argv[1]
    files = glob.glob(f"{run}/steps_rank*_nvtx_pushpop_trace.csv")
    ranks = sorted(files, key=lambda p: int(re.search(r"steps_rank(\d+)_", p).group(1)))
    if not ranks:
        sys.exit(f"no steps_rank*_nvtx_pushpop_trace.csv in {run}")
    cols = ["rank", "steps", "first_ms", "step_med_ms", "step_min_ms", "step_max_ms", "rhs_med_ms", "comm_med_ms"]
    print("\t".join(cols))
    agg = []
    for p in ranks:
        r = re.search(r"steps_rank(\d+)_", p).group(1)
        d = load(p)
        steps = [x[1] for x in d.get("TIMESTEP", [])]
        rest = steps[1:]
        row = [r, len(steps), steps[0] if steps else float("nan"), med(rest), min(rest, default=float("nan")),
               max(rest, default=float("nan")), med([x[1] for x in d.get("COMPUTE-RHS", [])]),
               med([x[1] for x in d.get("RHS-COMMUNICATION", [])])]
        agg.append(row)
        print("\t".join(str(x) if isinstance(x, (int, str)) else f"{x:.3f}" for x in row))
    allrow = ["all", min(a[1] for a in agg)] + [max(a[i] for a in agg) for i in range(2, len(cols))]
    print("\t".join(str(x) if isinstance(x, (int, str)) else f"{x:.3f}" for x in allrow))


if __name__ == "__main__":
    main()
