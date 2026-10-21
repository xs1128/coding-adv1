#!/usr/bin/env bash
# Mirror the local working tree to nano4 and pull results back (adapted from coding-hw3).
#   tools/sync.sh push [host]   local tree -> host:$REMOTE_DIR (no .git, reference/, mfc/, results/)
#   tools/sync.sh pull [host]   host:results/ -> local results/ (never deletes local files)
# The remote MFC checkout lives at $REMOTE_DIR/mfc and is managed with git there.
# push refuses a dirty tree so every result maps to a commit; ALLOW_DIRTY=1 overrides (recorded).
set -euo pipefail
cmd=${1:?push|pull}
host=${2:-nano4-u1131128}
remote_dir=${REMOTE_DIR:-/work/u1131128/coding-adv1}
repo=$(cd "$(dirname "$0")/.." && pwd)
SSH="ssh -F $HOME/hpc-relay/ssh/config"
case "$cmd" in
  push)
    desc=$(git -C "$repo" describe --always --dirty)
    if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
      [[ "$desc" == *-dirty ]] || desc="$desc-untracked"
      if [[ "${ALLOW_DIRTY:-0}" != 1 ]]; then
        echo "sync.sh: working tree is not clean ($desc); commit first, or ALLOW_DIRTY=1" >&2
        exit 3
      fi
    fi
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    ( cd "$repo"
      echo "commit=$(git rev-parse HEAD)"
      echo "describe=$desc"
      echo "pushed_at=$(date -Iseconds)" ) > "$tmp/.provenance"
    rsync -az --delete -e "$SSH" --exclude .git --exclude /.provenance --exclude /reference/ \
      --exclude /mfc/ --exclude /build/ --exclude /results/ --exclude /runs/ "$repo/" "$host:$remote_dir/"
    rsync -az -e "$SSH" "$tmp/.provenance" "$host:$remote_dir/.provenance"
    ;;
  pull)
    rsync -az -e "$SSH" --exclude '*.nsys-rep' --exclude '*.ncu-rep' --exclude '*.sqlite' \
      --exclude 'restart_data/' --exclude 'p_all/' --exclude 'silo_hdf5/' \
      "$host:$remote_dir/results/" "$repo/results/"
    ;;
  *) echo "usage: $0 push|pull [host]" >&2; exit 2;;
esac
