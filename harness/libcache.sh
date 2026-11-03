#!/usr/bin/env bash
# libcache.sh DIR: fill DIR with symlinks to every shared library in $LD_LIBRARY_PATH (first one found wins, as the loader
# would pick it), so that LD_LIBRARY_PATH=DIR resolves the same files with lookups that miss in node-local memory, not Lustre.
set -euo pipefail
d=$1; mkdir -p "$d"
IFS=: read -ra dirs <<<"${LD_LIBRARY_PATH:-}"
for p in "${dirs[@]}"; do
  [[ -d $p ]] || continue
  for f in "$p"/*.so*; do
    [[ -e $f ]] || continue
    b=${f##*/}; [[ -e $d/$b || -L $d/$b ]] || ln -s "$f" "$d/$b"
  done
done
