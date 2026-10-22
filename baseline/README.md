# MFC baseline on nano4 (1× H200) and comparison with the official numbers

Every number below cites a Slurm job and a file under `results/`. Reproduce with `baseline/reproduce.sh`.

## 1. What is measured
- **Case:** MFC's official benchmark `examples/3D_performance_test`, 1 GPU, `--case-optimization`, as in MFC's
  performance docs: 5-equation two-fluid model (8 PDEs), WENO5 + HLLC, RK3, 201³ cells (m=n=p=200; the docs'
  "158-cubed" text is stale), 30 steps. `harness/cases/perf3d.py` with no arguments emits exactly the upstream
  v5.7.0 case dictionary (all 91 keys identical).
- **Builds:** pinned v5.7.0 (`0b3d56c`, unmodified, `mfc_diff_sha1=da39a3ee` = empty diff) and v4.9.3
  (`42cfdf0`, the version behind the official table) with two disclosed build/I/O fixes, no numerics changes:
  - `patches/v4.9.3-cuda13-nvtx.patch`: CUDA ≥ 12.9 ships no `libnvToolsExt`, so link NVHPC's NVTX wrapper
    (backport of v5.7.0 `cmake/MFCTargets.cmake`).
  - `patches/v4.9.3-double-file-close.patch`: `s_write_parallel_data_files` closes the file twice, and the
    second close segfaults with HPC-X Open MPI 4.1.9 (jobs 600470/600471). v5.7.0 does not have it.
- **Machine:** nano4 `25a-hgpn*`, H200 141 GB (700 W limit, 1980 MHz SM after each run), NVHPC 26.3
  (CUDA 13.1), HPC-X Open MPI 4.1.9. Timing: a warm-up/prep run, then 5 timed reps.

## 2. Corrected baseline (v5.7.0)
| Job | Grind, ns/gp/eq/rhs (median of 5) | Range | Wall (median) | Step (median, NVTX) | Correctness |
|---|---|---|---|---|---|
| 600407 `results/base/official_1g` | **0.3982** | 0.3980–0.3986 | 8.07 s | 77.06 ms | bitwise identical to reference run |

The GPU is busy for nearly the whole stage: the kernel time is 25.1 ms per RK stage
(`results/prof/nsys_v570_1g_30`, job 600682) out of a 25.5 ms minimum stage. So a single GPU is compute-bound.
In wall time, by contrast, start-up and I/O take more than 70%: 8.07 s total versus about 2.3 s of time
stepping.

## 3. Comparison with the official table
### 3a. The two "grind" numbers are different metrics
| | v4.9.3 (official table) | v5.7.0 (ours) |
|---|---|---|
| timed region | `s_compute_rhs` only | whole RK stage (RHS + update + BCs) |
| clock | `cpu_time` (host CPU time) | `system_clock` (wall clock) |
| statistic | running mean over steps | minimum over stages after 2 warm-up steps |
| divisor | (m+8)(n+8)(p+8)·sys_size, ghost cells included (208³) | m·n·p·sys_size (200³) |

So 0.398 (v5.7.0) **cannot** be put next to 0.38 (H100 SXM, v4.9.3). The v4.9.3 metric is also fragile.
Running the same binary with `run_time_info` on or off changes the printed grind by 9%
(0.4130 vs 0.4514), while wall time is the same (7.68 vs 7.62 s) and the final state is identical.
The reason is that `cpu_time` counts only the host CPU time spent around asynchronous GPU work.

### 3b. Same metric, different hardware: v4.9.3 on our H200 vs the published table
| Hardware | Grind (v4.9.3 metric) | Source |
|---|---|---|
| NVIDIA GH200 | 0.32 | MFC docs, NVHPC 24.1 |
| NVIDIA H100 SXM5 | 0.38 | MFC docs, NVHPC 24.5 |
| **NVIDIA H200 (nano4), official case** | **0.4130** (0.4127–0.4131) | job 600481 `results/base/v493_official_1g` |
| NVIDIA H200 (nano4), `run_time_info=F` | 0.4514 (0.4512–0.4518) | job 600482 `results/base/v493_samecfg_1g` |
| NVIDIA H100 PCIe | 0.45 | MFC docs, NVHPC 24.5 |

**Finding:** with the official code version, our H200 is 9% *slower* than the published H100 SXM5, even though
the H200 has 1.4× its memory bandwidth. Candidate causes, not yet tested:
- **Compiler:** NVHPC 26.3 here vs 24.5 there. v4.9.3's WENO kernel takes 4.79 ms per call here.
- **Measurement:** v4.9.3's `cpu_time` metric, see 3a.

Testing an older NVHPC would be a cheap follow-up (1 GPU-min) if nano4 has one.

### 3c. Same hardware, version-independent: GPU kernel time per step (nsys, same 30-step configuration)
| | v4.9.3 (job 600683) | v5.7.0 (job 600682) | v5.7.0 / v4.9.3 |
|---|---|---|---|
| all kernels, ms/step | 88.1 | **75.4** | 0.86 (1.17× faster) |
| WENO (incl. v5.7.0 `pack_weno_input`), ms/step | 43.1 | 31.4 | 0.73 |
| HLLC Riemann solver, ms/step | **13.1** | 18.7 | **1.43 (regression)** |
| kernel launches per step | 198 | 198 | same |
| final state vs v5.7.0 reference | L2 rel 2.7e-16, max rel 1.5e-4 (near-zero cells) | bitwise | different FP order between versions |

Source: `results/prof/nsys_v*_1g_30/nsys_rank0_cuda_gpu_kern_sum.csv`.

On the same GPU, v5.7.0 does 14% less GPU work per step than the official-table version. WENO got much faster,
but the HLLC solver is 43% slower. This matches upstream issue #2088 (HLLC regression since v4.9.3; see
`docs/refs/`). Restoring v4.9.3-level HLLC speed would remove about 5.6 ms of the 75.4 ms per step (−7%). It is
the first kernel target in `docs/roadmap.md`.

## 4. Package contents
`tools/package.sh` → `dist/mfc-baseline-<commit>.tar.gz`:
- this report and `reproduce.sh`;
- `harness/`, `scripts/`, `patches/`, `tools/sync.sh`, `docs/harness.md`;
- the raw results of every job cited above, plus `results/jobs.tsv`.

GPU cost of this baseline: about 10 GPU-min in total, including about 1 GPU-min of failed v4.9.3 runs.
