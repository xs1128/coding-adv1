# AGENT_LOG — mistakes the AI agent made

Every mistake the AI helper (the "agent") made, oldest first: what went wrong, what it cost, the rule now followed.
All are kept; hiding one would be dishonest.

Words: a **GPU job** is a request to Slurm, the cluster's queue, to borrow GPUs; cost is in GPU-minutes. **OTP** is
the one-time password for logging in to nano4. An **A/B** runs old (A) and new (B) code on one machine to compare.
**Bitwise** means the answer matches to the last bit. A **kernel** is a small program run on the GPU. The **suite**
is MFC's own test set, run as several jobs ("shards"); each test has an ID (UUID). A **worktree** is a folder with
one version of the code.

## How the work was split
The main session plans, chooses runs and sums up. Read-only helpers work in parallel: past homework, machine
checks, SC26 rules, later code reading and optimization research.

## Early setup (no dates recorded)
1. **Sync deleted a live build log.** `tools/sync.sh push` mirrors with `--delete` but did not skip the remote-only
   `logs/` folder. Rescued from `/proc/<pid>/fd/1`. Rule: sync skips `/logs/`.
2. **Used other people's accounts.** A read-only helper was pointed at `nano4-chwang`/`f1-chwang` before anyone
   checked ownership. Rule: only `nano4-u1131128`.
3. **First baseline job (600131) died at start.** MFC launched with `srun`, under which HPC-X Open MPI cannot
   start here. Cost: <1 GPU-min. Fix: force `-b mpirun`; set `OPAL_PREFIX`.
4. **The retry (600134) failed too.** `mpirun` tied rank 0 to a CPU core the job could not use. hw2 had already
   solved this with `--bind-to none`; the lesson was not carried over. Cost: <1 GPU-min. Rule: binding off by
   default, tried only as an experiment.
5. **Chased a wrong guess.** The agent suspected GPU data skipped the fast NVLink path, from `ucx_info` on the
   *login* node. Half of its test job died on `set -u`; job 600232 showed `cuda_ipc` already in use at 292 GB/s.
   Cost: 2 GPUs × ~3 min. Rules: check on a compute node; no `set -u` before vendor init scripts.
6. **Two reruns that would clobber each other.** Jobs 600312/600313 and a running build all wrote the same
   `mfc/tests/<UUID>/` folders. Cancelled before they ran. Rule: one MFC test run per checkout at a time.
7. **A false test failure.** In job 600296, test C4EB58A8 could not run at all: its chemistry build was never
   made. Fix: build every variant first; reruns 600389/600390 pass. See [docs/harness.md](docs/harness.md).
8. **Started a run that cost too much.** A full suite (≈ 145 GPU-min) just to list known failures. The user
   objected; jobs 600397–600400 were cancelled after ~1 GPU-min. Rule: small targeted tests; full suite once.
