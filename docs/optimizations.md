# MFC on H200: optimizations so far

Case: `examples/3D_performance_test` (201³, 5-equation 2-fluid, WENO5 + HLLC, RK3, 30 steps), case-optimized build,
NVHPC 26.3, 1× H200 unless noted. Code: branch `p4` on nano4 (`mfc-p4` = `p3` + P4), exported as `patches/opt/0001…0006`.
Every number below cites a job; details and rejected variants are in `docs/ladder.md`.

## Final (the report's headline; `report.md` §1)
v5.7.0 vs P3 on one node, P3 vs P4 (final) on another; speedup = product of the two same-node ratios.

| GPUs | v5.7.0 step | P3 step | Final step | Speedup | Jobs |
|---|---|---|---|---|---|
| 1 | 76.74 ms | 61.88 ms | 60.38 ms | 1.27× | 606017; 621788 |
| 4, all `rdma_mpi` | 23.10 ms | 17.72 ms | 17.03 ms | 1.35× | 606018; 622305 |
| 8, v5.7.0 default, then `rdma_mpi` | 21.94 ms | 10.22 ms | 9.75 ms | 2.23× | 605963/606019; 622306 |

## Result (1 GPU, rung by rung)
| Rung | Step, median | Grind (ns/gp/eq/rhs) | Wall | Final state | Job |
|---|---|---|---|---|---|
| v5.7.0 baseline | 77.06 ms | 0.3982 | 8.07 s | reference | 600407 |
| + P1 CBC async | 75.98 ms | 0.3935 | ~8.0 s | bitwise | 601152 |
| + K4b Riemann unity build | 70.42 ms | 0.3632 | 7.33 s | bitwise | 602474 |
| + K2 WENO register cap 128 | **62.99 ms** | **0.3255** | 6.9 s | bitwise | 602559 |
| = clean series `sc26` (canonical) | 62.91 ms | 0.3248 | 7.13 s | bitwise | 602728 |
| + T0.4 UCX on the GPU's own HCA (env, 1 GPU) | 63.00 ms | 0.3249 | **6.62 s** | bitwise | 602727 |
| + P3 async per-stage kernels (same-node A/B vs sc26: 62.87 → 61.79 ms) | 61.79 ms | 0.3200 | — | bitwise | 604561 |
| + P4 transverse-interior reconstruction (same-node A/B vs P3: 61.90 → 60.38 ms) | **60.38 ms** | **0.3123** | — | bitwise | 621788 |
| **total (rungs in sequence, different nodes)** | **−21.6 % (1.28×)** | **−21.6 %** | | | |

