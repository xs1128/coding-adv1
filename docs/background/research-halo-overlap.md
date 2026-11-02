# Halo exchange and overlap in MFC: a ranked design study

**What this is.** Background notes from 2026-10-22, the start of the project: a paper study (code read, not changed).
What later happened to each idea is in [ladder](../ladder.md) and [optimizations](../optimizations.md). The measured
inputs are in [profiling-baseline.md](../profiling-baseline.md).

**Setup.** Source: MFC master `1ececa3` (re-check line numbers against v5.7.0 before patching). Upstream status is from
the GitHub API on 2026-10-22, which hit its rate limit, so a few searches are missing. Case: 3D_performance_test,
5-equation, 2 fluids (8 variables), WENO5, HLLC, RK3, FP64; reflective walls at the low end, CBC at the high end; 4 ghost
layers.

**Words used below.**
- *Rank*: one copy of the program, one per GPU, owning one box of the grid.
- *Halo / ghost cells*: to update the edge of its box, a rank needs a thin layer of its neighbour's cells, like needing
  the edge of the next jigsaw piece. *Halo exchange*: copying those layers between ranks.
- *MPI*: the library ranks use to message each other. *Sendrecv*: a send+receive that blocks until done.
  *Isend/Irecv + Waitall*: start several messages, then wait for all.
- *RDMA / CUDA-aware MPI*: send straight from GPU memory, instead of copying through the CPU ("host-staged").
- *Overlap*: keep the GPU computing while messages travel. *Host sync*: the CPU stops to wait for or update the GPU.
- *Kernel*: one GPU program launch. *WENO / HLLC*: the face-reconstruction and face-flux steps. *RK stage*: one of 3
  sub-steps per time step. *CBC*: an "open" boundary that lets waves leave; it costs many small kernels.

## 0. What the code does today

### 0.1 One RK stage
Copy the state, convert to primitive variables, do **one halo exchange of the 8 variables**, then for x, y and z run WENO,
HLLC, CBC and the flux difference, then the RK update. **Every kernel is synchronous**: no `async` in the RHS, although
the `GPU_*` macros could pass it.

### 0.2 Halo exchange
Faces are done **strictly in order**: x−, x+, y−, y+, z−, z+. A real wall runs one BC kernel. A face shared with another
rank does: a host sync of `v_size` on **every call**; a pack kernel (the x pack reads memory in a poor order); one
blocking `MPI_SENDRECV` (host-staged, it copies the **whole** largest-face buffer, not just the used part); an unpack
kernel.

**Corners depend on the order.** The y exchange also carries x ghosts, and z carries both, so corners fill in 2 or 3
hops and directions must stay in order (unless corners are sent directly to all 26 neighbours). Our case reads corner
ghosts only in wasted WENO work; HLLC uses only the interior. Viscosity, surface tension, IB and a few other features
really need corners.

**Who talks to whom.** With 2 ranks per direction, a rank has **at most one MPI face per direction**. At 8 GPUs (2×2×2)
every rank has 3 MPI faces and 3 wall faces. Rank (0,0,0) owns 3 reflective faces; rank (1,1,1) owns 3 CBC faces.

### 0.3 How the grid is split
MFC picks the most cube-like split, with no user override: **2×1×1, 2×2×1 and 2×2×2** for 2, 4 and 8 GPUs. Leftover cells
go to the low corner, so rank (0,0,0) has 101³ cells (+3 %) while the CBC-heavy rank (1,1,1) has 100³.

### 0.4 Other facts
- `rdma_mpi` is **forbidden** in OpenMP-offload builds (`simulation/m_checker.fpp:45-47`), so that path is always
  host-staged, and new code must keep both paths.
- Each CBC face adds 5 host syncs and about 12 small kernels; WENO, Riemann and reconstruction add about 20 more host
  syncs per stage.

## 1. Time budget (8 GPUs, RDMA, rank 0, per RK stage)

| bucket | ms |
|---|---|
| stage (16.5 ms step / 3) | **5.50** |
| kernels | 3.5 |
| Sendrecv, actual transfer (2.6–3.0 MB over NVSwitch) | ≈0.09 |
| Sendrecv, **waiting for the neighbour** | ≈0.93 |
| pack/unpack/BC kernels + syncs | ≈0.33 |
| host gaps in the RHS (launch delays, small syncs) | ≈0.40 |
| outside the RHS | ≈0.25 |
| ideal (1-GPU stage / 8) | 3.38 (now 4.92×, 62 %) |

