# Runtime / environment tuning research — HPC-X 2.25.1 (OMPI 4.1.9 + UCX) on nano4 8× H200 (2026-10-22)

Scope: things we can change **without touching MFC numerics or source**: MPI/UCX env, launch/binding, MPI-IO
backend + hints, GPU power/clocks, MPS. Read-only web research; nothing here has been run on nano4 yet.
Tags: **[C]** = confirmed by a cited source; **[I]** = my inference / back-of-envelope, must be measured;
**[L]** = local evidence from our own results (job id / path).

Local facts used below **[L]**:
- Node has **10 RDMA NICs** (NIC0–NIC9 in `nvidia-smi topo -m`, results/base/caseopt_1g/env.txt). UCX opens
  every one of them in every rank at `MPI_Init` unless told otherwise.
- 8-GPU job cpuset = cores **0-31 (NUMA0) + 56-87 (NUMA1)** (results/scale/strong_8g_rdma/env.txt, job 600179;
  `--ntasks=8 --cpus-per-task=8`). GPUs 0-3 are NUMA0 (CPU affinity 0-31), GPUs 4-7 NUMA1 (56-87).
  With `binding_policy=none`, every rank can float across both sockets.
- MFC picks the GPU as `local_rank mod ndev` *after* MPI_Init (docs/source-structure.md); rank r ↔ GPU r with
  mpirun's default by-slot mapping.
- RDMA run: first step 175 ms (one-off CUDA-IPC mapping), steady RHS-COMMUNICATION 1.35 ms per stage for
  6 faces ≈ 225 µs per face at 8 GPUs strong (≈ 100³ cells/rank → face ≈ 100×100×4×8 vars×8 B ≈ 2.6 MB)
  (docs/profiling-baseline.md).
- nsys is run with `--trace=cuda,nvtx,mpi,openacc,ucx`, which itself inflates MPI_Init/Finalize.

---------------------------------------------------------------------------------------------------------

## 1. UCX / HPC-X settings for intra-node GPU↔GPU over NVSwitch

### What the sources say
- `cuda_ipc` is the UCX transport that moves GPU buffers between processes over NVLink; it only acts intra-node.
  UCX uses it whenever the driver can peer-map the remote GPU (always true on NVLink/NVSwitch); put_zcopy uses
  NVLink unconditionally, get_zcopy is only used when NVLink is present; underneath it is
  `cuMemcpyDtoDAsync`. **[C]** https://github.com/openucx/ucx/discussions/9896 ,
  https://docs.nvidia.com/dask-cuda/latest/ucx/
