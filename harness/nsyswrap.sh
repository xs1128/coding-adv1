#!/usr/bin/env bash
# WRAP for harness/run.sbatch: run the simulation under nsys (CUDA, NVTX, OS runtime, CPU sampling) so a profile can
# use the same run settings as a timed run (RUN_ENV, RUNLOCAL). Report: $NSYS_OUT_rank<r>.nsys-rep (set NSYS_OUT).
r=${OMPI_COMM_WORLD_RANK:-0}
# nsys keeps temp files in $TMPDIR/nvidia; a /tmp/nvidia left by another user on the node makes it fail (695468),
# so give it a folder of our own for this job.
export TMPDIR=/dev/shm/nsystmp_${SLURM_JOB_ID:-$$}_$r
mkdir -p "$TMPDIR"
exec nsys profile --trace=cuda,nvtx,osrt --sample=cpu --cpuctxsw=none --force-overwrite=true \
     -o "${NSYS_OUT:?}_rank$r" "$@"
