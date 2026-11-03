CBC: queue the boundary's small host-to-device updates before switching to the CBC queue

With CBC on one side of a direction (0028), the direction indexes, the FD/PI coefficient spacing and the CBC location were
sent to the GPU after the switch to the CBC queue. The first async copy from host memory on a new OpenACC queue makes the
NVHPC runtime allocate a pinned staging buffer for it (cuMemHostAlloc, 21 ms in the first time step on the benchmark,
nsys 685403). The updates now go out on the default queue just before the CBC queue waits for it, so that queue never
copies from the host. s_associate_cbc_coefficients_pointers now runs before s_initialize_cbc, whose kernels do not use
its results. Same values and kernels, so bitwise.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