- `UCX_TLS` must include cuda transports (`cuda` = alias for `cuda_copy,cuda_ipc,gdr_copy`) or GPU memory is
  not recognised. Check UCX GPU support with `ucx_info -d | grep cuda`; `UCX_LOG_LEVEL=info` prints transports
  and devices used; with protocols v2, `UCX_PROTO_INFO=y` prints the per-size protocol table (e.g. "rendezvous
  pipeline cuda_copy" vs a zero-copy cuda_ipc path). `UCX_MEMTYPE_CACHE=n` disables the memory-type cache that
  can misdetect GPU memory as host. **[C]** https://openucx.readthedocs.io/en/master/faq.html
- Open MPI's own CUDA page: UCX is "the preferred mechanism"; example
  `mpirun --mca pml ucx -x UCX_TLS=rc,sm,cuda_copy,gdr_copy,cuda_ipc ./osu_latency D D`; verify CUDA-awareness
  with `ompi_info --parsable --all | grep mpi_built_with_cuda_support:value`; GPU may be selected after
  MPI_Init because MPI_Init creates no CUDA resources. **[C]**
  https://docs.open-mpi.org/en/v5.0.x/tuning-apps/networking/cuda.html
- UCX-Py/RAPIDS recommended values (NVLink systems): `UCX_RNDV_THRESH=8192`, `UCX_RNDV_SCHEME=get_zcopy`,
  `UCX_CUDA_IPC_CACHE=y` (default y: caches remote IPC memhandle mappings), `UCX_MEMTYPE_CACHE=n`,
  `UCX_MAX_RNDV_RAILS=1`, `UCX_MEMTYPE_REG_WHOLE_ALLOC_TYPES=cuda` (default since UCX 1.12).
  `UCX_PROTO_ENABLE` (protocols v2) is default `y` since UCX 1.16; it fixed wrong transport choice on hybrid
  NVLink topologies but "may lack proper support/testing for CUDA async and managed memory". **[C]**
  https://ucx-py.readthedocs.io/en/latest/configuration.html
- HPC-X 2.25 known issues (relevant subset) **[C]** https://networking-docs.nvidia.com/hpcxum/225/known-issues :
  - 4662365 (2.25): MPI_Bcast/Allgather/Alltoall(v) slowdowns in some cases → `UCX_RNDV_THRESH=auto,inter:12kb`.
  - 4693674 (2.25): CX-8 Alltoall 2-proc slowdown → `UCX_CUDA_COPY_BW=9500MBps` (we have no CX-8 evidence).
  - 3995982: device symbols (`cudaGetSymbolAddress`, i.e. Fortran module `declare` arrays) as MPI buffers may
    segfault → use cudaMalloc'd buffers. MFC's halo buffers are allocatable `declare create` arrays —
    allocated by the OpenACC runtime, so fine **[I]**.
  - 4139280: cudaMallocAsync memory fails with gdr_copy → `UCX_TLS=^gdr_copy`.
  - 3606732: cuda_ipc assertion / "gdr_map failed" when gdrcopy registers the same buffer (no workaround).
  - 3606445: some message sizes slower with new protocol thresholds → `UCX_PROTO_ENABLE=n`.
  - 3884209: UCC excessive registrations → `UCX_PROTO_ENABLE=n`.
  - 2.25.1 fixed "unnecessary CUDA context initialization in UCC when CUDA is not enabled".
    https://networking-docs.nvidia.com/hpcxum/226/bug-fixes-history
- No HPC-X-2.25 known issue specific to **CUDA 13** was found **[C: absence]**. The CUDA DL 25.12 container
  ships exactly HPC-X 2.25.1 + UCX 1.20.0 + CUDA 13.1 (so this combo is NVIDIA-validated) and lists one MLX5
  UCX error with workaround `UCX_DC_MLX5_AR_ENABLE=n` (inter-node only).
  https://docs.nvidia.com/deeplearning/frameworks/cuda-dl-release-notes/rel-25-12.html

### Interpretation for MFC **[I]**
- Our halo messages (0.1–3 MB) are far above any rendezvous threshold, so they already go rendezvous; the
  question is *which* rendezvous: zero-copy `cuda_ipc` (good) or the `cuda_copy` pipeline through host bounce
  buffers (bad, ≈ host-staged speed). Only `UCX_PROTO_INFO=y` tells. The 175 ms first step and ~5× lower comm
  time vs host-staged suggest cuda_ipc is already used, but it is not proven.
- 225 µs per face for ~2.6 MB is ≈ 10× the pure NVLink transfer time (~7–10 µs at 300–400 GB/s). The rest is
  pack/unpack kernels, `acc wait`, rendezvous handshake + IPC handle lookup, and **neighbour skew** (max/median
  Sendrecv ≈ 10×). Env tuning can shave the handshake part; the big win is code-side (concurrent
  Isend/Irecv for all faces, overlap) — see NTHU PR #2089/2090 and docs/literature.md.
- On a single node, `rc`/`dc`/`ud` (IB loopback) are useless; keeping them in `UCX_TLS` only costs init time and
  can steer small messages to IB loopback. `UCX_TLS=self,sm,cuda_copy,cuda_ipc` (+`gdr_copy` if
  `ucx_info -d` shows it) is the natural single-node set.
- Caveat: OMPI 4.1's `pml_ucx` may *decline* if no "network" transport is present (it has `pml_ucx_tls` /
  `pml_ucx_devices` filters) and OMPI then silently falls back to `ob1` (+`smcuda` btl). Therefore always force
  `OMPI_MCA_pml=ucx` (aborts instead of silently falling back) and check with `OMPI_MCA_pml_ucx_verbose=10`.
  If it declines, set `OMPI_MCA_pml_ucx_tls=any OMPI_MCA_pml_ucx_devices=any` **[I — verify with
  `ompi_info --param pml ucx --level 9`]**.
- `UCX_TLS` without cuda transports while passing device pointers = segfault/garbage (FAQ) — never do that.
- MFC builds without `--unified`; if `--unified` (managed memory) were ever used, cuda_ipc does not apply to
  managed memory and protov2 is less tested there.

---------------------------------------------------------------------------------------------------------

## 2. Why MPI_Init/Finalize are slow, and remedies

Observed **[L]**: MPI_Init 2.2 s (1 rank), 4 s (2), ~29 s (8, under nsys); job wall 19 s at 8 vs 7.5 s at 1;
MPI_Finalize 2 s at 8; 996 MPI_Bcast at init = 0.9 s.

Candidate causes (each must be A/B-tested — no source pins our exact case):
1. **UCX opens all 10 mlx5 HCAs per rank** (contexts, QPs, memory domains, possibly IB address resolution) —
   8 ranks × 10 devices, serialised in the kernel driver. Restricting with `UCX_TLS=self,sm,cuda_copy,cuda_ipc`
   or `UCX_NET_DEVICES=<one mlx5 near the GPU>` skips this. **[I]**; device-selection syntax `mlx5_0:1` **[C]**
   https://openucx.readthedocs.io/en/master/faq.html
