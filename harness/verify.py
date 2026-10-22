#!/usr/bin/env python3
"""The correctness gate. Exit 0 only if every check passes; writes results/<LABEL>/verify.json.

  harness/verify.py LABEL [--ref REF_RUN] [--test-summary results/<T>/test_summary.json] [--rtol 1e-12]

Checks (any failure -> FAIL, exit 1):
 1. state: runs/<LABEL> final restart state vs the reference run's state at the same step
    (harness/compare_state.py: bitwise flag, max rel err <= rtol, no NaN/Inf). The default reference is the
    pinned-v5.7.0 case-optimized 1-GPU run `runs/ref/perf3d_201_30` (same grid/steps as the benchmark case).
    Every baseline so far (1/2/4/8 GPUs, host-staged and RDMA) is *bitwise* identical to it, so a change that
    only reorganises parallel work must stay bitwise; anything else is reported with its error.
 2. suite (optional): an MFC `./mfc.sh test` summary from harness/mfctest.sbatch for the same MFC checkout
    must show 0 failures beyond the pinned baseline's known failures (`harness/known_test_failures.txt`).
Never loosen rtol (MFC's own test tolerance is 1e-12).
Run on the nano4 login node (CPU only, reads ~0.5 GB): python3 is the MFC venv's (has numpy).
"""
import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--ref", default="ref/perf3d_201_30")
    ap.add_argument("--test-summary")
    ap.add_argument("--rtol", type=float, default=1e-12)
    a = ap.parse_args()
    out_dir = os.path.join(ROOT, "results", a.label)
    os.makedirs(out_dir, exist_ok=True)
    res = {"label": a.label, "ref": a.ref, "checks": {}}

    st_json = os.path.join(out_dir, "compare_vs_ref.json")
    p = subprocess.run([sys.executable, os.path.join(ROOT, "harness", "compare_state.py"),
                        os.path.join(ROOT, "runs", a.ref), os.path.join(ROOT, "runs", a.label),
                        "--rtol", str(a.rtol), "--json", st_json], capture_output=True, text=True)
    if os.path.exists(st_json) and p.returncode in (0, 1):
        st = json.load(open(st_json))
        res["checks"]["state"] = {k: st.get(k) for k in ("status", "bitwise", "max_rel", "l2_rel", "nonfinite", "step", "reason")}
    else:
        res["checks"]["state"] = {"status": "FAIL", "reason": (p.stderr or p.stdout).strip()[-400:]}

    if a.test_summary:
        known = set()
        kf = os.path.join(ROOT, "harness", "known_test_failures.txt")
        if os.path.exists(kf):
            known = {l.split()[0] for l in open(kf) if l.strip() and not l.startswith("#")}
        try:
            ts = json.load(open(a.test_summary))
            new = sorted(set(ts.get("failed_uuids", [])) - known)
            ok = ts.get("status") == "COMPLETE" and not new
            res["checks"]["suite"] = {"status": "PASS" if ok else "FAIL", "summary": a.test_summary,
                                      "passed": ts.get("passed"), "failed": ts.get("failed"),
                                      "new_failures": new, "known_failures_ignored": sorted(set(ts.get("failed_uuids", [])) & known)}
        except (OSError, ValueError) as e:
            res["checks"]["suite"] = {"status": "FAIL", "reason": f"cannot read {a.test_summary}: {e}"}

    res["status"] = "PASS" if all(c.get("status") == "PASS" for c in res["checks"].values()) else "FAIL"
    with open(os.path.join(out_dir, "verify.json"), "w") as f:
        json.dump(res, f, indent=1)
    print(json.dumps(res, indent=1))
    sys.exit(0 if res["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
