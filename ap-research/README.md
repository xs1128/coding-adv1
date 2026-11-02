# AP Research: WRF and MFC for the SC26 SCC

This folder studies both SC26 apps; the coding part speeds up only MFC ([`../report.md`](../report.md)).

- [`wrf.md`](wrf.md): WRF on the CPU cluster F1. Reading only (code, docs, webinar, benchmarks); nothing run.
- [`mfc.md`](mfc.md): MFC v5.7.0 on nano4 (8× H200 GPUs), plus our own measurements.

Both cover what the app computes, how it splits work, where time goes, checking answers, speed-up ideas, rules and open
questions. Rewritten on 2026-10-28 from older notes; where those disagree with our measurements, `mfc.md` trusts the
measurements.
