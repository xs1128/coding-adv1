#!/usr/bin/env bash
# Full ./mfc.sh test as chained shards: harness/run_suite.sh TAG [NGPU=2] [SHARDS=4] [MIN=25] [VAR=value ...]
# -> results/test/TAG_s<i>/test_summary.json; gate with verify.py --test-summary results/test/TAG_s*/test_summary.json
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
tag=${1:?TAG}; shift
ngpu=2; shards=4; mins=25; vars=()
for kv in "$@"; do
  case "$kv" in NGPU=*) ngpu=${kv#NGPU=} ;; SHARDS=*) shards=${kv#SHARDS=} ;; MIN=*) mins=${kv#MIN=} ;; *) vars+=("$kv") ;; esac
done
source "$ROOT/scripts/env.sh"
# Preflight (p12_full lost ~78 GPU-min to a CPU-only pre-build and to a binary rebuilt mid-suite, AGENT_LOG):
# the tests run the GPU build, so the worktree's build lock must say gpu: acc and every configured GPU build must
# have installed binaries. Never build in $MFC_DIR while the shards run.
grep -q "gpu: acc" "$MFC_DIR/build/lock.yaml" || { echo "run_suite: $MFC_DIR/build/lock.yaml is not gpu: acc" >&2; exit 2; }
for st in "$MFC_DIR"/build/staging/gpu-acc-*; do
  inst=$MFC_DIR/build/install/$(basename "$st")
  ls "$inst"/bin/* > /dev/null 2>&1 || { echo "run_suite: $(basename "$st") configured but not installed (run ./mfc.sh test --dry-run -j 8 --gpu acc)" >&2; exit 2; }
done
# nano4's QOS takes at most 7 queued jobs per user (QOSMaxSubmitJobPerUserLimit): with SHARDS=8 the last shard is
# refused and must be submitted (AFTER= the previous shard) once a shard has finished (bcskip_full, 2026-11-03).
# Each shard gets its UUIDs explicitly (--only): a --from/--to range follows the runner's order at run time, which lost
# 59 tests of the P18 suite (shard 6 ran 14 of 94; made up by job 671033).
# The 39 "Convergence" tests are left out: a plain `./mfc.sh test` skips them, and each one calls `./mfc.sh run`, which
# builds new configurations on the GPU node and failed there in CMake (P20 shard 7, 672470, timed out on them).
mapfile -t uuids < <(cd "$MFC_DIR" && ./mfc.sh test -l 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -v 'Convergence' \
                       | grep -oE '[0-9A-F]{8}')
n=${#uuids[@]}; per=$(( (n + shards - 1) / shards )); prev=""
cd "$ROOT"
for ((i = 0; i < shards; i++)); do
  lo=$((i * per)); hi=$(( (i + 1) * per - 1 )); (( hi >= n )) && hi=$((n - 1))
  dep=(); [[ -n $prev ]] && dep=(AFTER=$prev)
  prev=$(bash harness/submit.sh "test/${tag}_s$i" - "$ngpu" "$mins" SCRIPT=mfctest \
         "TEST_ARGS=--only ${uuids[*]:lo:hi-lo+1}" "${dep[@]}" "${vars[@]}")
  echo "shard $i: ${uuids[lo]}..${uuids[hi]} ($((hi - lo + 1)) tests) job $prev"
done
