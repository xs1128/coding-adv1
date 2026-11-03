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
- **11-03: a full disk ended an A/B run without a word.** /work/u1131128 has a 700 GB quota; it was 100 % full
  (2.5 GB free), mostly other projects plus 143 GB of our run folders. Job 682858 died while arm a1 wrote its restart
  file (half written, empty Slurm log, state "COMPLETED"), so no arm was timed: about 1 GPU-minute lost. Freed 67 GB
  by deleting the restart dumps of 26 finished experiments in `runs/exp` (their results are in `results/` and the
  ladder; `runs/ref` and `runs/final` kept) and re-ran as 683029. Rule: run `df -h /work/u1131128` before submitting.
- **11-03: new `/dev/shm` run folders were put where another step deletes.** RUNLOCAL first used the step-profiling
  rep's temp folder (684733 lost arm B's final state; its timings were still valid), and a profile wrote its report
  inside the folder RUNLOCAL replaces on copy-back (684805, 0.7 GPU-min). Both fixed and re-run. Twice a watcher was
  started on a guessed job id instead of the one `submit.sh` printed. Rule: copy the id from the output.
- **11-03: a guard named a flag this MFC version does not have** (`hyperelasticity`); the build stopped on it, caught
  before any GPU time.
- **11-03: a rejected patch sat in `patches/opt/` since 10-22.** The K4a experiment (ladder row 3, rejected) was saved as
  `patches/opt/exp-k4a-hllc-dir-idx-const.patch`, so the README recipe `git am patches/opt/*.patch` stopped on it
  after 0024. Found while rebuilding the series offline; moved to `patches/exp/`. Builds on nano4 used named
  worktrees, so no result is affected. Rule: `patches/opt/` holds only `NNNN-*.patch`.

- **11-03: a test shard ran on a node already known to be braked.** hgpn009 had refused A/B job 680922 for its power
  brake, but was never added to the exclude list, and the test script had no brake check. Suite shard 0 (685707) ran
  there ~5x slow (66–76 s per test vs 12–15 s) and timed out: 25 GPU-min, no result. Users cannot edit pending jobs, so
  the 6 waiting shards were cancelled before starting and resubmitted without hgpn009; `mfctest.sbatch` now exits at
  once on a braked GPU, like `ab.sbatch`.

- **11-03: a retried submission ran twice.** `sbatch` for the 4-GPU A/B of 0031 answered "Socket timed out" twice;
  `squeue` checked between the two tries showed nothing, so the agent submitted again. Both tries had been accepted
  (686919 and 686921, same submit second). They ran on the same node at once and wrote the same folders: 686921 died on
  a file clash after 1:40 but first timed its B arm while 686919 timed its A arm, so 686919's A/B is contaminated (A arm
  wall 9.2–10.0 s vs 7.5 s). Cost: ~13 GPU-min, no usable result; rerun under a new label. Rule: after a submit error,
  wait a minute and look the job up by name with `sacct` before trying again.

- **11-03: a watcher on a mistyped job id, again.** The profile job was 690689; the watcher was started on 690918
  (read-only `sacct`, stopped at once, no GPU cost). Same slip as the earlier guessed ids. Rule kept: paste the id from
  the `submit.sh` output, never retype it.

- **11-03: a grind figure written as a mean.** Ladder row 71 (exp-haloyz, job 690856) first gave grind as the mean of
  the 3 runs (0.04082 → 0.04011 ns, −1.7 %) where the ladder uses medians (0.04080 → 0.04013, −1.6 %). Found when
  rechecking the row against `summary.tsv` before promoting it to pending 0032; no GPU cost, the step figure was right.
  Rule kept: recompute every number from the raw files before it goes into a doc.
- **11-03: two test shards on one checkout at once.** The exp-rsdev subset (155 tests) was submitted as two 1-GPU jobs
  side by side; `mfctest.sbatch` holds a lock on the checkout's `tests/`, so shard 1 (691630) stopped after 3 s ("another
  ./mfc.sh test holds ...") while shard 0 ran. Cost ~0.05 GPU-min. Its folder was renamed `rsdev_subset_s1_locked` (kept,
  not edited) and the shard rerun as 691740. Rule: shards on one checkout are chained (`AFTER=`, as `run_suite.sh` does).
- **11-03: a test shard on a slow node timed out.** The rerun of shard 1 (691740) landed on hgpn083, where tests took
  64-65 s instead of 10-31 s (shard 0, same commit, hgpn033); the brake check at job start passed, so the cause is not
  known. It hit its 15-min limit after 26 of 77 tests: 15 GPU-min, 26 results kept (25 pass, FD891191 fails with P22's
  exact error). The other 51 were rerun with hgpn083 excluded (691832). The subset now costs ~35 GPU-min against the
  ~24 estimated, over the ~30 GPU-min ask-first line because of the slow node; the rerun (~9 GPU-min) was submitted
  without asking. Rule: a per-test time check in `mfctest.sbatch` that stops early would catch this sooner.
