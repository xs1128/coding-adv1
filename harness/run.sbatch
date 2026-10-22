#!/usr/bin/env bash
# One MFC timing job on nano4. Submit through harness/submit.sh (sets resources + env), not directly.
# Env in:  LABEL (results/<LABEL>), CASE (harness/cases/*.py), CASE_ARGS, NGPU, REPS (default 3),
#          BUILD (generic|caseopt), MPIRUN_ARGS (extra mpirun flags), RUN_ENV (extra "K=V K=V" for the runs)
# Out:     results/<LABEL>/{env.txt,smi_before.csv,smi_after.csv,prep.log,rep<i>.log,summary.tsv}
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
source "$ROOT/scripts/env.sh"
# Slurm cgroups only expose the allocated cores; OMPI's default core binding (core 0) then fails.
# Default: no binding; explicit binding is a tuning experiment (MPIRUN_ARGS / RUN_ENV).
export OMPI_MCA_hwloc_base_binding_policy=${OMPI_MCA_hwloc_base_binding_policy:-none}
: "${LABEL:?}" "${CASE:?}" "${NGPU:=1}" "${REPS:=3}" "${BUILD:=generic}" "${CASE_ARGS:=}" "${MPIRUN_ARGS:=}" "${RUN_ENV:=}"
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
  echo "mfc=$(git -C "$MFC_DIR" describe --always --dirty) $(git -C "$MFC_DIR" rev-parse HEAD)"
  echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-}"
  nvfortran --version | sed -n 2p
  nvidia-smi topo -m
  lscpu | grep -E 'Model name|^CPU\(s\)|NUMA node'
} > "$out/env.txt" 2>&1
smi "$out/smi_before.csv"

opt=(); [[ $BUILD == caseopt ]] && opt=(--case-optimization)
cd "$MFC_DIR"
# Prep: pre_process + one simulation run through mfc.sh (also the warm-up; writes *.inp and shows the binary).
# --case-optimization here only selects the already-built binary (--no-build).
./mfc.sh run "$run/case.py" -n "$NGPU" -t pre_process simulation --no-build -b mpirun "${opt[@]}" \
    -- $CASE_ARGS > "$out/prep.log" 2>&1
sim=$(grep -oE '[^ ]*/bin/simulation' "$out/prep.log" | tail -1)
[[ -x $sim ]] || { echo "simulation binary not found in prep.log" >&2; exit 1; }
echo "sim=$sim" >> "$out/env.txt"

cd "$run"
printf 'rep\twall_s\tgrind_ns\n' > "$out/summary.tsv"
for r in $(seq 1 "$REPS"); do
  t0=$(date +%s.%N)
  env $RUN_ENV mpirun -np "$NGPU" $MPIRUN_ARGS "$sim" > "$out/rep$r.log" 2>&1
  t1=$(date +%s.%N)
  g=$(awk '/Performance:/{print $2}' "$out/rep$r.log" | tail -1)
  printf '%s\t%.3f\t%s\n' "$r" "$(echo "$t1 - $t0" | bc)" "$g" >> "$out/summary.tsv"
done
smi "$out/smi_after.csv"
cp -f "$run"/*.inp "$out/" 2>/dev/null || true
cat "$out/summary.tsv"
