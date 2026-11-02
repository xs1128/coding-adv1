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

All runs in one job on one node, taking turns (job 680943, 2026-11-03). Every run's final answer is
**bit-for-bit identical** to plain v5.7.0.

| Version | Time per step | Faster than v5.7.0 |
|---|---|---|
| MFC v5.7.0 (original) | 77.8 ms | 1× |
| **Ours: v5.7.0 + patches 0001–0024 ("P20")** | **29.8 ms** | **2.61×** |
| Ours + 2 newer patches (0025–0026, still waiting for the full test suite) | 29.5 ms | 2.64× |
| Ours + 3 newer patches (0025–0027, same; 0027 measured in a second A/B, so this is an estimate) | about 29.0 ms | about 2.68× |

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

**Waiting for the full test suite** ([`patches/pending/`](patches/pending/)): 0025 lets the CPU queue one more
boundary step instead of waiting for it, and 0026 fills the edge ("ghost") cells with one GPU thread per value. Together
they save another 1.1 %. 0027 stops the boundary code (CBC) from copying data that its own kernels overwrite anyway;
it saves another 1.6 % (jobs 681650 and 683029, bitwise) and passes all 34 CBC tests (682349). With all three, the 49
boundary-condition tests give 45 passes and the 4 known failures, unchanged from P20 (684975, 685001).
On 4 GPUs the three of them make each step 5.4 % faster than P20 (8.99 → 8.52 ms, job 685059, bitwise).
0028 runs the small boundary (CBC) kernels on a second GPU queue next to the main solver kernel: −0.7 % more at 1 GPU
(685237, bitwise), −2.8 % at 4 GPUs (685274); the 5 tests that use it pass (685267).

**Run settings (disclosed, no code change):** at 1 GPU, Open MPI without UCX (`ob1`) and a run directory in node-local
memory (`/dev/shm`) cut the wall time of a whole run, start-up and save included, to about 3.8 s (job 684750).

**Since the 10-31 report**, the time per step at 1 GPU went from ~60 ms to ~30 ms (see [`report.md`](report.md) §11).

## Folder map

| Folder / file | What's inside |
|---|---|
| [`report.md`](report.md) | The full write-up (also built as `dist/report.pdf` by `tools/build_pdf.py`) |
| [`slides/`](slides/) | Slides for the 11-11 talk ([Slidev](https://sli.dev)): `cd slides && npm install && npm run dev`; `npm run export` writes `dist/slides.pdf` |
| [`patches/opt/`](patches/opt/) | Our 24 changes to MFC, one per file |
| [`patches/pending/`](patches/pending/) | Four newer changes that are faster and give the same answers, but have not had the full test suite yet |
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
