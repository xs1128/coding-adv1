#!/usr/bin/env bash
# OSU GPU<->GPU MPI benchmark, system UCX (A) vs HPC-X UCX (B): harness/submit.sh net/osu_2g - 2 6 SCRIPT=osu
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -uo pipefail
ROOT=/work/u1131128/coding-adv1
source "$ROOT/scripts/env.sh"
out=$ROOT/results/$LABEL; mkdir -p "$out"
H=$NVHPC_ROOT/comm_libs/13.1/hpcx/hpcx-2.25.1
OSU=$H/ompi/tests/osu-micro-benchmarks-cuda
{ echo "job=$SLURM_JOB_ID host=$(hostname) date=$(date -Iseconds)"; cat "$ROOT/.provenance"; nvidia-smi topo -m; } > "$out/env.txt" 2>&1

run_set() {  # $1 = tag
  local tag=$1
  { echo "## $tag"; echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"; ldd "$OPAL_PREFIX/lib/openmpi/mca_pml_ucx.so" | grep -E "ucp|uct|ucs"; } > "$out/$tag.libs.txt"
  UCX_LOG_LEVEL=info UCX_PROTO_INFO=y OMPI_MCA_pml_ucx_verbose=10 \
    timeout 120 mpirun -np 2 "$OSU/osu_latency" -d cuda -m 1048576:1048576 -i 10 -x 2 D D > "$out/$tag.verbose.txt" 2>&1
  timeout 200 mpirun -np 2 "$OSU/osu_latency" -d cuda -m 8:4194304 D D > "$out/$tag.latency.txt" 2>&1
  timeout 200 mpirun -np 2 "$OSU/osu_bw" -d cuda -m 4096:4194304 D D > "$out/$tag.bw.txt" 2>&1
  timeout 200 mpirun -np 2 "$OSU/osu_latency" -m 8:4194304 H H > "$out/$tag.latency_host.txt" 2>&1
  /usr/bin/time -f "mpi_init_hello_s=%e" timeout 120 mpirun -np 2 "$OSU/../osu-micro-benchmarks/osu_init" > "$out/$tag.init.txt" 2>&1
}
run_set A_system_ucx
set +u; source "$H/hpcx-init.sh"; hpcx_load; set -u
run_set B_hpcx_ucx
ls -la "$out"
