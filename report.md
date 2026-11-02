# MFC on NCHC nano4 H200 — making an SC26 application faster without changing its answer

Coding-Adv-HW-1. We made **MFC v5.7.0** (`0b3d56c`), the SC26 Student Cluster Competition application, run faster on
nano4's H200 GPUs without changing its answer by a single bit. MFC simulates moving gases and liquids: it cuts space
into small boxes (*cells*) and moves time forward in *steps*. A GPU is a chip with thousands of small cores.

Every number cites a Slurm job (a numbered batch job). Our changes are patches in `patches/opt/`: §1–§10 are the
10-31 report (`0001…0006`), §11 the later work P7–P20. Every rejected idea: `docs/ladder.md`. Agent mistakes:
`AGENT_LOG.md`.

**Update (2026-11-03, after the deadline):** at 1 GPU, in one same-node A/B (job 680943, every run bitwise identical),
v5.7.0 takes 77.79 ms per step and P20 (patches 0001–0024) takes **29.83 ms: 2.61× faster**. The full GPU test suite on
P20 shows only the 23 failures that v5.7.0 also has. Two more patches, still waiting for their full suite, bring it to
29.49 ms (2.64×). A third (0027, CBC skips a copy its own kernels overwrite) takes another 1.6 % off in a second
same-node A/B (683029), about 29.0 ms or 2.68× if the two A/Bs are multiplied. Details in §11.

## 1. Result

*Step* = median time of one step (steps 2–30) on the slowest GPU. *Grind* = MFC's cost figure: nanoseconds per cell,
per equation, per RHS (one "how fast is everything changing" calculation). Lower is better.

We compare builds on the same node in the same job (an *A/B*): v5.7.0 vs P3 (patches 0001–0005) in one job, P3 vs
the final build P4 (+ 0006) in another; the speedup multiplies the two ratios. All outputs are bitwise identical.

| GPUs | v5.7.0 step | P3 step | Final step | Speedup | v5.7.0 grind | Final grind | Jobs |
|---|---|---|---|---|---|---|---|
| 1 | 76.74 ms | 61.88 ms | **60.38 ms** | **1.27×** | 0.3973 | 0.3123 | 606017; 621788 |
| 4 (all `rdma_mpi`) | 23.10 ms | 17.72 ms | **17.03 ms** | **1.35×** | 0.1184 | 0.0876 | 606018; 622305 |
| 8 (v5.7.0 default, then `rdma_mpi`) | 21.94 ms | 10.22 ms | **9.75 ms** | **2.23×** | 0.1129 | 0.0502 | 605963 / 606019; 622306 |

![Same-node step times](docs/fig/scaling.png)

*Strong-scaling efficiency* asks: do N GPUs give N times the speed? Final build: 89 % at 4 GPUs, 77 % at 8. v5.7.0 at
its defaults: 44 % at 8.

