#!/usr/bin/env bash
# Timing job (submit via harness/submit.sh). Env: LABEL CASE CASE_ARGS NGPU REPS BUILD MPIRUN_ARGS RUN_ENV WRAP
#   STEPPROF KEEP_OUTPUT MFC_DIR. Out: results/<LABEL>/{summary.tsv,steps.tsv,...}
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
source "$ROOT/scripts/env.sh"
: "${LABEL:?}" "${CASE:?}" "${NGPU:=1}" "${REPS:=3}" "${BUILD:=generic}" "${CASE_ARGS:=}" "${MPIRUN_ARGS:=}" "${RUN_ENV:=}" "${WRAP:=}"
RUN_ENV=${RUN_ENV//+/,}; RUN_ENV=${RUN_ENV//@/ }  # sbatch --export splits at commas: write + for a comma, @ between variables
: "${STEPPROF:=1}" "${KEEP_OUTPUT:=0}" "${RUNLOCAL:=0}"
out=$ROOT/results/$LABEL
run=$ROOT/runs/$LABEL            # bulky outputs (D/, restart_data/, silo) live outside results/
# RUNLOCAL=1 (setting, disclosed): the case directory, so the initial-state read and the restart save, lives in
# node-local memory (/dev/shm) instead of Lustre; after the timed reps the final state is copied to runs/ for verify.
keep=$run
if [[ $RUNLOCAL == 1 ]]; then
  run=/dev/shm/${USER}_${SLURM_JOB_ID}_run/$LABEL   # not the STEPPROF TMPDIR, which is deleted after its rep
  rm -rf "$run"; mkdir -p "$keep"
fi
mkdir -p "$out" "$run"
cp "$ROOT/$CASE" "$run/case.py"

smi() { nvidia-smi --query-gpu=index,name,pci.bus_id,clocks.sm,clocks.mem,power.draw,power.limit,temperature.gpu,utilization.gpu,memory.used,clocks_event_reasons.hw_power_brake_slowdown,clocks_event_reasons.hw_slowdown \
          --format=csv > "$1"; }
{
  echo "job=$SLURM_JOB_ID host=$(hostname) date=$(date -Iseconds)"
  echo "label=$LABEL case=$CASE case_args=$CASE_ARGS ngpu=$NGPU reps=$REPS build=$BUILD"
  echo "mpirun_args=$MPIRUN_ARGS run_env=$RUN_ENV wrap=$WRAP nic_map=${NIC_MAP:-}"
  cat "$ROOT/.provenance"
  echo "nvhpc_module=$NVHPC_MODULE cuda=${NVHPC_CUDA_HOME:-bundled} cuda_module=${CUDA_MODULE:-} opal=$OPAL_PREFIX"
  echo "mfc_dir=$MFC_DIR mfc=$(git -C "$MFC_DIR" describe --always --dirty) $(git -C "$MFC_DIR" rev-parse HEAD)"
  echo "mfc_diff_sha1=$(git -C "$MFC_DIR" diff HEAD -- src toolchain CMakeLists.txt cmake | sha1sum | cut -c1-12)"
  echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-}"
  nvfortran --version | sed -n 2p
  nvidia-smi topo -m
  lscpu | grep -E 'Model name|^CPU\(s\)|NUMA node'
} > "$out/env.txt" 2>&1
smi "$out/smi_before.csv"

opt=(); [[ $BUILD == caseopt ]] && opt=(--case-optimization)
cd "$MFC_DIR"
# pre_process + warm-up run via mfc.sh (also writes *.inp and names the binary)
cargs=(); [[ -n $CASE_ARGS ]] && cargs=(-- $CASE_ARGS)
./mfc.sh run "$run/case.py" -n "$NGPU" -t pre_process simulation --no-build -b mpirun "${opt[@]}" \
    "${cargs[@]}" > "$out/prep.log" 2>&1
