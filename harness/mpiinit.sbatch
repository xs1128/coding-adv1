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
  [noproc]="UCX_POSIX_USE_PROC_LINK=n"
  [nic_local]=""
  [nic_local_noproc]="UCX_POSIX_USE_PROC_LINK=n"
  [ob1]="OMPI_MCA_pml=ob1 OMPI_MCA_btl=self,vader OMPI_MCA_osc=^ucx OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0"
  # 4-GPU settings adopted 2026-11-04 (ladder rows 86-89), then one change each
  [g4]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0"
  [g4_pmlucx]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi"
  [g4_btlself]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self"
  [g4_noosc]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self OMPI_MCA_osc=^ucx"
  [g4_noib]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self OMPI_MCA_osc=^ucx UCX_MODULES=^ib,rdmacm"
  [g4_novfs]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self OMPI_MCA_osc=^ucx UCX_VFS_ENABLE=n"
  [g4_noibvfs]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self OMPI_MCA_osc=^ucx UCX_MODULES=^ib,rdmacm UCX_VFS_ENABLE=n"
  [g5_posix]="UCX_TLS=self,posix,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self OMPI_MCA_osc=^ucx UCX_MODULES=^ib,rdmacm"
  [g5_posixmods]="UCX_TLS=self,posix,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self OMPI_MCA_osc=^ucx UCX_MODULES=^ib,rdmacm,gdrcopy,xpmem,knem,cma"
  [g5_nocuda]="UCX_TLS=self,sm UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self OMPI_MCA_osc=^ucx UCX_MODULES=^ib,rdmacm"
  [g6]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_osc=^ucx UCX_MODULES=^ib,rdmacm"
  [g6_dbg]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_osc=^ucx UCX_MODULES=^ib,rdmacm UCX_LOG_LEVEL=debug"
  [h_memev]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self OMPI_MCA_osc=^ucx UCX_MODULES=^ib,rdmacm UCX_MEM_EVENTS=n"
  [h_hooks]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self OMPI_MCA_osc=^ucx UCX_MODULES=^ib,rdmacm UCX_MEM_MALLOC_HOOKS=n UCX_MEM_MMAP_HOOK_MODE=none"
  [h_proto]="UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0 OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi OMPI_MCA_btl=self OMPI_MCA_osc=^ucx UCX_MODULES=^ib,rdmacm UCX_PROTO_ENABLE=n"
)
# NOLIBPATH=1 (as in run.sbatch): start with LD_LIBRARY_PATH unset
libu=(); [[ ${NOLIBPATH:-0} == 1 ]] && libu=(-u LD_LIBRARY_PATH)
{ echo "job=$SLURM_JOB_ID host=$(hostname) ngpu=$NGPU nic_map=${NIC_MAP:-} nolibpath=${NOLIBPATH:-0}"; ibv_devices 2>&1 | head -20; } > "$out/env.txt"
printf 'variant\trep\twall_s\tinit_s\tsendrecv_GBs\tfinalize_s\n' > "$out/mpiinit.tsv"
for rep in $(seq 1 ${REPS:-3}); do
  for v in ${VARIANTS:-default nocoll ucx_shm ucx_1hca ob1}; do
    t0=$(date +%s.%N)
    wrap=; [[ $v == nic_local* ]] && wrap=$ROOT/harness/nicbind.sh
    r=$(env "${libu[@]}" ${V[$v]} mpirun -np "$NGPU" $wrap "$bin" 2> "$out/$v.$rep.err" | head -1)
    t1=$(date +%s.%N)
    printf '%s\t%s\t%.3f\t%s\t%s\t%s\n' "$v" "$rep" "$(echo "$t1 - $t0" | bc)" \
      "$(awk '{print $2}' <<<"$r")" "$(awk '{print $4}' <<<"$r")" "$(awk '{print $6}' <<<"$r")" >> "$out/mpiinit.tsv"
  done
done
