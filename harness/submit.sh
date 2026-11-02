#!/usr/bin/env bash
# harness/submit.sh LABEL CASE NGPU MINUTES [VAR=value ...]   (SCRIPT=run|profile|mfctest|osu, AFTER=<jobid>, NODE=<host>,
#   EXCLUDE=<host,...>)
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
label=${1:?LABEL}; case=${2:?CASE}; ngpu=${3:?NGPU}; mins=${4:?MINUTES}; shift 4
exports="ALL,LABEL=$label,CASE=$case,NGPU=$ngpu"
# Only mfctest takes "-" (no case file); every other script copies $CASE on the GPU node. Fail here instead
# (667720, 667909 held GPUs for minutes to die on that cp).
[[ ( $case == - && " $* " == *" SCRIPT=mfctest "* ) || -f $ROOT/$case ]] || { echo "submit.sh: no case file $ROOT/$case" >&2; exit 2; }
# /work/u1131128 is a 700 GB quota shared with other projects; a full disk killed 682858 mid restart-write with an
# empty log. Each perf3d arm writes ~0.5 GB, so refuse below 10 GB free.
free_gb=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc 0-9)
(( free_gb >= 10 )) || { echo "submit.sh: only ${free_gb} GB free on $ROOT; clean runs/ first" >&2; exit 2; }
script=run; dep=()
for kv in "$@"; do
  case "$kv" in
    SCRIPT=*) script=${kv#SCRIPT=} ;;
    AFTER=*) dep=(--dependency=afterany:${kv#AFTER=}); continue ;;
    NODE=*) dep+=(--nodelist=${kv#NODE=}); continue ;;
    EXCLUDE=*) dep+=(--exclude=${kv#EXCLUDE=}); continue ;;
  esac
  exports="$exports,$kv"
done
mkdir -p "$ROOT/results/$label" "$ROOT/logs"
jid=$(sbatch --parsable -J "mfc-${label//\//-}" --gres=gpu:H200:"$ngpu" --ntasks="$ngpu" \
        --cpus-per-task=8 -t "$mins" "${dep[@]}" --export="$exports" \
        -o "$ROOT/results/$label/slurm-%j.out" "$ROOT/harness/$script.sbatch")
[[ -f $ROOT/results/jobs.tsv ]] || printf 'jobid\tsubmitted\tlabel\tngpu\tminutes\tvars\n' > "$ROOT/results/jobs.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$jid" "$(date -Iseconds)" "$label" "$ngpu" "$mins" "$*" >> "$ROOT/results/jobs.tsv"
echo "$jid"
