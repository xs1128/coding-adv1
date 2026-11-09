---
theme: default
title: MFC on nano4 H200
info: Coding-Adv-HW-1. Source of every number is report.md and results/.
colorSchema: light
aspectRatio: 16/9
canvasWidth: 980
transition: none
highlighter: shiki
lineNumbers: false
drawings:
  enabled: false
fonts:
  sans: Times New Roman
  serif: Times New Roman
  mono: Inconsolata
  provider: none
layout: cover
background: '#ffffff'
class: text-center
---

# Making MFC faster on H200 without changing its answer

CS5434 High Performance Computing, Coding-Adv-HW-1

<div class="note mt-10">

MFC v5.7.0, SC26 Student Cluster Competition application, nano4 (8× H200)

</div>

<!--
Hi, I am xs. For the coding part I chose MFC, a fluid dynamics code from the SC26 Student Cluster Competition, and I ran it on the H200 GPUs of nano4. My goal was simple: make it faster without changing a single bit of its answer.
-->

---

# Result: 2.7× faster per step, bitwise identical

<figure>
  <img src="/fig/scaling.png" class="h-92" />
</figure>

<div class="note text-center">

1 GPU: step 76.9 → 28.2 ms (2.73×), whole run 7.76 → 2.78 s (2.79×) · 4 GPUs: 23.1 → 7.9 ms (2.93×), 11.89 → 4.60 s (2.58×)
Grind time, MFC's own score figure (ns per grid point per equation per RHS): 0.397 → 0.145

</div>

<!--
This is the result. Grey is the original version 5.7.0, blue is my final build. The case is MFC's own benchmark: 201 cubed cells, double precision, 30 steps.

On one GPU the step time goes from 76.9 to 28.2 milliseconds, which is 2.73 times faster. On four GPUs, with the same setting on both sides, it is 23.1 to 7.9 milliseconds, 2.93 times.

The right panel is the whole run, start-up and saving included: 7.76 to 2.78 seconds on one GPU, and 11.89 to 4.60 seconds on four.

MFC also reports its own score figure, the grind time, nanoseconds per grid point per equation per right-hand-side call. That goes from 0.397 to 0.145.

Every comparison ran on the same node in the same job, and the final state matches the original bit for bit.

An earlier same-node A/B on a different node, job 690631, measured 77.74 to 28.36 milliseconds per step and a grind time of 0.402 to 0.146 — the same result, since the baseline moves a little from node to node.
-->

---

# What we changed: 31 patches, no physics touched

| Group | Patches | What it does |
|---|---|---|
| Stop copying | 0007–0009, 0011, 0023, 0024 | read an array where it is instead of copying it first |
| Merge passes | 0010, 0016, 0017, 0022 | one pass over the grid instead of four |
| Prefetch | 0020, 0021 | load the next values while still working on these |
| Remove host waits | 0013, 0019, 0025–0031 | the CPU stops blocking on the GPU |
| Build and flags | 0002–0005, 0012, 0014, 0018 | register caps, one translation unit |

<div class="note text-center">

Same equations, same grid, same step count, same FP64. One patch per change, in `patches/opt/`.

</div>

<!--
Thirty-one small patches got there. None of them changes the equations, the grid, the step count or the precision. One patch is one change, so each one can be reviewed and reverted on its own.

The first six were the October report. The interesting part is what came after.

Most of the gain is memory traffic, not mathematics. The code kept copying arrays it could simply read where they were, and it walked over the grid several times when one pass would do. So the biggest groups are: stop copying, and merge passes.

Two patches prefetch: the fused kernels load the next variable's stencil, or the next equation's values, while they are still computing the current one.

The last group removes the places where the CPU blocked waiting for the GPU, mostly in the boundary code, which matters more on several GPUs.
-->

---

# Why it is faster

<figure>
  <img src="/fig/ladder_1g.png" class="h-60" />
</figure>

- Profile first: WENO5 34 % and HLLC 25 % of a stage; copy-like kernels ≈25 % at a third of memory bandwidth
- Register caps and one translation unit fixed occupancy and inlining
- Still open: the copy kernels, and the halo exchange does not overlap with compute

<!--
Here is the same measurement, rung by rung. Each rung is its own comparison on one node, and every one of them is bitwise identical to the original. The v5.7.0 bar is re-measured in each job, so it moves between 76.7 and 77.7 milliseconds depending on the node.

I started from a profile. Two things stood out. The two heavy kernels, the WENO reconstruction and the HLLC Riemann solver, ran badly, and the GPU often waited for the CPU.

WENO used 196 registers, so only a few warps fit on each streaming multiprocessor. Capping it at 128 doubled the occupancy. That was the biggest single gain.

HLLC was a compiler surprise. NVHPC only inlines GPU helper routines inside one source file, so HLLC passed its arguments through slow local memory. Compiling those modules as one translation unit removed every call.

The bottom bars did not move. Those copy kernels reach only a third of the memory bandwidth, and the halo exchange still does not overlap with compute. Those are the next targets.
-->

---

# Correctness and limits

- Every run: final state bitwise identical to v5.7.0 (65 M numbers)
- Full MFC suite on the final build: 713 tests, **690 pass, 23 fail** — exactly the 23 that fail on unmodified v5.7.0, same errors, **0 new**
- 7 more patches measured but **not** suite-validated (`patches/pending/`); the headline does not use them
- The 10-31 report's 8-GPU number compares v5.7.0 at its defaults against our `rdma_mpi`, so it is asymmetric
- Next: overlap halo with compute, fuse the copy kernels, send the patches upstream

<div class="note mt-10">

Report `report.md`, patches `patches/opt/`, raw data `results/`

</div>

<!--
Now correctness, which is the part I care most about.

Every benchmark run is checked bitwise against the original: 65 million numbers, every bit the same.

I also ran MFC's full test suite on the final build: 713 tests, 690 pass, 23 fail. All 23 also fail on the unmodified code in this environment, with the same errors. So I add zero new failures, and I report the 23 instead of hiding them.

Two limits I want to be upfront about. Seven further patches are measured and faster, but their full test suite has not been run, so they are not part of the headline number. And the eight-GPU figure in the October report compares the original at its default settings against my setup, which sends halos straight between GPUs, so that number is flattered.

Some ideas did not work, for example a lower register cap or an older compiler. I kept those as negative results.

Next, I would overlap the halo exchange with compute, fuse the copy kernels, and send these patches upstream to MFC.

Thank you. I am happy to take questions.
-->
