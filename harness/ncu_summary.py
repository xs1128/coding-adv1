#!/usr/bin/env python3
"""Per-kernel table from an ncu raw CSV export (harness/profile.sbatch MODE=ncu -> ncu_raw.csv).

  harness/ncu_summary.py results/<LABEL>/ncu_raw.csv [--min-us 50]

Columns: duration, registers/thread, block size, theoretical occupancy limit by registers, achieved
warps-active %, DRAM bandwidth (TB/s and % of the 4.8 TB/s H200 peak), SM throughput %, FP64 pipe %,
register-spill instructions, local-memory spilling requests. Only reads the file.
"""
import argparse
import csv
import re

H200_DRAM_TBS = 4.8


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--min-us", type=float, default=50)
    a = ap.parse_args()
    rows = list(csv.reader(open(a.csv)))
    hdr, units, data = rows[0], rows[1], rows[2:]
    ix = {h: i for i, h in enumerate(hdr)}

    def g(r, k, scale=1.0):
        try:
            v = float(r[ix[k]].replace(",", ""))
        except (KeyError, ValueError):
            return float("nan")
        return v * scale

    def to_us(r):
        u = units[ix["gpu__time_duration.sum"]]
        return g(r, "gpu__time_duration.sum") * {"ns": 1e-3, "usecond": 1, "us": 1, "msecond": 1e3, "ms": 1e3}.get(u, 1e-3)

    def to_tbs(r):
        u = units[ix["dram__bytes.sum.per_second"]] if "dram__bytes.sum.per_second" in ix else ""
        v = g(r, "dram__bytes.sum.per_second")
        return v * {"Tbyte/second": 1, "Tbyte/s": 1, "Gbyte/second": 1e-3, "Gbyte/s": 1e-3, "Mbyte/s": 1e-6, "byte/second": 1e-12}.get(u, 1e-3)

    out = []
    for r in data:
        us = to_us(r)
        if us < a.min_us:
            continue
        name = re.sub(r"^(m_)?", "", r[ix["Kernel Name"]])[:58]
        tbs = to_tbs(r)
        out.append((us, name, int(g(r, "launch__registers_per_thread")), int(g(r, "launch__block_size")),
                    g(r, "launch__occupancy_limit_registers"), g(r, "sm__warps_active.avg.pct_of_peak_sustained_active"),
                    tbs, 100 * tbs / H200_DRAM_TBS, g(r, "sm__throughput.avg.pct_of_peak_sustained_elapsed"),
                    g(r, "sm__pipe_fp64_cycles_active.avg.pct_of_peak_sustained_elapsed"),
                    g(r, "sass__inst_executed_register_spilling"), g(r, "derived__local_spilling_requests")))
    tot = sum(o[0] for o in out)
    print(f"{'us':>8} {'%':>5} {'reg':>4} {'blk':>4} {'occL':>4} {'warp%':>6} {'TB/s':>5} {'dram%':>5} {'sm%':>5} {'fp64%':>5} {'spillI':>9} {'lspill':>9}  kernel")
    for o in sorted(out, key=lambda o: -o[0]):
        print(f"{o[0]:8.0f} {100*o[0]/tot:5.1f} {o[2]:4d} {o[3]:4d} {o[4]:4.0f} {o[5]:6.1f} {o[6]:5.2f} {o[7]:5.1f} {o[8]:5.1f} {o[9]:5.1f} {o[10]:9.3g} {o[11]:9.3g}  {o[1]}")
    print(f"total of listed kernels: {tot/1e3:.2f} ms")


if __name__ == "__main__":
    main()
