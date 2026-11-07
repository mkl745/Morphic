# Measuring AT-07 on your phone

AT-07 requires **filter + sort over 100k × 10 in ≤ 150 ms, engine-side, on a mid-class ARM
device**. This is the one clause blocking the M1.3 exit. Everything else in that milestone is
done and CI-green.

Until now the number was simply unmeasured, and nothing in the repo could measure it:

- `engine/crates/morphic-query/tests/perf.rs` runs the right workload but on a **CI x86
  runner**. It reports 36–70 ms and says in its own header that this cannot confirm the ARM
  figure. A different machine is not a slower one.
- `tools/device_smoke.sh` runs on real hardware but checks ten *behaviours* and times none of
  them. Its polling helper sleeps three seconds per attempt, so it could not observe a 150 ms
  budget even if it looked.

`tools/device_perf.sh` closes that gap. It drives an in-app probe and reads the engine's own
timings out of logcat.

---

## What you need

- Your phone, USB-debugging enabled, one device attached (`adb devices` shows exactly one).
- A MORPHIC APK installed. **Use a release or profile build, not debug** — a debug build's
  Dart VM is not what a user runs, and its numbers are not the ones AT-07 is about.
- Python 3 and `adb` on your PATH.

## Steps

### 1. Generate the dataset and push it

AT-01's 10 MB / 100k × 10 CSV is deliberately not committed — it would bloat every clone.
Generate it deterministically instead:

```bash
tools/gen_perf_csv.py --out build/perf/sales-10mb.csv
adb push build/perf/sales-10mb.csv /sdcard/Download/sales-10mb.csv
```

Or let the script do both: `tools/device_perf.sh --push-csv …`.

### 2. Import it in the app

Open MORPHIC → **Import** → pick `sales-10mb.csv` from Download → wait for the workspace.
Leave the workspace open.

This step is manual on purpose: driving Android's system file picker from adb is brittle, and
a flaky import would produce a *missing* measurement, which is worse than a slow one.

**On the handsets actually available.** Both are **low** class (realme C51, Galaxy A15), not the
Pixel 6a-class phone the matrix names. That is not a reason to skip the measurement — it is a
*harder* target. A pass on a C51 is a stronger result than a pass on a Pixel 6a, so the gate
accepts `--class low` and says so. A flagship pass is **not** accepted: it answers a different
question, and substituting it is exactly what this gate exists to prevent.

Record the class honestly. `--class low` on a C51 is worth more than `--class mid` on one.

### 3. Run the measurement

```bash
tools/device_perf.sh --tester "Your Name" --class mid
```

The script opens the workspace's **Performance probe** action (the gauge icon in the app bar),
taps **Run probe**, waits for the engine's timings, and writes:

```
docs/engineering/device-evidence/0.1.0-RMX3830-20261107T120000Z-perf.json
```

It exits non-zero unless the probe ran, the dataset was representative, and the worst sample
passed. Commit the JSON with the milestone.

You can also just tap the gauge icon and read the verdict on screen — the script exists to
turn that into a file a gate can check.

### 4. Check the exit clause

```bash
tools/check_device_evidence.py --version 0.1.0 --require-at07
```

---

## What is actually timed

The whole `componentPage` round trip: the FFI call, the engine's filter + sort + page, and the
JSON decode of the returned rows.

That is an **upper bound** on engine-side time. A pass therefore proves the narrower engine-side
claim *a fortiori*, and it is closer to what you feel when you tap. A failure needs a look before
blaming the engine — the decode is inside the measurement.

The command that *sets* the filter is not timed. It mutates state and saves to disk, which is a
different operation from the read AT-07 names.

## Why the probe won't flatter you

| Guard | Why it exists |
|---|---|
| A different filter bound every iteration | The cache key is `(data revision, plan hash)`. Applying a filter changes the *document* revision, not the data revision, so a repeated bound would be served from cache and time nothing. If the probe cannot build N distinct selections it **declines** instead. |
| Verdict = **worst** sample | "≤ 150 ms" is a ceiling. Six runs at 40 ms and one at 400 ms is a phone that misses it. A median would certify that phone. |
| Under 100k rows ⇒ `NOT AT-07 EVIDENCE` | The 600-row sample would sail under the budget and mean nothing. The gate re-checks the row count rather than trusting the flag derived from it. |
| Prior filters and sort restored | A diagnostic must not quietly rewrite the workspace it measured. |
| Emulator refused | `--emulator-rehearsal` exists only to test the script's plumbing. It writes under `build/` with `physicalDevice: false` and `at07Evidence: false`, so it cannot land in the evidence directory by accident. |

## What CI proves, and what it doesn't

The emulator smoke job now drives the probe end to end and asserts that it **refuses** the
600-row sample (`PROBE_HONEST`). That proves the navigation, the logcat format and the parsing
all work. It deliberately produces no AT-07 evidence — an x86 emulator with 600 rows is two
reasons short of the claim.

`tools/test_check_device_evidence.py` (17 cases, run in CI) covers the ways a green-looking
evidence file could still be worthless: an emulator, a rehearsal, a small table, a loosened
budget, too few samples, and a verdict that contradicts its own samples.

## If it fails

A fail is a real result, not a broken harness. Record it and commit the JSON anyway — the
number is the deliverable. Then, in order:

1. **Check the build type.** Debug builds are not the measurement.
2. **Check thermals.** Let the phone cool, re-run. Note the ambient condition in the evidence.
3. **Look at the spread.** If the median is comfortably under and one sample is over, that is a
   scheduler or GC pause, and the fix is different from a uniformly slow engine.
4. **Then optimise the engine.** The CI perf test gives a relative signal on x86; the phone
   gives the absolute one. Do not tune against the x86 number alone.