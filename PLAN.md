# Coding-Adv-HW-1 Plan — SC26 application optimization (MFC on nano4)

## Key dates
| Date | Milestone |
|---|---|
| 10/22 | Roadmap and repo skeleton |
| 10/23 | Env up on nano4 (own account), MFC builds, `./mfc.sh test` passes on H200 |
| 10/24 | Harness committed (verify + bench + env capture), baseline numbers |
| 10/25–10/26 | Config-level tuning ladder (no source changes) |
| 10/27–10/29 | Profiling-driven source optimizations + multi-GPU scaling |
| 10/30 | SC26 "Final Approach" webinar (11am ET); freeze measurements |
| 10/31 | Report + AGENT_LOG, final rerun from a clean tree |
| (11/02) | SC26 rule: app source changes must reach the committee ≥2 weeks before 11/16 |

## The one-line task
Make MFC as fast as possible on NCHC nano4 H200 under SC26 SCC rules, prove it is still correct, and explain why it runs at the speed it does.

## Step 0 — pick the app (decision)
| | MFC @ nano4 | WRF @ F1 |
|---|---|---|
| Access | `nano4-u1131128` (own account, OTP) | no own-account alias yet; all F1 aliases OTP and down |
| Hardware | H200 ×8/node, 151 nodes, partitions `dev`/`8gpus`/`16gpus`/… | Xeon 8480+ ×2, interactive/vis partitions only (`visual-dev` 8h) |
| Toolchain | `x86-nvhpc/26.3` (CUDA 13.1, HPC-X OpenMPI), `cuda/13.0`, `cmake/4.0.0` | gcc 8.5/10.4; no standalone oneAPI/netCDF/HDF5/PnetCDF found yet |
| Correctness bar | `./mfc.sh test` (tol 1e-12), golden-file compare | diffwrf vs reference run |
| Metric | grindtime (ns/gp/eq/rhs), defined by the MFC devs | "Timing for main" / wall time |
| Prior work | mfc-hw1 (build, nsys/ncu, hotspots), ap-hw2 MFC skill and repo | ap-hw2 WRF facts and repo only |
| Risk in 9 days | low–medium | high (build the dependency stack, WPS data, partition limits) |

**Decision: MFC on nano4** (pending user confirmation). WRF stays AP-Research-only.

## Step 1 — setup (10/22–10/23)
- [ ] `git init` and copy the hw3 skeleton: `CLAUDE.md` (hard rules, workflow, machine facts), `.gitignore`, `JOURNEY.md` (private), `AGENT_LOG.md`
- [ ] `reference/MFC` submodule pinned to a commit (v5.7.0 or the latest master at that time); never edited. Optimized fork goes in `mfc/` (branch `opt`)
- [ ] User runs `hpc up nano4-u1131128` (OTP). Do **not** use `*-chwang`/other personal aliases
- [ ] Adapt `tools/sync.sh` (hw3) to push the repo to `nano4:/work/u1131128/coding-adv1`
- [ ] Build: `module load x86-nvhpc/26.3`, `CC=nvc CXX=nvc++ FC=nvfortran MFC_CUDA_CC=90`, `./mfc.sh build --gpu acc --mpi`. Python via miniconda if 3.9 is too old. Lesson from hw1: delete `build/staging` when switching compiler or arch
- [ ] `./mfc.sh test --gpu` on one H200 inside an sbatch job (`-A acd110018 -p dev`). Record pass/fail counts

## Step 2 — harness, committed before any optimization
- [ ] `harness/cases.py`: target cases
  - `examples/3D_performance_test` (the MFC "standard" perf case)
  - `benchmarks/5eq_rk3_weno3_hllc` (plus `igr`, `viscous_weno5_sgb_acoustic` as secondary)
  - a 3D shock–cylinder or shock–bubble case like the SC26 practice problems
  - sizes chosen per GPU memory (grindtime vs gp/GPU curve)
