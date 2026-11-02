#!/usr/bin/env bash
# WRAP for harness/run.sbatch: run the simulation under nsys (CUDA, NVTX, OS runtime, CPU sampling) so a profile can
# use the same run settings as a timed run (RUN_ENV, RUNLOCAL). Report: $NSYS_OUT_rank<r>.nsys-rep (set NSYS_OUT).
r=${OMPI_COMM_WORLD_RANK:-0}
exec nsys profile --trace=cuda,nvtx,osrt --sample=cpu --cpuctxsw=none --force-overwrite=true \
     -o "${NSYS_OUT:?}_rank$r" "$@"
