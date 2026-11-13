#!/usr/bin/env python3
"""Scroll the workspace, not a nested table, using a uiautomator screen dump.

A centre swipe can be consumed by the table's own vertical list, leaving its pager below the
fold. The workspace has leading padding, so start a vertical swipe in that gutter instead.
The screen bounds come from the dump rather than assuming a particular device resolution.
MORPHIC_ADB_SERIAL selects a device when more than one is attached.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def swipe_coordinates(bounds: str) -> tuple[int, int, int, int]:
    match = BOUNDS.fullmatch(bounds)
    if not match:
        raise ValueError(f"invalid screen bounds: {bounds!r}")
    left, top, right, bottom = map(int, match.groups())
    width, height = right - left, bottom - top
    if width < 10 or height < 10:
        raise ValueError(f"empty screen bounds: {bounds!r}")
    # At most ten physical pixels from the edge: inside the workspace's 16 dp padding on
    # ordinary Android densities, but far enough inside for a vertical gesture to start.
    x = left + max(1, min(10, width // 100))
    return x, top + height * 4 // 5, x, top + height * 2 // 5


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ui.xml"
    try:
        root = ET.parse(path).getroot().find("node")
        if root is None:
            raise ValueError("UI dump has no root node")
        x1, y1, x2, y2 = swipe_coordinates(root.get("bounds", ""))
        serial = os.environ.get("MORPHIC_ADB_SERIAL")
        adb = ["adb"] + (["-s", serial] if serial else [])
        subprocess.run(
            adb + ["shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), "300"],
            check=True,
        )
        print(f"swiped workspace gutter from ({x1}, {y1}) to ({x2}, {y2})")
    except (OSError, ET.ParseError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"cannot scroll workspace: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