Only 0.09 ms of the 1.35 ms of comm moves data; about 70 % is **waiting**. Rank 0 is the lightest rank (0 CBC faces)
and waits for CBC-heavy neighbours; unpinned CPU threads probably add jitter. The slowest rank sets the pace, so overlap on
rank 0 cannot remove the wait. Only two things help: cheaper comm on the **heavy rank** (≈0.42 ms, the ceiling for any
pure-halo idea) or less **imbalance** (ceiling ≈0.9 ms). **First measurement to do:** nsys on rank 7 vs rank 0, to split
imbalance from jitter.

Unmeasured estimates with RDMA: 4 GPUs **≈3.1× (78 %)**, 2 GPUs **≈1.93× (96 %)**.

## 2. Options

### Option 1: turn on `rdma_mpi`, plus UCX and CPU-binding tuning (no code)
**Measured at 8 GPUs:** step 26.0 → 16.5 ms (−37 %); speedup 3.12 → 4.92; weak scaling 73 % → ≈100 %; bitwise identical.
Further tuning (est. 0–3 %, more if jitter is a big part of the wait): pin each rank to the CPU socket next to its GPU
(today nothing is pinned), and keep UCX (the transport under MPI) on GPU-to-GPU paths. The 175 ms first step is a
one-off link setup. RDMA is OpenACC-only; making it the default upstream is a change maintainers may refuse.

