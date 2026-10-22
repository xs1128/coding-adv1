#!/usr/bin/env bash
# GPU<->GPU MPI micro-benchmark (OSU, device buffers) under two MPI environments:
#   A = current env (NVHPC module; Open MPI's pml_ucx resolves the *system* /lib64 UCX)
#   B = HPC-X's own init (hpcx_load: bundled UCX 1.20 with the cuda/cuda_ipc/gdrcopy transports, hcoll, ucc)
# Submit: harness/submit.sh net/osu_2g - 2 6 SCRIPT=osu      (CASE is unused)
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -uo pipefail
ROOT=/work/u1131128/coding-adv1
source "$ROOT/scripts/env.sh"
export OMPI_MCA_hwloc_base_binding_policy=none
out=$ROOT/results/$LABEL; mkdir -p "$out"
H=$NVHPC_ROOT/comm_libs/13.1/hpcx/hpcx-2.25.1
OSU=$H/ompi/tests/osu-micro-benchmarks-cuda
{ echo "job=$SLURM_JOB_ID host=$(hostname) date=$(date -Iseconds)"; cat "$ROOT/.provenance"; nvidia-smi topo -m; } > "$out/env.txt" 2>&1

run_set() {  # $1 = tag
  local tag=$1
  { echo "## $tag"; echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"; ldd "$OPAL_PREFIX/lib/openmpi/mca_pml_ucx.so" | grep -E "ucp|uct|ucs"; } > "$out/$tag.libs.txt"
  # one verbose tiny run to record which pml/transports were selected
  UCX_LOG_LEVEL=info UCX_PROTO_INFO=y OMPI_MCA_pml_ucx_verbose=10 \
    timeout 120 mpirun -np 2 "$OSU/osu_latency" -d cuda -m 1048576:1048576 -i 10 -x 2 D D > "$out/$tag.verbose.txt" 2>&1
  timeout 200 mpirun -np 2 "$OSU/osu_latency" -d cuda -m 8:4194304 D D > "$out/$tag.latency.txt" 2>&1
  timeout 200 mpirun -np 2 "$OSU/osu_bw" -d cuda -m 4096:4194304 D D > "$out/$tag.bw.txt" 2>&1
  timeout 200 mpirun -np 2 "$OSU/osu_latency" -m 8:4194304 H H > "$out/$tag.latency_host.txt" 2>&1
  /usr/bin/time -f "mpi_init_hello_s=%e" timeout 120 mpirun -np 2 "$OSU/../osu-micro-benchmarks/osu_init" > "$out/$tag.init.txt" 2>&1
}
run_set A_system_ucx
# B: HPC-X's own environment on top (prepends bundled UCX/hcoll/ucc/ompi libs)
source "$H/hpcx-init.sh"; hpcx_load
run_set B_hpcx_ucx
ls -la "$out"
