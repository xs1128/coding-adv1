# Optimization ladder

One row per experiment, newest last. Baseline: `results/base/official_1g` (job 600407, v5.7.0, NVHPC 26.3,
1 H200, 0.3982 ns, step 77.06 ms). "Kept" means the change goes into the next rung.

| # | Item | Change | Job(s) | Result (1 GPU unless noted) | Verify | Kept |
|---|---|---|---|---|---|---|
| 1 | T0.5 | NVHPC 25.9 instead of 26.3 (same source, `mfc-nv259`) | 601138 `results/t0/nvhpc259_1g` | grind 0.3977 (−0.1 %, noise), step 76.93 ms; wall 13.8–22.8 s vs 8.1 s (HPC-X 2.24 start-up) | not bitwise (max rel 6.3e-8) | no |
