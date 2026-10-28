# MFC on nano4: optimization research brief (SC26 SCC)

This brief covers how to make MFC run faster on NCHC nano4 (8× NVIDIA H200 per node) for the SC26 Student Cluster
Competition (SCC). The target is MFC v5.7.0 at commit `0b3d56c`, pinned in `reference/MFC`. Sections 1–5 explain the
code and the toolchain. Sections 6–7 draw on our own measured results (Slurm job ids, `results/` paths). The coding
deliverable is [`../report.md`](../report.md); this brief gives the research view around it.

**Sources.** The background facts come from an older knowledge pack (`ap-hw2/research/mfc_facts.md`). Its `[repo:…]`
tags refer to MFC master `1ececa3`, two weeks after v5.7.0. Where it disagrees with our measurements, we trust the
measurements and say so (marked **Conflict**).

## 1. What MFC computes

MFC (Multicomponent Flow Code) simulates compressible multiphase and multi-component flows, such as shocks, bubbles
and droplets. It is Fortran 2008 with the Fypp preprocessor, about 40K lines, MIT licence [repo:README.md].

**Three executables** run in sequence and pass data through files [repo:architecture.md.in]:
- `pre_process` builds the grid and the initial condition from geometric "patches";
- `simulation` advances the solution in time and does nearly all the compute;
- `post_process` writes derived fields (Silo-HDF5 or binary) for ParaView or VisIt.

**Equations** (`model_eqns`) [repo:toolchain/mfc/params/definitions.py]:
- `1`, Γ/Π∞ (`"gamma_law"`): a single mixture with mixture γ and π∞.
- `2`, the **5-equation model** (`"5eq"`, Allaire 2002), the workhorse. Its state is per-fluid partial density αᵢρᵢ, momentum ρu, total energy ρE and
  volume fractions αᵢ. `alt_soundspeed = T` gives the Kapila variant.
- `3`, the **6-equation model** (`"6eq"`, Saurel 2009). It adds per-phase internal energies and relaxes pressure at
  every RK stage. It requires HLLC.
- The 4-equation model existed up to v5.6.1 and is gone in v5.7.0 [tag:v5.6.1].
- Closure: stiffened-gas equation of state, p = (γ−1)ρe − γπ∞. Other EOS families exist (ideal gas, Mie–Grüneisen, JWL, Vinet).

**Spatial scheme.** MFC is a finite-volume code. It reconstructs primitive variables at cell faces and computes a flux
there [repo:equations.md].
- **WENO** (weighted essentially non-oscillatory) reconstruction blends several stencils, using smoothness weights to avoid oscillations
  at shocks. Orders 1, 3, 5, 7. Variants: WENO-JS (default), WENO-M (`mapped_weno`), WENO-Z, TENO.
- MUSCL (`recon_type = 2`) is a second-order alternative.
- A **Riemann solver** turns the left and right face states into a flux. Choices (`riemann_solver`): 1 HLL, 2 HLLC
  (HLL with a restored contact wave), 4 HLLD (MHD or hypoelastic), 5 Lax–Friedrichs. The exact solver (3) was removed
  in v5.4.0 [repo:definitions.py].
- **IGR** (information geometric regularization, `igr = T`) replaces WENO and the Riemann solver with an elliptic
  "entropic pressure" term. It powered the 2025 Gordon Bell finalist run [refs 7, 18]. It is a different scheme.

**Time stepping.** `time_stepper` 1–3 selects RK1, RK2 or RK3. RK3 is the 3-stage strong-stability-preserving (SSP) Runge–Kutta method of
Gottlieb & Shu. Each stage evaluates one right-hand side (RHS). Per stage: conservative→primitive conversion, halo
exchange, then per direction WENO → Riemann solver → flux difference, then the RK update [repo:architecture.md.in].

**Case files.** A case is a Python script that prints a JSON dictionary of parameters. Logicals are `'T'`/`'F'`. The
toolchain turns it into Fortran namelists (`*.inp`) [repo:case.md]. See Appendix A.

