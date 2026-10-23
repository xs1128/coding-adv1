/* T0.4: cost of MPI_Init/MPI_Finalize and host-buffer ring-exchange bandwidth under a transport setting. */
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + 1e-9 * t.tv_nsec; }
int main(int argc, char **argv) {
    double t0 = now();
    MPI_Init(&argc, &argv);
    double init = now() - t0, gbs = 0;
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    const int n = 1 << 20, reps = 20;                  /* 8 MB of FP64, about one halo face at 4 GPUs */
    double *s = calloc(n, sizeof *s), *r = calloc(n, sizeof *r);
    if (size > 1) {
        int up = (rank + 1) % size, dn = (rank + size - 1) % size;
        for (int i = 0; i <= reps; i++) {               /* i == 0 is warm-up */
            if (i == 1) { MPI_Barrier(MPI_COMM_WORLD); t0 = now(); }
            MPI_Sendrecv(s, n, MPI_DOUBLE, up, 0, r, n, MPI_DOUBLE, dn, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        }
        gbs = 2.0 * reps * n * sizeof *s / (now() - t0) / 1e9;   /* sent + received per rank */
    }
    double t2 = now();
    MPI_Finalize();
    double t3 = now();
    if (rank == 0) printf("init_s %.3f sendrecv_GBs %.2f finalize_s %.3f\n", init, gbs, t3 - t2);
    free(s); free(r);
    return 0;
}
