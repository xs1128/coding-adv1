#!/usr/bin/env bash
# tools/package.sh -> dist/mfc-baseline-<commit>.tar.gz: the 1-GPU baseline + official comparison, self-contained
# (report, reproduce script, harness, patches, raw results). Run locally after tools/sync.sh pull; tree must be clean.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
[[ -z $(git status --porcelain) ]] || { echo "commit first: the package is named after HEAD" >&2; exit 1; }
sha=$(git rev-parse --short HEAD)
name=mfc-baseline-$sha
mkdir -p dist
git archive --format=tar --prefix="$name/" HEAD \
  baseline harness scripts patches tools/sync.sh docs/harness.md \
  results/jobs.tsv results/base/official_1g results/base/v493_official_1g results/base/v493_samecfg_1g \
  results/ref/perf3d_201_30 results/prof/nsys_v570_1g_30 results/prof/nsys_v493_1g_30 | gzip -9 > "dist/$name.tar.gz"
tar -tzf "dist/$name.tar.gz" | wc -l | xargs echo "files:"
ls -la "dist/$name.tar.gz"
