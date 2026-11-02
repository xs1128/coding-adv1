# Halo exchange and comm/compute overlap in MFC: a ranked design study

Date: 2026-10-22. This is a read-only static study. Source is MFC master `1ececa3` (local copy in
`/home/hipac2026/xs/ap-hw2/repos/MFC`), and every path below is relative to its `src/`. Line numbers are for
1ececa3, so re-check them against v5.7.0 before patching. The measured inputs are in `profiling-baseline.md`.
Upstream status comes from the GitHub REST API on 2026-10-22, which hit its rate limit, so a few searches are missing.

Case: 3D_performance_test. It is 5-eq with 2 fluids (sys_size = 8), WENO5-M, HLLC and RK3, built with case
optimization in FP64. BCs are `bc_{x,y,z}%beg = -2` (reflective) and `%end = -6` (CBC). `buff_size = weno_polyn + 2 = 4`
(`common/m_helper_basic.fpp:128-133`).

---

## 0. What the code actually does (facts that drive the ranking)

### 0.1 One RK stage
`s_tvd_rk` (`simulation/m_time_steppers.fpp:445`) runs these steps:
1. `GPU_UPDATE(mytime)` (:468).
2. `s_compute_rhs` (`simulation/m_rhs.fpp:578-915`):
   - Copy q_cons → q_cons_qp over the full ghosted box (:602-612).
   - cons→prim on the interior only (`idwint`, :650-652).
   - **One halo exchange of the 8 primitive variables**: `s_populate_variables_buffers` (:654-656).
   - Then for `id = 1..3`: `s_reconstruct_riemann_states` (:920-1019, WENO), then `s_compute_directional_rhs`
     (:1025-, HLLC, CBC and flux difference in `s_compute_advection_source_term` :1061-1755).
3. The RK update kernel.

All kernels are synchronous: there is no `async` anywhere in the RHS. The macros do support it, because
`GPU_PARALLEL_LOOP`, `GPU_UPDATE` and `GPU_WAIT` take `extraAccArgs`/`extraOmpArgs`
(`common/include/parallel_macros.fpp:25-28, 244, 256`).

### 0.2 Halo exchange
`s_populate_variables_buffers` (`common/m_boundary_common.fpp:92-115`) calls `s_populate_bc_direction` for these
faces **strictly in order**: x−, x+, y−, y+, z−, z+.
- An MPI face (`bc_edge >= 0`) calls `s_mpi_sendrecv_variables_buffers` (`common/m_mpi_common.fpp:552-1068`).
- A physical face runs one BC kernel (`m_boundary_common.fpp:150-180`).

Inside `s_mpi_sendrecv_variables_buffers`:
- `GPU_UPDATE(device=[v_size])` is a host→device sync on **every call** (:594).
- One pack kernel (:622-809):
  - The x pack has `i` (variable) innermost (:628-633), so its reads are uncoalesced across arrays.
  - The y and z packs have `j` innermost.
- One blocking `MPI_SENDRECV` (:818 RDMA / :830 host-staged).
  - On the host-staged path, `update host/device` copies the **whole** `buff_send`/`buff_recv` (`halo_size`, the
    largest face, :73-85), not `buffer_count` elements (:826, :836).
  - On the RDMA path, `host_data use_device` is followed by `GPU_WAIT` (:815-823).
- One unpack kernel (:843-1065).

**Corner/edge dependence (question 2): yes, the y and z exchanges carry the x (and y) ghosts.**
- The y pack covers `j = -buff_size .. m+buff_size` (:686-692) and the y BC covers `k = -buff_size..m+buff_size` (:144).
- The z pack covers both x and y ghosts (:746-752).
- So edges and corners are filled by 2 or 3 sequential hops, and the dims must stay in order unless edges and corners
  are sent directly (26 neighbours) or proven unused.
- How much of the volume is ghost columns: at a 101³ local box, 7 % of the y-face message and 14 % of the z-face
  message.
