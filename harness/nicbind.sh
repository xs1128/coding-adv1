#!/usr/bin/env bash
# mpirun ... harness/nicbind.sh CMD...   Pins each rank's UCX to the InfiniBand HCA next to its GPU (PIX in
# `nvidia-smi topo -m`). Without it UCX opens all 10 HCAs of a node, which costs seconds in MPI_Init/MPI_Finalize.
# NIC_MAP (one mlx5_N per visible GPU) is computed once per job: export NIC_MAP=$(harness/nicbind.sh --map)
if [[ ${1:-} == --map ]]; then
  nvidia-smi topo -m | sed 's/\x1b\[[0-9;]*m//g' | awk '
    /^\t*GPU0/ && !hdr { for (i = 1; i <= NF; i++) col[i] = $i; hdr = 1; next }
    /^GPU[0-9]+/ { for (i = 2; i <= NF; i++) if ($i == "PIX" && col[i - 1] ~ /^NIC/) { nic[$1] = col[i - 1]; break }
                   gpus[++n] = $1 }
    /^ *NIC[0-9]+: / { sub(":", "", $1); name[$1] = $2 }
    END { for (g = 1; g <= n; g++) printf "%s%s", (g > 1 ? " " : ""), name[nic[gpus[g]]]; print "" }'
  exit
fi
map=(${NIC_MAP:?run: export NIC_MAP=\$(harness/nicbind.sh --map)})
r=${OMPI_COMM_WORLD_LOCAL_RANK:-0}
export UCX_NET_DEVICES=${map[r % ${#map[@]}]}:1   # MFC uses GPU (local rank mod #GPUs)
exec "$@"