9. **Sync deleted a worktree mid-build (same kind as #1).** `mfc-v4.9.3` was not on the skip list. Rule: skip
   `/mfc*/`, and add any new remote-only folder to the list before the next push.
10. **A kill command killed its own connection.** `pkill -f "seq 1 30"` also matched the remote shell running it
    (a repeat slip). Rule: `pkill -f "[s]eq 1 30"`, or kill by PID.
11. **Misread compiler output.** The agent took `-Minfo` and `cuobjdump` output as proof that HLLC's helpers were
    inlined (pasted into the caller). Those describe CPU-side code; the GPU code still had 9 calls. Rule: check GPU
    inlining in the PTX or SASS only.

## 12. A check passed a run that never ran (2026-10-23, job 602704)
The timed run crashed, but the warm-up run's output file was still there, so `verify.py` said bitwise PASS. Fix:
delete old output before the timed runs. Earlier verdicts stand: each had timings from every run.

## 13. A comment broke the build (2026-10-23, P3 build)
A comment after a `$:` fypp line was read as Python. Rule: comments go on their own line.

## 14. A loop ran only its first row (2026-10-24, jobs 605961-3)
mpirun read the loop's input and swallowed the remaining rows. Cost: ~41 GPU-min (baseline rows still valid).
Rule: launchers get `< /dev/null`.

## 15. A speedup from rounded numbers (2026-10-27)
The agent told the user 2.24× before computing it from raw files; the exact value is 2.2350, so 2.23×. Caught when
the figure script disagreed. Rule: derived numbers come from raw files, in one script. P4 budget (user-approved):
5 + 77 + 138 GPU-min (estimates 70 and 124 for the last two).

## 16. From P7 onward (2026-11-01 and later)
- **Pointer bug (P7), caught in self-review before any build.** Re-pointing arrays OpenACC had already linked to the
  GPU would have left the GPU copy pointing at freed memory.
- **Test lines read as comments.** `!$acc` after `;` is a comment in Fortran; job 664557 failed, 664560 PASS.
- **Power-braked nodes.** Two A/Bs ran 5x slow in *both* arms. The agent checked before trusting them:
  `nvidia-smi -q` showed "HW Power Brake Slowdown: Active". Cost: ~28 GPU-min lost. Rule: record why clocks are
  slowed, not just the clock.
- **Build-script slips** (no GPU cost; caught by checking `git log`): a bad file pattern built P8/P9 without their
  patches; `git revert --no-verify` does not exist; sbatch ignores `SBATCH_EXCLUDE`.
- **Day total 2026-11-01:** 98.1 GPU-min, 22.5 of it on braked nodes.
- **8-GPU A/B far over budget.** Approved at "~40 GPU-min", it cost 67 and hit its time limit, so P11 got 2 runs,
  not 3. The estimate left out start-up and setup. Rule: estimate from an earlier job of the same shape.
- **Missing case file, twice.** Profiler job 667720 held a GPU 7.5 min, then failed. The same mistake hit the A/B
  script (8 GPU-min), and a helper script resubmitted it. Rule: submit.sh rejects a missing case file.
- **Cluster fault.** Jobs ran to their limits without output while about 100 jobs on nano4 were stuck. Cost: 30
  GPU-min, no data. GPU jobs held until it cleared.
- **Slow start-up on one node.** A 4-GPU A/B timed out: runs took 94 s, not 12 s as that morning, while grind
  (speed per cell) was unchanged. The node was slow to start several processes; the code was not slower. Cost: 28 GPU-min. Rerun elsewhere.
- **Suite broken by a build running at the same time.** The script rebuilt the worktree the suite was running from,
  so tests ran a program being overwritten. Cost: ~22 GPU-min. Rule: never build where a suite runs.
- **Suite built for CPU, not GPU.** A fresh worktree's saved settings had no GPU mode, so tests could not find the
  GPU program. Cost: ~56 GPU-min; ~78 for both tries, no result. Rule: run_suite.sh checks for GPU builds first.
- **Mistyped job ids** in two watchers (no GPU cost). Ids now come from the submit output.
- **Comma bug.** `sbatch --export` splits at commas, so `UCX_TLS=self,sm,cuda_copy,cuda_ipc` arrived as
  `UCX_TLS=self`. A commit (d671af8) credited a gain to the wrong setting; at 4 ranks MPI_Init failed (~1
  GPU-min). Rule: write commas as '+'.
- **Chemistry builds broken since P10.** A register cap made them fail to link. Found at P14; fixed by 0018.
- **Correction: P11's "94/94 pass" was a CPU run**, same cause as above. So no series after P4 had a GPU suite result
  then. The P12 ladder row no longer cites a suite.
- **Same comma bug again** (~0.2 GPU-min), caught before the job ran.
- **Checked the wrong folder.** A parent label gave a false FAIL; all 8 arms pass bitwise. Rule: verify each arm.
- **Counted a failure twice.** Overlapping shards ran two known tests twice; the second copy looked "NEW". Rule:
  count failures by unique UUID (23, all known).
- **Gave a path instead of a label.** verify.py printed FAIL and wrote stray files, since deleted. Rechecked by
  label: PASS. Rule: verify.py takes a label.
- **Called a suite clean while 59 tests had not run.** The P18 suite was read as "no new failures"; comparing UUIDs
  run (713 vs 654) showed the gap. Made up later. Rule: complete means every UUID ran.
- **Commits blocked, not bypassed.** MFC's commit check needs zstd, missing on login node lgn01. The agent did not
  skip the check; diffs were kept in `patches/exp/`. Solved 11-02 when the user built zstd.
- **11-02: a sweep script reused old folders**, set off a rebuild of an old tree, and repeated ladder row 17
  without checking. Rule: scripts refuse existing folders; check the ladder first.
- **11-02: watchers misread a dropped connection.** One read the error as "queue empty"; one kept retrying an OTP
  login (stopped, so the account would not get locked). Rule: stop on `hpc` exit status 255.
- **11-02: the P20 suite included 39 tests that rebuild MFC.** The shard timed out on them (25 min of 1 GPU). The
  agent had written that the lists matched P18's without comparing. Rule: diff the test list before submitting.

## Code the student must be able to defend
(filled in as optimizations land)