- The 5-eq inviscid solve only **reads** corner ghosts in wasted work:
  - WENO is launched over the full transverse ghost range: `is2 = idwbuff(2)`, `is3 = idwbuff(3)`
    (`m_rhs.fpp:2026-2041`, loops at `m_weno.fpp:954-969`).
  - HLLC consumes only transverse-interior states: `irx/iry/irz` (`m_rhs.fpp:1033-1040`) are passed to
    `s_riemann_solver` (`m_riemann_state.fpp:305-317`).
- Corners are needed with viscous terms (`buff_size = 2*weno_polyn+2`; `s_get_viscous` uses the transverse-ghost
  `qL_rsx_vf`, `m_rhs.fpp:664`). They are also needed with surface tension, MTHINC normals, IB, Lagrangian bubbles and
  axis BCs.

**Sendrecv pattern.** The tag and destination logic (:599-621) pairs ranks as a shift. With 2 ranks per dimension, a
rank has **at most one MPI face per dimension**. At 8 GPUs with 2×2×2, every rank has exactly 3 MPI faces and 3 physical
faces, which matches the 90 Sendrecv calls per 30 stages (= 3 per stage) that we measured. There are no "interior"
ranks. Rank (0,0,0) owns 3 reflective faces and rank (1,1,1) owns 3 CBC faces.

### 0.3 Decomposition
`s_mpi_decompose_computational_domain` (`m_mpi_common.fpp:1323-1682`; 3D search at :1440-1466,
`MPI_CART_CREATE` at :1477) minimises `|Nx/px−Ny/py|+|Ny/py−Nz/pz|`. Ties go to the later candidate. There is no user
override.
- For 201³ it picks **2×1×1, 2×2×1 and 2×2×2** for 2, 4 and 8 GPUs.
- Remainder cells go to the low coordinates (:1486-1494), so rank (0,0,0) has 101³ cells (+3 %) while the CBC-heavy
  rank (1,1,1) has 100³.

### 0.4 Other relevant facts
- `rdma_mpi` is **forbidden** in non-OpenACC (OpenMP-offload) builds (`simulation/m_checker.fpp:45-47`). The OpenMP
  path is therefore always host-staged, and any new code must keep the `#:for rdma_mpi` dual path (:812-840).
- CBC adds host syncs per CBC face per direction: `GPU_UPDATE` at `m_cbc.fpp:461, 522, 951, 952, 1189`, plus about 12
  small kernels. Their footprint in the counts: (2072−992)/30 stages ≈ 36 extra launches/stage = **3 CBC faces × ~12**.
- Further per-call host syncs: WENO (`m_weno.fpp:945, 948`), Riemann (`m_riemann_state.fpp:317, 337, 339`) and
  reconstruction (`m_rhs.fpp:937, 977, 2074`). That is about 20 or more per stage.

## 1. Time budget used for all estimates (8 GPUs strong, RDMA, rank 0, per RK stage)

| bucket | ms | source / reasoning |
|---|---|---|
| stage = TIMESTEP/3 | **5.50** | 16.5 ms / 3 |
| kernels | 3.5 | nsys |
| Sendrecv, pure transfer + MPI latency | ≈0.09 | 3 × min 0.03 ms (2.6–3.0 MB over NVSwitch) |
| Sendrecv, **waiting for the neighbour** | ≈0.93 | 3 × (median 0.34 − min 0.03) |
| pack/unpack/BC kernels + `v_size` syncs + `GPU_WAIT` | ≈0.33 | RHS-COMMUNICATION 1.35 − 1.02 |
| RHS host gaps (launch latency, ~20 scalar `GPU_UPDATE`s) | ≈0.40 | 5.25 − 1.35 − 3.5 |
| outside RHS (RK update, `mytime`) | ≈0.25 | 5.50 − 5.25 |
| ideal (1-GPU stage 27.07 ms / 8) | 3.38 | 81.2 ms / 3 / 8; now 4.92× (62 %) |

