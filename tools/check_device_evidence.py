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


def qualifies_at07(doc: dict, version: str) -> list[str]:
    """Reasons this perf evidence does NOT satisfy AT-07 (empty list = it does).

    Deliberately stricter than the functional gate. A latency claim is easy to fake by
    accident: an emulator, a 600-row table, or a median that hides one slow frame would each
    produce a green-looking file. Every one of those is checked here, independently of whatever
    the recording script asserted.
    """
    reasons = []
    if doc.get("schema") != "morphic/perf-evidence/1":
        reasons.append("not perf evidence")
        return reasons
    if doc.get("appVersion") != version:
        reasons.append(f"version {doc.get('appVersion')!r} != {version!r}")
    if doc.get("physicalDevice") is not True:
        reasons.append("not a physical device")
    if doc.get("rehearsal") is True:
        reasons.append("marked as a rehearsal")
    if doc.get("at07Evidence") is not True:
        reasons.append("not marked as AT-07 evidence")
    probe = doc.get("probe") or {}
    if probe.get("schema") != "morphic/perf-probe/1":
        reasons.append("unknown probe schema")
    rows = probe.get("rowCount")
    # Check the count, not just the flag derived from it: a hand-edited or buggy recorder
    # could set representative=true on a 600-row run, and the gate is the last line of defence.
    if not isinstance(rows, int) or rows < 100000:
        reasons.append(f"dataset of {rows} rows is below AT-01's 100000")
    elif probe.get("representative") is not True:
        reasons.append("probe did not mark the dataset representative")
    if probe.get("passes") is not True:
        reasons.append(f"probe did not pass (worst {probe.get('worstMs')} ms)")
    budget = probe.get("budgetMs")
    worst = probe.get("worstMs")
    if not isinstance(budget, (int, float)) or not isinstance(worst, (int, float)):
        reasons.append("timings missing")
    elif budget > 150:
        reasons.append(f"budget {budget} ms is looser than AT-07's 150 ms")
    elif worst > budget:
        reasons.append(f"worst {worst} ms exceeds the stated budget {budget} ms")
    samples = probe.get("samples") or []
    if len(samples) < 5:
        reasons.append(f"only {len(samples)} samples; at least 5 are required")
    elif any((s.get("ms") or 0) > 150 for s in samples):
        reasons.append("a sample exceeds 150 ms even though the verdict claims a pass")
    if not doc.get("gitSha"):
        reasons.append("git sha not recorded")
    # AT-07 asks about a *mid-class* phone. A low-class pass is a strictly stronger result on
    # the same architecture, so it is accepted and reported as such. A flagship pass answers a
    # different question and is not a substitute — that is the substitution this gate exists
    # to prevent.
    cls = (doc.get("device") or {}).get("class")
    if cls not in ("low", "mid"):
        reasons.append(f"device class {cls!r} does not answer AT-07's mid-class question")
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
    ap.add_argument(
        "--require-at07",
        action="store_true",
        help="also require passing AT-07 latency evidence from a physical device "
             "(the M1.3 exit clause); see tools/device_perf.sh",
    )
    args = ap.parse_args()

    required = [c.strip() for c in args.require_classes.split(",") if c.strip()]
    docs, problems = load_evidence(pathlib.Path(args.dir))

    covered: dict[str, str] = {}
    print(f"Device-evidence gate for version {args.version}")
    print(f"  required classes: {', '.join(required)}")
    if not docs:
        print("  no evidence files found.")
    functional = [d for d in docs if d.get("schema") == "morphic/device-evidence/1"]
    perf = [d for d in docs if d.get("schema") == "morphic/perf-evidence/1"]
    for doc in functional:
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

    if args.require_at07:
        print()
        print("AT-07 latency gate (filter + sort, 100k x 10, <= 150 ms, physical device)")
        at07_ok = None
        for doc in perf:
            reasons = qualifies_at07(doc, args.version)
            label = doc.get("_file", "?")
            if reasons:
                print(f"  SKIP {label}: {'; '.join(reasons)}")
                continue
            at07_ok = doc
            print(f"  OK   {label}: {doc['device'].get('model')} "
                  f"worst {doc['probe']['worstMs']} ms")
            break
        if at07_ok is None:
            print()
            print("AT-07 BLOCKED — no passing physical-device latency evidence.")
            print("On the phone, with a 100k x 10 workspace open:")
            print('  tools/device_perf.sh --tester "Your Name" --class mid')
            print("An emulator rehearsal does not count, and neither does a smaller table.")
            return 1

    print()
    print("Device-evidence gate PASSED for classes: " + ", ".join(sorted(covered)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
