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
| **total** | **−18.3 % (1.22×)** | **−18.3 %** | −14 % | | |

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

**Rejected, with evidence.**
- NVHPC 25.9: no gain, not bitwise.
- Compile-time `dir_idx` in HLLC: the SASS got worse (255 registers).
- WENO `vector_length` 64/96.
- WENO cap at 96.

## Correctness
- **Benchmark output.** Every rung is bitwise identical to the pinned-v5.7.0 reference (`harness/verify.py`).
- **K4b tests** (generic build, `./mfc.sh test`):
  - A 15 % sample, plus all HLL / HLLD / `mpp_lim` / surface-tension cases.
  - The only failures are 4 tests that fail identically on the unmodified build (`harness/known_test_failures.txt`).
- **K2 tests:** pending (WENO3/5/7, mapped, WENO-Z, TENO, mp-WENO plus a 15 % sample).
- **Before an upstream PR:** the full suite.

## Where the time is now (K4b profile, 69.6 ms of kernels per step; K2 profile pending)
| Kernel | ms/step | Share | Note |
|---|---|---|---|
| WENO5 reconstruction | 25.4 | 36 % | K2 targets it (16 warps) |
| HLLC | 12.9 | 18 % | 146–152 registers |
| WENO input pack | 6.0 | 9 % | removed by NTHU's #2092 (not ours to claim) |
| RK update, advection source, conversion, finalize | ~20 | 29 % | bandwidth-bound copies (#2087 pattern) |

## Next
1. **Start-up.** Wall time is 6.9 s, of which only 2 s is time stepping (T0.4: environment only).
2. **Multi-GPU re-measure.** Rerun 4 and 8 GPUs for P1+K4b+K2 to report strong-scaling efficiency next to time to
   solution. Faster kernels lower the efficiency, as #2093 showed. The 8-GPU runs need the user's OK.
3. **Remaining host-launch gaps (P2/P3).** These matter more at 8 GPUs, where kernels are short.