**Key reading of the budget.**
- With RDMA, the halo is **not bandwidth-bound**: only 0.09 ms of the 1.35 ms moves data.
- About 70 % of the time is **waiting**: rank 0 is the lightest rank (0 CBC faces) and waits for CBC-heavy neighbours.
  Jitter from unbound host threads probably adds to this.
- In steady state, the stage time is set by the heaviest rank's own path, so overlap on rank 0 cannot remove the wait.
  Only two things shorten the stage:
  - shortening the **heavy rank's** comm overhead (≈0.33 + 0.09 ≈ 0.42 ms: the ceiling for any pure-halo option);
  - reducing the **imbalance** itself (ceiling ≈0.9 ms).
- **First measurement to do:** a per-rank nsys of rank 7 vs rank 0. Compare (COMPUTE-RHS − Sendrecv) per stage to split
  "imbalance" from "jitter".

Estimated RDMA baselines for 2 and 4 GPUs (not measured; please measure):
- **4 GPU (2×2×1).** Host-staged is 10.87 ms/stage with 3.05 ms of comm for 2 faces of ~5.4 MB. RDMA should give about
  0.45 ms per face, as at 8 GPUs, so ≈8.7 ms/stage → **≈3.1× (78 %)**.
- **2 GPU (2×1×1).** One 10.3 MB face. Estimate ≈14.0 ms/stage → **≈1.93× (96 %)**.
- **Weak scaling:** RDMA already gives ≈100 % on min-stage. The weak-scaling loss was host staging of 10–11 MB faces
  (3 faces ≈ 9.5 ms).

## 2. Options

### Option 1: `rdma_mpi = T` plus UCX and affinity tuning (no code)
**Mechanism.** CUDA-aware `MPI_SENDRECV` on device buffers (`m_mpi_common.fpp:815-823`) removes the full-buffer
D2H/H2D (:826, :836) and the host copy.

**Measured.**
- 8 GPUs: TIMESTEP 26.0 → 16.5 ms (−37 %); speedup 3.12 → 4.92 (median step) and 3.57 → 5.57 (grind).
- Weak: 73 % → ≈100 %.
- Bitwise identical.

**Remaining tuning (est. 0–3 %, possibly more if jitter is a big part of the 0.93 ms wait):**
- **NUMA/CPU binding.** Today the binding policy is none. Use a wrapper such as
  `numactl --cpunodebind=$NODE_OF_GPU --membind=…`, keyed on `OMPI_COMM_WORLD_LOCAL_RANK`, which avoids the cgroup
  problem with OMPI binding. Unbound host threads add launch and MPI-progress jitter, and at 8 GPUs every stage is
  host-latency sensitive.
- **UCX environment:**
  - `UCX_TLS=cuda_ipc,cuda_copy,sm,self` keeps intra-node traffic off rc loopback.
  - `UCX_RNDV_SCHEME=get_zcopy|put_zcopy` (A/B the two).
  - `UCX_CUDA_IPC_CACHE=y` and `UCX_MEMTYPE_CACHE=y`, which are the defaults; check them.
  - `OMPI_MCA_pml=ucx`.
  - The 2.6–3 MB messages are always rendezvous, so `UCX_RNDV_THRESH` hardly matters.

**Notes.**
- The 175 ms first step is cuda_ipc handle mapping. It is a one-off because `buff_send`/`buff_recv` are persistent.
- The ceiling on transfer gains is 0.09 ms/stage.

**Risk.** None for numerics. RDMA is OpenACC-only (`m_checker.fpp:45-47`).

**Verify.** nsys `RHS-COMM-SENDRECV-RDMA` min/median on every rank, and `compare_vs_1g`.

**Expected.** Measured (8) / est. (4: −20 %, 2: grind 1.54 → ~1.9).

**PR-ability.** No source change. You could propose documenting it, or defaulting `rdma_mpi` on for NVHPC, but that
would be a behavioural change maintainers may refuse.

### Option 2: concurrent face exchanges (Isend/Irecv + Waitall)