## After the deadline (2026-11-01): P7–P14, `patches/opt/0007…0017`
Each row is a same-node A/B against the row above (alternating arms in one allocation, power-braked nodes refused,
AGENT_LOG #16). Every arm is bitwise identical to v5.7.0.

| Rung | 1 GPU step | 4 GPUs step (`rdma_mpi`) | Jobs |
|---|---|---|---|
| P4 (above) | 60.95 ms | 17.03 ms | 664597; 664614 |
| + P7: 0007 spatial-only collapse in copy kernels, 0008 WENO direct read, 0009 Riemann buffers aliased | 45.10 ms (−26.0 %) | 13.02 ms (−23.5 %) | 664597; 664614 |
| + P8: 0010 α·div(u) added in the flux-difference kernels | −0.4 % | — | 664763 |
| + P9: 0011 RK stage state aliased to the RHS working copy | −2.6 % | — | 664763 |
| + P10: 0012 register cap 128 on the Riemann unity file | **42.23 ms** (−5.4 % vs P7) | **12.45 ms** (−4.4 % vs P7) | 664848; 664859 |
| + P11: 0013 no CBC host waits on NVHPC OpenACC (0014: formatter only) | 42.04 ms (−0.3 % vs P10) | 12.26 ms (−1.5 % vs P10) | 664894; 664895 |
| + P12: 0015 HLLC reconstructs its WENO5 states in-kernel | **37.71 ms** (−10.5 % vs P11) | **10.94 ms** (−10.6 % vs P11) | 668372 (667981: −10.2 %); 668436 |
| + P13: 0016 all directions' flux differences into `rhs` in one pass (per-direction flux slabs) | **36.83 ms** (−2.4 % vs P12) | — | 669254 |
| + P14: 0017 flux differences fused into the TVD-RK stage update (`rhs` neither written nor read) | **36.24 ms** (−1.9 % vs P13) | — | 669327 |
| **v5.7.0 → P14, chained same-node ratios** | **2.13×** | (P12: 2.10×) | |
| **v5.7.0 → P16, direct same-node A/B** (2 rounds × 5 reps, hgpn065) | **77.06 → 36.23 ms: 2.13×**; grind 0.3968–0.3985 → 0.1872–0.1877 ns (2.12×); wall median 7.31 → 5.65 s (1.29×) | — | 669752 |

8 GPUs (`rdma_mpi`, 667577, hgpn029): P4 → P11 grind 0.0502 → 0.0376 ns (−25.2 %), bitwise; the P11 arm got 2 of 3
reps (time limit, AGENT_LOG). P12 at 8 GPUs is not measured.

**P7 (0007–0009).**
- *Evidence.* After P4 the copy-like kernels were 40 % of kernel time at 1–1.8 TB/s, SM-instruction-bound: each
  collapsed (variable, z, y, x) iteration recovered four indices with 64-bit div/mod and walked a derived-type
  descriptor.
- *0007.* `collapse(3)` over space and a `seq` variable loop inside: upstream #2087 (NTHU, merged 10-24) on the q_cons
  copy, flux differences, finalize and WENO pack, extended here to the RK update, the dual-pass/cylindrical differences,
  the WENO1 copies and the u-interface source. `tools/var_inner.py` did the reorder mechanically.
- *0008.* Upstream #2092 (NTHU, merged 10-25): WENO reads `v_vf` directly; the pack runs only for MP-WENO/THINC.
  Reverting it on P10 costs +8.5 % (664848), so the extra descriptor arithmetic is cheaper than the copy.
- *0009.* On the inviscid path the RHS fluxes are the Riemann solver's own (x, y, z)-ordered buffers, allocated in
  m_rhs with remapped bounds before anything is attached, so finalize copies nothing. `harness/src/remap_attach.f90`
  checked first that NVHPC carries remapped bounds to the device (664560).

**P8–P10 (0010–0012).**
- *0010.* With the u-interface source and no K·div(u), cylindrical, 6-equation or dual-pass terms, the α·div(u) term is
  added by the flux-difference kernel right after it writes `rhs`. Small (−0.4 %): the three removed kernels were cheap
  after 0007.
- *0011.* `q_cons_ts(1)` points at `q_cons_qp` on the same plain path (no probes, run-time info, damage), so the
  per-stage copy of the state goes; the conversion writes cont/adv back unchanged and the halo fill writes the ghosts.
- *0012.* The inlined HLLC kernels used 146–152 registers (3 blocks/SM); a per-file cap of 128 gives 4 with 0 B of
  spills. 96 is worse (−0.6 % vs −2.4 %). Compiler flag (disclosed); m_hb_function and m_bubbles_EL_kernels get the same
  cap because nvlink rejects a capped kernel calling a cross-file routine with more registers.

**P11–P12 (0013–0015).**
- *0013.* On NVHPC OpenACC the async queue is the synchronous stream (P3), so the three host waits in `s_cbc` order
  nothing; `GPU_ASYNC_WAIT` drops them there and keeps them on every other compiler. MPI-buffer waits stay.
- *0015, evidence.* WENO wrote 2 × sys_size states per cell to `qL/qR_rs*_vf` and HLLC read them back: 5.57 + 4.26 ms
  per stage at P7, both latency-bound at 128 registers.
- *0015, change.* On the 5-equation pure-fluid HLLC path each thread reconstructs its face's two WENO5 states itself
  (cell j's right boundary, cell j+1's left boundary) from `q_prim`; the buffers are neither written nor read. The WENO5
  point formula moved to `src/simulation/include/weno5_macros.fpp`, which both `s_weno` and the HLLC kernel expand, so
  the states are bitwise those `s_weno` stores. HLLC's shared body reads its states through `QL()/QR()` accessors, so
  the fused kernel is a third emission, not a copy. Selected at init only where nothing else reads or edits the buffers
  (no viscous/capillary/MP-WENO/THINC/`weno_Re_flux`/Riemann-extrapolation BC; see `recon_riemann_fused`).
- *0015, cost.* One extra smoothness-indicator evaluation per face; the weights, the expensive part, are computed once
  per side as before. 128 registers, 288 B stack (HLLC 88 + WENO 152–192 before).
- *0015, effect.* 1 GPU −10.5 % (668372, hgpn014) and −10.2 % (667981, hgpn005); 4 GPUs −10.6 % (668436). Bitwise in
  every arm.
- *Rejected: W3,* WENO5 kernel with `collapse(4)` over (variable, z, y, x): +15.7 % (667981), bitwise.
- *Rejected: register cap 168 / 255* on the Riemann unity file with the fused kernel: +7.1 % / +6.7 % vs 128 (669327).
  128 is still best.

**P13–P14 (0016–0017).**
- *0016.* On the fused path each sweep direction writes its own flux slab, so the three flux-difference kernels, each a
  read-modify-write of all of `rhs`, become one pass after the last sweep. Per cell and equation it adds the same terms
  in the same order (x flux, x α·div(u), y …, z …). CBC still edits each direction's fluxes right after its sweep. Costs
  about 1.3 GB of flux buffers at 201³ per GPU. −2.4 % (669254).
- *0017.* When nothing between the RHS and the stage update reads or adds to `rhs` (no body forces, IB, bubbles,
  damage, adaptive dt, …), that pass is the TVD-RK update itself: `q1 = (c1·q1 + c2·qs + c3·dt·r)/c4` with r formed
  as above, so `rhs` is neither written nor read. The first-stage return on the last step still comes before any
  update. −1.9 % (669327).
- *Rejected: two rewrites of the fused RK update kernel* (ncu 669515: DRAM at 25 %, occupancy 37 %, 76 registers,
  latency-bound). One thread per (equation, cell) with `collapse(4)`: +3.6 % (669544). All loads of a cell into
  private arrays first, then the stores, so no load waits behind a store the compiler cannot prove does not alias it:
  +7.5 % (669580); the private arrays sit in local memory (SASS: 84 registers, 192 B stack, 23 LDL / 7 STL). Both were bitwise identical.
- *Why the fused RK update is slow (SASS of P16).* It needs ~12 values per equation and cell but issues ~66 global loads:
  every `x(j)%sf(q,k,l)` walks module structure → `vf(j)` → `sf` descriptor (base, offset, strides) before the data
  load, and the stores to `q1` keep the compiler from reusing any of it. Taking 4 cells along y per thread does not
  help on its own (the descriptors are still reloaded per cell: 112 loads per iteration, unchanged). With per-equation
  local `contiguous` pointers the loop drops to 26 loads per cell, but the kernel then holds 202 registers (occupancy
  37.5 → 12.5 %) and the step is 15 % slower (rkb2, 669708, bitwise).
  Capping `m_rhs` at 80 registers instead spills 624 B of stack (build only, not run). With this data layout
  (one pointer per field) we leave the kernel as it is.
- *Rejected: register caps 96 / 80* on the Riemann unity file with the fused kernel: +0.8 % / +6.8 % (669708). 128
  stays (168 and 255 were also worse, 669327).

**Where the time is now (P12 profile, 1 GPU, 668466; 12.3 ms of kernels per stage).** Fused WENO5+HLLC 8.07 ms
(65 %), flux differences + α·div(u) 2.0 ms, RK update 0.90 ms, cons→prim 0.64 ms, BCs + CBC ~0.65 ms. ncu (668497):
the fused kernel runs the FP64 pipe at 42 % of peak with DRAM at 12–21 %, so it is now instruction-bound, not
memory-bound. Normalising the WENO weights by one reciprocal of their sum instead of three divisions (exp-rcp, 669254)
came out bitwise identical and no faster (37.68 vs 37.72 ms). The compiler already does this, so the division cost is
lower than a count of `/` in the source suggests.

**Before P12 (P7 profile, 1 GPU, 664617; 14.8 ms of kernels per stage).** WENO5 5.57 ms (38 %), HLLC
4.26 ms (29 %), flux differences + α·div(u) 2.03 ms, RK update 0.89 ms, cons→prim 0.63 ms, q_cons copy 0.40 ms (removed
by 0011). WENO and HLLC are FP64/latency-bound (no `pow` calls; divides are already `rcp`-based under `-fast`).

The official MFC table lists 0.38 ns for H100 SXM. That number uses a different metric (v4.9.3, `s_compute_rhs` only,
`cpu_time`, ghost cells counted), see `baseline/README.md`. Same-metric comparisons are within this table only.

## What and why

**P1: CBC without host round trips** (`m_cbc.fpp`, 46 lines).
- *Evidence.* A timeline trace showed that each `s_cbc` call issued about 12 tiny kernels and 5 scalar updates, each
  followed by `cuStreamSynchronize`: about 230 µs of launch and sync gaps per call.
- *Change.* Queue them on the OpenACC async queue and wait once, before the fluxes are read. The OpenMP path is
  unchanged.
- *Effect.* −1.4 % at 1 GPU, −2.3 % at 4 GPUs. The gain grows with rank count, because the rank with the most CBC
  faces sets the pace.

**K4b: let the compiler inline the Riemann helpers** (CMake only, plus a 3-line cleanup).
- *Evidence.* The HLLC kernel was 42 % slower than in v4.9.3. ncu showed more local-memory than global traffic, and
  long-scoreboard stalls. Its PTX had 9 `.extern .func` calls (`s_compute_mixture_coefficients`,
  `s_compute_speed_of_sound`, `s_compute_average_state`, …).
- *Cause.* nvfortran inlines device routines only within one source file. `-Minfo`'s "cross-inlined" refers to host
  code. The call arguments therefore lived in local memory, and the flux stores became generic `ST`s that forced
  reloads after every store.
- *Change.* Compile the 10-module slice `m_variables_conversion … m_riemann_solvers` as one translation unit.
- *Effect on the kernel.* 0 calls, local loads 178 → 76, all stores now global `STG`.
- *Effect on time.* HLLC 18.7 → 12.9 ms/step, now faster than v4.9.3's 13.2.

**K2: WENO occupancy** (one per-file flag).
- *Evidence.* The WENO5 reconstruction kernel uses 188 registers, so only 8 warps per SM are resident. It is
  latency-bound: FP64 pipe 32 % busy, mostly "wait" and long-scoreboard stalls.
- *Why not the launch shape.* `vector_length(64)` just raised the register count to 206.
- *Change.* `-gpu=maxregcount:128` for `m_weno` only gives 16 warps per SM, at the cost of a few L1-resident spills.
- *Sweep.* 168 → 64.0 ms, 128 → 63.0 ms, 96 → 66.5 ms, so 96 spills too much.
- *Disclosure.* This is a compiler-flag change, so it is disclosed.

**T0.4: MPI start-up** (environment only, 1 GPU).
- *Evidence.* `MPI_Init` alone took 1.70 s of the 1-rank wall time (nsys). A bare `MPI_Init` timer
  (`harness/src/mpiinit.c`) showed the cost is UCX opening all 10 HCAs of the node; HCOLL/UCC off changed nothing.
- *Change.* `harness/nicbind.sh` sets `UCX_NET_DEVICES` to the HCA next to each rank's GPU (read from
  `nvidia-smi topo -m` per job). Wall 7.13 → 6.62 s at 1 GPU, step time unchanged.
