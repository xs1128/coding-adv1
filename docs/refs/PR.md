## 1. Fused WENO/Riemann/RHS kernel (`MFC_FUSED_RHS`)

### The bottleneck in the existing pipeline

One RHS evaluation on the GPU is a sequence of full-domain kernels. The sequence runs the
conservative-to-primitive conversion, the WENO reconstruction, the Riemann solver, and the
RHS assembly, with boundary population between them. The WENO reconstruction writes both
face values of every field, for every direction, to device memory. The Riemann solver reads
those face values back and writes per-direction flux fields. The RHS assembly reads the
flux fields back again. The kernels are `s_convert_conservative_to_primitive` in
`src/common/m_variables_conversion.fpp`, `s_weno` in `src/simulation/m_weno.fpp`,
`s_hllc_riemann_solver` in `src/simulation/m_riemann_solver_hllc.fpp`, and `s_rhs` in
`src/simulation/m_rhs.fpp`. Every intermediate is a full-domain array. At 200³ with an
8-row state, one set of reconstructed face values is approximately 1.0 GB. The three per-direction
flux fields add approximately 1.6 GB. All of it goes to device memory and back within a
single stage, to produce a 0.5 GB RHS. A profile of the original kernels shows the
result. All of them stall mostly on long scoreboard, which is the wait for off-chip loads of
their own intermediates. Every stencil value makes a round trip through L2.

### What this change does

The fused kernel replaces the per-direction part of that pipeline with **one kernel per
coordinate direction** (`s_weno_fused_rhs_openacc_kernel` in `m_fused_rhs_openacc.fpp`).
The single launch executes the primitive conversion, the WENO reconstruction, the Riemann
solve (HLLC, HLL, LF, or HLLD), the flux differencing, and, for the final RK stage, the
time update. The kernel stages the working set into shared memory once
(`s_fused_weno_state` in `include/fused_weno.fpp`). The working set is the stencil of the
state for a column of cells. Every intermediate (face values, fluxes, viscous stresses,
source terms) stays in registers and shared memory. No intermediate reaches device memory.
The halo exchange, the boundary fill, and the diagnostics stay where they are.

The fused implementation is in `m_fused_rhs_openacc.fpp`, with the column staging in
`include/fused_weno.fpp`.

The fused kernel reconstructs every volume fraction, including the last one, as the
original code does. The mixture closures are the same sums over the fluids as
`s_compute_mixture_coefficients`.

The solver decides at run time whether a case uses the fused kernel
(`f_use_fused_rhs_openacc` in `m_rhs.fpp`). Other cases use the classic pipeline in the same
binary. For example, HLL with `alt_soundspeed = T` uses the classic pipeline (no such test case exist in CI so far).

### Why it works

| configuration | kernel | launches/step | µs each | µs per step |
| --- | --- | ---: | ---: | ---: |
| original | WENO reconstruction | 3 | 1250 | 3750 |
| original | HLLC Riemann solver | 3 | 1710 | 5130 |
| original | RHS assembly | 1 | 822 | 822 |
| original | **stage total** | **7** | | **9702** |
| fused | x direction | 1 | 2119 | 2119 |
| fused | y direction | 1 | 1538 | 1538 |
| fused | z direction | 1 | 2197 | 2197 |
| fused | **stage total** | **3** | | **5854** |

| metric | original stage kernels | fused kernels |
| --- | --- | --- |
| dominant stall | long scoreboard on all three kernels. The SM waits on device-memory loads of the stage's own intermediates. | barrier on all three kernels. Warps wait on the shared-memory exchange of column faces, which is an on-chip dependency that cannot be optimized further. |
| memory / SM throughput | 30 to 57% / 18 to 59% of peak. The kernels wait on the latency of intermediate arrays. | 25 to 49% / 30 to 32% of peak. The bottleneck moves to the on-chip barrier chain. |

The original total time excludes the conversion and advection kernels. The fused kernels include those, so the original total above is underestimating the real run time.

Host calls per time step (1 GPU, 50-steps).

| configuration | host calls per step | host-to-device transfers |
| --- | ---: | ---: |
| original | 93 launches | 93 |
| fused | 13 | 3 |

The fused implementation alone is 2.6× faster than the original build on the 200³
performance test. The grind goes from 0.361 to 0.141 ns/gp/eq/rhs on 1 GPU (measured before most of the recent HLLC regressions). The fused
implementation is also faster on multiple nodes. On the 2D viscous shock tube, at 2 nodes × 4
GPUs with every other optimization fixed, it is 2.1× faster than the original code over 2107
steps (grind 0.0975 and 0.0473). At one GPU it is 2.9× faster.

### Physics coverage

The fused implementation supports the physics families below. Each family has its own
benchmark case. The table compares each case against the original code, with all
optimizations enabled. tol = tolerance as defined by their respective test suite cases. ulp = unit of least precision.

| physics family | grind | numerical parity vs original code |
| --- | ---: | --- |
| 5-eq inviscid (HLLC/HLL/LF, mapped/JS/WENO-Z, WENO3/5/7) | 2.1× faster | sub-ulp |
| viscous Newtonian (IBM benchmark) | 1.45× faster | sub-ulp |
| non-Newtonian (Herschel-Bulkley mixture, unrolled per fluid) | 2.1× faster | <9.8e-16 |
| continuum damage | 2.7× faster | bit-identical |
| cylindrical geometry (grid_geometry 3) stress + hoop terms | 1.27× faster | <1.2e-14 |
| characteristic-BC band viscous divergence | 1.23× faster | <1.0e-14 at 1e-7 tol |
| MHD (HLLD) | 3.4× faster | <4.1e-12 at 1e-8 tol |
| weno_order 1 (5-eq HLLC) | 1.52× faster | <2.8e-12 at 1e-3 tol |
| 6-equation | 2.3× faster | <1.2e-13 at 1e-10 tol |
| surface tension | 1.69× faster | <1.0e-14 at 1e-12 tol |
| chemistry | 2.0× faster | <2.9e-16 at 1e-12 tol |
| THINC | 5.6× faster | <1.0e-14 at 1e-12 tol |
| bubbles (Euler-Euler) | 1.54× faster | bit-identical |
| QBMM | 1.25× faster | <7.7e-11 at 1e-10 tol |

§11 and §14 list the solver paths that this PR changes in place.

### Aligned state stride
The state layout aligns with the memory system in two
pads, computed at configuration (`m_global_parameters.fpp`). Each state row has a padded
stride, so every row base address lands on a cache line. The allocation front has the same
pad, so the ghost-cell offset keeps the transverse lane runs on the sector grid. The RHS
rows and the moment, IGR, and source arrays that the per-direction kernels read carry the
same pads. On the 200³ performance test, this alone makes it 1.062× faster at 1 GPU and 1.042× at 4 GPUs,
with bit-identical output.

Cost: due to padding, additional memory is required. Below is the table for the 200^3 3D Performance Test case. These can be statically calculated before running.

| array | fields | pad per row | extra memory |
| --- | --- | ---: | ---: |
| `q_cons_ts` staging pool | 3 × 8 = 24 | +15 of 209 | 125.8 MB |
| `q_prim_vf` | 8 | +15 of 209 | 41.9 MB |
| `rhs_vf` | 8 | +7 of 203 | 18.5 MB |

The overhead is bounded by one alignment unit per row, so it shrinks as the row
grows. For the 2834^2 advection case, there are 1417 interior cells per rank, pads 1425 to
1440 elements, 1.1% additional memory.

### RK buffer ping-pong
The RK3 staging alternates its storage buffers (three under
RK3). It does not copy the updated conservative state between stages
(`m_time_steppers.fpp`). This removes one full-domain copy and conversion per stage. On
the 200³ performance test it is 1.014× faster at 1 GPU and 1.007× at 4. Unified-memory
builds keep the copy per stage, because the alternation needs an extra RK buffer.

### Hardware-specific tuning

To allow for more flexible hardware-software co-optimization (for NVIDIA GPUs for now), the fused kernel has compile-time constants that can be independently tuned for each hardware. The tuning process is optional but recommended for large scale runs to save end to end runtime, and thus cost. The tuning code will be released after the SC26 SCC competition for reference, as currently they are too specialized for our hardware and we think it is not suitable to PR into the main repository. The current PR sets a default for each tunable parameter which may not be optimal on all hardware. A
developer can override them at build time with `MFC_TUNING_FILE` or the
`MFC_FUSION_*` environment variables.

