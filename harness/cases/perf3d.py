#!/usr/bin/env python3
# MFC examples/3D_performance_test (v5.7.0) with the grid size, step count and output made parameters.
# The physics/numerics dictionary is copied verbatim from upstream; only m/n/p, t_step_stop/save and
# the I/O switches are exposed. Defaults reproduce the upstream case exactly (201^3 cells, 30 steps).
#   --cells N     cells per GPU (approx.; global grid = N * ranks, decomposed by MFC). Overrides --m.
#   --m M         global m=n=p (upstream: 200 -> 201^3 cells)
#   --steps S     t_step_stop (= t_step_save, so only the initial and final states are written)
#   --no-io       disable the database writes (format/parallel_io kept; prim_vars_wrt off, t_step_save > stop)
import argparse
import json
import math

parser = argparse.ArgumentParser()
parser.add_argument("--mfc", type=json.loads, default="{}", metavar="DICT")
parser.add_argument("--cells", type=float, default=None)
parser.add_argument("--m", type=int, default=200)
parser.add_argument("--steps", type=int, default=30)
parser.add_argument("--no-io", action="store_true")
args = parser.parse_args()

m = n = p = args.m
if args.cells is not None:
    ranks = args.mfc.get("nodes", 1) * args.mfc.get("tasks_per_node", 1)
    # Grow the cube along x, then y, then z (like MFC's own weak-scaling benchmarks) so each rank keeps
    # ~`cells` cells with the same per-rank cube shape when ranks is a power of two.
    side = round(args.cells ** (1 / 3))
    dims = [side, side, side]
    k, i = ranks, 0
    while k > 1:
        f = 2 if k % 2 == 0 else k
        dims[i % 3] *= f
        k //= f
        i += 1
    m, n, p = (d - 1 for d in dims)

case = {
    # Logistics
    "run_time_info": "F",
    # Computational Domain Parameters
    "x_domain%beg": 0.0e00,
    "x_domain%end": 4.0e-03 / 1.0e-03,
    "y_domain%beg": 0.0e00,
    "y_domain%end": 4.0e-03 / 1.0e-03,
    "z_domain%beg": 0.0e00,
    "z_domain%end": 4.0e-03 / 1.0e-03,
    "stretch_x": "T",
    "a_x": 4.0e00,
    "x_a": -1.5e-03 / 1.0e-03,
    "x_b": 1.5e-03 / 1.0e-03,
    "stretch_y": "T",
    "a_y": 4.0e00,
    "y_a": -1.5e-03 / 1.0e-03,
    "y_b": 1.5e-03 / 1.0e-03,
    "stretch_z": "T",
    "a_z": 4.0e00,
    "z_a": -1.5e-03 / 1.0e-03,
    "z_b": 1.5e-03 / 1.0e-03,
    "cyl_coord": "F",
    "m": m,
    "n": n,
    "p": p,
    "dt": 0.2e-09 / 1.0e-03,
    "t_step_start": 0,
    "t_step_stop": args.steps,
    "t_step_save": args.steps,
    # Simulation Algorithm Parameters
    "num_patches": 2,
    "model_eqns": "5eq",
    "alt_soundspeed": "F",
    "num_fluids": 2,
    "mpp_lim": "T",
    "mixture_err": "T",
    "time_stepper": "rk3",
    "weno_order": 5,
    "weno_eps": 1.0e-16,
    "weno_Re_flux": "F",
    "weno_avg": "F",
    "avg_state": "arithmetic",
    "mapped_weno": "T",
    "null_weights": "F",
    "mp_weno": "F",
    "riemann_solver": "hllc",
    "wave_speeds": "direct",
    "bc_x%beg": -2,
    "bc_x%end": -6,
    "bc_y%beg": -2,
    "bc_y%end": -6,
    "bc_z%beg": -2,
    "bc_z%end": -6,
    # Formatted Database Files Structure Parameters
    "format": "silo",
    "precision": "double",
    "prim_vars_wrt": "T",
    "parallel_io": "T",
    # Patch 1: High pressured water
    "patch_icpp(1)%geometry": 9,
    "patch_icpp(1)%x_centroid": 80.0e-03 / 1.0e-03,
    "patch_icpp(1)%y_centroid": 80.0e-03 / 1.0e-03,
    "patch_icpp(1)%z_centroid": 80.0e-03 / 1.0e-03,
    "patch_icpp(1)%length_x": 160.0e-03 / 1.0e-03,
    "patch_icpp(1)%length_y": 160.0e-03 / 1.0e-03,
    "patch_icpp(1)%length_z": 160.0e-03 / 1.0e-03,
    "patch_icpp(1)%vel(1)": 0.0e00,
    "patch_icpp(1)%vel(2)": 0.0e00,
    "patch_icpp(1)%vel(3)": 0.0e00,
    "patch_icpp(1)%pres": 1.0e05,
    "patch_icpp(1)%alpha_rho(1)": 1000.0e00,
    "patch_icpp(1)%alpha_rho(2)": 0.1e00,
    "patch_icpp(1)%alpha(1)": 0.9e00,
    "patch_icpp(1)%alpha(2)": 0.1e00,
    # Patch 3: Air bubble
    "patch_icpp(2)%geometry": 8,
    "patch_icpp(2)%smoothen": "T",
    "patch_icpp(2)%smooth_patch_id": 1,
    "patch_icpp(2)%smooth_coeff": 0.5e00,
    "patch_icpp(2)%x_centroid": 0.0e00,
    "patch_icpp(2)%y_centroid": 0.0e00,
    "patch_icpp(2)%z_centroid": 0.0e00,
    "patch_icpp(2)%radius": 1.0e-03 / 1.0e-03,
    "patch_icpp(2)%alter_patch(1)": "T",
    "patch_icpp(2)%vel(1)": 0.0e00,
    "patch_icpp(2)%vel(2)": 0.0e00,
    "patch_icpp(2)%vel(3)": 0.0e00,
    "patch_icpp(2)%pres": 1.0e03,
    "patch_icpp(2)%alpha_rho(1)": 100.0e00,
    "patch_icpp(2)%alpha_rho(2)": 0.9e00,
    "patch_icpp(2)%alpha(1)": 0.1e00,
    "patch_icpp(2)%alpha(2)": 0.9e00,
    # Fluids Physical Parameters
    "fluid_pp(1)%gamma": 1.0e00 / (4.4e00 - 1.0e00),
    "fluid_pp(1)%eos": "stiffened_gas",
    "fluid_pp(1)%pi_inf": 4.4e00 * 6.0e08 / (4.4e00 - 1.0e00),
    "fluid_pp(2)%gamma": 1.0e00 / (1.4e00 - 1.0e00),
    "fluid_pp(2)%eos": "ideal_gas",
}

if args.no_io:
    case["prim_vars_wrt"] = "F"
    case["t_step_save"] = args.steps + 1

print(json.dumps(case))
