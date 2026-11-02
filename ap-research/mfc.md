# MFC on nano4: optimization research brief (SC26 SCC)

How can MFC run faster on NCHC nano4, whose nodes each hold 8 NVIDIA H200 GPUs? A GPU is a chip with thousands of small
cores that do the same math on many numbers at once. We study MFC v5.7.0 (commit `0b3d56c`). Sections 6–7 use our own
measurements, each tagged with its Slurm job id. The coding deliverable is [`../report.md`](../report.md).

**Sources.** Background facts come from an older note pack (`ap-hw2/research/mfc_facts.md`) about a slightly newer MFC
(`1ececa3`). Where it disagrees with our measurements, we trust the measurements and say **Conflict**.

## 1. What MFC computes

MFC (Multicomponent Flow Code) simulates fast, squeezable flows of several fluids: shocks, bubbles, droplets. It is
about 40K lines of Fortran [repo:README.md]. Three programs run in turn: `pre_process` builds the grid (a 3D mesh of
small boxes, or cells), `simulation` moves the flow forward in time and does nearly all the work, and `post_process`
writes output for viewing.

**Equations.** The everyday choice is the **5-equation model** (Allaire 2002). It tracks each fluid's mass and volume
share, plus momentum and energy.

**Space.** MFC stores one average per cell and computes the flow (flux) through each cell face [repo:equations.md].
- **WENO** (weighted essentially non-oscillatory) estimates the value at a face from several groups of neighbour cells.
  It trusts the smooth groups more, so shocks do not cause fake wiggles.
- A **Riemann solver** takes the two estimates on either side of a face and works out the flux. HLLC is a common one.
- **IGR** replaces both with a different smoothing term. It powered the 2025 Gordon Bell finalist run [refs 7, 18],
  but it is a different scheme.

**Time.** Each time step has 3 sub-steps (RK3 stages). Each stage computes how fast every value is changing (the
right-hand side, RHS): swap edge cells with neighbours (§2.1), then per direction WENO → Riemann solver → flux
difference, then update.

**Our test case** is MFC's own `examples/3D_performance_test` [`../baseline/README.md`](../baseline/README.md): 2
fluids (8 equations), WENO5-M, HLLC, double precision (FP64), 201³ cells, 30 steps.

## 2. Parallel and GPU model

**Splitting the grid.** MPI (Message Passing Interface) lets copies of a program, called ranks, send each other data.
MFC cuts the grid into boxes, one per rank and one rank per GPU. Each box keeps a border of **ghost cells**, copies of
the neighbours' edge cells, like borrowed puzzle pieces. The **halo exchange** refreshes them every stage
([`../docs/background/research-halo-overlap.md`](../docs/background/research-halo-overlap.md) §0). The 6 faces go one
after another, and each swap waits until done. Faces on the outer wall use a **CBC** (characteristic boundary
condition), a rule that lets waves leave cleanly; ranks with more CBC walls do more CPU work.

**One source, two GPU languages.** OpenACC and OpenMP are two kinds of compiler comments that say "run this loop on the
GPU". MFC writes GPU code once with macros that become either one [repo:gpuParallelization.md]. A *kernel* is one
function launched on the GPU. Data stays on the GPU [ref 10]. Any `src/` change must keep both paths working.

**Case optimization.** `--case-optimization` bakes some case settings into the program as fixed numbers, so the
compiler can simplify loops. The docs claim "up to 10x" [repo:expectedPerformance.md]. **Conflict:** we measured 2.3×
on one H200 (jobs 600136, 600139; [`../docs/profiling-baseline.md`](../docs/profiling-baseline.md)). It is still the
biggest single lever, and every number below uses it.

**`rdma_mpi`.** This setting sends halos GPU to GPU over NVLink, the fast GPU-to-GPU wires, without a stop in CPU memory
[repo:case.md]. At 8 GPUs it cut the median step from 26.0 to 16.5 ms and the halo share of a stage from 53 % to 26 %
(profiling-baseline). At 4 GPUs: −27 % per step (602770 vs 604560, different nodes). Output stays bitwise identical
(every bit the same).

## 3. Where the time goes

**Grind time** is MFC's score: nanoseconds per grid point per equation per RHS; lower is better. MFC reports its
fastest stage, which flatters the code, so we also report the median **step time**.

**One GPU, unmodified v5.7.0.** Step 77.06 ms, grind 0.3982 (job 600407). The GPU is busy ≈96 % of the time. Kernel
shares (ncu, job 600146; ncu slows the clock, so its times are ≈25 % too long):