| constant | default | geometry it sets |
| --- | ---: | --- |
| `MFC_FUSION_STAGING_BYTES` | 32768 | Size in bytes of the shared memory buffer that stages the working set of a column. The kernel shrinks the tile when the set does not fit. |
| `MFC_FUSION_X_PADDED_CELLS` | 16 | Cells in one x run of the x direction kernel. The interior x range is padded to multiples of this run. |
| `MFC_FUSION_TRANSVERSE_CELLS` | 4 | Cells in one run along the sweep direction of a y or z direction kernel. |
| `MFC_FUSION_TRANSVERSE_WIDE_CELLS` | 4 | Only for the six equation WENO3 family without MUSCL. |
| `MFC_FUSION_TRANSVERSE_LANES` | 2 | Rows a y or z direction kernel carries in parallel per run. The run and the rows together form the transverse tile. |
| `MFC_FUSION_TRANSVERSE_WIDE_LANES` | 2 | Only for the six equation WENO3 family without MUSCL. |
| `MFC_FUSION_COMPACT_LANES` | 2 | Rows of the compact form the kernel falls back to when the transverse working set exceeds the staging buffer, and of the 3D gradient columns. |
| `MFC_FUSION_CHEM_LANES` | `[1, 2]` | Candidate row counts of the chemistry pass. The kernel takes the largest whose species rows fit the staging buffer. |
| `MFC_FUSION_VECTOR_X` | 128 | Vector length of the x direction kernel. |
| `MFC_FUSION_VECTOR_TRANSVERSE` | 64 | Vector length of the y and z direction kernels. |
| `MFC_FUSION_VECTOR_COMPACT` | 128 | Vector length of the compact kernels. |
| `MFC_FUSION_VECTOR_CHEM_PER_LANE` | 32 | Vector length per lane of the chemistry pass. The pass uses the maximum of this value times its lanes and the x vector length. |
| `MFC_BUBBLE_VECTOR_LENGTH` | 128 | Vector length of the Euler-Euler bubble source kernels. |
| `MFC_STATE_ALIGNMENT_BYTES` | 128 | Row stride alignment in bytes of the state arrays. |

`MFC_TUNING_FILE` names a JSON profile whose key maps the constants below.
The profile applies in builds with `--fused-rhs` or `--fused-bubble-source`. Every
entry except `MFC_FUSION_CHEM_LANES` takes one positive integer. Below is a sample that reproduces the defaults values. Setting a profile changes the build slug
even when the values equal the defaults.
```json
{
  "values": {
    "MFC_FUSION_STAGING_BYTES": 32768,
    "MFC_FUSION_X_PADDED_CELLS": 16,
    "MFC_FUSION_TRANSVERSE_CELLS": 4,
    "MFC_FUSION_TRANSVERSE_WIDE_CELLS": 4,
    "MFC_FUSION_TRANSVERSE_LANES": 2,
    "MFC_FUSION_TRANSVERSE_WIDE_LANES": 2,
    "MFC_FUSION_COMPACT_LANES": 2,
    "MFC_FUSION_CHEM_LANES": [1, 2],
    "MFC_FUSION_VECTOR_X": 128,
    "MFC_FUSION_VECTOR_TRANSVERSE": 64,
    "MFC_FUSION_VECTOR_COMPACT": 128,
    "MFC_FUSION_VECTOR_CHEM_PER_LANE": 32,
    "MFC_BUBBLE_VECTOR_LENGTH": 128,
    "MFC_STATE_ALIGNMENT_BYTES": 128
  }
}
```

### The compact form of the transverse kernels

Each y or z direction kernel of the fused path processes one tile per block. The tile
holds `MFC_FUSION_TRANSVERSE_CELLS` cells along the sweep direction and
`MFC_FUSION_TRANSVERSE_LANES` rows across it. The block stages the reconstruction
stencil of every record of the tile into shared memory, then reconstructs and solves
the Riemann problems of the whole tile on chip.

The compact form is the same kernel with a narrower tile. The run length stays and the
rows become `MFC_FUSION_COMPACT_LANES`. The vector length becomes
`MFC_FUSION_VECTOR_COMPACT`. The generator picks the form at compile time from the
physics of the case.

There are 2 conditions pick the compact form. The first is a fit test. Bubbles and hypoelasticity add information to the state, which are the bubble moments and the stress components. When the staged set of the full tile would
exceed `MFC_FUSION_STAGING_BYTES`, the sweep takes the compact form so the tile fits
the buffer.

The second is the reconstruction gradients. A 3D case with `weno_Re_flux = T`
reconstructs the velocity gradients inside the sweep and stages one gradient column
per direction and component next to the state columns. These sweeps take the compact
form to hold both sets. TENO7 cases keep the regular form because the compact form exists to make room for the gradient columns, and TENO7 does not stage any. Their sweeps read the precomputed face
gradients, so the tile fits without narrowing.

The x direction kernel is never compact. It carries one row by construction.

### Restructured non-fused HLLC paths (`MFC_HLLC_REGISTER_TUNING`)

`MFC_HLLC_REGISTER_TUNING` selects the restructured HLLC paths. This unlocks the use of `MFC_REGISTER_CAPS` which allow users to tune register caps according to their own GPU. Examples on how to use this is at a later section.

From my investigation on #2088, recent changes to HLLC kernel moved the HLLC kernel's mixture, energy and sound speed math
into helper routines in other files, and the GPU pays a call on every face, causing significant regression.
This flag moves that math back inside the kernel with the case's constants
baked in (via case optimization).

This is also the direct fix to #2088, improving the performance of the HLLC kernel from current 2.83ms to 1.30ms (v4.9.3 was 1.42ms), improving the grind time on the 3D Performance Test case on H200 PCIe to 0.304ns, beating current best 0.32ns on GH200.

Note that this entire restructured HLLC kernel is independent of the fused kernel, which does not have these regressions by design (no cross-TU device call), and this flag is ignored when the case can use the fused path. Some cases involving alt_soundspeed, chemistry, MHD, hypoelasticity and surface tension combinations cannot use the fused path and therefore falls back to the non-fused path, in which this flag become useful.

## 2. Characteristic BCs without host synchronization (`MFC_CBC_NO_HOST_SYNC`)

Every `s_cbc` call needs control values on the device. These are the coordinate direction
that the boundary face is perpendicular to, the end of the axis that the face sits on, the
grid spacing at that face, and the equation slots that hold continuity, momentum, and
energy. The original code keeps these values in module variables that the device kernels
read. Before every call, the host pushes the values over with a blocking copy and fills
a spacing array again. Each copy stalls the host in the middle of the step.

With this flag, the host computes the direction, the axis end, the spacing, and the equation
slots at each call. It passes them as kernel arguments. The arguments travel with the launch,
so no copy and no wait occur. A single kernel writes the per-direction coefficient tables to
the device once, at initialization.

`MFC_CBC_PARALLEL_SCATTER` parallelizes the copy-out of the 3D boundary fluxes. The
characteristic-boundary kernels write their results into a staged buffer. The original
code copies that buffer into the per-field flux arrays with serial loops inside the
kernel. In that copy, one thread walks every field and face point. The flag moves the
copy into a separate kernel that spreads it across fields and face points. It requires
`MFC_CBC_NO_HOST_SYNC`.

| measurement | |
| --- | ---: |
| host-to-device transfers per step, original build | 147 |
| host-to-device transfers per step, with all optimizations | 3 |
| grind on 1 GPU | 1.02× faster |
| grind on 4 GPUs | 1.03× faster |

The numerical difference is below 1.6e-7.

The code is in `m_cbc.fpp` (the launch-parameter scalars and one-trip direction tables of
`MFC_CBC_NO_HOST_SYNC`, and the parallel 3D output scatter of
`MFC_CBC_PARALLEL_SCATTER`).

## 3. Asynchronous execution (`MFC_ASYNC_QUEUE`)

For every synchronous OpenACC region, the compiler emits a kernel launch and then a
`cuStreamSynchronize`. The host cannot enqueue the next region until the previous one
returns. The original code has 432 blocking syncs per step. The GPU idles in the
gaps between kernels. This flag puts the whole per-step path on one non-default OpenACC
queue.

The flag requires `--accurate-grind-time` because the host runs ahead of the device on the queue,
so the printed grind needs device events (§4).

