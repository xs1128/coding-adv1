# Single-GPU kernel plan for MFC on H200

**What this is.** Background notes from 2026-10-22, the start of the project. Nothing here was built or run when it was
written. What later happened to each idea is in [ladder](../ladder.md) and [optimizations](../optimizations.md).

**Setup.** Case: 5-equation model, WENO5, HLLC, RK3, FP64 (double precision). Source read: MFC master 1ececa3, about 2
weeks after v5.7.0; paths are under `src/` unless they start with `cmake/`. The full #2093 text is in
[refs/PR.md](refs/PR.md).

**Words used below.**
- *Kernel*: a small program the GPU runs on many grid cells at once.
- *Register*: the fastest scratch slot on the chip. Each SM (a GPU processor block) has a fixed pool, so the more each
  thread uses, the fewer threads fit. *Warp*: a team of threads in lockstep. *Occupancy*: how many warps fit; more warps
  hide waiting, because while one team waits for data another works.
- *Spill / stack*: values that do not fit in registers go to much slower "local" memory.
- *WENO*: rebuilds values at cell faces from nearby cells. *HLLC* (a *Riemann solver*): works out the flow through each
  face from its two sides.
- *RK stage*: one of 3 sub-steps per time step. *Grind time*: nanoseconds per cell per equation per sub-step; lower is
  better; our main score.
- *HBM*: the GPU's main memory. *Floor / roofline*: the best time possible given the bytes to move or the math to do.
- *ncu*: NVIDIA's kernel profiler. *Fypp*: MFC's code generator. *OpenACC / OpenMP*: two ways to run loops on the GPU;
  MFC must keep both. *Bit-identical*: answers match to the last bit. *PR*: a proposed change to upstream MFC.

## 0. Rules that shape the ranking

