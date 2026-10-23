#!/usr/bin/env bash
# Timing job (submit via harness/submit.sh). Env: LABEL CASE CASE_ARGS NGPU REPS BUILD MPIRUN_ARGS RUN_ENV
#   STEPPROF KEEP_OUTPUT MFC_DIR. Out: results/<LABEL>/{summary.tsv,steps.tsv,...}
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
source "$ROOT/scripts/env.sh"
: "${LABEL:?}" "${CASE:?}" "${NGPU:=1}" "${REPS:=3}" "${BUILD:=generic}" "${CASE_ARGS:=}" "${MPIRUN_ARGS:=}" "${RUN_ENV:=}"
: "${STEPPROF:=1}" "${KEEP_OUTPUT:=0}"
out=$ROOT/results/$LABEL
run=$ROOT/runs/$LABEL            # bulky outputs (D/, restart_data/, silo) live outside results/
mkdir -p "$out" "$run"
cp "$ROOT/$CASE" "$run/case.py"

smi() { nvidia-smi --query-gpu=index,name,pci.bus_id,clocks.sm,clocks.mem,power.draw,power.limit,temperature.gpu,utilization.gpu,memory.used \
          --format=csv > "$1"; }
{
  echo "job=$SLURM_JOB_ID host=$(hostname) date=$(date -Iseconds)"
  echo "label=$LABEL case=$CASE case_args=$CASE_ARGS ngpu=$NGPU reps=$REPS build=$BUILD"
  echo "mpirun_args=$MPIRUN_ARGS run_env=$RUN_ENV"
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
for r in $(seq 1 "$REPS"); do
  t0=$(date +%s.%N)
  env $RUN_ENV mpirun -np "$NGPU" $MPIRUN_ARGS "$sim" > "$out/rep$r.log" 2>&1
  t1=$(date +%s.%N)
  g=$(awk '/Performance:/{print $2}' "$out/rep$r.log" | tail -1)
  printf '%s\t%.3f\t%s\n' "$r" "$(echo "$t1 - $t0" | bc)" "$g" >> "$out/summary.tsv"
done
smi "$out/smi_after.csv"

# extra rep under NVTX-only nsys: per-rank step times (grind is only the min stage)
if [[ $STEPPROF == 1 ]]; then
  export TMPDIR=/dev/shm/${USER}_${SLURM_JOB_ID}; mkdir -p "$TMPDIR"
  printf '#!/usr/bin/env bash\nexec nsys profile --trace=nvtx --sample=none --cpuctxsw=none --force-overwrite=true -o "%s/steps_rank${OMPI_COMM_WORLD_RANK:-0}" "$@"\n' \
    "$run" > "$run/nvtxwrap.sh"
  chmod +x "$run/nvtxwrap.sh"
  env $RUN_ENV mpirun -np "$NGPU" $MPIRUN_ARGS "$run/nvtxwrap.sh" "$sim" > "$out/steprep.log" 2>&1 || true
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
cat "$out/summary.tsv"; cat "$out/steps.tsv" 2>/dev/null || true
