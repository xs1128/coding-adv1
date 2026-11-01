#!/usr/bin/env bash
# harness/submit.sh LABEL CASE NGPU MINUTES [VAR=value ...]   (SCRIPT=run|profile|mfctest|osu, AFTER=<jobid>, NODE=<host>,
#   EXCLUDE=<host,...>)
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
label=${1:?LABEL}; case=${2:?CASE}; ngpu=${3:?NGPU}; mins=${4:?MINUTES}; shift 4
exports="ALL,LABEL=$label,CASE=$case,NGPU=$ngpu"
# Only ab/mfctest take "-" (no case file); fail here rather than on a GPU node (667720 held a GPU 7.5 min to die on cp)
[[ $case == - || -f $ROOT/$case ]] || { echo "submit.sh: no case file $ROOT/$case" >&2; exit 2; }
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
