# Optimization roadmap — MFC on nano4 H200, parallelism first (2026-10-22)

Inputs: measurements in `docs/profiling-baseline.md`; research in `docs/research-halo-overlap.md`,
`docs/research-env-tuning.md`, `docs/research-kernels.md`, `docs/literature.md`. Estimates are marked *est.*;
everything else cites a results path.

## Where the time goes (measured)
- **1 GPU** (201³, case-opt): 0.397 ns grind, 81 ms/step; GPU busy 96 %. WENO 34 %, HLLC 25 %, copy-like kernels
  ≈25 % at ~30 % of HBM bandwidth (instruction-bound), host gaps ≈4 %.
- **8 GPUs strong, host-staged (default)**: 26.0 ms/step median → 3.1× (39 %). Halo = 53 % of a stage.
- **8 GPUs strong, `rdma_mpi=T`**: 16.5 ms/step → **4.9× (62 %)**; weak ≈100 % on grind. Remaining loss per stage
  (5.5 ms vs 3.4 ms ideal): neighbour **wait ≈0.9 ms**, pack/unpack/BC/sync ≈0.33 ms, host gaps ≈0.4 ms,
  transfer ≈0.09 ms.
- **The wait is host-side imbalance**: GPU kernel time is equal on all ranks (3.54–3.61 ms), but the rank owning
  3 CBC (bc=−6) faces spends **+0.9 ms/stage on the host** (tiny CBC kernels + 5 blocking `GPU_UPDATE`s per call).
- **Transport is not the problem**: UCX uses `cuda_ipc` (292 GB/s, 12.5 µs at 1 MB; net/osu_2g).
- **Fixed costs** (outside grind): MPI_Init 2→7–29 s, 996 startup Bcasts, MPI-IO; wall at 8 GPUs ≈2.5× 1-GPU wall
  for a 30-step run.

## Rules for every step
Same case, FP64, grid, steps; bitwise compare of the final state vs the 1-GPU reference
(`harness/compare_state.py`, all baselines are bitwise identical across 1/2/4/8 ranks) + `./mfc.sh test` (1e-12)
for any `src/` change. Metric = **median step time** (nsys NVTX, all ranks) *and* grind; report the first-step
cost separately. Src changes ≤ a few hundred lines, OpenACC + OpenMP paths, upstream-PR-able. Tiny jobs:
1/2/4 GPUs routinely, 8 GPUs only for the confirming run.

