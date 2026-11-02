# WRF on F1: optimization research brief (SC26 SCC)

How would we make WRF run faster on the NCHC F1 cluster for the SC26 Student Cluster Competition (SCC)? This is reading
only: we ran nothing on F1 and measured none of these numbers. We read the code of WRF v4.8.0 (commit 06d4240) and WPS
v4.7.0 [1][2]. `[1: path]` means a file in the WRF v4.8.0 code.

## 1. What WRF computes

WRF (Weather Research and Forecasting model) is a widely shared model for forecasting and studying regional weather [6].
It covers a region with a 3D grid of boxes (cells); the **grid spacing** (dx) is the width of one box. Its only
dynamical core (the part that moves the air) is ARW; the NMM core was removed in v4.4 [1: `doc/README.NMM`]. The SCC
page still says "two dynamic cores" [5][6], so the sources disagree.

- **Equations.** Air is squeezable and free to move up and down. No dry air is lost or made [3].
- **Time stepping.** A Runge–Kutta method (RK3) handles slow changes; fast sound waves get small sub-steps inside each
  step [3]. Rule of thumb: time step dt (seconds) ≈ 6 × dx (km) [3][6]. Runs stop with "Time step too large" when
  dt/dx goes above 6 [1].
- **Edges and nests.** The outer domain gets its edge values from a global model. Nests are finer grids inside it,
  best at 3:1 or 5:1 [1][4].
- **Physics.** Processes too small for the grid run as per-column recipes: microphysics (how droplets, rain and snow
  form), clouds, radiation (sunlight and heat), the air layer near the ground, and land [1].
- **Precision.** Numbers are 4-byte (single precision) by default; `-r8` makes them 8-byte [1].

In order: WPS prepares map and weather input, `real.exe` builds start and edge files, `wrf.exe` runs the forecast [6].

## 2. Parallel model

WRF splits work at two levels. MPI (Message Passing Interface) runs many copies of the program, called ranks, that send
each other data. Each rank gets a rectangle of the map, a **patch**. Inside a rank, OpenMP threads (helpers that share
one memory) split the patch into **tiles**.

- **Patch layout.** `nproc_x` and `nproc_y` set the rank grid. Patches below 10 cells wide abort the run [1].
- **Halo exchange.** Before a step that looks at neighbours, each patch copies a ring of edge cells (the halo) from its
  neighbours through MPI [1].
- **I/O** (input/output: reading and writing files). By default, output is NetCDF (a common file format for science
  grids), and rank 0 gathers every field and writes alone [1]. **Quilting** sets aside extra ranks that write in the
  background [1].

## 3. Where the time goes

**Score.** NCAR and NVIDIA use the mean of the per-step "Timing for main" log lines, in seconds per step [13][14].
Reading, writing and start-up print their own lines and are left out [1].

**Hot spots (from papers; nothing measured on F1).**
- Physics is "roughly half the computational cost" [16]. One microphysics scheme was 0.4% of the code but about 25% of
  run time on one core [16].
- Radiation steps cost 41.8 s vs 5.64 s for other steps at 80 ranks, about 7–8× [10]. `radt` sets how often radiation
  runs.
- WRF is "a memory bandwidth bound application": it mostly waits for memory, not math [23].

**Scaling.** Strong scaling means solving the same problem with more cores. A forum rule suggests at most about
(e_we/25)·(e_sn/25) useful ranks, where e_we and e_sn are the grid sizes east–west and south–north [11]. On Cheyenne
(WRF 4.0), efficiency collapses above gridpoints/10⁴ cores [12]. Start-up and output time do not shrink, so they
dominate at high counts [12].

**Published benchmarks.**

| Case | Grid | Reported time | Source |
|---|---|---|---|
| CONUS 12 km | 425×300 | ≈0.3 s/step on 144 cores | [13] |
| CONUS 2.5 km | 1501×1201 | ≈0.6 s/step on 1008 cores | [13] |
| CONUS 2.5 km, one node | – | Grace-Grace 531.5 s; SPR Xeon Max 541.3 s; EPYC Milan 1052.3 s | [21] |

