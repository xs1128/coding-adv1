Split the x sweep around the x halo exchange when x has an MPI neighbour

With RDMA MPI and an MPI neighbour in x, the x halo exchange no longer runs
before the x sweep. The x Riemann solve first covers the faces that read no
x ghost cell on an MPI side (WENO5: face j reads cells j-2..j+3). While the
GPU runs them, the host sits in the x exchange, queued on its own
high-priority OpenACC queue (3) so it does not wait behind the CBC kernels
on queue 2. The default queue then waits for that queue, and the 3 faces
next to each MPI side are solved. Every face is computed by the same code
as before, only in another kernel launch, so results are bitwise the same.

The y/z ghost fill spans the x ghost columns, so in 2D/3D the split is only
used when the y/z fill is deferred too (s_decide_halo_yz): the y/z exchange
on queue 2 waits for queue 3, keeping the x-then-y-then-z order. Same
physics exclusions as the y/z deferral. s_cbc_priority_stream takes the
queue as an argument and is public.