sim=$(grep -oE '[^ ]*/bin/simulation' "$out/prep.log" | tail -1)
[[ -x $sim ]] || sim=$(ls -t "$MFC_DIR"/build/install/*/bin/simulation 2>/dev/null | head -1)  # older mfc.sh
[[ -x $sim ]] || { echo "simulation binary not found in prep.log" >&2; exit 1; }
echo "sim=$sim" >> "$out/env.txt"

cd "$run"
rm -f restart_data/lustre_[1-9]*.dat   # the warm-up's final state must not stand in for the timed reps' (verify reads it)
printf 'rep\twall_s\tgrind_ns\n' > "$out/summary.tsv"
# NOLIBPATH=1 (setting, disclosed): the timed runs start with LD_LIBRARY_PATH unset. The binaries' RPATHs find the same
# libraries (696781: the same 187 loaded objects), and every LD_LIBRARY_PATH miss was a metadata lookup on Lustre.
libu=(); [[ ${NOLIBPATH:-0} == 1 ]] && libu=(-u LD_LIBRARY_PATH)
echo "nolibpath=${NOLIBPATH:-0}" >> "$out/env.txt"
# LAUNCH=singleton (1 rank only; setting, disclosed): start the simulation without mpirun, as an MPI singleton that
# starts no helper daemon (OMPI_MCA_ess_singleton_isolated=1). A plain singleton hung in MPI_Init (696387), so every
# rep runs under a timeout.
launch=(mpirun -np "$NGPU" $MPIRUN_ARGS)
if [[ ${LAUNCH:-mpirun} == singleton ]]; then
  [[ $NGPU == 1 ]] || { echo "LAUNCH=singleton needs NGPU=1" >&2; exit 2; }
  # mpirun gives the processes it starts Open MPI's library folders in LD_LIBRARY_PATH even when it is unset; without
  # them the singleton cannot open its components (697728: pml ob1 not found). Take the same value from mpirun, untimed.
  ldp=$(env "${libu[@]}" $RUN_ENV timeout 30 mpirun -np 1 printenv LD_LIBRARY_PATH)
  echo "singleton_ld_library_path=$ldp" >> "$out/env.txt"
  launch=(timeout "${LAUNCH_TIMEOUT:-60}" env OMPI_MCA_ess_singleton_isolated=1 "LD_LIBRARY_PATH=$ldp")
fi
echo "launch=${LAUNCH:-mpirun}" >> "$out/env.txt"
for r in $(seq 1 "$REPS"); do
  t0=$(date +%s.%N)
  env "${libu[@]}" $RUN_ENV "${launch[@]}" $WRAP "$sim" > "$out/rep$r.log" 2>&1
  t1=$(date +%s.%N)
  g=$(awk '/Performance:/{print $2}' "$out/rep$r.log" | tail -1)
  printf '%s\t%.3f\t%s\n' "$r" "$(echo "$t1 - $t0" | bc)" "$g" >> "$out/summary.tsv"
done
smi "$out/smi_after.csv"

# LAUNCHPROBE=1 (untimed, after the reps): how long launching alone takes. Times mpirun and srun of /bin/true (3 each,
# each under a timeout), records the dynamic loader's statistics for one mpirun of the simulation, and times launches
# without hwloc's GPU plugins (srun of the simulation fails in orte_init with this Open MPI, 696467/696471).
# LAUNCHPROBE=3 (untimed, after the reps): the simulation with LD_LIBRARY_PATH unset (the binaries' RPATHs find their
# libraries; each LD_LIBRARY_PATH miss is a Lustre lookup), alternating with the default; the loaded objects of both
# (LD_DEBUG=files) and the final states are compared
if [[ ${LAUNCHPROBE:-0} == 3 ]]; then
  pf=$out/launchprobe3.tsv; printf 'what\trep\twall_s\trc\n' > "$pf"
  tm() { local w=$1 r=$2; shift 2; local t0 t1 rc=0; t0=$(date +%s.%N); "$@" > "$out/launchprobe3_$w.log" 2>&1 || rc=$?
         t1=$(date +%s.%N); printf '%s\t%s\t%.3f\t%s\n' "$w" "$r" "$(echo "$t1 - $t0" | bc)" "$rc" >> "$pf"; }
  last=$(ls restart_data/ | sed -nE 's/^lustre_([0-9]+)\.dat$/\1/p' | sort -n | tail -1)
  cp restart_data/lustre_${last}.dat restart_data/lustre_${last}.dat.reps
  for r in 1 2 3; do
    tm version_default $r timeout 60 mpirun --version
    tm version_nolibpath $r env -u LD_LIBRARY_PATH timeout 60 mpirun --version
    tm sim_default $r env $RUN_ENV timeout 90 mpirun -np 1 $MPIRUN_ARGS "$sim"
    tm sim_nolibpath $r env -u LD_LIBRARY_PATH $RUN_ENV timeout 90 mpirun -np 1 $MPIRUN_ARGS "$sim"
    cmp -s restart_data/lustre_${last}.dat restart_data/lustre_${last}.dat.reps && echo "nolibpath rep $r: final state identical" \
      >> "$out/launchprobe3_cmp.txt" || echo "nolibpath rep $r: final state DIFFERS" >> "$out/launchprobe3_cmp.txt"
  done
  objs() { grep -oE 'file=[^ ]+ \[0\];  generating link map' "$1" | sed -E 's/^file=([^ ]+).*/\1/' | xargs -r -n1 readlink -f | sort -u; }
  env $RUN_ENV LD_DEBUG=files LD_DEBUG_OUTPUT=$run/ldd_default timeout 90 mpirun -np 1 $MPIRUN_ARGS "$sim" > /dev/null 2>&1 || true
  env -u LD_LIBRARY_PATH $RUN_ENV LD_DEBUG=files LD_DEBUG_OUTPUT=$run/ldd_nolib timeout 90 mpirun -np 1 $MPIRUN_ARGS "$sim" > /dev/null 2>&1 || true
  cat $run/ldd_default.* | objs /dev/stdin > "$out/launchprobe3_objs_default.txt" || true
  cat $run/ldd_nolib.* | objs /dev/stdin > "$out/launchprobe3_objs_nolibpath.txt" || true
  diff "$out/launchprobe3_objs_default.txt" "$out/launchprobe3_objs_nolibpath.txt" > "$out/launchprobe3_objs.diff" \
    && echo "loaded objects: identical" >> "$out/launchprobe3_cmp.txt" || echo "loaded objects: DIFFER" >> "$out/launchprobe3_cmp.txt"
  rm -f $run/ldd_default.* $run/ldd_nolib.*
fi
# LAUNCHPROBE=2 (untimed, after the reps): mpirun -np 1 /bin/true under Open MPI start-up settings, 3 times each
if [[ ${LAUNCHPROBE:-0} == 2 ]]; then
  pf=$out/launchprobe2.tsv; printf 'what\trep\twall_s\trc\n' > "$pf"
  tm() { local w=$1 r=$2; shift 2; local t0 t1 rc=0; t0=$(date +%s.%N); "$@" > "$out/launchprobe2_$w.log" 2>&1 || rc=$?
         t1=$(date +%s.%N); printf '%s\t%s\t%.3f\t%s\n' "$w" "$r" "$(echo "$t1 - $t0" | bc)" "$rc" >> "$pf"; }
  declare -A pv=([default]="" [plm_isolated]="OMPI_MCA_plm=isolated" [oob_lo]="OMPI_MCA_oob_tcp_if_include=lo"
                 [bind_none]="OMPI_MCA_hwloc_base_binding_policy=none" [odls_pspawn]="OMPI_MCA_odls=pspawn"
                 [combo]="OMPI_MCA_plm=isolated OMPI_MCA_oob_tcp_if_include=lo OMPI_MCA_hwloc_base_binding_policy=none")
  for r in 1 2 3; do
    tm version $r timeout 60 mpirun --version
    for v in default plm_isolated oob_lo bind_none odls_pspawn combo; do
      tm $v $r env $RUN_ENV ${pv[$v]} timeout 60 mpirun -np 1 $MPIRUN_ARGS /bin/true
    done
  done
fi
if [[ ${LAUNCHPROBE:-0} == 1 ]]; then
  SRUN_ENV=${SRUN_ENV:-}; SRUN_ENV=${SRUN_ENV//+/,}; SRUN_ENV=${SRUN_ENV//@/ }   # extra env for the srun launches only
  echo "srun_env=$SRUN_ENV" >> "$out/env.txt"
  pf=$out/launchprobe.tsv; printf 'what\trep\twall_s\trc\n' > "$pf"
  tm() { local w=$1 r=$2; shift 2; local t0 t1 rc=0; t0=$(date +%s.%N); "$@" > "$out/launchprobe_$w.log" 2>&1 || rc=$?
         t1=$(date +%s.%N); printf '%s\t%s\t%.3f\t%s\n' "$w" "$r" "$(echo "$t1 - $t0" | bc)" "$rc" >> "$pf"; }
  srun --mpi=list > "$out/launchprobe_srun_mpi_list.log" 2>&1 || true
  for r in 1 2 3; do
    tm mpirun_true $r env $RUN_ENV timeout 60 mpirun -np 1 $MPIRUN_ARGS /bin/true
    tm srun_true $r env $RUN_ENV $SRUN_ENV timeout 60 srun -n 1 --mpi=pmix /bin/true
  done
  tm lddebug_sim 1 env $RUN_ENV LD_DEBUG=statistics timeout 90 mpirun -np 1 $MPIRUN_ARGS "$sim"
  # hwloc's GPU plugins start NVML/CUDA during topology discovery, in mpirun and again in MPI_Init: try without them,
  # and with a pre-generated topology (v1 XML, which the hwloc inside Open MPI 4.1 reads)
  hwx=HWLOC_COMPONENTS=-cuda,-nvml,-opencl,-rsmi,-levelzero,-gl
  lstopo-no-graphics --of xml --export-xml-flags v1 "$run/topo.xml" > /dev/null 2>&1 || true
  for r in 1 2 3; do
    tm mpirun_true_nogpuhwloc $r env $RUN_ENV $hwx timeout 60 mpirun -np 1 $MPIRUN_ARGS /bin/true
    tm mpirun_true_topov1 $r env $RUN_ENV OMPI_MCA_hwloc_base_topo_file=$run/topo.xml timeout 60 mpirun -np 1 $MPIRUN_ARGS /bin/true
  done
  last=$(ls restart_data/ | sed -nE 's/^lustre_([0-9]+)\.dat$/\1/p' | sort -n | tail -1)
  cp restart_data/lustre_${last}.dat restart_data/lustre_${last}.dat.reps
  for r in 1 2 3; do
    tm mpirun_sim $r env $RUN_ENV timeout 90 mpirun -np 1 $MPIRUN_ARGS "$sim"
    tm mpirun_sim_nogpuhwloc $r env $RUN_ENV $hwx timeout 90 mpirun -np 1 $MPIRUN_ARGS "$sim"
    cmp -s restart_data/lustre_${last}.dat restart_data/lustre_${last}.dat.reps && echo "nogpuhwloc rep $r: final state identical" \
      >> "$out/launchprobe_cmp.txt" || echo "nogpuhwloc rep $r: final state DIFFERS" >> "$out/launchprobe_cmp.txt"
  done
fi

# extra rep under NVTX-only nsys: per-rank step times (grind is only the min stage)
if [[ $STEPPROF == 1 ]]; then
  export TMPDIR=/dev/shm/${USER}_${SLURM_JOB_ID}; mkdir -p "$TMPDIR"
  printf '#!/usr/bin/env bash\nexec nsys profile --trace=nvtx --sample=none --cpuctxsw=none --force-overwrite=true -o "%s/steps_rank${OMPI_COMM_WORLD_RANK:-0}" "$@"\n' \
    "$run" > "$run/nvtxwrap.sh"
  chmod +x "$run/nvtxwrap.sh"
  env $RUN_ENV mpirun -np "$NGPU" $MPIRUN_ARGS $WRAP "$run/nvtxwrap.sh" "$sim" > "$out/steprep.log" 2>&1 || true
  for f in "$run"/steps_rank*.nsys-rep; do
    nsys stats --force-export=true --format csv --report nvtx_pushpop_trace --output "${f%.nsys-rep}" "$f" \
      > /dev/null 2>&1 || true
  done
  python3 "$ROOT/harness/steps.py" "$run" > "$out/steps.tsv" || true
  rm -f "$run"/steps_rank*.nsys-rep "$run"/steps_rank*.sqlite
  rm -rf "$TMPDIR"
fi

cp -f "$run"/*.inp "$run"/time_data.dat "$run"/io_time_data.dat "$out/" 2>/dev/null || true
if [[ $KEEP_OUTPUT != 1 ]]; then   # keep only the final state for verify
  last=$(ls "$run"/restart_data/ | sed -nE 's/^lustre_([0-9]+)\.dat$/\1/p' | sort -n | tail -1)
  for f in "$run"/restart_data/lustre_[0-9]*.dat; do [[ $f == */lustre_${last}.dat ]] || rm -f "$f"; done
  rm -rf "$run"/D "$run"/p_all "$run"/silo_hdf5 "$run"/steps_rank*.csv
fi
if [[ $RUNLOCAL == 1 ]]; then   # untimed: bring the run (final state, inputs, logs) back to runs/ and free the RAM
  rm -rf "$keep"; mkdir -p "$(dirname "$keep")"; cp -r "$run" "$keep"; rm -rf "/dev/shm/${USER}_${SLURM_JOB_ID}_run"
fi
cat "$out/summary.tsv"; cat "$out/steps.tsv" 2>/dev/null || true
