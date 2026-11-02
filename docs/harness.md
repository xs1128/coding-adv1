# Harness

Scripts that run MFC on the cluster, time it, and check that the answer did not change.

Jobs run on nano4 in `/work/u1131128/coding-adv1` (sent by `tools/sync.sh push`). Results come back to
`results/<LABEL>/` (`tools/sync.sh pull`, never hand-edited); big outputs stay on nano4 in `runs/<LABEL>/`.

| Tool | Does |
|---|---|
| `scripts/build.sh` | builds MFC on the login node: `generic`, or `caseopt` (tuned to one case) |
| `harness/submit.sh` | queues a job (`SCRIPT=run`/`profile`/`mfctest`/`osu`), logs it in `results/jobs.tsv` |
| `harness/run.sbatch`, `harness/profile.sbatch`, `harness/osu.sbatch` | timing runs; nsys (a timeline) or ncu (a close-up of one GPU function, a "kernel"); GPU-to-GPU MPI speed |
| `harness/mfctest.sbatch`, `harness/run_suite.sh` | MFC's tests: a subset, or all in back-to-back shards of ≤25 min |
| `harness/verify.py` | **the gate**: final state vs `runs/ref/perf3d_201_30`, and no new test failures |
| `harness/run_all.sh`, `harness/collect.py` | standard runs (201³ grid; 8.12 M cells per GPU), one results table |
| `harness/tests/test_compare_state.sh` | tests the comparer: last-digit (1-ulp) diffs pass; 1e-9, NaN, wrong size fail |

## Speed numbers
- **grind**: MFC's own number, ns per grid point per equation per RHS pass. Fastest RK stage (sub-step) from step
  3 on, slowest rank (one MPI process per GPU). Optimistic: skips I/O, start-up and pauses.
- **step_ms_med**: median time of a whole step from step 2 on, slowest rank. Our main multi-GPU number.
- **wall**: the whole run, start to end.

## Correctness rules
1. `verify.py` must PASS for every timing we report. All baselines so far are **bitwise** identical to the
   reference (every bit the same). Changes that only reorder work must stay bitwise; any other change must stay
   within 1e-12 and say why.
2. `src/` changes must pass the full `./mfc.sh test` with no failures beyond `harness/known_test_failures.txt`
   (tests that already fail on the unchanged code here).
3. Never touch tolerances, the reference run, or the expected-answer files.

## Testing cheaply
The full suite costs ~145 GPU-min, and upstream runs it on every PR anyway.
1. After each change, build all test variants on the login node (`./mfc.sh test --dry-run -j 8`); a missing one
   shows up as a failure (C4EB58A8, job 600296).
2. While working, run only the related tests on 1 GPU.
3. A failure counts as old only if it fails the same way on the pinned build; then it goes into
   `harness/known_test_failures.txt` with the evidence.
4. Run the full suite once, on the final branch, before the upstream PR, with the user's go-ahead.
5. Finish with `harness/verify.py <label> --test-summary results/test/<tag>*/test_summary.json`.