| Kernel group | Share | What holds it back |
|---|---|---|
| WENO5 | 34 % | each thread needs 188–196 *registers* (tiny private scratch slots), so few threads fit at once; mostly waiting on data |
| HLLC Riemann solver | 25 % | helper calls not pasted in (inlined), so data goes through slow local memory |
| Copy-like kernels | ≈25 % | only 24–37 % of peak memory speed |

- **A slowdown between versions.** HLLC takes 18.7 ms per step in v5.7.0 vs 13.2 ms in v4.9.3 (nsys 601030 vs
  600682), matching upstream issue #2088 [ref 13].
- **Wall time is mostly fixed cost.** A 1-GPU run takes 8.07 s; only about 2.3 s is time stepping.

**Several GPUs, unmodified.** At 8 GPUs with default halos, the halo exchange is 53 % of a stage; with `rdma_mpi`, 26 %.
The actual transfer is only ≈0.03 ms per face; the rest is waiting. GPU work is even within 2 %, but the rank with 3
CBC walls spends 0.9 ms more per stage on CPU work, and the others wait for it. MPI start-up (`MPI_Init`) takes
5.8–6.5 s at 4 ranks (602722/602764).

**After our changes** (job 602705; [`../docs/optimizations.md`](../docs/optimizations.md)): WENO5 29 %, HLLC 21 %,
copies 40 % of kernel time.

**Where others disagree with us.**
- MFC 5.0 paper: WENO + Riemann ≈ 50 % of wall time on NVIDIA [ref 4]. Our 1-GPU share (59 %) fits.
- **Conflict.** The SCC26 webinar calls the code "largely memory-bound", meaning it waits on memory more than on math
  [ref 10]. On H200 with NVHPC 26.3, no kernel is limited by memory speed: WENO waits on data at 10 % memory use, and
  copies run at a third of memory speed.
- **Conflict.** The webinar calls communication cheap [ref 10]. At 8 GPUs, default halos took 53 % of a stage.
- **Conflict.** "Nearly all time is in `simulation`" holds for compute only. A 30-step run at 4 GPUs spent 15.9 s of
  wall time for 0.6 s of stepping (606018); start-up dominates.

## 4. Building and running on nano4

`source scripts/env.sh` loads the NVHPC 26.3 compiler, HPC-X 2.25.1 MPI and cmake 4.0.0. Each compute node has 8× H200
(141 GB memory each, 700 W limit), 2× Xeon 8480+ CPUs and 10 network cards. Login nodes are for compiling only (`-j` ≤
8): `./mfc.sh build -i case.py --case-optimization --gpu acc -j 8`. Our test scripts
([`../docs/harness.md`](../docs/harness.md)) run `mpirun` through Slurm (the job queue) and log every job in
`results/jobs.tsv`.

**Fixes needed before anything ran** (none touches the math):
- `srun` cannot start this MPI → launch with `mpirun`.
- Open MPI pins work to cores the job may not use → `OMPI_MCA_hwloc_base_binding_policy=none` [ref 16].
- MPI file writing took 337 s or crashed → `OMPI_MCA_io=romio321`.
- Optional: `harness/nicbind.sh` points each rank at the network card next to its GPU [ref 14].

## 5. Correctness

**The test suite.** `./mfc.sh test` runs many small cases and compares each output with a saved known-good **golden
file**. A value passes if its error is ≤ 1e-12 (a few features allow a little more).

**Our bitwise check** (`harness/verify.py`). After every benchmark run, the final state must match unmodified v5.7.0
bit for bit, which is stricter than 1e-12. It holds for every change, every GPU count and both halo paths.

**Full suite on the final version.** 713 tests ran (jobs 622349–622356): **690 pass, 23 fail, 0 new failures**. All 23
fail the same way on unmodified v5.7.0 (recheck 606331;
[`../harness/known_test_failures.txt`](../harness/known_test_failures.txt)). So v5.7.0's suite is not clean on NVHPC
26.3 / H200. We report this rather than hide it.

## 6. Optimization ideas, ranked

"−X %" means X % less time. "Expected" is the guess made *before* the work. Details:
[`../docs/optimizations.md`](../docs/optimizations.md), [`../docs/ladder.md`](../docs/ladder.md); background studies on
[kernels](../docs/background/research-kernels.md), [halos](../docs/background/research-halo-overlap.md) and the
[environment](../docs/background/research-env-tuning.md).

