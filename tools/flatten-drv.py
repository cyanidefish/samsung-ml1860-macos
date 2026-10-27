#!/usr/bin/env python3
"""Flatten a SpliX .drv.in file for ppdc.

SpliX's driver files use a custom `#import "file"` line that ppdc doesn't
understand. This expands those lines (like upstream's ppd/compile.sh, without
needing GNU sed) and points the filter at an absolute path, which is where
macOS expects third-party printer filters.

Usage: flatten-drv.py SOURCE.drv.in FILTER_PATH > OUTPUT.drv
"""
import os
import re
import sys

IMPORT = re.compile(r'^[ \t]*#import[ \t]*"([A-Za-z0-9.\-]+)"')
FILTER_LINE = "Filter application/vnd.cups-raster 0 rastertoqpdl"


def expand(path, base, out):
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = IMPORT.match(line)
            if m:
                expand(os.path.join(base, m.group(1)), base, out)
            else:
                out.append(line)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    src, filter_path = sys.argv[1], sys.argv[2]
    lines = []
    expand(src, os.path.dirname(src), lines)
    text = "".join(lines)
    if FILTER_LINE not in text:
        sys.exit("error: filter line not found; has the upstream file changed?")
    sys.stdout.write(text.replace(
        FILTER_LINE, "Filter application/vnd.cups-raster 0 " + filter_path))


if __name__ == "__main__":
    main()
