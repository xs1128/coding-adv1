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

## 3. Code the student must be able to defend
(filled in as optimizations land)
