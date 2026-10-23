# source scripts/env.sh — NVHPC toolchain (default 26.3; NVHPC_MODULE=x86-nvhpc/25.9) + MPI settings for nano4
if ! command -v module >/dev/null 2>&1; then
  source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/lmod/lmod/init/bash
fi
module purge >/dev/null 2>&1
module load ${NVHPC_MODULE:=x86-nvhpc/26.3} cmake/4.0.0
export CC=nvc CXX=nvc++ FC=nvfortran
if [[ -n ${CUDA_MODULE:-} ]]; then          # e.g. cuda/12.6 instead of the bundled CUDA 13.1
  module load "$CUDA_MODULE"
  export NVHPC_CUDA_HOME=$CUDA_HOME
fi
export MFC_CUDA_CC=90                       # H200 = sm_90
export ROOT=/work/u1131128/coding-adv1      # repo mirror on nano4
export MFC_DIR=${MFC_DIR:-$ROOT/mfc}        # MFC checkout: mfc = pinned v5.7.0, mfc-opt = our branch
OPAL_PREFIX=$(ls -d "$NVHPC_ROOT"/comm_libs/*/hpcx/hpcx-*/ompi | head -1); export OPAL_PREFIX
export OMPI_MCA_hwloc_base_binding_policy=${OMPI_MCA_hwloc_base_binding_policy:-none}  # default binding fails in cgroups
export OMPI_MCA_io=${OMPI_MCA_io:-romio321}  # OMPIO hangs/segfaults on wekafs
# HCA next to each visible GPU, for harness/nicbind.sh (compute nodes only; empty on login nodes)
if [[ -n ${SLURM_JOB_ID:-} ]] && command -v nvidia-smi >/dev/null; then
  NIC_MAP=$("$ROOT/harness/nicbind.sh" --map 2>/dev/null); export NIC_MAP
fi
