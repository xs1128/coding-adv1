# Baseline measurements and profiling — MFC v5.7.0 on nano4 H200 (2026-10-22)

Case: `harness/cases/perf3d.py` = upstream `examples/3D_performance_test` (5-eq, 2 fluids, WENO5-M, HLLC, RK3,
FP64, stretched grid), 201³ cells (strong) or 8.12 M cells/GPU (weak), 30 steps, NVHPC 26.3 OpenACC,
HPC-X 2.25.1 mpirun, 1 rank/GPU, `OMPI_MCA_io=romio321`, no CPU binding. Every number → `results/<path>`.

## Environment fixes needed before anything ran (all disclosed, none touch numerics)
| Problem | Evidence | Fix |
|---|---|---|
| `srun` cannot init HPC-X OMPI | results/base/failed_600131_srun | `mpirun` (`-b mpirun`) |
| OMPI core binding outside cgroup cpuset | results/base/failed_600134_bind | `OMPI_MCA_hwloc_base_binding_policy=none` |
| OMPIO on WekaFS: `MPI_File_write_all` 337 s at 2 ranks; `MPI_File_close` segfault at 4 ranks | results/old/scale_ompio, results/prof/nsys_caseopt_2g | `OMPI_MCA_io=romio321` |
| nsys cannot write /tmp/nvidia on some nodes | results/prof/nsys_caseopt_4g_romio (job 600177) | per-job TMPDIR in /dev/shm |

## 1 GPU
| Build | grind ns/gp/eq/rhs | wall (30 steps) | job |
|---|---|---|---|
| generic `--gpu acc` | 0.930 (±0.1 %) | 10.8 s | base/generic_1g (600136) |
| `--case-optimization` | **0.397** (±0.2 %) | 7.5 s | base/caseopt_1g (600139) |

Reference: MFC docs H100 SXM 0.38, GH200 0.32; issue #2088 reports master 0.41–0.47 on H200 → we reproduce the
known regression vs v4.9.3 (0.346).

nsys (prof/nsys_caseopt_1g, 10 steps): GPU busy ≈96 % of a stage (25.3 of 26.3 ms); 66 kernel launches/stage.
Wall of a 10-step run: INIT 3.9 s (MPI_Init 2.2 s), SAVE-DATA 1.4 s, stepping 0.82 s.

ncu (prof/ncu_caseopt_1g; clocks locked at 1.48 GHz so durations ≈25 % inflated):
| kernel (per stage) | share | regs | warps active | DRAM | note |
|---|---|---|---|---|---|
| WENO5 ×3 | 34 % | 188–196 | 12 % (2 blocks/SM) | 10 % | FP64 pipe 31 %, latency-bound (wait/long_scoreboard) |
| HLLC ×3 | 25 % | 127–160 | 17–23 % | 31–42 % | no spills in case-opt build; long_scoreboard |
| copy-like (pack ×3, finalize ×3, rhs copy, flux-diff ×3, RK, cons→prim) | ≈25 % | 44–66 | 40–56 % | 24–37 % (1.2–1.8 TB/s) | SM 64–74 %: instruction-bound index math |

## Multi-GPU (case-opt), one node
Grind (= min over stages, max over ranks — optimistic) and the honest **median step time** from nsys NVTX.
| GPUs | strong grind | strong speedup (grind) | weak stage (grind) | weak eff. | wall strong / weak |
|---|---|---|---|---|---|
| 1 | 0.397 | 1.00 | 25.8 ms | 100 % | 7.5 / 7.5 s |
| 2 | 0.258 | 1.54 | 27.4 ms | 94 % | 10 / 12 s |
| 4 | 0.158 | 2.51 | 30.4 ms | 85 % | 13.6 / 17.3 s |
| 8 | 0.111 | 3.57 | 35.4 ms | 73 % | 18.8 / 31.0 s |
| 8, `rdma_mpi=T` | **0.071** | **5.57** | **25.8 ms** | **≈100 %** | 18.7 / 26.6 s |
(results/scale/*; jobs 600171–600180)

Correctness: final states (step 30) of 2/4/8 GPUs, host-staged and RDMA, are **bitwise identical** to 1 GPU
(results/scale/*/compare_vs_1g.json).

nsys per-step distribution (rank 0, 10 steps; prof/nsys_caseopt_{1g,4g_romio,8g_romio,8g_rdma}):
| config | TIMESTEP median | COMPUTE-RHS median | RHS-COMMUNICATION median | first step |
|---|---|---|---|---|
| 1 GPU | 81.2 ms | 25.9 ms | 0.38 ms (BC only) | 89 ms |
| 4 GPU host-staged | 32.6 ms | 10.3 ms | 3.05 ms (30 %) | 46 ms |
| 8 GPU host-staged | 26.0 ms | 8.3 ms | 4.42 ms (53 %) | 50 ms |
| 8 GPU RDMA | **16.5 ms** | 5.25 ms | 1.35 ms (26 %) | **175 ms** (one-off IPC setup) |

## Identified bottlenecks (ranked by impact on multi-GPU time-to-solution)
1. **Halo exchange is serial, blocking and (by default) host-staged.** 53 % of a stage at 8 GPUs strong;
   RDMA cuts it to 26 % but 6 sequential blocking `MPI_Sendrecv` + pack/unpack with no compute overlap remain.
   Strong-scaling efficiency at 8 GPUs: 45 % (grind, host-staged) → 62 % (median step, RDMA).
2. **Fixed per-run costs grow with rank count** (not in grind): MPI_Init 2.2 s (1 rank) → 7–29 s (8 ranks,
   under nsys), 996 MPI_Bcast at startup, MPI_Finalize 2 s, MPI-IO. Wall at 8 GPUs ≈ 2.5× the 1-GPU wall for
   the 30-step benchmark despite 5× faster steps.
3. **Single-GPU kernel efficiency** (sets the compute floor; faster kernels make comm relatively worse):
   WENO register-limited occupancy, instruction-bound copy kernels at ~30 % of HBM bandwidth, ≈18 % of stage in
   redundant copies.
4. **Load imbalance**: kernel launches per rank 992–2072 (boundary ranks run BC/CBC kernels; interior ranks
   more pack/unpack) → neighbours wait in Sendrecv (variance: max/median Sendrecv ≈ 10×).
5. **Variance / first-step cost of RDMA** (175 ms first step) — amortized in long runs, matters for short ones.
