#!/usr/bin/env python3
"""Report figures from raw results (every bar reads a results/ file; job ids in the labels).

  python3 tools/figs.py [results_dir] [out_dir]     (needs matplotlib; nano4: mfc/build/venv/bin/python)
"""
import csv
import os
import re
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

RES = sys.argv[1] if len(sys.argv) > 1 else "results"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/fig"
os.makedirs(OUT, exist_ok=True)

SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"   # categorical slots 1-3 (validated, light surface)
plt.rcParams.update({"figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "axes.edgecolor": INK2,
                     "axes.labelcolor": INK, "xtick.color": INK2, "ytick.color": INK2, "text.color": INK,
                     "font.size": 10, "axes.spines.top": False, "axes.spines.right": False})


def step(label):
    """Median step (ms) over all ranks from results/<label>/steps.tsv."""
    rows = list(csv.DictReader(open(f"{RES}/{label}/steps.tsv"), delimiter="\t"))
    row = next((r for r in rows if r["rank"] == "all"), rows[0])
    return float(row["step_med_ms"])


def wall(label):
    """Median wall (s) over the timed reps from results/<label>/summary.tsv."""
    v = sorted(float(r["wall_s"]) for r in csv.DictReader(open(f"{RES}/{label}/summary.tsv"), delimiter="\t"))
    n = len(v)
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2


def ncu_groups(label):
    """Kernel time (ms, ncu window) grouped by role, from results/<label>/summary.txt."""
    g = {"WENO5": 0.0, "HLLC": 0.0, "WENO pack": 0.0, "copy-like and other": 0.0}
    for line in open(f"{RES}/{label}/summary.txt"):
        m = re.match(r"\s*(\d+)\s+[\d.]+\s.*\s(\S+)$", line)
        if not m:
            continue
        us, name = float(m.group(1)), m.group(2)
        key = ("WENO5" if "s_weno_1096" in name else "HLLC" if "hllc" in name
               else "WENO pack" if "pack_weno" in name else "copy-like and other")
        g[key] += us / 1e3
    return g


def finish(ax, path):
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    plt.tight_layout()
    plt.savefig(path, dpi=200)
    plt.close()
    print("wrote", path)


# 1. Ladder at 1 GPU. Each rung is its own same-node A/B and every one is bitwise identical to v5.7.0, but the
#    v5.7.0 arm is re-measured per job, so the baseline moves 76.7-77.7 ms between nodes; these are not one job.
ladder = [("v5.7.0", "base/official_1g", "600407"),
          ("P4 - 0001-0006", "p4/ab_1g/b1", "621788"),
          ("P16 - 0001-0019", "final/v570_vs_p16_1g/b1", "669752"),
          ("P18 - 0001-0021", "final/v570_vs_p18_1g/b1", "670158"),
          ("P20 - 0001-0024", "final/v570_p20_p21_1g/b1", "686551"),
          ("P21 - 0001-0030", "final/v570_p20_p21_1g/c1", "686551"),
          ("P22 - 0001-0031", "final/v570_p21_p22_1g/c1", "690631")]
vals = [step(p) for _, p, _ in ladder]
fig, ax = plt.subplots(figsize=(6.4, 2.8))
y = range(len(ladder))[::-1]
ax.barh(list(y), vals, height=0.55, color=[INK2] + [BLUE] * (len(vals) - 1))
for yi, v, (name, _, job) in zip(y, vals, ladder):
    ax.text(v + 0.6, yi, f"{v:.1f} ms  ({job})", va="center", color=INK, fontsize=9)
ax.set_yticks(list(y), [n for n, _, _ in ladder])
ax.set_xlim(0, max(vals) * 1.34)
ax.set_xlabel("median step time, 1 H200 (ms)\nv5.7.0 baseline re-measured per job: 76.7-77.7 ms across nodes")
ax.set_title("Step time per rung, 1 GPU - every rung bitwise identical to v5.7.0", loc="left", fontsize=10)
finish(ax, f"{OUT}/ladder_1g.png")

