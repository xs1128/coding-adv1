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
mapfile -t uuids < <(cd "$MFC_DIR" && ./mfc.sh test -l 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '[0-9A-F]{8}')
n=${#uuids[@]}; per=$(( (n + shards - 1) / shards )); prev=""
cd "$ROOT"
for ((i = 0; i < shards; i++)); do
  lo=$((i * per)); hi=$(( (i + 1) * per - 1 )); (( hi >= n )) && hi=$((n - 1))
  dep=(); [[ -n $prev ]] && dep=(AFTER=$prev)
  prev=$(bash harness/submit.sh "test/${tag}_s$i" - "$ngpu" "$mins" SCRIPT=mfctest \
         "TEST_ARGS=--from ${uuids[lo]} --to ${uuids[hi]}" "${dep[@]}" "${vars[@]}")
  echo "shard $i: ${uuids[lo]}..${uuids[hi]} ($((hi - lo + 1)) tests) job $prev"
done
