#!/usr/bin/env bash
# harness/submit_clean.sh LABEL CASE NGPU MINUTES SCRIPT=ab ...   (same arguments as submit.sh, ab jobs only)
# ab.sbatch refuses a power-braked node within seconds (AGENT_LOG #16); resubmit excluding every node it refused, up to
# 6 tries. Blocks until a job has produced results/LABEL/a1, so run it under nohup.
set -uo pipefail
ROOT=/work/u1131128/coding-adv1
cd "$ROOT"
label=$1; braked=results/$label/braked_nodes.txt
for t in 1 2 3 4 5 6; do
  ex=$( [[ -s $braked ]] && paste -sd, "$braked" )
  j=$(bash harness/submit.sh "$@" ${ex:+EXCLUDE=$ex})
  echo "try $t: job $j${ex:+ excluding $ex}"
  [[ -n $j ]] || { echo "submit failed (bad arguments?)"; exit 2; }
  while squeue -j "$j" -h 2>/dev/null | grep -q .; do sleep 20; done
  [[ -s results/$label/a1/summary.tsv ]] && { echo "ran: job $j"; exit 0; }
done
echo "gave up after 6 braked nodes" >&2; exit 1
