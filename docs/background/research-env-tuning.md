# Runtime and environment tuning on nano4 (HPC-X 2.25.1, 8× H200)

**What this is.** Background notes from 2026-10-22, the start of the project: web research, nothing run on nano4 yet.
What later happened to each idea is in [ladder](../ladder.md) and [optimizations](../optimizations.md).

**Scope.** Things we can change **without touching MFC's numerics or source**: MPI/UCX settings, how ranks are launched
and pinned, file-writing settings, GPU power and clocks, MPS. Tags: **[C]** = confirmed by a cited source; **[I]** = my
own guess, must be measured; **[L]** = our own results.

**Words used below.**
- *MPI*: the library that lets the program's copies (*ranks*, one per GPU) message each other. *Open MPI* is one version
  of it; *HPC-X* is NVIDIA's package of Open MPI plus *UCX*, the layer that picks the actual wire or link.
- *CUDA-aware / RDMA*: MPI sends straight from GPU memory. *cuda_ipc*: UCX's GPU-to-GPU path inside one node over
  NVLink/NVSwitch (the fast GPU links). *cuda_copy*: a slower path that bounces through CPU memory.
- *Rendezvous*: the big-message protocol: the two sides agree first, then copy with no extra buffer ("zero-copy").
  *Halo exchange*: swapping the thin layer of edge cells each GPU needs from its neighbours.
- *NUMA node / socket*: each CPU chip has its own nearby memory and nearby GPUs; reaching the other chip is slower.
  *cgroup*: the fence Slurm puts around the CPU cores a job may use. *hwloc*: the library that maps this layout.
- *MPI-IO / ROMIO / OMPIO*: the MPI way to write one shared file from many ranks; ROMIO and OMPIO are two engines for it.
- *MPS*: lets several processes share one GPU at the same time.

**Local facts [L].**
- The node has **10 network cards** (NIC0–NIC9 in `nvidia-smi topo -m`, results/base/caseopt_1g/env.txt). UCX opens
  every one in every rank at `MPI_Init` unless told not to.
- 8-GPU jobs get cores **0-31 (NUMA0) + 56-87 (NUMA1)** (results/scale/strong_8g_rdma/env.txt, job 600179). GPUs 0-3
  sit by NUMA0, GPUs 4-7 by NUMA1. With binding off, every rank can drift across both sockets.
- MFC picks its GPU as `local_rank mod ndev` *after* `MPI_Init` ([source-structure](../source-structure.md)), so rank r
  uses GPU r.
- With RDMA: first step 175 ms (one-off link setup); then the halo takes 1.35 ms per stage for 6 faces, ≈225 µs per face
  of ≈2.6 MB at 8 GPUs ([profiling-baseline](../profiling-baseline.md)).

## 1. UCX settings for GPU-to-GPU inside one node

**What the sources say [C].**
- `cuda_ipc` moves GPU buffers between processes over NVLink, only inside a node, whenever the driver can map the other
  GPU (always on NVSwitch). https://github.com/openucx/ucx/discussions/9896 , https://docs.nvidia.com/dask-cuda/latest/ucx/
- `UCX_TLS` must include the cuda transports, or GPU memory is not recognised. `ucx_info -d | grep cuda` shows GPU
  support; `UCX_LOG_LEVEL=info` prints the transports used; `UCX_PROTO_INFO=y` prints which protocol each message size
  uses. `UCX_MEMTYPE_CACHE=n` turns off a cache that can mistake GPU memory for CPU memory.
  https://openucx.readthedocs.io/en/master/faq.html
- Open MPI calls UCX "the preferred mechanism" for CUDA. https://docs.open-mpi.org/en/v5.0.x/tuning-apps/networking/cuda.html
- UCX-Py suggests for NVLink systems: `UCX_RNDV_THRESH=8192`, `UCX_RNDV_SCHEME=get_zcopy`, `UCX_CUDA_IPC_CACHE=y`
  (default), `UCX_MEMTYPE_CACHE=n`. The newer protocol engine (default since UCX 1.16) "may lack proper support/testing
  for CUDA async and managed memory". https://ucx-py.readthedocs.io/en/latest/configuration.html
