#!/usr/bin/env bash
# Same-node A/B[/C...]: harness/submit.sh <label> CASE NGPU MIN SCRIPT=ab MFC_A=<dir> MFC_B=<dir> [MFC_C..MFC_F=<dir>]
#   [ROUNDS=2] [ENV_A..ENV_F=<VAR=value> per-arm environment; + stands for a comma, @ separates variables] [run.sbatch vars]
# Runs run.sbatch for each arm in turn (A B ... A B ...) inside one allocation, so node, GPUs and clocks are shared.
# Out: results/<label>/{a1,b1,...,a2,b2,...}/ (each a full run.sbatch result directory)
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -uo pipefail
ROOT=/work/u1131128/coding-adv1
: "${LABEL:?}" "${MFC_A:?}" "${MFC_B:?}" "${ROUNDS:=2}"
base=$LABEL
# A power-braked GPU runs every kernel ~5x slower (AGENT_LOG #16): refuse the node instead of timing it
if nvidia-smi --query-gpu=clocks_event_reasons.hw_power_brake_slowdown --format=csv,noheader | grep -q '^Active'; then
  echo "power brake active on $(hostname); not timing" >&2; mkdir -p "$ROOT/results/$base"
  echo "$(hostname)" >> "$ROOT/results/$base/braked_nodes.txt"; exit 3
fi
for r in $(seq 1 "$ROUNDS"); do
  for v in a b c d e f; do
    dir=MFC_$(tr a-z A-Z <<<"$v")
    [[ -n ${!dir:-} ]] || continue
    # optional per-arm environment, appended to RUN_ENV. sbatch --export splits at commas, so write '+' for ','
    # (ENV_B="UCX_TLS=self+sm+cuda_copy+cuda_ipc"): a comma-separated value arrives cut at its first comma.
    envv=ENV_$(tr a-z A-Z <<<"$v"); armenv=${!envv:-}; armenv=${armenv//+/,}; armenv=${armenv//@/ }
    rlv=RUNLOCAL_$(tr a-z A-Z <<<"$v"); armrl=${!rlv:-${RUNLOCAL:-0}}   # per-arm RUNLOCAL_A..F (run.sbatch)
    lav=LAUNCH_$(tr a-z A-Z <<<"$v"); armla=${!lav:-${LAUNCH:-mpirun}}   # per-arm LAUNCH_A..F (run.sbatch)
    LABEL=$base/$v$r MFC_DIR=${!dir} RUN_ENV="${RUN_ENV:-} $armenv" RUNLOCAL=$armrl LAUNCH=$armla bash "$ROOT/harness/run.sbatch" \
      || echo "$v$r failed" >&2
  done
done