- *Host-staged multi-GPU: no.* At 4 GPUs it saves 3.1 s of start-up but makes every step 1.2 ms (4.5 %) slower,
  on every rank and on two nodes: default UCX stripes large host messages over two rails.
- *With `rdma_mpi`: yes.* Halos then go over NVLink, not the HCAs. Final build, 4 GPUs, same node (606032): step
  17.65 → 17.69 ms (noise), wall 13.03 → 9.28 s (−29 %).

**P2+P3: no host round trip per kernel** (`patches/opt/0005`, 10 files, +170/−153).
- *Evidence.* Each RK stage launched 44–68 kernels (by rank) and ~45 scalar `GPU_UPDATE`s, each followed by a host sync: ~1 ms of
  GPU idle per stage. That cost does not shrink with more GPUs, so it was ~20 % of a stage at 4 GPUs (trace 604253).
- *Check first.* A 5-second NVHPC test (604388) showed: after `acc_set_cuda_stream(acc_async_noval, <sync stream>)`,
  async and synchronous work run in issue order on one stream; async scalar updates are staged when queued; an
  update+kernel pair drops from 15.3 to 4.05 µs of host time.
- *Change.* The alias at start-up, and `GPU_ASYNC` (`'async'` on NVHPC, `None` elsewhere) on the 115 directives that run
  every stage: WENO, Riemann state/HLLC, flux differences, conversion, boundaries, halo pack/unpack, RK update. One wait
  before device buffers go to MPI. Other compilers and the OpenMP path generate the same code as before.
