# MFC on NCHC nano4 H200 — making an SC26 application faster without changing its answer

Coding-Adv-HW-1. Application: **MFC v5.7.0** (`0b3d56c`), the SC26 SCC application, on nano4 (H200).
Every number in this report cites a Slurm job and a path under `results/`. Changes to MFC are the patch series
`patches/opt/0001…0005` (branch `p3` on nano4). The per-rung detail, including all rejected variants, is in
`docs/ladder.md`, and agent mistakes are in `AGENT_LOG.md`.

## 1. Result

Same node per row, outputs bitwise identical to unmodified v5.7.0, median of 5 reps; step = median NVTX step over all
ranks; grind = MFC's ns / grid point / equation / RHS.

| GPUs | v5.7.0 step | Final step | Speedup | v5.7.0 grind | Final grind | Jobs |
|---|---|---|---|---|---|---|
| 1 | 76.74 ms | **61.88 ms** | **1.24×** | 0.3972 | 0.3201 | 606017 |
| 4 (both `rdma_mpi`) | 23.10 ms | **17.72 ms** | **1.30×** | 0.1184 | 0.0913 | 606018 |
| 8 (v5.7.0 default vs final) | 21.94 ms | **10.22 ms** | **2.15×** | 0.1129 | 0.0527 | 605963 / 606019 |

Strong-scaling efficiency of the final build (step time): 87 % at 4 GPUs and 76 % at 8 GPUs. v5.7.0 at its default
settings reaches 44 % at 8 GPUs.

The 1- and 4-GPU rows isolate the source changes; the 8-GPU row also includes one run-time setting (`rdma_mpi=T`).
Nothing changes the physics, the numerics, the grid, the step count or FP64.

## 2. Rules we held ourselves to
- SC26 spirit: same equations, schemes, grid, step count and precision. No loosened tolerances, no changed outputs.
- Correctness gate on every run: the final conservative state (65 M doubles) must be **bitwise identical** to the
  pinned v5.7.0 reference (`harness/verify.py`). For every `src/` change, `./mfc.sh test` (tolerance 1e-12) must show
  no failure that the unmodified build does not also show.
- Source changes are upstream-PR-able: small, idiomatic FYPP macros, OpenACC *and* OpenMP paths, compiler-portable.
  Build and run-time settings are disclosed.
- Measurement: warm-up, then ≥3 (final: 5) reps, medians; A/B on the same node; `nvidia-smi` clocks/power recorded.
  Negative results are reported.

## 3. Environment and method
- nano4 compute nodes `25a-hgpn*`: 8× H200 (141 GB, 700 W, NVLink), 2× Xeon 8480+, 10 Mellanox HCAs. NVHPC 26.3
  (CUDA 13.1, OpenACC), HPC-X 2.25.1 Open MPI 4.1.9, Slurm partition `dev`. One rank per GPU.
- Case: MFC's own benchmark `examples/3D_performance_test` (5-equation two-fluid model, WENO5-M, HLLC, RK3, FP64,
  201³ cells, 30 steps), `--case-optimization`.
- Harness (`harness/`): `submit.sh` (every job logged in `results/jobs.tsv`), `run.sbatch` (warm-up + timed reps +
  one NVTX-only nsys rep for per-rank step times), `ab.sbatch`/`series.sbatch` (several builds or settings on one node
  in one allocation), `profile.sbatch` (nsys/ncu), `mfctest.sbatch` (`./mfc.sh test`), `verify.py` (bitwise gate).
- Environment fixes needed before anything ran (none touches numerics): `mpirun` instead of `srun`, no OMPI core
  binding inside the cgroup, ROMIO instead of OMPIO on WekaFS (OMPIO took 337 s or segfaulted).

## 4. Baseline and where the time went
- **1 GPU:** 77.06 ms per step, GPU busy 96 % of a stage. WENO5 34 %, HLLC 25 %, copy-like kernels ≈25 % at
  ~30 % of HBM bandwidth (`docs/profiling-baseline.md`, jobs 600139/600146/600682).
- **Comparison with MFC's table** (0.38 ns on H100 SXM): a different metric (v4.9.3 times only `s_compute_rhs`, with
  `cpu_time`, counting ghost cells). Same-metric comparisons stay within our tables (`baseline/README.md`).