2. **CUDA driver initialisation of all 8 GPUs in every rank** (UCX cuda_copy/cuda_ipc and OMPI's opal/smcuda
   CUDA support call `cuInit` and enumerate devices before MFC calls `acc_set_device_num`). If **persistence
   mode is off**, each cuInit pays "significant GPU initialization overhead" — hwloc docs explicitly recommend
   persistence mode for this reason **[C]** https://open-mpi.org/projects/hwloc/doc/v1.10.1/a00028.php .
   Also hwloc I/O discovery through NVML/CUDA is the expensive part of topology load; disable with
   `HWLOC_COMPONENTS=-opencl,-cuda,-nvml` (hwloc 1.x syntax in that doc; hwloc 2 uses the same env var) **[C]**.
   Check: `nvidia-smi -q | grep -i "Persistence Mode"`. Remedy if off: ask admins (needs root) **[I]**.
   Per-rank `CUDA_VISIBLE_DEVICES=$OMPI_COMM_WORLD_LOCAL_RANK` (wrapper) means each rank initialises one GPU
   only; but cuda_ipc between processes that see disjoint devices must then be re-verified (UCX checks peer
   accessibility) — **[I], must test** both correctness and that `UCX_PROTO_INFO` still shows cuda_ipc.
3. **HCOLL / UCC collective-component init** (SHARP probe, IB contexts, per-communicator setup also in
   `MPI_Comm_split_type` / `MPI_Cart_create`). HPC-X docs say HCOLL is *disabled by default* and UCC is
   *not enabled by default* (2.17–2.23 docs; one 2.18.1-LTS page contradicts) — but NVHPC's bundled
   `etc/openmpi-mca-params.conf` may differ, so check `ompi_info --param coll hcoll --level 9 | grep enable`
   and same for `ucc`. **[C]** https://networking-docs.nvidia.com/hpcxum/223/running-configuring-and-rebuilding-hpc-x ,
   https://docs.nvidia.com/networking/display/hpcx222/Unified+Collective+Communication+(UCC) ;
   disabling: `OMPI_MCA_coll_hcoll_enable=0`, `OMPI_MCA_coll_ucc_enable=0` **[C]**
   https://docs.excl.ornl.gov/software/mpi , https://docs.nvidia.com/cuda/cublasmp/troubleshooting/index.html
4. **HPC-X /tmp inotify bug**: MPI_Init "significant delays when there were many files in /tmp" — fixed in
   2.21, so not ours (2.25.1) **[C]** https://networking-docs.nvidia.com/hpcxum/226/bug-fixes-history .
   Older bug: MPI_Init created a CUDA context on GPU0 (fixed 2.14) — check with `nvidia-smi` during init that
   GPU0 does not show 8 processes **[C/I]**.
5. **nsys itself** (CUPTI + UCX + MPI tracing injection per process) inflates MPI_Init; measure init time
   *without* nsys (wall-clock around `mpirun` of a trivial MPI program, or `osu_init` from HPC-X OSU tests).
6. **The 996 Bcasts (0.9 s)**: ≈ 0.9 ms per Bcast is ~100× an intra-node small Bcast. Most likely this is
   *skew*, not MPI: rank 0 reads/parses input between Bcasts while others wait inside MPI_Bcast, plus leftover
   init skew **[I]**. Test: put an `MPI_Barrier` before the first Bcast (instrumentation only) or compare
   rank 0 vs others in nsys. Packing all parameters into one derived-type Bcast is a source change (PR-able).
7. **MPI_Finalize 2 s**: UCX endpoint flush/teardown over all devices, IPC cache unmapping, hcoll/ucc teardown;
   same remedies as (1)/(3) **[I]**.

Diagnostics: `UCX_LOG_LEVEL=info` (prints timestamps per transport init), `OMPI_MCA_pml_ucx_verbose=10`,
`OMPI_MCA_coll_base_verbose=10`, `strace -f -tt -e trace=openat,ioctl` on one rank, `UCX_PROTO_INFO=y`.

---------------------------------------------------------------------------------------------------------

## 3. GPU ↔ CPU/NUMA affinity under Slurm cgroups with mpirun