- *Effect (same node, A/B).* 4 GPUs with `rdma_mpi`: step 18.81 → 17.71 ms (−5.8 %, every rank). 1 GPU: −1.7 %.
- *Not covered.* NVHPC unified-memory builds (`--unified`, GH200) are untested with this change.

**P4: reconstruct only the cells the Riemann solver reads** (`patches/opt/0006`, 2 files, +29/−14).
- *Evidence.* WENO plus its input pack were 45 % of kernel time after P3 (ncu 606033). Every sweep reconstructed the
  full transverse ghost range, 4 cells on each side, but the only reader of the reconstructed states is the Riemann
  solver, at transverse-interior cells (`irx/iry/irz`). A consumer audit of `simulation/*.fpp` found no other reader.
- *Change.* Transverse reconstruction ranges `idwbuff` → `idwint`; the pack copies only the cells the WENO,
  monotonicity and THINC kernels read. The viscous, capillary and viscous-derivative reconstructions keep their ranges.
- *Effect (same node, A/B vs P3, `rdma_mpi` on multi-GPU).* 1 GPU −2.5 % (621788), 4 GPUs −3.5 % (622305), 8 GPUs
  −4.0 % (622306). Skipped work grows as boxes shrink: 7.5 % of each sweep at 201³ per GPU, 14 % at 101³.
