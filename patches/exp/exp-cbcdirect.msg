CBC: copy the boundary fluxes back alongside the Riemann solve, which skips those faces

With the fused HLLC path and CBC on one side of a direction (s_cbc phase 1),
the CBC copy-back (s_finalize_cbc) ran on the default queue after the
Riemann solve: up to 9 small kernels per step on the critical path, one of
them 31 us at 1 GPU. Its faces (-1 .. cbc_flux_jend from the boundary, 3 for
WENO5) were also solved by the Riemann kernel only to be overwritten.

Now phase 1 copies back itself, on cbc_queue, and the Riemann solve skips
those faces. The fused path's only per-face outputs are the flux slab and
flux_src(adv%beg), both of which the copy-back writes (every flux, as
adv%end = sys_size), so every final value is the one computed before.
The later s_cbc call then only waits for cbc_queue. Off unless
recon_riemann_fused, flux_per_dir, no use_nc_iface_vel, and at least 8
cells in each direction.
