# Speaker script, 5 minutes

About 620 words at a calm pace. The same text is in `slides.md` as presenter notes (press `P` in `pnpm dev` to open presenter mode).

## 1. Title (0:00–0:20)

Hi, I am [name]. For the coding part I chose MFC, a fluid dynamics code from the SC26 Student Cluster Competition, and I ran it on the H200 GPUs of nano4. My goal was simple: make it faster without changing a single bit of its answer.

## 2. Result (0:20–1:20)

This is the result. Grey is the original version 5.7.0, blue is my final build. The case is MFC's own benchmark: 201 cubed cells, double precision, 30 steps.

On one GPU, the step time goes from 76.7 to 60.4 milliseconds. That is 1.27 times faster. On four GPUs it is 1.35 times, and on eight GPUs 2.23 times.

The eight-GPU number is larger partly because the original, at its default settings, sends halo data through host memory, and my final setup sends it directly between GPUs. I say this up front so the number is not oversold.

Every comparison ran on the same node, and the final state matches the original bit for bit.

## 3. Six changes (1:20–3:00)

Six changes got there. None of them changes the equations, the grid or the precision.

I started by profiling. Two things stood out. The GPU often waited for the CPU, and the two heavy kernels, the WENO reconstruction and the HLLC Riemann solver, ran poorly.

P1 and P3 remove the waiting. The code synchronized with the host after many small kernels. I made them asynchronous on one stream, with a single wait.

K4b was a compiler surprise. NVHPC only inlines GPU helper routines inside one source file, so HLLC passed its arguments through slow local memory. Compiling those modules as one unit removed every call and saved 7 percent.

K2: WENO used 196 registers, so only a few warps fit on each SM. Capping it at 128 registers doubled occupancy. That was the biggest single gain, about 11 percent.

P4: WENO also computed ghost cells that nothing reads. I checked every consumer, then limited it to the interior.

Finally, `rdma_mpi` sends halos from GPU to GPU over NVLink. That saved 27 percent at four GPUs.

## 4. Why it is faster (3:00–3:50)

This kernel profile shows why. Kernel time drops from 35.1 to 28.2 milliseconds.

WENO falls from 13.7 to 9.6, because occupancy doubled. HLLC falls from 9.1 to 6.4, because its helpers are now inlined.

The bottom bars did not move. Those copy kernels reach only a third of the memory bandwidth, and the halo exchange still does not overlap with compute. Those are the next targets.

## 5. Correctness and limits (3:50–4:50)

Now correctness. Every benchmark run is checked bitwise against the original.

I also ran MFC's full test suite: 690 tests pass and 23 fail. All 23 also fail on the unmodified code in this environment. So I add zero new failures, and I report the 23 instead of hiding them.

Some ideas did not work, for example a lower register cap or an older compiler. I kept those as negative results.

Next, I would overlap the halo exchange with compute, fuse the copy kernels, and send these patches upstream to MFC.

Thank you. I am happy to take questions.
