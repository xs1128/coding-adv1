# Speaker script, 5 minutes

About 640 words at a calm pace. The same text is in `slides.md` as presenter notes (press `P` in `pnpm dev` to open presenter mode).

## 1. Title (0:00–0:20)

Hi, I am xs. For the coding part I chose MFC, a fluid dynamics code from the SC26 Student Cluster Competition, and I ran it on the H200 GPUs of nano4. My goal was simple: make it faster without changing a single bit of its answer.

## 2. Result (0:20–1:20)

This is the result. Grey is the original version 5.7.0, blue is my final build. The case is MFC's own benchmark: 201 cubed cells, double precision, 30 steps.

On one GPU the step time goes from 76.9 to 28.2 milliseconds, which is 2.73 times faster. On four GPUs, with the same setting on both sides, it is 23.1 to 7.9 milliseconds, 2.93 times.

The right panel is the whole run, start-up and saving included: 7.76 to 2.78 seconds on one GPU, and 11.89 to 4.60 seconds on four.

MFC also reports its own score figure, the grind time, which is nanoseconds per grid point per equation per right-hand-side call. That goes from 0.397 to 0.145.

Every comparison ran on the same node in the same job, and the final state matches the original bit for bit.

## 3. What we changed (1:20–2:50)

Thirty-one small patches got there. None of them changes the equations, the grid, the step count or the precision. One patch is one change, so each one can be reviewed and reverted on its own.

The first six were the October report. The interesting part is what came after.

Most of the gain is memory traffic, not mathematics. The code kept copying arrays it could simply read where they were, and it walked over the grid several times when one pass would do. So the biggest groups are: stop copying, and merge passes.

Two patches prefetch. The fused kernels load the next variable's stencil, or the next equation's values, while they are still computing the current one.

The last group removes the places where the CPU blocked waiting for the GPU, mostly in the boundary code, which matters more on several GPUs.

## 4. Why it is faster (2:50–3:50)

Here is the same measurement, rung by rung. Each rung is its own comparison on one node, and every one of them is bitwise identical to the original. The v5.7.0 bar is re-measured in each job, so it moves between 76.7 and 77.7 milliseconds depending on the node.

I started from a profile. Two things stood out. The two heavy kernels, the WENO reconstruction and the HLLC Riemann solver, ran badly, and the GPU often waited for the CPU.

WENO used 196 registers, so only a few warps fit on each streaming multiprocessor. Capping it at 128 doubled the occupancy. That was the biggest single gain.

HLLC was a compiler surprise. NVHPC only inlines GPU helper routines inside one source file, so HLLC passed its arguments through slow local memory. Compiling those modules as one translation unit removed every call.

The bottom bars did not move. Those copy kernels reach only a third of the memory bandwidth, and the halo exchange still does not overlap with compute. Those are the next targets.

## 5. Correctness and limits (3:50–4:50)

Now correctness, which is the part I care most about.

Every benchmark run is checked bitwise against the original: 65 million numbers, every bit the same.

I also ran MFC's full test suite on the final build: 713 tests, 690 pass, 23 fail. All 23 also fail on the unmodified code in this environment, with the same errors. So I add zero new failures, and I report the 23 instead of hiding them.

Two limits I want to be upfront about. Seven further patches are measured and faster, but their full test suite has not been run, so they are not part of the headline number. And the eight-GPU figure in the October report compares the original at its default settings against my setup, which sends halos straight between GPUs, so that number is flattered.

Some ideas did not work, for example a lower register cap or an older compiler. I kept those as negative results.

Next, I would overlap the halo exchange with compute, fuse the copy kernels, and send these patches upstream to MFC.

Thank you. I am happy to take questions.
