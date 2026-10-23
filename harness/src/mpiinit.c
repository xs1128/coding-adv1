/* Time MPI_Init/MPI_Finalize alone (T0.4: what costs 1.7 s of MFC's start-up at 1 rank). */
#include <mpi.h>
#include <stdio.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + 1e-9 * t.tv_nsec; }
int main(int argc, char **argv) {
    double t0 = now();
    MPI_Init(&argc, &argv);
    double t1 = now();
    MPI_Barrier(MPI_COMM_WORLD);
    double t2 = now();
    MPI_Finalize();
    double t3 = now();
    int rank = 0;
    if (rank == 0) printf("init_s %.3f barrier_s %.3f finalize_s %.3f\n", t1 - t0, t2 - t1, t3 - t2);
    return 0;
}