Caveat: the 8-GPU row compares v5.7.0 at its defaults with our settings (`rdma_mpi=T`). The fair v5.7.0 `rdma_mpi`
run never ran: an agent bug (AGENT_LOG #14) used up the budget. In a different job, v5.7.0 with `rdma_mpi` took
16.5 ms per step at 8 GPUs (`docs/profiling-baseline.md`).

## 2. Rules we held ourselves to
- Same equations, methods, grid, steps and FP64 precision. No looser tolerances, no changed outputs.
- **Bitwise gate on every run:** the final state (65 M numbers) must match v5.7.0 in every bit (`harness/verify.py`).
  Every `src/` change must pass MFC's test suite (`./mfc.sh test`, tolerance 1e-12) with no failure that unmodified
  MFC does not also show.
- Source changes must be fit to send upstream: small, and portable to both GPU paths (OpenACC and OpenMP, two ways of
  telling the compiler "run this on the GPU").
- Timing: warm-up, ≥3 runs (final: 5), medians, A/B on one node. Failures are reported.

## 3. Setup
- nano4 nodes: 8× H200 (141 GB, NVLink), 2× Xeon 8480+, 10 network cards (HCAs). NVHPC 26.3 (CUDA 13.1, OpenACC),
  HPC-X 2.25.1 Open MPI 4.1.9. MPI runs one copy of the program (*rank*) per GPU; ranks send each other messages.
- Case: MFC's benchmark `examples/3D_performance_test` (two fluids, WENO5-M, HLLC, RK3, FP64, 201³ cells, 30 steps).
- Scripts in `harness/` run, log (`results/jobs.tsv`), test and check every job.
- Setup fixes (no effect on the math): `mpirun` instead of `srun`, no OMPI core binding, ROMIO instead of OMPIO.

## 4. Starting point: where the time went
Each step has three sub-steps (*RK stages*). **WENO5** estimates the values on the walls between cells, and the
**HLLC Riemann solver** decides what flows through each wall. A *kernel* is one function the
GPU runs on many cells at once.

- **1 GPU:** 77.06 ms per step (600407). WENO5 34 %, HLLC 25 %, plain copy kernels ≈25 % using only ~30 % of memory
  speed (ncu 600146; `docs/profiling-baseline.md`). MFC's published 0.38 ns uses a different metric
  (`baseline/README.md`).
- **8 GPUs:** each GPU owns a box of cells and needs copies of its neighbours' edge cells (*ghost cells*). Swapping
  them (*halo exchange*) took 53 % of a stage, going through CPU memory. With `rdma_mpi=T`, the rank with more CBC
  faces (CBC = a special rule for the outer walls that lets waves leave) spent 0.9 ms more per stage on the *CPU*
  (tiny kernels + waits), and the others waited for it.
- **Plan:** first stop the CPU from waiting on the GPU so often, then make the kernels faster.

## 5. What we changed, and what it gained

Ladder at 1 GPU (each rung on top of the one before; all bitwise):

| Rung | Step | Grind | Job |
|---|---|---|---|
| v5.7.0 | 77.06 ms | 0.3982 | 600407 |
| P1 CBC async | 75.98 ms | 0.3935 | 601152 |
| K4b Riemann unity build (final slice: 70.00 ms, 602531) | 70.42 ms | 0.3632 | 602474 |
| K2 WENO register cap | 62.99 ms | 0.3255 | 602559 |
| P3 async per-stage kernels (same-node A/B 62.87 → 61.79) | 61.79 ms | 0.3201 | 604561 |
| P4 transverse-interior reconstruction (same-node A/B 61.90 → 60.38) | 60.38 ms | 0.3123 | 621788 |

![Ladder at 1 GPU](docs/fig/ladder_1g.png)

**P1 — boundary code without CPU waits** (`0001`). Each CBC call sent ~12 small GPU jobs, and the CPU waited after
each one (~230 µs per call), like a cook standing at the oven after every dish. Now the jobs are queued (*async*) and
the CPU waits once. −1.4 % at 1 GPU, −2.3 % at 4 GPUs (601183 vs 601184, different nodes).

**K4b — let the compiler paste in the Riemann helpers** (`0002`+`0003`, CMake + 3 lines). HLLC was 42 % slower than in
v4.9.3. nvfortran *inlines* GPU helper routines (pastes their body into the caller) only within one source file, so
9 real calls remained, each passing data through slow memory. (A compiler message misled us at first, AGENT_LOG #11.)
Fix: compile the Riemann modules and the ones they use as one unit. HLLC 18.7 → 12.9 ms/step.

**K2 — let more WENO threads run at once** (`0004`, one compiler flag, disclosed). *Registers* are each core's tiny,
fastest storage, like desk space: the more each thread needs, the fewer threads fit. WENO5 needed 188–196. A cap of
128 doubles the threads; a few values *spill* to slower memory, but to the fast L1 cache. Caps 168 / 128 / 96 → 64.0 / 63.0 / 66.5 ms per step.

**P3 — no CPU wait per kernel** (`0005`, 10 files). Each RK stage still launched 44–68 kernels and ~45 small updates,
each followed by a CPU wait: ~1.2 ms of idle GPU per stage, which does not shrink with more GPUs. Now the 115
directives that run every stage are queued, with one wait before data goes to MPI. Same-node
A/B: 4 GPUs 18.81 → 17.71 ms (−5.8 %); 1 GPU −1.7 %.

**P4 — compute only what the Riemann solver reads** (`0006`). WENO also filled 4 ghost cells on each side in the sideways
(*transverse*) directions, which the only reader, the Riemann solver, never looks at. Now it skips them. The skipped share grows as boxes shrink (7.5 % of a sweep at 201³ per GPU, 14 % at
101³), so more GPUs gain more. Same-node A/B against P3: 1 GPU **−2.5 %** (621788), 4 GPUs **−3.5 %** (622305),
8 GPUs **−4.0 %** (622306). Bitwise in all 8 runs.

**`rdma_mpi=T`** (MFC input setting, disclosed): ghost cells go GPU→GPU over NVLink instead of through CPU memory.
−27 % per step at 4 GPUs (602770 vs 604560, different nodes); bitwise.

**T0.4 — faster MPI start-up** (environment, disclosed). `MPI_Init` took 5.8–6.5 s at 4 ranks (602722/602764),
because UCX (the layer under MPI) opens all 10 network cards. `harness/nicbind.sh` gives each rank only the card next
to its GPU. With CPU-memory halos each step got 4.5 % slower (rejected); with `rdma_mpi=T` it is free: 4 GPUs, same node (606032), step 17.65 → 17.69 ms (noise), **wall 13.03 → 9.28 s (−29 %)**.

## 6. What did not work
| Idea | Result | Job |
|---|---|---|
| NVHPC 25.9 instead of 26.3 | no gain, not bitwise | ladder row 1 |
| Fixed sweep direction in HLLC (K4a) | worse (255 registers); real cause was missing inlining | ladder row 3 |
| WENO `vector_length(64/96)` | registers rose to 206 / 192 in a compile check; not timed | `results/k2/kcheck_vector_length.txt` |
| WENO register cap 96 | too many spills, 66.5 ms | 602567 |
| HCOLL/UCC off | no clear effect | 602638/9, 602683 |
| one network card per rank, CPU-memory halos | −3 s start-up, +4.5 % per step | 602770/1 |
| `ob1`/vader, UCX shm | ranks could not reach each other / no gain | 602704/26 |

## 7. Correctness
- Every benchmark run: final state bitwise identical to v5.7.0.
- **Full test suite on P4** (713 tests ran, jobs 622349–622356): **690 pass, 23 fail, 0 new failures**. P3 gave the
  same 23.
- **All 23 fail the same way on unmodified v5.7.0** here (606331). They are 17 `model_eqns=3` / viscous IBM cases,
  five examples and one reactive-burn case that does not start (`harness/known_test_failures.txt`). So our changes
  alter no test result, but v5.7.0's suite is not clean on NVHPC 26.3 / H200, and we say so.
- Two holes in our own scripts, found and closed: `verify.py` once passed a run that never timed anything
  (AGENT_LOG #12); 1-GPU test jobs could not start 2-rank tests.

## 8. Why it runs at this speed now
Per-kernel profile (ncu 600146 vs 606033, P3; clocks locked, so times are longer but ratios hold).

| Kernel (per call) | v5.7.0 | P3 | Why |
|---|---|---|---|
| WENO5 | 3.39–3.49 ms; 188–196 regs; 12 % warps active | **2.34–2.56 ms**; 128 regs; 24 % | K2: twice the threads |
| HLLC | 2.13–2.48 ms | **1.57–1.62 ms** | K4b: helpers inlined |
| Copy-like (pack, flux difference, RK update, conversion) | 0.72–1.19 ms; 24–37 % of memory peak | unchanged | busy with index math, not memory |
| All listed kernels | 35.10 ms | **28.20 ms (−19.7 %)** | |

![Kernel time by role](docs/fig/kernels_1g.png)

- WENO5 still waits more than it computes; the copy kernels are busy computing array positions. Both are next.
- 8 GPUs (P3): the halo exchange takes 0.36–0.72 ms per stage (606019), as 6 one-after-another `MPI_Sendrecv`s with
  no compute running alongside.

## 9. What we would do next
1. Compute the interior while the halo exchange runs (possible now that P3 removed the CPU waits).
2. Merge or skip the plain copy kernels (40 % of kernel time).
3. Send P1/K4b/P3/P4 upstream as small PRs.

## 10. Reproduce
On nano4, from this repository mirrored to `/work/u1131128/coding-adv1`:
```
bash harness/reproduce.sh build    # v5.7.0 + every patch in patches/opt/ (0001-0024), case-opt + generic builds
bash harness/reproduce.sh run      # the final 1/4/8-GPU same-node sets (harness/specs/final_*g.tsv)
bash harness/reproduce.sh verify   # bitwise gate + median step per run
```
Multi-GPU runs with `rdma_mpi` add `WRAP=$ROOT/harness/nicbind.sh` (T0.4).

## 11. Later work (2026-11-01, updated 11-02): P7–P20

Same rules: every run bitwise identical to v5.7.0, A/B on one node against the rung below. Details:
`docs/ladder.md` and `docs/optimizations.md`.

**1 GPU** (v5.7.0 vs P16, same node, 2 rounds × 5 runs, job 669752):

| | v5.7.0 | P16 | Gain |
|---|---|---|---|
| Step | 77.06 ms | **36.23 ms** | **2.13×** |
| Grind (ns) | 0.3968–0.3985 | 0.1872–0.1877 | 2.12× |
| Wall, default setup | 7.31 s | 5.65 s | 1.29× |

v5.7.0 vs P18 (job 670158): step **76.75 / 76.74 → 34.39 / 34.30 ms, 2.24×**; bitwise. P19 takes another 3.4 % off
(670619) and P20 another 10.5 % (671002): about 2.59× if the A/Bs are multiplied.

**Direct check, v5.7.0 vs P20 (2026-11-03, same node, 2 rounds × 3 runs, job 680943; all bitwise):**

| | v5.7.0 | P20 | + 0025 | + 0025 + 0026 |
|---|---|---|---|---|
| Step | 77.806 / 77.778 ms | 29.837 / 29.815 ms | 29.635 / 29.636 ms | **29.511 / 29.460 ms** |
| vs v5.7.0 | 1× | **2.61×** | 2.62× | 2.64× |
| Grind (ns, first run) | 0.4027 | 0.1538–0.1539 | 0.1527 | 0.1519 |

0025 runs the CBC primitive-to-flux conversion on the GPU queue instead of making the CPU wait; 0026 fills each ghost
value with its own GPU thread. Both are in `patches/pending/`, not `patches/opt/`, because the full test suite has not
run on them yet. The first try of this job (680922) stopped itself in 4 s: its node had the power brake on.

0027 (also in `patches/pending/`): with WENO3/5 the CBC kernels overwrite every flux value the boundary routine copies
back, so it no longer copies the fluxes in, and copies back only the layers it changed. Job 681650 (hgpn011):
29.501 / 29.501 → 29.021 / 29.014 ms; job 683029 (hgpn001): 29.265 / 29.252 → 28.807 / 28.802 ms; −1.6 % both times,
every arm bitwise. All 34 CBC tests pass (682349). Multiplying the two A/Bs gives about 29.0 ms, about 2.68×.

**Several GPUs** (`rdma_mpi`, same node, P11 vs P18; bitwise):

| GPUs | P11 step | P18 step | Change | Job |
|---|---|---|---|---|
| 4 | 12.294 ms | **10.131 ms** | −17.6 % | 670516 |
| 8 | 7.344 ms | **6.115 ms** | −16.7 % | 670540 |

Scaling efficiency drops to about 85 % at 4 GPUs and 70 % at 8 (P4: 89 % and 77 %): the compute shrank, the halo
exchange did not. The fair v5.7.0 multi-GPU A/B was not run.

**What changed** (one patch each). Two terms: a *slab* is one big array holding many fields; a *descriptor* is the
small card Fortran keeps for each array (start, size), which the GPU must read before it can find a value.

| Rung | Patch | Change | 1 GPU step | Job |
|---|---|---|---|---|
| P7 | 0007–0009 | Leaner copy kernels and buffers | 60.95 → 45.10 ms | 664597 |
| P8–P11 | 0010–0014 | Merged steps; register cap 128; no CBC CPU waits | → 42.04 ms | 664763–664895 |
| P12 | 0015 | **HLLC computes its own WENO5 values** in one kernel per direction | → 37.71 ms (−10.5 %) | 668372 |
| P13 | 0016 | Flux slabs; all three flux differences in one pass | → 36.83 ms (−2.4 %) | 669254 |
| P14 | 0017 | Flux differences merged into the RK update | → 36.24 ms (−1.9 %) | 669327 |
| P15 | 0018 | Build fix: chemistry GPU builds failed to link since 0012 | — | suite |
| P16 | 0019 | Check the saved state for NaN on the GPU, not the CPU | save 1.1–1.25 → 0.6–0.74 s | 669490 |
| P17 | 0020 | Load the next inputs one round early | 36.66 → 35.90 ms (−2.1 %) | 670011 |
| P18 | 0021 | Same idea in the RK update | 35.88 → 34.51 ms (−3.8 %) | 670088 |
| P19 | 0022 | RK update reads flux slabs directly (one descriptor, not three) | 34.27 → 33.12 ms (−3.4 %) | 670619 |
| P20 | 0023–0024 | Fixed-size slabs (0023); no self-copies in cons→prim (0024) | 33.09 → **29.63 ms (−10.5 %)**, bitwise | 670687, 670779, 670811, 671002 |

P20 came from a line-by-line profile (ncu 670130): 16 % of the merged kernel's instructions only found addresses
through descriptors.

**Correctness.** Full suite on P15 (jobs 669500–669511), P18 (670591–670598 + make-up 671033) and P20 (0001–0024, so
it covers P19; jobs 672459–672470): each time the same 713 tests, and the failures are exactly the 23 known ones. The
first P18 run silently skipped 59 tests; a make-up job ran them, and `run_suite.sh` now lists tests explicitly. MFC's
39 "Convergence" tests try to rebuild MFC on the GPU node and failed or timed out there; they say nothing about the math and are
now left out.

**Wall time (environment setting, disclosed).** At 1 GPU the biggest cost outside the steps was `MPI_Init`, which
opens the network cards even for one rank. Not loading UCX at all
(`OMPI_MCA_pml=ob1 OMPI_MCA_btl=self,vader OMPI_MCA_osc=^ucx`) cut the median wall time from 5.556 s (669785) to
**4.300 s** (669940). With P16, 1-GPU wall goes from 7.31 s (v5.7.0) to about 4.3 s, about 1.7× (different jobs). This
is for one rank only; multi-GPU runs need a GPU-aware transport, which we did not compare.

**Run directory in node-local memory (setting, disclosed; 2026-11-03).** With `ob1` on, a CPU-sampling profile
(684723) showed what is left of start-up is reading the 520 MB initial state from Lustre, and the save is a slow
pageable copy plus the Lustre write. Running the case directory in `/dev/shm` and copying it back afterwards, untimed,
cut the median wall time from 4.039 to **3.810 s (−5.7 %)** on the exp-cbcdead binary (684750: 3 rounds × 5 reps,
every round agrees; final state bitwise). A bigger OpenACC copy buffer for the save made it slower (684697).

**What did not work (all bitwise, all measured):** WENO kernel `collapse(4)` +15.7 %; other register caps on the
merged kernel (+0.8 % to +7 %); RK update variants (+3.6 %, +7.5 %, +15 %); saving through an MPI-IO memory datatype
(+70 %), a staging buffer or ROMIO hints (no gain); packed WENO coefficients (no gain, 670870); RK update per (cell,
equation) (+1.7 ms, 670933); delayed velocity stores in cons→prim (slower, 671032).

**Where the time is now** (P20, 1 GPU, per RK stage, nsys 670902): merged WENO5+HLLC 6.87 ms (68 %), RK update
1.50 ms (15 %), cons→prim 0.63 ms, boundaries 0.25 ms.

**Reproduce.** `harness/reproduce.sh` applies every patch in `patches/opt/` (0001–0024). The canonical nano4 tree
is branch `p20` (worktree `mfc-p20`); its full suite shows only the known failures.
