# WRF on F1: optimization research brief (SC26 SCC)

This brief studies how one would optimize WRF for the SC26 Student Cluster Competition (SCC) on the NCHC F1 cluster.
It is research only: nothing was built or run on F1, and no number below was measured by us.
Source code read: WRF v4.8.0 (commit 06d4240, released 2026-06-08) and WPS v4.7.0 [1][2][28].
The web notes and hardware sheet were collected on 2026-09-28; the main fact sheet is undated; the F1 survey is from 2026-10-22 [34].
Citations are [n] from the References; `[1: path]` means a file in the WRF v4.8.0 tree.

## 1. What WRF computes

WRF (Weather Research and Forecasting model) is a community mesoscale weather prediction and research model [6].
Its only dynamical core is ARW (Advanced Research WRF); the NMM core was removed in v4.4 [1: `doc/README.NMM`].
The webinar dates "only core" to v4.3.1, and the SCC page still says "two dynamic cores" [5][6]. These sources disagree.

- **Equations.** Fully compressible, Eulerian, nonhydrostatic equations in flux form. They conserve dry-air mass and scalar mass [3].
- **Prognostic variables.** Winds u, v, w; perturbation moist potential temperature (`use_theta_m=1`); perturbation geopotential; perturbation surface pressure; moisture and other scalars [3][1].
- **Grid.** Horizontal Arakawa C-grid, a staggering where velocities sit on cell faces [3].
  The vertical coordinate is a terrain-following hybrid sigma-pressure coordinate (`hybrid_opt=2` default) [1: `run/README.namelist`].
- **Time integration.** Time-split third-order Runge–Kutta (RK3) for slow modes [3].
  Acoustic sub-steps are explicit horizontally and implicit vertically [3].
  `time_step_sound=0` (Registry default) picks sub-steps automatically: 4 at dt = 6·dx [1: `dyn_em/solve_em.F:451-468`].
- **Advection.** Default 5th order horizontal, 3rd order vertical, with positive-definite moisture advection (`moist_adv_opt=1`) [1].
- **Time step.** Rule of thumb: dt (s) ≈ 6 × dx (km) [3][6].
  Runs stop with "Time step too large" when dt/dx exceeds `reasonable_time_step_ratio=6` [1: `dyn_em/start_em.F:290-310`].
- **Boundaries and nests.** The outer domain d01 is driven by lateral boundary conditions (LBCs) from a global model, refreshed every `interval_seconds` [1].
  Nests refine resolution by odd integer ratios, best 3:1 or 5:1 [1][4].
- **Physics.** Parameterized processes run as column schemes: microphysics, cumulus, radiation, boundary layer, surface and land.
  The default real-data namelist uses `physics_suite='CONUS'` [1: `test/em_real/namelist.input`].
  CONUS means Thompson microphysics (8), Tiedtke cumulus (6), RRTMG radiation (4/4), MYJ PBL (2), Eta surface layer (2) and Noah land (2) [1].
- **Precision.** Default reals are 4 bytes (single precision); `-r8` gives 8 bytes [1: `configure`].

The pipeline is WPS (geogrid → ungrib → metgrid), then `real.exe`, then `wrf.exe` [6].
`real.exe` builds initial and boundary files; `wrf.exe` integrates the model [6].

## 2. Parallel model

WRF uses a two-level decomposition [1: `frame/module_tiles.F`, `external/RSL_LITE/module_dm.F`].
RSL_LITE, WRF's MPI layer, splits each domain into **patches**, one per MPI rank.
Each patch is split into **tiles**, which OpenMP threads process.

- **Build modes.** `serial`, `smpar` (OpenMP only), `dmpar` (distributed memory, MPI only) and `dm+sm` (MPI plus OpenMP) [1: `arch/Config.pl`].
- **Decomposition.** `nproc_x` and `nproc_y` default to −1 (automatic).
  Automatic picks the factor pair closest to square, with `nproc_x ≤ nproc_y` [1: `external/RSL_LITE/module_dm.F:98-180`].
- **Minimum patch.** Patches below 10 cells in x or y abort the run [1: `share/module_check_a_mundo.F:3013-3030`].
- **Tiles.** With `numtiles=1` and OpenMP on, the tile count equals `omp_get_max_threads()` [1: `frame/module_tiles.F:260-330`].
  Env vars `WRF_NUM_TILES*` override this. The default tile strategy splits along y.
- **Halo exchange.** A halo is the ring of neighbor cells a patch copies before a stencil.
  `solve_em.F` holds 69 `HALO_EM_*` references, implemented as MPI point-to-point via `RSL_LITE_EXCH_X/Y` [1].
  The forum quotes a 5-point halo per side [11].
