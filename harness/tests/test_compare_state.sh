#!/usr/bin/env bash
# Self-test of the correctness comparator: it must PASS identical states, PASS (non-bitwise) a 1-ulp change,
# and FAIL a 1e-9 relative perturbation, a NaN, a size mismatch and a missing file. Runs anywhere with numpy.
#   harness/tests/test_compare_state.sh [python]
set -uo pipefail
py=${1:-python3}
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
mk() {  # mk DIR MODE
  mkdir -p "$tmp/$1/restart_data"
  "$py" - "$tmp/$1/restart_data/lustre_30.dat" "$2" <<'PY'
import sys, numpy as np
rng = np.random.default_rng(1); a = rng.uniform(0.1, 1e5, 10000)
m = sys.argv[2]
if m == "ulp": a[17] = np.nextafter(a[17], np.inf)
if m == "pert": a[17] *= 1 + 1e-9
if m == "nan": a[17] = np.nan
if m == "short": a = a[:-1]
a.astype("<f8").tofile(sys.argv[1])
PY
  : > "$tmp/$1/restart_data/lustre_x_cb.dat"   # grid file must be ignored
}
expect() {  # expect WANT_EXIT NAME B
  "$py" "$here/compare_state.py" "$tmp/ref" "$tmp/$3" > "$tmp/out.json" 2>&1; rc=$?
  if [[ $rc == "$1" ]]; then echo "ok   $2 (exit $rc)"; else echo "FAIL $2: exit $rc, want $1"; cat "$tmp/out.json"; fails=$((fails+1)); fi
}
mk ref same; mk same same; mk ulp ulp; mk pert pert; mk nan nan; mk short short; mkdir -p "$tmp/empty"
expect 0 "identical -> PASS" same
grep -q '"bitwise": true' "$tmp/out.json" || { echo "FAIL identical not flagged bitwise"; fails=$((fails+1)); }
expect 0 "1 ulp -> PASS (not bitwise)" ulp
grep -q '"bitwise": false' "$tmp/out.json" || { echo "FAIL 1-ulp flagged bitwise"; fails=$((fails+1)); }
expect 1 "1e-9 relative perturbation -> FAIL" pert
expect 1 "NaN -> FAIL" nan
expect 1 "size mismatch -> FAIL" short
"$py" "$here/compare_state.py" "$tmp/ref" "$tmp/empty" > /dev/null 2>&1 && { echo "FAIL missing file accepted"; fails=$((fails+1)); } || echo "ok   missing restart file -> error"
echo "failures: $fails"; exit $(( fails > 0 ))
