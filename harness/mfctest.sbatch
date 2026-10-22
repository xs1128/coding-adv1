#!/usr/bin/env bash
# ./mfc.sh test on the generic build: harness/submit.sh test/<label> - NGPU MIN SCRIPT=mfctest [TEST_ARGS=..] [JOBS=..]
# Out: results/<LABEL>/test_summary.json
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -uo pipefail
ROOT=/work/u1131128/coding-adv1
source "$ROOT/scripts/env.sh"
: "${LABEL:?}" "${NGPU:=1}" "${TEST_ARGS:=}" "${JOBS:=$((2 * NGPU))}"
out=$ROOT/results/$LABEL; mkdir -p "$out"
{
  echo "job=$SLURM_JOB_ID host=$(hostname) date=$(date -Iseconds) ngpu=$NGPU jobs=$JOBS test_args=$TEST_ARGS"
  cat "$ROOT/.provenance"
  echo "cuda=${NVHPC_CUDA_HOME:-bundled} cuda_module=${CUDA_MODULE:-}"
  echo "mfc_dir=$MFC_DIR mfc=$(git -C "$MFC_DIR" describe --always --dirty) $(git -C "$MFC_DIR" rev-parse HEAD)"
  echo "mfc_diff_sha1=$(git -C "$MFC_DIR" diff HEAD -- src toolchain CMakeLists.txt cmake | sha1sum | cut -c1-12)"
  nvidia-smi --query-gpu=index,name --format=csv
} > "$out/env.txt" 2>&1
gpus=$(seq -s ' ' 0 $((NGPU - 1)))
cd "$MFC_DIR"
exec 9> tests/.harness.lock   # tests/<UUID>/ dirs are shared: one suite run per checkout
flock -n 9 || { echo "another ./mfc.sh test holds $MFC_DIR/tests" > "$out/test.log"; exit 3; }
rm -f tests/failed_uuids.txt
t0=$(date +%s)
./mfc.sh test --no-build -j "$JOBS" -g $gpus $TEST_ARGS -- -b mpirun > "$out/test.log" 2>&1
rc=$?
t1=$(date +%s)
cp -f tests/failed_uuids.txt "$out/" 2>/dev/null || : > "$out/failed_uuids.txt"
python3 - "$out" "$rc" "$((t1 - t0))" <<'PY'
import json, re, sys
out, rc, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
log = re.sub(r"\x1b\[[0-9;]*m", "", open(f"{out}/test.log", errors="replace").read())
def n(word):
    m = re.findall(rf"(\d+)\s+{word}", log)
    return int(m[-1]) if m else None
failed = [l.strip() for l in open(f"{out}/failed_uuids.txt") if l.strip()]
s = {"rc": rc, "seconds": secs, "passed": n("passed"), "failed": n("failed"), "skipped": n("skipped"),
     "failed_uuids": failed}
s["status"] = "COMPLETE" if s["passed"] is not None else "INCOMPLETE"
json.dump(s, open(f"{out}/test_summary.json", "w"), indent=1)
print(json.dumps(s))
PY
