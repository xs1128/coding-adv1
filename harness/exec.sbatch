#!/usr/bin/env bash
# Run one short command on a GPU node: harness/submit.sh <label> - NGPU MIN SCRIPT=exec "CMD=..."  -> results/<label>/out.txt
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -uo pipefail
ROOT=/work/u1131128/coding-adv1
source "$ROOT/scripts/env.sh"
: "${LABEL:?}" "${CMD:?}"
out=$ROOT/results/$LABEL; mkdir -p "$out"
{ echo "job=$SLURM_JOB_ID host=$(hostname) cmd=$CMD"; nvidia-smi --query-gpu=index,name --format=csv,noheader; } > "$out/env.txt"
cd "$ROOT" && bash -c "$CMD" > "$out/out.txt" 2>&1
