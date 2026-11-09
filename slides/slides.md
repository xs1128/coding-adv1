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

# Result: 1.27× to 2.23× faster, bitwise identical

<figure>
  <img src="/fig/scaling.png" class="h-92" />
  <figcaption>201³ cells, FP64, 30 steps. Each comparison on one node. Jobs 606017 / 621788, 606018 / 622305, 606019 / 622306.</figcaption>
</figure>

<!--
This is the result. Grey is the original version 5.7.0, blue is my final build. The case is MFC's own benchmark: 201 cubed cells, double precision, 30 steps.

On one GPU, the step time goes from 76.7 to 60.4 milliseconds. That is 1.27 times faster. On four GPUs it is 1.35 times, and on eight GPUs 2.23 times.

The eight-GPU number is larger partly because the original, at its default settings, sends halo data through host memory, and my final setup sends it directly between GPUs. I say this up front so the number is not oversold.

Every comparison ran on the same node, and the final state matches the original bit for bit.
-->

---

# Six changes, no physics changed

| Change | Problem | Fix | Gain |
|---|---|---|---|
| P1 | host sync per boundary call | async, wait once | −1.4 % |
| K4b | Riemann helpers not inlined | one translation unit | −7.3 % |
| K2 | WENO at 196 registers | `maxregcount:128` | −10.6 % |
| P3 | ~1.2 ms GPU idle per stage | async kernels | −1.7 % |
| P4 | WENO on unread ghost cells | interior only | −2.5 % |
| `rdma_mpi` | halos through host | GPU→GPU over NVLink | −27 % (4 GPUs) |

<div class="note text-center">

Step time on 1 GPU, 77.06 → 60.38 ms. P3 and P4 gain more at 8 GPUs (P4: −4.0 %).

</div>

<!--
Six changes got there. None of them changes the equations, the grid or the precision.

I started by profiling. Two things stood out. The GPU often waited for the CPU, and the two heavy kernels, the WENO reconstruction and the HLLC Riemann solver, ran poorly.

P1 and P3 remove the waiting. The code synchronized with the host after many small kernels. I made them asynchronous on one stream, with a single wait.

K4b was a compiler surprise. NVHPC only inlines GPU helper routines inside one source file, so HLLC passed its arguments through slow local memory. Compiling those modules as one unit removed every call and saved 7 percent.

K2: WENO used 196 registers, so only a few warps fit on each SM. Capping it at 128 registers doubled occupancy. That was the biggest single gain, about 11 percent.

P4: WENO also computed ghost cells that nothing reads. I checked every consumer, then limited it to the interior.

Finally, `rdma_mpi` sends halos from GPU to GPU over NVLink. That saved 27 percent at four GPUs.
-->

---

# Why it is faster

<figure>
  <img src="/fig/kernels_1g.png" class="h-60" />
  <figcaption>ncu 600146 (v5.7.0) vs 606033 (P3)</figcaption>
</figure>

- WENO5: occupancy doubled. HLLC: helpers inlined.
- Still slow: copy kernels at a third of HBM bandwidth, halo not overlapped.

<!--
This kernel profile shows why. Kernel time drops from 35.1 to 28.2 milliseconds.

WENO falls from 13.7 to 9.6, because occupancy doubled. HLLC falls from 9.1 to 6.4, because its helpers are now inlined.

The bottom bars did not move. Those copy kernels reach only a third of the memory bandwidth, and the halo exchange still does not overlap with compute. Those are the next targets.
-->

---

# Correctness and limits

- Every run: final state bitwise identical to v5.7.0.
- `./mfc.sh test`: 690 pass, 23 fail, 0 new. The same 23 fail on unmodified v5.7.0.
- Tried and rejected: `vector_length`, register cap 96, NVHPC 25.9.
- Next: overlap halo with compute, fuse copy kernels, send PRs upstream.

<div class="note mt-10">

Report `report.md`, patches `patches/opt/`, raw data `results/`

</div>

<!--
Now correctness. Every benchmark run is checked bitwise against the original.

I also ran MFC's full test suite: 690 tests pass and 23 fail. All 23 also fail on the unmodified code in this environment. So I add zero new failures, and I report the 23 instead of hiding them.

Some ideas did not work, for example a lower register cap or an older compiler. I kept those as negative results.

Next, I would overlap the halo exchange with compute, fuse the copy kernels, and send these patches upstream to MFC.

Thank you. I am happy to take questions.
-->
