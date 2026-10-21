# Source on nano4 (login or compute node): toolchain for MFC GPU builds/runs.
#   source scripts/env.sh
# NVHPC 26.3 = nvfortran + CUDA 13.1 + HPC-X 2.25.1 (Open MPI 4.1.9, CUDA-aware via UCX).
if ! command -v module >/dev/null 2>&1; then
  source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/lmod/lmod/init/bash
fi
module purge >/dev/null 2>&1
module load x86-nvhpc/26.3 cmake/4.0.0
export CC=nvc CXX=nvc++ FC=nvfortran
export MFC_CUDA_CC=90                       # H200 = sm_90
export ROOT=/work/u1131128/coding-adv1      # repo mirror on nano4
export MFC_DIR=$ROOT/mfc                    # MFC checkout (v5.7.0 + our branch)
