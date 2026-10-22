# Optimization ladder

One row per experiment, newest last. Baseline: `results/base/official_1g` (job 600407, v5.7.0, NVHPC 26.3,
1 H200, 0.3982 ns, step 77.06 ms). "Kept" means the change goes into the next rung.

| # | Item | Change | Job(s) | Result (1 GPU unless noted) | Verify | Kept |
|---|---|---|---|---|---|---|
| 1 | T0.5 | NVHPC 25.9 instead of 26.3 (same source, `mfc-nv259`) | 601138 `results/t0/nvhpc259_1g` | grind 0.3977 (−0.1 %, noise), step 76.93 ms; wall 13.8–22.8 s vs 8.1 s (HPC-X 2.24 start-up) | not bitwise (max rel 6.3e-8) | no |
| 2 | P1 | CBC kernels + scalar updates on the OpenACC async queue, one wait per `s_cbc` (`patches/opt/0001-cbc-async.patch`, 1 file) | 601152 `results/p1/cbc_async_1g`, trace 601153, tests 601171 | grind 0.3933 (−1.2 %), step 75.98 ms (−1.4 %); CBC-range host gaps 0.83 → 0.44 ms/stage (`harness/range_gaps.py`) | bitwise ✓; 25/25 CBC tests (bc −5…−12, 1D/2D/3D) pass | yes |
