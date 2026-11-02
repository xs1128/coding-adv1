# Starting point: where the time went (MFC v5.7.0, nano4 H200, 2026-10-22)

We measured the unchanged code first. Case: `harness/cases/perf3d.py` = upstream `examples/3D_performance_test`
(2 fluids, WENO5-M, HLLC, RK3, FP64), 201³ cells ("strong": same problem, more GPUs) or 8.12 M cells per GPU
("weak"), 30 steps, 1 rank (MPI process) per GPU. Every number points to `results/<path>`.

A **kernel** is one GPU function run over many cells. **WENO5** builds smooth values at cell faces; **HLLC** works
out what flows across them. A **halo exchange** swaps border cells between GPUs. **nsys** records a timeline;
**ncu** looks closely at one kernel. **Grind** is MFC's speed number (ns per grid point per equation per RHS
pass); lower is better.

## Fixes needed before anything ran (settings only, disclosed, math untouched)
`srun` could not start Open MPI → `mpirun`. Open MPI pinned cores outside the job's CPUs → binding off. Default MPI
file I/O took 337 s at 2 ranks and crashed at 4 → `OMPI_MCA_io=romio321`. nsys could not write /tmp/nvidia on
some nodes → TMPDIR in /dev/shm. (Evidence: results/base/failed_600131_srun, results/base/failed_600134_bind,
results/old/scale_ompio, job 600177.)

## 1 GPU
| Build | grind | wall (30 steps) | job |
|---|---|---|---|
| generic | 0.930 | 10.8 s | 600136 |
| case-optimized (built for this one case) | **0.397** | 7.5 s | 600139 |

Upstream reports 0.41–0.47 on H200 (issue #2088), slower than v4.9.3 (0.346); we see the same.

nsys: the GPU is busy ≈96 % of a stage (66 kernel launches). A 10-step run spends 3.9 s starting up, 1.4 s saving
data, and only 0.82 s stepping.

ncu (prof/ncu_caseopt_1g): "regs" are registers, each thread's tiny fast storage. The more a thread needs, the
fewer threads run at once ("warps active").

| kernel | share of stage | regs | warps active | memory speed used |
|---|---|---|---|---|
| WENO5 | 34 % | 188–196 | 12 % | 10 % (waits on memory) |
| HLLC | 25 % | 127–160 | 17–23 % | 31–42 % |
| copy-like kernels | ≈25 % | 44–66 | 40–56 % | 24–37 % (busy with index math) |

## Several GPUs on one node
Grind is optimistic (fastest stage, slowest rank); the honest number is the **median step**. `rdma_mpi=T` sends
halos straight from GPU to GPU; otherwise they go through the CPU ("host-staged").

| GPUs | strong grind | speedup | weak efficiency | wall strong / weak |
|---|---|---|---|---|
| 1 | 0.397 | 1.00 | 100 % | 7.5 / 7.5 s |
| 2 | 0.258 | 1.54 | 94 % | 10 / 12 s |
| 4 | 0.158 | 2.51 | 85 % | 13.6 / 17.3 s |
| 8 | 0.111 | 3.57 | 73 % | 18.8 / 31.0 s |
| 8, RDMA | **0.071** | **5.57** | **≈100 %** | 18.7 / 26.6 s |

(results/scale/*, jobs 600171–600180.) All end **bitwise identical** (every bit the same) to 1 GPU.

Medians per step, nsys, rank 0:

| config | step | halo exchange | first step |
|---|---|---|---|
| 1 GPU | 81.2 ms | 0.38 ms | 89 ms |
| 4 GPU host-staged | 32.6 ms | 3.05 ms (30 %) | 46 ms |
| 8 GPU host-staged | 26.0 ms | 4.42 ms (53 %) | 50 ms |
| 8 GPU RDMA | **16.5 ms** | 1.35 ms (26 %) | **175 ms** |

## Bottlenecks, biggest multi-GPU cost first
1. **Halo exchange**: one face at a time, waiting, through the CPU by default. RDMA helps, but 6 waiting
   `MPI_Sendrecv`s in a row remain. 8-GPU efficiency: 45 % → 62 % with RDMA.
2. **Start-up grows with rank count** (grind hides it): MPI_Init 2.2 s → 7–29 s at 8 ranks (under nsys). 8 GPUs take ≈ 2.5×
   the 1-GPU wall time, though their steps are 5× faster.
3. **Kernel speed on one GPU** sets the floor: ≈18 % of a stage is unneeded copies.
4. **Uneven load**: 992–2072 kernel launches per rank, so neighbours wait.
5. **RDMA's slow first step** matters only for short runs.

## Who waits for whom at 8 GPUs (prof/nsys_caseopt_8g_rdma, per stage)
Each rank has 3 faces facing other ranks and 3 on the domain edge; some edges use CBC (an outflow boundary).

| rank | GPU kernels | rest of RHS | Sendrecv wait |
|---|---|---|---|
| 0 (no CBC face) | 3.54 ms | 3.91 ms | 0.34 ms |
| 3, 5, 6 (2 CBC faces) | 3.59–3.61 | 4.46–4.52 | 0.04 |
| 7 (3 CBC faces) | 3.60 | **4.79** | 0.03 |

GPU work is even (±2 %), but rank 7 spends **0.9 ms/stage more on the CPU** (tiny CBC kernels plus 5 waiting
updates per call), and the others wait for it. So at 8 GPUs the limit is **the CPU's launch-and-wait delay, spread
unevenly**, not halo bandwidth (≈0.03 ms per face).

## MPI transport check (job 600232, two GPUs)
The guess "no fast NVLink path between GPUs" is **wrong** on compute nodes: UCX 1.20 uses `cuda_ipc` for GPU
messages ≥1.3 KB, at 292 GB/s. A 2.6 MB halo face needs ≈15–20 µs, so the 0.34 ms median Sendrecv is mostly
waiting. (The HPC-X-UCX half of the job did not run: `hpcx-init.sh` trips `set -u`. Not re-run, since the first
half already reaches NVLink speed.)