**2a. Per dimension (= upstream #2090 by NTHU, draft, +174/−69).**
- Mechanism: both sides of a direction go Isend/Irecv, then Waitall. Dims stay sequential, so corners are preserved.
- Gain:
  - With the default decompositions here (2×1×1, 2×2×1, 2×2×2) a rank has **at most one MPI face per dimension**, so
    there is nothing to run concurrently: **≈0 % at 2/4/8 GPUs** on this node.
  - It helps only with ≥3 ranks per dimension. #2090 claims −9 to −12 % at 3–6 ranks, and the effect would show at
    16+ GPUs or with 1×2×4.
- Status: #2090 has gpu-omp MPI test failures on Phoenix and no maintainer review yet. If #2090 is our team's PR, fix it
  and land it first, then build on it. Do not duplicate it.

**2b. All dimensions in one round, with 26-neighbour edges and corners (new `s_mpi_exchange_halo_single_round`).**
- Mechanism:
  - Post all (up to 26) neighbour messages at once. At 2×2×2 non-periodic that is 7 neighbours: 3 faces, 3 edges
    (~0.1 MB each) and 1 corner (2 KB).
  - Waitall, then run **physical BCs in x→y→z order**. The x BC is extended over the transverse ghost rows of MPI
    dims.
- Bitwise argument (pointwise identical arithmetic):
  - corner(x-MPI, y-MPI): the diagonal neighbour's interior in both schemes.
  - corner(x-MPI, y-phys): `BC_y` over the received x-ghost, as today.
  - corner(x-phys, y-MPI): today it is the neighbour's `BC_x` of its interior, which equals our y-ghost after the round;
    the new scheme applies `BC_x` to that y-ghost, the same function on the same input.
  - corner(phys, phys): unchanged order.
  - The diagonal neighbour exists iff both face neighbours exist (Cartesian, incl. periodic), so the cases are complete.
  - Fall back to the old path for `BC_AXIS`/cylindrical, Dirichlet-from-buffers, IB, qbmm and IGR. #2093 also kept
    the old path for Dirichlet corners.
- Files and LOC:
  - New routine plus a neighbour/offset table in `common/m_mpi_common.fpp`: ~250 LOC, built once in
    `s_initialize_mpi_common_module` (:51-95).
  - Dispatch in `s_populate_variables_buffers` (`m_boundary_common.fpp:92-115`), plus the transverse-range change in
    `s_populate_bc_direction` (:139-146) for dir 1 (and dir 2 over z): ~60 LOC.
  - Tags must encode the direction index (`13 ± offset`). With periodic BCs and 2 ranks per dim, the same peer appears
    for several directions.
  - Total **≈350–500 LOC**.
- Gain: it removes 2 of the 3 serialized round trips on the heavy rank's path (latency + `GPU_WAIT` + `v_size` sync,
  ≈30–50 µs each).
  - 8 GPUs: **−0.06–0.15 ms (−1–3 %)**
  - 4 GPUs: −0.5–1 %
  - 2 GPUs: 0
  - #2093 measured 1.036× for single-round, but in a regime with 8× faster kernels.
- Risks:
  - Deadlock or mis-matching with duplicate peers (fix with unique tags).
  - Corner bitwise identity for exotic BCs (fix with fallbacks).
  - Buffer offsets.
  - The OpenMP path must stay host-staged: a single `update host` of the used part of the buffer.
- Verify:
  - Full `./mfc.sh test` and `./mfc.sh test --rdma-mpi`.
  - Multi-rank goldens with periodic, reflective and CBC BCs on 2, 3, 4, 6 and 8 ranks, including 1-D and 2-D
    (`n==0` and `p==0` early returns at :102, :109).
  - Compare state files incl. ghosts with a debug dump (expect identical); `compare_vs_1g`; an OpenMP build plus the
    test subset.

### Option 3: pack/unpack fusion, host-sync removal and async queues

