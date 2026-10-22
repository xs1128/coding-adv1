#!/usr/bin/env bash
# scripts/build.sh generic | caseopt <case.py> [mfc.sh build flags]   (login node, compile only)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/env.sh"
mode=${1:?generic|caseopt}; shift
[[ $mode == caseopt ]] && set -- "$(realpath "${1:?case.py}")" "${@:2}"
cd "$MFC_DIR"
jobs=${BUILD_JOBS:-8}
case "$mode" in
  generic) ./mfc.sh build --gpu acc --mpi -t pre_process simulation -j "$jobs" "$@" ;;
  caseopt) casefile=${1:?case.py}; shift
           ./mfc.sh build --gpu acc --mpi -t pre_process simulation -j "$jobs" \
                 -i "$casefile" --case-optimization "$@" ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
