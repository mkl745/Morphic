#!/usr/bin/env python3
"""Print the first data-table row range found in a uiautomator UI dump.

The runtime renders ranges like `1–256 of 4,096` (en dash) or `0 of 0`. A raw grep is
unreliable because the dump may encode the dash as a character reference, so this parses the
XML properly and normalizes the dash before matching.

Usage: tools/read_row_range.py [/tmp/ui.xml]
Prints the range, or nothing if no table range is on screen. Exit code is always 0 unless
the file cannot be read, so callers can test for an empty string.
"""
import re
import sys
import xml.etree.ElementTree as ET

RANGE = re.compile(r"([\d,]+)\s*[-\u2010-\u2015]\s*([\d,]+)\s+of\s+([\d,]+)")
EMPTY = re.compile(r"\b0\s+of\s+([\d,]+)")


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ui.xml"
    try:
        tree = ET.parse(path)
    except (OSError, ET.ParseError) as exc:
        print(f"cannot parse {path}: {exc}", file=sys.stderr)
        return 1

    for node in tree.iter("node"):
        for attr in ("text", "content-desc"):
            raw = node.get(attr, "")
            if not raw:
                continue
            text = raw.replace("\u00a0", " ")
            m = RANGE.search(text)
            if m:
                print(f"{m.group(1)}-{m.group(2)} of {m.group(3)}")
                return 0
            m = EMPTY.search(text)
            if m:
                print(f"0 of {m.group(1)}")
                return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