**3a. Without changing the protocol (small, ~30–60 LOC):**
- Drop `GPU_UPDATE(device=[v_size])` at `m_mpi_common.fpp:594`: pass `v_size` as a local scalar (`firstprivate`).
- Swap the x-pack and x-unpack loop order so that `j/k` is fastest (:628-633, :848-853). Keep `r` unchanged so the
  buffer layout stays the same.
- On the host-staged path, copy only `buffer_count` elements, using an array section in `GPU_UPDATE`
  (:826, :836). This helps the OpenMP path and the default path: −14 % bytes on the x face.
- Gain at 8 GPUs (RDMA): ≈0.03–0.06 ms (≈1 %).
- Risk: very low, bitwise identical (same values, same layout).

**3b. With 2b: one fused gather kernel and one fused scatter kernel over all neighbours.**
- Use a device-resident index table built once. #2093 called this "halo index cache".
- Instead of 3 pack kernels, 3 unpack kernels, 3 syncs and 3 waits, you get 1 + 1 + 1 wait.
- Gain on top of 2b: −0.1–0.2 ms at 8 (−2–4 %).
- **Combined 2b+3b: −0.15–0.3 ms → −3–5 % at 8, −1–2 % at 4, ≈0 at 2.**

**3c. OpenACC `async(q)` for pack and unpack.**
- Use it only together with option 4. On its own the MPI call needs the pack finished anyway.
- Use `extraAccArgs='async(1)'` and an empty `extraOmpArgs`, so the OpenMP path stays synchronous and correct.

### Option 4: overlap communication with computation

**4a. Interior/boundary split (classic).**
- Feasibility: with WENO5 the RHS at cell j needs j−3..j+3, so the "interior" is cells ≥3 from every MPI face. CBC and
  physical BCs run with the interior because they need no MPI data.

| case | interior fraction of cells |
|---|---|
| 1 M cells/GPU (101³), 2×2×2: one MPI side per dim | **91.3 %** |
| 8.1 M cells/GPU (201³), 2×2×2 weak: one MPI side per dim | **95.6 %** |
| 101³ rank with all 6 faces MPI (multi-node) | 83 % |
| 201³ rank with all 6 faces MPI (multi-node) | 91 % |

- Changes:
  - Run WENO (`s_weno` range args), HLLC (`irx/iry/irz`) and flux difference (`m_rhs.fpp:1117-1140` ff., loops
    `0..m`) per box: 1 interior box plus up to 3 (6) shell slabs.
  - CBC calls go into the interior phase.
  - Per-cell accumulation order (x assign, y/z add) is preserved inside each phase, so results stay **bitwise
    identical**.
  - Pack, Isend and Irecv go on `async(2)`, the interior on `async(1)`, then wait, unpack, BCs, and the shell.
- Show-stopper today: every WENO, Riemann and reconstruct call does 3–6 scalar `GPU_UPDATE`s (module-level
  `is1/is2/is3`, `iv`, `v_size`, `dir_idx`).
  - Splitting into 4–7 boxes × 3 directions adds about 60–100 host syncs per stage (~0.6–1 ms), which is **larger than
    the 0.42 ms it can hide**.
  - It only pays after these become kernel arguments (option 9).
- Hideable: at most the heavy rank's 0.42 ms, minus the cost of the slab kernels. The slabs are 3 cells thick and
  latency-bound: about 27 extra launches per stage.
- Gain:
  - 8 GPUs: −2–5 % (after option 9), negative before it.
  - 4 GPUs: −1–3 %.
  - 2 GPUs and weak: ≈0.
- **LOC 700–1200.** High risk: every physics module that consumes ranges.
- Not recommended for SC26.

**4b. Direction-pipelined overlap plus transverse-interior WENO (cheaper, also a compute win).**
- Restrict the WENO transverse range from `idwbuff` to `0..n` / `0..p` (`m_rhs.fpp:2026-2037`, :2061-2071).
  - The v_rs_weno pack (`m_weno.fpp:893-910`) is restricted the same way.
  - Guard with an allowlist (inviscid, no surface tension, `int_comp == 0`, no IB, no Lagrangian, cartesian, no
    hypoelastic FD, …), because those features read transverse-ghost reconstructions.
