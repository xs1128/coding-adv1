#!/usr/bin/env bash
# Build MFC on nano4 (login node; compile only, never run there).
#   scripts/build.sh generic            # GPU (OpenACC) build, no case optimization
#   scripts/build.sh caseopt <case.py>  # --case-optimization build for one case
# Extra mfc.sh build flags may follow, e.g. --fastmath.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/env.sh"
cd "$MFC_DIR"
mode=${1:?generic|caseopt}; shift
jobs=${BUILD_JOBS:-8}   # login node is shared; keep -j modest
case "$mode" in
  generic) ./mfc.sh build --gpu acc --mpi -t pre_process simulation -j "$jobs" "$@" ;;
  caseopt) casefile=${1:?case.py}; shift
           ./mfc.sh build --gpu acc --mpi -t pre_process simulation -j "$jobs" \
                 -i "$casefile" --case-optimization "$@" ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