# 2. Kernel time by role, before and after (ncu, same window and settings)
before, after = ncu_groups("prof/ncu_caseopt_1g"), ncu_groups("prof/ncu_final_1g")
keys = list(before)
fig, ax = plt.subplots(figsize=(6.4, 2.6))
y = range(len(keys))[::-1]
h = 0.36
ax.barh([v + h / 2 for v in y], [before[k] for k in keys], height=h, color=INK2, label="v5.7.0 (600146)")
ax.barh([v - h / 2 for v in y], [after[k] for k in keys], height=h, color=BLUE, label="P3 (606033)")
for v, k in zip(y, keys):
    ax.text(before[k] + 0.2, v + h / 2, f"{before[k]:.1f}", va="center", fontsize=8, color=INK2)
    ax.text(after[k] + 0.2, v - h / 2, f"{after[k]:.1f}", va="center", fontsize=8, color=INK)
ax.set_yticks(list(y), keys)
ax.set_xlabel("kernel time in the ncu window (ms; clocks locked at 1.48 GHz)")
ax.set_title(f"Kernel time by role: {sum(before.values()):.1f} → {sum(after.values()):.1f} ms", loc="left",
             fontsize=10)
ax.legend(frameon=False, fontsize=8, loc="lower right")
finish(ax, f"{OUT}/kernels_1g.png")

# 3. Step time and whole-run wall time, v5.7.0 vs P22, one same-node A/B per set (harness/reproduce.sh wall).
#    Both arms of the 4-GPU set run rdma_mpi, so unlike the 8-GPU row of the 10-31 report this is a like-for-like
#    comparison. No clean 8-GPU P22 A/B exists, so 8 GPUs is left out of the figure.
sets = [("1 GPU", "repro/w1g/base", "repro/w1g/final", "697808 / 697810"),
        ("4 GPUs\n(rdma_mpi)", "repro/w4g/base_rdma", "repro/w4g/final_rdma", "697809 / 697811")]
fig, (axs, axw) = plt.subplots(1, 2, figsize=(8.2, 2.9))
y = range(len(sets))[::-1]
h = 0.34
for v, (name, base, fin, job) in zip(y, sets):
    for ax, metric, fmt, pad in ((axs, step, "{:.1f} ms", 1.2), (axw, wall, "{:.2f} s", 0.28)):
        b, f = metric(base), metric(fin)
        first = v == len(sets) - 1
        ax.barh(v + h / 2, b, height=h, color=INK2, label="v5.7.0" if first else None)
        ax.barh(v - h / 2, f, height=h, color=BLUE, label="P22 (0001-0031)" if first else None)
        ax.text(b + pad, v + h / 2, fmt.format(b), va="center", fontsize=8, color=INK2)
        ax.text(f + pad, v - h / 2, fmt.format(f) + f"  ({b / f:.2f}x)", va="center", fontsize=8, color=INK)
for ax, xlabel, title, xmax in ((axs, "median step time, slowest rank (ms)", "Per step", 100),
                                (axw, "whole run, start-up and save included (s)", "Whole run", 14)):
    ax.set_yticks(list(y), [s[0] for s in sets])
    ax.set_xlim(0, xmax)
    ax.set_xlabel(xlabel)
    ax.set_title(title, loc="left", fontsize=10)
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
axs.legend(frameon=False, fontsize=8, loc="lower right")
fig.suptitle("Same-node A/B, 201\u00b3 cells, FP64, 30 steps - every run bitwise identical to v5.7.0",
             x=0.005, ha="left", fontsize=9.5, color=INK2)
fig.text(0.995, 0.015, "jobs " + ", ".join(s[3] for s in sets), ha="right", fontsize=7.5, color=INK2)
plt.tight_layout(rect=(0, 0, 1, 0.93))
plt.savefig(f"{OUT}/scaling.png", dpi=200)
plt.close()
print("wrote", f"{OUT}/scaling.png")
