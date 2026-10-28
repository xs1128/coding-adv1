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

---

# Result: 1.27× to 2.23× faster, bitwise identical

<figure>
  <img src="/fig/scaling.png" class="h-92" />
  <figcaption>201³ cells, FP64, 30 steps. Each comparison on one node. Jobs 606017 / 621788, 606018 / 622305, 606019 / 622306.</figcaption>
</figure>

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

---

# Why it is faster

<figure>
  <img src="/fig/kernels_1g.png" class="h-60" />
  <figcaption>ncu 600146 (v5.7.0) vs 606033 (P3)</figcaption>
</figure>

- WENO5: occupancy doubled. HLLC: helpers inlined.
- Still slow: copy kernels at a third of HBM bandwidth, halo not overlapped.

---

# Correctness and limits

- Every run: final state bitwise identical to v5.7.0.
- `./mfc.sh test`: 690 pass, 23 fail, 0 new. The same 23 fail on unmodified v5.7.0.
- Tried and rejected: `vector_length`, register cap 96, NVHPC 25.9.
- Next: overlap halo with compute, fuse copy kernels, send PRs upstream.

<div class="note mt-10">

Report `report.md`, patches `patches/opt/`, raw data `results/`

</div>
