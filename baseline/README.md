# MFC baseline on nano4 (1× H200) and the official numbers

The baseline is the unchanged code's speed. Each number cites a Slurm job (a request to the cluster's queue
system) and a file under `results/`. To redo it, run [reproduce.sh](reproduce.sh).

## 1. What we measured
- **Case:** MFC's official speed test: two fluids, 8 equations, a 201³ grid, 30 steps, on 1 GPU. Built with
  caseopt (`--case-optimization`: MFC compiled for this one case, which is faster).
- **Builds:** v5.7.0 unmodified, and v4.9.3, the version behind the official table. v4.9.3 has one disclosed fix:
  it closes a file twice, which crashes with our MPI library. No math changes.
- **Timing:** one warm-up run, then 5 timed runs.

## 2. Baseline (v5.7.0)
Grindtime is MFC's speed measure: nanoseconds per grid point, per equation, per RHS evaluation (one pass
computing how the flow changes). Lower is faster.

Job 600407 (`results/base/official_1g`): grind **0.3982** (median of 5, range 0.3980–0.3986), wall time 8.07 s,
bitwise (same to the last bit) as the reference run.

The GPU's kernels (small programs on the GPU) take 25.1 ms of a 25.5 ms minimum stage, so one GPU is limited by
computing. But start-up and file writing take more than 70% of the wall time: about 2.3 s of 8.07 s is actual
time stepping.

## 3. Comparison with the official table
### 3a. The two "grind" numbers measure different things
v4.9.3 times only part of the work, on a CPU-only clock, and divides by a larger grid. v5.7.0
times the whole stage with a real clock. So 0.398 (v5.7.0) **cannot** be put next to 0.38 (H100 SXM, v4.9.3).

The old measure is also shaky: one output option (`run_time_info`) changes it by 9% (0.4159 vs 0.4509), with the
same wall time and answer. Its CPU clock misses GPU work running in the background.

### 3b. Same measure, different hardware
| Hardware | Grind (v4.9.3 measure) | Source |
|---|---|---|
| NVIDIA H100 SXM5 | 0.38 | MFC docs |
| **NVIDIA H200 (nano4)** | **0.4159** | job 601028 `results/base/v493_official_1g` |

**Finding:** with the official code version, our H200 is 9% *slower* than the published H100 SXM5, even though the
H200 has 1.4× its memory bandwidth. It is not the CUDA version (a CUDA 13.1 build gave almost the same numbers).
Untested: the compiler version, and the old CPU-clock measure itself.

### 3c. Same hardware, any version: GPU time per step
| | v4.9.3 | v5.7.0 | v5.7.0 / v4.9.3 |
|---|---|---|---|
| all kernels, ms/step | 88.1 | **75.4** | 0.86 |
| WENO kernels, ms/step | 49.6 | 31.4 | 0.63 |
| HLLC solver, ms/step | **13.2** | 18.7 | **1.42 (slower)** |

v5.7.0 does 14% less GPU work per step. WENO got much faster, but the HLLC solver got 43% slower, as upstream
issue #2088 reports (see [docs/background/refs/](../docs/background/refs/)). Bringing HLLC back to v4.9.3 speed
would save about 5.5 ms per step (−7%). It was the first kernel target in the [roadmap](../docs/history/roadmap.md).

## 4. Package and cost
`tools/package.sh` bundles this report, scripts, patches and the raw results cited above.
GPU cost: about 15 GPU-min, including about 1 GPU-min of failed runs and about 5 GPU-min of replaced runs.
