#!/usr/bin/env python3
"""Print the visible text/content-desc nodes of a uiautomator dump.

Raw XML dumps are unreadable in CI logs (one enormous line, truncated by `cut`). This prints
one node per line so a failure actually tells you which screen the app was on.

Usage: tools/ui_texts.py [/tmp/ui.xml] [--limit 60]
"""
import argparse
import sys
import xml.etree.ElementTree as ET


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", default="/tmp/ui.xml")
    ap.add_argument("--limit", type=int, default=60)
    args = ap.parse_args()

    try:
        tree = ET.parse(args.path)
    except (OSError, ET.ParseError) as exc:
        print(f"cannot parse {args.path}: {exc}")
        return 1

    shown = 0
    for node in tree.iter("node"):
        text = node.get("text", "")
        desc = node.get("content-desc", "")
        if not text and not desc:
            continue
        label = text or desc
        kind = "text" if text else "desc"
        print(f"  {kind}={label!r} bounds={node.get('bounds')}")
        shown += 1
        if shown >= args.limit:
            print(f"  … (truncated at {args.limit} nodes)")
            break
    if shown == 0:
        print("  (no text nodes on screen)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