**Done**, roughly by measured effect; all disclosed and low rules risk (§8):

| # | Idea | Expected | Measured |
|---|---|---|---|
| 1 | `--case-optimization` | up to 10× | 2.3× |
| 2 | `rdma_mpi` (GPU-to-GPU halos) | 4× halo [ref 5] | −27 %/step at 4 GPUs |
| 3 | K4b: compile the Riemann files as one unit | HLLC up to −45 % | HLLC 18.7 → 12.9 ms/step (602474) |
| 4 | K2: register cap 128 for the WENO file only | WENO −10 to −30 % | WENO5 25.4 → 18.0 ms/step (602559) |
| 5 | P2+P3: queue GPU work without waiting | −2 to −5 % at 8 GPUs | −5.8 % at 4 GPUs (604560/604561) |
| 6 | P4: skip cells nobody reads | −3 to −4 % | −2.5 / −3.5 / −4.0 % at 1/4/8 GPUs |
| 7 | P1: boundary calls without CPU round trips | −3 to −8 % at 8 GPUs | −2.3 % at 4 GPUs (601183 vs 601184) |
| 8 | Each rank uses its GPU's own network card | faster start-up | wall 13.03 → 9.28 s at 4 GPUs (606032); **rejected** without `rdma_mpi` (+4.5 %/step) |

**Not tried:** 9. rewrite copy kernels the #2087 way (−10 to −12 % of a stage; another NTHU team's open PR, which we
would extend next); 11. overlap halos with compute (−1 to −6 % at 8 GPUs); 12. one-round exchange with all 26
neighbours (−3 to −5 %); and smaller items. Lower precision or IGR (≈ 4× for IGR [ref 7]) is **forbidden** because it
changes the numerics.

**Rejected:** a WENO register cap of 96 (spills, 66.5 ms, 602567), NVHPC 25.9 (no gain, not bitwise), and other MPI
transport settings (no clear gain).

**Why they worked.**
- **K4b.** The compiler pastes small GPU helper functions into the caller (inlining) only when they sit in the same
  file. HLLC had 9 calls into other files, each passing data through slow local memory. One unit removed them all, and
  HLLC became faster than in v4.9.3. **Conflict:** the old pack says the compiler inlines across files
  [repo:gpuParallelization.md]; our GPU code and issue #2094 show it did not [ref 13].
