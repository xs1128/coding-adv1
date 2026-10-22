#!/usr/bin/env bash
# Standard benchmark set: harness/run_all.sh TAG [GPUS="1 2 4"] [VAR=value ...]
# -> TAG/strong_<g>g (201^3) and TAG/weak_<g>g (8.12M cells/GPU); then verify.py + collect.py.
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
tag=${1:?TAG}; shift
gpus="1 2 4"
vars=()
for kv in "$@"; do
  case "$kv" in GPUS=*) gpus=${kv#GPUS=} ;; *) vars+=("$kv") ;; esac
done
extra=""
for kv in "${vars[@]}"; do [[ $kv == CASE_ARGS=* ]] && extra=${kv#CASE_ARGS=}; done
rest=(); for kv in "${vars[@]}"; do [[ $kv == CASE_ARGS=* ]] || rest+=("$kv"); done
C=harness/cases/perf3d.py
cd "$ROOT"
for g in $gpus; do
  bash harness/submit.sh "$tag/strong_${g}g" $C "$g" 15 BUILD=caseopt REPS=3 "CASE_ARGS=$extra" "${rest[@]}"
  if (( g > 1 )); then
    bash harness/submit.sh "$tag/weak_${g}g" $C "$g" 15 BUILD=caseopt REPS=3 "CASE_ARGS=--cells 8120601 $extra" "${rest[@]}"
  fi
done