- HPC-X 2.25 known issues: device-symbol MPI buffers may crash (MFC's halo buffers come from the OpenACC runtime, so fine
  **[I]**); some message sizes are slower with the new protocols (workaround `UCX_PROTO_ENABLE=n`).
  https://networking-docs.nvidia.com/hpcxum/225/known-issues
- No known issue specific to CUDA 13 was found. NVIDIA's CUDA DL 25.12 container ships exactly HPC-X 2.25.1 + UCX 1.20.0
  + CUDA 13.1, so the combo is NVIDIA-tested.
  https://docs.nvidia.com/deeplearning/frameworks/cuda-dl-release-notes/rel-25-12.html

**What it means for MFC [I].**
- Our halo messages (0.1–3 MB) are big, so they already use rendezvous. The question is which kind: zero-copy
  `cuda_ipc` (good) or the `cuda_copy` pipeline through CPU memory (bad, about host-staged speed). Only
  `UCX_PROTO_INFO=y` can tell. The 175 ms first step and ~5× faster comm than host-staged suggest `cuda_ipc`, but that is
  not proven.
- 225 µs per face is ≈10× the pure NVLink transfer time. The rest is pack/unpack kernels, waits, the handshake, and
  **neighbour skew** (max/median Sendrecv ≈10×). Settings can trim only the handshake; the big win is in code (send all
  faces at once, overlap; see NTHU PR #2089/2090 and [literature](literature.md)).
- On one node the InfiniBand transports are useless; keeping them only costs start-up time.
  `UCX_TLS=self,sm,cuda_copy,cuda_ipc` is the natural single-node set.
- **Caveat:** Open MPI 4.1 may quietly refuse UCX when no network transport is listed and fall back to its older engine.
  So always force `OMPI_MCA_pml=ucx` (it then aborts instead) and check with `OMPI_MCA_pml_ucx_verbose=10`.
- Never drop the cuda transports from `UCX_TLS` while sending GPU pointers: crash or garbage.

## 2. Why MPI start-up and shut-down are slow

**Seen [L]:** `MPI_Init` 2.2 s (1 rank), 4 s (2), ~29 s (8, under nsys); job wall 19 s at 8 vs 7.5 s at 1; `MPI_Finalize`
2 s at 8; 996 `MPI_Bcast` calls at start = 0.9 s.

Possible causes, each to be A/B-tested (no source matches our exact case):
1. **UCX opens all 10 network cards in every rank** **[I]**. `UCX_TLS=self,sm,cuda_copy,cuda_ipc` or
   `UCX_NET_DEVICES=<one card near the GPU>` skips this.
2. **Every rank wakes up all 8 GPUs** before MFC picks one. If GPU **persistence mode is off**, each wake-up is slow;
   hwloc's docs recommend persistence mode for this **[C]** https://open-mpi.org/projects/hwloc/doc/v1.10.1/a00028.php .
   hwloc's own GPU probing can be turned off with `HWLOC_COMPONENTS=-opencl,-cuda,-nvml`. Turning persistence on needs
   the admins **[I]**. Showing each rank only its own GPU (`CUDA_VISIBLE_DEVICES`) would help, but then `cuda_ipc` must be
   re-checked **[I, must test]**.
3. **Collective add-ons (HCOLL / UCC) starting up.** HPC-X docs say both are off by default, but NVHPC's bundled config
   may differ, so check with `ompi_info` and disable with `OMPI_MCA_coll_hcoll_enable=0`, `OMPI_MCA_coll_ucc_enable=0`
   **[C]** https://networking-docs.nvidia.com/hpcxum/223/running-configuring-and-rebuilding-hpc-x ,
   https://docs.nvidia.com/networking/display/hpcx222/Unified+Collective+Communication+(UCC) ,
   https://docs.excl.ornl.gov/software/mpi , https://docs.nvidia.com/cuda/cublasmp/troubleshooting/index.html
4. **A known /tmp slowdown** was fixed in HPC-X 2.21, so not ours **[C]**
   https://networking-docs.nvidia.com/hpcxum/226/bug-fixes-history . **nsys itself** also slows `MPI_Init`.
5. **The 996 Bcasts (0.9 s)** are ~100× slower than a small Bcast should be. Most likely *skew*, not MPI: rank 0 reads the
   input between Bcasts while the others wait **[I]**. Packing all settings into one Bcast is a source change.
6. **`MPI_Finalize` 2 s**: tearing down all those connections; same fixes as (1) and (3) **[I]**.

## 3. Pinning ranks to the right CPU cores under Slurm

- **Why our binding failed [C]:** Open MPI 4.1.x ships hwloc 2.0, which does not understand the newer cgroup v2 fences,
  so `mpirun` tries cores outside the job and errors. Fixes are `srun` (not available to us), `--bind-to none`, a rebuilt
  Open MPI, or Open MPI 5. https://github.com/open-mpi/ompi/issues/12470 , https://www.osc.edu/node/6482
- So Open MPI's own `--bind-to core` will most likely fail the same way **[I]**; `--cpu-set <allowed list>` might work.
- **Robust option: a small wrapper per rank** that asks the OS directly. It looks up which NUMA node the rank's GPU sits
  on, takes a private slice of the allowed cores there, and runs MFC under `numactl` bound to those cores and that
  memory. The OS keeps the request inside the job's fence **[I, standard kernel behaviour]**. Launch with
  `mpirun --bind-to none`; check with `/proc/<pid>/status` and `numastat -p`.
- **Expected effect [I]:** GPU kernels do not care. Pinning matters for host-staged halos (CPU buffers on the wrong
  socket slow every copy), launch delays and skew. A 2–10 % change in step time at 8 GPUs is plausible: **measure it**.

## 4. Writing files on WekaFS

- No Weka guidance for MPI-IO was found; Lustre/GPFS striping hints do not apply **[I]**.
- OMPIO's file locking is already off on non-NFS file systems, so locking very unlikely explains the 337 s write **[I]**;
  our own test with locking forced off did not fix OMPIO either. The problem is more likely in OMPIO's aggregation or a
  bug (it crashed at file close). **Not worth more time: ROMIO works.**
  https://accserv.lepp.cornell.edu/svn/packages/openmpi-4.0.3/ompi/mca/fs/ufs/fs_ufs_component.c
- **ROMIO hints worth trying** (a file named by `ROMIO_HINTS`) **[C meaning, I values]**: collective writes on, one
  aggregator node, a 64 MB buffer (default 16 MB) for fewer, larger writes; data sieving off; then 2 or 4 writer
  processes. https://accserv.classe.cornell.edu/svn/packages/openmpi/ompi/mca/io/romio321/romio/README ,
  https://doku.lrz.de/mpi-io-10746186.html , https://wordpress.cels.anl.gov/romio/?p=464
- **One file per rank** (`file_per_process`): changes the file layout, not the numerics; must be disclosed. With few
  ranks it is usually fastest **[I]**. Writing (520 MB per save) is outside grind time and only matters for wall time.

## 5. MPS, `CUDA_DEVICE_MAX_CONNECTIONS`, power and clocks

- **MPS** pays off when one rank cannot fill a GPU **[C]**
  https://www.olcf.ornl.gov/wp-content/uploads/2021/06/MPS_ORNL_20210817.pdf , https://kb.ucar.edu/x/TYA-Bg . One MFC
  rank already keeps an H200 96 % busy **[L]**, and 2 ranks per GPU double the halo: expect **no gain** **[I]**.
- **`CUDA_DEVICE_MAX_CONNECTIONS`** (number of GPU work queues; default 8 per forum posts **[C-weak]**): MFC launches
  everything on one queue, so **no effect today** **[I]**.
- **Power cap and clocks** (matter for the SC26 power budget):
  - H200 needs ≥ ~550 W to reach full memory bandwidth (H100 ~350 W); at ≤300 W its bandwidth drops, and it cannot
    hold 200 W **[C]** https://arxiv.org/abs/2604.11391 . Math-heavy work scales with SM clock; >500 W gives diminishing
    returns.
  - AI work on H200 loses 48–58 % at a 300 W cap **[C]** (arXiv 2603.16164). SPEChpc on H100: 350→200 W costs 18–32 %
    on the most sensitive codes, ≤13 % on the least **[C]**
    https://lenovopress.lenovo.com/lp1706-analyzing-the-performance-impact-of-gpu-power-level-using-spechpc-2021
  - Locking clocks usually beats power capping for efficiency **[C]** https://arxiv.org/abs/2607.00819
  - **MFC is not memory-streaming code**: WENO is limited by FP64 latency (DRAM 10 %), HLLC uses 31–42 % DRAM **[L]**.
    So its speed tracks SM clock, and a cap that lowers the clock costs nearly in proportion **[I]**. First measure the
    actual draw: if MFC draws, say, 450–550 W, a cap of ~550 W is free. Setting caps or clocks needs root.

## 6. NCCL / NVSHMEM vs CUDA-aware MPI inside one node

- *NCCL* and *NVSHMEM* are NVIDIA's GPU messaging libraries. They queue work on the GPU without a CPU wait; MPI needs the
  CPU to wait for the GPU before each send **[C]** https://arxiv.org/pdf/2409.09874
- Examples: GROMACS's NVSHMEM halo scaled up to 1.5× better inside a node **[C]** https://arxiv.org/abs/2509.21527 ;
  multi-path UCX + CUDA graphs up to 2.95× over single-path `cuda_ipc` **[C]** https://arxiv.org/pdf/2604.22228 ;
  NVIDIA's reference examples (no numbers in the repo) https://github.com/NVIDIA/multi-gpu-programming-models
- **Rough guess [I, not measured]:** below ~1 MB the fixed start-up cost of each message dominates, which is exactly
  MFC's size at 8 GPUs. Six faces sent one after another pay it 6×, so sending all faces at once is worth more than any
  setting.
- To measure: HPC-X's OSU tests (`osu_latency D D`) and nccl-tests.
- NCCL/NVSHMEM are source changes with a new dependency; #2093 (NTU) already tried NVSHMEM on H200.

## A/B checklist (in priority order)

Rules: one change at a time against the baseline (`OMPI_MCA_io=romio321 OMPI_MCA_hwloc_base_binding_policy=none`); at
least 3 reps; record wall, grind and nsys step time; 2 GPUs first, 8 GPUs only for winners. Pass settings with
`RUN_ENV="K=V ..."`, and add `-x K` to `MPIRUN_ARGS` to be safe.

0. **Look first** (no speed claim): `UCX_LOG_LEVEL=info UCX_PROTO_INFO=y OMPI_MCA_pml_ucx_verbose=10`, 2 ranks, 1 step.
   Learn which transports and protocols are used (want `cuda_ipc` zero-copy, not the `cuda_copy` pipeline), whether
   HCOLL/UCC are on, and whether persistence mode is on.
1. **Force UCX**: `OMPI_MCA_pml=ucx OMPI_MCA_btl=^smcuda,openib,uct`. No silent fallback.
2. **Single-node `UCX_TLS=self,sm,cuda_copy,cuda_ipc`**: faster start-up and shut-down. Fallback if UCX declines: keep one
   network card with `UCX_NET_DEVICES`.
3. **Collective add-ons off** (`OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0`): faster start-up if either was on.
4. **NUMA pinning wrapper** (§3): less jitter and skew; expect 0–10 %.
5. **`HWLOC_COMPONENTS=-opencl,-cuda,-nvml`** (plus persistence mode, admin): faster `MPI_Init` if GPU probing dominates.
6. **Rendezvous knobs** (`UCX_RNDV_SCHEME`, `UCX_RNDV_THRESH=8192`): ± a few µs per face.
7. **`UCX_PROTO_ENABLE=n`**: may help or hurt.
8. **`UCX_MEMTYPE_CACHE=n`**: only if GPU buffers get misdetected.
9. **`UCX_CUDA_IPC_CACHE=y`** (default; confirm).
10. **One visible GPU per rank**: faster `MPI_Init`; **must** re-check `cuda_ipc` and bitwise results.
11. **ROMIO hints file** (§4): faster saves.
12. **`file_per_process=T`** (disclose): faster saves still.
13. **Power**: measure draw first, then try caps 550/500/450 W or locked clocks (admin); find a cap that costs <2–3 %.
14. **MPS, 2 ranks per GPU**: probably no gain for the current code.

**Do not set:** `UCX_TLS` without `cuda_*` (breaks GPU buffers), `UCX_GVA_ENABLE=y`, `UCX_DC_MLX5_TX_POLICY=dcs_hybrid`
(HPC-X known issues), or anything that changes the numerics.

The Perplexity tool returned errors for every query in this session; everything above is from web search and fetch.