- WENO work then shrinks by **9.2 % at 1 GPU (201³), 12 % at 2, 16 % at 4 and 19 % at 8** (these are the excess
  fractions). WENO is 34 % of the stage, so that is −0.78 ms at 1 GPU, −0.52 at 2, −0.33 at 4 and −0.20 at 8.
  **About −3–4 % at every GPU count**: a time-to-solution win, not mainly a scaling win.
- With corners no longer read, the exchange can post **faces only, all dims at once** (no 26-neighbour logic):
  - y/z messages shrink by 7 % and 14 %.
  - Pipeline: `wait(x)` → x sweep → `wait(y)` → y sweep → … with unpack on `async`.
  - This hides the y/z transfers and unpacks behind the x sweep: a further −0.05–0.15 ms at 8.
- **Total −4–6 % at 8, −4–5 % at 4, −4 % at 2, −3 % at 1.** About 200–350 LOC.
- Risk:
  - Allowlist completeness. A wrong gate makes goldens fail, which is loud, not silent.
  - Interior bitwise identity holds, but ghost corners become stale (they are not in output).
  - Coordinate with #2092 (WENO direct read), which edits the same code.

### Option 5: fewer exchanges or less volume
- **Prim vs cons:** same 8 variables, so no volume change. Exchanging cons and converting at ghosts is bitwise
  identical (pointwise) but only adds compute. **0 %.**
- **3 instead of 4 layers:** layer 4 only feeds the unused reconstructions at j = −2 and m+2 (Riemann uses −1..m+1).
  - That cuts volume by 25 %. But transfer is only 0.09 ms, so the saving is ≈0.02 ms plus about 25 % of pack time:
    **< 1 %**.
  - Risk: `buff_size` is shared with many features. Not worth it.
- **One exchange per stage is already minimal.** The 26-neighbour single round (2b) is the only "fewer rounds" change
  (9 → 3 dependent rounds per step).
- **FP32 halo:** changes numerics. **Forbidden.**

### Option 6: NVSHMEM, CUDA Graphs, MPS
- **NVSHMEM.**
  - The ceiling is the transfer plus host-progress part. With RDMA that is ≈0.1–0.4 ms at 8 (2–7 %).
  - #2093 claimed +7–25 % in step time, but with kernels about 8× faster than ours.
  - It needs a C++/NVSHMEM backend, is OpenACC/NVIDIA-only, and breaks OpenMP parity.
  - Maintainers rejected exactly this in #2093 ("OpenACC+Nvidia specific modules… C++ backends", "no chance").
  - **Do not pursue.**
- **CUDA Graphs.**
  - They would remove the ~0.4 ms of host gaps plus launch latency (up to −7 % at 8), but need every scalar
    `GPU_UPDATE` made async, and MPI cannot be captured.
  - NVHPC/OpenACC-specific, same veto. **Do not pursue** upstream. Removing the syncs (option 9) gets most of the
    benefit portably.
- **MPS with 2 ranks/GPU (16 ranks, 2×2×4).**
  - No code; this is a run-configuration experiment. Results stay bitwise identical, as observed across
    decompositions.
  - Pro: one rank's waits and host gaps are filled by the other rank's kernels.
  - Con: WENO excess rises to ~25 % and comm volume doubles.
  - Estimate: −5 % to +10 %, uncertain. Worth one 30-step run.

### Option 7: decomposition choice and load imbalance (201³ strong; volume = max send bytes per rank per stage)

