#!/usr/bin/env bash
# Same-node A/B: harness/submit.sh <label> CASE NGPU MIN SCRIPT=ab MFC_A=<dir> MFC_B=<dir> [ROUNDS=2] [run.sbatch vars]
# Runs run.sbatch for A and B alternately (A B A B ...) inside one allocation, so node, GPUs and clocks are shared.
# Out: results/<label>/{a1,b1,a2,b2,...}/ (each a full run.sbatch result directory)
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -uo pipefail
ROOT=/work/u1131128/coding-adv1
: "${LABEL:?}" "${MFC_A:?}" "${MFC_B:?}" "${ROUNDS:=2}"
base=$LABEL
for r in $(seq 1 "$ROUNDS"); do
  for v in a b; do
    dir=MFC_$(tr a-z A-Z <<<"$v")
    LABEL=$base/$v$r MFC_DIR=${!dir} bash "$ROOT/harness/run.sbatch" || echo "$v$r failed" >&2
  done
done
