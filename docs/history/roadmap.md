# Optimization roadmap: MFC on nano4 H200, parallelism first (2026-10-22)

> Historical: the plan as written in October 2026; what actually happened is in [../../report.md](../../report.md)
> and [../ladder.md](../ladder.md).

Based on [profiling-baseline.md](../profiling-baseline.md) and the research in
[research-halo-overlap.md](../background/research-halo-overlap.md),
[research-env-tuning.md](../background/research-env-tuning.md),
[research-kernels.md](../background/research-kernels.md) and [literature.md](../background/literature.md).
Guesses are marked *est.*; everything else is measured.

## Where the time goes (measured)
The simulation moves in steps; each step has stages. With several GPUs, each GPU owns one block of the grid and
swaps its border cells (the "halo") with its neighbours every stage. Kernels are the small programs the GPU runs.
- **1 GPU:** 81 ms per step; the GPU is busy 96 % of the time. The WENO and HLLC kernels take 34 % and 25 %.
- **8 GPUs, data sent through the CPU (default):** 26.0 ms per step, only 3.1× faster. The halo swap takes 53 %.
- **8 GPUs, sending GPU to GPU directly (`rdma_mpi=T`):** 16.5 ms per step, **4.9×**. The biggest loss left is
  waiting for neighbours (≈0.9 ms per stage).
- **That wait comes from uneven CPU work.** GPU time is the same on every rank (process). But the rank that owns
  the special open boundaries (CBC) spends **+0.9 ms per stage on the CPU**, and the others wait for it.
- **The link is not the problem:** GPU-to-GPU transfer runs at 292 GB/s.

## Rules for every step
Same case, grid, steps and FP64 math. The final state must match the 1-GPU answer bitwise (to the last bit).
Code changes must pass MFC's tests and be fit to send back to MFC.

## Tier 0: settings only (disclosed) · ~1 day
- **T0.1** `rdma_mpi=T`: **measured −37 % step time at 8 GPUs**, bitwise.
- **T0.3** Tie each process to the CPU next to its GPU: est. 0–10 %. It targets CPU jitter, which *is* our
  bottleneck.
- **T0.4** Faster MPI start-up: est. −5…−20 s of wall time; no effect on grind.
- **T0.5** Older vs newer compiler as an A/B (both on one node): est. 0–25 %.

## Tier 1: small code changes for multi-GPU speed · ~3–4 days
Gains are *est.* at 8 GPUs.
- **P1** Remove blocking CPU–GPU waits in CBC and merge its small kernels: −3…−8 %, up to −15 % if the whole
  imbalance goes.
- **P2** Stop copying single values between CPU and GPU every stage: −2…−5 %.
- **P3** Queue GPU work without waiting, and wait only before MPI: −3…−10 %.
- **P4** Skip WENO work that is not needed: −4…−6 %.
- **P5** Small halo clean-ups: ~1 %.

## Tier 2: faster single-GPU kernels · ~2–3 days
Savings are *est.* per stage.
- **K1** Better loop layout in copy kernels (same as NTHU's upstream change #2087): −10…−12 %.
- **K2** Keep more GPU threads busy in WENO: −5…−10 %.
- **K3** Drop an extra copy: −3.5…−4.5 %.
- **K4** Inline HLLC's helper functions (paste them into the caller): −5…−11 %.

Projected 1-GPU grind with K1–K4: 0.397 → ≈0.27–0.29 ns *est.*

## Tier 3: bigger redesigns (only if time remains)
Compute the inside of each block while the border is in transit. Each extra piece adds CPU–GPU waits that cost
more than it hides, so **only after P2/P3**.

## Expected outcome (est.)
| | 1 GPU step | 8 GPU step | 8-GPU speedup |
|---|---|---|---|
| baseline | 81 ms | 26.0 ms | 3.1× |
| + T0 (measured) | 81 ms | 16.5 ms | 4.9× |
| + P1–P3 | 79 ms | ≈13–14 ms | ≈5.8–6.1× |
| + K1–K4 | ≈58–62 ms | ≈10–11 ms | ≈5.5–6× |

Faster kernels lower parallel *efficiency*: communication becomes a bigger share.

## Order of work (homework due end of Oct)
1. A/B T0.3–T0.5 in short jobs, then lock the settings.
2. K1, coordinating with its NTHU authors (likely classmates) so we do not duplicate work.
3. P1 → P2 → P3, each tested, compared bitwise and committed with job ids.
4. K2–K4 as time allows; Tier 3 only as a written design.