| configuration | 1 GPU | 4 GPUs |
| --- | ---: | ---: |
| default | 1.04× faster | 1.11× faster |
| fused | 1.07× faster | 1.23× faster |

These are measured on AMD EPYC 9755 CPU, a rather high-end CPU in single-core performance. We expect performance improvements of this feature to be greater on majority of other clusters with weaker CPUs.

The code is in the GPU macro layer, `src/common/include/shared_parallel_macros.fpp` (the
non-default queue and the wait rules) and `src/common/include/parallel_macros.fpp`.
Every physics path gets the queue through the existing `GPU_*` macros.

## 4. Device-event grind time measurement (`MFC_ACCURATE_GRIND_TIME`)

The original code measures the grind with host clocks. The value is the minimum over RK
stages of the host-observed stage time. That measurement is correct for the synchronous
execution model. Under asynchronous execution, the host enqueues a stage and returns at once.
A host clock then measures the enqueue latency, which severely underestimates the actual grind time. This flag uses hardware device events (CUDA/HIP events) to accurately measure the execution time on
the compute stream (a standard approach widely used, e.g. in PyTorch). CPU based runs are unaffected by this as there is no concept of hardware stream queue without GPUs.

| build | host-clock timer | device-event timer |
| --- | ---: | ---: |
| with all optimizations (asynchronous) | 1.4e-4 | 0.113 |
| original (synchronous) | 0.3605 | 0.3606 |

On
the synchronous original build, the two timers agree to four significant figures, showing that the actual timed region is still strictly followed.

The flag needs an OpenACC GPU build with NVHPC or CCE. The capture uses CUDA events on
NVHPC and HIP events on CCE. The grind report groups the ranks per GPU with
`CUDA_VISIBLE_DEVICES`, `ROCR_VISIBLE_DEVICES` or `HIP_VISIBLE_DEVICES`. The instrumentation
costs a fixed 1.5 to 1.7 ms of host time per step which is only obvious in toy-scale cases.

The code is in `m_time_steppers.fpp` and `m_start_up.fpp`.

## 5. CUDA graph capture and replay (`MFC_CUDA_GRAPHS`)

With the kernels fused and the queue asynchronous, the host cost that remains in the step
is the launch of each region. This flag captures the per-step device work that has no
communication into a CUDA graph at a warmup step, and replays it (`m_cuda_graph.fpp`). The
replay puts the captured step work into three CUDA graph launches per step. The regions
that the graph does not capture run as plain launches (ten per step on the 200³ performance
test). Capture and instantiation happen once at warmup (approximately 7 ms) for the whole
run. Replay output is bit-identical to plain execution.

The flag requires `--async-queue`, because the capture records the kernels on that queue.

The next table gives the effect of the flag in step time, on top of the fused
implementation and the queue so the relative speedup is small.

| case | wall step time |
| --- | ---: |
| 200³ performance test, 1 GPU | 1.008× faster |
| 200³ performance test, 4 GPUs | 1.018× faster |
| 100³ | 1.036× faster |
| 49×39 2-D | 1.35× faster |

Step time is the metric that sees the work of the flag. The launch gaps between regions are
outside the bracket of the device-event grind. On the 2D case, the queue alone makes the step
2.3× faster, and graph replay makes it a further 1.35× faster (from 1.67 ms to 0.54 ms per
step). The gaps inside the grind time bracket shrinks 1.2× on this small case.

The saving grows as the share of work per GPU gets smaller, improving strong scaling. The launch sequence per step
is the same for all domain sizes. When the run adds ranks, or the case is smaller, the
launches take a larger part of the step of every rank.

Capture is dynamic. The code brackets the region (`f_graph_action` /
`f_graph_commit`) and the graph records everything that the physics path launches inside
the region. The graph also captures kernels that new physics or fypp changes add, with no
registration per kernel. The capture check uses the data transfers and the launch topology
of the region, so new features can use the same dispatch logic. Therefore, I do not expect this feature to add maintenance burden.

The code is in `m_cuda_graph.fpp` (the capture decision and Fortran interface),
`m_cuda_graph_backend.cpp` (capture, instantiate, replay), `include/graph_macros.fpp`,
`m_fftw.fpp` (FFT plans bound to the compute stream), and `m_riemann_solver_hll.fpp`,
`m_riemann_solver_lf.fpp` and `m_riemann_solver_hlld.fpp` (`norm_dir` as `firstprivate`).


## 6. Halo exchange (`MFC_HALO_SINGLE_ROUND`, `MFC_HALO_INDEX_CACHE`, `MFC_NVSHMEM`)

- **Single round.** Currently, the exchange sends the faces one direction at a time. Edge and
  corner values arrive after the next rounds. The three rounds per RK stage therefore
  depend on each other, which costs nine synchronization points per time step. The
  single-round form enumerates every face, edge, and corner neighbor and packs one disjoint
  buffer per neighbor (`halo_26_dir`, `halo_26_point_offset` and `halo_26_point_count` in
  `m_mpi_common.fpp`). It posts the whole exchange in one round per stage. Nine rounds
  become three, and no round depends on the unpack of another. The corner messages are small
  (approximately 512 values against approximately 320k for a face). The message count goes up,
  and the byte count stays almost the same. The result is bit-identical to the current exchange
  on MPI.
  
  When any rank has a Dirichlet boundary face, it reverts to using the current exchange. The current exchange carry the face owner's buffer value into the corner where a
Dirichlet face meets a processor seam, and the single round would place the
neighbor's data there instead.

  A similar optimization is #2090 which makes the exchange nonblocking. It uses one `MPI_Isend`/`MPI_Irecv` pair
  and one `MPI_Waitall` per direction in place of two blocking `MPI_SENDRECV` calls. The two
  changes work together. With both merged, the nonblocking form of #2090 improves the
  exchanges that this flag does not enable. Outside of those, I believe this approach is better:

  | | #2090 | single round |
  | --- | --- | --- |
  | concurrently transmitted | the two sides of one direction | every face, edge, and corner neighbor |
  | rounds per exchange | 3, one per direction, each after the unpack of the previous round | 1 |
  | completion | one blocking `MPI_Waitall` per direction | plain MPI completes the exchange with one `MPI_WAITALL` pair for all neighbors. GPU-direct MPI uses persistent requests and retires the sends at the post of the next exchange. NVSHMEM waits in device kernels. |

- **Index cache.** The original code computes the point coordinates of each neighbor again
  on every exchange (`s_get_26_neighbor_indices`). On a fixed grid, they are constants. The
  cache builds them once and builds them again on a grid change
  (`s_get_26_cached_indices`). The flag requires `MFC_HALO_SINGLE_ROUND`.
- **NVSHMEM transport.** One-sided NVSHMEM puts into a symmetric-heap inbox replace MPI
  sendrecv for the conserved-field halo. The puts run over six double-buffered channels
  with ready and consumed signal pairs for flow control. The host issues the bulk
  transfer in stream order on the compute queue. The waits and completions live in device
  kernels. This puts 78 operations per exchange on the stream into three launches.
  `gen_nvshmem.py` derives the transport from the annotated MPI regions in the Fortran
  (`MFC_COMM_BEGIN` / `MFC_COMM_END`) and generates it again when they change.
  The schedule takes field counts, point counts, and peers from the packing routines at
  run time. New fields and new physics therefore use the existing exchanges through their
  Fortran definitions.
  
  Costs/trade offs:
  - When there is a new communication pattern, it needs its support added in the generator.
  - Extra staging memory required for the symmetric buffer (like any SHM communications). Each rank allocates:
    - The staged inbox holds 12 slots, six channels double buffered by epoch parity, each
      slot one payload wide.
    - The 26-neighbor inbox under `--halo-single-round` holds two payloads, one per epoch
      parity.
    - One ready and one consumed signal array per channel, about 1 KB together.
    - An IB patch inbox for IBM cases, one uniform slot per rank plus a patch count slot,
      and an IGR inbox for IGR cases.


    On the 200³ performance test at 8 GPUs, grid 1×2×4, double
    precision, the worst rank owns 201×101×51 cells and exchanges one y face, two z faces
    and two edges, 209,844 points times 8 variables, a 13.4 MB payload.

    | piece | size |
    | --- | ---: |
    | 26-neighbor inbox, 2 × payload | 26.9 MB |
    | staged inbox, 12 × payload | 161.2 MB |
    | signals | about 1 KB |
    | total | 188 MB per rank |

    Without `--halo-single-round` the bound falls back to the staged slab of about 729,000
    elements, so the heap is 12 slabs, about 70 MB, and the 26 inbox does not exist. In a
    single round build the staged slots inherit the 26 sized bound even though a staged
    channel only ever carries one direction, so the two inboxes together cost more than
    either alone.

    The heap scales with the per rank ghost shell, surface times ghost depth times
    variables. It grows with the local domain and with `buff_size`.
    
    That being said, NVSHMEM maps the heap in 512 MiB
    units, so the minimum extra VRAM it takes per rank (and per GPU, if 1 rank on each GPU) is 512MiB.

