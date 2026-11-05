#!/usr/bin/env python3
"""Tap the 'Run proof of concept' button by parsing a uiautomator UI dump.

Used by the CI Android runtime smoke (ci.yml) to drive the real app on the emulator and
verify the Rust CSV-profiling proof of concept end to end. Reads /tmp/ui.xml (produced by
`adb shell uiautomator dump` + `adb pull`), finds the button's bounds, and taps its center.
"""
import re
import subprocess
import sys

UI_XML = "/tmp/ui.xml"
BUTTON_TEXT = "Run proof of concept"


def main() -> int:
    try:
        xml = open(UI_XML, encoding="utf-8").read()
    except OSError as exc:
        print(f"cannot read {UI_XML}: {exc}")
        return 1

    # uiautomator nodes list text before bounds; match within a single node.
    pattern = (
        r'text="' + re.escape(BUTTON_TEXT) + r'"[^>]*'
        r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
    )
    match = re.search(pattern, xml)
    if not match:
        print(f"button {BUTTON_TEXT!r} not found in UI dump")
        return 1

    x1, y1, x2, y2 = map(int, match.groups())
    cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
    subprocess.run(["adb", "shell", "input", "tap", str(cx), str(cy)], check=True)
    print(f"tapped {BUTTON_TEXT!r} at ({cx}, {cy})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
