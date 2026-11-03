# CLAUDE.md — rules for agents working in this repo

Homework (Coding-Adv-HW-1): make one SC26 Student Cluster Competition app faster. We picked **MFC on nano4 (H200 GPUs)**.
Start with `README.md`. Full write-up: `report.md`. Every change, explained: `docs/optimizations.md`. Every attempt,
kept or not: `docs/ladder.md`. Agent mistakes: `AGENT_LOG.md`. Old plan: `docs/history/plan.md`.
Private notes: `JOURNEY.md` (gitignored).

## The app
**MFC** v5.7.0 — https://github.com/MFlowCode/MFC, commit `0b3d56c8e1c9a3aa8d112681b72c87ab69fe5f13`.
- Our changes are the patch files in `patches/opt/` (one patch = one optimization). Apply them in order to a v5.7.0
  checkout with `git am --keep-cr patches/opt/*.patch` to get our version. Rejected or pending experiments are in `patches/exp/`.
- On nano4, `$ROOT/mfc` is the clone where builds happen. Each stage has its own git worktree next to it:
  - `mfc` = plain v5.7.0, `mfc-p4` = the 10-31 report state.
  - `mfc-bcskip` (branch `exp-bcskip`) = **canonical P21** (v5.7.0 + 0001–0030, full test suite clean apart from the
    23 known failures, ladder row 67). `mfc-p20` = the previous version P20 (0001–0024); `mfc-iomem` has P20's source
    and is the A/B baseline.
  - `mfc-p2fa` (branch `exp-p2fasync`), `mfc-bcfast` (`exp-bcfast`), `mfc-cbcdead` (`exp-cbcdead`), `mfc-cbcq`,
    `mfc-cbcprio` = P20 + 0025, + 0025–0026, + 0025–0027, + 0025–0028, + 0025–0029 (the steps to P21). `mfc-c2pslab` (`exp-c2pslab`, on cbcdead) was not adopted.
  - Older stages (`mfc-p12` … `mfc-p18`, `mfc-rkb2`, …) are kept only so old results can be rebuilt.

## SC26 rules we follow
1. No physics shortcuts: same equations, schemes, grid, step count and FP64. Never loosen the `./mfc.sh test`
   tolerance (1e-12) or change outputs. Our A/B runs check results are bit-for-bit identical.
2. Source changes must be fit for an upstream pull request: pass the full `./mfc.sh test`, work for both OpenACC
   and OpenMP (use the FYPP macros), stay within ±5000 lines. Build/flag changes must be disclosed.
3. Score = MFC grindtime (ns per grid point per equation per RHS call) plus `simulation` wall time.
4. Never hide a failing test, a slowdown or a negative result.
5. Never bypass the pre-commit hook (`--no-verify`).

## Using the GPUs (user's instruction: H200s are expensive)
- Compile on the login node with `-j` 8 or less. **Never run simulations on the login node.**
- Jobs: `-A acd110018 -p dev`, **1 GPU by default**, short `--time` (15–20 min at most). 2–4 GPUs only for scaling
  studies; a full 8-GPU node only briefly; **no multi-node runs without asking.** Ask before any job set over ~30 GPU-minutes.
- Use the smallest problem and fewest steps that show the effect; cancel stuck jobs at once.
- Say GPUs × minutes before submitting. Submit through `harness/submit.sh`, which logs every job in `results/jobs.tsv`.

## Workflow
- **Commit often** (the graders want version control): before launching jobs, and again after with the raw results.
- `tools/sync.sh push` copies this tree to `nano4-u1131128:/work/u1131128/coding-adv1` (it refuses if there are
  uncommitted changes); `tools/sync.sh pull` brings `results/` back. Never hand-edit `results/`; every number names its job id and path.
- Timing: warm up, then at least 3 repeats (5 for final claims); report the median and spread; record GPU clocks, power and temperature.
- Never trust a subagent's claim about timings or correctness. Check the raw files yourself.
- After rewriting docs, run `tools/check_rewrite.py FILE…`. It flags any number the rewrite added and any broken links.

## nano4 facts
- Alias `nano4-u1131128` (the user's own account; needs OTP). Never use `*-chwang` or other people's aliases.
- Compute nodes `25a-hgpn*`: 8× H200 (141 GB), 2× Xeon 8480+ (112 cores), Slurm. Login nodes rotate and have
  different GPUs, so never benchmark on them.
- `/work/u1131128` is a 700 GB quota shared with the user's other projects; `harness/submit.sh` refuses below 10 GB free.
- Toolchain: `source scripts/env.sh` loads NVHPC 26.3 (CUDA 13.1, HPC-X Open MPI, CUDA-aware) and cmake 4.0.0. nsys and ncu are in the NVHPC bin dir.
  `/work` has ~60 GB free, so keep outputs small.
- `hpc <host> '<cmd>'` runs a single argument through the remote shell; use `bash -lc` when the command needs modules.