- **I/O.** The default `io_form_history=2` is serial netCDF. Rank 0 gathers each field and writes alone [1: `frame/module_io.F`].
  Alternatives are PnetCDF (11), parallel netCDF-4 (13), ADIOS2 (14) and per-rank split files (+100) [1: `Registry/Registry.EM_COMMON:3424-3439`].
  **Quilting** reserves extra MPI ranks as asynchronous output servers (`&namelist_quilt`) [1: `frame/module_io_quilt_old.F`].
- **Logs.** Every rank writes `rsl.out.NNNN` and `rsl.error.NNNN` [1: `external/RSL_LITE/c_code.c`].

## 3. Where the time goes

**Figure of merit.** NCAR and NVIDIA use the mean of the per-step "Timing for main" lines, in seconds per step [13][14].
This excludes I/O and initialization, which print their own "Timing for Writing …" lines [1: `share/mediation_integrate.F`].

**Hot spots (no F1 measurements; literature only).**
- Physics is "roughly half the computational cost" [16].
  WSM5 microphysics was 0.4% of the source but about 25% of single-core run time [16].
- Radiation steps are costly. ISC21 measured 41.8 s per radiation step vs 5.64 s per other step at 80 ranks [10].
  That is about 7–8×; `radt` sets how often radiation runs.
- With spectral-bin microphysics (Fast SBM), `fast_sbm` took 51% (gprof) or 77% (Nsight) of runtime [17].
  Advection tendencies (`rk_scalar_tend`) took 28% / 10% in the same study [17].
- Dynamics hot spots are RK advection tendencies (`module_advect_em.F`), acoustic small steps (`module_small_step_em.F`) and diffusion [1].
- WRF is "a memory bandwidth bound application", with diminishing returns as bandwidth per core falls [23].
- A CFL-check internal write was guarded by `OPTIMIZE_CFL_TEST` because it "breaks vectorization" on newer Xeons [1: `dyn_em/module_big_step_utilities_em.F:2671-2674`].
- In an MPI profile of WRF 3.4, most MPI time was `MPI_Wait` on small halo messages, plus `MPI_Bcast` [15].

**Scaling evidence.**
- Forum rule: maximum useful ranks ≈ (e_we/25)·(e_sn/25) for the smallest domain [11].
  Minimum ranks ≈ (e_we/100)·(e_sn/100) for the largest domain [11].
- On Cheyenne (WRF 4.0), strong scaling is linear while cores < gridpoints/10⁵ [12].
  Efficiency collapses above gridpoints/10⁴ cores [12].
- Initialization and output time stay roughly constant as cores grow, so they dominate at high counts [12].
- A 64 GB node holds about 10⁵–10⁶ gridpoints, depending on physics [12].

**Benchmarks.**

| Case | Grid | dt | Reported time | Source |
|---|---|---|---|---|
| CONUS 12 km (v4.2.2) | 425×300 | 72 s | ≈0.3 s/step on 144 cores (Intel 19.0.5) | [13] |
| CONUS 2.5 km (v4.2.2) | 1501×1201 | 15 s | ≈0.6 s/step on 1008 cores | [13] |
| CONUS 12 km on Grace Superchip | 425×300 | 72 s | 0.3884 s/step, 36 ranks × 4 threads | [14] |
| CONUS 12 km on GH200 (Grace part) | 425×300 | 72 s | 0.5761 s/step, 18 × 4 | [14] |
| CONUS 2.5 km, one node | – | – | Grace-Grace 531.5 s; SPR Xeon Max 541.3 s; EPYC Milan 1052.3 s | [21] |

The v4.2.2 cases are 1-hour runs from a restart file [13].
The old v3 CONUS 2.5 km case is 1901×1301, not 1501×1201; it runs only on WRF ≤3.8.1 [27][12].

**Sizing for one F1 node (our arithmetic).**
An F1 node has two Xeon Platinum 8480+ (56 cores, 350 W, 8-channel DDR5-4800 each) [34][22].
That gives 112 cores and 2 × 307.2 = 614.4 GB/s peak memory bandwidth, about 5.5 GB/s per core [22].
For the webinar domain (d01 150×130), the forum rule caps useful ranks near 6 × 5 = 30 [11][6].
So pure MPI on 112 cores exceeds the guideline, though the hard limit (15 × 13 = 195) still holds [1].
This makes a hybrid layout attractive on even one node. That is an inference, not a measurement.

## 4. Building and running on F1