**One F1 node (our arithmetic).** It has two Xeon 8480+ chips, 112 cores in all, with about 5.5 GB/s of memory speed per
core [34][22]. For the webinar's domain (150×130), the forum rule suggests about 30 useful ranks [11][6]. So pure MPI on
112 cores is past the guideline, and a mix of ranks and threads looks attractive even on one node. This is a guess, not
a measurement.

## 4. Building and running on F1

**What F1 lacks (survey of 2026-10-22).** We found only gcc 8.5 and 10.4, and no Intel oneAPI compiler, NetCDF, HDF5 or
PnetCDF [34]. We had no own-account login then [34].

**Libraries to build first:** compilers and MPI (MPI on F1 is unconfirmed), then HDF5, then NetCDF-C and NetCDF-Fortran
(required), optionally PnetCDF [1][4]. Set `export NETCDF=<prefix>` [1].

**Configure and compile.** `./configure` shows a numbered menu of compiler × build mode [1]. The GNU options 32–35 (34
dmpar, 35 dm+sm) are the only usable path on F1 today; the Intel options need Intel compilers. For gfortran newer than
9, configure adds flags that let old code compile [1], so gcc 10.4 should work; gcc 8.5 skips this. Build with
`./compile -j 8 em_real`; the guide says more than about 6 jobs does not help, and a build takes about 10–60 min [4].

**WPS** (the WRF Preprocessing System) is built after WRF [2]. `geogrid.exe` adds terrain and land, `ungrib.exe` unpacks
global weather data, and `metgrid.exe` fits it to our grid; then `real.exe` writes the start and edge files [2][6]. The
webinar example is a 15 km grid with a 3:1 nest [6].

**The namelist** (`namelist.input`, a plain text file of settings) sets run length and output (`&time_control`), grid,
time step and layout (`&domains`), and physics (`&physics`, fixed under the rules) [1: `run/README.namelist`].

**Running.** `mpiexec -np N ./wrf.exe` [6]. Each rank writes a log, `rsl.out.NNNN`; rank 0's has one "Timing for main"
line per step [1].

## 5. Correctness

**Did it finish?** `wrf.exe` prints "SUCCESS COMPLETE WRF" [1]. That line plus the expected output files is the
webinar's only check [6].

**diffwrf** compares two output files and prints, per differing field, how many significant digits agree (15 means
equal) [1]. It has no tolerance setting.

**What counts as "the same answer"?**
- **Bit-identical** results across serial, OpenMP and MPI runs are only expected for debug builds (`./configure -d`)
  [1]. In fast builds, changing the rank count or flags changes the last digits.
- **Statistical.** ISC21 checked results with a statistical test on temperature, water vapour and wind [10].
- **SC26** has published no WRF tolerance or method [6].

Our plan: keep a reference run with stock settings, compare every variant with diffwrf on key fields (temperature, wind,
pressure, rain, moisture), and report agreeing digits per field. Never claim equal answers from "SUCCESS COMPLETE WRF"
alone.

## 6. Optimization ideas, ranked

Ranked by expected gain per effort under the rules; gains come from papers, not F1.

| # | Idea | Expected gain | Effort | Rules risk |
|---|---|---|---|---|
| 1 | Ranks × threads layout and tiles | Large when patches are small; mixed vs pure MPI: "marginal" [12] to ~5% [20] | Low | None; last digits change |
| 2 | Intel oneAPI instead of gcc | ≈1.5× [12]; up to 42% [15] | High (not installed) | Low; ISC21 allowed it [10] |
| 3 | Flags: `-O3`, `-march=native` | Unmeasured | Low | Medium; needs checking |
| 4 | Faster output: quilting, PnetCDF, split files | Grows with output and core count [12] | Medium | Low if output is unchanged |
| 5 | Pin ranks to cores and memory | Unmeasured; NVIDIA pins every run [14] | Low | None |
| 6 | MPI library choice | Most similar; MPICH and Intel MPI did poorly [12] | Medium | None |
| 7 | Hyper-threading | +8% once, negligible otherwise [12] | Low | None |
| 8 | Run physics less often (`radt`, `cudt`, `bldt`) | Radiation steps 7–8× a normal step [10] | Low | High: changes the answer |

