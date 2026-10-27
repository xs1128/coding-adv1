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


# 1. Ladder at 1 GPU
ladder = [("v5.7.0", "base/official_1g", "600407"), ("+ P1 CBC async", "p1/cbc_async_1g", "601152"),
          ("+ K4b Riemann unity", "k4/unity_1g", "602474"), ("+ K2 WENO reg. cap", "k2/cap128_1g", "602559"),
          ("+ P3 async kernels", "p3/ab_1g/b1", "604561"), ("+ P4 interior reconstruction", "p4/ab_1g/b1", "621788")]
vals = [step(p) for _, p, _ in ladder]
fig, ax = plt.subplots(figsize=(6.4, 2.8))
y = range(len(ladder))[::-1]
ax.barh(list(y), vals, height=0.55, color=[INK2] + [BLUE] * (len(vals) - 1))
for yi, v, (name, _, job) in zip(y, vals, ladder):
    ax.text(v + 0.6, yi, f"{v:.1f} ms  ({job})", va="center", color=INK, fontsize=9)
ax.set_yticks(list(y), [n for n, _, _ in ladder])
ax.set_xlim(0, max(vals) * 1.32)
ax.set_xlabel("median step time, 1 H200 (ms)")
ax.set_title("Step time per rung, 1 GPU (each rung bitwise identical)", loc="left", fontsize=10)
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

# 3. Step time at 1/4/8 GPUs: v5.7.0 vs P3 on one node, P3 vs final (P4) on another; speedup = product of the ratios
sets = [("1 GPU", "final/s1g/base", "final/s1g/final", "p4/ab_1g/a1", "p4/ab_1g/b1"),
        ("4 GPUs\n(all rdma_mpi)", "final/s4g/base_rdma", "final/s4g/final_rdma", "p4/ab_4g_rdma/a1", "p4/ab_4g_rdma/b1"),
        ("8 GPUs\n(v5.7.0 default,\nthen rdma_mpi)", "final/s8g/base_host", "final/s8g/final_rdma", "p4/ab_8g_rdma/a1",
         "p4/ab_8g_rdma/b1")]
fig, ax = plt.subplots(figsize=(6.4, 3.6))
y = range(len(sets))[::-1]
h3 = 0.26
for v, (name, base, p3, p3b, fin) in zip(y, sets):
    sb, s3, sf = step(base), step(p3), step(fin)
    first = v == len(sets) - 1
    ax.barh(v + h3, sb, height=h3, color=INK2, label="v5.7.0" if first else None)
    ax.barh(v, s3, height=h3, color=ORANGE, label="P3" if first else None)
    ax.barh(v - h3, sf, height=h3, color=BLUE, label="final (P4)" if first else None)
    ax.text(sb + 0.8, v + h3, f"{sb:.1f} ms", va="center", fontsize=8, color=INK2)
    ax.text(s3 + 0.8, v, f"{s3:.1f} ms", va="center", fontsize=8, color=INK2)
    ax.text(sf + 0.8, v - h3, f"{sf:.1f} ms  ({sb / s3 * step(p3b) / sf:.2f}×)", va="center", fontsize=8, color=INK)
ax.set_yticks(list(y), [s[0] for s in sets])
ax.set_xlim(0, 100)
ax.set_xlabel("median step time over all ranks (ms)")
ax.set_title("Same-node comparisons, 201³ strong scaling", loc="left", fontsize=10)
ax.legend(frameon=False, fontsize=8, loc="lower right")
finish(ax, f"{OUT}/scaling.png")