| grid | cells max/min (M) | MPI faces/rank | MB/rank | CBC faces max/min | WENO excess | interior frac |
|---|---|---|---|---|---|---|
| 2×1×1 (default, 2 GPU) | 4.08/4.04 | 1 | 10.3 | 3/2 | 12.3 % | 97 % |
| 2×2×1 (default, 4 GPU) | 2.05/2.01 | 2 | 10.8 | 3/1 | 15.6 % | 94 % |
| **2×2×2 (default, 8 GPU)** | 1.03/1.00 | 3 | **8.5** | **3/0** | **18.9 %** | 91 % |
| 1×2×4 (NTU choice) | 1.035/1.005 | 3 | 14.3 | 3/1 | 22.0 % | 85 % |
| 1×1×8 slabs | 1.05/1.01 | 2 | 22.4 | 3/2 | 30.8 % | 76 % |

| weak, 8.1 M cells/GPU | MB/rank (max) |
|---|---|
| 2×2×2 | 32.3 |
| 2×2×1 | 21.1 |
| 2×1×1 | 10.3 |

(Computed with `/tmp/claude-1001/-home-hipac2026-xs-coding-adv1/b32117a9-6154-48d6-90fd-869c95370172/scratchpad/decomp.py`.)

- With RDMA, volume is irrelevant (≤0.1 ms). The default **2×2×2 is best** on volume, WENO excess and interior
  fraction.
- Its weakness is the worst CBC spread: 3 CBC faces on rank (1,1,1) vs 0 on rank (0,0,0). The ~0.93 ms wait is
  consistent with ~0.3 ms per CBC face (12 launches + 5 syncs).
- Slabs and pencils reduce the CBC spread but cost +3–12 % WENO work: likely net negative.
- **Better: rebalance cells.** Add an optional case parameter for the process grid and/or cut offsets.
  - Today it is impossible: `s_mpi_decompose_computational_domain` has no override (:1440-1494).
  - About 80–200 LOC (toolchain `case_dicts`, `m_global_parameters`, `m_mpi_common` :1440-1494 and the 2D/1D
    analogues, checker).
  - One x-plane is ~1 % of a rank's work (~0.035 ms), so offsetting ~0.3 ms per CBC face needs ~8 planes per dim.
  - Gain is at most the imbalance part (est. −3–8 % at 8). Decide only after the per-rank measurement in §1.
  - PR-ability medium: maintainers may prefer an automatic method. NTU's env-var version died with #2093.

### Option 8 (new, the biggest halo-adjacent lever): cut CBC cost on boundary ranks (imbalance)
- Turn the 5 scalar `GPU_UPDATE`s per CBC call (`m_cbc.fpp:461, 522, 951, 952, 1189`) into `firstprivate` kernel
  arguments or locals.
- Fuse the CBC staging copies (`m_cbc.fpp:535-594`, 956-1160).
- This directly shrinks the critical (heavy) rank. Same idea as #2093's `--cbc-no-host-sync`, but as a small,
  portable, default-on change.
- **≈100–300 LOC.** Gain −3–8 % at 8 (ceiling 0.93 ms), −1–3 % at 2/4, ~1 % at 1 GPU.
- Risk: low. Bitwise identical, same arithmetic. OpenMP is fine with `firstprivate`.
- Verify: CBC goldens and per-rank nsys spread.

### Option 9 (enabler): remove per-call scalar host syncs in the RHS
- Targets: `m_weno.fpp:945, 948`, `m_riemann_state.fpp:317, 337, 339`, `m_rhs.fpp:937, 977, 2074`, and
  `m_time_steppers.fpp:468`.
- This is the 0.40 ms "host gap" bucket.
- About 150–300 LOC. −2–5 % at 8. It is the prerequisite for 4a and for any async work.

---

## 3. Upstream status (avoid duplication)

| # | what | state | maintainer signal |
|---|---|---|---|
| 2089 (issue) | per-direction non-blocking halo; median Sendrecv 4.4 µs vs mean 92 µs, so the cost is waiting | open | none |
| 2090 (PR, NTHU) | Isend/Irecv both sides per direction + Waitall, halo_side descriptor, +174/−69 | open draft; gpu-omp MPI tests failing | wilfonba: maintainers mark ready; no technical review yet |
| 2093 (PR, NTU) | fused RHS, single-round 26-neighbour, index cache, NVSHMEM, async queue, CUDA graphs, `MFC_HALO_OVERLAP` | **closed 10-20, rejected** | ~5× over the 5000-line guideline; `#ifdef`/vendor modules/C++ backend; "prioritize protecting the scaling efficiency"; danieljvickers: changes should fit "under 1k lines of additions" |
| 2092 / 2087 | WENO direct read / collapse | drafts | not ready-gated |
| 1628 → #2080 | AMR/active-box, device "wire pools" | closed, to be split | — |