- [ ] `harness/verify`: `./mfc.sh test` subset + per-case golden output compare (L2/max rel err vs the reference build). JSON out, non-zero exit on fail
- [ ] `harness/bench`: parse MFC grindtime **and** wall time of `simulation`; warm-up + ≥5 reps, median/IQR; `nvidia-smi` clocks/power/temperature before and after; job ID and commit in every record
- [ ] `harness/abtest.sbatch` (from hw2): alternate A/B builds on the same node to cancel thermal drift
- [ ] Reuse `mfc-hw1/profile.sh`, `hotspots.sh`, `mpi_timer.c` and `profile.mako` for nsys/ncu/PMPI
- [ ] **Gate commit**: harness plus baseline results before any change

## Step 3 — baseline
- [ ] 1× H200, default build (no case-opt), each target case, three sizes
- [ ] Compare to published reference grindtimes (H100 SXM 0.38, GH200 0.32 ns) to sanity-check the setup
- [ ] 1→8 GPUs on one node (strong and weak scaling); 2 nodes (`16gpus`) if time allows

## Step 4 — config-level ladder (no `src/` change; SC26-safe, disclose only)
Each rung gets an A/B against the previous rung and must pass verify:
1. `--case-optimization` (expected the biggest win, "up to 10×")
2. `--fastmath` (check tolerance impact explicitly)
3. NVHPC 26.3 vs 25.9; CMake/compiler flags (`-gpu=cc90,...`, maxregcount)
4. GPU-aware MPI: `rdma_mpi=T` with HPC-X UCX, plus rank↔GPU↔NUMA binding (8480+ has 2 sockets)
5. Ranks per GPU, domain decomposition shape, problem size per GPU
6. I/O off or `parallel_io` for the timed run, which grindtime already excludes
7. Power: log `nvidia-smi` power draw → grindtime per watt (SC26 has a 10 kW cap). Test a power limit only if `-pl` is permitted
8. Optional: GB200 (`gb200-dev`) with `--unified`, as a "what the competition box would see" data point

## Step 5 — profiling → source optimizations (PR-able, ≤5000 lines, must pass the full `./mfc.sh test`)
- [ ] nsys timeline: kernel share, D2D copies, halo pack/unpack, MPI waits
- [ ] ncu on the top kernels. From hw1 on H100 the candidates were:
  - WENO: 188 regs, about 12% occupancy (latency bound)
  - HLLC: memory bound
  - cons→prim conversion
  - halo pack/unpack
- [ ] Roofline per kernel (H200: about 4.8 TB/s, 67 TF FP64) → which kernels are near their limit
- [ ] Candidate changes, each with an ablation row:
  - OpenACC `vector_length`/`collapse`/`maxregcount` per kernel
  - fusing small kernels or packs
  - removing redundant copies
  - loop order and memory layout in the hot loops
- [ ] Record negative results too

## Step 6 — scaling and the final story
- [ ] Final ladder table: baseline → each config rung → each source change (grindtime, wall, speedup, verify status, job ID)
- [ ] Strong and weak scaling plots 1/2/4/8/16 GPUs with the communication fraction
- [ ] "Why this speed": roofline + fraction of HBM bandwidth achieved
- [ ] If source changes exist, prepare a clean diff/PR description (SC26 requires public PR + CI)

## Step 7 — deliverables
- [ ] `report.md` → PDF (reuse hw2 `build_report.py`/`report_figs.py`): Environment / Method / Baseline / Ladder / Profiling / Scaling / Negative results / Reproduction
- [ ] `AGENT_LOG.md` (prompts, task split, table of agent mistakes, code to defend)
- [ ] `harness/run_all.sh` reproduces every number from a clean tree

## Rules carried over from hw1–hw3
- Benchmark only in Slurm jobs, never on the login node; login nodes rotate and have different GPUs
- Commit before launching a job; never hand-edit `results/`; every number cites a job ID + results path
- One job per GPU for timing; A/B on the same node
- Never claim correctness without the verify JSON; never loosen tolerances
- Do not trust subagent claims about timing regions, so measure first

## Open questions (for the user / TA)
- Deliverable format and grading split for Coding-Adv-HW-1 (report? talk? video?)
- A prescribed case or MFC commit, or free choice?
- Is the SCC26 practice-problem material (Google Group) available to us?