**Our benchmark case** is MFC's own `examples/3D_performance_test` [`../baseline/README.md`](../baseline/README.md):
- 5-equation model, 2 fluids, so 8 equations (`sys_size = 8`);
- WENO5-M, HLLC, RK3, FP64, stretched grid;
- 201³ cells (m = n = p = 200), 30 steps.

The docs say "158-cubed"; that text is stale, and the case file uses 201³.

## 2. Parallel and GPU model

### 2.1 MPI decomposition and halo exchange
MFC splits the grid into Cartesian blocks with `MPI_Cart_create`, one block per rank. Each block has **ghost cells**
(copies of neighbour cells), `buff_size = 4` deep for WENO5. The **halo exchange** fills them before each RHS
([`../docs/research-halo-overlap.md`](../docs/research-halo-overlap.md) §0):
- one exchange of the 8 primitive variables per RK stage;
- faces handled strictly in order x−, x+, y−, y+, z−, z+, each with a pack kernel, a blocking `MPI_SENDRECV` and an
  unpack kernel;
- y and z messages also carry x (and y) ghosts, so edges and corners arrive by 2–3 sequential hops;
- for 201³ the decomposition is 2×1×1, 2×2×1 and 2×2×2 on 2, 4 and 8 ranks. There is no user override.

At 2×2×2 each rank has 3 MPI faces and 3 physical faces. The `end` faces use a **CBC** (characteristic boundary
condition, `bc = −6`). The CBC-heavy rank (1,1,1) therefore does more host work than rank (0,0,0).

### 2.2 OpenACC / OpenMP offload through Fypp macros
GPU code is written once with Fypp macros in `src/common/include/*.fpp` [repo:gpuParallelization.md]. For example,
`GPU_PARALLEL_LOOP` becomes `!$acc parallel loop gang vector collapse(3) default(present)` (OpenACC) or
`!$omp target teams distribute parallel do collapse(3)` (OpenMP offload). Other macros cover data movement
(`GPU_UPDATE`, `GPU_ENTER_DATA`), device routines (`GPU_ROUTINE`) and waits (`GPU_WAIT`).
- Kernel shape: 3 collapsed spatial loops in parallel; the inner equation loop runs serially per thread [ref 10].
- Data stays on the GPU. Large copies happen once at start-up, and device→host only at output [ref 10].
- Build with `--gpu acc` (OpenACC, preferred on NVIDIA) or `--gpu mp` (OpenMP) [ref 10].
- Any `src/` change must keep both paths working. Our P3 patch emits `async` only on NVHPC; the OpenMP path is
  unchanged.

### 2.3 Case optimization
`--case-optimization` turns selected case parameters into compile-time constants through Fypp `#:set` in `case.fpp`.
Examples are `weno_order`, `num_fluids`, `mapped_weno` and `viscous` [repo:toolchain/mfc/case.py]. The compiler can then
unroll loops and drop dead branches. The binary must be rebuilt for each case.
- Claimed gain: "up to 10x" [repo:expectedPerformance.md]; ~10× on GPU, ~2× on CPU [ref 4].
- **Conflict.** We measured 2.3× on one H200: grind 0.930 (generic) vs 0.397 (case-optimized), jobs 600136 and
  600139 ([`../docs/profiling-baseline.md`](../docs/profiling-baseline.md)). It is still the biggest single lever,
  and every number in §6–7 uses it.

### 2.4 `rdma_mpi`
`rdma_mpi = 'T'` is a case parameter. It passes device buffers straight to a CUDA-aware MPI, so halos skip the host
[repo:case.md]. RDMA (remote direct memory access) here means GPU-to-GPU copies without host staging.
- It is OpenACC-only: `m_checker.fpp` rejects it in OpenMP builds (research-halo-overlap §0.4).
- On nano4, UCX (the HPC-X transport layer) uses `cuda_ipc` over NVLink. The OSU test (job 600232) gave 292 GB/s
  at 4 MB and 3.1 µs latency at 8 B.
- Effect at 8 GPUs (v5.7.0, nsys): median step 26.0 → 16.5 ms; halo share of a stage 53 % → 26 %
  (profiling-baseline). At 4 GPUs: −27 % per step (602770 vs 604560, different nodes; report §5).
