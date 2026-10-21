#!/usr/bin/env python3
"""Summarize the CSVs written by harness/profile.sbatch (MODE=nsys) for every rank in a results dir.

  harness/nsys_summary.py results/<LABEL> [--top 20]

Prints, per rank: top GPU kernels (time share, instances, mean), memcpy totals, NVTX range totals for the
RHS phases, MPI totals; then a cross-rank table (GPU-busy vs MPI time) to spot imbalance. Only reads files.
"""
import argparse
import csv
import glob
import os
import re
from collections import defaultdict


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        lines = [l for l in f if l.strip() and not l.startswith("Processing") and not l.startswith("NOTICE")]
    return list(csv.DictReader(lines))


def num(row, *keys):
    for k in keys:
        if k in row and row[k] not in ("", None):
            return float(row[k].replace(",", ""))
    return 0.0


def short(name, n=70):
    name = re.sub(r"_+\d+_gpu$", "", name)
    return name if len(name) <= n else name[: n - 3] + "..."


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--top", type=int, default=20)
    a = ap.parse_args()
    ranks = sorted({re.match(r".*nsys_rank(\d+)_", p).group(1) for p in glob.glob(f"{a.dir}/nsys_rank*_*.csv")}, key=int)
    if not ranks:
        raise SystemExit(f"no nsys CSVs in {a.dir}")
    overview = []
    for r in ranks:
        base = f"{a.dir}/nsys_rank{r}"
        kern = read_csv(f"{base}_cuda_gpu_kern_sum.csv")
        mem = read_csv(f"{base}_cuda_gpu_mem_time_sum.csv")
        nvtx = read_csv(f"{base}_nvtx_sum.csv")
        mpi = read_csv(f"{base}_mpi_event_sum.csv")
        api = read_csv(f"{base}_cuda_api_sum.csv")
        ktot = sum(num(k, "Total Time (ns)") for k in kern)
        mtot = sum(num(m, "Total Time (ns)") for m in mem)
        mpitot = sum(num(m, "Total Time (ns)") for m in mpi)
        nlaunch = sum(num(k, "Instances") for k in kern)
        overview.append((r, ktot, mtot, mpitot, nlaunch))
        if r != ranks[0] and len(ranks) > 2:
            continue  # detailed tables for rank 0 only when many ranks
        print(f"\n=== rank {r}: kernels {ktot/1e6:.1f} ms in {int(nlaunch)} launches, memcpy {mtot/1e6:.1f} ms, MPI {mpitot/1e6:.1f} ms")
        print(f"{'share':>6} {'total ms':>9} {'inst':>7} {'mean us':>9}  kernel")
        for k in sorted(kern, key=lambda k: -num(k, "Total Time (ns)"))[: a.top]:
            t = num(k, "Total Time (ns)")
            print(f"{100*t/ktot:5.1f}% {t/1e6:9.2f} {int(num(k,'Instances')):7d} {num(k,'Avg (ns)')/1e3:9.1f}  {short(k.get('Name',''))}")
        if mem:
            print("-- memcpy/memset")
            for m in mem:
                print(f"   {num(m,'Total Time (ns)')/1e6:9.2f} ms {int(num(m,'Count','Instances')):7d}x  {m.get('Operation','')}")
        if nvtx:
            print("-- NVTX ranges (wall, includes host waits)")
            for n in sorted(nvtx, key=lambda n: -num(n, "Total Time (ns)"))[:16]:
                print(f"   {num(n,'Total Time (ns)')/1e6:9.2f} ms {int(num(n,'Instances')):7d}x  {n.get('Range','')}")
        if api:
            print("-- top CUDA API (host)")
            for c in sorted(api, key=lambda c: -num(c, "Total Time (ns)"))[:8]:
                print(f"   {num(c,'Total Time (ns)')/1e6:9.2f} ms {int(num(c,'Num Calls','Instances')):7d}x  {c.get('Name','')}")
        if mpi:
            print("-- MPI")
            for m in sorted(mpi, key=lambda m: -num(m, "Total Time (ns)"))[:8]:
                print(f"   {num(m,'Total Time (ns)')/1e6:9.2f} ms {int(num(m,'Instances')):7d}x  {m.get('Name', m.get('Event',''))}")
    if len(ranks) > 1:
        print("\n=== per-rank overview")
        print(f"{'rank':>4} {'kernel ms':>10} {'memcpy ms':>10} {'MPI ms':>9} {'launches':>9}")
        for r, k, m, p, n in overview:
            print(f"{r:>4} {k/1e6:10.1f} {m/1e6:10.1f} {p/1e6:9.1f} {int(n):9d}")


if __name__ == "__main__":
    main()
