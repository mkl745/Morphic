#!/usr/bin/env python3
"""Generate the 10 MB / 100k x 10 sales CSV that AT-01 names but the repo does not carry.

AT-01 (`docs/roadmap/mvp-acceptance-tests.md`) measures "import fixtures/valid/sales.csv
(~10 MB, 100k x 10) -> workspace in <= 3 s". That file was never committed: a 10 MB fixture
would bloat every clone to answer a question that only a physical device can answer. This
generator produces it on demand, deterministically, so two testers measure the same bytes.

The output is **not** a fixture and must not be committed. The default destination is under
`build/`, which is gitignored.

Usage:
    tools/gen_perf_csv.py                              # ~10 MB, clean
    tools/gen_perf_csv.py --rows 250000 --out build/perf/big.csv
    tools/gen_perf_csv.py --bad-rows 5 --out build/perf/sales-review.csv

Why --bad-rows exists
---------------------
A clean, confident import navigates straight to the workspace, so the import screen's
"<N> rows imported in <M> ms" line disappears before it can be read. Adding a handful of
ragged rows makes the import quarantining, which keeps the review card on screen and the
millisecond figure readable. It is a *companion* measurement, not a replacement for timing
the clean import end to end.

Then push it to the handset and pick it through the app's own file picker:
    adb push build/perf/sales-10mb.csv /sdcard/Download/sales-10mb.csv
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path

REGIONS = ["Europe", "North America", "LATAM", "APAC", "MEA", "Oceania"]
CHANNELS = ["Web", "Partner", "Retail"]
PRODUCTS = [
    "Widget Pro", "Widget Lite", "Sensor Kit", "Gateway Hub", "Cable Pack",
    "Mount Bracket", "Power Unit", "Spare Filter", "Field Case", "Relay Board",
    "Antenna Set", "Service Plan",
]
REPS = [
    "Ana Ferreira", "Ben Okafor", "Chen Wei", "Dana Levi",
    "Emil Novak", "Farah Haddad", "Gus Moreau", "Hana Sato",
]
NOTES = [
    "Bulk order; expedited shipping",
    "Renewal of annual contract",
    "Replacement under warranty",
    "First order from new account",
    "Requested invoice by post",
    "Discount approved by regional lead",
    "Ships with the maintenance kit",
    "Customer asked for a callback",
]

HEADER = [
    "order_id", "ordered_at", "region", "channel", "product",
    "units", "unit_price", "revenue", "sales_rep", "notes",
]


def build(rows: int, bad_rows: int, seed: int) -> bytes:
    rng = random.Random(seed)
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    buf = io.StringIO(newline="")
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(HEADER)

    # Spread the ragged rows through the file rather than parking them at the end, so the
    # quarantine report is exercised across the whole scan and not only at EOF.
    bad_at = set()
    if bad_rows > 0:
        step = max(1, rows // (bad_rows + 1))
        bad_at = {step * (i + 1) for i in range(bad_rows)}

    for i in range(rows):
        ts = start + timedelta(seconds=rng.randrange(0, 365 * 24 * 3600))
        units = rng.randint(1, 25)
        price = rng.choice([19.5, 49.99, 129.99, 249.0, 899.0, 1299.5])
        row = [
            1000000 + i,
            ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
            rng.choice(REGIONS),
            rng.choice(CHANNELS),
            rng.choice(PRODUCTS),
            units,
            f"{price:.2f}",
            f"{units * price:.2f}",
            rng.choice(REPS),
            rng.choice(NOTES),
        ]
        if i + 1 in bad_at:
            # Two fields short: a ragged row the CSV reader must quarantine, not crash on.
            row = row[:-2]
        w.writerow(row)
    return buf.getvalue().encode("utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rows", type=int, default=100_000,
                    help="data rows, excluding the header (default: 100000)")
    ap.add_argument("--bad-rows", type=int, default=0,
                    help="ragged rows to inject so the import stays on the review screen")
    ap.add_argument("--seed", type=int, default=20261106, help="deterministic by default")
    ap.add_argument("--out", type=Path, default=Path("build/perf/sales-10mb.csv"))
    args = ap.parse_args()

    if args.rows < 1:
        ap.error("--rows must be positive")
    if args.bad_rows < 0 or args.bad_rows >= args.rows:
        ap.error("--bad-rows must be between 0 and --rows - 1")

    data = build(args.rows, args.bad_rows, args.seed)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(data)

    mib = len(data) / (1024 * 1024)
    print(f"wrote {args.out}")
    print(f"  rows      {args.rows:,} (+1 header), 10 columns")
    print(f"  ragged    {args.bad_rows}")
    print(f"  bytes     {len(data):,}  ({mib:.2f} MiB)")
    print(f"  sha256    {hashlib.sha256(data).hexdigest()}")
    print()
    print("Push it to the handset, then import it through the app's file picker:")
    print(f"  adb push {args.out} /sdcard/Download/{args.out.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