- Output stays bitwise identical. The first step costs 175 ms once, for IPC handle setup.
- Background: CUDA-aware MPI gave 4× faster halo exchange on Summit [ref 5].

## 3. Where the time goes

**Grind time** is MFC's figure of merit: wall nanoseconds per grid point per equation per RHS. MFC prints the
minimum over stages after 2 warm-up steps, then the maximum over ranks [repo:m_time_steppers.fpp]. That minimum is
optimistic, so we also report the median **step time** from NVTX (NVIDIA tool-extension) ranges.

### 3.1 One GPU, unmodified v5.7.0 (our profile)
- Step 77.06 ms, grind 0.3982 (job 600407, 5 reps; [`../baseline/README.md`](../baseline/README.md)).
- The GPU is busy for ≈96 % of a stage, with 66 kernel launches per stage (nsys, profiling-baseline).
- Kernel shares from ncu (Nsight Compute, job 600146; clocks locked at 1.48 GHz, so durations are ≈25 % inflated):

| Kernel group | Share of stage | What limits it |
|---|---|---|
| WENO5 reconstruction (×3 directions) | 34 % | 188–196 registers → 12 % of warps active; FP64 pipe 31 %; latency-bound |
| HLLC Riemann solver (×3) | 25 % | local-memory traffic from non-inlined device calls; long-scoreboard stalls |
| Copy-like kernels (pack, finalize, flux difference, RK update, conversion) | ≈25 % | 24–37 % of DRAM peak; SM 64–74 % busy on index arithmetic |

- **Version regression.** On the same H200, HLLC takes 18.7 ms per step in v5.7.0 vs 13.2 ms in v4.9.3. WENO got
  faster, 49.6 → 31.4 ms (nsys 601030 vs 600682; baseline/README §3c). This matches upstream issue #2088 [ref 13].
- **Wall time is mostly fixed cost.** A 1-GPU run takes 8.07 s, of which about 2.3 s is time stepping
  (baseline/README §2).

### 3.2 Multi-GPU, unmodified v5.7.0
- At 8 GPUs with default host-staged halos, the halo exchange is 53 % of a stage. Speedup over 1 GPU is 3.6×
  (grind; report §4).
- With `rdma_mpi`, the halo share is 26 %. Pure transfer is only ≈0.03 ms per face; the rest is waiting
  (research-halo-overlap §1).
- **Load imbalance is on the host.** GPU kernel time is balanced within 2 %. The 3-CBC-face rank spends 0.9 ms per
  stage more on host work (small kernels, 5 blocking scalar updates per CBC call). The other ranks wait for it inside
  `MPI_Sendrecv` (profiling-baseline).
- `MPI_Init` takes 1.7–2.2 s at 1 rank and 5.8–6.5 s at 4 ranks (bare timer 602722/602764). UCX opens all 10
  network adapters (HCAs) in every rank (report §5, T0.4).

### 3.3 After our optimizations (P3 series)
Kernel time per step (sc26 profile, job 602705; [`../docs/optimizations.md`](../docs/optimizations.md)):
WENO5 29 %, HLLC 21 %, WENO input pack 10 %, bandwidth-bound copies 40 %. Host gaps inside the reconstruction and
Riemann phases fell to 0.002–0.012 ms per stage (trace 604667). At 8 GPUs the halo is 0.36–0.72 ms per stage,
depending on the rank (606019).

### 3.4 Background, and where it disagrees
- MFC 5.0 paper: WENO + Riemann ≈ 50 % of wall time on NVIDIA; on GH200, WENO reaches 24 % and Riemann 5 % of roofline [ref 4].
- On 4 V100s: WENO 37–43 %, Riemann 25–33 %, communication 6–18 % [ref 5]. Our 1-GPU WENO + HLLC share (59 %) fits.
- SCC26 webinar: Riemann is "solidly memory-bound"; WENO is compute-bound; the code is "largely memory-bound" [ref 10].
- **Conflict.** On H200 with NVHPC 26.3, ncu shows no kernel limited by DRAM bandwidth. WENO is latency-bound at
  10 % DRAM, HLLC was limited by local memory, and copies are instruction-bound at a third of HBM bandwidth.
