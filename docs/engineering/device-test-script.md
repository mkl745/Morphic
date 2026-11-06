# Device test script — realme C51 + Galaxy A15

Concrete steps for the two phones on hand. Written 2026-11-06 against commit `38ca412`
(CI run [42175082666](https://github.com/mkl745/Morphic/actions/runs/42175082666), all 6 jobs green).

## Your two phones and which class to record

| Phone | Model code | SoC / RAM / storage | Record as |
|---|---|---|---|
| realme C51 | **RMX3830** | Unisoc Tiger T612 (12 nm), 2×A75 + 6×A55 @ 1.8 GHz, **4 GB**, **eMMC 5.1**, 720×1600 LCD, Android 13 [1](https://www.welectronics.com/shop/gsm-phones/realme-c51-rmx3830-carbon-black-64gb-4gb-ram-gsm-unlocked-phone-unisoc-tiger-t612-50mp-detail) | **`--class low`** |
| Samsung Galaxy A15 | SM-A155 / SM-A156 | Helio G99 (4G) or Dimensity 6100+ (5G), 4–8 GB, UFS 2.2 [2](https://en.wikipedia.org/wiki/Samsung_Galaxy_A15) | **`--class low`** |

Run the **C51 first**. It is the weaker of the two — 4 GB RAM, eMMC 5.1 storage and a 12 nm
Unisoc part — so it is the honest worst case. The A15's Helio G99 and UFS storage are
meaningfully faster and would mask problems.

### ⚠ Neither phone satisfies the M1.1 exit rule

Our matrix ([real-device-testing.md](real-device-testing.md) §2) sets the minimum bar for
**every milestone exit** at **mid = "Pixel 6a / 7a class"**, and defines **low** as
"4 GB RAM, A-series class".

- realme C51 → squarely **low** (4 GB, eMMC, entry Unisoc).
- Galaxy A15 → **low**; the matrix names A-series class explicitly.

So both runs produce **low-class evidence**. That is genuinely useful — it is the hardware
most likely to expose our memory and storage debts — but it **does not close M1.1**, and it
does not unblock a release either (M1.7 needs low + mid + flagship).

**What this pass can establish:** FFI works on Unisoc and MediaTek arm64; the offline
guarantee; persistence across process death; paging and search correctness; low-end scroll
smoothness. **What it cannot establish:** the mid-class milestone exit, the 10 MB perf budget,
or flagship behaviour.

To close M1.1 you need one borrow of a Pixel 6a/7a-class device (or comparable: Snapdragon
7-series / Dimensity 7000-series with 6–8 GB). Alternatively you, as product owner, can
explicitly revise the matrix — but that is a rule change to be recorded in an ADR, not
something to infer from whichever phones happen to be on the desk.

---

# Path A — Manual pass (start here, no computer needed)

You already installed the APK, so this can run right now. Do the whole list **on each phone**.
Every expected value below was computed from the bundled CSV, so a mismatch is a real bug.

### A1. Cold start
Force-stop MORPHIC first (Settings → Apps → MORPHIC → Force stop), then open it.

- **Expect:** title `MORPHIC`, and `Rust engine connected` with `core 0.1.0`.
- If it says anything else about the engine, **stop and tell me** — FFI failed on that ABI.

### A2. Rust profiling
Tap **Run proof of concept**.

- **Expect:** `Detected schema`, and **`600 rows · 5 fields`**.
- Fields: `time`, `level`, `service`, `message`, `latency_ms`, each with a type and a role chip.

### A3. Generate — and time it
Tap **Generate workspace**. Start a stopwatch on the tap; stop when the table rows appear
(scroll down if needed).

- **Expect:** app bar `Sample Logs`, and an `Import notes (1)` banner mentioning ISO-8601 /
  UTC normalization. That banner is correct, not an error.
- **Write down the seconds.** This is the measurement I actually need.

### A4. Metric values
- **Expect:** `Records` = **600**
- **Expect:** `Avg latency_ms` = **65.48**

Any other number is a real bug — tell me the number you got.

### A5. Chart placeholders
Two collapsed cards: `latency_ms over time` and `average latency_ms by service`.

- **Expect:** subtitles `line_chart renders in M1.4` and `bar_chart renders in M1.4`.
- Tap one. **Expect:** it expands to show why the engine chose it.
- This is intended behaviour, **not** a crash or a missing chart.

### A6. The table and paging
Scroll to the card titled **Data**.

- **Expect:** sticky header `time · level · service · message · latency_ms`, and a range
  label reading **`1–256 of 600`**.
- **Expect first row:** `2026-11-05T14:00:02.000Z` · `ERROR` · `auth` · `Upstream timeout` · `128`

Now tap the **right chevron** (Next page):

| Tap | Expected range | Expected first row |
|---|---|---|
| Next | **`257–512 of 600`** | `2026-11-05T14:10:32.000Z` · `DEBUG` · `auth` · `Query plan chosen` · `24` |
| Next | **`513–600 of 600`** | `2026-11-05T14:21:01.000Z` · `DEBUG` · `db` · `Entering handler` · `16` |

- On the last page the **right chevron must be disabled** (greyed). The left one must work.
- Tap left twice → back to `1–256 of 600`.

### A7. Scroll behaviour
- Scroll the rows **vertically**: the header row must stay pinned at the top.
- Scroll **sideways**: header and rows must move together, never drift apart.
- Note any stutter — the A15 is the phone that will reveal it.

### A8. Search
Type into **Search rows** (wait ~¼ second after typing; it is debounced).

| Type | Expected range |
|---|---|
| `ERROR` | **`1–101 of 101`** |
| `auth` | **`1–138 of 138`** |
| `timeout` | **`1–27 of 27`** |
| `zzzz` | **`No rows match “zzzz”.`** and `0 of 0` |

Clear the box → back to `1–256 of 600`.

### A9. Kill and reopen — the persistence test
1. Force-stop MORPHIC (or swipe it out of recents).
2. Reopen it.
3. On Home, under recents, tap **Sample Logs**.

- **Expect:** the workspace returns with `Records` 600 and range **`1–256 of 600`** — the same
  first page as A6, not an empty screen and not an error.
- Reopen is currently slower than it should be (it re-reads the source file). Note the delay.

### A10. Airplane mode — the offline guarantee
Turn **airplane mode ON**, force-stop the app, then repeat **A1 → A2 → A3 → A6**.

- **Expect:** everything works identically. Any network error or blank screen is a
  **serious bug** — the app has no INTERNET permission by design.

Turn airplane mode off afterwards.

### A11. Crash check
Did the app close itself, freeze, or show a red error screen at any point? Note the step.

---

## Send me this, per phone

```
Phone:            realme C51 (RMX3830)  /  Galaxy A15 (4G or 5G?)
Android version:  Settings → About phone → Android version
RAM:              
A1 engine:        connected?  yes / no
A2 rows:          600?        yes / no  → if no: ____
A3 generate time: ____ seconds
A4 metrics:       Records ____   Avg latency_ms ____
A6 paging:        1–256 → 257–512 → 513–600 all correct?  yes / no
A7 scroll:        header pinned? ____   jank? ____
A8 search:        ERROR ____  auth ____  timeout ____  zzzz ____
A9 reopen:        same first page?  yes / no   took ____ s
A10 airplane:     full slice worked?  yes / no
A11 crashes:      none / at step ____
Anything that felt wrong:
```

---

# Path B — Formal evidence (computer + USB, produces the gate-valid JSON)

Path A gives me feedback. **Only Path B produces evidence the release gate accepts** — that
is your physical-device rule doing its job. Manual notes cannot be substituted into the
evidence file, and I will not write one on your behalf.

### B1. One-time setup on the computer
- Install Android **platform-tools** (provides `adb`) and **python3**.
- `git clone https://github.com/mkl745/Morphic.git && cd Morphic`
- `git checkout arena/849efee9-morphic`
- Download `morphic-debug-apk.zip` from the green run's **Artifacts** and unzip it on the
  computer. The harness installs the APK itself.

### B2. Per phone
- Settings → About phone → tap **Build number** 7 times → back → **Developer options** →
  enable **USB debugging**.
- **realme specifically:** if Developer options offers **USB debugging (Security settings)**
  (wording varies on Realme UI T), enable it too, or simulated taps are blocked and the
  harness cannot drive the UI. Also disable any "deep optimization" / battery restriction for
  MORPHIC, since Unisoc realme builds kill background apps aggressively.
- Plug in USB, accept the *Allow USB debugging* prompt on the phone.
- `adb devices` — must show the serial as `device`, not `unauthorized`.

### B3. Run it
One phone at a time:

```bash
# realme C51 (weakest — run first)
tools/device_smoke.sh ~/Downloads/app-debug.apk --tester "Your Name" --class low

# Galaxy A15
tools/device_smoke.sh ~/Downloads/app-debug.apk --tester "Your Name" --class low
```

Both plugged in at once? Target explicitly:

```bash
adb devices                       # note the serials
tools/device_smoke.sh ~/Downloads/app-debug.apk --tester "Your Name" --class low --serial RMX3830SERIAL
```

If it reports it cannot toggle airplane mode, turn airplane mode on by hand and add
`--airplane-manual`.

### B4. Commit the evidence
Each run writes `docs/engineering/device-evidence/0.1.0-<model>-<timestamp>.json` and exits
non-zero if any of the 10 checks failed.

```bash
git add docs/engineering/device-evidence/
git commit -m "test: device evidence — <model>"
git push origin arena/849efee9-morphic
```

Or just paste me the JSON / the `RESULT` block and I will commit it.

---

## Known gaps — please do not report these as bugs

- **No file picker.** Only the bundled 600-row sample can be imported. Task 1.1.7.
- **Charts are placeholders.** Painters land in M1.4.
- **No column sorting.** The table's own description says "searchable, sortable" — the
  *sortable* wording is ahead of the implementation (M1.3). Known copy issue.
- **Coarse progress.** `reading → importing → done`; per-row Rust events are not forwarded to
  Dart until 1.1.7.
- **Reopen re-reads the source.** Deliberate M1.1 trade-off; columnar snapshot is 1.1.6.

## What is still genuinely unmeasured

The **10 MB → workspace ≤ 3 s** budget. The sample is 30 KB and there is no file picker, so
nothing in this script tests that number. Your A3 timing is a useful data point, not proof of
the budget.

Also unmeasured after this pass: **mid-class** and **flagship** behaviour, because neither
phone is in those classes. M1.1 stays open until a mid-class run exists.