- **Root cause of our binding failure [C]**: Open MPI 4.1.x (incl. HPC-X 2.15/2.18) bundles hwloc 2.0, which
  does not understand cgroup v2 cpusets; mpirun then binds to cores outside the job's cpuset →
  `hwloc_set_cpubind returned "Error" for bitmap "0"`. Maintainers will not update hwloc in 4.1; fixes are
  `srun` (not available to us), `--bind-to none`, OMPI built `--with-hwloc=/usr`, or OMPI 5.0.x (hwloc ≥2.2).
  https://github.com/open-mpi/ompi/issues/12470 , https://www.osc.edu/node/6482
- So OMPI's own `--map-by ppr:4:package:PE=8 --bind-to core` will most likely fail the same way **[I]**;
  `--cpu-set <allowed list>` might work because then hwloc's view is restricted to allowed cores — cheap to
  try with `--report-bindings` **[I]**.
- **Robust option: per-rank wrapper** (binding done by the OS, not hwloc). Linux `sched_setaffinity` intersects
  the requested mask with the cgroup cpuset, so `numactl --cpunodebind=N --membind=N` / `taskset` work inside
  the cgroup as long as the job has cores on node N **[I — standard kernel behaviour]**. Our 8-GPU jobs get
  32 cores on each socket, so (untested sketch — assumes nvidia-smi index i = CUDA device i inside the job's
  device cgroup, which holds for whole-node jobs):

```bash
#!/bin/bash   # harness/bind.sh  — usage: mpirun -np 8 --bind-to none harness/bind.sh $sim
lr=${OMPI_COMM_WORLD_LOCAL_RANK:?}
# GPU NUMA node from sysfs (robust to CUDA_VISIBLE_DEVICES remapping on partial-node jobs)
bus=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader -i "$lr" | tr 'A-F' 'a-f' | sed 's/^0000//')
node=$(cat /sys/bus/pci/devices/0000${bus#0000}/numa_node 2>/dev/null || echo $(( lr / 4 )))
allowed=$(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || taskset -cp $$ | awk '{print $NF}')
# pick a private slice of the allowed cores on that node: 8 cores per rank
cores=$(python3 -I - "$allowed" "$node" "$lr" <<'EOF'
import sys
def expand(s): return [c for p in s.split(',') for c in (range(int(p.split('-')[0]), int(p.split('-')[-1])+1))]
allowed=set(expand(sys.argv[1])); node=int(sys.argv[2]); lr=int(sys.argv[3])
nodecpus=sorted(c for c in expand(open(f'/sys/devices/system/node/node{node}/cpulist').read().strip()) if c in allowed)
k=lr%4; per=max(1,len(nodecpus)//4); print(','.join(map(str,nodecpus[k*per:(k+1)*per])))
EOF
)
exec numactl --physcpubind="$cores" --membind="$node" "$@"
```
  (Assumes local rank r drives GPU r, which is what MFC does with by-slot mapping. Verify with
  `grep Cpus_allowed_list /proc/<pid>/status` and `numastat -p <pid>` during a run; log it in env.txt.)
- **Expected effect [I + C-background]**: for a GPU-resident code the kernels do not care. Affinity matters for
  (a) host-staged halos (`rdma_mpi=F`): pinned host buffers on the wrong socket cross UPI for every H2D/D2H —
  can cost tens of % of the copy bandwidth; (b) kernel-launch/`acc wait` latency of a launch-bound code
  (66 launches/stage, ~15–25 sync updates) — OS migration and cross-socket wakeups add jitter that shows up as
  Sendrecv skew; (c) MPI_Init/Bcast skew. Typical published effect for GPU-resident codes is a few %
  (larger for small/strong-scaled problems). For MFC strong scaling at 8 GPUs, where steps are ~16 ms and comm
  is skew-dominated, a 2–10 % change in step time is plausible — **measure it**; the UCX FAQ notes RDMA
  zero-copy is "inefficient when the RDMA device and GPU sit on different NUMA nodes" (relevant only
  inter-node) **[C]** https://openucx.readthedocs.io/en/master/faq.html

---------------------------------------------------------------------------------------------------------

## 4. MPI-IO on WekaFS

- No Weka-published MPI-IO/ROMIO guidance was found **[C: absence]**. WekaFS is a POSIX kernel-mounted FS;
  ROMIO treats it as generic UFS (no striping hints apply — `striping_factor/unit` are Lustre/GPFS-only) **[I]**.
