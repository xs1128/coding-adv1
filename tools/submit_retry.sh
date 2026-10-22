#!/usr/bin/env bash
# tools/submit_retry.sh <harness/submit.sh args...>   (nano4, from $ROOT; returns at once, retries in the background)
# For when slurmctld times out: waits until squeue answers, skips if a job with this label is already queued or logged
# (a timed-out sbatch can still have been accepted), then submits once. Log: logs/submit_<label>.log
set -euo pipefail
cd "$(dirname "$0")/.."
label=${1:?label}; name="mfc-${label//\//-}"; log="logs/submit_${label//\//-}.log"
mkdir -p logs
(setsid nohup bash -c '
  for i in $(seq 1 ${RETRIES:-120}); do
    if q=$(timeout 60 squeue -u "$USER" -h -o "%j" 2>/dev/null); then
      if grep -qx "$1" <<<"$q" || grep -qP "\t$2\t" results/jobs.tsv; then echo "already queued/logged"; exit 0; fi
      timeout 120 bash harness/submit.sh "${@:3}" && exit 0
    fi
    sleep 60
  done; echo "gave up"' _ "$name" "$label" "$@" > "$log" 2>&1 < /dev/null &)
echo "retrying in background, log: $log"