- *Correctness.* Bitwise in all 8 runs; full `./mfc.sh test` 690 pass / 23 fail, the same 23 as P3 and v5.7.0
  (622349–622356).

**Rejected, with evidence.**
- NVHPC 25.9: no gain, not bitwise.
- Compile-time `dir_idx` in HLLC: the SASS got worse (255 registers).
- WENO `vector_length` 64/96.
- WENO cap at 96.
- One HCA per rank at multi-GPU (above). `ob1`/vader: peers unreachable in these jobs. UCX shared memory
  (`UCX_POSIX_USE_PROC_LINK=n`): works, no gain.

## Correctness
- **Benchmark output.** Every rung is bitwise identical to the pinned-v5.7.0 reference (`harness/verify.py`).
- **K4b tests** (generic build, `./mfc.sh test`):
  - A 15 % sample, plus all HLL / HLLD / `mpp_lim` / surface-tension cases.
  - The only failures are 4 tests that fail identically on the unmodified build (`harness/known_test_failures.txt`).
- **K2 tests** (generic build):
  - All 33 WENO-variant cases pass: WENO3/5/7, mapped, WENO-Z, TENO, mp-WENO (602632).
  - A 15 % sample: 102 of 106 pass (602634). Of the 4 failures, 2F35A1FE was already known to vary between runs;
    FD891191 and 1843DA80 fail identically on the unmodified build (602681/602682); 0DDE8A87 had too few MPI slots.
  - The 1-GPU test job now allows MPI oversubscription. With it, 0DDE8A87 and AFBACA70 pass on both builds;
    AFBACA70 had been wrongly listed as a known failure.
- **P3 tests** (generic build):
  - 33 WENO variants plus all 8 multi-rank MPI tests: 41/41 pass (604600).
  - All 19 chemistry tests: 19/19 (604755).
  - A 15 % sample: 100/106 (604601). Five failures were chemistry cases whose binaries had not been built; they now
    pass. The sixth, 1843DA80, fails identically on the unmodified build.
- **Full suite on the final series** (606006–606014): 690 pass, 23 fail, 0 new. All 23 fail identically on
  unmodified v5.7.0 (rechecks 606331/606332 and earlier); listed in `harness/known_test_failures.txt`.

