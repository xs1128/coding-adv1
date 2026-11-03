# Making MFC faster on H200 GPUs

This is our homework for the SC26 Student Cluster Competition: take the fluid simulator
[MFC](https://github.com/MFlowCode/MFC) (version 5.7.0) and make it run faster on one NVIDIA H200 GPU of the nano4 cluster,
**without changing the answers**.

## The short version

- **MFC** simulates gas and liquid flows. It splits space into a 3-D grid of small boxes (here 201 × 201 × 201)
  and, at every time step, works out how much stuff flows between neighbouring boxes.
- The GPU spends almost all its time doing that "flow between boxes" maths. Most of our speedup comes from
  **doing less copying and fewer separate passes over memory**. The maths is unchanged.
- Every change is checked: our results match the original program's **bit for bit**, and the full MFC test suite gives
  the same results as before (only the 23 tests that already failed on plain v5.7.0 still fail).

## The result (1 H200 GPU, 201³ grid, 30 steps)

All runs in one job on one node, taking turns (job 690631, 2026-11-03, node hgpn011, 2 rounds). Every run's final
answer is **bit-for-bit identical** to plain v5.7.0.

| Version | Time per step | Faster than v5.7.0 |
|---|---|---|
| MFC v5.7.0 (original) | 77.7 ms | 1× |
| Ours, previous version: patches 0001–0030 ("P21") | 28.5 ms | 2.73× |
| **Ours: v5.7.0 + patches 0001–0031 ("P22")** | **28.4 ms** | **2.74×** |

P22 is 0.32 % faster per step than P21, and its first step takes 35 ms instead of 57–59 ms. The wall time of a whole run
is 5.48 s (median) for P22 and 5.63 s for P21, but the ranges overlap (5.24–5.89 vs 5.37–5.92 s), because start-up and
saving take most of it. Earlier jobs on other nodes: 686551 (v5.7.0 76.9, P20 29.7, P21 28.3 ms: P20 2.59×, P21
2.72×) and 680943 (v5.7.0 77.8, P20 29.8 ms: 2.61×).

For comparison, the 10-31 report ("P4", patches 0001–0006) was 1.27× faster at 1 GPU (60.38 ms vs 76.74 ms, two
chained A/Bs). On 4 and 8 GPUs the 10-31 numbers are 1.35× and 2.23×; later multi-GPU results are in [`report.md`](report.md) §11.

## What we changed, in plain words

Each change is one small patch in [`patches/opt/`](patches/opt/). Apply them in order to MFC v5.7.0 to rebuild our version.
[`docs/optimizations.md`](docs/optimizations.md) explains each one, and [`docs/ladder.md`](docs/ladder.md) lists every
attempt, including the ones that failed.

**Steps 1–6 (by the 10-31 report, "P4"):**

| # | What it does | Everyday picture |
|---|---|---|
| 0001, 0005 | Queue GPU jobs without making the CPU wait for each one | Drop off all your laundry at once instead of waiting by the machine for each load |
| 0002 | Remove an unused import | Tidy-up |
| 0003 | Compile the flux solver as one file so the compiler can inline everything | Put the whole recipe on one page |
| 0004 | Limit registers per GPU thread in the WENO code so more threads run at once | Smaller desks, so more students fit in the room |
| 0006 | Only compute the cells the next step actually reads | Don't cook food nobody will eat |

**Steps 7–24 (new since the 10-31 report):**

| # | What it does | Everyday picture |
|---|---|---|
| 0007, 0008, 0009, 0011, 0023, 0024 | Stop copying arrays that can just be read where they are | Read the book on the shelf instead of photocopying it first |
| 0010, 0016, 0017, 0022 | Merge several passes over the grid into one | Do all your shopping in one trip, not four |
| 0015 | The flux solver works out its own inputs (WENO5) instead of reading them from a big temporary array | Chop the vegetables right at the stove |
| 0020, 0021 | Start loading the next numbers while working on the current ones | Read the next line while you're still saying this one |
| 0013, 0019 | Remove places where the CPU stopped and waited for the GPU | Fewer "are you done yet?" check-ins |
| 0012, 0018 | Register limits for the flux solver; a build fix | Same idea as 0004 |
| 0014 | Code formatting only | Tidy-up |

**Steps 25–30 (P21, full test suite passed 2026-11-03):** mostly the boundary code, which matters more on several GPUs.

| # | What it does | Everyday picture |
|---|---|---|
| 0025 | The boundary code (CBC) gets its few numbers passed directly, so the CPU doesn't wait for each flux solve | Hand over the note instead of waiting at the counter |
| 0026, 0030 | Fill the edge ("ghost") cells with one GPU thread per value; skip the old per-cell pass where it has nothing left to do | Many hands, and don't walk the hall twice |
| 0027 | CBC stops copying data that its own kernels overwrite anyway | Don't copy a page you are about to rewrite |
| 0028, 0029 | Small CBC kernels run on a second, high-priority GPU queue beside the main flux kernel | A second checkout lane for small baskets |

On 1 GPU these six save about 4.75 % per step (above). On 4 GPUs they save more, about 11 % per step by chaining
A/B jobs (685059, 685274, 685404), because there the other GPUs wait for the one with the most boundary work. The full
suite (713 tests, ladder row 67) gives exactly the 23 known failures, with the same errors as P20.

**Step 31 (P22, full test suite passed 2026-11-03):** 0031 sets the boundary code's few numbers on the GPU with one
tiny kernel instead of 9 small copies from the CPU per call. That removes a 21 ms one-off cost in the first step (the
GPU runtime had to set up a pinned copy buffer for the second queue) and makes each step 0.3 % faster at 1 GPU (job
686808) and 1.3 % faster at 4 GPUs (686954), bitwise. Full suite: the 23 known failures, same errors (ladder row 70).

**Pending 0032 (not in P22, multi-GPU only):** while the host waits on MPI for the y/z halo exchange, the GPU now runs
the x sweep (ghost cells filled on a second queue). 4 GPUs: 7.921 → 7.781 ms per step (−1.8 %, job 690856), bitwise;
the 7 two-rank MPI tests with RDMA pass (690903). Full suite not run, so it stays in `patches/pending/` (ladder row 71).

**Pending 0033 (on 0032, not in P22):** before each Riemann solve, 10 tiny CPU-to-GPU copies ran one after another while
the GPU waited; one tiny kernel now writes the same values. 4 GPUs: 7.780 → 7.721 ms per step (−0.76 %, job 691553);
1 GPU unchanged (691872); bitwise; 155 targeted tests clean apart from the known failures (ladder row 72).

**Pending 0034 (on 0033, not in P22):** the boundary code (CBC) used to copy its results into the flux arrays after the
flux solver had finished, while the GPU waited, and the solver first computed the 3 boundary faces that this copy then
overwrote. Now the copy runs on the CBC's own queue during the solve, and the solver skips those faces. 1 GPU: 28.12 /
28.15 → 27.83 / 27.79 ms per step (−1.0 % / −1.3 %, job 692419); 4 GPUs: 7.710 → 7.541 ms (−2.2 %, 692812); bitwise,
also with CBC on the other side of the box (692840); the 30 CBC tests pass (692852). Full suite not run (ladder row 74).

**Pending 0035 (on 0034, not in P22):** the final update pass (RK update) waited on memory most of the time, because
each GPU thread fetched only the next equation's numbers ahead. It now fetches two ahead, and that file is capped at 168
registers so as many threads still fit on the GPU (without the cap it was 3.9 % slower). 1 GPU: 27.86 → 27.66 ms per
step (−0.78 % / −0.67 %, job 693627); 4 GPUs: 7.548 → 7.484 ms (−0.85 %, 693693); bitwise. Full suite not run (ladder row 76).

**Pending 0036 (on 0035, not in P22):** at the end of a run the answer is copied from the GPU into a part of CPU memory
that had never been used, so the operating system had to set up every page during the copy. It now goes into the copy
that already holds the starting state; the file written is the same. Saving takes about 0.42 s instead of 0.66–0.85 s,
and a whole run (with the `ob1` and `/dev/shm` settings) 3.72–3.91 s instead of 3.96–4.33 s (jobs 693750, 693774; ladder row 77).

**Pending 0037 (on 0036, not in P22):** the file writer was handed each variable with its border cells cut off, which is
not one block of memory, so it first copied it into fresh memory. Now the GPU packs the data into one block before the
copy to the CPU, and the writer uses it as is. Saving takes about 0.24 s instead of 0.34–0.38 s; a whole run 3.40–3.41 s
instead of 3.51–3.64 s (job 694651); the file is the same, also with saves in the middle of a run (694653; ladder row 78).

**Pending 0038 (on 0037, not in P22):** reading the starting state had the same problem the other way round: the reader
filled a fresh block and the runtime then copied it into place. Now the reader is told where each value goes and fills the
variable's own memory directly. A whole run takes about 3.3 s instead of 3.46–3.53 s (median, jobs 694689 and 696366); the
answer is the same (ladder rows 79–80).

**Run settings (disclosed, no code change):** at 1 GPU, Open MPI without UCX (`ob1`) and a run directory in node-local
memory (`/dev/shm`) cut the wall time of a whole run, start-up and save included, to about 3.8 s (job 684750).
Starting the run with `LD_LIBRARY_PATH` unset (`NOLIBPATH=1`) cuts it further: the variable lists 6 compiler folders on the
slow shared file system, and the program finds the same libraries without it. With patches up to 0038, a whole run takes
2.79–2.82 s instead of 3.55–3.65 s (median, job 696791), with the same answer (ladder row 85). At 4 GPUs it saves about 0.6–0.9 s too (job 696824, row 86); the `/dev/shm` run directory adds about 3 % there (696970, row 87), and turning off two collective libraries that HPC-X starts with MPI (hcoll, UCC) about 12 % more (697130, row 89), and leaving out two UCX parts a single node does not use another 10 % (697393, row 92). A file of ROMIO hints (bigger buffer, 4 writers instead of 1) makes the 4-GPU save about a third faster (697672, row 95). Altogether a whole 4-GPU run went from about 7.2–7.3 s to about 4.5–4.6 s with the same answer.

**Since the 10-31 report**, the time per step at 1 GPU went from ~60 ms to ~28.4 ms (see [`report.md`](report.md) §11).

## Folder map

| Folder / file | What's inside |
|---|---|
| [`report.md`](report.md) | The full write-up (also built as `dist/report.pdf` by `tools/build_pdf.py`) |
| [`slides/`](slides/) | Slides for the 11-11 talk ([Slidev](https://sli.dev)): `cd slides && npm install && npm run dev`; `npm run export` writes `dist/slides.pdf` |
| [`patches/opt/`](patches/opt/) | Our 31 changes to MFC, one per file |
| [`patches/exp/`](patches/exp/) | Experiments we tried, most of them rejected |
| [`docs/`](docs/) | Explanations: each optimization, the ladder of attempts, how the test harness works, the code layout |
| [`docs/background/`](docs/background/) | Research notes and papers we read |
| [`docs/history/`](docs/history/) | The original plan and roadmap |
| [`harness/`](harness/) | Slurm job scripts, test cases, and the timing and result-checking scripts |
| [`results/`](results/) | Raw output of every job (never hand-edited); `results/jobs.tsv` logs every job |
| [`baseline/`](baseline/) | How to reproduce plain v5.7.0 numbers |
| [`scripts/`](scripts/), [`tools/`](tools/) | Build/env scripts; helpers for syncing, plotting, packaging |
| [`ap-research/`](ap-research/) | Short briefs on the two competition apps (WRF and MFC) |
| [`AGENT_LOG.md`](AGENT_LOG.md) | Mistakes the AI assistant made along the way, and what we did about them |
| [`CLAUDE.md`](CLAUDE.md) | Working rules (GPU budget, test rules) for the AI assistant |

## How to reproduce

The scripts expect this folder at `/work/u1131128/coding-adv1` on nano4 (`tools/sync.sh push` puts it there).

```bash
harness/reproduce.sh build     # login node, no GPU: clone v5.7.0, apply our patches, compile (~1 h)
harness/reproduce.sh run       # submit the timing jobs on 1, 4 and 8 GPUs
harness/reproduce.sh verify    # check every result is bit-for-bit the same as plain v5.7.0, print a summary
```

To get our version of MFC anywhere else, apply the patches to v5.7.0 yourself:

```bash
git clone https://github.com/MFlowCode/MFC mfc && cd mfc
git checkout 0b3d56c8e1c9a3aa8d112681b72c87ab69fe5f13      # v5.7.0
git am --keep-cr /path/to/this/repo/patches/opt/*.patch
```

## Putting this on GitHub

This folder is already a git repo with the full history. After `gh auth login`:

```bash
git branch -m master main                        # optional: rename the branch
gh repo create coding-adv1 --private --source . --push
```

Keep the repo **private**: it contains the cluster account and project IDs.
