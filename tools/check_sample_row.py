#!/usr/bin/env python3
"""Check a smoke-test row announcement against the bundled synthetic log CSV.

This is intentionally specific to the PoC sample, which has no embedded comma-space in
any field. The workspace is unfiltered and unsorted, so the announced 1-based row number
identifies the source record. This verifies field/value association, not just pagination.
"""
import argparse
import csv
from datetime import datetime, timezone
from pathlib import Path
import re
import sys

SAMPLE = (
    Path(__file__).resolve().parent.parent
    / "apps/morphic_flutter/assets/samples/sample_logs.csv"
)


def check_row(signature: str, sample: Path = SAMPLE) -> tuple[bool, str]:
    match = re.fullmatch(r"Row (\d+): (.*)", signature, flags=re.DOTALL)
    if match is None:
        return False, "not an explicitly labelled data row"
    number = int(match.group(1))
    with sample.open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    if number < 1 or number > len(rows):
        return False, f"row number {number} is outside the bundled sample"

    actual: dict[str, str] = {}
    for item in match.group(2).split(", "):
        field, separator, value = item.partition(": ")
        if not separator or not field or field in actual:
            return False, "row does not contain distinct named fields"
        actual[field] = value

    expected = dict(rows[number - 1])
    # Rust stores timestamps as UTC and serializes them with millisecond precision.
    timestamp = datetime.fromisoformat(expected["time"].replace("Z", "+00:00"))
    expected["time"] = timestamp.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )
    if actual != expected:
        return False, f"row {number} fields do not match the sample: expected {expected}, got {actual}"
    return True, f"row {number} has the correct field/value associations"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("signature", help="row label from read_row_range.py --signature")
    args = parser.parse_args()
    try:
        ok, message = check_row(args.signature)
    except (OSError, ValueError, KeyError) as exc:
        print(f"cannot verify the bundled sample: {exc}", file=sys.stderr)
        return 1
    print(message, file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
