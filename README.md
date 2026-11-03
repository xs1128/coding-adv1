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

All runs in one job on one node, taking turns (job 686551, 2026-11-03, 2 rounds). Every run's final answer is
**bit-for-bit identical** to plain v5.7.0.

| Version | Time per step | Faster than v5.7.0 |
|---|---|---|
| MFC v5.7.0 (original) | 76.9 ms | 1× |
| Ours, previous version: patches 0001–0024 ("P20") | 29.7 ms | 2.59× |
| **Ours: v5.7.0 + patches 0001–0030 ("P21")** | **28.3 ms** | **2.72×** |

P21 is 4.75 % faster per step than P20. The whole run's wall time is about the same for both (median 5.63 s for P21 vs
5.56 s for P20, in the run-to-run noise of ±0.2 s), because start-up and saving take most of it. An earlier job on
another node (680943) gave 77.8 ms and 29.8 ms (2.61×) for v5.7.0 and P20.

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

**Waiting for the full test suite** ([`patches/pending/`](patches/pending/)): 0031 sets the boundary code's few
numbers on the GPU with one tiny kernel instead of 9 small copies from the CPU per call. That removes a 21 ms one-off
cost in the first step (the GPU runtime had to set up a pinned copy buffer for the second queue) and makes each step
0.3 % faster (job 686808, bitwise); all 34 CBC tests pass (686876).

**Run settings (disclosed, no code change):** at 1 GPU, Open MPI without UCX (`ob1`) and a run directory in node-local
memory (`/dev/shm`) cut the wall time of a whole run, start-up and save included, to about 3.8 s (job 684750).

**Since the 10-31 report**, the time per step at 1 GPU went from ~60 ms to ~28 ms (see [`report.md`](report.md) §11).

## Folder map

| Folder / file | What's inside |
|---|---|
| [`report.md`](report.md) | The full write-up (also built as `dist/report.pdf` by `tools/build_pdf.py`) |
| [`slides/`](slides/) | Slides for the 11-11 talk ([Slidev](https://sli.dev)): `cd slides && npm install && npm run dev`; `npm run export` writes `dist/slides.pdf` |
| [`patches/opt/`](patches/opt/) | Our 30 changes to MFC, one per file |
| [`patches/pending/`](patches/pending/) | One newer change (0031) that is faster and gives the same answers, but has not had the full test suite yet |
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