On the 200³ performance test at 4 GPUs:
| configuration | grind |
| --- | ---: |
| single-round exchange | 1.036× faster |
| single-round exchange + index cache | 1.041× faster |

| Exchange census, 4 GPUs, per rank-step | NVSHMEM | GPU-direct MPI |
| --- | --- | --- |
| exchange transfers | 18 stream-ordered puts on the compute queue | 36 host-issued copy-engine peer transfers |
| exchange waits | device kernels | host (MPI wait) |
| blocking synchronizations on the stepping path | 0 | 12 (context syncs from CUDA-aware MPI) |

The next table compares the two transports on two nodes across case families (8 ranks, arms
identical except the transport, three interleaved repetitions each).

| case family | NVSHMEM vs GPU-direct MPI |
| --- | --- |
| 2D viscous shock tube (1280×640) | grind 9.4% slower, step wall 1.19× faster |
| IGR jet bench (768×768×384) | grind within 0.5%, step wall 1.20× faster |

The rows give two metrics because the transport moves the exchange onto the device. The
grind contains the puts and wait kernels of the exchange. The host does not block in MPI
waits between stages. The stalls that the transport removes are between stages. They are
outside the bracket of the grind and inside the bracket of the step. The step therefore
shows the gain of the transport. The single-node scaling study measures the step 7 to 25%
faster at 2 to 8 GPUs, and the two rows above measure it 1.19× and 1.20× faster. The grind time get faster when the host work of the original blocks inside the timed region. The IBM force
exchange below is an example.

The IBM force exchange has the highest exchange density. Its force and patch exchanges per
step add small, frequent messages on top of the halo. The exchange is owner-based. Each rank
sends its nonzero partials for a body directly to the rank that owns the body. The owners
broadcast the totals back. On the NVSHMEM transport the exchange stays on the device. The
partials go into symmetric slots indexed by owner rank. A kernel ships them through the peer
mapping of each neighbor, which the setup resolves once.

On 8 GPUs, a moving-sphere
case (`2440B4AE`) runs 1.25× faster grind time, and 1.31 faster end-to-end time with the device-resident exchange than with the MPI exchange.

Three environment variables control the exchange at run time (see "Environment variables").
`MFC_HALO_OVERLAP` overlaps the halo exchange with the interior computation in the fused
path.
`MFC_HALO_EPOCH_DEVICE` completes the 26-neighbor exchange on the device, so a CUDA graph can
capture the exchange. `MFC_HALO_26_TRIM` shrinks the 26-neighbor exchange to the active-box
window, if both features are enabled.

The code is in `src/common/m_mpi_common.fpp` (the neighbor enumeration and packing, the index
cache, and the GPU-direct transport). The generated backend of the NVSHMEM transport is in
`src/nvshmem/` (`gen_nvshmem.py`, `nvshmem_ir.py`, and the `templates/` sources). The
Fortran interface is `src/common/m_nvshmem_interfaces.fpp`.

## 7. WENO direct loads (`MFC_WENO_DIRECT_LOADS`)

#2092 reads the WENO3/5/7 stencils from the field in place in the default
module. #2092 therefore covers the direct read itself which coincides with this PR. On top of that, this flag also removes the staging
copy in other configurations: the MP-WENO bounds (`s_preserve_monotonicity` in `m_weno.fpp`) and THINC compression (`s_thinc_compression` in `m_thinc.fpp`), making their reads in-place from both the WENO and the MUSCL
reconstruction. #2092 keeps the copy for `mp_weno` and `int_comp > 0`, and measures 0.45%
higher grind on a WENO5 + MP-WENO case.

The flag changes the non-fused reconstruction path. The fused implementation
reconstructs in the column and reads the field in place in all builds. The flag requires
a case-optimized NVHPC OpenACC build with `MFC_FUSED_RHS` or `MFC_HLLC_REGISTER_TUNING`,
which select the restructured WENO module.

On a 316×158×158 WENO3 shock-droplet case (5-equation, RK3, HLLC, 200 steps, 1 GPU)
it is 1.07× faster than the original with its staging copy, with bit-identical output, on a
uniform grid and on a stretched grid.

The code is in `m_weno.fpp`, `m_thinc.fpp`, `m_muscl.fpp`.

## 8. MUSCL direct loads (`MFC_MUSCL_DIRECT_LOADS`)

The original MUSCL reconstruction copies the field into a staging array before it
reconstructs. The direct-load form reads the field in place (`s_muscl` in `m_muscl.fpp`).
With THINC compression, the pack runs for THINC. With `MFC_WENO_DIRECT_LOADS` also on, THINC
reads the field in place and the pack does not run. This improvement works on
every backend running non-fused kernels. Fused kernels do not need this load by construction.

| configuration | L2 read sectors | duration µs |
| --- | ---: | ---: |
| original| 1121 | 6.8 |
| direct loads, reconstruction in place | 706 | 3.2 |

The code is in `m_muscl.fpp`.

## 9. Direct Riemann flux (`MFC_DIRECT_RIEMANN_FLUX`)

The Riemann solver already computes the numerical flux. This flag uses that flux directly
for the flux differencing. The solver does not derive the flux again from the reconstructed
states (`s_compute_rhs` in `m_rhs.fpp`). This removes a full-domain pass per stage. The flag
applies to the non-fused path only. The
fused kernel in §1 computes the numerical flux and differences it in one pass. With this flag,
the grind goes from 0.361 to 0.328 (10% lower).

The code is in `m_rhs.fpp`, `m_riemann_state.fpp`.

## 10. Boundary conditions on the device

Two changes keep the boundary work per step off the host path.

**Persistent BC tables** (`MFC_PERSISTENT_BC`, `m_boundary_common.fpp`). The ghost-cell
population tables stay on the device. The solver fills them once at initialization. The
tables act together with `MFC_HALO_SINGLE_ROUND`. They cover 2D and 3D runs with the boundary
types that the persistent fill supports.

**Grouped ghost fill** (always enabled). The original population loop threads both boundary
indices in every dimension. In 2D and 3D the thread mapping of the outer index is poor. The
grouped form keeps the fast index threaded and groups the ghost depth per dimension
(`s_populate_bc_direction` in `m_boundary_common.fpp`). Each direction fills both of its
faces in one device loop. The fill is bit-identical to the original. The parallel scatter of
§2 handles the boundary output on the 3D CBC path.

| change | case | grind |
| --- | --- | ---: |
| grouped ghost fill, vs ungrouped | 200³ performance test | 1.22× faster |
| persistent tables, vs the same build without the tables | 100³ Dirichlet | 1.05× faster |
| persistent tables, vs the same build without the tables | 100³ boundary patch | 1.05× faster |
| persistent tables, vs the same build without the tables | 256² MHD | 1.12× faster |

The code is in `src/common/m_boundary_common.fpp`, `src/common/m_boundary_primitives.fpp`.

## 11. Source-term kernels

Several optimizations has been done to the source-term kernels below.

- **Euler-Euler bubble source** (`MFC_FUSED_BUBBLE_SOURCE`). Six launches per RK stage
  become one kernel that adds directly into the RHS. The flag removes the temporary
  full-domain arrays, the zeroing launch, and a device-to-host transfer. The
  original code does all of that every RK stage on every bubbles case.
- **QBMM moment inversion and sources** (`MFC_QBMM_DEVICE_INVERSION`). The moment inversion
  (92% of GPU kernel time on the 3D QBMM benchmark) becomes a case-specialized device
  kernel. The source side gets the term-loop unroll and the reciprocal hoist. Being a case-optimization feature, this flag
  needs a case-optimized build.
- **IBM patch application.** With `many_ib_patch_parallelism = T`, the original loop
  parallelizes over patches. With one patch, a single thread then does the work of the patch.
  This PR runs the cell loops of each patch as vector loops.
