#!/usr/bin/env bash
# Profiling job (submit via harness/submit.sh ... SCRIPT=profile). Env: MODE=nsys|ncu, NCU_SKIP NCU_COUNT
#   NCU_SET NCU_KERNEL, plus the run.sbatch vars. CSV summaries -> results/, reports stay in runs/.
#SBATCH -A acd110018
#SBATCH -p dev
#SBATCH -N 1
set -euo pipefail
ROOT=/work/u1131128/coding-adv1
source "$ROOT/scripts/env.sh"
: "${LABEL:?}" "${CASE:?}" "${NGPU:=1}" "${BUILD:=generic}" "${MODE:=nsys}" "${CASE_ARGS:=}"
: "${MPIRUN_ARGS:=}" "${RUN_ENV:=}" "${NCU_SKIP:=200}" "${NCU_COUNT:=120}" "${NCU_SET:=full}" "${NCU_KERNEL:=.*}"
out=$ROOT/results/$LABEL
run=$ROOT/runs/$LABEL
mkdir -p "$out" "$run"
# /tmp/nvidia is not writable on some nodes
export TMPDIR=/dev/shm/${USER}_${SLURM_JOB_ID}; mkdir -p "$TMPDIR"; trap 'rm -rf "$TMPDIR"' EXIT
cp "$ROOT/$CASE" "$run/case.py"
{
  echo "job=$SLURM_JOB_ID host=$(hostname) date=$(date -Iseconds) mode=$MODE"
  echo "label=$LABEL case=$CASE case_args=$CASE_ARGS ngpu=$NGPU build=$BUILD"
  echo "mpirun_args=$MPIRUN_ARGS run_env=$RUN_ENV ncu: skip=$NCU_SKIP count=$NCU_COUNT set=$NCU_SET kernel=$NCU_KERNEL"
  cat "$ROOT/.provenance"
  echo "mfc=$(git -C "$MFC_DIR" describe --always --dirty) $(git -C "$MFC_DIR" rev-parse HEAD)"
  nsys --version; ncu --version | tail -1
  nvidia-smi --query-gpu=index,name,clocks.sm,clocks.mem,power.limit --format=csv
} > "$out/env.txt" 2>&1

opt=(); [[ $BUILD == caseopt ]] && opt=(--case-optimization)
cd "$MFC_DIR"
cargs=(); [[ -n $CASE_ARGS ]] && cargs=(-- $CASE_ARGS)
./mfc.sh run "$run/case.py" -n "$NGPU" -t pre_process simulation --no-build -b mpirun "${opt[@]}" \
    "${cargs[@]}" > "$out/prep.log" 2>&1
sim=$(grep -oE '[^ ]*/bin/simulation' "$out/prep.log" | tail -1)
[[ -x $sim ]] || sim=$(ls -t "$MFC_DIR"/build/install/*/bin/simulation 2>/dev/null | head -1)  # older mfc.sh
echo "sim=$sim" >> "$out/env.txt"
cd "$run"

wrap=$run/wrap.sh
case "$MODE" in
  nsys)
    cat > "$wrap" <<EOF
#!/usr/bin/env bash
r=\${OMPI_COMM_WORLD_RANK:-0}
exec nsys profile --trace=cuda,nvtx,mpi,openacc,ucx --mpi-impl=openmpi --sample=none --cpuctxsw=none \
     --force-overwrite=true -o "$run/nsys_rank\$r" "\$@"
EOF
    ;;
  ncu)
    # rank 0 only
    cat > "$wrap" <<EOF
#!/usr/bin/env bash
r=\${OMPI_COMM_WORLD_RANK:-0}
if [[ \$r == 0 ]]; then
  exec ncu --set $NCU_SET --import-source yes --kernel-name-base function --kernel-name "regex:$NCU_KERNEL" \
       --launch-skip $NCU_SKIP --launch-count $NCU_COUNT --force-overwrite -o "$run/ncu_rank0" "\$@"
fi
exec "\$@"
EOF
    ;;
  *) echo "unknown MODE $MODE" >&2; exit 2 ;;
esac
chmod +x "$wrap"
t0=$(date +%s.%N)
env $RUN_ENV mpirun -np "$NGPU" $MPIRUN_ARGS "$wrap" "$sim" > "$out/run.log" 2>&1
t1=$(date +%s.%N)
echo "wall_s=$(echo "$t1 - $t0" | bc)" >> "$out/env.txt"

case "$MODE" in
  nsys)
    for f in "$run"/nsys_rank*.nsys-rep; do
      b=$(basename "$f" .nsys-rep)
      nsys stats --force-export=true --format csv --output "$out/$b" \
        --report cuda_gpu_kern_sum --report cuda_gpu_mem_time_sum --report cuda_api_sum \
        --report nvtx_sum --report mpi_event_sum "$f" > /dev/null 2>&1 || true
    done ;;
  ncu)
    ncu --import "$run/ncu_rank0.ncu-rep" --page raw --csv > "$out/ncu_raw.csv" 2>/dev/null || true
    ncu --import "$run/ncu_rank0.ncu-rep" --page details --csv > "$out/ncu_details.csv" 2>/dev/null || true ;;
esac
ls -la "$out"
