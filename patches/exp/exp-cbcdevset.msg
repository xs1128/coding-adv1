CBC: set the boundary's device state with one small kernel instead of host-to-device copies

Each CBC call copied cbc_dir/cbc_loc, the index bounds, dj, dir_idx/dir_flg and ds to the GPU: 9 small asynchronous
copies from host memory. With 0028 they ran on the CBC queue, whose first copy from host memory makes the NVHPC runtime
allocate a pinned staging buffer (cuMemHostAlloc, 21 ms in the first time step, nsys 685403). The values are now set on
the host as before and written on the GPU by one single-block kernel that takes them as arguments; ds is read from the
GPU copy of dx/dy/dz. Moving the copies to the default queue instead (exp-cbcnobuf) removed the 21 ms but cost 0.15 % per
step (686710). Same values in every field the CBC kernels read, so bitwise.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
