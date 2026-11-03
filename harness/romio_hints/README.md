# ROMIO hint files

Pass one with `ROMIO_HINTS=$ROOT/harness/romio_hints/<file>` in `RUN_ENV` or `ENV_<arm>`. ROMIO reads the file when a
file is opened. These are the files tried for the 4-GPU restart save (ladder row 95), where ROMIO's two-phase write
went through a 16 MB buffer: 32 rounds, each building new MPI datatypes on rank 0 (nsys 697602,
`results/prof/nsys_4g_lean/save_samples.txt`).

| File | Hints |
|---|---|
| `cb256` | 256 MB collective buffer |
| `cb256x4` | 256 MB buffer, 4 aggregators on the node |
| `nocb` | no collective buffering for reads and writes |
