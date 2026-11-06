#!/usr/bin/env python3
"""Release gate: refuse to ship a version without physical-device evidence.

Implements the standing rule in docs/engineering/real-device-testing.md. Run by
release.yml before any artifact is built, and usable locally:

    tools/check_device_evidence.py --version 0.1.0
    tools/check_device_evidence.py --version 0.1.0 --require-classes low,mid,flagship

Exit 0 only if, for the requested version, there is passing evidence from a *physical*
device covering every required class. Emulator results never satisfy this gate.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

REQUIRED_CHECKS = (
    "install",
    "coldStart",
    "engineFfi",
    "poc",
    "generateWorkspace",
    "tablePaging",
    "reopenIdentical",
    "airplaneMode",
    "processDeath",
    "noCrash",
)
EVIDENCE_DIR = pathlib.Path("docs/engineering/device-evidence")


def load_evidence(directory: pathlib.Path) -> tuple[list[dict], list[str]]:
    docs: list[dict] = []
    problems: list[str] = []
    if not directory.is_dir():
        return docs, [f"{directory}/ does not exist — no device testing has been recorded."]
    for path in sorted(directory.glob("*.json")):
        try:
            doc = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            problems.append(f"{path.name}: unreadable ({exc})")
            continue
        doc["_file"] = str(path)
        docs.append(doc)
    return docs, problems


def qualifying(doc: dict, version: str) -> list[str]:
    """Return reasons this evidence does NOT qualify (empty list = it qualifies)."""
    reasons = []
    if doc.get("schema") != "morphic/device-evidence/1":
        reasons.append("unknown evidence schema")
    if doc.get("appVersion") != version:
        reasons.append(f"version {doc.get('appVersion')!r} != {version!r}")
    if doc.get("physicalDevice") is not True:
        reasons.append("not asserted as a physical device")
    if doc.get("result") != "pass":
        reasons.append(f"result is {doc.get('result')!r}, not 'pass'")
    checks = doc.get("checks") or {}
    missing = [c for c in REQUIRED_CHECKS if checks.get(c) != "pass"]
    if missing:
        reasons.append("checks not passed: " + ", ".join(missing))
    if not (doc.get("device") or {}).get("class"):
        reasons.append("device class not recorded")
    if not doc.get("apkSha256"):
        reasons.append("APK checksum not recorded")
    return reasons


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--version", required=True, help="version being released, e.g. 0.1.0")
    ap.add_argument(
        "--require-classes",
        default="mid",
        help="comma-separated device classes required (default: mid)",
    )
    ap.add_argument("--dir", default=str(EVIDENCE_DIR), help="evidence directory")
    args = ap.parse_args()

    required = [c.strip() for c in args.require_classes.split(",") if c.strip()]
    docs, problems = load_evidence(pathlib.Path(args.dir))

    covered: dict[str, str] = {}
    print(f"Device-evidence gate for version {args.version}")
    print(f"  required classes: {', '.join(required)}")
    if not docs:
        print("  no evidence files found.")
    for doc in docs:
        reasons = qualifying(doc, args.version)
        label = doc.get("_file", "?")
        if reasons:
            print(f"  SKIP {label}: {'; '.join(reasons)}")
            continue
        cls = doc["device"]["class"]
        covered.setdefault(cls, label)
        print(f"  OK   {label}: {doc['device'].get('model')} (class {cls})")

    for p in problems:
        print(f"  WARN {p}")

    missing = [c for c in required if c not in covered]
    if missing:
        print()
        print("RELEASE BLOCKED — missing passing physical-device evidence for class(es): "
              + ", ".join(missing))
        print("Run on real hardware:")
        print(f"  tools/device_smoke.sh <apk> --tester \"Your Name\" --class {missing[0]}")
        print("then commit the generated JSON under docs/engineering/device-evidence/.")
        print("See docs/engineering/real-device-testing.md. Emulator runs do not count.")
        return 1

    print()
    print("Device-evidence gate PASSED for classes: " + ", ".join(sorted(covered)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