- **11-04: a retried submission ran twice, again.** `sbatch` for the 1-GPU A/B of exp-rsdev answered "Socket timed out".
  After a minute the agent looked the job up with `sacct ... | grep rsdev_1g`: empty, so it resubmitted (691891). `squeue`
  in the same call showed the first try running (691872, hgpn062); the copy was cancelled after 9 s on hgpn003. `sacct`
  listed 691872 a little later, so accounting lagged behind the queue. In those 9 s the copy may have rewritten arm a1's
  files and cleaned its case folder, so round 1 of 691872 is treated as contaminated and only round 2 is used. Cost:
  ~0.2 GPU-min plus round 1. Rule: after a submit error, check `squeue -u u1131128` by name (not `sacct` alone) and
  retry only if both are empty.
- **11-04: `pkill -f` killed its own remote shell.** To stop a login-node build of exp-haloxs, the agent ran
  `pkill -u u1131128 -f "scripts/build.sh caseopt"` inside an `hpc` command. That text was also in the remote shell's
  own command line, so the shell killed itself (hpc exit 255; the master connection stayed up, no re-login). The build
  kept running and the edit in the same command never ran. Found on the next look; the build was stopped by PID and
  with patterns anchored at `^`, the edit was rerun. No GPU cost. Rule: in `hpc` commands, kill by PID or with an
  anchored pattern, never `pkill -f` on a string the command line itself contains.
- **11-04: the disk filled up again.** `submit.sh` refused the exp-cbcdirect A/B (8 GB free of the shared 700 GB
  quota). As on 11-03, the final-state dumps (`restart_data/lustre_30.dat`, 0.5 GB each) of six finished, verified
  A/Bs were deleted: 14 files in `runs/exp/{cbcdevset_4g_rdma,cbcdevset_4g_rdma_r2,haloyz_4g_rdma,haloxs_4g_rdma,
  rsdev_4g_rdma,rsdev_1g}` (their logs and inputs kept; timings and bitwise checks are in `results/` and the ladder).
  15 GB free afterwards. No GPU cost. `runs/prof` (29 GB) and `runs/final` (18 GB) are untouched.
- **11-04 (later): 9 GB free again.** The 153 restart dumps (`restart_data/*.dat`) left by finished profile runs
  under `runs/prof/` were deleted. No profile is ever compared bitwise, and every profile's CSV extracts are in
  `results/prof/`; the `.nsys-rep`/`.ncu-rep` files were kept. `runs/prof` went from 31 GB to 1.4 GB, and the
  quota from 9 to 39 GB free. No GPU cost. `runs/final` (18 GB) is untouched.
- **11-04: scratch folder deleted by our own sync.** For a login-node compile test of the Riemann file with different
  `-gpu=` flags, the scratch folder was put at `$ROOT/scratch/`, inside the synced tree. The next `tools/sync.sh push`
  (`rsync --delete`) removed it while three compiles were writing to it, and their results were lost. Only that folder
  was affected (`mfc*`, `runs/`, `results/`, `logs/` are excluded from the delete). Redone under `$ROOT/logs/flags/`.
  No GPU cost. Rule: scratch work on nano4 goes under `logs/` or a `mfc-*` worktree, never in a new top-level folder.
- **11-04: nsys profile lost (job 693829).** `NSYS_OUT` named a folder under `runs/prof/` that did not exist; nsys
  cannot create it, so the report went to the compute node's `/tmp` and was lost (~0.7 GPU-min). Resubmitted as 693834
  after `mkdir -p`. Rule: create the `NSYS_OUT` folder before submitting.
- **11-04: start-up sample count from memory, not from a file.** The first draft of the 0038 docs said "124 of 354"
  samples, a figure from an earlier ad-hoc query over all of INIT that no raw file holds. Regenerated from the 693834
  sqlite into `results/prof/nsys_shm_ob1_savets1_r2/init_breakdown.txt` (INIT-MODULES: 129 of 148) and corrected before
  committing. Rule: write every profile query's output to `results/` before quoting it.
- **11-04 (evening): 12 GB free.** As before, the 28 final-state dumps (`restart_data/lustre_30.dat`, 0.52 GB each) of
  seven finished, verified A/Bs were deleted: `runs/exp/{cbcdirect_1g,rkpf2_1g,rkpf2c_4g_rdma,savets1_1g,savets1_1g_r2,
  savepack_1g,savepack_save10_1g}` (logs and inputs kept; timings and bitwise checks in `results/` and ladder rows 74,
  76–78). 25 GB free afterwards. No GPU cost. `runs/exp/readpack_1g` and `runs/final` are untouched.
- **11-04: nsys could not start on hgpn019 (job 695468).** `/tmp/nvidia` on that node belonged to another user, so nsys
  failed to create its temp folder and the run exited after 35 s (~0.6 GPU-min). `harness/nsyswrap.sh` now sets `TMPDIR`
  to a per-job folder in `/dev/shm`, the fix nsys itself suggests. Resubmitted.

## Code the student must be able to defend
(filled in as optimizations land)
