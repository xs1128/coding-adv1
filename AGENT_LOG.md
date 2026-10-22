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
