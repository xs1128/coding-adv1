# Prior work on MFC performance (research notes, 2026-10-22)

Numbers are the authors' own; not reproduced by us unless marked.

## Papers
- **MFC 5.0** (Wilfong et al., CPC 2026, arXiv 2503.07953): OpenACC collapse(3) + seq species loop; Fypp case
  optimization ≈10× GPU; coalescing reshapes ≈10×; GPU-aware MPI. Grind (3D_performance_test): GH200 0.32,
  H100 SXM 0.38, B200 0.46 ns (no H200). Strong scaling ×8/×16 devices: Summit 79/51 % → 84/60 % with
  GPU-aware MPI; Frontier 96/92 %. WENO+Riemann ≈50 % of wall on NVIDIA; GH200 roofline: WENO 24 %, Riemann 5 %.
- **Radhakrishnan et al., CPC 2024** (arXiv 2305.09163): ≈10 FLOP/B, 46 % of peak FLOP; 84 % strong at ×8.
- **OpenACC porting** (arXiv 2409.10729): flatten derived types 6×; compile-time-sized private arrays essential;
  manual inlining avoids 10× slowdowns; GPU-aware MPI 81→92 % at ×16.
- **SC25 GB finalist, IGR** (arXiv 2505.07392): single fused RHS kernel, 25× less memory; GH200 unified memory;
  newer NVHPC regressed FP64 (used 24.3). Not our case (WENO/HLLC), but shows fusion headroom.

## MFC GitHub, Oct 2026 (SC26 teams; mostly unmerged)
| # | What | Claimed effect |
|---|---|---|
| 2088 | master ≈31 % slower than v4.9.3 (H200 PCIe 0.468 vs 0.346 ns); HLLC spills (190–242 regs, local mem) | HLLC 2.7 ms vs 1.42 ms |
| 2094/2095 | NVHPC does not inline cross-file device routines; private-copy inlining | HLLC stack 576→48 B, −11.7 % grind (closed: "too cumbersome") |
| 2087 (NTHU) | collapse only the 3 spatial loops, not 4 | −5–10 % grind |
| 2092 (NTHU) | drop redundant WENO input pack | ≈−6 % grind |
| 2089/2090 (NTHU) | Isend/Irecv+Waitall halo | +9–12 % at 3–6 ranks; delay is neighbour imbalance, not bandwidth |
| 2093 (NTU, closed) | fused WENO+Riemann+RHS w/ shared-mem tiling, async queue, CUDA graphs, 26-neighbour halo, NVSHMEM, per-module reg caps (168), explicit 1×2×4 grid — on 8× H200 **NVL** | 8× at 1 GPU, 6× at 8; strong scaling ×8 fell 5.85→4.4 (grind) / 2.7–3.4 (step time) |
| 987 | maxregcount:128 helps IGR on GH200 | not merged globally |

Key methodological warning (#2093): grindtime is host-clocked min-stage time; with async it is wrong, and host-side
halo stalls fall outside the bracket → **step/wall time is the honest metric for parallel efficiency.**
SC26 note: source changes must be shared with the committee ≈2 weeks before 11/16 (PR thread mentions 10/26).

## General
- Pekkilä et al. 2022 (arXiv 2103.01597) CUDA-aware MPI for high-order stencils.
- Ekelund et al. PDP 2025 (arXiv 2501.09398) CUDA Graphs kernel batching (>1.4× on stencils).
- Sojoodi et al. (arXiv 2604.22228) multi-path intra-node UCX + CUDA Graphs (up to 2.95× over single-path cuda_ipc).
- GROMACS NVSHMEM halo (arXiv 2509.21527): 1.5× intra-node strong scaling.
- STREAmS-2 (arXiv 2304.05494), URANOS-2.0 (CPC 2024): OpenACC WENO restructuring.
