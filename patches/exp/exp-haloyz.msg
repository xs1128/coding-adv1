Halos: with an MPI neighbour in y or z, fill the y/z ghost cells on a second OpenACC queue while the x sweep runs

On the fused per-direction path the x sweep reads interior y/z cells only, so the y and z ghost cells are not needed
until the y sweep. With RDMA halo exchange and an MPI neighbour in y or z (OpenACC with NVHPC), s_compute_rhs now fills
the x ghost cells first, queues the x sweep, and only then fills the y and z ghost cells, with the exchange's pack and
unpack kernels on OpenACC queue 2 and its waits limited to that queue, so the host sits in MPI while the GPU runs the x
sweep. Queue 2 first waits for the x ghost cells; the default queue waits for queue 2 before the y sweep. The exchange
also sends v_size to the GPU only when it changes. Off when anything that runs before the y sweep reads y/z ghost
cells (viscous, QBMM, surface tension, chemistry, hypoelasticity, IGR, IB, bubbles, MTHINC) and on the call that
returns after filling the buffers. Same values, so bitwise.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
