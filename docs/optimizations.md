# MFC on H200: optimizations so far

Case: `examples/3D_performance_test` (201³, 5-equation 2-fluid, WENO5 + HLLC, RK3, 30 steps), case-optimized build,
NVHPC 26.3, 1× H200 unless noted. Code: branch `p3` on nano4 (`mfc-p3` = `sc26` + P3), exported as `patches/opt/0001…0005`.
Every number below cites a job; details and rejected variants are in `docs/ladder.md`.

## Final, same node per row (the report's headline; `report.md` §1)
| GPUs | v5.7.0 step | Final step | Speedup | Jobs |
|---|---|---|---|---|
| 1 | 76.74 ms | 61.88 ms | 1.24× | 606017 |
| 4, both `rdma_mpi` | 23.10 ms | 17.72 ms | 1.30× | 606018 |
| 8, v5.7.0 default vs final `rdma_mpi` | 21.94 ms | 10.22 ms | 2.15× | 605963/606019 |

## Result (1 GPU, rung by rung)
| Rung | Step, median | Grind (ns/gp/eq/rhs) | Wall | Final state | Job |
|---|---|---|---|---|---|
| v5.7.0 baseline | 77.06 ms | 0.3982 | 8.07 s | reference | 600407 |
| + P1 CBC async | 75.98 ms | 0.3933 | ~8.0 s | bitwise | 601152 |
| + K4b Riemann unity build | 70.42 ms | 0.3632 | 7.33 s | bitwise | 602474 |
| + K2 WENO register cap 128 | **62.99 ms** | **0.3255** | 6.9 s | bitwise | 602559 |
| = clean series `sc26` (canonical) | 62.91 ms | 0.3248 | 7.13 s | bitwise | 602728 |
| + T0.4 UCX on the GPU's own HCA (env, 1 GPU) | 63.00 ms | 0.3249 | **6.62 s** | bitwise | 602727 |
| + P3 async per-stage kernels (same-node A/B vs sc26: 62.87 → 61.79 ms) | **61.79 ms** | **0.3200** | — | bitwise | 604561 |
| **total** | **−19.8 % (1.25×)** | **−19.6 %** | **−18 %** | | |

The official MFC table lists 0.38 ns for H100 SXM. That number uses a different metric (v4.9.3, `s_compute_rhs` only,
`cpu_time`, ghost cells counted), see `baseline/README.md`. Same-metric comparisons are within this table only.

## What and why

**P1: CBC without host round trips** (`m_cbc.fpp`, 46 lines).
- *Evidence.* A timeline trace showed that each `s_cbc` call issued about 12 tiny kernels and 5 scalar updates, each
  followed by `cuStreamSynchronize`: about 230 µs of launch and sync gaps per call.
- *Change.* Queue them on the OpenACC async queue and wait once, before the fluxes are read. The OpenMP path is
  unchanged.
- *Effect.* −1.4 % at 1 GPU, −2.3 % at 4 GPUs. The gain grows with rank count, because the rank with the most CBC
  faces sets the pace.

**K4b: let the compiler inline the Riemann helpers** (CMake only, plus a 3-line cleanup).
- *Evidence.* The HLLC kernel was 42 % slower than in v4.9.3. ncu showed more local-memory than global traffic, and
  long-scoreboard stalls. Its PTX had 9 `.extern .func` calls (`s_compute_mixture_coefficients`,
  `s_compute_speed_of_sound`, `s_compute_average_state`, …).
- *Cause.* nvfortran inlines device routines only within one source file. `-Minfo`'s "cross-inlined" refers to host
  code. The call arguments therefore lived in local memory, and the flux stores became generic `ST`s that forced
  reloads after every store.
- *Change.* Compile the 10-module slice `m_variables_conversion … m_riemann_solvers` as one translation unit.
- *Effect on the kernel.* 0 calls, local loads 178 → 76, all stores now global `STG`.
- *Effect on time.* HLLC 18.7 → 12.9 ms/step, now faster than v4.9.3's 13.2.

**K2: WENO occupancy** (one per-file flag).
- *Evidence.* The WENO5 reconstruction kernel uses 188 registers, so only 8 warps per SM are resident. It is
  latency-bound: FP64 pipe 32 % busy, mostly "wait" and long-scoreboard stalls.
- *Why not the launch shape.* `vector_length(64)` just raised the register count to 206.
- *Change.* `-gpu=maxregcount:128` for `m_weno` only gives 16 warps per SM, at the cost of a few L1-resident spills.
- *Sweep.* 168 → 64.0 ms, 128 → 63.0 ms, 96 → 66.5 ms, so 96 spills too much.
- *Disclosure.* This is a compiler-flag change, so it is disclosed.

**T0.4: MPI start-up** (environment only, 1 GPU).
- *Evidence.* `MPI_Init` alone took 1.70 s of the 1-rank wall time (nsys). A bare `MPI_Init` timer
  (`harness/src/mpiinit.c`) showed the cost is UCX opening all 10 HCAs of the node; HCOLL/UCC off changed nothing.
- *Change.* `harness/nicbind.sh` sets `UCX_NET_DEVICES` to the HCA next to each rank's GPU (read from
  `nvidia-smi topo -m` per job). Wall 7.13 → 6.62 s at 1 GPU, step time unchanged.
- *Host-staged multi-GPU: no.* At 4 GPUs it saves 3.1 s of start-up but makes every step 1.2 ms (4.5 %) slower,
  on every rank and on two nodes: default UCX stripes large host messages over two rails.
- *With `rdma_mpi`: yes.* Halos then go over NVLink, not the HCAs. Final build, 4 GPUs, same node (606032): step
  17.65 → 17.69 ms (noise), wall 13.03 → 9.28 s (−29 %).

