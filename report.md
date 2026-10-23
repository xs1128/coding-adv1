# MFC on NCHC nano4 H200 — making an SC26 application faster without changing its answer

Coding-Adv-HW-1. Application: **MFC v5.7.0** (`0b3d56c`), the SC26 SCC application, on nano4 (H200).
Every number in this report cites a Slurm job and a path under `results/`. Changes to MFC are the patch series
`patches/opt/0001…0005` (branch `p3` on nano4). The per-rung detail, including all rejected variants, is in
`docs/ladder.md`, and agent mistakes are in `AGENT_LOG.md`.

## 1. Result

Same node per row, outputs bitwise identical to unmodified v5.7.0. Step = median NVTX step time (steps 2–30) of the
slowest rank, from one NVTX-profiled rep after the timed ones; grind = MFC's ns / grid point / equation / RHS, median
of the 5 timed reps.

| GPUs | v5.7.0 step | Final step | Speedup | v5.7.0 grind | Final grind | Jobs |
|---|---|---|---|---|---|---|
| 1 | 76.74 ms | **61.88 ms** | **1.24×** | 0.3973 | 0.3201 | 606017 |
| 4 (both `rdma_mpi`) | 23.10 ms | **17.72 ms** | **1.30×** | 0.1184 | 0.0913 | 606018 |
| 8 (v5.7.0 default vs final) | 21.94 ms | **10.22 ms** | **2.15×** | 0.1129 | 0.0527 | 605963 / 606019 |

![Same-node step times](docs/fig/scaling.png)

Strong-scaling efficiency of the final build (step time): 87 % at 4 GPUs and 76 % at 8 GPUs. v5.7.0 at its default
settings reaches 44 % at 8 GPUs.

