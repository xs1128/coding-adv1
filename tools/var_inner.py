#!/usr/bin/env python3
"""Turn `collapse=4` loops whose outermost loop runs over variables into `collapse=3` over space plus a `seq`
variable loop inside (the upstream #2087 pattern). Per-element arithmetic is unchanged; loop-invariant
`inv_ds = ...` lines move above the variable loop.

  tools/var_inner.py FILE LINE [LINE ...]    (LINE = 1-based line of the GPU_PARALLEL_LOOP directive)
"""
import re
import sys

path, lines_at = sys.argv[1], sorted((int(a) for a in sys.argv[2:]), reverse=True)
src = open(path).read().split("\n")
DO = re.compile(r"^(\s*)do\s+(\w+)\s*=")
for at in lines_at:
    i = at - 1
    d = i
    while "collapse=4" not in src[d] and d < i + 2:      # directive may continue on the next line
        d += 1
    assert "GPU_PARALLEL_LOOP" in src[i] and "collapse=4" in src[d], (at, src[i])
    j = d + 1
    while not DO.match(src[j]):
        j += 1
    m = [DO.match(src[j + t]) for t in range(4)]
    assert all(m), (at, src[j:j + 4])
    ind, var = m[0].group(1), m[0].group(2)
    assert re.search(r"=\s*1\s*,\s*(sys_size|v_size|nb|num_fluids)\b", src[j]), (at, src[j])
    # body = lines after the 4th do up to the matching 4 end do's
    k, depth = j + 4, 4
    while depth:
        t = src[k].strip()
        if DO.match(src[k]):
            depth += 1
        elif t.startswith("end do"):
            depth -= 1
        k += 1
    body, ends = src[j + 4:k - 4], src[k - 4:k]
    hoist = [b for b in body if re.match(r"\s*inv_ds\s*=", b) and not re.search(rf"\b{var}\b", b.split("=", 1)[1])]
    body = [b for b in body if b not in hoist]
    sp = [src[j + t][4:] for t in (1, 2, 3)]
    inner = ind + " " * 12
    new = sp + [inner + h.strip() for h in hoist] + [inner + "$:GPU_LOOP(parallelism='[seq]')", inner + src[j].strip()] \
        + body + ends
    src[d] = src[d].replace("collapse=4", "collapse=3")
    src[j:k] = new
    print(f"{path}:{at}: {var} moved inside; hoisted {len(hoist)}")
open(path, "w").write("\n".join(src))
