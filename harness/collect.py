#!/usr/bin/env python3
"""Collect every timing result into one table (read-only over results/).

  harness/collect.py [results_dir] > results/table.tsv

One row per results/<LABEL> that has a summary.tsv: job id, MFC checkout + diff hash, build, GPUs, case args,
median grind (MFC: min stage, max rank), median wall of the timed reps, steady-state median step time and first
step from steps.tsv ('all' row = slowest rank), and the verify.json status if present.
"""
import glob
import json
import os
import re
import statistics
import sys


def kv(text, key):
    m = re.search(rf"(?:^|\s){re.escape(key)}=(\S*)", text, re.M)
    return m.group(1) if m else ""


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
    cols = ["label", "job", "mfc", "diff", "build", "ngpu", "case_args", "reps", "grind_ns_med", "wall_s_med",
            "step_ms_med", "step_ms_first", "rhs_ms_med", "comm_ms_med", "verify"]
    print("\t".join(cols))
    for summ in sorted(glob.glob(f"{base}/**/summary.tsv", recursive=True)):
        d = os.path.dirname(summ)
        label = os.path.relpath(d, base)
        if label.startswith("old/") or "/failed_" in "/" + label:
            continue
        env = open(f"{d}/env.txt", errors="replace").read() if os.path.exists(f"{d}/env.txt") else ""
        rows = [l.split("\t") for l in open(summ).read().splitlines()[1:] if l.strip()]
        g = [float(r[2].replace("E", "e")) for r in rows if len(r) > 2 and r[2].strip()]
        w = [float(r[1]) for r in rows if len(r) > 1 and r[1].strip()]
        step = first = rhs = comm = ""
        if os.path.exists(f"{d}/steps.tsv"):
            for l in open(f"{d}/steps.tsv"):
                p = l.rstrip("\n").split("\t")
                if p[0] == "all":
                    first, step, rhs, comm = p[2], p[3], p[6], p[7]
        ver = ""
        if os.path.exists(f"{d}/verify.json"):
            ver = json.load(open(f"{d}/verify.json")).get("status", "")
        m = re.search(r"case_args=(.*?) ngpu=", env)
        mfc = kv(env, "mfc_dir").rsplit("/", 1)[-1] or "mfc"
        print("\t".join(str(x) for x in [
            label, kv(env, "job"), mfc, kv(env, "mfc_diff_sha1"), kv(env, "build"), kv(env, "ngpu"),
            (m.group(1) if m else "").strip() or "-", len(rows),
            f"{statistics.median(g):.4f}" if g else "", f"{statistics.median(w):.2f}" if w else "",
            step, first, rhs, comm, ver]))


if __name__ == "__main__":
    main()
