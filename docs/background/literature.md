# Prior work on MFC performance

**What this is.** Reading notes from 2026-10-22, the start of the project. Numbers are the authors' own, not reproduced
by us. What we later tried is in [ladder](../ladder.md) and [optimizations](../optimizations.md). *Grind* = MFC's speed
score in ns per cell per equation per step; lower is better.

## Papers
- **MFC 5.0** (Wilfong et al., CPC 2026, arXiv 2503.07953): simpler GPU loops, per-case code (≈10× on GPU), better memory
  layout (≈10×), GPU-aware MPI. Grind: GH200 0.32, H100 SXM 0.38, B200 0.46 ns (no H200). Strong scaling ×8/×16: Summit
  79/51 % → 84/60 % with GPU-aware MPI; Frontier 96/92 %. WENO + Riemann ≈50 % of time on NVIDIA.
- **Radhakrishnan et al., CPC 2024** (arXiv 2305.09163): 46 % of peak FLOP; 84 % strong scaling at ×8.
- **OpenACC porting** (arXiv 2409.10729): flattening nested types 6×; hand inlining avoids 10× slowdowns.
- **SC25 finalist, IGR** (arXiv 2505.07392): one fused kernel, 25× less memory; used NVHPC 24.3 because newer releases
  were slower at FP64. A different method, but it shows fusion headroom.

## MFC GitHub, Oct 2026 (SC26 teams; mostly unmerged)
- **#2088**: master ≈31 % slower than v4.9.3 (H200 PCIe 0.468 vs 0.346 ns); HLLC spills to slow memory (2.7 vs 1.42 ms).
- **#2094/2095**: the compiler does not inline helpers from other files; pasting private copies of them in gave −11.7 % grind (closed: "too
  cumbersome").
- **#2087 (NTHU)**: collapse only the 3 space loops: −5–10 % grind. **#2092 (NTHU)**: drop a needless WENO input copy:
  ≈−6 %.
- **#2089/2090 (NTHU)**: send all halo messages, then wait once: +9–12 % at 3–6 ranks; the delay is uneven neighbours,
  not bandwidth.
- **#2093 (NTU, closed)**: fused kernels, CUDA graphs, NVSHMEM, register caps, a fixed 1×2×4 grid on 8× H200 NVL: 8× at
  1 GPU, 6× at 8, but ×8 scaling fell 5.85→4.4.
- **#987**: a register cap of 128 helps IGR on GH200; not merged globally.

**Warning from #2093:** grind is clocked on the CPU from the fastest stage. With async GPU work it is wrong and misses
CPU-side halo waits, so **step or wall time is the honest measure of parallel efficiency.** SC26: source changes go to the
committee ≈2 weeks before 11/16 (the PR thread mentions 10/26).

## General
- Pekkilä et al. 2022 (arXiv 2103.01597): CUDA-aware MPI for high-order stencils.
- Ekelund et al. PDP 2025 (arXiv 2501.09398): CUDA Graphs batching (>1.4× on stencils).
- Sojoodi et al. (arXiv 2604.22228): multi-path UCX + CUDA Graphs (up to 2.95× over cuda_ipc).
- GROMACS NVSHMEM halo (arXiv 2509.21527): 1.5× better strong scaling in a node.
- STREAmS-2 (arXiv 2304.05494), URANOS-2.0 (CPC 2024): WENO restructuring for OpenACC.
