#!/usr/bin/env python3
"""Regenerate the bundled demo CSV deterministically.

The demo asset must be large enough to exercise **paging**: the compiler emits
`page_size: 256`, so a 12-row sample fits on one page and the device harness could never
verify `tablePaging`. 600 rows gives three pages (256 / 256 / 88).

Deterministic (fixed seed, fixed base timestamp) so the asset is reproducible and diffs stay
meaningful. Latency values deliberately repeat: a perfectly unique integer column would be
classified as an identifier and earn no measure metric.

Usage: tools/gen_sample_logs.py [--rows 600] [--out path]
"""
import argparse
import csv
import datetime as dt
import pathlib
import random

SERVICES = ["api", "auth", "db", "cache", "worker", "gateway"]
LEVELS = ["INFO", "INFO", "INFO", "DEBUG", "WARN", "ERROR"]  # weighted, realistic mix
MESSAGES = {
    "INFO": [
        "Request received", "Token validated", "Cache hit", "Job completed",
        "Connection established", "Response sent",
    ],
    "DEBUG": ["Entering handler", "Query plan chosen", "Pool stats sampled"],
    "WARN": ["Slow query", "Retry scheduled", "Cache miss storm", "Queue depth high"],
    "ERROR": ["Upstream timeout", "Constraint violation", "Connection reset", "Auth failed"],
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=600)
    ap.add_argument(
        "--out",
        default="apps/morphic_flutter/assets/samples/sample_logs.csv",
    )
    args = ap.parse_args()

    rng = random.Random(20261105)
    base = dt.datetime(2026, 11, 5, 14, 0, 0, tzinfo=dt.timezone.utc)
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    with out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["time", "level", "service", "message", "latency_ms"])
        elapsed = 0
        for _ in range(args.rows):
            elapsed += rng.randint(1, 4)
            ts = (base + dt.timedelta(seconds=elapsed)).strftime("%Y-%m-%dT%H:%M:%SZ")
            level = rng.choice(LEVELS)
            service = rng.choice(SERVICES)
            message = rng.choice(MESSAGES[level])
            # Repeating values, with a heavier tail for errors.
            latency = rng.choice([4, 8, 12, 16, 20, 24, 32, 48, 64, 96])
            if level == "ERROR":
                latency *= rng.choice([4, 8])
            elif level == "WARN":
                latency *= 2
            w.writerow([ts, level, service, message, latency])

    print(f"wrote {args.rows} rows to {out} ({out.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
