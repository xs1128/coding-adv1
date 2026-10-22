# Harness

All jobs run on nano4 (`hpc nano4-u1131128 '...'`) from `/work/u1131128/coding-adv1` after `tools/sync.sh push`.
Results land in `results/<LABEL>/` (pulled back with `tools/sync.sh pull`, never hand-edited); bulky run outputs
in `runs/<LABEL>/` stay on nano4.

| Tool | Purpose |
|---|---|
| `scripts/env.sh`, `scripts/build.sh` | toolchain + MPI env; `build.sh generic` / `build.sh caseopt <case.py>` (login node) |
| `harness/submit.sh LABEL CASE NGPU MIN [VAR=..]` | submit `SCRIPT=run` (default) / `profile` / `mfctest` / `osu`; logs `results/jobs.tsv` |
| `harness/run.sbatch` | timing: prep + REPS reps → `summary.tsv` (wall, grind); +1 NVTX-only nsys rep → `steps.tsv` |
| `harness/profile.sbatch` | `MODE=nsys` (all ranks) or `MODE=ncu` (rank 0) → CSVs; summarize with `nsys_summary.py` / `ncu_summary.py` |
| `harness/mfctest.sbatch` | `./mfc.sh test` (all or `TEST_ARGS` subset) → `test_summary.json` |
| `harness/verify.py LABEL [--test-summary ..]` | **gate**: final state vs `runs/ref/perf3d_201_30` (bitwise / ≤1e-12) + suite with no new failures |
| `harness/run_all.sh TAG [GPUS=..] [VAR=..]` | standard set: `TAG/strong_<g>g` (201³) + `TAG/weak_<g>g` (8.12 M cells/GPU) |
| `harness/collect.py` | one table of all results (grind, wall, median/first step, verify) |
| `harness/osu.sbatch` | GPU↔GPU MPI latency/bandwidth |
| `harness/tests/test_compare_state.sh` | comparator self-test (identical/1-ulp pass; 1e-9, NaN, size, missing fail) |

## Metrics
- **grind** (MFC): min RK-stage time over steps ≥3, max over ranks, ns/gp/eq/rhs. Optimistic; excludes I/O,
  init and any stall outside the stage bracket.
- **step_ms_med** (`steps.tsv`, `all` row = slowest rank): median TIMESTEP over steps 2..N — the headline
  number for parallel efficiency. `first_ms` reported separately (one-off costs, e.g. RDMA IPC setup).
- **wall**: whole `simulation` process incl. MPI_Init and I/O.

## Correctness contract
1. `harness/verify.py <label>` must PASS for every timing result we report. Every baseline so far — 1/2/4/8 GPUs,
   host-staged and RDMA, generic and case-optimized builds — is **bitwise identical** to the reference, so any
   change that only reorganises parallel work or memory traffic must remain bitwise; a non-bitwise change must
   stay ≤1e-12 and be justified.
2. Any `src/` change must also pass the full `./mfc.sh test` with no failures beyond
   `harness/known_test_failures.txt` (failures of the unmodified pinned build on this machine).
3. Never edit tolerances, the reference run, or golden files.