## Tier 0 — configuration/tooling (no src change; disclose)  · ~1 day
| # | Change | Evidence / est. gain | Verify |
|---|---|---|---|
| T0.1 | `rdma_mpi=T` (case param) | **measured −37 % step at 8 GPUs** | bitwise ✓ (scale/strong_8g_rdma) |
| T0.2 | ROMIO MPI-IO (`OMPI_MCA_io=romio321`), `mpirun`, no OMPI auto-binding | required to run at all on wekafs | done |
| T0.3 | NUMA-correct pinning wrapper (rank r → cores of GPU r's socket, `numactl --membind`) | est. 0–10 %; targets host-side jitter, which *is* our bottleneck | per-rank RHS−comm spread |
| T0.4 | Cut MPI_Init/Finalize: `OMPI_MCA_coll_hcoll_enable=0`, `OMPI_MCA_coll_ucc_enable=0`, `UCX_NET_DEVICES`/`UCX_TLS=self,sm,cuda_copy,cuda_ipc` (single node), `HWLOC_COMPONENTS=-opencl,-cuda,-nvml` | wall: est. −5…−20 s at 8 ranks; no effect on grind | `osu_init` + job wall; UCX_PROTO_INFO still shows cuda_ipc |
| T0.5 | NVHPC 25.9 vs 26.3 A/B (IGR paper/#2088: newer NVHPC regressed FP64) | est. 0–25 % single-GPU | grind A/B on same node |
| T0.6 | Power: record draw; test perf at lower caps if allowed (SC26 10 kW) | perf/W data point | smi logs already captured |

## Tier 1 — parallel-efficiency source changes (small, PR-able)  · ~3–4 days
| # | Change | Where | Est. gain @8 GPUs | LOC | Risk |
|---|---|---|---|---|---|
| P1 | **Remove blocking host syncs in CBC + fuse its small kernels** (attacks the measured +0.9 ms/stage imbalance) | `m_cbc.fpp` (GPU_UPDATE at ~461, 522, 951, 952, 1189) | −3…−8 % (up to −15 % if the whole imbalance goes) | 100–300 | low, bitwise |
| P2 | **Remove scalar `GPU_UPDATE`s per stage** (mytime, v_size, is*/isx/dir_idx in WENO/Riemann setup) — keep them device-resident or pass by value | `m_time_steppers:468`, `m_weno:945-948`, `m_riemann_state:317-339`, `m_mpi_common:594` | −2…−5 % | 50–150 | low |
| P3 | **Single OpenACC async queue + explicit `wait` before MPI** to hide launch latency (the remaining host gaps) | `parallel_macros.fpp` (`extraAccArgs`), halo routines | −3…−10 % (#2093: 1.11× at 4 GPUs) | 50–200 | medium (grind becomes wrong → use step time) |
| P4 | WENO only on transverse-interior rows + all-dims face exchange with per-direction wait | `m_rhs`, `m_weno`, `m_mpi_common` | −4…−6 % (and −3 % at 1 GPU) | 200–350 | medium (feature allowlist) |
| P5 | Small halo cleanups (x-pack loop order, copy `buffer_count` not max face on host path) | `m_mpi_common:594,826,836` | ~1 % | 30–60 | low; fold into NTHU #2090 |
Not worth it here (measured/est.): per-direction Isend/Irecv (#2090) — at ≤2 ranks per dimension each rank has
one MPI face per dim, so ≈0 gain; MPS (one rank already keeps the GPU 96 % busy); other decompositions (2×2×2
already minimal volume); NVSHMEM/CUDA graphs (vetoed upstream).

## Tier 2 — single-GPU kernel efficiency (sets the compute floor)  · ~2–3 days, overlaps Tier 1
| # | Change | Est. stage saving | LOC | Upstream |
|---|---|---|---|---|
| K1 | collapse(3) + seq variable loop in copy kernels (= NTHU #2087) | −10…−12 % | 8 | approved 10-21 |
| K2 | WENO occupancy: `vector_length(64)` / per-file maxregcount 128–168 / collapse trial | −5…−10 % | 3–6 | flag-only parts need disclosure |
| K3 | Alias `flux_n(1)` → `flux_rsx_vf` (drop finalize copy) + #2092 pack removal | −3.5…−4.5 % | ~34 | new small PR + open draft |
| K4 | HLLC inlining (raise `-Minline` limits for that file; else Fypp-constant `dir_idx`) | −5…−11 % | 0–100 | open (#2094) |
| K5 | #2087 pattern on RK update and α·div(u) source | −2…−3 % | ~40 | follow-up |
Projected 1-GPU grind: 0.397 → ≈0.31–0.33 (K1–K3) → ≈0.27–0.29 ns (+K4) *est.*

## Tier 3 — architectural (only if time remains; not before the deadline)
- Interior/boundary split with comm overlap: 91–96 % of cells overlappable, but each extra box adds 3–6 host
  syncs (~0.6–1 ms) > the 0.42 ms it can hide — **only after P2/P3 remove host syncs**. 700–1200 LOC.
- 26-neighbour single-round exchange with fused pack/unpack (350–550 LOC; −3…−5 % at 8 GPUs).

## Expected outcome (est.)
| | 1 GPU step | 8 GPU step | 8-GPU speedup |
|---|---|---|---|
| baseline host-staged | 81 ms | 26.0 ms | 3.1× |
| + T0 (rdma, measured) | 81 ms | 16.5 ms | 4.9× |
| + P1–P3 | 79 ms | ≈13–14 ms | ≈5.8–6.1× |
| + K1–K4 | ≈58–62 ms | ≈10–11 ms | ≈5.5–6× (comm share grows as kernels shrink) |
Note the #2093 lesson: faster kernels lower parallel *efficiency*; we report both time-to-solution and efficiency.

## Order of work (homework deadline end of Oct; SC26 src changes must be merged upstream by 10-26)
1. T0.3–T0.5 A/B (1–2 GPU-jobs each, ≤10 min) → lock the configuration.
2. K1 (+ coordinate with NTHU's #2087/#2090/#2092 authors — likely classmates; do not duplicate).
3. P1 → P2 → P3, each: patch on branch `opt` in nano4 `mfc/`, export to `patches/`, `./mfc.sh test`, bitwise
   compare, 2-/8-GPU nsys, commit with job ids.
4. K2–K4 as time allows; Tier 3 only as a design write-up.
