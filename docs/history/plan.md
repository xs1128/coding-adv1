# The October plan: speed up MFC on nano4 for SC26

> Historical: the plan as written in October 2026; what actually happened is in [../../report.md](../../report.md)
> and [../ladder.md](../ladder.md).

## The task
Make MFC (a program that simulates fluid flow) as fast as possible on nano4's H200 GPUs, under the SC26 student
competition rules. Prove the answers are still correct, and explain the speed.

## Dates
- 10/22–10/24: set up nano4, build MFC, pass its tests, write the harness (scripts that check, time and record
  runs), measure the baseline.
- 10/25–10/29: tune settings, then change code guided by profiling (measuring where time goes).
- 10/30: stop measuring. 10/31: report and AGENT_LOG.
- SC26 rule: code changes must reach the committee ≥2 weeks before 11/16.

## Status on 2026-10-22
Setup, baseline and profiling done ([../profiling-baseline.md](../profiling-baseline.md)). The ranked plan in
[roadmap.md](roadmap.md) replaces Steps 4–5 below.

## Step 0: pick the app
MFC on nano4, or WRF (a weather model) on F1? nano4 has the user's own login (with an OTP, a one-time password)
and 8 H200 GPUs per node. F1 had no own login yet, its logins were down, and key libraries were not found yet.
MFC also has strict tests (tolerance 1e-12) and a speed measure from its developers (grindtime), and earlier
homework had already built and profiled it. Risk in 9 days: low–medium for MFC, high for WRF.

**Decision: MFC on nano4** (pending user confirmation).

Steps 1–6 were open to-do lists when written.

## Step 1: setup
- Start from the hw3 repo skeleton. Keep an untouched copy of MFC (v5.7.0 or the latest master); work in a copy.
- Log in only as `nano4-u1131128`, never with other people's logins.
- Build MFC for the GPU and run its tests on one H200 inside a GPU job (a request to Slurm, the queue system).

## Step 2: harness, committed before any change
- Test cases: MFC's standard 3D speed case, a few benchmarks, and a case like the SC26 practice problems.
- `verify`: compare each output with the untouched build.
- `bench`: one warm-up, then ≥5 timed runs; median and spread; GPU clocks, power and temperature; job ID and
  commit in every record.
- A/B test: run the old (A) and new (B) builds in turns on the same node, so heat drift hits both equally.

## Step 3: baseline
One H200, default build, three sizes. Compare with published numbers (H100 SXM 0.38, GH200 0.32 ns). Then 1→8
GPUs on one node.

## Step 4: settings only, no code change
Each change is an A/B against the last and must pass verify: caseopt (compile MFC for one case; expected to be
the biggest win, "up to 10×"); `--fastmath`, checking its effect on accuracy; compiler versions and flags; GPUs
sending data to each other directly; processes per GPU and how the grid is split; file output off; speed per watt
(SC26 has a 10 kW cap).

## Step 5: profiling, then code changes
Code changes must be fit to send back to MFC: ≤5000 lines, passing the full test set.
- Find which GPU kernels (small programs the GPU runs) take the time, and how long the halo swap takes (each GPU
  sends its border cells, the "halo", to its neighbours).
- hw1 pointed at WENO (it uses so many registers that only about 12% of the possible threads run at once), HLLC
  (limited by memory speed), and the halo swap.
- Try ideas one at a time, each measured. Record the failures too.

## Step 6: scaling and the story
A final table from baseline through each change, with job IDs; scaling plots up to 16 GPUs; why it runs at this
speed; a public PR if code changed (SC26 needs one).

## Step 7: deliverables
- [x] `report.md` → PDF.
- [x] `AGENT_LOG.md`.
- [x] `harness/reproduce.sh` rebuilds the final numbers from a clean tree.

## Rules carried over
- Time only inside Slurm jobs, never on the login node.
- Commit before each job; never hand-edit `results/`; every number cites a job ID.
- Never claim correctness without the verify output; never loosen tolerances.
- Measure before trusting a helper agent's timing claim.

## Open questions
What do we hand in, and how is it graded? Is a case or MFC version prescribed?
