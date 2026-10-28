# AP Research: WRF and MFC for the SC26 SCC

The AP Research side of Coding-Adv-HW-1 asks for a study of both SC26 applications; the coding side does one (MFC on
nano4, see [`../report.md`](../report.md)). These briefs are that study.

| Brief | Machine | Basis |
|---|---|---|
| [`wrf.md`](wrf.md) | NCHC F1 (2× Xeon 8480+, CPU) | Research only: WRF v4.8.0 / WPS v4.7.0 source, docs, SC26 webinar, published benchmarks. Nothing run on F1. |
| [`mfc.md`](mfc.md) | NCHC nano4 (8× H200) | MFC v5.7.0 source and docs, plus our measured profiles and optimizations in this repo. |

Each brief has the same shape: what the app computes, its parallel model, where the time goes, build/run on the target
machine, correctness, ranked optimization approaches, SC26 rules, open questions, references.

Provenance: rewritten on 2026-10-28 from the ap-hw2 knowledge packs (`ap-hw2/research/{wrf,mfc,hardware}_facts.md`,
`web_notes_wrf.md`), which were written in an exam Q&A format. Where the old MFC facts disagree with our measurements,
`mfc.md` says so and trusts the measurements.
