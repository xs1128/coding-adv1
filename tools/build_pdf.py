#!/usr/bin/env python3
"""report.md -> dist/report.html -> dist/report.pdf (Python-Markdown + headless Chrome).

  python3 tools/build_pdf.py        (needs the `markdown` package and google-chrome/chromium)
"""
import pathlib
import shutil
import subprocess

import markdown

REPO = pathlib.Path(__file__).resolve().parents[1]
DIST = REPO / "dist"
CSS = """
@page { size: A4; margin: 16mm 15mm; }
body { font: 10pt/1.4 "DejaVu Serif", Georgia, serif; color: #0b0b0b; }
h1 { font-size: 15pt; margin: 0 0 6pt; } h2 { font-size: 12pt; margin: 14pt 0 4pt; border-bottom: 1px solid #ccc; }
table { border-collapse: collapse; margin: 6pt 0; font-size: 8.6pt; page-break-inside: avoid; }
th, td { border: 1px solid #bbb; padding: 2pt 5pt; vertical-align: top; } th { background: #f0efec; }
code { font: 8.6pt "DejaVu Sans Mono", monospace; background: #f4f4f2; padding: 0 2px; }
pre { background: #f4f4f2; padding: 5pt; font-size: 8.4pt; }
img { max-width: 92%; display: block; margin: 6pt auto; page-break-inside: avoid; }
li { margin: 1pt 0; }
"""


def main():
    DIST.mkdir(exist_ok=True)
    body = markdown.markdown((REPO / "report.md").read_text(), extensions=["tables", "fenced_code", "sane_lists"])
    html = DIST / "report.html"
    html.write_text(f'<!doctype html><html><head><meta charset="utf-8"><title>MFC on H200</title>'
                    f'<base href="{REPO.as_uri()}/"><style>{CSS}</style></head><body>{body}</body></html>')
    chrome = next(shutil.which(c) for c in ("google-chrome", "chromium-browser", "chromium") if shutil.which(c))
    subprocess.run([chrome, "--headless", "--disable-gpu", "--no-pdf-header-footer",
                    f"--print-to-pdf={DIST / 'report.pdf'}", html.as_uri()], check=True, capture_output=True)
    print("wrote", DIST / "report.pdf")


if __name__ == "__main__":
    main()
