# Single-GPU kernel plan for MFC on H200 (5-eq, WENO5, HLLC, RK3, FP64)

Research only: nothing was built or run for this plan. Source read at `/home/hipac2026/xs/ap-hw2/repos/MFC` (master 1ececa3,
about 2 weeks after v5.7.0). Paths are relative to `src/` unless they start with `cmake/`. Upstream status was checked on 2026-10-22
through the GitHub API. The raw JSON is in the session scratchpad, and the full #2093 description is in `docs/refs/PR.md`.

## 0. Constraints that drive the ranking

- **Deadline.** wilfonba wrote in #2093 (closed 10-20) that SCC source changes must be **merged upstream by 2026-10-26**,
  four days from now.
  - The guideline is ±5000 lines. danieljvickers expects most changes to be "under 1k lines of additions".
  - Maintainers rejected the following:
    - large rewrites;
    - `#ifdef` and opt-in toggles;
    - NVIDIA- or OpenACC-only modules;
    - code inlined by hand through Fypp. #2095 was called "too cumbersome", even though it was bit-identical and cut
      grind by 11.7 %.
    - global `maxregcount` without an architecture guard and data across schemes and GPUs (#987, closed).
  - **They accept** small, default-on, bit-identical loop restructures. #2087 (+8 LOC) was APPROVED by sbryngelson on 10-21.
  - Contributors must not mark their own PRs ready. Maintainers flip drafts to ready, which is what starts the self-hosted CI.
- **What a change must satisfy:**
  - pass `./mfc.sh test` at 1e-12;
  - keep the OpenMP-offload path, either through the `GPU_*` Fypp macros or as OpenACC-only clauses passed in `extraAccArgs`;
  - leave the numerics unchanged. In practice "bit-identical" is the safe bar: anything that reorders a division or a sum is
    flagged below.
- **Flag-only changes** to CMake or the compiler are legal for the competition run but must be disclosed. They are not
  PR-able unless guarded and benchmarked.

### Upstream status (2026-10-22)

| # | What | State | Maintainer signal |
|---|---|---|---|
| 2087 (NTHU) | collapse(3) plus a seq variable loop in 8 copy/diff loops | open, **approved 10-21** | very likely to merge |
| 2088 (NTU issue) | master 31 % slower than v4.9.3; HLLC 1.42→2.83 ms | open | no comment |
| 2092 (NTHU) | WENO reads `v_vf(i)%sf` directly; pack only for MP-WENO/THINC | open **draft** | procedural only ("maintainer will mark ready") |
| 2093 (NTU) | mega-fusion + 20 flags (+27k LOC) | **closed 10-20** | "no chance of ever being merged", "AI slop", ~5× over the size guideline |
| 2094 (NTHU issue) | cross-file device calls cause HLLC stack 528–576 B; inlining gives 2.45→1.42 ms | open | no comment |
| 2095 (NTHU) | Fypp private copies of EOS/Riemann helpers | **closed 10-20** | "too cumbersome and will not be accepted" |
| 987 | `-gpu=maxregcount:128/165` for IGR on GH200 | closed 2026-06 | "guard by device type"; "could mess with performance for WENO" |
| other | #1940 amdflang flag (merged, maintainer-authored); #2090 Isend/Irecv halo (draft); #2097 IB loops (draft) | — | no merged HLLC fix, register-cap, finalize, or ping-pong PR exists |

## 1. Stage budget used for the estimates

All figures are from ncu at a locked 1.48 GHz and are per RK stage. Field sizes:

- interior: 201³ × 8 B = 65 MB per variable;
- buffered (`idwbuff`, 209³): 73 MB;
- faces: 65 MB.

The roofline bandwidth is taken as an achievable 4.2 TB/s, which is 88 % of 4.8 TB/s. FP64 is 64 lanes per SM per clock.

| Kernel (file:line) | ×/stage | ncu ms each | Bytes moved (ideal) | Floor ms | Achieved | Bound now | Realistic target |
|---|---|---|---|---|---|---|---|
| WENO5 `m_weno.fpp:1096` | 3 | ~4.66 (34 %) | R 8×73 + W 16×70 MB ≈ 1.7 GB | 0.40 (DRAM); **~1.45 (FP64)** | FP64 pipe 31 % | latency: 8 warps/SM; `wait` = dependent DFMA/DDIV chains | 2.2–3.3 (pipe 45–65 %) |
| HLLC `m_riemann_solver_hllc.fpp:900` | 3 | ~3.42 (25 %) | R 16 + W ~13 fields ≈ 1.9 GB | 0.46 | DRAM 31–42 % incl. **local-memory stack** | local memory from 140 device CALLs (#2094) | ~1.8 (= #2094's 1.42 ms at real clock) |
| `s_pack_weno_input_arr` `m_weno.fpp:893` | 3 | 0.81 | 16×73 MB = 1.17 GB | 0.28 | 1.44 TB/s (30 %) | instructions (collapse 4) | 0 (remove) |
| `s_finalize_riemann_solver` `m_riemann_state.fpp:1342` | 3 | 0.72 | 16×65 MB = 1.05 GB | 0.25 | 1.45 TB/s | instructions | 0 (alias) |
| q_cons→q_cons_qp `m_rhs.fpp:602` | 1 | 0.89 | 1.17 GB | 0.28 | 1.31 TB/s | instructions; 64-bit loop indices (`m_rhs.fpp:594`) | 0.30 → 0 |
| flux difference `m_rhs.fpp:1127/1203/1365` | 3 | ~0.95 | x 1.04 GB; y,z 1.56 GB | 0.25 / 0.37 | 1.1–1.6 TB/s | instructions; one FP64 divide `1/dx` per element | 0.30–0.45 |
| RK update `m_time_steppers.fpp:497` | 1 | 1.19 | 2.1 GB (s≥2), 2.6 GB (s=1) | 0.50–0.62 | 1.75–2.2 TB/s | instructions; one FP64 divide `/rk_coef(s,4)` per element | 0.6 |
| cons→prim `common/m_variables_conversion.fpp:421` | 1 | 0.75 | R 8 + W 4 = 0.78 GB | 0.19 | 1.0 TB/s | descriptor-heavy device calls, 102 regs | 0.35 |
| Other (BC/CBC, α·div u `m_rhs.fpp:1462+`, syncs) | — | ~6.5 | — | — | — | mixed | — |
| **Stage total** | | **≈41 ms (ncu)** | | | | | |

The ncu sum overstates wall time, because ncu flushes the caches and locks the clocks. The NTHU measurement of master on an
H200 SXM with NVHPC 26.3 is **0.417 ns grind**, or about 27 ms per stage. The savings below are therefore given as a
fraction of the ncu stage and then applied to 0.417 ns.

## 2. Evaluation of each lever

### 2.1 Register caps (WENO / HLLC)

**Occupancy arithmetic.** There are 64 K registers per SM, and registers are allocated in 256-register units per warp.

| regs/thread | block 128 (default) | block 64 (`vector_length(64)`) |
|---|---|---|
| 188–196 (WENO now) | 2 blocks = 8 warps (12.5 %), matching the measured 12 % | **5 blocks = 10 warps** (+25 %, no spill risk) |
| ≤168 | 3 blocks = 12 warps | 6 blocks = 12 warps |
| ≤128 | 4 blocks = 16 warps | 8 blocks = 16 warps |
| ≤96 | 5 blocks = 20 warps | 10 blocks = 20 warps |

HLLC sits at 127–160 regs, which is 12–16 warps. A cap of 128 lifts only the 160-register sweeps from 12 to 16 warps.

**Why WENO is at 196 regs.** It is very likely that loop-invariant coefficients are hoisted out of the `seq` variable loop:

- the reconstruction loop `do i = 1, v_size` (`m_weno.fpp:1100`) is a `seq` loop, so hoisting is legal;
- the per-cell coefficients `poly_coef_cbL/R` (12), `beta_coef` (9) and `d_cbL/R` (6) total 27 FP64 values, which is about
  54 registers.

A cap or a different loop shape therefore trades re-loads (from L1) for occupancy. Capping should be cheap for WENO.
The kernel is not memory-bound (DRAM is 10 %), and its stalls are `wait` and `long_scoreboard`, which more resident warps hide
directly.

**Options, in order of preference.**

- **W1. `vector_length(64)` on the WENO loops.**
  - **Change:** `extraAccArgs='vector_length(64)'` on the `GPU_PARALLEL_LOOP` calls at `m_weno.fpp:1096`, and on 1005 and 1255
    for WENO3 and WENO7. The macro supports this (`common/include/parallel_macros.fpp:24`); OpenMP is untouched.
  - **Effect:** 8 → 10 warps with the same registers, so no spill risk. It is bit-identical, about 3 LOC, and PR-able if
    benchmarked.
  - **Expected:** WENO −8 to −15 %.
- **W2. Per-file register cap for `m_weno`.** This is flag-only and must be disclosed.
  - **Precedent:** the per-file `COMPILE_OPTIONS` pattern already exists at `cmake/MFCTargets.cmake:74-78`.
  - **Implementation:**
    `set_property(SOURCE "${CMAKE_BINARY_DIR}/fypp/simulation/m_weno.fpp.f90" TARGET_DIRECTORY simulation APPEND PROPERTY COMPILE_OPTIONS "-gpu=maxregcount:128")`.
    - Use `APPEND`, because `set_source_files_properties` would overwrite the `-Mnoinline` options set for other files.
    - The rdc device code is assembled per object, so a per-file cap affects only that file's kernels.
    - Every kernel in the file gets the cap. This is harmless for the pack loop, which uses few registers.
  - **Candidates:** caps of 168, 128 and 96, combined with W1.
  - **Expected:** WENO −10 to −30 % if spill traffic stays under about 50 B per thread.
- **W3. Experimental: `collapse(4)` for the WENO5 kernel.** This is the opposite of #2087, and the reason is registers, not
  index math.
  - Each thread would reconstruct one (variable, cell) pair. The variables are fully independent, so the result stays
  bit-identical.
  - This removes the hoisted 54-register coefficient block. It may also take the kernel to ≤128 regs with no cap at all.
  - The index-recovery cost of the collapse is amortised over about 340 FP64 instructions per item.
  - **Check:** ptxinfo regs after a compile only. Keep the change only if regs ≤128 and WENO time drops.
- **HLLC caps.** These are low value until the stack problem in §2.4 is fixed.
  - The HLLC long-scoreboard stall is local-memory *stack* traffic (#2094: 528–576 B stack, 0 spill requests), not
    register pressure. A cap of 128 can only add spills to the same local-memory path.
  - Expected HLLC change is 0 to −8 %.
  - #2093's figure of 1.70→1.38 ms with a cap of 168 was measured on its restructured, call-free HLLC at more than 168 regs.
    It **does not transfer** to our 127–160-register kernel.
- **OpenACC `num_workers` does not help.** The loops are `gang vector` with collapse, so workers would sit idle.

**Cheap sweep, in about one hour of compile time and one GPU-hour of runs.**

1. **Compile only.** Take the exact compile line for `m_weno.fpp.f90` (and `m_riemann_solver_hllc.fpp.f90`) from
   `make VERBOSE=1`, or from `compile_commands.json` in the case-optimized build directory. Re-run it with
   `-gpu=maxregcount:{255,168,128,96}` and with W1/W3 variants. The existing `-gpu=ptxinfo` prints for each kernel:
   - registers used;
   - spill store and load bytes;
   - stack frame.
   Discard any variant whose spill exceeds about 64 B per thread.
2. **Build the survivors** by adding the per-file cap through an environment variable read in CMake. Because the variable is
   read at configure time, delete `CMakeCache.txt` in that case's build directory to force a reconfigure. Only that object
   recompiles, plus the relink.
3. **Measure at real clocks.**
   - Kernel durations:
     `nsys profile --stats=true` → `cuda_gpu_kern_sum`.
   - ncu, for warps, spills and the FP64 pipe:
     `ncu --clock-control none -k regex:s_weno --launch-skip 6 --launch-count 3 --metrics gpu__time_duration.sum,launch__registers_per_thread,launch__occupancy_limit_registers,sm__warps_active.avg.pct_of_peak_sustained_active,l1tex__t_sectors_pipe_lsu_mem_local_op_ld.sum,l1tex__t_sectors_pipe_lsu_mem_local_op_st.sum,sm__inst_executed_pipe_fp64.avg.pct_of_peak_sustained_active`
   - Final A/B: grind over at least 3 interleaved runs, the same method #2092 used.
   - Caps and vector length do not change FP results, so a single `./mfc.sh test` pass on the final setting is enough.

### 2.2 Redundant full-array copies

| Copy | Where | Feasibility on this tree | LOC | Notes |
|---|---|---|---|---|
| **Pack q_prim → `v_rs_weno`** | `m_weno.fpp:893-910`, called at :996 | **Trivial.** It is the same (j,k,l,i) layout for every direction, so it is a pure de-referencing copy. #2092 replaces `v_rs_weno(SF,i)` with `v_vf(i)%sf(SF)` in the WENO3/5/7 kernels and keeps the pack only for `mp_weno .or. int_comp>0`. | +4 net | **Interacts with #2087.** On master, pack removal nets −6.1 % (pack 7.7 % of kernel time minus WENO +5–6 % from descriptor loads). After #2087 the pack is already about 45 % cheaper, so the net drops to **about −1.5 to −2 %**. It may move further with W1–W3, because the descriptor address math adds registers. |
| **Finalize `flux_rsx_vf` → `flux_n`** | `m_riemann_state.fpp:1342-1509`; buffers at `m_riemann_solvers.fpp:106-108`; `flux_n` allocated at `m_rhs.fpp:209-292` | **Feasible as a pointer alias, with no kernel changes.** Both arrays use the same (x,y,z) order; the copy at :1357/:1467 is element-for-element. `flux_n(2:3)` *already* alias `flux_n(1)` (`m_rhs.fpp:288`), so all directions share one buffer anyway. Steps: (1) add `target` to `flux_rsx_vf` (and `flux_src_rsx_vf`); (2) after both modules are initialised, set `flux_n(1)%vf(l)%sf(-1:,-1:,-1:) => flux_rsx_vf(:,:,:,l)` plus `GPU_ENTER_DATA(attach=...)`, as at :288; (3) in finalize, skip the `flux_vf` copy when aliased, keeping the 1-var `flux_src` copy or aliasing it too; (4) nullify instead of deallocating at :2226. | ~25–35 | **Range check.** All readers stay inside (-1:m,-1:n,-1:p): the flux difference reads `k-1` with k≥0, and CBC reads and writes [-1,m] (`m_cbc.fpp:984,1198`). The one write-back reader is CBC, which updates the boundary fluxes in place and still works through the alias. The HLLD dual-pass `finalize_hatR` (`m_rhs.fpp:789`) copies hatR into the aliased buffer after the hat_L set has been consumed, which is still correct. Also audit the qbmm reader at `m_rhs.fpp:757`. **Benefits:** bit-identical, frees 0.58 GB, and works for all Riemann solvers. This is in effect "fuse finalize into the HLLC write", without touching HLLC. |
| **q_cons → q_cons_qp** | `m_rhs.fpp:602-612` | **Partial.** `q_prim_qp` cont/adv *are* `q_cons_qp` (`m_rhs.fpp:183,190`), and the halo fill writes their ghosts. Variant (a): set `q_cons_qp%vf(l)%sf => q_cons_ts(1)%vf(l)%sf` once (stage input is always `q_cons_ts(1)`, `m_time_steppers.fpp:469`). Halos would then land in the RK state's ghost cells, which RK never updates (`m_time_steppers.fpp:497`, interior only). The copy must stay when `mpp_lim .and. bubbles_euler` (in-place normalisation at :617) and for IBM, relativity, probes and output, unless audited. Variant (b): conversion reads `q_cons_vf`; copy only cont+adv, interior only (4 of 8 vars, no ghosts). | 10–30 | Only about 1 % after #2087, and more audit risk than the gain warrants. Do it last. |

### 2.3 Instruction-bound copy kernels

- **Root cause.** `collapse(4)` over (variable, z, y, x) makes every element a separate iteration. Each one then pays for:
  - the collapsed-index div/mod recovery, in 64-bit when the loop indices are `integer(kind=8)` (`m_rhs.fpp:594`);
  - two derived-type descriptor walks, `vf(i)` → `sf` base, lbounds and strides;
  - in the flux difference, an FP64 reciprocal `1/dx(k)` per element.

  That is roughly 60–100 instructions for every 16 B moved. It explains SM throughput around 72 %, the
  `not_selected`/`math_pipe_throttle` stalls, and the 30–37 % of DRAM peak.
- **#2087 fixes exactly this.** It uses `collapse(3)` with a `seq` variable loop and hoists `inv_ds`. NTHU measured −59 to
  −67 % instructions, −40 to −49 % kernel time, and −5.4 to −10.3 % grind, all bit-identical. It is approved; **build on it
  rather than duplicating it.**
- **Extend the same pattern to loops #2087 does not touch.** Each is bit-identical:
  - RK update `m_time_steppers.fpp:497`: 1.19 ms → about 0.6 ms, ~10 LOC. The `/rk_coef(s,4)` divide must stay a divide to
    remain bit-identical.
  - α·div(u) sources `m_rhs.fpp:1462+`: `collapse=4` over `j_adv` (2 fluids). About 3 × 0.1–0.2 ms, ~20 LOC.
  - WENO1 copies `m_weno.fpp:952-989`: not used in this case.
  - The `qL/qR` copies at `m_rhs.fpp:939/979`: only when `weno_Re_flux`.

  These fit in one follow-up PR of about 40 LOC: "#2087 follow-up: same transformation for the RK update and the advection
  source".
- **Contiguous 4D state / no derived types.** This would remove the descriptor loads everywhere. It is a cross-module refactor
  touching every `vf(i)%sf` user, which is thousands of lines. #2093's aligned-stride padding alone gave +6 %, and it was part
  of a rejected PR. **Not feasible by 10-26.** After #2087 the remaining gap on the copy kernels is about 1.3× to the
  bandwidth floor, so the extra gain is ≤3 % of the stage.

### 2.4 HLLC: the largest single item (25 % of the stage)

- **Cause, per #2094 on NVHPC 26.3, which is our compiler and matches our 127–160 regs.**
  - The kernel makes 140 device CALLs into `common/m_eos.fpp`, for example `s_compute_mixture_coefficients:568` and
    `s_compute_speed_of_sound:653`, and into `common/m_variables_conversion.fpp`, for example `s_compute_energy:1188`.
  - Fixed-size arrays such as `alpha_rho_L` and `alpha_L` are passed by reference to these calls, which forces a 528–576 B
    stack in local memory.
  - The two-pass IPO (`cmake/MFCTargets.cmake:55-58`, `-Mextract` then `-Minline=lib:`) extracts these routines but does not
    inline them into the kernel.
- **A second, smaller cause.** `vel_L(dir_idx(1))` and its relatives are indexed dynamically: `dir_idx` is a runtime array set
  at `m_riemann_state.fpp:308-314`, used about 100 times in lines 900–1400. That keeps `vel_L` and `vel_R` out of registers,
  even though the kernel is already emitted once per direction through Fypp (`NORM_DIR`, `m_riemann_solver_hllc.fpp:171`).
- **Route H1, flag-only: try this first.**
  1. `-Minfo=inline` is already on. Grep the case-optimized build log for the HLLC routine's "not inlined" messages and their
     stated reason, such as a size or level limit, "too big", or a routine flagged `cray_noinline`.
  2. If the reason is a size or level limit, add the corresponding `-Minline` limit suboptions for
     `m_riemann_solver_hllc.fpp.f90` only (and `m_variables_conversion` for cons→prim) through the per-file `APPEND` hook from
     W2. Verify the suboption names with `nvfortran -help -Minline` on 26.3.
  3. **Success test:** ptxinfo stack drops from about 550 B to under 64 B, and HLLC drops from about 2.7 ms to about 1.4 ms at
     real clocks.
  - The change is bit-identical if FMA contraction is unchanged, but check `./mfc.sh test`. There is a known precedent of an
    NVHPC IPO miscompile after inlining (`m_pressure_relaxation`, `cmake/MFCTargets.cmake:66-72`), so the run must pass in
    full.
- **Route H2, source.** In the HLLC 5-eq template, replace `dir_idx(1..3)` with Fypp constants derived from `NORM_DIR`:
  `${[1,2,3] / [2,1,3] / [3,1,2]}$`.
  - The change is mechanical, about 100 changed lines, and bit-identical. It removes the dynamic indexing.
  - It is smaller and less "cumbersome" than #2095, but it does **not** fix the call/stack problem on its own.
  - Expected HLLC change is −5 to −15 %. PR-ability is medium.
- **Route H3: an include file instead of Fypp macros,** which #2094 lists as an alternative. Maintainers rejected the macro
  form, and there is no time to negotiate a variant before 10-26. Treat it as post-SCC.

### 2.5 Fusion short of #2093

| Option | Mechanism | Saving | LOC | Verdict |
|---|---|---|---|---|
| F1 Finalize folded into the HLLC write | Pointer alias, §2.2 | 3 kernels: ~1.0 ms after #2087, 2.2 ms before | 25–35 | **Do it.** Bit-identical, no kernel edit. |
| F2 One flux-difference + α·div(u) kernel after all three sweeps | Un-alias `flux_n(2:3)` and `flux_src_n(2:3)` (`m_rhs.fpp:288-291`; +1.2 GB device memory). One `collapse(3)` kernel that keeps the exact summation order `((((Fx+Ax)+Fy)+Ay)+Fz)+Az`. CBC still runs per sweep before it. | Removes 2 rhs read-modify-write passes and 4–6 launches: ~0.6–0.9 ms (ncu) | 60–100 | Optional second wave. Must prove bit-identity for every adv_src_mode and geometry. |
| F3 z flux difference fused into the RK update | Crosses `m_rhs`↔`m_time_steppers`; all post-loop source terms would have to move | ~0.3–0.5 ms | 100+ | No: touches every physics path for about 1 %. |
| F4 q_cons copy fused into cons→prim | Conversion reads `q_cons_vf` and also writes the cont/adv copies | ~0.3 ms after #2087 | 30 | Low priority (see §2.2). |
| F5 WENO and HLLC fused without shared memory | Each face recomputes both reconstructions | WENO FP64 work doubles in a kernel that is already FP64-latency-bound | — | **No.** Doing it with shared-memory tiling is #2093, which was rejected. |

### 2.6 Compiler flags and toolchain (disclose all)

| Flag | Expected | Comment |
|---|---|---|
| `-gpu=fastmath` (`--fastmath`, `CMakeLists.txt:25`, `cmake/MFCTargets.cmake:250`) | 0–2 % | The CUDA fast-math switches mostly affect FP32 (ftz, approximate div/sqrt). FP64 `DDIV`/`DSQRT` stay IEEE, so WENO's 24 divides per variable-cell are unaffected. `x**2._wp` should already be folded to `x*x`. Results may differ by ulps in libm calls, so run `./mfc.sh test`. **Not worth the disclosure** unless measured above 2 %. |
| `-O3` / `-Mvect` / `-O4` | ~0 | Release already uses `-fast -O3`. `-Mvect` is host-only. |
| `-gpu=lineinfo,keep,ptxinfo` (`cmake/MFCTargets.cmake:248`) | 0 | Metadata only; SASS is unchanged. Keep it for profiling. |
| `-Mfprelaxed` (`cmake/GPU.cmake:159`) | — | Already on; host-side relaxed precision. |
| `-gpu=maxregcount` per file | WENO 10–30 % | §2.1, W2. |
| `-Minline` limits per file | HLLC up to −45 % | §2.4, H1. **Highest-value flag experiment.** |
| `-gpu=loadcache:L1`, `-gpu=nounroll` | ±5 %, uncertain | Cheap to add to the WENO sweep. `nounroll` may break register promotion of `alpha/beta/omega(0:2)`, so watch ptxinfo stack. |
| **NVHPC version** | unknown, possibly large | NTHU found 25.9 ≈ 26.3 (0.4148 vs 0.4166 ns). The IGR paper used 24.3 because newer releases regressed FP64. `nvhpc/24.7` is available on nano5 (H200 partition `normal2`); 25.9 and 26.3 are on nano4. Building the same tree with 24.7 costs about 1 hour. Check for compile breaks: the NVTX library name is fine on releases ≤26.5. |
| Global `-gpu=maxregcount` | do not use | Hurts the 102–160-register kernels and the copy kernels' memory-level parallelism; it was the #987 objection. |

## 3. Ranked plan

Savings are fractions of the 41 ms ncu stage, applied sequentially. Baseline grind is 0.417 ns (NTHU, H200 SXM, NVHPC 26.3).

| Rank | Change | Stage-time saving | LOC | Risk | PR-ability by 10-26 |
|---|---|---|---|---|---|
| 1 | **#2087**: collapse(3) + seq variable loop in pack, q_cons copy, finalize, and x/y/z flux difference | **−10 to −12 %** (about 4.5 ms ncu) | +8 | very low; bit-identical, approved | **Already approved.** Push maintainers to merge. |
| 2 | **WENO occupancy**: W1 `vector_length(64)` (src) + W2 per-file cap 128/168 (flag) + W3 collapse(4) trial | **−5 to −10 %** (WENO −15 to −30 %) | 3 (W1), CMake 5 (W2), 6 (W3) | low; no numerics change; spills must be watched | W1 and W3 PR-able if data shows no loss on another GPU. W2 is flag-only (disclose). |
| 3 | **Finalize alias** (F1) + **#2092** pack removal | **−3.5 to −4.5 %** after #2087 (alias ~2.4 %, #2092 ~1.5–2 %) | 30 + 4 | low–medium; alias needs the range audit in §2.2 | #2092 is open as a draft. The alias would be a new ~30-LOC bit-identical PR, which is tight but plausible. |
| 4 | **HLLC inlining** by flags (H1); fall back to H2 `dir_idx` constants | **−5 to −11 %** if the stack goes away; −1 to −3 % for H2 alone | 0 (flags) / ~100 changed (H2) | medium; IPO miscompile precedent | H1 is flag-only (disclose). H2 is a new PR with a maintainer reaction that is hard to predict. |
| 5 | #2087 pattern on the RK update and α·div(u) | −2 to −3 % | ~40 | very low | Easy follow-up PR. |
| 6 | NVHPC 24.7 vs 26.3 A/B | unknown (0 to −15 %?) | 0 | low; compile risk only | Toolchain choice (disclose). |
| 7 | F2 fused flux difference across sweeps | −1.5 to −2 % | 60–100 | medium | Post-SCC. |
| 8 | q_cons copy alias, F4, cons→prim cleanup | −1 to −2 % | 10–30 | medium (ghost-cell semantics) | Post-SCC. |
| 9 | `-gpu=fastmath` | 0–2 % | 0 | tolerance | Not recommended. |

### Projected grind

| After | Saving | Grind (from 0.417 ns) |
|---|---|---|
| Ranks 1–3 (the top three) | ~10–12 % + 5–10 % + 3.5–4.5 % ≈ **20–25 %** | **≈0.31–0.33 ns** |
| plus rank 4 (HLLC inlined, matching #2094's 2.45→1.42 ms) | 30–35 % | **≈0.27–0.29 ns** |
| plus rank 5 | — | **≈0.27 ns** |

That last figure is below the documented GH200 number (0.32) and in line with #2093's restructured, non-fused HLLC path
(0.304 ns).

**Roofline position after these changes, at real clocks:**

- copy, difference and RK kernels: 70–85 % of the HBM roofline;
- HLLC: about 30–35 % of HBM, latency- and instruction-bound with no local memory;
- WENO: about 45–65 % of the FP64 pipe, which is still the stage's largest item at about 30 %.

The next step past this point is fusion (#2093's 2.6×), which is out of scope for 10-26.

## 4. Suggested order of work (4 days)

1. **Day 0.**
   - Rebase on #2087 + #2092.
   - Compile-only sweep (§2.1 step 1).
   - Grep `-Minfo=inline` for HLLC "not inlined" reasons (§2.4 H1).
   - Kick off an NVHPC 24.7 build on nano5.
2. **Day 1.**
   - Implement the finalize alias and the RK/α-source collapse(3) follow-up.
   - `./mfc.sh test` on GPU and CPU.
   - Open both as **draft** PRs with an ncu/nsys before/after table, following the #2087 format.
3. **Day 1–2.**
   - nsys and grind A/B for W1/W2/W3 and for H1; keep the winners.
   - W1/W3 go into a small PR only if they are a clear win.
   - W2 and H1 stay as a disclosed `CMAKE`/environment setting for the competition build.
4. **Day 3.** Freeze. Re-validate with `./mfc.sh test` at 1e-12 on the final flag set and NVHPC version, and record the
   flags for disclosure.