**What F1 lacks (survey of 2026-10-22).** We found gcc 8.5 and 10.4 only [34].
We found no Intel oneAPI, netCDF, HDF5 or PnetCDF installation [34].
F1 exposes interactive and visualization partitions only, e.g. `visual-dev` with 8 h [34].
No own-account login to F1 existed at survey time [34].

**Dependency stack.** Build in this order:
1. Compilers (Fortran + C) and MPI. gcc on F1; MPI availability is unconfirmed.
2. zlib and HDF5 (for netCDF-4 compression) [4][1].
3. netCDF-C, then netCDF-Fortran. They are mandatory [4][1].
4. Optional: PnetCDF (io_form 11), ADIOS2, and JasPer + libpng for GRIB2 in WPS [1][2].
5. perl ≥5, m4, csh/tcsh and make. The `compile` script is csh [1: `compile`].

NCAR's parallel-I/O test used HDF5 1.10.7, netcdf-c 4.7.4 and netcdf-fortran 4.5.3 [1: `doc/README.netcdf4par`].
NVIDIA's Grace guide used HDF5 1.14.2, netcdf-c 4.9.2 and netcdf-fortran 4.6.1 [14].
`export NETCDF=<prefix>` is required, or configure prints "No environment variable NETCDF set." [1: `configure`].

**Configure and compile.**
`./configure` shows a numbered menu of compiler × build mode. We recomputed the Linux x86_64 numbers from v4.8.0 [1: `arch/configure.defaults`]:

| Options | Stanza | Relevance to F1 |
|---|---|---|
| 32–35 | GNU gfortran/gcc (34 dmpar, 35 dm+sm) | The only usable path today |
| 13–16 | Intel ifort/icc (15 dmpar, 16 dm+sm) | Needs Intel compilers |
| 64–67 | Intel HSW/BDW (67 dm+sm; used by ISC21) | Needs Intel compilers [10] |
| 76–79 | Intel oneAPI ifx/icx (78 dmpar, 79 dm+sm) | Needs oneAPI |

There is no NVHPC stanza for x86_64 [1].
A second prompt asks for nesting: 1 = basic (default), 2 = preset moves, 3 = vortex following [1: `arch/Config.pl`].
The result is `configure.wrf`, which one edits to change flags [1].
For gfortran newer than 9, configure appends `-fallow-argument-mismatch -fallow-invalid-boz` [1: `configure:700-716`].
So gcc 10.4 should be handled; gcc 8.5 skips this step.

The GNU stanza's optimization is `-O2 -ftree-vectorize -funroll-loops` [1: `arch/configure.defaults:798`].
Build with `./compile -j 8 em_real >& compile.log`. The UG says more than about 6 make jobs does not help [4].
Success prints "Executables successfully built", with `wrf.exe`, `real.exe`, `ndown.exe` and `tc.exe` in `main/` [1: `Makefile:250`].
A full build takes about 10–60 min [4]; about 1 h with Intel [10].
v4.6 added a CMake path, `./configure_new` + `./compile_new`, needing CMake ≥3.20 [1: `doc/README.cmake_build`].

**WPS pipeline.** Build WRF first, because WPS links WRF's I/O library [2: `configure`].
WPS options per stanza are `serial`, `serial_NO_GRIB2`, `dmpar` and `dmpar_NO_GRIB2` [2].
A serial WPS is recommended unless domains are thousands of points per side [4].
1. `geogrid.exe` interpolates static terrain and land data from `geog_data_path` into `geo_em.d0N.nc` [2][6].
2. `ungrib.exe` decodes GRIB via a Vtable, e.g. `Vtable.GFS`, into `FILE:YYYY-MM-DD_HH` [2][6]. It is serial.
3. `metgrid.exe` interpolates horizontally into `met_em.d0N.<date>.nc` and rotates winds to the grid [6].
4. `real.exe` writes `wrfinput_d01` and `wrfbdy_d01` [6].

The webinar slide names the geogrid output `geo_em_d01.nc`; WPS actually writes `geo_em.d01.nc` [6][2].
The webinar example uses GFS 0.25° data, 2019-09-04_12 to 2019-09-05_00, 3-hourly [6].
Its domain is a 15 km Lambert grid at 33°N, 79°W with a 3:1 nest, matching WRF's default namelist [6][1].

**Namelist essentials** (`namelist.input`) [1: `run/README.namelist`]:
- `&time_control`: run length, `interval_seconds`, `history_interval`, `frames_per_outfile`, `restart_interval`, `io_form_*`.
- `&domains`: `time_step`, `e_we`, `e_sn`, `e_vert`, `dx`, `dy`, `num_metgrid_levels`, nest geometry, `nproc_x/y`, `numtiles*`.
- `&physics` and `&dynamics`: scheme choices; under the rules these are fixed (Section 7).
- `&namelist_quilt`: `nio_tasks_per_group`, `nio_groups`.