- **Lagrangian cell list** (`MFC_LAGRANGIAN_DEVICE_CELL_LIST`). The counting sort that maps
  each cell to its bubbles runs on the device instead of the host.
- **Information geometric regularization (IGR).**
  - `MFC_IGR_TUNED_SWEEPS` enables 4 minor optimizations together:
    - selects the restructured sweeps. Each sweep thread adds its flux
    terms in registers and writes them with two atomic updates per field. The original code
    uses one atomic update per term. The two forms differ in the summation order only, which produces floating-point class numerical differences.
    -In a 3D case-optimized build, the divided differences of the
    stencil are computed once per RHS into one array. The original code computes them
    approximately 18 times per stage. The same pass computes the strain invariant of the x
    sweep. The array adds memory for nine full-size fields per rank. On the IGR jet bench, 768×768×384, 4 ranks add 4.3GB per rank (384×384×384 per rank), 8 ranks add 2.2GB per rank (384×384×192 per rank).
    - In a 3D case-optimized build without bubbles, the mixture
    coefficients are inline.
    - In a case-optimized build, the RK update kernel works on raw
    array sections instead of derived-type descriptor chains.
    - Batched IGR Jacobi halo exchange: sends all processor faces in one
    nonblocking batch with a single wait. The boundary kernel packs the faces. This
    replaces the 54 exchanges per step of the original code. Works in both MPI and NVSHMEM transport.
  - `MFC_IGR_SHALLOW_HALO` exchanges one ghost layer on each Jacobi iteration except the last.
    The sweeps read the previous iterate at a distance of one cell. The last iteration fills
    all ghost layers.
  - `MFC_IGR_PINGPONG=1` (env variable) at run time alternates the two Jacobi buffers. It does not copy the
    full buffer each iteration. The default is off.

| family | item | speedup | accuracy |
| --- | --- | --- | --- |
| Euler-Euler bubbles | source kernel vs the six-launch original | approximately 1.3× kernel; 1.19× grind on a 300-cell 1D polytropic Keller-Miksis case | bit-identical |
| QBMM | moment inversion and sources | 14.3× kernel; 2.17× grind on the 1D QBMM case | <3e-16 |
| IBM | patch application | 2.9× | <2.6e-20 |
| IGR | divided-difference precompute | 1.25× | <2.9e-10 |
| IGR | inlined mixture coefficients | 1.19× | bit-identical |
| IGR | x-direction strain assembly | 1.09× | bit-identical |
| IGR | raw-array RK update | 1.06× | <1.15e-15 |
| IGR | batched Jacobi halo, 2 / 4 / 8 ranks | 1.06× / 1.26× / 1.50×; cost per exchange 161 µs to 81 µs | bit-identical |

The code is in `m_bubbles_EE_openacc.fpp`, `m_qbmm_openacc.fpp`, `m_ib_patches.fpp`, `m_igr.fpp`,
`m_bubbles_EL_kernels.fpp`, and the original files `m_bubbles_EE.fpp`, `m_qbmm.fpp` and
`m_boundary_common.fpp`.

## 12. Active compute window (improved on #1628)

The idea comes from
[#1628](https://github.com/MFlowCode/MFC/pull/1628) (block-structured AMR with
load-balance and active-box infrastructure). The weighted split arithmetic of the
SFC-weighted partition follows #1628. The rectangle clustering of the multibox cover follows
the AMR flag clustering of #1628. The SFC-weighted partition can rebalance the decomposition
to a supplied activity profile, so every rank keeps its own window. The cover is a set of
boxes, so the empty space between separate features stays out of the computation. The
optional inner cover follows the activity between updates.

The solver restricts the computation to the sub-box where the solution changes, and it
can rebalance the decomposition to match. Each rank keeps its own window over its
partition, so the window works at any rank count. The window applies only to the fused
kernel of §1; extending it to the non-fused paths is future work.

Enabling the feature needs a build with `--active-box` and `--fused-rhs`, and the
`MFC_ACTIVE_BOX` environment variable set at run time.
`MFC_ACTIVE_BOX=<steps>[,<growth>[,<boxes>]]` sets the update cadence, growth
margin, and the box count. A box count above 1 needs CUDA-graph to be enabled too, because
only that produces the scan partials the cover derivation reads. `<steps> = 0`
gives a fixed window and needs a fixed step count. `MFC_ACTIVE_BOX_FLOOR` sets the
deviation floor fraction. When `MFC_ACTIVE_BOX` is set and the build did not use
`--active-box`, the run stops with a message.

The windows can use an SFC-weighted partition of the domain. `MFC_SFC_WEIGHTS` names a file
of cost weights per block.

### The weights file (`MFC_SFC_WEIGHTS`)

The first line of the file holds the header. The file
below fits a case with 100 cells per direction, blocks of 50 cells, and equal weight
throughout.

```
100 100 100 50 1 1 1
1 1 1 1 1 1 1 1
```

| header field | meaning |
| --- | --- |
| `100 100 100` | global cell counts per direction |
| `50` | block edge length in cells |
| `1 1 1` | cut snapping stride per direction, `1` turns snapping off |

The global cell counts must match the case, or the run stops with a message. A stride above
`1` holds each cut on a multiple of the stride.

The file below gives the blocks of the high x half of the domain four times the weight of
the rest.

```
100 100 100 50 1 1 1
1 4 1 4 1 4 1 4
```

With two ranks in x, the cut of the equal file gives each rank 50 cells. The weighted cut
gives the low x rank 69 cells and the high x rank 31 cells. Each rank then holds close to
half the total weight. The heavy region gets fewer cells per rank.

The weights are computed from the output of preprocess, before the actual simulation.
`misc/gen_sfc_weights.py` reads `lustre_0.dat` from each directory it is given and sums a
per-cell cost model over each block. The model is `base * (1 + K_stencil * I_stencil + K_bub * void)`. `base` is one inside the active-window box grown by `G` cells and zero outside, so
a quiescent block gets no weight. `I_stencil` is one where a five-point alpha stencil is
nonconstant, which marks the cells the fused reconstruction cannot shortcut. `void` is the
local bubble void fraction on Lagrangian-bubble cases.

The case's `restart_data` directory contributes the initial condition, so a case whose
activity is known in advance needs no simulation step before generating the file. For a
moving front, add dumps from a shorter pilot run or from an earlier run of the same case as
repeated `--sample` directories, each holding its dump as `lustre_0.dat`. The costs average
over the samples with equal weight, because a partition cut fitted to one state becomes wrong
as the front advances.

| script argument | meaning |
| --- | --- |
| `block` | block edge in cells, matching the header |
| `K` | weight of a nonconstant alpha stencil, calibrated on the 201³ performance test by default |
| `--box G` | grows the active-box base indicator by `G` cells |
| `--grid G1,G2,G3` | cell counts of the dump |
| `--alpha-var N` | 1-based variable index of alpha(1) in the dump |
| `--sample DIR` | another dump to average over, stored as `DIR/lustre_0.dat`, repeatable |

A 200³ case has 201 cells per direction. A block of 67 cells gives three blocks per
direction and 27 weights.

Every rank runs the same sequence every `<steps>`.

1. **Scan.** Finds the cells that deviate from the ambient state. Under CUDA
   graphs it writes the partial boxes into a page-locked device-mapped buffer. The apply
   step then waits on an event, not on the whole queue.
2. **Band growth.** The window grows by its margin in one pass. When the window reaches a
   decomposition seam, the ranks across the seam add a band on their side. Their computation
   then runs when the front crosses.
3. **Multibox cover.** A single bounding rectangle holds the empty space between separate
   features. The cover derivation therefore clusters the activity of the scan. It starts
   from the activity hull. It splits the box that holds the most covered but inactive
   volume. Each axis proposes the deepest dip and the strongest edge of the activity
   signature, and the split whose halves drop the most volume wins. It stops when no split
   shrinks the cover, or at the configured box count. The union of the boxes contains the
   activity, and the solver checks this every cadence. Every box gets the margin and snap
   of the window, so the cover is always a subset of the single-box window. The cover stays
   on the device and replays under CUDA graphs with no new capture. The column loops of the
   fused kernel skip the columns that no box covers. With the default of one box, the cover
   is the window. A seam band makes the cover fall back to the single window.
4. **Apply.** The apply step runs half a cadence after the scan. It uses two
   allgathers per cadence, with the flags packed into the payload.