The 4-GPU row isolates the source changes. The 1-GPU final run was also launched with the start-up fix (T0.4,
`nicbind.sh`), which changes wall time, not step time. The 8-GPU row compares v5.7.0 at its defaults with the final
configuration (`rdma_mpi=T`); the like-for-like 8-GPU v5.7.0 `rdma_mpi` arm of the plan was not run (an agent bug,
AGENT_LOG #14, used the budget). As a cross-job reference only, v5.7.0 with `rdma_mpi` measured 16.5 ms per step at
8 GPUs in the profiling phase (nsys, 10 steps; `docs/profiling-baseline.md`). The 4- and 8-GPU final runs used default
UCX, not `nicbind.sh`. Nothing changes the physics, the numerics, the grid, the step count or FP64.

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
- **1 GPU:** 77.06 ms per step (600407), GPU busy 96 % of a stage (nsys 600140). WENO5 34 %, HLLC 25 %, copy-like
  kernels ≈25 % at ~30 % of HBM bandwidth (ncu 600146; `docs/profiling-baseline.md`).
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
| P1 CBC async | 75.98 ms | 0.3935 | 601152 |
| K4b Riemann unity build (13-module slice; the final 10-module slice: 70.00 ms, 602531) | 70.42 ms | 0.3632 | 602474 |
| K2 WENO register cap | 62.99 ms | 0.3255 | 602559 |
| P3 async per-stage kernels (same-node A/B 62.87 → 61.79) | 61.79 ms | 0.3201 | 604561 |

![Ladder at 1 GPU](docs/fig/ladder_1g.png)

**P1 — CBC without host round trips** (`0001`, `m_cbc.fpp`, +50/−44). Each characteristic-boundary call issued ~12
small kernels and 5 scalar updates, each followed by a host sync (~230 µs per call). Queue them async, wait once.
−1.4 % at 1 GPU, −2.3 % at 4 GPUs (601183 vs 601184, `rdma_mpi`, different nodes); the gain grows with rank count because the rank with the most CBC faces sets the
pace.

**K4b — let the compiler inline the Riemann helpers** (`0002`+`0003`, CMake + 3 lines). HLLC was 42 % slower than in
v4.9.3. ncu: more local-memory than global traffic. The PTX had 9 `.extern .func` calls: nvfortran inlines `acc routine
seq` device routines only within one source file (`-Minfo`'s "cross-inlined" is about host code — we were misled by
it first, AGENT_LOG #11). Non-inlined calls pass arguments through local memory, and the flux stores became generic
`ST`s that forced reloads after every store. Compiling the module slice `m_variables_conversion … m_riemann_solvers` as
one translation unit (first 13 modules, 602474; 10 after dropping three unused `use`s, 602531, same speed): 0 calls, local loads 178 → 76, all stores `STG`; HLLC 18.7 → 12.9 ms/step (faster than
v4.9.3's 13.2). The slice must be closed under `use` in both directions or the build gets a module cycle.

**K2 — WENO occupancy** (`0004`, one per-file flag, disclosed). The WENO5 kernels need 188–196 registers → 8 warps per SM,
latency-bound (FP64 pipe 31 %, "wait"/long-scoreboard stalls). A compile check of `vector_length(64)` / `(96)` raised
registers to 206 / 192 (`results/k2/kcheck_vector_length.txt`), so it could not raise occupancy and was not timed.
`-gpu=maxregcount:128` for `m_weno` alone gives 16 warps per SM for a few L1-resident spills. Sweep 168 / 128 / 96 →
64.0 / 63.0 / 66.5 ms per step. WENO5 25.4 → 18.0 ms per step (nsys 602481 → 602705).

**P2+P3 — no host round trip per kernel** (`0005`, 10 files, +170/−153). After P1/K4b/K2 each RK stage still launched
44–68 kernels (depending on the rank's boundaries) and ~45 scalar `GPU_UPDATE`s, each followed by a host sync:
~1.2 ms of GPU idle per stage, which does not shrink with rank count (18–19 % of a stage at 4 GPUs; trace 604253).

- First a 5-second NVHPC check (604388): after `acc_set_cuda_stream(acc_async_noval, <sync stream>)` async and
  synchronous work share one stream (0 ordering errors in 16.8 M elements); async scalar updates are staged when
  queued (0 / 20 000 wrong); update+kernel host cost 15.3 → 4.05 µs.
- Change: that alias at start-up; `GPU_ASYNC` (`'async'` on NVHPC, `None` elsewhere) on the 115 directives that run
  every stage; one `GPU_WAIT` before device buffers go to MPI. Stream order keeps everything else correct; other
  compilers and the OpenMP path generate exactly the old code.
- Same-node A/B: 4 GPUs `rdma_mpi` 18.81 → 17.71 ms (−5.8 %, every rank); 1 GPU −1.7 %.

**`rdma_mpi=T`** (MFC input parameter, disclosed): halos go GPU→GPU over NVLink (UCX `cuda_ipc`, 292 GB/s measured)
instead of through host memory. Bitwise; −27 % per step at 4 GPUs (sc26 build, 602770 host-staged vs 604560
`rdma_mpi`, different nodes).

**T0.4 — MPI start-up** (environment, disclosed). `MPI_Init` took 1.7 s at 1 rank (nsys 602481) and 5.8–6.5 s at 4 ranks
(bare `MPI_Init` timer, 602722/602764) because UCX opens all 10 HCAs. Restricting UCX to one HCA cut 1-GPU wall
7.13 → 6.62 s (602728 vs 602727, fixed `mlx5_0`, different nodes). `harness/nicbind.sh` generalises this: each rank
uses the HCA next to its GPU (map from `nvidia-smi topo -m` per job). With host-staged halos at 4 GPUs it also made every step
4.5 % slower (UCX stripes large host messages over two rails), so it was rejected there.
With `rdma_mpi=T` the halos no longer use the HCAs, so the binding costs nothing per step: final build, 4 GPUs, same
node (606032): step 17.65 → 17.69 ms (noise), **wall 13.03 → 9.28 s (−29 %)**. It is part of the final multi-GPU
configuration together with `rdma_mpi`.

## 6. Negative results (kept, with evidence)
| Idea | Result | Job |
|---|---|---|
| NVHPC 25.9 instead of 26.3 | no gain, not bitwise | ladder row 1 |
| Compile-time `dir_idx` in HLLC (K4a) | SASS worse (255 registers) — cause was the missing inlining, fixed by K4b | ladder row 3 |
| WENO `vector_length(64/96)` | registers rose to 206 / 192 in a compile check; not timed | `results/k2/kcheck_vector_length.txt` |
| WENO register cap 96 | spills dominate, 66.5 ms | 602567 |
| HCOLL/UCC off | no clear effect: wall 7.28 → 6.81 s, inside the control's 6.77–7.74 s spread; bare `MPI_Init` 1.97 → 1.94 s | 602638/9, 602683 |
| one HCA per rank, host-staged halos | −3 s start-up, +4.5 % per step | 602770/1 |
| `ob1`/vader, UCX shm | peers unreachable in these jobs / no gain | 602704/26 |

## 7. Correctness
- Every benchmark run: final state bitwise identical to pinned v5.7.0 (`verify.json` per run).
- **Full `./mfc.sh test` on the final series** (all 752 tests that `./mfc.sh test -l` lists, 8 shards, jobs 606006
  and 606008–606014; generic build plus the 6 chemistry variants; 713 ran, MFC skips the rest for this build): **690 pass, 23 fail, 0 new failures** (`verify.py --test-summary`: PASS).
- All 23 failures fail **identically on unmodified v5.7.0** in this environment: each was re-run on the pinned build
  (606331 for the 14 found by the full suite; earlier rechecks for the other 9). The 14 were re-run on the final
  build too (606332), with identical errors. They are 17 `model_eqns=3` / viscous IBM cases (errors from just above
  1e-12 up to O(1)), five examples (vacuum, vacuum_restart, rayleigh_taylor, isentropicvortex, recovering_sphere) and
  one reactive-burn case that does not start. The list,
  with the error of each, is `harness/known_test_failures.txt`. One of them (isentropicvortex) reports a different
  first failing variable from run to run on both builds.
- What this means: the final series changes no test outcome. It does not mean v5.7.0's suite is clean on NVHPC 26.3 /
  H200 — 23 tests already fail before our changes, which we report rather than hide.
- Two harness holes we found and closed: `verify.py` once passed a run whose timed reps never started (it read the
  warm-up's output; AGENT_LOG #12); 1-GPU test jobs could not start 2-rank tests (fixed with MPI oversubscription;
  this also removed a wrongly "known" failure).

## 8. Why it runs at this speed now
Per-kernel ncu, same settings before and after (600146 vs 606033; clocks locked at 1.48 GHz, so durations are
inflated but ratios hold; 4 steps, kernels 140–210):

| Kernel (per call) | v5.7.0 | Final | Why |
|---|---|---|---|
| WENO5 reconstruction | 3.39–3.49 ms; 188–196 regs; 12 % warps active; FP64 pipe 31 % | **2.34–2.56 ms**; 128 regs; 24 %; FP64 pipe 42–46 % | K2: occupancy doubled; the spills (3.4–4.8·10⁷ local ops) hit L1 |
| HLLC | 2.13–2.48 ms; FP64 pipe 9–10 % | **1.57–1.62 ms**; FP64 pipe 13 % | K4b: helpers inlined; local-load instructions in SASS 178 → 76 |
| Copy-like (pack, finalize, flux difference, RK update, conversion) | 0.72–1.19 ms; 1.2–1.8 TB/s (24–37 % of DRAM peak); SM 64–74 % busy (conversion: 44 %) | unchanged | not touched: instruction-bound index arithmetic |
| All listed kernels | 35.10 ms | **28.20 ms (−19.7 %)** | |

![Kernel time by role](docs/fig/kernels_1g.png)

WENO5 is still latency-bound below the FP64 roof, and the copy-like kernels reach a third of HBM bandwidth because the
SMs are busy with index arithmetic, not memory. Both are the next single-GPU targets.

- After P3 the host gaps inside the reconstruction and Riemann ranges are 0.002–0.012 ms per stage (4-GPU trace
  604667, rank 0), so on the compute side kernel time is the step time. Kernel time (sc26 profile 602705) is in WENO5 (29 %), HLLC (21 %), the
  WENO input pack (10 %; removed by NTHU's open PR #2092, not ours to claim) and bandwidth-bound copies (40 %).
- 8 GPUs: 10.2 ms per step, 76 % strong-scaling efficiency; the halo exchange takes 0.36–0.72 ms per stage depending on the
  rank (606019), as 6 sequential, blocking `MPI_Sendrecv`s with no compute overlap.
- Wall time of a 30-step run is mostly fixed cost, which no per-step optimization touches: at 4 GPUs 15.9 s of wall
  for 0.6 s of stepping (606018), of which `MPI_Init` + `MPI_Finalize` are ≈7.2 s (bare timer 602722); at 8 GPUs
  19.6 s of wall for 0.3 s of stepping (606019). `nicbind.sh` removes 3.8 s at 4 GPUs (606032); at 8 GPUs it is
  untested.

## 9. What we would do next
1. Overlap the halo exchange with interior compute (now possible: P3 removed the host syncs that would have eaten
   the overlap).
2. Fuse or skip the bandwidth-bound copies (40 % of kernel time), e.g. extend the #2087 pattern.
3. Submit P1/K4b/P3 upstream as three small PRs (K2 is a flag; K4b a CMake change).

## 10. Reproduce
On nano4, from a clone of this repository mirrored to `/work/u1131128/coding-adv1`:
```
bash harness/reproduce.sh build    # v5.7.0 + patches/opt/0001-0005, case-opt + generic builds
bash harness/reproduce.sh run      # the final 1/4/8-GPU same-node sets (harness/specs/final_*g.tsv)
bash harness/reproduce.sh verify   # bitwise gate + median step per run
```
The patch series applied to v5.7.0 gives a tree identical to the one measured here (checked: empty diff against
branch `p3`). Multi-GPU runs with `rdma_mpi` add `WRAP=$ROOT/harness/nicbind.sh` for the start-up fix (T0.4).