### Option 2: send faces at the same time
- **2a. Per direction** (upstream #2090 by NTHU, draft): Isend/Irecv both sides, then Waitall. With our splits a rank has
  at most one MPI face per direction, so **≈0 % at 2/4/8 GPUs** here. It helps only with ≥3 ranks per direction (#2090
  claims −9 to −12 % at 3–6 ranks). #2090 has failing OpenMP MPI tests and no review yet. If it is our team's PR, fix and
  land it first; do not duplicate it.
- **2b. All directions in one round, sending edges and corners directly (26 neighbours).** Post every neighbour message
  at once, wait, then apply wall BCs in x→y→z order. Corners get the same function on the same input as today, so it stays
  bitwise identical; unusual BCs fall back to the old path. **≈350–500 LOC.** It removes 2 of 3 back-to-back round trips:
  **−1–3 % at 8**, 0 at 2. Risks: deadlocks or mixed-up messages (needs unique tags), unusual BCs, buffer offsets.

### Option 3: fewer syncs and fused pack/unpack
- **3a. Small clean-ups (~30–60 LOC):** pass `v_size` as a kernel argument; reorder the x pack loops; copy only the used
  part of the buffer when host-staged (−14 % bytes on x). ≈1 % at 8 with RDMA, more host-staged. Very low risk.
- **3b. With 2b: one gather and one scatter kernel for all neighbours** (#2093's "halo index cache"). **2b+3b: −3–5 % at
  8, −1–2 % at 4, ≈0 at 2.**

### Option 4: compute while messages travel
**4a. Interior first, boundary later (the classic way).** WENO5 needs 3 cells each side, so "interior" means cells at
least 3 from every MPI face: 91.3 % of cells at 101³ per GPU, 95.6 % at 201³ (83 % and 91 % if all 6 faces were MPI).
**Show-stopper today:** each WENO/Riemann call does small host syncs, so splitting into boxes adds about 60–100 syncs
per stage (~0.6–1 ms), **more than the 0.42 ms it can hide**. Gain −2–5 % at 8
only after option 9 (negative before). **700–1200 LOC, high risk. Not recommended for SC26.**

**4b. Skip unused sideways ghosts in WENO, then overlap per direction (cheaper, and a compute win).** Run WENO over the
sideways interior only, guarded by an allowlist (inviscid, no surface tension, no IB, cartesian, …) because those
features read sideways ghosts. WENO work shrinks by **9.2 % at 1 GPU, 12 % at 2, 16 % at 4, 19 % at 8**: about −3–4 % at
every GPU count. Without corner reads, all faces can go at once, hiding y/z transfers behind the x sweep. **Total −4–6 % at 8, −3 % at
1**, about 200–350 LOC. Risks: an incomplete allowlist (tests fail loudly, not silently); stale ghost corners (not in
the output); overlap with #2092's edits.

### Option 5: fewer exchanges or less data
Exchanging conserved instead of primitive variables: same 8 variables, **0 %**. 3 ghost layers instead of 4: 25 % less
data but **< 1 %** (transfer is only 0.09 ms) and `buff_size` is shared with many features. One exchange per stage is
already the minimum. **FP32 halo: changes the numerics, forbidden.**

### Option 6: NVSHMEM, CUDA Graphs, MPS
- **NVSHMEM** (GPUs write straight into each other's memory): ceiling 2–7 % at 8. #2093 claimed +7–25 % with 8× faster
  kernels. NVIDIA-only C++ backend; maintainers rejected exactly this ("no chance"). **Do not pursue.**
- **CUDA Graphs** (record a batch of launches, replay it cheaply): would remove the ~0.4 ms host gaps (up to −7 % at 8),
  but MPI cannot be recorded and it is NVIDIA-specific. **Do not pursue** upstream; option 9 gets most of it portably.
- **MPS, 2 ranks per GPU** (no code): one rank fills the other's waits, but extra WENO work and comm grow. −5 % to
  +10 %, uncertain; worth one short run.

### Option 7: grid split and load imbalance (201³ strong)

| split | MB/rank | CBC faces max/min | WENO extra | interior |
|---|---|---|---|---|
| 2×1×1 (default, 2 GPU) | 10.3 | 3/2 | 12.3 % | 97 % |
| 2×2×1 (default, 4 GPU) | 10.8 | 3/1 | 15.6 % | 94 % |
| **2×2×2 (default, 8 GPU)** | **8.5** | **3/0** | **18.9 %** | 91 % |
| 1×2×4 (NTU choice) | 14.3 | 3/1 | 22.0 % | 85 % |
| 1×1×8 slabs | 22.4 | 3/2 | 30.8 % | 76 % |

The default **2×2×2 is best** on data, WENO extra work and interior share; with RDMA, data volume barely matters anyway.
Its weak spot is the CBC spread (3 vs 0), which fits the ~0.93 ms wait. Other splits even out CBC but cost +3–12 % WENO
work: likely a net loss. **Better: shift cells** with an optional process-grid or cut setting
(today impossible). About 80–200 LOC; at most −3–8 % at 8. Decide only after the per-rank measurement in §1.

### Option 8 (new, the biggest halo-related lever): make CBC cheaper on boundary ranks
Turn the 5 host syncs per CBC call into kernel arguments and fuse the CBC staging copies. This shrinks the slowest rank
directly; same idea as #2093's `--cbc-no-host-sync`, but small, portable and default-on. **≈100–300 LOC; −3–8 % at 8**,
−1–3 % at 2/4, ~1 % at 1 GPU. Low risk, bitwise identical.

### Option 9 (enabler): remove small host syncs in the RHS
The 0.40 ms "host gap". About 150–300 LOC; −2–5 % at 8. Needed before 4a or any async work.

## 3. Upstream status
#2089 (issue) shows median Sendrecv 4.4 µs vs mean 92 µs: the cost is waiting. #2090 is a draft with failing tests.
#2093 was **closed and rejected**: ~5× over the 5000-line guideline, vendor-only code; maintainers want changes "under 1k
lines of additions".

So: PRs under 1k added lines, portable, byte-identical, with multi-rank 3D evidence (≥3 ranks per direction for exchange
PRs). **SCC source deadline: 2026-10-26.** The 26-neighbour round and overlap are unclaimed in mergeable form; NVSHMEM
and graphs are effectively vetoed.

## 4. Ranked recommendation

Gains against the RDMA baseline (5.50 ms/stage at 8); 2/4-GPU baselines are estimates.

| rank | option | est. gain 2 / 4 / 8 GPU | LOC | risk |
|---|---|---|---|---|
| 1 | **O1** `rdma_mpi=T` (+ binding, UCX) | measured −37 % at 8; tuning 0–3 % more | 0 | none |
| 2 | **O8** cheaper CBC | −1 / −2 / **−3–8 %** | 100–300 | low |
| 3 | **O4b** skip sideways ghosts + faces-only exchange | −4 / −4–5 / **−4–6 %** | 200–350 | medium |
| 4 | **O2b + O3b** 26-neighbour round + fused pack | 0 / −1–2 / −3–5 % | 350–550 | medium |
| 5 | **O9** host-sync removal | −1 / −2 / −2–5 % | 150–300 | low |
| 6 | **O3a** small clean-ups | ~0 / <1 / ~1 % | 30–60 | very low |
| 7 | **O7** user-set grid | 0 / ? / −3–8 % if imbalance confirmed | 80–200 | low |
| 8 | **O2a** #2090 | 0 / 0 / 0 here | 174 | low |
| 9 | **O4a** interior/boundary split | ~0 / −1–3 / −2–5 % (negative before O9) | 700–1200 | high |
| 10 | **O6** MPS | −5…+10 % | 0 | low |
| 11 | **O5** 3 ghost layers | <1 % | ~50 | medium |
| 12 | **O6** NVSHMEM / graphs | ≤2–7 % | >1000 | **vetoed** |

**Realistic set before 10-26:** O1 + O8 + O3a + (O4b or O2b) ≈ −0.5 to −1.0 ms/stage at 8 GPUs, about **5.4–6.0×
(67–75 %)** vs 4.92× now.

**Checks for every source change:** full `./mfc.sh test` (also `--rdma-mpi`); multi-rank runs with periodic, reflective
and CBC walls, including odd rank counts; bitwise compare against 1 GPU; an OpenMP build; per-rank step time (not grind);
a long hang check.
