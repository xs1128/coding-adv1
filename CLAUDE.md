# CLAUDE.md — rules for agents working in this repo

Coding-Adv-HW-1: optimize an SC26 Student Cluster Competition application. The coding part picks one of
WRF (F1) / MFC (nano4); **we do MFC on nano4 (H200)**. Grading criteria not yet published. Deadline: end of Oct 2026.
Plan: `PLAN.md`. Private notes: `JOURNEY.md` (gitignored). Agent mistakes: `AGENT_LOG.md`.

## App
**MFC** v5.7.0 — https://github.com/MFlowCode/MFC, commit `0b3d56c8e1c9a3aa8d112681b72c87ab69fe5f13`.
- `reference/MFC` — pinned submodule (read-only, for source reading/research).
- nano4 `$ROOT/mfc` — working clone where builds happen; optimizations go on branch `opt` there and are
  exported as patches into `patches/` here (so the history of every source change lives in this repo).

## SC26 rules we follow (spirit of scientific computing)
1. No physics/numerics shortcuts: same equations, schemes, grid, steps and FP64 unless an explicit, labelled
   experiment. Never loosen `./mfc.sh test` tolerances (1e-12) or change outputs.
2. `src/` changes must be upstream-PR-able: pass the full `./mfc.sh test`, portable (OpenACC *and* OpenMP paths
   via FYPP macros), within ±5000 lines. Build/flag changes: disclose, and show `./mfc.sh test` passes.
3. Figure of merit = MFC grindtime (ns / gridpoint / equation / RHS) plus wall time of `simulation`.
4. Never hide a failing test, a regression, or a negative result.

## Compute etiquette (user instruction — H200s are expensive)
- Compile on the login node with modest `-j` (≤8). **Never run simulations on the login node.**
- Jobs: `-A acd110018 -p dev`, **1 GPU by default**, tight `--time` (≤15–20 min). 2–4 GPUs for scaling studies;
  a full 8-GPU node only briefly and only when needed; **no multi-node without asking the user.**
- Smallest problem that shows the behaviour; short step counts; cancel stuck jobs immediately.
- Before submitting, state GPUs × minutes. Log every job in `results/jobs.tsv`.

## Workflow
- **Commit often** (the graders want version control): commit before launching jobs, commit raw results after.
- `tools/sync.sh push` mirrors this tree to `nano4-u1131128:/work/u1131128/coding-adv1` (refuses a dirty tree);
  `tools/sync.sh pull` brings `results/` back. `results/` is never hand-edited; every number cites job id + path.
- Timing: warm-up, ≥3 reps (≥5 for final claims), median + spread; record `nvidia-smi` clocks/power/temp.
- Never trust a subagent's claim about timing regions or correctness — verify against the raw files.

## Machine facts (nano4)
- Alias `nano4-u1131128` (user's own account; OTP; never use `*-chwang`/other people's aliases).
- Compute nodes `25a-hgpn*`: 8× H200 (141 GB), 2× Xeon 8480+ (112 cores), Slurm 25.11. Login nodes rotate
  (lgn01/02/04/05) and have different GPUs — do not benchmark there.
- Toolchain: `source scripts/env.sh` → NVHPC 26.3 (CUDA 13.1, HPC-X 2.25.1 Open MPI 4.1.9, CUDA-aware/UCX),
  cmake 4.0.0. nsys/ncu are in the NVHPC bin dir. `/work` has ~60 GB free — keep outputs small.
- `hpc <host> '<cmd>'`: single arg goes to the remote shell; use `bash -lc` for module-dependent commands.