- **K2.** Fewer registers per thread let twice as many threads run at once; a few values spill but stay in fast cache.
  A cap for all files was rejected upstream (#987) because it hurts other kernels [ref 13].
- **P3.** Each stage launched 44–68 kernels, and the CPU waited after each. That cost ≈1.2 ms per stage, whatever the
  GPU count.
- **P4.** WENO computed 4 extra ghost cells on each side, and an audit found nothing that reads them. The skipped share
  grows as boxes shrink (7.5 % at 201³, 14 % at 101³), so the gain grows with GPU count.

**What remains:** copy kernels, WENO waiting on data, and six one-at-a-time halo swaps at 8 GPUs (items 9, 11, 12).

## 7. Result summary

From [`../report.md`](../report.md) §1. Outputs are bitwise identical to unmodified v5.7.0. Speedup is the product of
two same-node ratios (v5.7.0 vs P3, then P3 vs final), so it can differ slightly from the ratio of the columns.

| GPUs | v5.7.0 step | Final step | Speedup | Jobs |
|---|---|---|---|---|
| 1 | 76.74 ms | **60.38 ms** | **1.27×** | 606017; 621788 |
| 4 (all `rdma_mpi`) | 23.10 ms | **17.03 ms** | **1.35×** | 606018; 622305 |
| 8 (v5.7.0 default, then `rdma_mpi`) | 21.94 ms | **9.75 ms** | **2.23×** | 605963 / 606019; 622306 |

- Strong-scaling efficiency (how close N GPUs get to N times faster) of the final build: 89 % at 4 GPUs, 77 % at 8.
  v5.7.0 at its defaults reaches 44 % at 8.
- The 4-GPU row shows the code changes alone. The 8-GPU row mixes code and settings; the fair v5.7.0 `rdma_mpi` run
  was not done.

## 8. SC26 rules and what they allow

**The competition** (16–18 November 2026) [refs 9, 11]: teams run HPL, HPL-MxP, MLPerf Training, WRF, MFC and a mystery
app. The whole system must stay under 10,000 W; over 11,000 W at any time can disqualify.

**MFC rules** (webinar [ref 10]): `src/` changes must pass the full test suite in a public GitHub pull request, within
±5000 lines. Compiler-option changes need only `./mfc.sh test` passing on the team's hardware, plus disclosure.
A maintainer wrote that changes must be **merged upstream by 2026-10-26** (#2093). They rejected large rewrites and
NVIDIA-only code, and accepted small, bit-identical loop changes
([`../docs/background/research-kernels.md`](../docs/background/research-kernels.md) §0).

**Our reading:** allowed, if disclosed, are case optimization, `rdma_mpi`, per-file flags, CMake and MPI settings, and
small portable `src/` patches that pass the suite. Not allowed: lower precision, IGR, other grids or step counts, looser
tolerances.

## 9. Open questions

1. Our `src/` patches are not yet submitted upstream. Do they count now that the 2026-10-26 deadline has passed?
2. v5.7.0 with `rdma_mpi` at 8 GPUs on the same node is unmeasured, so the 8-GPU gain from code alone is unknown.
3. Our H200 is 9 % slower than the published H100 on v4.9.3. The compiler difference is untested as a cause.
4. Power caps: the old pack expects them to be cheap because MFC is "memory-bound", but our data says WENO and HLLC
   speed follows the chip clock. The real cost is unmeasured, and caps need root.
5. Are the 23 known test failures a compiler issue or stale golden files?
6. In 30-step runs, MPI start-up and shutdown take ≈ 7.2 s at 4 GPUs (602722). The contest's problem size decides
   whether that matters.

## References

1. MFC source repository, MFlowCode. https://github.com/MFlowCode/MFC
2. MFC v5.7.0 release (2026-09-12). https://github.com/MFlowCode/MFC/releases/tag/v5.7.0
3. MFC docs, expected performance. https://raw.githubusercontent.com/MFlowCode/MFC/master/docs/documentation/expectedPerformance.md
4. Wilfong et al., "MFC 5.0: An exascale many-physics flow solver", Comput. Phys. Commun. 322, 110055 (2026). https://arxiv.org/abs/2503.07953
5. Radhakrishnan et al., "Method for portable, scalable, and performant GPU-accelerated simulation of multiphase compressible flow", CPC 302, 109238 (2024). https://arxiv.org/abs/2305.09163
6. Bryngelson et al., "MFC: An open-source high-order multi-component, multi-phase, and multi-scale compressible flow solver", CPC 266, 107396 (2021). https://arxiv.org/abs/1907.10512
7. Wilfong et al., "Simulating many-engine spacecraft: Exceeding 1 quadrillion degrees of freedom via information geometric regularization", SC'25 (Gordon Bell finalist). https://arxiv.org/abs/2505.07392
8. OpenACC offloading of MFC on AMD and NVIDIA GPUs. https://arxiv.org/abs/2409.10729
9. SC26 Student Cluster Competition. https://sc26.supercomputing.org/students/student-cluster-competition/
10. SCC26 MFC webinar slides (Wilfong, Vickers, Bryngelson, 2026-08-26). https://sc26.supercomputing.org/wp-content/uploads/2026/08/SCC26-MFC-Webinar-Slides.pdf
11. SCC26 introduction webinar slides. https://sc26.supercomputing.org/wp-content/uploads/2026/04/SCC26-Intro-Webinar-slides.pdf
12. NVIDIA H200 product page. https://www.nvidia.com/en-us/data-center/h200/
13. Upstream MFC threads: #2087 https://github.com/MFlowCode/MFC/pull/2087 ; #2088 https://github.com/MFlowCode/MFC/issues/2088 ; #2090 https://github.com/MFlowCode/MFC/pull/2090 ; #2092 https://github.com/MFlowCode/MFC/pull/2092 ; #2093 https://github.com/MFlowCode/MFC/pull/2093 ; #2094 https://github.com/MFlowCode/MFC/issues/2094 ; #2095 https://github.com/MFlowCode/MFC/pull/2095 ; #987 https://github.com/MFlowCode/MFC/pull/987
14. UCX FAQ. https://openucx.readthedocs.io/en/master/faq.html
15. NVIDIA HPC-X 2.25 known issues. https://networking-docs.nvidia.com/hpcxum/225/known-issues
16. Open MPI issue 12470 (hwloc and cgroup v2 binding). https://github.com/open-mpi/ompi/issues/12470
17. Ujeniya et al., H100 vs H200 under power caps (2026). https://arxiv.org/abs/2604.11391
18. Cao and Schäfer, information geometric regularization. https://arxiv.org/abs/2308.14127
