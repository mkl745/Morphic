#!/usr/bin/env python3
"""Print the first data-table row range found in a uiautomator UI dump.

The runtime renders ranges like `1–256 of 4,096` (en dash) or `0 of 0`. A raw grep is
unreliable because the dump may encode the dash as a character reference, so this parses the
XML properly and normalizes the dash before matching.

Usage: tools/read_row_range.py [/tmp/ui.xml] [--signature]

--signature prints a fingerprint of the first visible data row instead of the range. Paging
is then proven by the fingerprint changing, which does not depend on how Flutter exposes the
pager label to the accessibility tree.
Prints the range, or nothing if no table range is on screen. Exit code is always 0 unless
the file cannot be read, so callers can test for an empty string.
"""
import re
import sys
import xml.etree.ElementTree as ET

RANGE = re.compile(r"([\d,]+)\s*[-\u2010-\u2015]\s*([\d,]+)\s+of\s+([\d,]+)")
EMPTY = re.compile(r"\b0\s+of\s+([\d,]+)")


def first_data_row(tree) -> str:
    """The first node that looks like a rendered data row (multi-cell, not a header)."""
    for node in tree.iter("node"):
        for attr in ("text", "content-desc"):
            raw = node.get(attr, "")
            # Data rows carry values (digits); a merged header row does not.
            if (raw.count("\n") >= 2 and any(c.isdigit() for c in raw)
                    and not RANGE.search(raw)):
                return " ".join(raw.split())[:200]
    return ""


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    signature = "--signature" in sys.argv
    path = args[0] if args else "/tmp/ui.xml"
    try:
        tree = ET.parse(path)
    except (OSError, ET.ParseError) as exc:
        print(f"cannot parse {path}: {exc}", file=sys.stderr)
        return 1

    if signature:
        print(first_data_row(tree))
        return 0

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