5. **Timestep.** The timestep reduction runs over the window. A masked complement pass
   adds the frozen region when the window moves, and once per cadence.

### Tight inner cover (`MFC_ACTIVE_BOX_INNER=<k>`)

This is an optional second layer for the single-box window. It builds the cover again on the
device every `k` steps, with a margin of the stencil plus the travel in `k` steps and no snap.
The inner cover keeps the boundary bands of the outer window. The cover then follows the
measured activity without the snap quantization of the outer window.

On a 400³ quad-droplet case,
it removes a further 12.7% of grind from the single-box window. The maximum absolute
difference of the solution against the single-box run is 1.3e-15.

### Cases that cannot use this feature

Three types of cases cannot run with this feature, because their physics changes cells that
the deviation test sees as ambient.

- Reactive-burn chemistry. Induction zones stay below the deviation threshold while their
  reaction timers run, and a programmed detonation front moves faster than the margin
  between cadences.
- Ghost-cell Riemann boundary conditions (GRCBC). The boundary reconstruction reads cells
  that the window can freeze.
- Cylindrical coordinates. Their geometric sources change a uniform flowing state. The
  window turns itself off for the first two; a cylindrical case must not set
  `MFC_ACTIVE_BOX` env variable.

### Improvements to the original implementation (#1628)

This PR changes the original implementation in these ways.

- **Multi-rank.** #1628 restricts the reconstruction, Riemann, and RK windows to one box
  around flow that is not ambient, on a single rank. The implementation in this PR works at
  any rank count.
- **Conservative margin.** The margin is the stencil plus the largest travel of a front until
  the next update. The travel bound per step is a fixed value in a stable explicit run, and
  follows the CFL target under `cfl_dt`. Without an explicit growth the margin adapts to the
  measured travel, so a slow front is not padded to the travel bound all run. The measured
  travel is a running maximum, so an accelerating front widens the margin and a slowing front
  does not narrow it. An explicit growth in `MFC_ACTIVE_BOX` fixes the margin in place of the
  default.
- **Fixed window.** A fixed window (`<steps> = 0`) grows by the travel over the whole run.
  Under `cfl_dt` the run ends at the stop time, not at the step count, so the fixed window's
  growth can under-cover the run.
- **Bound hysteresis.** Bounds grow at once and tighten when the target repeats on two
  updates in a row. The rule applies to the lower bounds and the upper bounds in the same way.
- **Seam bands in every cover.** A band is planted from the sender's raw box at a single
  growth margin, instead of growing the sender's already-grown window a second time. The
  multibox cover falls back to the single window when a seam band is present. The inner cover
  does not rebuild after the window settles.
- **Periodic seam.** A periodic axis split across ranks is a seam through the wrap. When the
  window reaches one periodic face, a band opens at the opposite face, on the rank that holds
  it.
- **Boundary faces.** A face with a characteristic boundary condition keeps a permanent
  full-width band, because the CBC machinery consumes the face fluxes those columns publish. The two
  extrapolation types keep no band, so a case with extrapolation boundaries on every face
  keeps the full speedup. A wall needs no band, because the flow that reaches it deviates and
  the scan covers it.
- **Inner cover reductions.** The inner cover rebuild is a chain of three regions on the compute queue. A row scan reads the solution once and writes per-row partials. A per-slice reduction and a final reduction follow, each reading only the partials the region before it wrote.
- **Snap.** Window bounds snap outward to a multiple of the lane stride, so a partial lane
  block occurs only at a subdomain edge, where a per-cell guard excludes the extra cells.

### Results

The next table shows how the window adds to the rest of this PR, on the 4-GPU 200³ 3D
performance test.

| configuration | grind (ns/gp/eq/rhs) |
| --- | ---: |
| with all optimizations | 0.0183 |
| with all optimizations + active window | 0.0184 |

The window does not reduce the grind on this test. Its characteristic boundary faces each keep
a full-width band, and the three bands together span the whole subdomain, so the window is the
whole domain. At 8 GPUs the two are also level, 0.0127 against 0.0127.

The next table uses a custom 400³ quad-droplet case (four spheres advected in ambient, 300
steps), with the droplets in the corners of the transverse plane. This case uses extrapolation faces, which keep no band.

On 1 GPU:
| configuration | grind (ns/gp/eq/rhs) |
| --- | ---: |
| without the window | 4.25e-2 |
| single-box window (cadence 20) | 2.70e-2 (1.57×) |
| 4-box cover | 1.91e-2 (2.23×) |

The cover adds a further 1.41× over the single box, because the empty space between the
droplets belongs to no box.

On 4 GPUs (1600×400×400):
| configuration | relative speedup from without window |
| --- | ---: |
| single-box window (cadence 20) | 1.62x |
| 4-box cover | 2.19x |

On the 200³ performance test the SFC-weighted cuts are 1.8× to 2.1× slower than the
Cartesian cut, with the window on and the same rank count. The SFC weights intentionally skew the cut into uneven allocation across ranks, so they are beneficial only when ranks carry different active fractions, else it will worsen work imbalance per rank. Thus this feature must be used selectively.

The code is in `m_active_box.fpp` (the scan, band growth, cover derivation, update cadence,
and the inner cover), with the window bounds of each kernel in `m_fused_rhs_openacc.fpp` and
`m_cbc.fpp`, the graph recapture on window changes in `m_weno.fpp`, the windowed timestep in
`m_time_steppers.fpp`, the setup and first measurement in `m_start_up.fpp`, and the
SFC-weighted partition in `m_mpi_common.fpp`.


## 13. Phase-change relaxation early stopping

### The bottleneck

The pTg relaxation (`relax_model = 6`) solves Gibbs equality and energy conservation
for the liquid mass and pressure of each cell with a damped Newton iteration. The
iteration halves the step up to 30 times until the residual falls. When the equilibrium of
a cell is single phase (all liquid boils or all vapor condenses), no two-phase
root exists. See https://github.com/MFlowCode/MFC/pull/2052 for a related bug I fixed. The residual stays between 1e2
and 1.5e5 against a tolerance of 1e-2. Every one of the 30 halvings fails on every
iteration. The original code then runs the full `max_iter = 100000` iterations, which is
approximately 3 million residual evaluations per cell per step. On the GPU, a single such
cell holds its whole thread block for the entire solve.

Analyzing the runs of the phase-change suite cases in the original code shows 2 endings that such cases will converge to:
1. Solves that converge finish in 1 to 9 iterations and never meet a failed line search.
2. Solve reaches the iteration cap with the liquid
mass exactly at its bound.