Implications:
- Keep PRs under 1k added lines and portable (OpenACC + OpenMP + CCE, no new backends).
- Results must be byte-identical.
- Bring multi-rank 3D evidence, with ≥3 ranks per dim for exchange PRs.
- **The SCC source-change deadline is 2026-10-26.**
- Single-round 26-neighbour exchange, index cache and overlap are unclaimed in mergeable form.
- NVSHMEM and graphs are effectively vetoed.

## 4. Ranked recommendation

Gains are relative to the RDMA baseline (5.50 ms/stage at 8). The 2/4 GPU baselines are estimated.

| rank | option | est. gain 2 / 4 / 8 GPU | LOC | risk | PR-ability |
|---|---|---|---|---|---|
| 1 | **O1** `rdma_mpi=T` (+ NUMA binding, UCX env) | measured −37 % at 8 vs host-staged; tuning extra 0–3 % | 0 | none | n/a (run config) |
| 2 | **O8** CBC host-sync removal / fusion (imbalance) | −1 / −2 / **−3–8 %** | 100–300 | low | high (small, portable) |
| 3 | **O4b** transverse-interior WENO + faces-only all-dim exchange with per-direction wait | −4 / −4–5 / **−4–6 %** (1 GPU −3 %) | 200–350 | medium (feature allowlist) | medium-high |
| 4 | **O2b + O3b** single-round 26-neighbour + fused pack/unpack (+ O3a) | 0 / −1–2 / −3–5 % | 350–550 | medium (tags, corners, BC fallbacks) | medium; build on #2090 |
| 5 | **O9** scalar host-sync removal in RHS | −1 / −2 / −2–5 % | 150–300 | low | high |
| 6 | **O3a** v_size sync, x-pack order, partial host copies | ~0 / <1 / ~1 % (more on OpenMP/host-staged) | 30–60 | very low | high (fold into #2090) |
| 7 | **O7** user process grid / cut offsets | 0 / ? / −3–8 % only if imbalance confirmed | 80–200 | low | medium |
| 8 | **O2a** per-direction Isend (#2090) | 0 / 0 / 0 here (helps ≥3 ranks/dim) | 174 (exists) | low | land existing PR |
| 9 | **O4a** interior/boundary split | ~0 / −1–3 / −2–5 % (negative before O9) | 700–1200 | high | low before deadline |
| 10 | **O6** MPS 2 ranks/GPU | −5…+10 % (experiment) | 0 | low | n/a |
| 11 | **O5** 3-layer exchange | <1 % | ~50 | medium | low |
| 12 | **O6** NVSHMEM / CUDA graphs | ≤2–7 % | >1000 | high | **vetoed** (#2093) |

**Realistic combination before 10-26:** O1 + O8 + O3a + (O4b or O2b) ≈ −0.5 to −1.0 ms/stage at 8 GPUs. That is
4.5–5.0 ms/stage, about **5.4–6.0× (67–75 %)** vs 4.92× now.

**Verification for every source option:**
1. Full `./mfc.sh test` (1e-12 goldens), plus `--rdma-mpi`.
2. Multi-rank runs at 2/3/4/6/8 ranks with periodic, reflective and CBC BCs.
3. `compare_vs_1g` bitwise check at 1/2/4/8.
4. An OpenMP-offload build (`--gpu mp`) with the test subset; it is host-staged only.
5. Per-rank nsys (all ranks) with NVTX medians and step-time (not grind) as the metric.
6. A hang check: a 1000-step run at 8 ranks plus odd rank counts.