The v4.8 default em_real case is 36 h, `time_step=90`, `e_vert=48`, `radt=15`, `history_interval=60` [1: `test/em_real/namelist.input`].

**Running.** `mpiexec -np N ./wrf.exe` for dmpar [6].
For hybrid runs, NVIDIA sets `OMP_STACKSIZE=1G OMP_PLACES=cores OMP_PROC_BIND=close` and `ulimit -s unlimited` [14].

**rsl.out.** Rank 0's `rsl.out.0000` holds one line per step [1: `frame/module_timing.F:87`]:
`Timing for main: time 2019-09-04_12:01:30 on domain   1:    0.54321 elapsed seconds`.
Output writes, LBC reads and restarts each print their own "Timing for …" lines [1].
`-DRSL0_ONLY` in CFLAGS limits rsl files to rank 0 [1: `external/RSL_LITE/c_code.c:50`][10].

## 5. Correctness

**Did it finish?** Each program prints a success line [1]:
- `wrf.exe`: "wrf: SUCCESS COMPLETE WRF" [1: `main/module_wrf_top.F:2116`].
- `real.exe`: "real_em: SUCCESS COMPLETE REAL_EM INIT" [1: `main/real_em.F:293`]. The UG abbreviates it differently [4].
- `metgrid.exe`: "Successful completion of metgrid" [6].

Failures print "FATAL CALLED" in `rsl.error.*` [1: `frame/module_wrf_error.F`].
CFL warnings ("points exceeded v_cfl") signal a too-large time step [1: `dyn_em/module_big_step_utilities_em.F:2671-2706`].
The webinar's only criterion is "SUCCESS COMPLETE WRF" plus the expected `wrfout_d01_*` files [6].

**diffwrf.** `diffwrf file1 file2` is built with WRF in `external/io_netcdf/` [1: `external/io_netcdf/diffwrf.F90:300-525`].
It prints one line per differing field: `Field Ndifs Dims RMS(1) RMS(2) DIGITS RMSE pntwise max`.
DIGITS is the count of agreeing significant digits of the RMS; 15 means equal.
Identical files print nothing after "Diffing". It has no tolerance flag.

**What counts as "same answer".**
- **Bit-identical.** WRF's regression test expects bit-for-bit agreement across serial, OpenMP and MPI runs only for `./configure -d` builds [1: `tools/regtest.csh`].
  Optimized builds make "No inter-comparisons" [1]. So changing rank count or flags will change the last digits.
- **Statistical.** ISC21 validated with an ANOVA test on theta, QVAPOR and U [10].
  It used 13 boxes × 3 levels over the first output times, against the organizers' run [10].
- **Visual.** NCAR's v4.2.2 benchmarks ship a Python script and PNGs of "acceptable differences" [13].
- **SC26.** No WRF tolerance or method is published as of the sources [6].

Our proposal: keep a reference run built with stock flags and default decomposition.
Then compare every variant with diffwrf on T2, U10, V10, PSFC, Q2, RAINNC, RAINC, T, QVAPOR, U, V, W and PH [1].
Report DIGITS per field. Never claim equality from "SUCCESS COMPLETE WRF" alone.

## 6. Optimization approaches, ranked

Ranking is by expected gain per effort under the rules. Gains are from the literature, not F1.

| # | approach | expected gain | effort | rules risk | evidence |
|---|---|---|---|---|---|
| 1 | MPI×OpenMP layout and tiling (`nproc_x/y`, dm+sm, `numtiles`) | Large when patches are small; hybrid vs pure MPI: "marginal" [12] to ~5% [20] | Low | None for physics; last digits change | [11][12][14][20] |
| 2 | Compiler: Intel oneAPI instead of gcc | Intel ≈1.5× GNU [12]; up to 42% [15] | High on F1 (not installed) | Low; ISC21 allowed compiler changes [10] | [10][12][15] |
| 3 | Flags: `-O3`, AVX-512 / `-march=native`, drop `-fp-model precise` | Unmeasured; stanza comment says faster "at the expence of accuracy" | Low | Medium; needs statistical validation | [1][10] |
| 4 | I/O: quilting, PnetCDF, split files, classic netCDF, `RSL0_ONLY` | Grows with output frequency and core count; I/O does not scale [12] | Medium (PnetCDF must be built) | Low for format; high if output content changes | [1][10][12] |
| 5 | Process pinning / NUMA placement | Unmeasured; NVIDIA pins every run [14] | Low | None | [14][30] |
| 6 | MPI library choice and tuning | OpenMPI, MPT, MVAPICH similar; MPICH poor; Intel MPI scaled badly [12] | Medium | None | [12][15] |
| 7 | Hyper-threading | +8% in one case, negligible otherwise [12] | Low | None | [12] |
| 8 | Physics cost: `radt`, `cudt`, `bldt`, fast RRTMG (24) | Radiation steps 7–8× a normal step [10] | Low | High: changes the answer | [1][10] |
| 9 | Adaptive time step | Unquantified speedup | Low | High: results differ from fixed dt | [1][3] |
| 10 | GPU or Grace options | Not applicable on F1; Grace matters for hardware choice | – | GPU forks are not WRF source | [14][19][21][24] |
| 11 | `-r8` or mixed precision | Negative: default is already 4-byte | – | – | [1] |