- **Deadline.** wilfonba wrote in #2093 that SCC source changes must be **merged upstream by 2026-10-26**.
- **Size.** Guideline ±5000 lines; danieljvickers expects most changes "under 1k lines of additions".
- **Rejected:** big rewrites; `#ifdef` and opt-in switches; NVIDIA- or OpenACC-only modules; hand-inlining through Fypp
  (#2095, "too cumbersome", even though bit-identical with grind −11.7 %); a global `maxregcount` with no architecture
  guard and no data across schemes and GPUs (#987).
- **Accepted:** small, default-on, bit-identical loop changes such as #2087 (+8 LOC, approved 10-21).
- **Every change must** pass `./mfc.sh test` at 1e-12, keep the OpenMP path, and leave the numerics alone. Anything that
  reorders a division or a sum is flagged. Flag-only changes are allowed in the competition but must be disclosed.

**Upstream on 2026-10-22.** #2087 (NTHU, collapse(3) in copy loops): approved. #2092 (NTHU, WENO reads its input
directly): draft. #2094 (NTHU issue): calls across files give HLLC a 528–576 B stack; inlining gives 2.45→1.42 ms. #2093
(NTU, mega-fusion, +27k LOC): closed, "no chance of ever being merged". #987 (`maxregcount`): closed, "guard by device
type". No merged HLLC fix or register-cap PR exists.

## 1. Time budget per stage

ncu at a locked 1.48 GHz, per RK stage. One variable is 201³ × 8 B = 65 MB. The memory floor assumes 4.2 TB/s (88 % of
4.8 TB/s).

| Kernel (file:line) | ×/stage | ncu ms | Floor ms | What limits it now | Target ms |
|---|---|---|---|---|---|
| WENO5 `m_weno.fpp:1096` | 3 | ~4.66 (34 %) | 0.40 memory; **~1.45 FP64** | chains of dependent FP64 math; 8 warps/SM | 2.2–3.3 |
| HLLC `m_riemann_solver_hllc.fpp:900` | 3 | ~3.42 (25 %) | 0.46 | **stack in local memory** from 140 calls | ~1.8 |
| WENO input pack `m_weno.fpp:893` | 3 | 0.81 | 0.28 | instructions | 0 (remove) |
| Riemann finalize `m_riemann_state.fpp:1342` | 3 | 0.72 | 0.25 | instructions | 0 (alias) |
| q_cons copy `m_rhs.fpp:602` | 1 | 0.89 | 0.28 | instructions | 0.30 → 0 |
| flux difference `m_rhs.fpp:1127` | 3 | ~0.95 | 0.25 / 0.37 | instructions; a divide per element | 0.30–0.45 |
| RK update `m_time_steppers.fpp:497` | 1 | 1.19 | 0.50–0.62 | instructions; a divide per element | 0.6 |
| cons→prim | 1 | 0.75 | 0.19 | heavy calls, 102 regs | 0.35 |
| Other (boundaries, sources, syncs) | — | ~6.5 | — | mixed | — |
| **Stage total** | | **≈41** | | | |

ncu overstates real time (it empties caches and locks clocks). NTHU measured master on an H200 with NVHPC 26.3 at
**0.417 ns grind**, about 27 ms per stage. Savings below are fractions of the ncu stage, applied to 0.417 ns.

## 2. Each idea

### 2.1 Register caps (WENO / HLLC)

An SM has 64 K registers, handed out 256 per warp. WENO now uses 188–196 per thread, so only 8 warps fit (12.5 %; we
measured 12 %). Blocks of 64 threads instead of 128 fit 10 warps with no spill risk. Caps of ≤168, ≤128 and ≤96 fit 12,
16 and 20 warps. HLLC uses 127–160 (12–16 warps), so a 128 cap only helps its 160-register sweeps.

Very likely the compiler keeps 27 FP64 coefficients (about 54 registers) outside WENO's variable loop. A cap trades
re-loading them from cache for more warps. That should be cheap: WENO is not memory-bound (DRAM 10 %), and more warps
hide its waits.

- **W1. `vector_length(64)` on the WENO loops** (through `extraAccArgs`). 8 → 10 warps, same registers, no spills, OpenMP
  untouched, bit-identical, about 3 LOC. **Expected WENO −8 to −15 %.**
- **W2. A register cap for the `m_weno` file only** (flag-only; disclose), using the existing per-file `COMPILE_OPTIONS`
  pattern with `APPEND` (otherwise other files' `-Mnoinline` is wiped). Try 168, 128, 96 with W1. **Expected WENO −10 to
  −30 %** if spills stay under about 50 B per thread.
- **W3. Experiment: `collapse(4)` for WENO5**, one thread per (variable, cell). Still bit-identical; drops the
  54-register block and may reach ≤128 regs with no cap. Keep only if WENO gets faster.
- **HLLC caps: low value until §2.4 is fixed.** HLLC stalls on stack traffic (0 spill requests), not register pressure;
  a cap can only add spills. Expected 0 to −8 %. #2093's 1.70→1.38 ms with a 168 cap was on its rewritten, call-free
  HLLC and **does not transfer** to ours.

**Cheap sweep** (about one hour of compiling, one GPU-hour of runs): recompile the WENO (and HLLC) file with
`-gpu=maxregcount:{255,168,128,96}` and W1/W3; `-gpu=ptxinfo` prints registers, spills and stack. Drop any variant that
spills more than about 64 B per thread. Build the survivors, then compare grind over at least 3 interleaved runs at real
clocks. Caps do not change results, so one `./mfc.sh test` on the final setting is enough.

### 2.2 Whole-array copies that could go

- **WENO input pack.** A plain copy; #2092 makes WENO read the source arrays directly. **It interacts with #2087:** on
  master removal nets −6.1 % (the pack is 7.7 % of kernel time, but WENO gets 5–6 % slower from extra address lookups).
  After #2087 the pack is about 45 % cheaper, so the net is **about −1.5 to −2 %**.
- **Riemann finalize copy.** **Doable as a pointer alias**: let `flux_n` point at the Riemann output instead of copying
  it, with no kernel change (the layouts match). About 25–35 LOC. All readers stay inside the shared range, including CBC
  (which edits boundary fluxes in place); the qbmm reader still needs an audit. **Bit-identical, frees 0.58 GB, works for
  every Riemann solver.**
- **q_cons copy.** **Only partly removable**: the copy must stay for some features (`mpp_lim .and. bubbles_euler`), and
  IBM, relativity, probes and output need an audit. 10–30 LOC for about 1 % after #2087: do it last.

### 2.3 Copy kernels slowed by bookkeeping, not memory

These kernels should be limited by memory speed, but `collapse(4)` makes every element its own loop step. Each step
recovers its indices with divide/modulo (64-bit), walks two Fortran array descriptors, and in the flux difference
computes `1/dx(k)`. That is roughly 60–100 instructions per 16 B moved, which is why they reach only 30–37 % of DRAM peak.

- **#2087 fixes exactly this** (`collapse(3)` with a `seq` variable loop). NTHU measured −40 to −49 % kernel time and
  −5.4 to −10.3 % grind, bit-identical. **Build on it, do not redo it.**
- **Extend it** to the RK update (1.19 ms → about 0.6 ms; its divide must stay a divide) and the α·div(u) sources: one
  follow-up PR of about 40 LOC.
- **One flat 4D array instead of derived types** would touch thousands of lines. **Not feasible by 10-26**, and after
  #2087 the gain is ≤3 %.

### 2.4 HLLC: the largest single item (25 % of the stage)

- **Main cause** (#2094, on our compiler and matching our 127–160 regs): the kernel makes 140 calls to helpers in other
  files. Small arrays are passed by reference, which forces a 528–576 B stack in slow local memory. The build extracts
  these helpers but does not *inline* them (paste their code into the kernel).
- **Smaller cause:** `vel_L(dir_idx(1))` uses an index known only at run time, which keeps `vel_L`/`vel_R` out of registers.
- **H1, flags only: try first.** Search the build log (`-Minfo=inline` is on) for HLLC's "not inlined" reasons. If it is
  a size or level limit, raise it with `-Minline` options for that file only. **Success:** stack from about 550 B to under
  64 B, HLLC from about 2.7 ms to about 1.4 ms. Run the full test: NVHPC has miscompiled after inlining before
  (`m_pressure_relaxation`).
- **H2, source.** Replace `dir_idx(1..3)` with Fypp constants per direction. About 100 mechanical lines, bit-identical,
  smaller than #2095, but it does **not** fix the stack alone. HLLC −5 to −15 %.
- **H3, an include file instead of Fypp macros**: no time to negotiate. Post-SCC.

### 2.5 Fusion, short of #2093

*Fusion* merges kernels so data skips a round trip through memory.
- **F1. Finalize folded into the HLLC write** (the §2.2 alias): ~1.0 ms after #2087. **Do it.**
- **F2. One flux-difference + source kernel after all three directions**, keeping the exact sum order; +1.2 GB memory;
  ~0.6–0.9 ms; 60–100 LOC. Optional; must prove bit-identity everywhere.
- **F3/F4.** Flux difference into the RK update (touches every physics path for about 1 %: **no**); q_cons copy into
  cons→prim (~0.3 ms, low priority).
- **F5. WENO and HLLC fused without shared memory**: doubles FP64 work in a kernel already limited by FP64. **No.** With
  shared memory it is #2093, which was rejected.

### 2.6 Compiler flags and toolchain (disclose all)

- **`-gpu=fastmath`**: 0–2 %; mostly changes FP32. **Not worth disclosing** unless above 2 %. `-O3`/`-O4` and the
  metadata flags: ~0.
- **Per-file `maxregcount`**: WENO 10–30 % (W2). **Per-file `-Minline` limits**: HLLC up to −45 % (H1), the
  **highest-value flag experiment**.
- **NVHPC version**: unknown, possibly large. NTHU found 25.9 ≈ 26.3. The IGR paper used 24.3 because newer releases got
  slower at FP64; 24.7 is on nano5.
- **Global `maxregcount`: do not use.** It hurts the other kernels (the #987 objection).

## 3. Ranked plan

Savings are fractions of the ncu stage, applied one after another, from 0.417 ns.

| Rank | Change | Stage saving | LOC | Risk |
|---|---|---|---|---|
| 1 | **#2087** collapse(3) in copy loops | **−10 to −12 %** | +8 | very low; approved |
| 2 | **WENO occupancy** W1 + W2 + W3 | **−5 to −10 %** | 3–6 | low; W2 flag-only |
| 3 | **Finalize alias** + **#2092** | **−3.5 to −4.5 %** | 30 + 4 | low–medium |
| 4 | **HLLC inlining** (H1), else H2 | **−5 to −11 %**; H2 alone −1 to −3 % | 0 / ~100 | medium; miscompile precedent |
| 5 | #2087 pattern on RK update and sources | −2 to −3 % | ~40 | very low |
| 6 | NVHPC 24.7 vs 26.3 | unknown (0 to −15 %?) | 0 | compile risk |
| 7 | F2 fused flux difference | −1.5 to −2 % | 60–100 | medium; post-SCC |
| 8 | q_cons alias, F4 | −1 to −2 % | 10–30 | medium; post-SCC |
| 9 | `-gpu=fastmath` | 0–2 % | 0 | not recommended |

**Projected grind:** ranks 1–3 ≈ **20–25 %** → **≈0.31–0.33 ns**; plus rank 4 → **≈0.27–0.29 ns**. That is below the
published GH200 figure (0.32). Afterwards the copy kernels would sit at 70–85 % of the HBM roofline and WENO at about
45–65 % of the FP64 pipe, still the largest item. Going further needs fusion (#2093's 2.6×), out of scope for 10-26.

## 4. Suggested order of work (4 days)

Day 0: rebase on #2087 + #2092, register sweep, HLLC inlining reasons. Day 1: finalize alias and follow-up, test,
draft PRs. Days 1–2: A/B the W and H options. Day 3: freeze, re-test at 1e-12, record flags for disclosure.
