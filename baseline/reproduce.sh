#!/usr/bin/env bash
# Reproduce the 1-GPU baseline and the official-version comparison on nano4 (from $ROOT, after tools/sync.sh push).
#   baseline/reproduce.sh checkout   # pinned v5.7.0 in mfc/, official-table version v4.9.3 in mfc-v4.9.3/
#   baseline/reproduce.sh build      # login node, -j 8, ~15 min each
#   baseline/reproduce.sh submit     # 3 jobs x 1 H200 x ~2 min
#   baseline/reproduce.sh report     # verify + table (login node, no GPU)
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
cd "$ROOT"
V5=0b3d56c8e1c9a3aa8d112681b72c87ab69fe5f13
case "${1:?checkout|build|submit|report}" in
  checkout)
    [[ -d mfc ]] || git clone https://github.com/MFlowCode/MFC mfc
    git -C mfc checkout --detach $V5
    git -C mfc fetch --depth 1 origin tag v4.9.3
    [[ -d mfc-v4.9.3 ]] || git -C mfc worktree add --detach ../mfc-v4.9.3 v4.9.3
    git -C mfc-v4.9.3 apply ../patches/v4.9.3-cuda13-nvtx.patch        # CUDA >= 12.9 has no libnvToolsExt
    git -C mfc-v4.9.3 apply ../patches/v4.9.3-double-file-close.patch  # 2nd MPI_FILE_CLOSE segfaults on OMPI 4.1.9
    ;;
  build)
    bash scripts/build.sh caseopt harness/cases/perf3d.py
    (cd mfc-v4.9.3 && source ../scripts/env.sh && export CMAKE_POLICY_VERSION_MINIMUM=3.5 &&
       ./mfc.sh build --gpu --mpi -t pre_process simulation -j 8 \
         -i examples/3D_performance_test/case.py --case-optimization)
    ;;
  submit)
    a=$(bash harness/submit.sh base/official_1g harness/cases/perf3d.py 1 10 BUILD=caseopt REPS=5)
    b=$(bash harness/submit.sh base/v493_official_1g mfc-v4.9.3/examples/3D_performance_test/case.py 1 10 \
          BUILD=caseopt REPS=5 MFC_DIR=$ROOT/mfc-v4.9.3 AFTER=$a)
    bash harness/submit.sh base/v493_samecfg_1g harness/cases/official_v493.py 1 10 \
          BUILD=caseopt REPS=5 MFC_DIR=$ROOT/mfc-v4.9.3 AFTER=$b
    ;;
  report)
    py=mfc/build/venv/bin/python3
    for l in base/official_1g base/v493_official_1g base/v493_samecfg_1g; do
      $py harness/verify.py "$l" > /dev/null || true
    done
    $py harness/collect.py | grep -E "^label|^base/(official|v493)"
    ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
