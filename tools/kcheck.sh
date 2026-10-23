#!/usr/bin/env bash
# tools/kcheck.sh SRC.fpp KERNEL_REGEX [STAGING]  (nano4 login node, no GPU)
# EXTRA="<flags>" appends compiler flags (e.g. -gpu=maxregcount:168).
# Compiles one simulation source with the exact flags of the case-optimized build in STAGING and prints, per matching
# kernel, registers/stack and the SASS memory-instruction mix. Lets a kernel variant be screened in ~1 min.
set -euo pipefail
src=$(realpath "${1:?src.fpp}"); kre=${2:?kernel regex}
here=$(cd "$(dirname "$0")/.." && pwd)
B=${3:-$here/mfc-opt/build/staging/gpu-acc-3b50febf95}
source "$here/scripts/env.sh" >/dev/null 2>&1
name=$(basename "$src" .fpp)
out=$here/kcheck/$(basename "$(dirname "$src")")-$name-$(date +%H%M%S); mkdir -p "$out"; cd "$out"
fy=$(grep -A4 "^fypp/simulation/$name.fpp.f90:" "$B"/CMakeFiles/simulation_lib.dir/build.make | grep -m1 "bin/fypp " | sed 's/^\s*//')
fy=${fy% *}; fy=${fy% *}                       # drop the original input/output paths
eval "$fy" "$src" "$out/$name.fpp.f90"
cmd=$(python3 -c "
import json,sys
for c in json.load(open('$B/compile_commands.json')):
    if c['file'].endswith('/$name.fpp.f90') and 'Minline=lib' in c['command']: print(c['command']); break
else:  # file compiled inside m_riemann_unity.f90: all simulation files share the same flags
    for c in json.load(open('$B/compile_commands.json')):
        if '/fypp/simulation/' in c['file'] and 'Minline=lib' in c['command']: print(c['command']); break")
cmd=${cmd% -c *}
cmd=${cmd//-Minline=lib:simulation_lib/-Minline=lib:$B/simulation_lib}
$cmd ${EXTRA:-} -I"$B" -module "$out" -c "$out/$name.fpp.f90" -o "$out/$name.o" > compile.log 2>&1 || { tail -20 compile.log; exit 1; }
cub=$(ls "$out"/*.n001.cubin | head -1)
for k in $(cuobjdump --dump-resource-usage "$cub" | grep -oE "Function [A-Za-z0-9_]+" | awk '{print $2}' | grep -E "$kre"); do
  ru=$(cuobjdump --dump-resource-usage -fun "$k" "$cub" 2>/dev/null | grep -oE "REG:[0-9]+|STACK:[0-9]+" | tr '\n' ' ')
  mix=$(cuobjdump -sass -fun "$k" "$cub" | grep -oE "^\s+/\*[0-9a-f]+\*/\s+(@!?U?P[0-9T] )?[A-Z0-9_.]+" | awk '{print $NF}' |
        sed -E 's/\..*//' | awk '{n++; c[$1]++} END{printf "inst:%d", n; split("LDG STG LDL STL LD ST DFMA",o," "); for(i in o) printf " %s:%d", o[i], c[o[i]]}')
  echo "$k $ru $mix"
done
echo "out: $out"
# KLINES=<kernel> also prints local/generic memory ops per source line of that kernel
if [[ -n ${KLINES:-} ]]; then
  nvdisasm -g "$cub" 2>/dev/null | awk -v K="$KLINES" '
    /\.section[ \t]+\.text\./ {infn = index($0, "." K ",") > 0}
    !infn {next}
    /## File/ {match($0,/line [0-9]+/); ln=substr($0,RSTART+5,RLENGTH-5); f=$0; sub(/.*\//,"",f); sub(/".*/,"",f); next}
    /\/\*[0-9a-f]+\*\// { op=$0; sub(/.*\*\/[ \t]+/,"",op); sub(/^@!?U?P[0-9T] /,"",op); sub(/[ \t].*/,"",op); sub(/\..*/,"",op);
       if (op ~ /^(LDL|STL|ST|LD)$/) print f":"ln, op }' | sort | uniq -c | sort -t: -k2n | awk '{printf "%s %s:%s  ", $2, $3, $1} END{print ""}'
fi