**1. Layout and tiling.** This is free and decides the communication-to-compute ratio.
Choose a rank count that keeps patches at or above about 25×25 points, never below 10 [11][1].
Set `nproc_x ≤ nproc_y` or test x-short patches explicitly [1].
Threads then work on tiles, so fewer ranks send fewer, larger halo messages [1].
NVIDIA's Grace recipe uses 4 threads per rank [14]. On an F1 node, 28 × 4 is the analogous first guess (our inference).
Sweep threads per rank in {1, 2, 4, 7, 14} and `numtiles` in {threads, 2×threads}.

**2. Compiler.** Intel compilers beat GNU in both studies found: about 1.5× on Cheyenne [12] and up to 42% in 2012 [15].
F1 has no oneAPI, so this needs a user-space install and an Intel-built netCDF stack.
That is the largest effort item, and its payoff on F1 is unmeasured.
If it fails, the GNU stanza (34/35) with tuned flags is the fallback.

**3. Flags.** The Intel stanzas ship `-fp-model precise`; their comment suggests removing it for speed [1: `arch/configure.defaults:268-340`].
ISC21's HSW/BDW stanza used `-xHost -fp-model fast=2 -no-prec-div -no-prec-sqrt` [1][10].
ISC21 also advised trying AVX-512 on Intel [10]. The 8480+ is a Sapphire Rapids (SPR) part [22], and SPR supports AVX-512.
For gcc, test `-O3 -march=native` against the stanza's `-O2`. Each variant needs a diffwrf check.

**4. I/O.** Serial netCDF funnels all output through rank 0 [1].
Quilting adds `nio_groups × nio_tasks_per_group` ranks on top of the compute ranks [1: `frame/module_io_quilt_old.F:311-320`].
PnetCDF (`io_form_history=11`) needs `PNETCDF` at configure time and `nocolons=.true.` [1: `doc/README.netcdf4par`].
The netCDF-4 README itself says PnetCDF "will have better IO performance" if compression is not needed [1].
Split files (`102`) are fast but cannot be read by a different task count or combined with quilting [1: `frame/module_io.F:2869-2902`].
`NETCDF_classic=1` avoids compression cost; that it is faster is unverified [1].
Changing `history_interval` or the field list changes the output set, so treat it as a rules question.

**5. Pinning and NUMA.** Each 8480+ socket has its own memory channels; ranks should use local memory.
NVIDIA binds with `OMP_PLACES=cores OMP_PROC_BIND=close` and `--map-by ppr:18:numa:PE=4` [14].
On F1 the analogue is ranks per NUMA node with `PE=threads`. The NUMA count per socket is unknown (Section 8).

**Grace and GPU.** Official WRF is CPU-only; ISC21 said "no GPU performance optimization is sought" [10].
NCAR has frozen WRF development, and GPU work is "not our priority" [19].
AceCAST is a proprietary GPU WRF with limited physics options [24]. A community OpenACC port covers only the dycore and hangs [19]. Older NCAR GPU work stayed experimental [18].
For the competition cluster, Grace CPU nodes look strong per watt.
A Grace CPU Superchip has 144 cores and up to 1 TB/s at 500 W including memory [25].
STREAM Triad reaches 820–972 GB/s on it [26]. NVIDIA advises NVHPC or GCC ≥12.3 there [29].
TACC ran CONUS 2.5 km in 531.5 s on Grace-Grace at 500 W vs 541.3 s on SPR Xeon Max at ≥700 W [21].
None of this applies to F1, which is x86 only.

## 7. SC26 rules and what they allow