- OMPIO `fs_ufs_lock_algorithm`: 0 = auto (default; locks the whole file only if the path is detected as NFS,
  otherwise no locking), 1 = skip, 2 = whole file, 3 = ranges **[C]** (OMPI fs/ufs source,
  https://accserv.lepp.cornell.edu/svn/packages/openmpi-4.0.3/ompi/mca/fs/ufs/fs_ufs_component.c ). WekaFS is
  not NFS → auto already means no locking, so the lock algorithm is very unlikely to explain 337 s
  **[I; our own `io/ompio_nolock_2g_m99` (lock_algorithm=1) is consistent: it did not fix OMPIO]**. The
  OMPIO problem is more likely in its fcoll (vulcan/dynamic) aggregation or a 4.1.9a1 bug (the segfault at
  File_close). Not worth more time: ROMIO works.
- ROMIO hints that matter on a single node (pass via `ROMIO_HINTS=/path/file`, one `key value` per line — a
  ROMIO feature honoured by `romio321` **[C]** ROMIO README,
  https://accserv.classe.cornell.edu/svn/packages/openmpi/ompi/mca/io/romio321/romio/README ):
  - `romio_cb_write enable` + `cb_nodes 1` (one aggregator node anyway) + `cb_buffer_size 67108864`
    (64 MB; default 16 MB) → fewer, larger, contiguous writes. **[C meaning, I values]**
    https://doku.lrz.de/mpi-io-10746186.html , ROMIO two-phase https://wordpress.cels.anl.gov/romio/?p=464
  - `romio_ds_write disable` (data sieving does read-modify-write + locks; FS does better) **[C]** LRZ page.
  - `cb_config_list *:2` or `*:4` to try more aggregator *processes* on the node if one writer cannot saturate
    the Weka client **[I]**.
- **File-per-process alternative**: MFC has a `file_per_process` case parameter for parallel I/O (each rank
  writes its own file, no collective at all). It changes the *file layout*, not the numerics; needs
  post_process to read it, and must be disclosed. Our benchmark output is 520 MB per save — on Weka
  file-per-process is usually the fastest pattern for few ranks **[I]**.
- I/O is outside grindtime; it matters only for the wall-time FOM. Keep `t_step_save` as given by the case.

---------------------------------------------------------------------------------------------------------

## 5. MPS / multiple ranks per GPU, CUDA_DEVICE_MAX_CONNECTIONS, power & clocks

- **MPS** maps several MPI ranks onto one GPU concurrently; it pays off when one rank cannot fill the GPU;
  without MPS ranks time-slice with a context-switch penalty; each process has its own context (~300 MB on
  V100); MPS works with OpenACC/OpenMP offload. **[C]** https://www.olcf.ornl.gov/wp-content/uploads/2021/06/MPS_ORNL_20210817.pdf ,
  https://kb.ucar.edu/x/TYA-Bg . For MFC at ≥1M cells/GPU one rank fills an H200 (GPU busy 96 % at 1 GPU
  **[L]**), and 2 ranks/GPU double the halo surface → expect **no gain** **[I]**. Only conceivable use: 2
  ranks/GPU so one rank's comm overlaps the other's compute — a cheap experiment, low priority. (MPS daemon can
  be started by the user inside the job with `CUDA_MPS_PIPE_DIRECTORY`/`CUDA_MPS_LOG_DIRECTORY` under
  `$TMPDIR`; cuda_ipc under MPS must be re-verified.)
- **`CUDA_DEVICE_MAX_CONNECTIONS`**: number of host→device hardware work queues; forum-sourced default 8,
  range 1–32; too few queues create false dependencies between streams. **[C-weak]**
  https://forums.developer.nvidia.com/t/question-on-stream-connection-and-performance/283825 ,
  https://docs.nvidia.com/nvshmem/api/latest/cuda-interactions.html . MFC launches everything synchronously on
  the default queue → **no effect today** **[I]**; becomes relevant only if we add ≥8 `async` queues (e.g.
  per-direction WENO/HLLC queues + comm queue). NVHPC OpenACC maps async queues to CUDA streams.
- **Power cap / clocks** (relevant to the SC26 power budget):
  - H100 vs H200 under caps (Ujeniya, Eitzinger, Hager, Wellein, arXiv 2604.11391, 2026) **[C]**:
    memory-bound Schönauer triad reaches peak BW on **H100 at ~350 W**, but **H200 needs ≥ ~550 W**; H200
    bandwidth degrades at ≤300 W and it cannot enforce 200 W (draws ~250 W, SM clock falls to 345 MHz).
    H200 memory power up to ~220 W (outliers 240 W) vs H100 ~120 W. Compute-bound (DGEMM): performance ∝ SM
    clock; 200→400 W gives the biggest gain, >500 W diminishing returns; H200 at 400 W beats H100 at full TDP
    in efficiency for memory-bound work. https://arxiv.org/abs/2604.11391
  - AI workloads on H200 lose 48–58 % throughput at a 300 W cap and peak in efficiency at ~400–500 W
    (arXiv 2603.16164) **[C]**. SPEChpc 2021 on H100 PCIe: 350→200 W costs 18–32 % on the most
    power-sensitive codes, ≤13 % on the least sensitive; memory-boundness alone does not predict sensitivity
    **[C]** https://lenovopress.lenovo.com/lp1706-analyzing-the-performance-impact-of-gpu-power-level-using-spechpc-2021
  - Frequency scaling (locked SM clocks) generally beats power capping for efficiency, esp. for workloads
    below TDP (Afzal et al., arXiv 2607.00819) **[C]**. https://arxiv.org/abs/2607.00819
  - **MFC is not STREAM-like**: WENO is FP64/latency-bound (DRAM 10 %), HLLC 31–42 % DRAM **[L ncu]** → its
    speed tracks SM clock, so a cap that throttles SM clock costs nearly proportionally, while H200 memory
    power is a fixed tax **[I]**. First measure actual draw: if MFC draws, say, 450–550 W at 700 W limit, a cap
    of ~550 W is free. Commands: `nvidia-smi -pl <W>` (root), `nvidia-smi -lgc <min>,<max>` (root),
    `nvidia-smi -ac 3201,<sm>` (root unless app-clock permission is unrestricted); measure with
    `nvidia-smi --query-gpu=index,power.draw,clocks.sm,clocks.mem,clocks_throttle_reasons.active
    --format=csv -lms 100` or DCGM. Energy-to-solution = ∫P dt over the `simulation` run.
  - Note ncu locks clocks to base by default (our ncu run at 1.48 GHz vs 1.98 GHz max boost).

---------------------------------------------------------------------------------------------------------

## 6. NCCL / NVSHMEM vs CUDA-aware MPI for halos inside one NVSwitch node

- Semantics: MPI and NCCL are two-sided; NVSHMEM is one-sided and GPU-initiated; NCCL/NVSHMEM are
  stream-ordered (no host sync), MPI has no stream argument → needs `acc wait` before Sendrecv **[C]**
  https://arxiv.org/pdf/2409.09874
- Measured examples: CUDA-aware MPI intra-node bidirectional ≈ 220 GB/s on an H100 node vs 300 GB/s
  theoretical (informal blog, now 410-gone) **[C-weak]**; GROMACS NVSHMEM halo: up to 1.5× better intra-node
  strong scaling than its MPI path **[C]** https://arxiv.org/abs/2509.21527 ; multi-path UCX + CUDA graphs
  up to 2.95× over single-path cuda_ipc (A100/V100) **[C]** https://arxiv.org/pdf/2604.22228 ;
  NVIDIA's reference Jacobi variants (mpi, mpi_overlap, nccl, nccl_overlap, nccl_graphs, nvshmem) — numbers only
  in GTC talks, not in repo **[C]** https://github.com/NVIDIA/multi-gpu-programming-models
- Ballpark for one H100/H200 pair over NVSwitch (NVLink4 = 450 GB/s per direction per GPU aggregate)
  **[I — from typical nccl-tests/OSU outputs, not a cited measurement; measure on nano4]**:

| message | CUDA-aware MPI (UCX cuda_ipc, blocking) | NCCL send/recv | NVSHMEM put (device-initiated) |
|---|---|---|---|
| small (≤8 KB) | 2–5 µs (eager/gdr_copy) | 6–10 µs (kernel launch) | ~1–3 µs in-kernel |
| 0.1 MB | 10–20 µs → 5–10 GB/s effective | 8–15 µs | 2–5 µs |
| 1 MB | 15–25 µs → 40–70 GB/s | 10–15 µs → 70–100 GB/s | 5–8 µs → 150+ GB/s |
| 10 MB | 35–50 µs → 200–300 GB/s | 30–40 µs → 250–350 GB/s | ~30 µs → 300–370 GB/s |

  The latency floor (handshake + host sync) dominates below ~1 MB, which is exactly MFC's regime at 8 GPUs.
  Six *sequential* blocking faces pay that floor 6× plus pack/unpack/`acc wait` each; issuing all 6 faces at once
  (Isend/Irecv + Waitall, or one NCCL group) is worth more than any env knob.
- What to run (bundled with NVHPC/HPC-X, check paths): HPC-X OSU tests
  (`$HPCX_OSU_CUDA_DIR`/`ompi/tests/osu-micro-benchmarks*`): `osu_latency D D`, `osu_bw D D`, `osu_bibw D D`
  for 2 ranks on GPUs 0↔1 and 0↔4; NVHPC `comm_libs/.../nccl` + nccl-tests `sendrecv_perf -b 64K -e 16M -f 2`.
- NCCL/NVSHMEM are source changes (new dependency) → must pass `./mfc.sh test`, be PR-able; #2093 (NTU) already
  tried NVSHMEM on H200 NVL.

---------------------------------------------------------------------------------------------------------

## Actionable A/B checklist (priority order)

Rules: one change at a time vs the current baseline (`OMPI_MCA_io=romio321 OMPI_MCA_hwloc_base_binding_policy=none`);
REPS ≥ 3; record wall, grind, nsys median step / RHS-COMMUNICATION; 2-GPU first, 8-GPU only for the winner(s).
Pass via `RUN_ENV="K=V ..."` (note: `env $RUN_ENV mpirun` exports to all local ranks since mpirun forwards
the launching environment on a single node; to be safe add `-x K` in `MPIRUN_ARGS`).

| # | Setting | Expected effect | How to verify it took effect |
|---|---|---|---|
| 0 | **Diagnostics run** (no perf claim): `UCX_LOG_LEVEL=info UCX_PROTO_INFO=y OMPI_MCA_pml_ucx_verbose=10`, `rdma_mpi=T`, 2 ranks, 1 step | Learn current transports, protocols, init timeline | Log lines `ucp_context ... transports: ...cuda_ipc...`; protocol table for `cuda` memory shows `rendezvous ... cuda_ipc` (zero-copy) not `rendezvous pipeline cuda_copy`; `ompi_info --param coll hcoll,ucc --level 9 \| grep enable`; `nvidia-smi -q \| grep -i persistence` |
| 1 | `OMPI_MCA_pml=ucx` (force) + `OMPI_MCA_btl=^smcuda,openib,uct` | No silent ob1 fallback; skip smcuda CUDA init; uct btl is a known corruption risk (UCX FAQ) | Job aborts if UCX PML not selectable; `OMPI_MCA_pml_base_verbose=10` prints "select: component ucx selected" |
| 2 | **Single-node UCX_TLS**: `UCX_TLS=self,sm,cuda_copy,cuda_ipc` (+`,gdr_copy` if listed by `ucx_info -d`) | MPI_Init/Finalize ↓ (no 10-HCA open); maybe small-msg latency ↓ | `UCX_LOG_LEVEL=info` shows no `mlx5_*`/`rc`/`dc` lines; time MPI_Init (nsys MPI range or wall of a `mpirun -np 8 true`-like MPI hello). Fallback if pml_ucx declines: `OMPI_MCA_pml_ucx_tls=any OMPI_MCA_pml_ucx_devices=any`, or keep IB but `UCX_NET_DEVICES=mlx5_X:1` (one NIC) |
| 3 | `OMPI_MCA_coll_hcoll_enable=0 OMPI_MCA_coll_ucc_enable=0` | MPI_Init, comm-split/cart-create and Finalize ↓ if either was on; Bcasts fall back to `coll/tuned` | `OMPI_MCA_coll_base_verbose=10` lists selected coll components; no `hcoll`/`ucc` in `lsof -p` / `UCX_LOG_LEVEL` output |
| 4 | **NUMA binding wrapper** (§3) with `--bind-to none`; alternative `--cpu-set <cgroup list> --map-by ppr:4:package:PE=8 --bind-to core --report-bindings` | Step-time jitter ↓, Sendrecv skew ↓, host-staged copies ↑; expect 0–10 % | `/proc/<pid>/status` `Cpus_allowed_list` per rank within GPU's NUMA; `numastat -p`; compare max/median Sendrecv in nsys |
| 5 | `HWLOC_COMPONENTS=-opencl,-cuda,-nvml` (and persistence mode on, admin) | MPI_Init ↓ if hwloc NVML/CUDA probing or cold GPU init dominates | MPI_Init time; `strace -c` shows fewer `nvidia*` ioctls during init |
| 6 | Rendezvous knobs: `UCX_RNDV_SCHEME=get_zcopy` vs `put_zcopy` vs default `auto`; `UCX_RNDV_THRESH=8192` | ± a few µs per face | `UCX_PROTO_INFO=y` table changes accordingly; RHS-COMMUNICATION median |
| 7 | `UCX_PROTO_ENABLE=n` (protocols v1) | HPC-X lists it as workaround for some size regressions; may help or hurt | `UCX_PROTO_INFO` output disappears (v1); compare comm time |
| 8 | `UCX_MEMTYPE_CACHE=n` | Correctness safety net; slight overhead per call | Only if any GPU-buffer misdetection/segfault; HPC-X sets default per build (`ucx_info -c \| grep MEMTYPE_CACHE`) |
| 9 | `UCX_CUDA_IPC_CACHE=y` (default; confirm) | Keeps steady-state IPC cost low; the 175 ms first step is the cache fill | `ucx_info -c \| grep CUDA_IPC_CACHE`; first-step vs median step in nsys |
| 10 | Per-rank `CUDA_VISIBLE_DEVICES` via wrapper | MPI_Init ↓ (1 GPU initialised per rank) | MPI_Init time; **must** re-check cuda_ipc still selected (#0) and `./mfc.sh test`-equivalent bitwise compare; MFC `local_rank mod ndev` then gives device 0 = correct GPU |
| 11 | ROMIO hints file via `ROMIO_HINTS`: `romio_cb_write enable`, `cb_nodes 1`, `cb_buffer_size 67108864`, `romio_ds_write disable`; then `cb_config_list *:2/4` | SAVE-DATA time ↓ | `MPI_File_get_info` dump (or ROMIO `ROMIO_PRINT_HINTS=1` if supported **[I]**); nsys MPI_File_write_all duration |
| 12 | `file_per_process=T` (case parameter, disclose) | SAVE-DATA ↓ further | Output file count = ranks; post_process reads it |
| 13 | Power: measure draw first; then `-pl 550/500/450` or locked clocks (admin) | Find cap that costs <2–3 % | `clocks_throttle_reasons.active`, power.draw trace, grind & energy-to-solution |
| 14 | MPS with 2 ranks/GPU; `CUDA_DEVICE_MAX_CONNECTIONS=32` only after async-queue code exists | Probably none for current code | `nvidia-smi` shows `M+C` / mps-server; compare step time |

Do **not** set: `UCX_TLS` without `cuda_*` (breaks device buffers), `UCX_GVA_ENABLE=y`, `UCX_DC_MLX5_TX_POLICY=dcs_hybrid`
(HPC-X known issues), anything that changes numerics.

## Sources (consulted)
- UCX FAQ https://openucx.readthedocs.io/en/master/faq.html
- UCX NVLink discussion https://github.com/openucx/ucx/discussions/9896
- UCX-Py config https://ucx-py.readthedocs.io/en/latest/configuration.html ; dask-cuda UCX https://docs.nvidia.com/dask-cuda/latest/ucx/
- Open MPI CUDA https://docs.open-mpi.org/en/v5.0.x/tuning-apps/networking/cuda.html
- HPC-X 2.25 known issues https://networking-docs.nvidia.com/hpcxum/225/known-issues ; bug-fix history https://networking-docs.nvidia.com/hpcxum/226/bug-fixes-history
- HPC-X running/HCOLL default https://networking-docs.nvidia.com/hpcxum/223/running-configuring-and-rebuilding-hpc-x ; UCC https://docs.nvidia.com/networking/display/hpcx222/Unified+Collective+Communication+(UCC)
- CUDA DL 25.12 release notes https://docs.nvidia.com/deeplearning/frameworks/cuda-dl-release-notes/rel-25-12.html
- OMPI hwloc/cgroup issue https://github.com/open-mpi/ompi/issues/12470 ; OSC note https://www.osc.edu/node/6482
- hwloc FAQ (I/O discovery cost, persistence mode, HWLOC_COMPONENTS) https://open-mpi.org/projects/hwloc/doc/v1.10.1/a00028.php
- ORNL ExCL (hcoll disable) https://docs.excl.ornl.gov/software/mpi ; cuBLASMp (ucc disable) https://docs.nvidia.com/cuda/cublasmp/troubleshooting/index.html
- OMPI fs/ufs lock algorithm https://accserv.lepp.cornell.edu/svn/packages/openmpi-4.0.3/ompi/mca/fs/ufs/fs_ufs_component.c
- ROMIO README https://accserv.classe.cornell.edu/svn/packages/openmpi/ompi/mca/io/romio321/romio/README ; LRZ MPI-IO https://doku.lrz.de/mpi-io-10746186.html ; ROMIO blog https://wordpress.cels.anl.gov/romio/?p=464
- OLCF MPS https://www.olcf.ornl.gov/wp-content/uploads/2021/06/MPS_ORNL_20210817.pdf ; NCAR MPS https://kb.ucar.edu/x/TYA-Bg
- H100 vs H200 power capping https://arxiv.org/abs/2604.11391 ; AI power-aware benchmarking https://arxiv.org/abs/2603.16164 ; energy sweet spots https://arxiv.org/abs/2607.00819 ; Lenovo SPEChpc https://lenovopress.lenovo.com/lp1706-analyzing-the-performance-impact-of-gpu-power-level-using-spechpc-2021
- GPU-centric comm landscape https://arxiv.org/pdf/2409.09874 ; GROMACS NVSHMEM https://arxiv.org/abs/2509.21527 ; multi-path UCX https://arxiv.org/pdf/2604.22228 ; NVIDIA multi-GPU models https://github.com/NVIDIA/multi-gpu-programming-models
- Perplexity MCP returned errors for all queries in this session; everything above is from WebSearch/WebFetch.
