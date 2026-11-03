#!/usr/bin/env bash
# Rebuild the final MFC from the pinned release plus our patches, then re-run the final same-node sets.
#   harness/reproduce.sh build    (login node: clone/patch/compile, ~1 h at -j 8, no GPU)
#   harness/reproduce.sh run      (submit the 1/4/8-GPU sets: ~1, ~16 and ~48 GPU-min)
#   harness/reproduce.sh wall     (submit the 1/4-GPU wall-time sets with the disclosed run settings: ~6 and ~15 GPU-min)
#   harness/reproduce.sh verify   (bitwise gate + summary of every run)
# Baseline = pinned v5.7.0 in $ROOT/mfc; final = $ROOT/mfc-repro (v5.7.0 + every patch in patches/opt/, P22).
# The wall-time settings (ladder rows 85-99) were measured on pending patch 0038, so P22 with them is a little slower.
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
PIN=0b3d56c8e1c9a3aa8d112681b72c87ab69fe5f13
cd "$ROOT"
case "${1:?build|run|verify}" in
  build)
    [[ -d mfc/.git || -f mfc/.git ]] || git clone https://github.com/MFlowCode/MFC mfc
    git -C mfc checkout -q "$PIN"
    [[ -d mfc-repro ]] || git -C mfc worktree add --detach ../mfc-repro "$PIN"
    git -C mfc-repro -c user.name=repro -c user.email=repro@localhost am --keep-cr "$ROOT"/patches/opt/*.patch
    for d in mfc mfc-repro; do
      MFC_DIR=$ROOT/$d bash scripts/build.sh caseopt harness/cases/perf3d.py
      MFC_DIR=$ROOT/$d bash scripts/build.sh generic
    done ;;
  run)
    for g in 1 4 8; do
      sed 's/\tmfc-p3\t/\tmfc-repro\t/' "harness/specs/final_${g}g.tsv" > "harness/specs/repro_${g}g.tsv"
      bash harness/submit.sh "repro/s${g}g" harness/cases/perf3d.py "$g" 15 SCRIPT=series \
        "SPEC=harness/specs/repro_${g}g.tsv" BUILD=caseopt REPS=5
    done ;;
  wall)
    for g in 1 4; do   # time limit 10 / 8 min (expected ~6 / ~15 GPU-min)
      bash harness/submit.sh "repro/w${g}g" harness/cases/perf3d.py "$g" $(( g == 1 ? 10 : 8 )) SCRIPT=series \
        "SPEC=harness/specs/wall_${g}g.tsv" BUILD=caseopt REPS=5
    done ;;
  verify)
    for d in results/repro/[sw]*g/*/; do
      l=${d#results/}; l=${l%/}
      printf '%-28s %s  step %s ms\n' "$l" "$(python3 harness/verify.py "$l" | grep -o '"status": "[A-Z]*"' | tail -1)" \
        "$(awk '$1 == "all" {print $4}' "$d/steps.tsv")"
    done ;;
esac