- **Conflict.** The webinar calls communication cost low [ref 10]. At 8 GPUs on one node, default halos took 53 % of
  a stage.
- **Conflict.** "Nearly all time is in `simulation`" holds for compute. In a 30-step run, start-up dominates wall
  time: 15.9 s of wall for 0.6 s of stepping at 4 GPUs (606018; report §8).

## 4. Building and running on nano4

**Toolchain.** `source scripts/env.sh` loads NVHPC 26.3 (bundled CUDA 13.1), HPC-X 2.25.1 (Open MPI 4.1.9 with
UCX; known issues in [ref 15]) and cmake 4.0.0. It also sets `MFC_CUDA_CC=90` (H200 is sm_90) and the MPI settings below.

**Machine.** Compute nodes `25a-hgpn*` have 8× H200 (141 GB HBM3e, 4.8 TB/s [ref 12], 700 W limit, NVLink). Each
node also has 2× Xeon 8480+ and 10 Mellanox HCAs (report §3). Login nodes have other GPUs and are for compiling only.

**Build** (login node, `-j` ≤ 8):
- generic GPU build: `./mfc.sh build --gpu acc -j 8`;
- case-optimized: `./mfc.sh build -i case.py --case-optimization --gpu acc -j 8`.
- Flags such as `--gpu` are remembered between invocations [repo:toolchain/mfc/state.py].

**Run.** Our harness runs `./mfc.sh run case.py -n <ngpu> -t pre_process simulation -b mpirun --case-optimization`
for preparation and warm-up. Timed reps then call `mpirun -np <ngpu>` on the `simulation` binary
([`../docs/harness.md`](../docs/harness.md)). One MPI rank drives one GPU.

**Fixes needed before anything ran** (profiling-baseline; none touches numerics):
- `srun` cannot initialise HPC-X Open MPI → launch with `mpirun` (`-b mpirun`).
- Open MPI binds cores outside the job's cgroup cpuset → `OMPI_MCA_hwloc_base_binding_policy=none`. The cause is the old
  hwloc 2.0 bundled with Open MPI 4.1 [ref 16].
- OMPIO on WekaFS took 337 s or segfaulted → `OMPI_MCA_io=romio321`.
- nsys could not write `/tmp/nvidia` on some nodes → per-job `TMPDIR` in `/dev/shm`.
- Optional: `harness/nicbind.sh` sets `UCX_NET_DEVICES` [ref 14] to the HCA next to each rank's GPU (§6, T0.4).

**Slurm.** `sbatch -A acd110018 -p dev --gres=gpu:H200:<n> --ntasks=<n>`, through `harness/submit.sh`. That script
logs every job in `results/jobs.tsv`. Our rule is 1 GPU by default and ≤ 15–20 min.

**Profiling.** `./mfc.sh run … --nsys` or `--ncu` wraps the run [repo:toolchain/mfc/run/run.py]. ncu locks SM clocks
at base (1.48 GHz vs 1.98 GHz boost). Use its ratios, not its absolute times.

## 5. Correctness

**The regression suite.** `./mfc.sh test` generates cases in Python and runs `pre_process` + `simulation`. It compares
the packed output with a **golden file** `tests/<UUID>/golden.txt` [repo:toolchain/mfc/test/test.py].
- A value passes if its absolute **or** relative error is ≤ 1e-12. Some features use looser per-feature tolerances,
  for example 1e-10 for bubbles and 1e-9 for WENO7 [repo:toolchain/mfc/test/case.py].
- A test fails on NaN/Inf, a missing golden file, a tolerance miss, a non-zero exit, or a 1-hour timeout.
- `--rdma-mpi` runs the suite with `rdma_mpi`; `--shard i/n` splits it across jobs.

**Our bitwise gate** (`harness/verify.py`). After every benchmark run, the final conservative state (65 M doubles)
must be bitwise identical to the pinned v5.7.0 reference. This is stricter than 1e-12. It holds for every rung, every
GPU count, and both halo paths (report §7).

**Full suite on the final series (P4).**
- `./mfc.sh test -l` lists 752 tests at v5.7.0. In 8 shards (jobs 622349–622356), 713 ran and the rest were skipped
  for this build.