**Power.** The whole system must stay under 10,000 W, including network, cooling and storage [5].
A penalty applies whenever the PDU (power distribution unit) reads ≥10,000 W [5].
Teams may be disqualified above 11,000 W at any time [5]. A benchmark run during an overdraw is invalid [5].
Power comes through one 208 V circuit and one Vertiv Geist PDU [5]. Sleep states are allowed; power-off and hibernation are not [5].
The sources give different PDU part numbers (VP6N62A1 vs NR30214).
The page's "19A/208V" splitter rating (≈3.95 kW) does not match a 10 kW cap; its meaning is unclear.

**What a CPU node costs in watts (our estimate).** Using the hardware sheet's method [22][31][32]:
- Two 8480+ at 350 W = 700 W; 16 DIMMs × 11 W = 176 W; NIC 25 W; misc 60 W. Total 961 W DC.
- With 12% fans and 95% PSU efficiency: about 1,130 W at the wall.
- Seven such nodes plus about 304 W of switches is about 8.2 kW, inside a 10–15% safety margin [33].
These are estimates; only a PDU reading under HPL load is authoritative.

**Other hardware rules.** One 42U rack, commercially available hardware with public specs, no NDA, ≤85 dBA, closed-loop cooling [5].
Hardware is locked at the end of benchmarking; no changes or reboots afterward [7][8].

**Permitted code and namelist changes.** SC26 has published no WRF-specific rules [6].
The webinar names no version, tolerance, figure of merit or allowed changes [6].
The nearest precedent is ISC21: compiler, chip, optimization flags and even real*8 may change; physics and numerics schemes may not [10].
This repo's own rule also forbids physics or numerics shortcuts unless labelled as experiments (CLAUDE.md).
Its "FP64" clause is MFC-specific; WRF's reference precision is its 4-byte default.

**Run format.** The contest runs 16–18 Nov 2026 in Chicago [5].
Applications are WRF, MFC and a Mystery Application; benchmarks are HPL, HPL-MxP and MLPerf Training (Llama 2 70B LoRA) [5][8].
The history page lists MLPerf Inference; the September overview confirms Training [9][8].
There is no Reproducibility Challenge; CORE (Cluster Operational Readiness Evaluation) replaces it [5][7].
The intro slides put the mystery app and datasets on Monday evening [7].
The hardware sheet says Wednesday evening, from a garbled slide extraction. These sources disagree.
The webinar walks through all of WPS with batch scripts, so teams may have to run WPS too (inference) [6].
At ISC21 a single 3-domain run served both timing and validation [10].

## 8. Open questions

**Not verified.**
- Whether SC26 will publish WRF rules, a version, a dataset, a tolerance or a figure of merit.
- Whether the contest case is Hurricane Dorian. The webinar's date and domain match it, but nobody confirmed this [6].
- The Notre Dame team works on LES-scale nests and WRF-Chem [35]; a nested or chemistry case is a guess.
- Whether oneAPI and a netCDF/PnetCDF stack can be installed in user space on F1.
- Which MPI libraries exist on F1, and whether F1 has a batch partition for multi-node runs.
- Whether gcc 8.5 or 10.4 accepts `-march=sapphirerapids`; `-march=native` is the safe test.
- The number of F1 nodes, NUMA nodes per socket, and whether hyper-threading is on.
- Hybrid gains: Cheyenne says "marginal" [12]; the Azure ~5% figure is a search summary [20].
- The DIGITS threshold that SC26 graders would accept; no source states one.

**What we would measure first.**
1. Build the stack with gcc 10.4 (stanza 35, dm+sm) and run the webinar case on one node. Confirm "SUCCESS COMPLETE WRF".
2. Save that run as the reference. Record "Timing for main" mean, median and spread over ≥3 repeats.
3. Split one step into radiation and non-radiation averages, as ISC21 did [10].
4. Sweep ranks × threads on one node, then on two nodes, with pinning fixed.
5. Profile one rank (e.g. VTune or gprof) to confirm whether advection, small steps, microphysics or RRTMG dominate.
6. Measure STREAM bandwidth per socket to test the memory-bound claim [23].
7. Time output with `io_form_history` 2, 11 and quilting, at the contest's output frequency.
8. Only then try oneAPI and fast-math flags, each checked with diffwrf against the reference.

## References

