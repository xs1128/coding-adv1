# AGENT_LOG — Coding-Adv-HW-1 (MFC on nano4)

## 1. Task decomposition
- Main session: planning, run/measurement decisions, synthesis.
- Parallel read-only subagents: prior-homework inventory (hw1/hw2/hw3), environment probe (nano4/F1),
  SC26 rules/app research. Later: source analysis of hot kernels, literature research on optimizations.

## 2. Agent mistakes
| # | What went wrong | How found | Fix + evidence |
|---|---|---|---|
| 1 | `tools/sync.sh push` mirrors with `--delete` but did not exclude the remote-only `logs/` dir, so the first push after starting the build deleted the live build log. | `tail logs/build_generic.log` → "No such file" | Excluded `/logs/` in sync.sh; recovered the stream from `/proc/<pid>/fd/1` of the running build. |
| 2 | The environment-probe subagent was pointed at `nano4-chwang`/`f1-chwang` (other people's accounts) before checking ownership. | Main session cross-checked the hw3 CLAUDE.md rule against `hpc hosts` | Probe was read-only; all work now uses `nano4-u1131128` only (CLAUDE.md rule). |
| 3 | First baseline job (600131) died in `syscheck`: MFC default template picked `srun`, and HPC-X Open MPI cannot init under srun here (OPAL help-file paths point at the /proj build prefix). | `results/base/generic_1g/prep.log` | Force `-b mpirun` in run/profile sbatch; export `OPAL_PREFIX` in env.sh. Cost: <1 GPU-min. |
| 4 | Retry (600134) failed again: HPC-X `mpirun` binds rank 0 to core 0, outside the job's cgroup cpuset (`hwloc_set_cpubind ... "0"`). hw2 had already solved this with `--bind-to none` — prior-work lesson not carried over. | `results/base/generic_1g/prep.log` | Default `OMPI_MCA_hwloc_base_binding_policy=none` in both sbatch; binding becomes an explicit experiment. Cost: <1 GPU-min. |
| 5 | Main session suspected the GPU-direct path bypassed NVLink because `ucx_info` on the *login* node showed no CUDA transports, and wrote an OSU A/B job whose HPC-X arm then died on `set -u` inside `hpcx-init.sh`. | OSU job 600232: arm A already uses `cuda_ipc` at 292 GB/s | Recorded as a refuted hypothesis; lesson: probe transports on a compute node, and do not `set -u` before sourcing vendor init scripts. Cost: 2 GPUs × ~3 min. |
| 6 | Submitted two concurrent reruns of the same failing MFC tests while a `./mfc.sh test --dry-run` build ran: all three write the same `mfc/tests/<UUID>/` dirs, so results would have clobbered each other. | Noticed right after submitting (jobs 600312/600313) | Cancelled both before they ran; reruns go sequentially after the build. Rule: one MFC test invocation per checkout at a time. |
| 7 | The 10% test sample (job 600296) reported chemistry test C4EB58A8 as failed: `mfctest.sbatch` runs `--no-build` and the `gpu-acc-chem` variant had never been built. | `test.log` showed it failed to execute, not a tolerance error | Built all variants with `./mfc.sh test --dry-run -j 8` on the login node; reruns 600389/600390 pass C4EB58A8. Procedure documented in `docs/harness.md`. |
| 8 | Launched a full pinned-build test baseline (4 chained shards × 2 GPUs × ~18 min ≈ 145 GPU-min) only to pre-list known failures. | User objected to the cost | Cancelled 600397–600400 after ~1 GPU-min. Switched to targeted subsets + rerunning individual failures on the pinned build; the full suite runs once, before the upstream PR (upstream CI runs it too). |
| 9 | Created the `mfc-v4.9.3` worktree next to `mfc/` on nano4, then `tools/sync.sh push` (`rsync --delete`, only `/mfc/` excluded) deleted it mid-build — same class as #1. | Build log ended in `Terminated`/143; worktree dir held only `build/` | Exclude `/mfc*/` (every MFC checkout); recreated the worktree from `patches/v4.9.3-cuda13-nvtx.patch`. Rule: any new remote-only dir must be added to the sync excludes before the next push. |
| 10 | `pkill -f "seq 1 30"` over `hpc` matched its own remote shell (the pattern is in that shell's command line) and dropped the connection — repeat of an earlier slip. | Exit 255 | The loop was killed anyway; use `pgrep/pkill -f "[s]eq 1 30"` (bracket trick) or kill by PID. |
| 11 | Read `cuobjdump` `STACK:0` and `-Minfo` "cross-inlined" as proof that HLLC's helpers were inlined, and ruled out #2094's cause. Both describe the relocatable object / host code; the device PTX still had `.extern .func` calls. | K4a (constant `dir_idx`) made SASS worse; PTX showed 9 extern calls | Check device inlining in the PTX (`.extern .func`, `call.uni`) or SASS `CALL`, never from `-Minfo`/per-object stack. |

## 3. Code the student must be able to defend
(filled in as optimizations land)

## 12. verify.py passed a run whose timed reps never started (2026-10-23, job 602704)
- `run.sbatch` runs a warm-up through `mfc.sh run` first; it writes `restart_data/lustre_30.dat`, which the timed reps
  overwrite. When rep 1 died in `MPI_Init`, the warm-up's file stayed and `verify.py` reported bitwise PASS.
- Fix: delete `lustre_[1-9]*.dat` before the timed reps, so a failed rep leaves no final state and verify FAILs.
  Earlier verdicts stand: every one had a grind number for every rep, so the last rep wrote the file.

## 13. Trailing comment on a fypp `$:` line (2026-10-23, P3 build)
- Wrote `$:GPU_WAIT()  ! buff_send is packed asynchronously`. Fypp evaluates everything after `$:` as Python, so the
  build failed with a SyntaxError. Comments go on their own line above fypp directives.

## 14. A `while read` loop around mpirun ran only the first row (2026-10-24, jobs 605961-3)
- `harness/series.sbatch` read its spec with `while read ...; do bash run.sbatch; done < SPEC`. mpirun/mfc.sh inherited
  stdin and swallowed the remaining rows, so each final set ran only its first (baseline) row. Cost: ~41 GPU-min, of
  which the baseline rows are still valid. Fix: run the body with `< /dev/null`. Lesson: never let MPI launchers
  inherit a loop's stdin.

## 15. A chained speedup quoted from rounded inputs (2026-10-27)
- Before computing it from the raw `steps.tsv` files, the agent told the user the 8-GPU speedup after P4 would be
  2.24×. Products of rounded medians drift: the exact value is 21.939 / 10.222 × 10.150 / 9.747 = 2.2350, so 2.23×.
  Caught when the figure script (which reads raw files) disagreed with the report table. Lesson: derived numbers come
  from the raw files in one script, never from rounded table entries.
- Budget for P4 (all user-approved): 1-GPU A/B 5 GPU-min (621788), 4/8-GPU A/B 77 GPU-min (622305/6, estimate 70),
  full suite 138 GPU-min (622349–622356, estimate 124).

## #16 — P7 (2026-11-01)
- First design of 0009 re-pointed `flux_n(i>1)` pointers that OpenACC had already attached. Under the OpenACC rules a
  second `attach` only bumps the attachment counter, so the device copy would have kept pointing at freed memory.
  Caught in self-review before any build; the alias is now set where the arrays are first allocated, before any attach.
- The `remap_attach.f90` test put `!$acc` directives after `;` on the same line, where Fortran treats them as comments,
  so job 664557 failed with "not present". Fixed (directives on their own lines); 664560 PASS.
- Two 1-GPU A/Bs (664568 on hgpn008, 664583 on hgpn010) ran 5x slow in *both* arms. Before reading anything into the
  P7/P4 ratio there, the agent checked: identical inputs, harness and modules; `nvidia-smi -q` showed
  "HW Power Brake Slowdown: Active" (664593). A 30 s probe found a clean node (hgpn028) for the real A/B (664597).
  Lesson: run.sbatch should record the clock-event reasons, not just clocks; a braked GPU shows 1980 MHz idle.
- Budget: ~40 GPU-min for the 1-GPU work (~28 of it lost to the power brake), plus the 4-GPU A/B (664612, ≤32).
- Build-script slips (no GPU cost, caught by checking each build's `git log` before timing): `git -C dir am ../x*.patch`
  globbed relative to the shell's cwd, so P8/P9 first built without their patches; `git revert --no-verify` is not an
  option; `SBATCH_EXCLUDE` is not read by sbatch (664752 landed on a braked node; the guard refused it in 4 s).
- Budget 2026-11-01 (sacct): 98.1 GPU-min, of which 22.5 on power-braked nodes before the guard existed. No set over
  30 GPU-min; no 8-GPU run; full test suite not run yet for 0007-0014.
- 8-GPU A/B P4 vs P11 (667577, user-approved at "~40 GPU-min"): cost 67 GPU-min (8 × 8.4 min) and still hit its
  8-minute limit, so P11 has 2 reps, not 3, and there was no second round. The estimate counted only the timed reps
  (~19 s each). It missed the per-arm pre_process run, the compare-vs-ref step and the 8-rank start-up. Lesson: for
  8-GPU sets, budget from the elapsed time of an earlier job of the same shape (622306), not from rep wall time.
- ncu job 667720 was submitted with CASE `-`, which only the A/B and test scripts accept. It held one GPU for 7.5 min
  and then failed on `cp` (the slow part before that was node-side start-up). Cost: 7.5 GPU-min. submit.sh now rejects
  a missing case file at submit time. submit_clean.sh also looped 6 times on an sbatch argument error; it now stops.
- Repeated the CASE `-` mistake on the A/B script, which also copies the case file per arm. W3 try 1 (667909) failed
  every arm after slow start-ups (8 GPU-min). submit_clean.sh read the missing a1 result as a braked node and
  resubmitted (667944); the fused A/B (667932) had the same argument. submit.sh now accepts `-` only for SCRIPT=mfctest.
- 17:14-17:35: 667917 (correct arguments), 667932 and 667944 never wrote a Slurm output file and ran to their 10-min
  limits. About 100 jobs on nano4 were stuck in COMPLETING (18 nodes completing, 24 drained), so this was a
  cluster-side Slurm/epilog or filesystem fault. Cost: 30 GPU-min with no data. GPU submissions held until it cleared.
- 4-GPU A/B 668370 (P11 vs P12, hgpn040) timed out at 7 min before the P12 arm ran. On that node the P11 arm's rep walls
  were 94/45/32 s against 12 s for the same shape that morning (664895); grind was unchanged (0.0633). So the cause was
  node-side multi-rank start-up, not the code. Concurrent 1-GPU reps elsewhere were normal. Cost: 28 GPU-min, P11 arm
  only (kept as results/p12/ab_4g_rdma_timeout). Rerun as 668436 excluding hgpn040, with a 10-min limit.
- Full suite p12_full, first attempt (668868-668875): every shard aborted under the runner's "100 % failure" guard, with
  `pre_process` exiting 132 (SIGILL). Cause: my build chain ran the caseopt build of the same worktree (mfc-p12) right
  after launching the suite. `pre_process` is not case-optimized, so both builds install into the same directory
  (gpu-acc-7d1e32e277), and tests executed a binary that was being rewritten (installed 18:27:16). Cost: ~22 GPU-min.
  Lesson: never build in a worktree while a suite runs from it; the suite now gets its own worktree, or runs after
  the builds. Rerun the same day; the failed attempt is kept under results/test/failed_p12_full_concurrent_build.
- Full suite p12_full, second attempt (669256-669261): shards failed again under the 100 % guard, with mpirun unable to
  find `build/install/gpu-acc-c819d00b45/bin/simulation`. The test-variant pre-build (`./mfc.sh test --dry-run`) ran in
  a fresh worktree whose build lock had no GPU mode yet, so it built CPU variants. The fmt suite had worked only
  because an earlier GPU build had set the lock. Shards 5-7 were cancelled once noticed. Cost: ~56 GPU-min (shards
  ran 2.6-20.6 min each, mostly syscheck and pre_process of tests that then failed). Two attempts together: ~78
  GPU-min with no suite result. Fixes: run_suite.sh refuses unless the lock is gpu: acc and every configured GPU build
  has installed binaries; the next suite runs on the final series (P14) after a 3-test smoke shard.
- Also today: two watchers waited on mistyped job ids (no GPU cost). Job ids are now captured from submit output.
- UCX transport A/B: `ENV_B=UCX_TLS=self,sm,cuda_copy,cuda_ipc` went through `sbatch --export`, which splits at
  commas, so both runs got `UCX_TLS=self` (env.txt). The 1-GPU wall gain (669410, ~6.0 -> ~5.5 s) is therefore
  `UCX_TLS=self`, valid only for a single rank; commit d671af8 described it as the four-transport list. At 4 ranks
  `self` alone cannot reach peers and MPI_Init failed (669420 b1, ~1 GPU-min). ab.sbatch now maps '+' to ',' in
  ENV_* values.
- Defect found by the P14 test-variant pre-build: since 0012 (P10) chemistry GPU builds fail to link. nvlink rejects
  unity-file kernels capped at 128 registers calling the generated m_thermochem (148-230 registers). The fmt (P11)
  pre-build had not hit it; its chemistry variants were not rebuilt there. Fixed by 0018 (cap m_thermochem as well,
  like m_hb_function). The P14 suite waits for the rebuilt variants.
- Correction: the P11 suite shards that ran (p11_full_s0/s1, "94/94 pass" in commit b5f97c7) used the CPU build
  (`--no-gpu` in the test banner). mfc-fmt's pre-build had built CPU variants only, the same cause as the second
  p12_full failure. So there is no GPU test-suite result for any series after P4 yet. The P3 and P4 suites did run
  GPU builds (`--acc-gpu`). The P12 ladder row no longer cites a suite.
- Same comma bug again (669825, cancelled after 14 s, ~0.2 GPU-min): `NSYS_TRACE=cuda,nvtx,mpi,openacc,osrt` was passed
  through `submit.sh`, and the job got `NSYS_TRACE=cuda`. Caught by reading `scontrol show job` before it ran.
  profile.sbatch now maps '+' to ',' in NSYS_TRACE too. Rule: any comma in a submit.sh value must be written as '+'.
- A watcher passed the parent label `exp/rkb2_regs_1g` to verify.py and printed FAIL (no state in the parent
  directory). All 8 arms pass bitwise when verified one by one; verify each arm, never the parent.
- The p15_full watcher printed two "NEW" failures (2BA0324F, E8C7E354). Both are in the known list. Shards 6 and 7
  overlap and both ran them, and the watcher's `comm` over a list with duplicates reported the second copy as new.
  Recomputed with sets: 23 unique failures, all known, none new. Count suite failures by unique UUID.
- verify.py was called with `results/<label>` instead of the label `<label>`. It looked for state under
  `runs/results/...`, printed FAIL, and wrote FAIL verify.json files under `results/results/` (8-GPU A/B 670540, and
  three t0 labels from an earlier session). Those were stray files, not results: deleted on both sides. Re-verified
  by label: both 670540 arms PASS bitwise. Rule: verify.py takes the label (`p18/ab_8g_rdma/b1`), never a path.
- The P18 full suite (670591–670598) was first read as "no new failures" while 59 tests had not run: shard 6's
  `--from A96DA754 --to 82A64F89` covered 14 tests at run time (94 in the P15 suite with the same range), shard 7
  76 of 94. The checker printed pass/fail per shard but not whether each shard ran its whole list. Caught by
  comparing the UUID sets run by P15 and P18 (713 vs 654). Made up by one shard with the 59 UUIDs (`--only`, 671033).
  Fix: run_suite.sh now passes each shard its UUIDs with `--only`; rule: a suite is complete only when the union of
  UUIDs run equals `./mfc.sh test -l`.
- Inner MFC commits on nano4 are blocked on login node lgn01: the pre-commit hook's lint runs a `tar --zstd` round
  trip and lgn01 has no zstd. Not bypassed (`--no-verify`); building zstd in user space was denied by the permission
  layer. The experiment diffs are versioned here (`patches/exp/`) until a commit can run the hook.
  Resolved 11-02: the user built zstd 1.5.6 into `~/.local/bin` on nano4 themselves (a first paste broke the URL
  across lines). With `PATH=$HOME/.local/bin:$PATH` the hook passes; P20 committed in `mfc-p20` (1673013, 6611288)
  with the full precheck, exported as `patches/opt/0023`–`0024`.
- 11-02: a register-cap sweep script reused worktree names (`mfc-r96`, `mfc-r255`) that already existed from earlier
  experiments, because it only created a worktree "if the directory is missing". Its `sed -i` rewrote `mfc-r96`'s
  CMakeLists.txt without changing its content (line 184 held no cap there), which updated the mtime and triggered a
  rebuild of that old tree; I stopped the script before it reached `mfc-r255`. The sweep also repeated
  ladder row 17 (caps 168/255 on the fused kernel, +7 %), which I had not checked first.
  Rule: experiment scripts refuse an existing directory, and check the ladder before planning a sweep.
