#!/usr/bin/env bash
# WRAP for harness/run.sbatch (multi-rank runs under mpirun): replace the 11-folder LD_LIBRARY_PATH that mpirun gives
# each rank (HPC-X folders on Lustre, every miss a metadata lookup) by $LDPWRAP_PATH, then run the program.
# Keep HPC-X's UCX folders in it: without them the UCX components resolve to the system UCX in /lib64 (ladder row 100).
export LD_LIBRARY_PATH=${LDPWRAP_PATH:?}
exec "$@"
