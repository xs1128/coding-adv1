# Optimization ladder

One row per experiment, newest last. Baseline: `results/base/official_1g` (job 600407, v5.7.0, NVHPC 26.3,
1 H200, 0.3982 ns, step 77.06 ms). "Kept" means the change goes into the next rung.

| # | Item | Change | Job(s) | Result (1 GPU unless noted) | Verify | Kept |
|---|---|---|---|---|---|---|
| 1 | T0.5 | NVHPC 25.9 instead of 26.3 (same source, `mfc-nv259`) | 601138 `results/t0/nvhpc259_1g` | grind 0.3977 (−0.1 %, noise), step 76.93 ms; wall 13.8–22.8 s vs 8.1 s (HPC-X 2.24 start-up) | not bitwise (max rel 6.3e-8) | no |
| 2 | P1 | CBC kernels + scalar updates on the OpenACC async queue, one wait per `s_cbc` (`patches/opt/0001-cbc-async.patch`, 1 file) | 601152 `results/p1/cbc_async_1g`, trace 601153, tests 601171 | grind 0.3933 (−1.2 %), step 75.98 ms (−1.4 %); CBC-range host gaps 0.83 → 0.44 ms/stage (`harness/range_gaps.py`) | bitwise ✓; 25/25 CBC tests (bc −5…−12, 1D/2D/3D) pass | yes |
| 2b | P1 @ 4 GPUs | same, `rdma_mpi=T`, 201³ strong, 2×2×1 (ranks have 1–3 CBC faces) | base 601183 `results/p1/base_4g_rdma` vs 601184 `results/p1/cbc_async_4g_rdma` (different nodes) | step 22.95 → 22.41 ms (−2.3 %), grind 0.1187 → 0.1151 (−3.0 %); rank-0 comm wait 0.63 → 0.47 ms | bitwise ✓ both | yes |
| 3 | K4a | 5-eq HLLC: runtime `dir_idx(k)` → compile-time `dir_idx_c(k, NORM_DIR)` (`patches/opt/exp-k4a-hllc-dir-idx-const.patch`) | none (screened with `tools/kcheck.sh`, no GPU) | SASS worse: 255 regs (was 127–160), LDL 226 / STL 156 (was 178 / 48), 2× instructions | — | no |
| 4 | K4b | **Unity build**: compile the module slice `m_variables_conversion` … `m_riemann_solvers` (13 modules) as one source on NVHPC GPU builds so device helpers inline into the Riemann kernels; CMake only, no Fortran change (`patches/opt/0002-riemann-unity-build.patch`, mfc-opt `32ec527`) | 602474 `results/k4/unity_1g`, nsys 602481 `results/prof/nsys_unity_1g_30` | grind **0.3632** (−7.7 % vs P1, −8.8 % vs baseline), step **70.42 ms** (−7.3 % / −8.6 %), wall 7.33 s; HLLC kernels 18.71 → **12.88 ms/step** (−31 %, v4.9.3: 13.2), WENO unchanged; HLLC SASS: 0 calls, LDL 178 → 76, generic ST 62 → 0 | **bitwise** ✓; tests: pending (602483–602487) | yes |
| 5 | K2-prep | Drop unused `use m_variables_conversion` from `m_weno`, `m_muscl`, `m_surface_tension` → unity slice shrinks to 10 modules (WENO compiled on its own again) | 602531 `results/k2/cap255_1g` | grind 0.3620, step 70.00 ms (= K4b, noise) | bitwise ✓ | yes |
| 6 | K2 | Per-file `-gpu=maxregcount:N` for `m_weno` only (NVHPC GPU): WENO-5 kernel 188 regs → 8 warps/SM. Sweep: 168 → 12 warps (602549: 0.3311 / 64.05 ms), **128 → 16 warps (602559: 0.3255 / 62.99 ms)**, 96 → 20 warps (602567: 0.3436 / 66.50 ms, spills dominate) (`patches/opt/0003-weno-maxregcount.patch`, mfc-k2 `9f86956`) | 602559 `results/k2/cap128_1g` | grind **0.3255** (−10.1 % vs K2-prep, **−18.3 % vs baseline**), step **62.99 ms** (−18.3 %) | bitwise ✓; compiler flag → disclosed | yes |

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
