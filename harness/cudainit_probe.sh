#!/usr/bin/env bash
# Where UCX's 1.6 s 'cuda' module load goes (ladder row 93): time, in fresh processes, nvmlInit, cuInit and
# dlopen of UCX's libuct_cuda, one process alone and 4 at once (like 4 ranks). LD_LIBRARY_PATH unset (NOLIBPATH).
# Run on a GPU node through exec.sbatch:
#   harness/submit.sh t0/cudainit harness/cases/perf3d.py 4 4 SCRIPT=exec "CMD=bash harness/cudainit_probe.sh"
set -uo pipefail
ucx=$(dirname "$(readlink -f "$(command -v mpirun)")")/../../ucx/mt/lib/ucx/libuct_cuda.so.0
echo "uct_cuda=$(readlink -f "$ucx")"
nvidia-smi --query-gpu=index,persistence_mode,pstate --format=csv,noheader
t() {  # $1 = what: nvml | cuinit | uctcuda
  env -u LD_LIBRARY_PATH python3 -I - "$1" "$ucx" <<'EOF'
import ctypes, os, sys, time
w, ucx = sys.argv[1], sys.argv[2]
t0 = time.perf_counter()
if w == "nvml":
    r = ctypes.CDLL("libnvidia-ml.so.1").nvmlInit_v2()
elif w == "cuinit":
    r = ctypes.CDLL("libcuda.so.1").cuInit(0)
else:
    r = ctypes.CDLL(ucx, mode=os.RTLD_NOW | os.RTLD_GLOBAL) and 0
print(f"{w}\t{time.perf_counter() - t0:.3f}\tret={r}")
EOF
}
for rep in 1 2 3; do
  for w in nvml cuinit uctcuda; do
    echo "alone rep$rep $(t $w)"
    for i in 1 2 3 4; do t $w & done | sed "s/^/x4 rep$rep /"; wait
  done
  # each process sees only its own GPU (as with CUDA_VISIBLE_DEVICES per rank)
  echo "alone1gpu rep$rep $(CUDA_VISIBLE_DEVICES=0 t cuinit)"
  for i in 0 1 2 3; do CUDA_VISIBLE_DEVICES=$i t cuinit & done | sed "s/^/x4_1gpu rep$rep /"; wait
done
