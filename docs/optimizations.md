# MFC on H200: optimizations so far

Case: `examples/3D_performance_test` (201³, 5-equation 2-fluid, WENO5 + HLLC, RK3, 30 steps), case-optimized build,
NVHPC 26.3, 1× H200 unless noted. Code: branch `sc26` on nano4 (`mfc-sc26`), exported as `patches/opt/0001…0004`.
Every number below cites a job; details and rejected variants are in `docs/ladder.md`.

## Result (1 GPU)
| Rung | Step, median | Grind (ns/gp/eq/rhs) | Wall | Final state | Job |
|---|---|---|---|---|---|
| v5.7.0 baseline | 77.06 ms | 0.3982 | 8.07 s | reference | 600407 |
| + P1 CBC async | 75.98 ms | 0.3933 | ~8.0 s | bitwise | 601152 |
| + K4b Riemann unity build | 70.42 ms | 0.3632 | 7.33 s | bitwise | 602474 |
| + K2 WENO register cap 128 | **62.99 ms** | **0.3255** | 6.9 s | bitwise | 602559 |
| = clean series `sc26` (canonical) | 62.91 ms | 0.3248 | 7.13 s | bitwise | 602728 |
| + T0.4 UCX on the GPU's own HCA (env, 1 GPU) | 63.00 ms | 0.3249 | **6.62 s** | bitwise | 602727 |
| **total** | **−18.3 % (1.22×)** | **−18.4 %** | **−18 %** | | |

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
- *Not at multi-GPU.* At 4 GPUs it saves 3.1 s of start-up but makes every step 1.2 ms (4.5 %) slower, on every rank
  and on two nodes. Default UCX stripes large messages over two rails. Break-even is ≈ 2700 steps, shorter than a
  production run, so multi-GPU keeps the default.

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
- **Before an upstream PR:** the full suite.

## Where the time is now (sc26 profile, 62.1 ms of kernels per step, job 602705)
| Kernel | ms/step | Share | Note |
|---|---|---|---|
| WENO5 reconstruction (3 directions) | 17.9 | 29 % | was 25.3 before K2 |
| HLLC | 12.9 | 21 % | 146–152 registers |
| WENO input pack | 6.0 | 10 % | removed by NTHU's #2092 (not ours to claim) |
| RK update, advection source, conversion, finalize | ~25 | 40 % | bandwidth-bound copies (#2087 pattern) |

## 4 GPUs (201³ strong, host-staged halos)
| Build | Step, median | Grind | Wall | Job |
|---|---|---|---|---|
| v5.7.0 baseline | — | 0.1534 / 0.1626 (2 reps) | 12.9 / 14.3 s | 600173 |
| sc26 | 26.55 ms | 0.1325 (median of 3) | 12.44 s | 602703 (hgpn003) |
| sc26 | 25.72 ms | 0.1377 (median of 3) | 13.07 s | 602770 (hgpn013) |

- Strong-scaling efficiency 1 → 4 GPUs: 62.9 / (4 × 25.7–26.6) = **59–61 %**. Communication is 2.6–3.1 ms per step.
- About 7.5 s of the 12–13 s wall is MPI start-up and finalize (5.9–6.4 s `MPI_Init` and 1.2 s `MPI_Finalize` at 4 ranks), so in a
  30-step run the wall is mostly start-up.
- The baseline has only 2 reps and no per-step data. A same-node baseline with ≥5 reps is needed for a final speedup claim.

## Next
1. **Same-node 4/8-GPU comparison** of baseline vs sc26, ≥5 reps. The 8-GPU runs need the user's OK.
2. **Remaining host-launch gaps (P2/P3).** These matter more at 8 GPUs, where kernels are short.
3. **Bandwidth-bound copies** (40 % of kernel time): fuse or skip them where the data is already in place.
