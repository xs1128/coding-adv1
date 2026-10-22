# Optimization ladder

One row per experiment, newest last. Baseline: `results/base/official_1g` (job 600407, v5.7.0, NVHPC 26.3,
1 H200, 0.3982 ns, step 77.06 ms). "Kept" means the change goes into the next rung.

| # | Item | Change | Job(s) | Result (1 GPU unless noted) | Verify | Kept |
|---|---|---|---|---|---|---|
| 1 | T0.5 | NVHPC 25.9 instead of 26.3 (same source, `mfc-nv259`) | 601138 `results/t0/nvhpc259_1g` | grind 0.3977 (−0.1 %, noise), step 76.93 ms; wall 13.8–22.8 s vs 8.1 s (HPC-X 2.24 start-up) | not bitwise (max rel 6.3e-8) | no |
| 2 | P1 | CBC kernels + scalar updates on the OpenACC async queue, one wait per `s_cbc` (`patches/opt/0001-cbc-async.patch`, 1 file) | 601152 `results/p1/cbc_async_1g`, trace 601153, tests 601171 | grind 0.3933 (−1.2 %), step 75.98 ms (−1.4 %); CBC-range host gaps 0.83 → 0.44 ms/stage (`harness/range_gaps.py`) | bitwise ✓; 25/25 CBC tests (bc −5…−12, 1D/2D/3D) pass | yes |
| 2b | P1 @ 4 GPUs | same, `rdma_mpi=T`, 201³ strong, 2×2×1 (ranks have 1–3 CBC faces) | base 601183 `results/p1/base_4g_rdma` vs 601184 `results/p1/cbc_async_4g_rdma` (different nodes) | step 22.95 → 22.41 ms (−2.3 %), grind 0.1187 → 0.1151 (−3.0 %); rank-0 comm wait 0.63 → 0.47 ms | bitwise ✓ both | yes |
| 3 | K4a | 5-eq HLLC: runtime `dir_idx(k)` → compile-time `dir_idx_c(k, NORM_DIR)` (`patches/opt/exp-k4a-hllc-dir-idx-const.patch`) | none (screened with `tools/kcheck.sh`, no GPU) | SASS worse: 255 regs (was 127–160), LDL 226 / STL 156 (was 178 / 48), 2× instructions | — | no |

### K4 diagnosis (HLLC, 1.88–2.19 ms/call vs 1.46 in v4.9.3)
- ncu (job 600146): 18.75 % occupancy (160 regs), long-scoreboard stalls; **local-memory traffic exceeds global**
  (182 M ld + 110 M st sectors vs 128 M + 53 M); 35 M local st sectors miss to DRAM → DRAM writes 2.1 GB vs 1.1 GB read.
- Cause: nvfortran does not inline `acc routine seq` helpers across source files into device code (#2094). The PTX of the
  5-eq kernel has 9 `.extern .func` calls (`s_compute_mixture_coefficients`, `s_compute_speed_of_sound`,
  `s_compute_energy`, `s_compute_average_state`, ...) even where `-Minfo` says "cross-inlined" (that is host code).
  Their by-reference arguments live in local memory; flux stores become generic `ST` that may alias them, so after every
  store the kernel reloads `dir_idx`, the flux descriptor and the local scalars (SASS at `m_riemann_solver_hllc.fpp:1208`).
- Same-file helpers are inlined (micro test `kcheck/micro2.f90`). Compiling the HLLC file together with the helper
  modules in one translation unit gives: 150 regs, LDL 76 / STL 8, generic ST 0 (all `STG`). → K4b.