1. WRF v4.8.0 source, commit 06d4240 (2026-06-08). https://github.com/wrf-model/WRF
2. WPS v4.7.0 source. https://github.com/wrf-model/WPS
3. Skamarock et al., *A Description of the ARW Version 4*, NCAR/TN-556+STR, 2019, doi:10.5065/1dfh-6p97. https://opensky.ucar.edu/system/files/2024-08/technotes_576.pdf
4. WRF Users' Guide. https://www2.mmm.ucar.edu/wrf/users/wrf_users_guide/build/html/
5. SC26 Student Cluster Competition page. https://sc26.supercomputing.org/students/student-cluster-competition/
6. SC26 WRF webinar slides, 2026-08-20. https://sc26.supercomputing.org/wp-content/uploads/2026/08/SCC26-WRF-Webinar-Slides.pdf
7. SC26 SCC intro webinar slides, April 2026. https://sc26.supercomputing.org/wp-content/uploads/2026/04/SCC26-Intro-Webinar-slides.pdf
8. SC26 Benchmarking Overview, 2026-09-10. https://sc26.supercomputing.org/wp-content/uploads/2026/09/Benchmarking-Overview-SCC26.pdf
9. SC cluster competition history. https://sc26.supercomputing.org/students/cluster-competition-history/
10. HPC-AI Advisory Council, ISC21 SCC WRF practice case. https://hpcadvisorycouncil.atlassian.net/wiki/spaces/HPCWORKS/pages/1827438600/
11. WRF forum, "How many processors should I use". https://forum.mmm.ucar.edu/threads/how-many-processors-should-i-use-to-run-wrf.5082/
12. A. Kyle, NCAR CISL SIParCS WRF scaling study (Cheyenne, WRF 4.0). https://akirakyle.github.io/WRF_benchmarks/results.html
13. NCAR WRF v4.2.2 benchmarks. https://www2.mmm.ucar.edu/wrf/users/benchmark/benchdata_v422.html
14. NVIDIA Grace CPU Benchmarking Guide, WRF page. https://github.com/NVIDIA/grace-cpu-benchmarking-guide/blob/main/src/applications/WRF/index.md
15. HPC Advisory Council, WRF analysis and profiling, 2012. https://www.hpcadvisorycouncil.com/pdf/WRF_Analysis_and_Profiling_7_2012.pdf
16. Michalakes & Vachharajani, GPU acceleration of NWP. https://www2.mmm.ucar.edu/wrf/WG2/michalakes_lspp.pdf
17. Wichitrnithed et al., SC24 workshops, arXiv 2409.07232. https://arxiv.org/html/2409.07232
18. NCAR 2016 workshop, "GPU Developments for the WRF Model". https://www2.mmm.ucar.edu/wrf/users/workshops/WS2016/oral_presentations/4.4.pdf
19. WRF forum, "WRF GPU port (FahrenheitResearch)". https://forum.mmm.ucar.edu/threads/wrf-gpu-port-fahrenheitresearch.26779/
20. Microsoft, "Run WRF v4 on Azure HPC VMs" (figures via search summary). https://techcommunity.microsoft.com/blog/azurehighperformancecomputingblog/run-wrf-v4-on-azure-hpc-virtual-machines/1131097
21. TACC Vista evaluation, SC-W 2024. https://conferences.computer.org/sc-wpub/pdfs/SC-W2024-6oZmigAQfgJ1GhPL0yE3pS/555400a558/555400a558.pdf
22. Intel Xeon Platinum 8480+ product page. https://www.intel.com/content/www/us/en/products/sku/231746/
23. Dell, WRF performance on AMD EPYC 7003. https://infohub.delltechnologies.com/en-nz/p/wrf-performance-with-amd-epyc-7003-series-processors-on-dell-emc-poweredge-servers/
24. TempoQuest AceCAST. https://tempoquest.com/acecast/
25. NVIDIA Grace CPU Superchip. https://www.nvidia.com/en-us/data-center/grace-cpu-superchip/
26. NVIDIA Grace guide, STREAM. https://github.com/NVIDIA/grace-cpu-benchmarking-guide/blob/main/src/foundations/STREAM/index.md
27. NCAR WRF v3 benchmarks. https://www2.mmm.ucar.edu/wrf/WG2/benchv3/
28. WRF GitHub releases. https://github.com/wrf-model/WRF/releases
29. NVIDIA Grace tuning guide, Fortran. https://nvidia.github.io/grace-cpu-benchmarking-guide/developer/languages/fortran.html
30. CHPC wiki, WRF how-to. https://wiki.chpc.ac.za/howto:wrf
31. Micron 128 GB DDR5 RDIMM brief (≈10 W/DIMM). https://assets.micron.com/adobe/assets/urn:aaid:aem:6ffd17ac-e709-469d-9473-a0a904681dd9/renditions/original/as/128gb-ddr5-rdimm-product-brief.pdf
32. 80 PLUS efficiency levels. https://en.wikipedia.org/wiki/80_Plus
33. NVIDIA Quantum QM8700 switch (≈274 W typical). https://www.nvidia.com/en-in/networking/infiniband/qm8700/
34. Local F1 survey, `PLAN.md` "Step 0" table in this repo, 2026-10-22 (no URL).
35. Notre Dame Atmospheric Modeling Group publications. https://acamg.nd.edu/publications/

