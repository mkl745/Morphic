#!/usr/bin/env python3
"""Tap the 'Run proof of concept' button by parsing a uiautomator UI dump.

Used by the CI Android runtime smoke (ci.yml) to drive the real app on the emulator and
verify the Rust CSV-profiling proof of concept end to end. Reads /tmp/ui.xml (produced by
`adb shell uiautomator dump` + `adb pull`), finds the button node (text or content-desc),
and taps its center. Prints visible nodes if the button is not found, to aid debugging.
"""
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

UI_XML = "/tmp/ui.xml"
BUTTON_TEXT = "Run proof of concept"


def main() -> int:
    try:
        tree = ET.parse(UI_XML)
    except (OSError, ET.ParseError) as exc:
        print(f"cannot parse {UI_XML}: {exc}")
        return 1

    found = None
    for node in tree.iter("node"):
        text = node.get("text", "")
        desc = node.get("content-desc", "")
        if BUTTON_TEXT in text or BUTTON_TEXT in desc:
            found = node
            break

    if found is None:
        print(f"button {BUTTON_TEXT!r} not found. Visible text/desc nodes:")
        for node in tree.iter("node"):
            t, d = node.get("text", ""), node.get("content-desc", "")
            if t or d:
                print(f"  text={t!r} desc={d!r} bounds={node.get('bounds')}")
        return 1

    bounds = found.get("bounds", "")
    match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    if not match:
        print(f"could not parse bounds {bounds!r}")
        return 1
    x1, y1, x2, y2 = map(int, match.groups())
    cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
    subprocess.run(["adb", "shell", "input", "tap", str(cx), str(cy)], check=True)
    print(f"tapped {BUTTON_TEXT!r} at ({cx}, {cy})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