- **8 GPUs, defaults:** 3.6× over 1 GPU (grind). Halo exchange 53 % of a stage (host-staged). With `rdma_mpi=T`, 5.6×,
  but a rank with more CBC boundary faces spent 0.9 ms per stage more on the *host* (tiny kernels + blocking syncs),
  and everyone else waited for it in `MPI_Sendrecv`. GPU work itself was balanced within 2 %.
- So the plan: remove host round trips (parallel efficiency), then raise single-GPU kernel efficiency.

## 5. What we changed, why, and what it gained

Ladder on 1 GPU (rungs measured in sequence; each bitwise):

| Rung | Step | Grind | Job |
|---|---|---|---|
| v5.7.0 | 77.06 ms | 0.3982 | 600407 |
| P1 CBC async | 75.98 ms | 0.3933 | 601152 |
| K4b Riemann unity build | 70.42 ms | 0.3632 | 602474 |
| K2 WENO register cap | 62.99 ms | 0.3255 | 602559 |
| P3 async per-stage kernels (A/B 62.87 → 61.79) | 61.79 ms | 0.3200 | 604561 |

**P1 — CBC without host round trips** (`0001`, `m_cbc.fpp`, +50/−44). Each characteristic-boundary call issued ~12
small kernels and 5 scalar updates, each followed by a host sync (~230 µs per call). Queue them async, wait once.
−1.4 % at 1 GPU, −2.3 % at 4 GPUs; the gain grows with rank count because the rank with the most CBC faces sets the
pace.