A lower pTg activation threshold `mixM` gives the solver many cells of this second
ending. A cell that holds a trace vapor seed has no two-phase solution. Its mass stays at the
bound and its line search fails on every iteration. For this reason the run in
[#1927](https://github.com/MFlowCode/MFC/issues/1927) hangs in `pre_process` after it sets
`mixM` to 1e-14. This change removes that hang.

### What this change does

The iteration exits when all 30 halves failed to reduce resnorm `resnorm_try < resnorm`. With the analytic Jacobian, the Newton step
is a descent direction of the residual norm. A line search that fails all 30 halvings
therefore means one of two things. The bound blocked the step, or the residual is at
round-off. Further iterations do not converge in either case. Therefore the early stop is safe.

#1653 introduced the 100k iteration but it was for the old solver. #1654 then rewrote the solver from fixed Om = 1e-3 to the damped Newton + backtracking line search, but that PR left the max_iter unchanged. The new solver, as described above, either converges in <9 steps or never.

### Results

| case | without the exit | with the exit |
| --- | ---: | ---: |
| `examples/2D_phasechange_bubble` on 1 H200 | 3.97 s | 0.146 s (27× faster) |
| `02BD9B5E` on CPU | 228 s | 14 s (16× faster)|

The grind time is the same with and without the exit (0.386 ns/gp/eq/rhs on the
example). The relaxation runs once per step after the Runge-Kutta update, outside the
grind bracket. The wall time per step shows the stall.

The outputs are unchanged. All 18 phase-change suite cases pass against goldens that
come from the full iteration budget.

The code is in `src/common/m_phase_change.fpp` (`s_infinite_ptg_relaxation_k`).

## 14. Optimizations that defaults to enable

These changes have no build option. Each one keeps the results of the original code
bit for bit, or within roundoff where stated.

- **Grouped ghost fill** (`m_boundary_common.fpp`). Each direction fills both of its faces in
  one device loop, with the fast index threaded and the ghost depth grouped (§10).
  Bit-identical.
- **Capillary fill in one kernel** (`m_boundary_common.fpp`). The capillary boundary fill
  writes both faces of a direction in one kernel. The faces write separate ghost cells and read
  interior cells. Bit-identical.
- **Batched IGR face exchange** (`m_boundary_common.fpp`, `m_mpi_common.fpp`). The boundary
  kernel packs the IGR faces, and all processor faces go out in one nonblocking batch (§11).
  Bit-identical for every cell that the IGR kernels read.
- **Flat halo pack and unpack** (`m_mpi_common.fpp`). Each pack and unpack loop is one flat
  parallel loop with an index decode. The buffer layout is the same. Bit-identical.
- **EOS pruning in case-optimized builds** (`m_eos.fpp`). The state-dependence tests read
  `any_state_dependent_eos .and. f_is_state_dependent(i)`. In a case-optimized build with
  constant coefficients, the compiler removes the reference-curve and RK4 code from the HLLC
  and IGR kernels. Bit-identical.
- **Four more case optimization parameters** (`toolchain/mfc/params/definitions.py`). A
  case-optimized build makes `model_eqns`, `bubbles_euler`, `qbmm` and `hypoelasticity`
  compile-time constants. The compiler folds the branches on these values. Bit-identical.
- **Lagrangian host staging** (`m_bubbles_EL.fpp`, `m_mpi_proxy.fpp`). The particle state goes
  to the host on the steps where a bubble changes rank, leaves the domain or wraps. The
  decision uses the positions and the local count, which go to the host first. Bit-identical.
- **Lagrangian pressure correction** (`s_compute_pinf_correction` in `m_bubbles_EL.fpp`). The
  kernel takes its state as arguments. The source and void-fraction kernels take their bounds
  and constants as launch scalars. Bit-identical.
- **Euler-Euler source kernels** (`m_bubbles_EE.fpp`). Outside AMD builds, the source kernel has
  one version with `adap_dt` and one without. Each version removes the other branch at compile time.
  Bit-identical.
- **QBMM RHS** (`s_compute_qbmm_rhs` in `m_qbmm.fpp`). The four quadrature nodes of a cell share
  one load of the moments, one square root and one spacing. The kernel writes each node once.
  The expressions and their order are the same, so the result is bit-identical up to FMA
  contraction.
- **Chemistry diffusion staging** (`s_compute_chemistry_diffusion_flux` in `m_chemistry.fpp`).
  Five per-thread arrays of `num_species` entries become scalars. Bit-identical.
- **Viscous gradients** (`s_get_viscous` in `m_viscous.fpp`). Pairs of one-sided gradient
  kernels for x and y merge into one kernel each. The cell-centered gradient for the cylindrical boundary
  stress runs when `cyl_coord = T`. The loops take their bounds from host scalars, so the
  call does not update device bounds. Bit-identical.
- **Collision temporaries** (`m_collisions.fpp`). The torque call uses the private
  `radial_vector`, so the GPU loop has no array temporary. Bit-identical.
- **Flux difference loops** (`s_compute_advection_source_term` in `m_rhs.fpp`). Each loop runs
  over cells with an inner sequential loop over equations. It computes the inverse spacing
  once per cell. Bit-identical.
- **Host bounds in `m_rhs`**. The kernels take `iv`, `is1`, `is2` and `is3` as launch
  scalars, so the calls do not update device copies. Bit-identical.
- **IGR RHS zeroing** (`m_rhs.fpp`). In 2D the zeroing skips the two z planes that no kernel
  reads. Bit-identical.
- **No divergence kernel under QBMM** (`m_rhs.fpp`). The `divu` kernels run when the
  Euler-Euler source reads them, which is without QBMM. Bit-identical.
- **NaN check on the device** (`s_save_data` in `m_start_up.fpp`). A device reduction flags a
  NaN. The host scan runs after a flag, and it reports the same cell. The output is the
  same.
- **HLL equation indices** (`m_riemann_solver_hll.fpp`). The x and y HLL kernels take the
  continuity-end and energy indices as kernel arguments. Bit-identical.
- **HLLC bubble states** (`m_riemann_solver_hllc.fpp`). One loop over the bubble bins fills
  scalar accumulators. It replaces four loops over eight per-thread arrays. Bit-identical.
- **HLLC identical bubble states** (`m_riemann_solver_hllc.fpp`, case-optimized
  `bubbles_euler` builds without QBMM). When the left and right states of a face are equal bit
  for bit, the kernel writes the analytic flux of that state. The case must use
  `model_eqns = 2`, direct wave speeds, the arithmetic average, `low_Mach = 0`, Cartesian
  geometry, and none of `alt_soundspeed`, viscosity, surface tension, hypoelasticity,
  chemistry, Lagrangian bubbles, relativity or MHD. HLLC of two equal states reduces to the
  analytic flux. The full solver computes the contact speed with rounding, so the results differ
  by roundoff.
- **CBC wave amplitudes** (`m_cbc.fpp`). Outside AMD builds, the CBC kernel keeps the wave
  amplitudes in one module array with one column per boundary point. The kernel then has no
  private array of run-time size, so no launch allocates device memory. Bit-identical.
- **MUSCL bounds** (`s_muscl` in `m_muscl.fpp`). The kernels take their bounds and the variable
  count as launch scalars, and the stencil loads once. Two host-to-device updates per call go
  away. Bit-identical.
- **THINC bounds** (`s_thinc_compression` in `m_thinc.fpp`). The kernel copies its bounds into
  integer scalars. Bit-identical.
- **WENO uniform stencil** (`m_weno.fpp`, case-optimized builds, WENO5 and WENO7, not TENO).
  When every value of the stencil equals the center value, the reconstruction writes that value
  and skips the weights for that variable. The original code returns the weighted sum of equal
  values, which equals the center value within a few ulps. The results differ by roundoff.

## 15. Fixes to existing code

### Physics fixes with their own pull requests

Each fix below has its own pull request with the issue, a reproducer, and a comparison before
and after the fix.

- **3D cylindrical azimuthal terms** (#2051, for #1817; `m_rhs.fpp`,
  `m_riemann_solver_hll.fpp`, `m_riemann_solver_lf.fpp`). Affected runs use `cyl_coord = T` with
  `p > 0`. The original code multiplies the azimuthal flux difference by the azimuthal
  velocity. It divides the azimuthal volume fraction sources by Δθ. HLL and LF apply the
  geometric source of the radial sweep in the azimuthal sweep. This PR divides the azimuthal
  flux difference and sources by rΔθ with no velocity factor. HLL and LF write the centrifugal
  and Coriolis momentum sources of the azimuthal sweep.
- **HLLD intermediate states** (#2053; `m_riemann_solver_hlld.fpp`). Affected runs use MHD with
  `riemann_solver = 4`. The original code evaluates the fast speed with a tangential field
  component, divides the star total pressure by (s_L − s_M), keeps the outer tangential states
  in the star states, and averages the two double-star energies. This PR follows Miyoshi and
  Kusano (2005) in each of these places, and uses one normal field in 2D and 3D.
- **MUSCL SUPERBEE slope sign** (#2049, for #1819; `m_muscl.fpp`). Affected runs use `muscl_lim = 5`.
  The original slope is always positive. This PR gives the slope the sign of the one-sided
  differences, as for minmod and MC.
- **LF volume fraction transport** (#2050, for #1818; `m_riemann_solver_lf.fpp`). Affected runs use `riemann_solver = 5` with more than one fluid. The original code fills the volume fraction
  outputs with the quantities of HLL method 1. This PR writes the LF flux of αu and the LF
  interface velocity, as the right-hand side expects.
- **HLL viscous work** (#2054; `m_riemann_solver_hll.fpp`). Affected runs use `riemann_solver = 1` with
  `viscous = T`. The original HLL solver never writes the face velocity that the viscous work
  term reads. This PR writes the HLL interface velocity to it.
- **Six-equation primitive energies** (#2055; `m_variables_conversion.fpp`). Affected runs use `model_eqns = 3`. The original conversion leaves the phasic internal energies of the
  primitive variables unset, and the primitive output writes them. This PR copies them from
  the conservative variables.
- **Phase depletion** (#2052, for #1820; `m_phase_change.fpp`). Affected runs use `relax_model = 6`
  where the pTg solve uses up a phase. The original code keeps the pressure and temperature of
  a Gibbs equality that cannot hold. This PR solves the pT equilibrium again for the final
  masses.

### Other fixes

Most of the fixes below has no golden covering the case, and I chose to not add any because I am not sure if they are within scope of MFC. I am open to dropping any of these fixes below (except for #2048 which I have added a golden for).

- **Cylindrical viscous GPU bounds** (`m_riemann_state.fpp`). Issue #2048. Affected runs use a GPU build with
  `cyl_coord = T`, `p > 0` and `viscous = T`. The original face loop reads bounds that the device never
  receives, so it computes a single face. This PR loops over the module bounds that the solver
  updates on the device. The GPU result then matches the CPU build.
- **Lagrangian smearing cell** (`s_get_cell` in `m_bubbles_EL_kernels.fpp`). Affected runs use Lagrangian bubbles with a bubble outside the domain during the smearing. The original code
  reads the grid spacing out of bounds. This PR clamps the cell to the interior grid, like the
  cell list does. The result is bit-identical for every bubble inside the domain, thus no existing golden file changes.
- **1D surface tension** (`m_surface_tension.fpp`). Affected runs use `surface_tension = T` with
  `n = 0`. In 1D the original code reads the normal magnitude as the second gradient
  component, so the capillary tensor is −σ|n| instead of 0. It also writes `Omega(2,*)` and
  reads `c_divs(2)` out of bounds. This PR sets the second component to 0 in 1D and skips the
  accesses for `n = 0`. The deallocation of `c_divs` covers all of its entries. There is currently no golden covering this case.
- **Euler-Euler bubble moments with `adv_n`** (`m_bubbles_EE.fpp`). Affected runs use `bubbles_euler = T`, `adv_n = T` and `adap_dt = F`. The original kernel loads the bubble
  radius and velocity in the branch without `adv_n`, and then uses them for the R²V moment. This PR
  loads them first, on every backend. The existing goldens are unchanged from this.
- **One-sided z gradient** (`s_compute_fd_gradient` in `m_viscous.fpp`). Affected runs use `cyl_coord = T`, `p > 0`, `viscous = T` and `weno_Re_flux = F`. The original code divides the
  one-sided z difference at the first ghost plane by one cell spacing instead of two. This PR
  uses `z_cc(idwbuff(3)%beg)`, like the x and y forms. The cylindrical boundary stress reads that
  plane. The existing golden `07C33719` is unchanged from this.
- **CBC chemistry wave amplitudes** (`m_compute_cbc.fpp`, `m_cbc.fpp`). Affected runs use `chemistry = T` with a characteristic boundary of type −5 (slip wall), −9 (force-free
  subsonic outflow) or −10 (constant-pressure subsonic outflow). The original routines never
  write the species entries of the wave amplitudes, and the species time derivative at the
  boundary reads them. This PR sets them to 0 at the slip wall. The two outflows fill them as
  the convected wave, like the other subsonic outflows. There is currently no golden covering this case.
- **Boundary file corners** (`m_boundary_io.fpp`). Affected runs use `bc_io` with Dirichlet
  boundaries. The original code allocates the transverse ghost range of the boundary buffers
  and leaves it unset, so the corner ghost cells of the simulation read undefined data. This
  PR fills that range with the values of the edge cells. There is currently no golden covering this case.
- **Lagrangian bubble output** (`s_stage_and_write_lag_bubble_evol` in `m_bubbles_EL.fpp`).
  Affected runs use Lagrangian bubbles with bubble output. The original code writes the positions and
  the gas mass without a copy from the device on some time stepper paths. This PR copies them
  before each write. The existing goldens do not check for outputs affected by this bug.
- **Lagrangian periodic wrap** (`m_mpi_proxy.fpp`). Affected runs use Lagrangian bubbles with periodic
  boundaries on more than one rank. The original code sets `periodic_bc` on rank 0 and leaves it unset on the other ranks. This
  PR broadcasts it. There is currently no golden covering this case.
- **GLM damping input** (`m_time_steppers.fpp`). Affected runs use `hyper_cleaning = T` with a
  fixed time step. The damping source reads the primitive variables before any conversion fills
  them. This PR sets them to 0 at allocation. The existing goldens are unaffected because they were read as 0 in practice.
- **2D chemistry probes** (`m_data_output.fpp`). Affected runs use chemistry with probe output in 2D.
  The original code reads the species densities before it computes the probe cell. This PR
  reads them after. The existing goldens do not check for outputs affected by this bug.
- **Mixed precision builds** (`m_ibm.fpp`, `m_igr.fpp`, `m_viscous.fpp`, `m_acoustic_src.fpp`,
  `m_bubbles_EE.fpp`). The defect affects `--mixed` builds. The original simulation source does not compile at
  these sites, because the actual and dummy kinds differ. This PR converts the IB markers with
  `int`, stores the IGR Jacobi arrays in the storage precision, and converts the viscous shear
  rate, acoustic source and bubble divergence arguments to the working precision.
  Double and single builds stay bit-identical to before this change. No golden is affected because this is a compile-time bug.
- **MPI I/O field memory** (`m_global_parameters.fpp` of `pre_process` and `post_process`).
  The defect affects every MPI run of these binaries. The original code allocates one field array per
  MPI I/O variable and then points the field at `null()`. This PR removes the allocation. The
  output is the same so no golden change.
- **Teardown** (`m_cbc.fpp`, `m_fftw.fpp`). The CBC teardown frees `pi_coef_y` and `pi_coef_z`
  under the same condition as their allocation, which includes MUSCL. The FFT teardown frees
  `gpu_fft_size`, `iembed` and `oembed`. No golden change.

## Compiler workarounds

- **Stability-extrema reduction on NVHPC OpenMP offload** (`m_data_output.fpp`). On two-rank
  runs the `s_write_run_time_information` reduction clause stops the region with
  `CUDA_ERROR_LAUNCH_FAILED` at the copy out of the region. On NVHPC OpenMP-offload builds the
  six extrema live in a module `declare target` array. The code seeds the array on the device
  before the loop, updates it with atomics inside the loop, and reads it back after. A plain
  read of the slot guards each atomic. Under max and min that read is monotone, so the guard
  skips the cells that cannot change the result. The code issues one atomic per new extremum. This is a miscompile by NVHPC 26.9 (and possibly older versions).
- **Shear component table** (`is_shear_comp` in `m_global_parameters_common.fpp`). The
  hypoelastic energy reads a logical table of the shear components. The original code tests
  `any(i == shear_indices)`, which NVHPC 26.9 miscompiles in the energy assembly. The values
  are the same on other compilers. I have filed the bug report with NVIDIA and they have confirmed a fix will be available in the next NVHPC SDK release (after 26.9)
- **Fixed extent in `m_riemann_solver_hypo_hlld.fpp`.** The private stress arrays have the
  fixed extent 6, as in the HLLC solver. An automatic extent from the declare-target eqn_idx makes nvfortran size the gang-private copy from a device-side bound read, which faults at region entry. Current CI does not catch this because the test suite's hypoelastic path is HLL only, and the offending subroutine never gets ran in the CI with GPU.

### Adaptive NVTX library link

The Fortran NVTX wrappers have different library names in different NVHPC
versions. NVHPC 26.9 provides `libnvhpcnvtx`. Earlier versions provide
`libnvhpcwrapnvtx`. Upstream links one fixed name, `nvhpcwrapnvtx`, so GPU builds fail
to link on NVHPC 26.9.

This PR selects the library that exists. The build derives the library directory of the
compiler from `CMAKE_Fortran_COMPILER`. It links `nvhpcnvtx` when that library is
present, and `nvhpcwrapnvtx` otherwise. Real builds with both toolchains confirm the
selection. NVHPC 26.9 links `nvhpcnvtx`, and NVHPC 26.5 links `nvhpcwrapnvtx`.

The code is in `cmake/MFCTargets.cmake`.


## Acknowledgement

This PR is prepared by Billy Cao from Nanyang Technological University SCC team: Supernova for SC26 Student Cluster Competition. It unintentionally overlapped with ideas that existing PRs from other teams have raised, and I have fully acknowledged them in these cases. It also took inspiration from existing PRs by the MFC team, which I have also fully credited where due. For each of such cases, I have explained the differences/improvements on top of existing PRs.