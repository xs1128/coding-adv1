#!/usr/bin/env python3
"""Check a rewritten Markdown file against its last committed version.

A plain-language rewrite may drop numbers (it is shorter) but must never add one that was not there before, and every
relative link must still point at a file. Usage: tools/check_rewrite.py FILE [FILE...]   (compares with `git show HEAD:FILE`)
Exit status 1 when a file has new numbers or broken links.
"""

import re
import subprocess
import sys
from pathlib import Path

NUM = re.compile(r"(?<![A-Za-z_])[-+−]?\d[\d,]*(?:\.\d+)?(?:e[-+]?\d+)?")
LINK = re.compile(r"\]\(([^)#\s]+)(?:#[^)]*)?\)")


def numbers(text):
    return {m.group(0).lstrip("+-−").replace(",", "") for m in NUM.finditer(text)}


def main(paths):
    bad = False
    for p in paths:
        new = Path(p).read_text()
        try:
            old = subprocess.run(["git", "show", f"HEAD:{p}"], capture_output=True, text=True, check=True).stdout
        except subprocess.CalledProcessError:
            old = ""
        added = sorted(numbers(new) - numbers(old), key=lambda s: (len(s), s))
        broken = [
            t
            for t in LINK.findall(new)
            if not re.match(r"[a-z]+:", t) and not (Path(p).parent / t).exists()
        ]
        words_old, words_new = len(old.split()), len(new.split())
        print(f"{p}: {words_old} -> {words_new} words ({100 * words_new / max(words_old, 1):.0f} %)")
        if added:
            bad = True
            print(f"  numbers not in the old version: {' '.join(added)}")
        if broken:
            bad = True
            print(f"  broken links: {' '.join(broken)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