## Where the time is now (sc26 profile, 62.1 ms of kernels per step, job 602705)
| Kernel | ms/step | Share | Note |
|---|---|---|---|
| WENO5 reconstruction (3 directions) | 18.0 | 29 % | was 25.4 before K2 |
| HLLC | 12.9 | 21 % | 146–152 registers |
| WENO input pack | 6.0 | 10 % | removed by NTHU's #2092 (not ours to claim) |
| RK update, advection source, conversion, finalize | ~25 | 40 % | bandwidth-bound copies (#2087 pattern) |

## 4 GPUs (201³ strong)
| Build | Halo exchange | Step, median | Grind | Job |
|---|---|---|---|---|
| v5.7.0 baseline | host-staged | — (2 reps, no per-step data) | 0.1534 / 0.1626 | 600173 |
| sc26 | host-staged | 25.72 ms | 0.1377 | 602770 |
| sc26 | `rdma_mpi=T` | 18.81 ms | 0.0969 | 604560 a1 |
| sc26 + P3 | `rdma_mpi=T` | 17.71 ms | 0.0914 | 604560 b1 |
| + P4 | `rdma_mpi=T` | **17.03 ms** | **0.0876** | 622305 b1 (A/B vs P3 17.65 ms) |

- `rdma_mpi=T` is an MFC input parameter: halos go GPU to GPU over NVLink instead of through host memory. Same
  numerics, bitwise output, −27 % per step at 4 GPUs. It is our multi-GPU configuration (disclosed).
- Strong-scaling efficiency 1 → 4 GPUs with P3 and `rdma_mpi`: 61.8 / (4 × 17.7) = 87 %; with P4
  60.4 / (4 × 17.0) = **89 %** (host-staged sc26: 61 %).
- In a 30-step run, MPI start-up and finalize (~7.5 s) dominate the 12 s wall at 4 GPUs.
- A 4-GPU trace on node hgpn012 (604667) showed one GPU uniformly 20 % slower in every kernel. The A/B runs on hgpn020
  show balanced ranks (RHS 5.35–5.37 ms) at equal clocks, so this is a node anomaly, not load imbalance.
- The baseline has 2 reps and no per-step data; the final comparison needs a same-node baseline with ≥5 reps.

## Next
1. **8 GPUs, code-only arm:** v5.7.0 with `rdma_mpi` on the node of 606019 (≈32 GPU-min, needs the user's OK); the
   8-GPU row above mixes code and configuration. `nicbind.sh` at 8 GPUs is also unmeasured.
2. **Faces-only, all-dims-at-once halo exchange:** after P4 no reconstruction reads corner ghosts on the inviscid path
   (`docs/research-halo-overlap.md` option 4b, second half).
3. **Halo/compute overlap** and fusing the copy-like kernels (`report.md` §9).

**Save time (wall-time FOM).** At 1 GPU a 30-step run is ~6.2 s of wall, of which the steps are ~1.1 s. The one
restart save (520 MB) takes 1.03–1.27 s and the rest is start-up. The ROMIO hints from `docs/research-env-tuning.md` §4
(data sieving off with a 64 MB collective buffer; or independent writes) change nothing: save 1.02–1.27 s against
1.04–1.14 s default, walls equal (669396, bitwise). The save is not bound by ROMIO's write path.

**Single-node MPI transports (configuration, disclosed).** For runs inside one node, UCX needs only shared memory and
CUDA IPC (`rdma_mpi`). `UCX_TLS=self,sm,cuda_copy,cuda_ipc UCX_POSIX_USE_PROC_LINK=n` (the second is needed for `sm`
in these jobs) skips opening the node's InfiniBand adapters at start-up. At 4 GPUs (669435, hgpn037, 2 reps each): wall
10.7 / 13.5 s against 22.6 / 17.0 s, grind 0.0551-0.0556 against 0.0552-0.0554, bitwise. At 1 GPU `UCX_TLS=self`
suffices: ~5.5 s against ~6.0 s (669410). Wall times on nano4 vary run to run, so these need more reps before a final
claim. Multi-node runs must keep the default.

**P16: NaN check of the saved state on the device** (`patches/opt/0019`, wall time only). `s_save_data` scanned every
saved value on the host with `ieee_is_nan`, single-threaded: 64 ms per variable at 201³ (trace 669407), half the
save. A device reduction with an exact bit test now counts NaNs, and the host scan, with its message and abort, runs
only if the count is non-zero. Same node (669490): save 1.11–1.25 → 0.60–0.74 s, wall 6.01–6.57 → 5.78–5.91 s,
grind and output unchanged (bitwise). Not covered by the P15 suite run (p15_full), which predates it.
