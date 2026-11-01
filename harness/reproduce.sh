#!/usr/bin/env bash
# Rebuild the final MFC from the pinned release plus our patches, then re-run the final same-node sets.
#   harness/reproduce.sh build    (login node: clone/patch/compile, ~1 h at -j 8, no GPU)
#   harness/reproduce.sh run      (submit the 1/4/8-GPU sets: ~1, ~16 and ~48 GPU-min)
#   harness/reproduce.sh verify   (bitwise gate + summary of every run)
# Baseline = pinned v5.7.0 in $ROOT/mfc; final = $ROOT/mfc-repro (v5.7.0 + patches/opt/00[01][0-9]).
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
PIN=0b3d56c8e1c9a3aa8d112681b72c87ab69fe5f13
cd "$ROOT"
case "${1:?build|run|verify}" in
  build)
    [[ -d mfc/.git || -f mfc/.git ]] || git clone https://github.com/MFlowCode/MFC mfc
    git -C mfc checkout -q "$PIN"
    [[ -d mfc-repro ]] || git -C mfc worktree add --detach ../mfc-repro "$PIN"
    git -C mfc-repro -c user.name=repro -c user.email=repro@localhost am --keep-cr "$ROOT"/patches/opt/00[01][0-9]-*.patch
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
  verify)
    for d in results/repro/s*g/*/; do
      l=${d#results/}; l=${l%/}
      printf '%-28s %s  step %s ms\n' "$l" "$(python3 harness/verify.py "$l" | grep -o '"status": "[A-Z]*"' | tail -1)" \
        "$(awk '$1 == "all" {print $4}' "$d/steps.tsv")"
    done ;;
esac
