#!/usr/bin/env bash
# Submit harness/run.sbatch on nano4 with minimal resources and log it in results/jobs.tsv.
#   harness/submit.sh LABEL CASE NGPU MINUTES [VAR=value ...]
# e.g. harness/submit.sh base/perf3d_1g harness/cases/perf3d.py 1 15 BUILD=generic REPS=3
# Runs on nano4 (call via hpc). Resources: NGPU GPUs, 8 cores per GPU, one node, partition dev.
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
label=${1:?LABEL}; case=${2:?CASE}; ngpu=${3:?NGPU}; mins=${4:?MINUTES}; shift 4
exports="ALL,LABEL=$label,CASE=$case,NGPU=$ngpu"
for kv in "$@"; do exports="$exports,$kv"; done
mkdir -p "$ROOT/results/$label" "$ROOT/logs"
jid=$(sbatch --parsable -J "mfc-${label//\//-}" --gres=gpu:H200:"$ngpu" --ntasks="$ngpu" \
        --cpus-per-task=8 -t "$mins" --export="$exports" \
        -o "$ROOT/results/$label/slurm-%j.out" "$ROOT/harness/run.sbatch")
[[ -f $ROOT/results/jobs.tsv ]] || printf 'jobid\tsubmitted\tlabel\tngpu\tminutes\tvars\n' > "$ROOT/results/jobs.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$jid" "$(date -Iseconds)" "$label" "$ngpu" "$mins" "$*" >> "$ROOT/results/jobs.tsv"
echo "$jid"
