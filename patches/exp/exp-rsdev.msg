Riemann states: write the direction's index bounds and direction arrays on the GPU with one small kernel

s_populate_riemann_states_variables_buffers updated is1-3, isx-z, dir_idx, dir_flg, dir_idx_tau and stress_perm with
10 small asynchronous host-to-device copies before every Riemann solve. On the GPU they wait for the previous
direction's solve and then run one after another with the GPU idle in between, so the next solve starts ~50 us late
wherever no other queue has work (4 GPUs, rdma_mpi: directions with an MPI neighbour). One single-thread kernel on the
same queue, taking the host values as arguments, writes the same device values.

