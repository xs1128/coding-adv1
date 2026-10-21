# MFC simulation: GPU/MPI parallel structure (static reading)

Source read: MFC master 1ececa3 (2026-09-25, ~2 weeks after v5.7.0; paths relative to `src/`). Line numbers
may shift slightly vs the pinned v5.7.0 — re-check before patching. Case: 3D 5-eq, 2 fluids, WENO5, HLLC, RK3
(sys_size = 8, buff_size = 4 ghost layers).

## One RK stage (all kernels synchronous, `!$acc parallel loop gang vector default(present)`, no `async`)
0. `GPU_UPDATE device(mytime)` (m_time_steppers:468) — sync scalar update every stage.
1. `s_compute_rhs` (m_rhs:578)
   - K copy q_cons → q_cons_qp incl. ghosts (m_rhs:602)
   - K cons→prim, interior only (common/m_variables_conversion:421)            [nvtx RHS-CONVERT]
   - Halo `s_populate_variables_buffers` (common/m_boundary_common:92): faces x−,x+,y−,y+,z−,z+ **strictly
     sequential**; MPI faces = pack K → `MPI_SENDRECV` (blocking) → unpack K (common/m_mpi_common:552–1030);
     physical faces = one face kernel.                                          [RHS-COMMUNICATION, -PACKBUF,
     -SENDRECV-RDMA / -NO-RMDA, -DEV2HOST, -HOST2DEV, -UNPACKBUF]
   - per direction id = 1..3 (m_rhs:683):
     a. WENO: sync updates of is*/v_size; K pack q_prim → v_rs_weno (full domain, 8 vars, **3× per stage**);
        K WENO5 (m_weno:1096)                                                    [RHS-RECONSTRUCTION]
     b. HLLC: sync updates of is/isx/dir_idx…; K HLLC (m_riemann_solver_hllc:900, "at the register ceiling");
        K finalize copy flux_rsx → flux_n (m_riemann_state:1342)                [RHS-RIEMANN-SOLVER]
     c. CBC on ranks owning bc=−6 faces (m_cbc, many small kernels); K flux difference → rhs (x assigns,
        y/z accumulate); K α·div(u) source                                       [RHS-ADVECTION-SRC]
2. K RK update (m_time_steppers:497).

## MPI
- Decomposition: search over factorizations minimising cell-count imbalance between dims; ≥25 cells/rank/dim;
  `MPI_CART_CREATE(reorder=.false.)`; no user override of px/py/pz (common/m_mpi_common:1323).
- 1 halo exchange / stage: 8 vars × 4 layers × 6 faces, `MPI_SENDRECV` per face, no overlap with compute.
- `rdma_mpi=T`: device buffers via `host_data use_device` + `acc wait`. Else full max-face buffer
  `update host` → Sendrecv → `update device`.
- Device: local rank (MPI_Comm_split_type SHARED) mod ndev; no CPU/NUMA affinity in code.

## Build knobs (cmake/GPU.cmake, cmake/MFCTargets.cmake)
`-gpu=cc90,keep,ptxinfo,lineinfo -Minfo=inline,accel -Mfprelaxed`, two-pass IPO in Release; no maxregcount.
Toolchain: `--case-optimization`, `--fastmath`, `--unified`, `--single/--mixed`.

## Static candidates (to be confirmed by profiling)
1. Fully synchronous launches + ~15–25 scalar `acc update` per stage → launch/sync latency.
2. Redundant full-array copies: q_cons→q_cons_qp, q_prim→v_rs_weno (×3), flux_rsx→flux_n.
3. Halo: 6 serialised blocking Sendrecv, no interior/boundary overlap; small pack/unpack kernels.
4. Load imbalance: CBC/physical-BC kernels only on boundary ranks.
5. Register pressure in WENO5/HLLC (large private lists) → occupancy.
6. x/y/z sweeps independent until the rhs accumulation → could use separate async queues.
