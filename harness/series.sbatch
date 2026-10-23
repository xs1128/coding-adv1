#!/usr/bin/env bash
# Several runs on one node in one allocation: harness/submit.sh <label> CASE NGPU MIN SCRIPT=series SPEC=harness/specs/<f>.tsv
# SPEC rows (tab-separated): name  mfc_dir (relative to ROOT)  case_args  extra VAR=value ...  ('-' for empty).
# Each row is a full run.sbatch run with the job's REPS/BUILD; out: results/<label>/<name>/
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -uo pipefail
ROOT=/work/u1131128/coding-adv1
: "${LABEL:?}" "${SPEC:?}" "${ONLY:=}"   # ONLY="name1 name2": run just these rows
base=$LABEL
while IFS=$'\t' read -r name dir cargs extra; do
  [[ -z $name || $name == \#* ]] && continue
  [[ -n $ONLY && " $ONLY " != *" $name "* ]] && continue
  [[ $cargs == - ]] && cargs=
  [[ $extra == - ]] && extra=
  # stdin from /dev/null: mpirun/mfc.sh would otherwise read the remaining SPEC rows
  env LABEL="$base/$name" MFC_DIR="$ROOT/$dir" CASE_ARGS="$cargs" $extra bash "$ROOT/harness/run.sbatch" < /dev/null ||
    echo "$name failed" >&2
done < "$ROOT/$SPEC"
