#!/usr/bin/env bash
# MPI start-up cost under transport settings: harness/submit.sh t0/<label> - NGPU MIN SCRIPT=mpiinit
# Out: results/<LABEL>/mpiinit.tsv (variant, rep, process wall, MPI_Init, ring Sendrecv GB/s per rank, MPI_Finalize)
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -uo pipefail
ROOT=/work/u1131128/coding-adv1
source "$ROOT/scripts/env.sh"
: "${LABEL:?}" "${NGPU:=1}"
out=$ROOT/results/$LABEL; mkdir -p "$out"
bin=$ROOT/build-tools/mpiinit
declare -A V=(
  [default]=""
  [nocoll]="OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0"
  [ucx_shm]="UCX_TLS=self,sm,cuda_copy,cuda_ipc"
  [ucx_shm_noproc]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n"
  [ucx_1hca]="UCX_NET_DEVICES=mlx5_0:1"
  [ob1]="OMPI_MCA_pml=ob1 OMPI_MCA_btl=self,vader OMPI_MCA_osc=^ucx OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0"
)
{ echo "job=$SLURM_JOB_ID host=$(hostname) ngpu=$NGPU"; ibv_devices 2>&1 | head -20; } > "$out/env.txt"
printf 'variant\trep\twall_s\tinit_s\tsendrecv_GBs\tfinalize_s\n' > "$out/mpiinit.tsv"
for rep in 1 2 3; do
  for v in ${VARIANTS:-default nocoll ucx_shm ucx_1hca ob1}; do
    t0=$(date +%s.%N)
    r=$(env ${V[$v]} mpirun -np "$NGPU" "$bin" 2> "$out/$v.$rep.err" | head -1)
    t1=$(date +%s.%N)
    printf '%s\t%s\t%.3f\t%s\t%s\t%s\n' "$v" "$rep" "$(echo "$t1 - $t0" | bc)" \
      "$(awk '{print $2}' <<<"$r")" "$(awk '{print $4}' <<<"$r")" "$(awk '{print $6}' <<<"$r")" >> "$out/mpiinit.tsv"
  done
done