**K4b — let the compiler inline the Riemann helpers** (`0002`+`0003`, CMake + 3 lines). HLLC was 42 % slower than in
v4.9.3. ncu: more local-memory than global traffic. The PTX had 9 `.extern .func` calls: nvfortran inlines `acc routine
seq` device routines only within one source file (`-Minfo`'s "cross-inlined" is about host code — we were misled by
it first, AGENT_LOG #11). Non-inlined calls pass arguments through local memory, and the flux stores became generic
`ST`s that forced reloads after every store. Compiling the 10-module slice `m_variables_conversion … m_riemann_solvers`
as one translation unit: 0 calls, local loads 178 → 76, all stores `STG`; HLLC 18.7 → 12.9 ms/step (faster than
v4.9.3's 13.2). The slice must be closed under `use` in both directions or the build gets a module cycle.

**K2 — WENO occupancy** (`0004`, one per-file flag, disclosed). The WENO5 kernel needs 188 registers → 8 warps per SM,
latency-bound (FP64 pipe 31 %, "wait"/long-scoreboard stalls). `vector_length(64)` only raised registers to 206.
`-gpu=maxregcount:128` for `m_weno` alone gives 16 warps per SM for a few L1-resident spills. Sweep 168 / 128 / 96 →
64.0 / 63.0 / 66.5 ms per step. WENO5 25.3 → 17.9 ms per step.

**P2+P3 — no host round trip per kernel** (`0005`, 10 files, +170/−153). After P1/K4b/K2 each RK stage still launched
~100 kernels and ~45 scalar `GPU_UPDATE`s, each followed by a host sync: ~1 ms of GPU idle per stage, which does not
shrink with rank count (~20 % of a stage at 4 GPUs; trace 604253).
- First a 5-second NVHPC check (604388): after `acc_set_cuda_stream(acc_async_noval, <sync stream>)` async and
  synchronous work share one stream (0 ordering errors in 16.8 M elements); async scalar updates are staged when
  queued (0 / 20 000 wrong); update+kernel host cost 15.3 → 4.05 µs.
- Change: that alias at start-up; `GPU_ASYNC` (`'async'` on NVHPC, `None` elsewhere) on the 115 directives that run
  every stage; one `GPU_WAIT` before device buffers go to MPI. Stream order keeps everything else correct; other
  compilers and the OpenMP path generate exactly the old code.
- Same-node A/B: 4 GPUs `rdma_mpi` 18.81 → 17.71 ms (−5.8 %, every rank); 1 GPU −1.7 %.

**`rdma_mpi=T`** (MFC input parameter, disclosed): halos go GPU→GPU over NVLink (UCX `cuda_ipc`, 292 GB/s measured)
instead of through host memory. Bitwise; −27 % per step at 4 GPUs.

**T0.4 — MPI start-up** (environment, disclosed). `MPI_Init` took 1.7 s at 1 rank and ~6 s at 4 ranks because UCX
opens all 10 HCAs. Binding each rank's UCX to the HCA next to its GPU (`harness/nicbind.sh`, map from
`nvidia-smi topo -m` per job): 1 GPU wall 7.13 → 6.62 s. With host-staged halos at 4 GPUs it also made every step
4.5 % slower (UCX stripes large host messages over two rails), so it was rejected there.
With `rdma_mpi=T` the halos no longer use the HCAs, so the binding costs nothing per step: final build, 4 GPUs, same
node (606032): step 17.65 → 17.69 ms (noise), **wall 13.03 → 9.28 s (−29 %)**. It is part of the final multi-GPU
configuration together with `rdma_mpi`.

## 6. Negative results (kept, with evidence)
| Idea | Result | Job |
|---|---|---|
| NVHPC 25.9 instead of 26.3 | no gain, not bitwise | ladder row 1 |
| Compile-time `dir_idx` in HLLC (K4a) | SASS worse (255 registers) — cause was the missing inlining, fixed by K4b | ladder row 3 |
| WENO `vector_length(64/96)` | registers rose to 206, no gain | ladder row 6 |
| WENO register cap 96 | spills dominate, 66.5 ms | 602567 |
| HCOLL/UCC off | no effect on start-up | 602638/9 |
| one HCA per rank, host-staged halos | −3 s start-up, +4.5 % per step | 602770/1 |
| `ob1`/vader, UCX shm | peers unreachable in these jobs / no gain | 602704/26 |

## 7. Correctness
- Every benchmark run: final state bitwise identical to pinned v5.7.0 (`verify.json` per run).
- `./mfc.sh test` on the final series: SUITE_RESULT
- Known failures of the unmodified build (`harness/known_test_failures.txt`, each re-run on the pinned build):
  9 tests, mostly `model_eqns=3` cases with errors just above 1e-12 or nondeterministic between runs.
- Two harness holes we found and closed: `verify.py` once passed a run whose timed reps never started (it read the
  warm-up's output; AGENT_LOG #12); 1-GPU test jobs could not start 2-rank tests (fixed with MPI oversubscription;
  this also removed a wrongly "known" failure).

## 8. Why it runs at this speed now
Per-kernel ncu, same settings before and after (600146 vs 606033; clocks locked at 1.48 GHz, so durations are
inflated but ratios hold; 4 steps, kernels 140–210):

| Kernel (per call) | v5.7.0 | Final | Why |
|---|---|---|---|
| WENO5 reconstruction | 3.39–3.49 ms; 188 regs; 12 % warps active; FP64 pipe 31 % | **2.34–2.56 ms**; 128 regs; 24 %; FP64 pipe 42–46 % | K2: occupancy doubled; the spills (3.4–4.8·10⁷ local ops) hit L1 |
| HLLC | 2.13–2.48 ms; FP64 pipe 9–10 % | **1.57–1.62 ms**; FP64 pipe 13 % | K4b: helpers inlined, no local-memory traffic |
| Copy-like (pack, finalize, flux difference, RK update, conversion) | 0.72–1.19 ms; 1.2–1.8 TB/s (25–37 % of HBM peak); SM 64–74 % busy | unchanged | not touched: instruction-bound index arithmetic |
| All listed kernels | 35.10 ms | **28.20 ms (−19.7 %)** | |

WENO5 is still latency-bound below the FP64 roof, and the copy-like kernels reach a third of HBM bandwidth because the
SMs are busy with index arithmetic, not memory. Both are the next single-GPU targets.
- 1 GPU: after P3 the host gaps inside the reconstruction and Riemann ranges are 0.002–0.012 ms per stage (trace
  604667), so kernel time is the step time. Kernel time (sc26 profile 602705) is in WENO5 (29 %), HLLC (21 %), the
  WENO input pack (10 %; removed by NTHU's open PR #2092, not ours to claim) and bandwidth-bound copies (40 %).
- 8 GPUs: 10.2 ms per step, 76 % strong-scaling efficiency; the median halo exchange is 0.72 ms per stage (606019),
  as 6 sequential, blocking `MPI_Sendrecv`s with no compute overlap.
- Wall time of a 30-step run is dominated by MPI start-up and shutdown (≈7.5 s at 4 ranks, ~17 s at 8), which no
  per-step optimization touches.

## 9. What we would do next
1. Overlap the halo exchange with interior compute (now possible: P3 removed the host syncs that would have eaten
   the overlap).
2. Fuse or skip the bandwidth-bound copies (40 % of kernel time), e.g. extend the #2087 pattern.
3. Submit P1/K4b/P3 upstream as three small PRs (K2 is a flag; K4b a CMake change).

## 10. Reproduce
REPRODUCE