**1. Layout** is free and sets how much talking there is per unit of computing. Keep patches at or above about 25×25
points, never below 10 [11][1]. With threads, fewer ranks send fewer, larger halo messages [1]. NVIDIA uses 4 threads
per rank [14]; on F1, 28 ranks × 4 threads is a first guess (our inference).

**2. Compiler.** Intel beat GNU in both studies we found [12][15]. F1 has no oneAPI, so we would install it and an
Intel-built NetCDF ourselves: the biggest job, with an unmeasured payoff.

**3. Flags.** Intel's settings include `-fp-model precise`, and a comment suggests removing it for speed "at the expence
of accuracy" [1]. For gcc, test `-O3 -march=native` against `-O2`. Check every variant with diffwrf.

**4. Output.** Serial NetCDF funnels everything through rank 0 [1]. PnetCDF writes in parallel and "will have better IO
performance" if compression is not needed [1: `doc/README.netcdf4par`]. Writing less often changes the output, so that
is a rules question.

**GPUs and Grace.** Official WRF runs only on CPUs [10]; GPU versions are commercial or unfinished [24][19]. For the
contest cluster, NVIDIA Grace CPUs look strong per watt: Grace-Grace at 500 W was about as fast as a Xeon Max at ≥700 W
[21]. None of this applies to x86-only F1.

## 7. SC26 rules and what they allow

**Power.** The whole system, including network, cooling and storage, must stay under 10,000 W [5]. A penalty applies
whenever the PDU (the power strip that meters it) reads ≥10,000 W; above 11,000 W teams may be disqualified, and a
benchmark run during an overdraw does not count [5]. The sources give different PDU part numbers.

**A CPU node's power (our estimate).** About 961 W of parts, or about 1,130 W at the wall [22][31][32]. Seven nodes plus
switches come to about 8.2 kW, inside a 10–15% safety margin [33]. Only a meter reading under full load can confirm
this.

**Hardware.** One rack, hardware anyone can buy, ≤85 dBA of noise. Hardware is locked when benchmarking ends [5][7][8].

**Allowed changes.** SC26 has published no WRF rules: no version, tolerance, score or allowed changes [6]. The closest
example is ISC21: compiler, chip, flags and even 8-byte numbers could change; physics and numerical schemes could not
[10]. This repo's rules also forbid physics or numerics shortcuts unless labelled as experiments (CLAUDE.md). For WRF
the reference precision is its 4-byte default.

**Format.** 16–18 Nov 2026 in Chicago [5]. Apps: WRF, MFC and a Mystery Application; benchmarks: HPL, HPL-MxP and MLPerf
Training [5][8]. CORE (a cluster readiness check) replaces the old Reproducibility Challenge [5][7]. Sources disagree on
when the mystery app is revealed. The webinar walks through all of WPS, so teams may have to run it too (our inference)
[6].

## 8. Open questions

**Not yet known.**
- Whether SC26 will publish WRF rules, a version, a dataset, a tolerance or a score.
- Whether the contest case is Hurricane Dorian. The webinar's dates and map match it, but nobody confirmed this [6].
- Whether oneAPI and NetCDF can be installed without admin rights on F1, which MPI libraries exist, and whether F1 can
  run multi-node jobs.
- F1's node count, memory layout per chip, and whether hyper-threading is on.
- Real gains from mixing ranks and threads: one source says "marginal" [12]; the ~5% figure is a search summary [20].
- Which diffwrf digit count SC26 graders would accept; no source says.

**What we would measure first.**
1. Build with gcc 10.4 (option 35), run the webinar case on one node, and confirm "SUCCESS COMPLETE WRF".
2. Keep that run as the reference. Record the mean, median and spread of "Timing for main" over ≥3 repeats.
3. Sweep ranks × threads on one node, then two, with pinning fixed.
4. Profile one rank to see which part really dominates (radiation, as ISC21 found [10]?), and measure memory speed [23].
5. Time output with serial NetCDF, PnetCDF and quilting at the contest's output rate.
6. Only then try oneAPI and fast-math flags, each checked with diffwrf.

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
34. Local F1 survey, `docs/history/plan.md` "Step 0" table in this repo, 2026-10-22 (no URL).
35. Notre Dame Atmospheric Modeling Group publications. https://acamg.nd.edu/publications/
