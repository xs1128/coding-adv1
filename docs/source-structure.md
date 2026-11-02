# MFC source map

From reading the code, not timing it: MFC master 1ececa3 (2026-09-25, ~2 weeks after v5.7.0; paths under `src/`;
line numbers may drift in v5.7.0). Case: 3D, 2 fluids, WENO5, HLLC, RK3, 8 variables, 4 ghost layers.

A **kernel** (K) is one GPU function run over all cells at once. **RK3** moves time forward in 3 sub-steps
(stages). **Ghost cells** are a border copied from the neighbour.

## One RK stage (each K finishes before the next starts)
0. `GPU_UPDATE device(mytime)` (m_time_steppers:468): a small copy that waits.
1. `s_compute_rhs` (m_rhs:578) works out how each cell changes:
   - K copies q_cons → q_cons_qp (m_rhs:602); K turns conserved into primitive variables (density, velocity,
     pressure) (common/m_variables_conversion:421).
   - Halo exchange (common/m_boundary_common:92) fills ghost cells **one face at a time**: pack K →
     `MPI_SENDRECV` (waits) → unpack K (common/m_mpi_common:552–1030).
   - Per direction (m_rhs:683): K copies WENO input (**3× per stage**); K WENO5 builds smooth values at cell faces
     (m_weno:1096); K HLLC works out what flows between two cells (m_riemann_solver_hllc:900, "at the register
     ceiling"); K copies flux_rsx → flux_n (m_riemann_state:1342); edge GPUs run many small CBC (outflow
     boundary) kernels (m_cbc); K adds flux differences into rhs.
2. K RK update (m_time_steppers:497).

## MPI
The split evens out cell counts; users cannot choose it (common/m_mpi_common:1323). One halo exchange per stage,
6 faces, no compute alongside. `rdma_mpi=T` sends straight from GPU memory; otherwise data goes through the CPU.
Build flags (cmake/GPU.cmake): `-gpu=cc90,keep,ptxinfo,lineinfo -Mfprelaxed`, no register limit.

## Suspects, to confirm by profiling
1. Every launch waits, plus ~15–25 small updates per stage.
2. Extra full-array copies (above).
3. Halo: 6 waiting Sendrecvs in a row.
4. Uneven load: boundary kernels run only on edge GPUs.
5. WENO5/HLLC use many registers (each thread's tiny fast storage), so fewer threads run at once.
6. The x/y/z sweeps are independent until rhs, so they could run side by side.