- Result: **690 pass, 23 fail, 0 new failures**.
- All 23 fail identically on unmodified v5.7.0 (recheck 606331, plus earlier rechecks). Most are `model_eqns=3` or viscous immersed-boundary
  cases. The list is in [`../harness/known_test_failures.txt`](../harness/known_test_failures.txt).
- So v5.7.0's suite is not clean on NVHPC 26.3 / H200. We report this rather than hide it.
- The old pack counts 770 tests on master `1ececa3` [computed via list_cases()]. That is a later version, not a conflict.

**Two harness holes we closed** (report §7): `verify.py` once passed a run whose timed reps never started; 1-GPU test
jobs could not start 2-rank tests until MPI oversubscription was allowed.

## 6. Optimization approaches, ranked

Rows 1–8 are done, roughly in order of measured impact. The rest are grouped as not tried or rejected, each roughly
by expected gain. "Rules risk" refers to §8.
"Expected gain" is the estimate made *before* the work, with its source. Jobs and per-rung detail are in
[`../docs/optimizations.md`](../docs/optimizations.md) and [`../docs/ladder.md`](../docs/ladder.md).

| # | Approach | Expected gain | Effort | Rules risk | Outcome |
|---|---|---|---|---|---|
| 1 | `--case-optimization` | up to 10× [repo:expectedPerformance.md] | none | none (standard benchmark setup) | **Done** (baseline): 2.3× measured, 600136/600139 |
| 2 | `rdma_mpi=T` (GPU-aware halos) | 4× halo [ref 5] | none | low; input parameter, disclosed | **Done**: −27 %/step at 4 GPUs; 8-GPU step 26.0 → 16.5 ms ([profiling](../docs/profiling-baseline.md)) |
| 3 | K4b: Riemann module slice as one translation unit | HLLC up to −45 % ([kernels](../docs/research-kernels.md) §2.4) | CMake + 3 lines | low; build change, disclosed | **Done**: HLLC 18.7 → 12.9 ms/step; step 75.98 → 70.42 ms (602474) |
| 4 | K2: `-gpu=maxregcount:128` for `m_weno` only | WENO −10 to −30 % (kernels §2.1) | one flag | low; disclosed flag | **Done**: WENO5 25.4 → 18.0 ms/step; step 70.42 → 62.99 ms (602559) |
| 5 | P2+P3: async per-stage kernels, one wait before MPI | −2 to −5 % at 8 GPUs ([halo](../docs/research-halo-overlap.md) O9) | 10 files, +170/−153 | low; `src/`, both paths | **Done**: −5.8 % at 4 GPUs, −1.7 % at 1 GPU (604560/604561) |
| 6 | P4: reconstruct only transverse-interior cells | −3 to −4 % at every count (halo O4b) | 2 files, +29/−14 | low; `src/`, audited | **Done**: −2.5 / −3.5 / −4.0 % at 1/4/8 GPUs (621788/622305/622306) |
| 7 | P1: CBC calls without host round trips | −3 to −8 % at 8 GPUs (halo O8) | 1 file, +50/−44 | low; `src/` | **Done**: −1.4 % at 1 GPU, −2.3 % at 4 GPUs (601152; 601183 vs 601184) |
| 8 | T0.4: UCX on the GPU's own HCA (`nicbind.sh`) | lower `MPI_Init` ([env](../docs/research-env-tuning.md) §2) | wrapper script | low; environment, disclosed | **Done** with `rdma_mpi`: wall 13.03 → 9.28 s at 4 GPUs (606032). **Rejected** for host-staged halos: +4.5 %/step (602770/1) |
| 9 | Copy kernels: `collapse(3)` + serial variable loop (#2087 pattern) | −10 to −12 % of a stage (kernels §3) | +8 to ~40 LOC | low; upstream PR by NTHU | **Not tried** (another team's open PR; extending it is our next step) |
| 10 | WENO pack removal (#2092) | −1.5 to −2 % after #2087 (kernels §2.2) | +4 LOC | low | **Not tried** (NTHU's open PR, not ours to claim) |
| 11 | Overlap halo with compute; faces-only all-dims exchange | −1 to −6 % at 8 GPUs (halo O4a/O4b) | 200–1200 LOC | medium | **Not tried** (made possible by P3 and P4; report §9) |
| 12 | Single-round 26-neighbour exchange + fused pack | −3 to −5 % at 8 GPUs (halo O2b+O3b) | 350–550 LOC | medium | **Not tried** |
| 13 | Finalize-buffer pointer alias | ≈ −2.4 % (kernels §2.2) | 25–35 LOC | low–medium | **Not tried** |
| 14 | WENO `vector_length(64/96)` | WENO −8 to −15 % (kernels §2.1) | 3 LOC | low | **Rejected**: registers rose to 206/192 in a compile check, so not timed |
| 15 | Compile-time `dir_idx` in HLLC (K4a) | HLLC −5 to −15 % (kernels §2.4 H2) | ~100 lines | medium | **Rejected**: SASS worse (255 registers); K4b fixed the real cause |
| 16 | WENO register cap 96 | more occupancy | one flag | low | **Rejected**: spills dominate, 66.5 ms (602567) |
| 17 | NVHPC 25.9 instead of 26.3 | unknown (kernels §2.6) | rebuild | low; disclosed | **Rejected**: no gain, not bitwise. NVHPC 24.x not tried |
| 18 | HCOLL/UCC off; `ob1`/vader; UCX shm | lower `MPI_Init` (env §2) | env only | low | **Rejected**: no clear effect, peers unreachable, or no gain (602638/9, 602683, 602704/26) |
| 19 | Per-rank NUMA binding wrapper | 0–10 % (env §3) | script | low | **Not tried** |
| 20 | Process-grid override to rebalance CBC ranks | −3 to −8 % at 8 GPUs, if imbalance remains (halo O7) | 80–200 LOC | low | **Not tried** |
| 21 | MPS, 2 ranks per GPU | −5 % to +10 % (halo O6) | none | low | **Not tried** |
| 22 | `--fastmath` | 0–2 % (kernels §2.6) | flag | medium; may change ulps | **Not tried** |
| 23 | NVSHMEM or CUDA Graphs | ≤ 2–7 % (halo O6) | > 1000 LOC | high; vetoed upstream (#2093) | **Not tried** |
| 24 | FP32 / FP16 storage, or IGR instead of WENO+HLLC | ≈ 4× for IGR [ref 7] | large | **forbidden**: changes numerics | **Not tried** (excluded by rule 1) |
| 25 | GPU power cap or locked clocks | energy, not speed (env §5) | admin rights | none for numerics | **Not tried** (needs root; see §9) |

### 6.1 The approaches that mattered most

**Case optimization and `rdma_mpi` come first.** Both cost no code. Case optimization sets the single-GPU floor;
`rdma_mpi` moves halos onto NVLink. Without `rdma_mpi`, v5.7.0 at its defaults reaches only 44 % strong-scaling
efficiency at 8 GPUs (report §1).

**K4b fixed the HLLC regression.** The HLLC PTX had 9 `.extern .func` calls into helpers in other files. nvfortran
inlines `acc routine seq` device routines only within one source file. Non-inlined calls pass arguments through local
memory. Compiling the 10-module slice `m_variables_conversion … m_riemann_solvers` as one translation unit removed all
calls. Local loads fell 178 → 76, and HLLC became faster than in v4.9.3 (report §5).
- **Conflict.** The old pack says NVHPC gets cross-file device inlining from its two-pass `-Mextract`/`-Minline` IPO
  [repo:gpuParallelization.md]. In the v5.7.0 case-optimized build, the HLLC helpers were still not inlined. Our PTX
  shows this, and so does issue #2094 [ref 13].
- `-Minfo`'s "cross-inlined" message refers to host code. It misled us at first (AGENT_LOG #11).

**K2 raised WENO occupancy.** **Occupancy** is the fraction of warp slots in use on a streaming multiprocessor. At
188–196 registers, only 8 warps fit per SM. A per-file cap of 128 doubles that, at the cost of a few spills that stay
in L1. A global cap was rejected upstream in #987 because it hurts other kernels [ref 13].

**P3 removed host round trips.** Each RK stage launched 44–68 kernels and ~45 scalar updates, each followed by a host
sync. That cost ≈1.2 ms per stage and did not shrink with more GPUs. A 5-second NVHPC test (604388) first showed that
async and sync work share one stream after `acc_set_cuda_stream`. The patch adds `GPU_ASYNC` to 115 per-stage
directives. Other compilers and the OpenMP path generate the old code.

**P4 skips work nobody reads.** WENO reconstructed 4 transverse ghost cells on each side. Its only reader, the Riemann
solver, reads transverse-interior cells only. An audit of `simulation/*.fpp` found no other reader. The skipped share
grows as boxes shrink (7.5 % at 201³, 14 % at 101³), so the gain grows with GPU count.

**What remains.** Copy kernels are 40 % of kernel time at a third of HBM bandwidth. WENO is still latency-bound. At
8 GPUs, six blocking `MPI_Sendrecv`s run without overlap. These are items 9, 11 and 12.

## 7. Result summary

From [`../report.md`](../report.md) §1, as written there. Outputs are bitwise identical to unmodified v5.7.0.
Speedup is the product of two same-node ratios (v5.7.0 vs P3, then P3 vs final).

| GPUs | v5.7.0 step | P3 step | Final step | Speedup | v5.7.0 grind | Final grind | Jobs |
|---|---|---|---|---|---|---|---|
| 1 | 76.74 ms | 61.88 ms | **60.38 ms** | **1.27×** | 0.3973 | 0.3123 | 606017; 621788 |
| 4 (all `rdma_mpi`) | 23.10 ms | 17.72 ms | **17.03 ms** | **1.35×** | 0.1184 | 0.0876 | 606018; 622305 |
| 8 (v5.7.0 default, then `rdma_mpi`) | 21.94 ms | 10.22 ms | **9.75 ms** | **2.23×** | 0.1129 | 0.0502 | 605963 / 606019; 622306 |

- Strong-scaling efficiency of the final build (step time): 89 % at 4 GPUs and 77 % at 8 GPUs. v5.7.0 at its
  defaults reaches 44 % at 8 GPUs.
- The 4-GPU row isolates the source changes. The 8-GPU row mixes code and configuration. The like-for-like v5.7.0
  `rdma_mpi` arm was not run (AGENT_LOG #14).
- Full `./mfc.sh test` on the final series: 690 pass, 23 fail, 0 new failures (report §7).

## 8. SC26 rules and what they allow

**The competition** [refs 9, 11]: SCC teams run HPL, HPL-MxP, MLPerf Training, WRF, MFC and a mystery application.
They also present a poster and pass the new CORE (Cluster Operational Readiness Evaluation). The competition runs 16–18 November 2026. The whole team system
must stay under 10,000 W at the PDU. A penalty applies at ≥ 10,000 W, and > 11,000 W at any time can disqualify.

**MFC ground rules** (SCC26 MFC webinar [ref 10]):
- Changes must maintain performance, portability and quality. Application developers have the final say.
- `src/` changes must pass the full CI suite through a public GitHub pull request, within ±5000 lines.
- Compiler-option (CMake) changes need not pass full CI. Teams must show `./mfc.sh test` passing on their hardware and
  disclose the change to the judges.

**Maintainer signals** (upstream threads read on 2026-10-22; [`../docs/research-kernels.md`](../docs/research-kernels.md) §0):
- wilfonba wrote in #2093 that SCC source changes must be **merged upstream by 2026-10-26**.
- Rejected: large rewrites (#2093, +27k LOC), `#ifdef` toggles, NVIDIA- or OpenACC-only modules, and Fypp hand
  inlining (#2095).
- Accepted: small, default-on, bit-identical loop restructures, for example #2087 (+8 LOC, approved 10-21).
- danieljvickers expects most changes to be "under 1k lines of additions".

**How we read this for our work** (project rules in `CLAUDE.md`):
- Allowed: case optimization, `rdma_mpi`, per-file flags, CMake changes, and MPI environment settings, all disclosed.
- Allowed: small portable `src/` patches that pass the full suite. P1, P3 and P4 are +50/−44, +170/−153 and +29/−14 lines.
- Not allowed: FP32 or mixed precision, IGR instead of WENO + HLLC, other grids or step counts, or looser tolerances.
- K2 and K4b are build changes. They need `./mfc.sh test` on our hardware and disclosure, which we have (§5).

## 9. Open questions

1. **Upstream status.** Our `src/` patches (P1, P3, P4) are not yet submitted upstream (report §9). Do they count if
   the 2026-10-26 merge deadline has passed?
2. **8-GPU code-only gain.** v5.7.0 with `rdma_mpi` at 8 GPUs on the same node is unmeasured. A cross-job reference
   gives 16.5 ms per step (report §1). `nicbind.sh` at 8 GPUs is also untested.
3. **Why H200 trails H100 on v4.9.3.** With the official code, our H200 is 9 % slower than the published H100 SXM5
   (0.4159 vs 0.38). The compiler (NVHPC 26.3 vs 24.5) is untested (baseline/README §3b).
4. **Power capping.** The old pack expects capping to be cheap because MFC is "memory-bound" [hardware_facts §6]. Our
   ncu data says WENO and HLLC track SM clock. H200 needs ≥ ~550 W for peak bandwidth [ref 17]. The real cost for MFC is unmeasured, and setting caps needs root.
5. **Copy kernels.** How much does the #2087 pattern give on top of our series, and does it stay bitwise?
6. **Halo overlap at scale.** Options 11–12 help most at ≥ 3 ranks per dimension, that is, multi-node. That
   needs approval and more than one node.
7. **The 23 known test failures.** They fail on unmodified v5.7.0 with NVHPC 26.3 on H200. Is that a compiler issue
   or a stale golden file?
8. **Wall-time figure of merit.** In 30-step runs, `MPI_Init` + `MPI_Finalize` take ≈ 7.2 s at 4 GPUs (602722). The
   SCC problem size and step count decide whether start-up matters.
9. **Unified memory.** P3 is untested with `--unified` builds (GH200 only; not available on nano4).

## Appendix A. Build / case-parameter reference

Source: the old pack §5 [repo:toolchain/mfc/cli/commands.py; state.py; case.md], master `1ececa3`. Check against
v5.7.0 before relying on a rarely used flag.

**Config flags** (shared by build/run/test; remembered): `--mpi`/`--no-mpi`, `--gpu [acc|mp]`/`--no-gpu`,
`--debug`, `--reldebug`, `--gcov`, `--unified` (GH200 only), `--single` (FP32), `--mixed` (FP16 storage),
`--fastmath`.

**`build`:** `-t/--targets` (pre_process, simulation, post_process, …), `-j/--jobs`, `-i/--input case.py`,
`--case-optimization` (needs `-i`), `--deps-only`, `-v`.

**`run`:** `-n/--tasks-per-node`, `-N/--nodes`, `-t/--targets`, `-b/--binary {mpirun,srun,jsrun,mpiexec}`,
`-g/--gpus <ids>`, `-e/--engine {interactive,batch}`, `-p/--partition`, `-a/--account`, `-w/--walltime`,
`--case-optimization`, `--no-build`, `--dry-run`, `--nsys [flags]`, `--ncu [flags]`.

**`test`:** `-l/--list`, `-o/--only <UUID|label>`, `-%/--percent`, `--shard i/n`, `--rdma-mpi`, `--no-build`,
`--case-optimization`, `--generate` (regenerate golden files; never used for our gate).

**Environment read by the build:** `MFC_CUDA_CC` (90 for H100/H200), `CC`/`CXX`/`FC`, `NVHPC_CUDA_HOME`. The Fortran
solver itself reads no environment variables [repo:src grep].

**Key case parameters:** `m`, `n`, `p` (cells − 1 per direction), `x_domain%beg/end`, `dt`, `t_step_start/stop/save`,
`model_eqns`, `num_fluids`, `weno_order`, `mapped_weno`, `riemann_solver`, `time_stepper`, `bc_x%beg/end`,
`parallel_io`, `file_per_process`, `rdma_mpi`, `run_time_info`. Outputs: `D/`, `restart_data/`, `time_data.dat`
(grind), and the console line `Performance: <grind> ns/gp/eq/rhs`.

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
