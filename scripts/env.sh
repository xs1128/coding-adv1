# source scripts/env.sh — NVHPC 26.3 toolchain + MPI settings for nano4
if ! command -v module >/dev/null 2>&1; then
  source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/lmod/lmod/init/bash
fi
module purge >/dev/null 2>&1
module load x86-nvhpc/26.3 cmake/4.0.0
export CC=nvc CXX=nvc++ FC=nvfortran
if [[ -n ${CUDA_MODULE:-} ]]; then          # e.g. cuda/12.6 instead of the bundled CUDA 13.1
  module load "$CUDA_MODULE"
  export NVHPC_CUDA_HOME=$CUDA_HOME
fi
export MFC_CUDA_CC=90                       # H200 = sm_90
export ROOT=/work/u1131128/coding-adv1      # repo mirror on nano4
export MFC_DIR=${MFC_DIR:-$ROOT/mfc}        # MFC checkout: mfc = pinned v5.7.0, mfc-opt = our branch
export OPAL_PREFIX=$NVHPC_ROOT/comm_libs/13.1/hpcx/hpcx-2.25.1/ompi
export OMPI_MCA_hwloc_base_binding_policy=${OMPI_MCA_hwloc_base_binding_policy:-none}  # default binding fails in cgroups
export OMPI_MCA_io=${OMPI_MCA_io:-romio321}  # OMPIO hangs/segfaults on wekafs