## Appendix A. Build and namelist reference

Only names confirmed in the v4.8.0 / WPS v4.7.0 sources are listed [1][2].

**`./configure` flags.** `-d` (debug, no optimization), `-D` (debug plus traps and checks), `-r8` (8-byte reals), `-f`, `-s`, `-os`, `-mach`, `-time`, `-cordex`, `-instvals`, `-h`.
Arguments: `chem`, `cmaq`, `kpp`, `radardfi`, `wrfda`, `4dvar`, `arw`, `coamps`, `wrfplus`, `mars`, `titan`, `venus`.

**`./compile`.** `-j N` (or env `J`, default `-j 2`), `-h`. Main target `em_real`; also `wrf`, `em_les`, `em_quarter_ss` and other idealized cases. Clean with `./clean -a`.

**CMake.** `./configure_new [-p stanza] [-x] [-- -DWRF_CORE=ARW -DWRF_NESTING=BASIC -DWRF_CASE=EM_REAL]`, then `./compile_new -j N`.
Booleans include `USE_MPI`, `USE_OPENMP`, `USE_PNETCDF`, `USE_HDF5`, `USE_DOUBLE`.

**WPS configure.** `--nowrf`, `--build-grib2-libs`. Executables `geogrid.exe`, `ungrib.exe`, `metgrid.exe`.

**Postamble defines.** `-DBUILD_RRTMG_FAST=0`, `-DBUILD_SBM_FAST=1`; `MAX_DOMAINS=21` [1: `arch/postamble`, `arch/preamble`].
Useful CFLAGS addition: `-DRSL0_ONLY`.

**Build-time env vars.** `NETCDF` (required), `NETCDF_C`, `NETCDF_classic`, `NETCDFPAR`, `PNETCDF`, `PNETCDF_QUILT`, `ADIOS2`, `HDF5`, `PHDF5`, `JASPERLIB`, `JASPERINC`, `WRF_CHEM`, `WRF_KPP`, `WRF_OS`, `WRF_MACH`, `J`, `WRF_LOG_BUFFERING`, `WRFIO_NCD_NO_LARGE_FILE_SUPPORT`; `WRF_DIR` for WPS.

**Runtime env vars.** `WRF_NUM_TILES`, `WRF_NUM_TILES_X`, `WRF_NUM_TILES_Y`, `WRF_NUM_TILES_INC`, plus `OMP_NUM_THREADS`, `OMP_STACKSIZE`, `OMP_PLACES`, `OMP_PROC_BIND`.

**`io_form_*` values.** 1 binary, 2 netCDF (default), 4 PHDF5, 5 GRIB1, 10 GRIB2, 11 PnetCDF, 12 PIO, 13 parallel netCDF-4, 14 ADIOS2. Add 100 for one file per rank.

**Performance-relevant namelist variables.**
- `&domains`: `nproc_x`, `nproc_y`, `numtiles`, `numtiles_x`, `numtiles_y`, `numtiles_inc`, `tile_sz_x`, `tile_sz_y`, `tile_strategy`, `time_step`, `use_adaptive_time_step`, `reasonable_time_step_ratio`.
- `&time_control`: `history_interval`, `frames_per_outfile`, `restart_interval`, `io_form_history`, `io_form_restart`, `io_form_input`, `io_form_boundary`, `iofields_filename`, `nocolons`, `ncd_nofill`, `debug_level`.
- `&namelist_quilt`: `nio_tasks_per_group` (0 = off), `nio_groups` (1), `poll_servers`.
- `&namelist_adios2`: `adios2_compression_enable`, `adios2_blosc_compressor`, `adios2_numaggregators`.
- `&physics` cost knobs (fixed under the rules): `radt`, `cudt`, `bldt`, `ra_lw_physics`, `ra_sw_physics`, `mp_physics`.
- `&dynamics`: `time_step_sound` (0 = auto), `*_adv_order`, `moist_adv_opt`.

**Log lines worth grepping.** "Timing for main", "Timing for Writing", "WRF NUMBER OF TILES FROM OMP_GET_MAX_THREADS", "Quilting with N groups of M I/O tasks.", "SUCCESS COMPLETE WRF", "FATAL CALLED".