**P2+P3: no host round trip per kernel** (`patches/opt/0005`, 10 files, +170/−153).
- *Evidence.* Each RK stage launched ~100 kernels and ~45 scalar `GPU_UPDATE`s, each followed by a host sync: ~1 ms of
  GPU idle per stage. That cost does not shrink with more GPUs, so it was ~20 % of a stage at 4 GPUs (trace 604253).
- *Check first.* A 5-second NVHPC test (604388) showed: after `acc_set_cuda_stream(acc_async_noval, <sync stream>)`,
  async and synchronous work run in issue order on one stream; async scalar updates are staged when queued; an
  update+kernel pair drops from 15.3 to 4.05 µs of host time.
- *Change.* The alias at start-up, and `GPU_ASYNC` (`'async'` on NVHPC, `None` elsewhere) on the 115 directives that run
  every stage: WENO, Riemann state/HLLC, flux differences, conversion, boundaries, halo pack/unpack, RK update. One wait
  before device buffers go to MPI. Other compilers and the OpenMP path generate the same code as before.
- *Effect (same node, A/B).* 4 GPUs with `rdma_mpi`: step 18.81 → 17.71 ms (−5.8 %, every rank). 1 GPU: −1.7 %.
- *Not covered.* NVHPC unified-memory builds (`--unified`, GH200) are untested with this change.

**Rejected, with evidence.**
- NVHPC 25.9: no gain, not bitwise.
- Compile-time `dir_idx` in HLLC: the SASS got worse (255 registers).
- WENO `vector_length` 64/96.
- WENO cap at 96.
- One HCA per rank at multi-GPU (above). `ob1`/vader: peers unreachable in these jobs. UCX shared memory
  (`UCX_POSIX_USE_PROC_LINK=n`): works, no gain.

## Correctness
- **Benchmark output.** Every rung is bitwise identical to the pinned-v5.7.0 reference (`harness/verify.py`).
- **K4b tests** (generic build, `./mfc.sh test`):
  - A 15 % sample, plus all HLL / HLLD / `mpp_lim` / surface-tension cases.
  - The only failures are 4 tests that fail identically on the unmodified build (`harness/known_test_failures.txt`).
- **K2 tests** (generic build):
  - All 33 WENO-variant cases pass: WENO3/5/7, mapped, WENO-Z, TENO, mp-WENO (602632).
  - A 15 % sample: 102 of 106 pass (602634). Of the 4 failures, 2F35A1FE was already known to vary between runs;
    FD891191 and 1843DA80 fail identically on the unmodified build (602681/602682); 0DDE8A87 had too few MPI slots.
  - The 1-GPU test job now allows MPI oversubscription. With it, 0DDE8A87 and AFBACA70 pass on both builds;
    AFBACA70 had been wrongly listed as a known failure.
- **P3 tests** (generic build):
  - 33 WENO variants plus all 8 multi-rank MPI tests: 41/41 pass (604600).
  - All 19 chemistry tests: 19/19 (604755).
  - A 15 % sample: 100/106 (604601). Five failures were chemistry cases whose binaries had not been built; they now
    pass. The sixth, 1843DA80, fails identically on the unmodified build.
- **Before an upstream PR:** the full suite.

## Where the time is now (sc26 profile, 62.1 ms of kernels per step, job 602705)
| Kernel | ms/step | Share | Note |
|---|---|---|---|
| WENO5 reconstruction (3 directions) | 17.9 | 29 % | was 25.3 before K2 |
| HLLC | 12.9 | 21 % | 146–152 registers |
| WENO input pack | 6.0 | 10 % | removed by NTHU's #2092 (not ours to claim) |
| RK update, advection source, conversion, finalize | ~25 | 40 % | bandwidth-bound copies (#2087 pattern) |

## 4 GPUs (201³ strong)
| Build | Halo exchange | Step, median | Grind | Job |
|---|---|---|---|---|
| v5.7.0 baseline | host-staged | — (2 reps, no per-step data) | 0.1534 / 0.1626 | 600173 |
| sc26 | host-staged | 25.72 ms | 0.1377 | 602770 |
| sc26 | `rdma_mpi=T` | 18.81 ms | 0.0969 | 604560 a1 |
| sc26 + P3 | `rdma_mpi=T` | **17.71 ms** | **0.0914** | 604560 b1 |

- `rdma_mpi=T` is an MFC input parameter: halos go GPU to GPU over NVLink instead of through host memory. Same
  numerics, bitwise output, −27 % per step at 4 GPUs. It is our multi-GPU configuration (disclosed).
- Strong-scaling efficiency 1 → 4 GPUs with P3 and `rdma_mpi`: 61.8 / (4 × 17.7) = **87 %**
  (host-staged sc26: 61 %).
- In a 30-step run, MPI start-up and finalize (~7.5 s) dominate the 12 s wall at 4 GPUs.
- A 4-GPU trace on node hgpn012 (604667) showed one GPU uniformly 20 % slower in every kernel. The A/B runs on hgpn020
  show balanced ranks (RHS 5.35–5.37 ms) at equal clocks, so this is a node anomaly, not load imbalance.
- The baseline has 2 reps and no per-step data; the final comparison needs a same-node baseline with ≥5 reps.

## Next
1. **8-GPU confirmation, same node:** baseline vs final, host-staged vs `rdma_mpi`, ≥5 reps. Needs the user's OK.
2. **Full `./mfc.sh test`** of the final series (SC26 requirement for `src/` changes).
3. **Report:** scaling plots, roofline and achieved HBM bandwidth per kernel, `harness/run_all.sh` from a clean tree.
