# Phone test quickstart — build 0.1.0, through task 1.2.5

For the product owner's physical-device pass. Rule and evidence format:
[real-device-testing.md](real-device-testing.md).

**An emulator does not count.** `tools/device_smoke.sh` inspects `ro.kernel.qemu`,
`ro.boot.qemu`, and the model/hardware strings and **refuses to run** on an emulator.

**What this build contains:** CSV, JSON, JSONL, TXT and log import through the real file
picker *and* from the clipboard; automatic format detection with confidence and evidence;
quarantine reporting; cancel mid-import; re-import with a different format; generated
workspaces with metric cards and a paged, searchable table; save and reopen.

Three parts, about 25 minutes total. **Part A is the gate; Part B is what the gate cannot
see; Part C is the measurement the whole project is waiting on.**

---

## 0. Get the APK

Every green CI run uploads a debug APK built for all three ABIs:

1. Open [Actions runs](https://github.com/mkl745/Morphic/actions) and pick the latest green
   run on `arena/849efee9-morphic` (the current one is **42256267974**, commit `fccec5c`).
2. Download the **`morphic-debug-apk`** artifact and unzip it.

A debug APK is fine for this pass. Release builds stay blocked until device evidence exists —
that is the gate working, not a bug.

## 1. Prepare the phone and the computer

- On the phone: **Developer options → USB debugging**, connect by USB, accept the RSA prompt.
- On the computer: `adb` (Android platform-tools), `python3`, and a clone of this repo.
- `adb devices` must list exactly one device as `device`, not `unauthorized`.

---

## Part A — the automated gate (10 checks, ~3 min)

From the repository root:

```bash
tools/device_smoke.sh ~/Downloads/app-debug.apk --tester "Your Name" --class mid
```

`--class` is `low`, `mid`, or `flagship`. **Use `mid`** — it is the minimum bar for every
milestone exit, and the reason this session matters. If the phone refuses the adb
airplane-mode toggle, turn airplane mode on by hand and add `--airplane-manual`.

| # | Check | What it proves |
|---|---|---|
| 1 | `install` | The APK installs on real hardware |
| 2 | `coldStart` | The app reaches Home |
| 3 | `engineFfi` | Home says **Rust engine connected** — FFI works on this ABI |
| 4 | `poc` | Rust profiled the bundled sample; schema is displayed |
| 5 | `generateWorkspace` | A real import reaches the runtime with a **paged** table |
| 6 | `tablePaging` | Next page advances the row range — paging runs in Rust |
| 7 | `reopenIdentical` | Force-stop, reopen from Home, same first-page range |
| 8 | `airplaneMode` | The slice still works with radios off |
| 9 | `processDeath` | Survives force-stop and relaunch |
| 10 | `noCrash` | No `FATAL EXCEPTION` in logcat |

The script writes `docs/engineering/device-evidence/<version>-<model>-<timestamp>.json` and
exits non-zero if anything fails. **Commit that JSON and push — that file is the evidence.**

> The harness drives the *proof-of-concept* path with the bundled 600-row sample. It does
> **not** touch the file picker, the other four formats, the clipboard, or cancellation.
> That is what Part B is for.

---

## Part B — manual pass over the import features (~10 min)

The harness cannot see any of this. Do it by hand and tell me what felt wrong.

**B1. Import your own file.** Home → **Import a file** → **Choose a file** → pick any CSV
from Downloads. Expect: a facts card (name, size), live progress, then a workspace with a
metric card and a table.

**B2. Try the other formats.** Push the repo's fixtures to the phone once:

```bash
adb push fixtures/valid /sdcard/Download/morphic-fixtures
```

Then import, one at a time: `nested.json` (expect flattened `a.b` columns), `events.jsonl`,
`server_logs.log` (expect time / level / service / message extracted), `notes.txt`,
`semicolon.csv` (expect the delimiter detected, not guessed from the extension).

**B3. Check the detection is honest.** On the import screen, read the confidence line. Then
set **Read it as something else** to a deliberately wrong format and import again. Expect a
clear result or a clear error — never a crash and never silent nonsense.

**B4. Quarantine.** Import `fixtures/malformed/` files. Expect either a partial import with a
**Set aside** count and a **View report** sheet, or a typed error with a next step.
*Known limitation: the report shows counts and caveats, not the offending rows themselves.*

**B5. Cancel.** Start an import and tap **Cancel import** while it runs. Expect
**Import cancelled** and **Nothing was saved**. Then import again — it must still work.

**B6. Clipboard.** Copy a few rows of CSV or a JSON object in any app, return to Morphic,
tap **Paste from clipboard**. Expect the same facts card and a workspace. Android 13+ will
show its own system clipboard notice — that is the OS, not Morphic, and the screen says so.
Also try it with an empty clipboard: expect *"The clipboard has no text to import."*

**B7. Airplane mode, for real.** Turn radios off and repeat B1 and B6. Nothing may change.

---

## Part C — the 10 MB measurement (AT-01, ~5 min)

This is the number the project has never had. The fixture AT-01 names was never committed
(a 10 MB file in every clone is a poor trade), so generate it:

```bash
python3 tools/gen_perf_csv.py
# → build/perf/sales-10mb.csv, 100,000 rows × 10 columns, 10.71 MiB, deterministic
adb push build/perf/sales-10mb.csv /sdcard/Download/sales-10mb.csv
```

**C1. Time the clean import — wall clock, tap to table.** Start a screen recording, then
import `sales-10mb.csv` through the picker:

```bash
adb shell screenrecord --time-limit 60 /sdcard/morphic-import.mp4
# on the phone: Import a file → Choose a file → sales-10mb.csv → wait for the table
# stop the recording (Ctrl-C), then:
adb pull /sdcard/morphic-import.mp4
```

Count the time from tapping the file to the first frame showing the table. **The budget is
≤ 3 s.** Report the number even if it is bad — especially if it is bad.

**C2. Read the engine's own figure.** A clean import navigates straight to the workspace, so
the on-screen milliseconds vanish before they can be read. Generate the companion file with
five ragged rows; the quarantine keeps the review card on screen:

```bash
python3 tools/gen_perf_csv.py --bad-rows 5 --out build/perf/sales-review.csv
adb push build/perf/sales-review.csv /sdcard/Download/sales-review.csv
```

Import it and read the line **"99,995 rows imported in N ms"**. Expect **5** rows set aside.

> **What that number does and does not cover.** The controller's clock starts *after* the
> picker has handed over the bytes, so it excludes the Android storage read and the copy
> into Dart memory. It is the engine-side component, **not** the user-perceived total.
> AT-01's ≤ 3 s is the user-perceived total, which is why C1 is the primary measurement and
> C2 only explains where the time went. Please report both and do not let C2 stand in for C1.

**C3. Scroll and reopen.** Scroll the 100k-row table — note any jank. Force-stop, reopen from
Home, and note how long the reopen takes (budget ≤ 500 ms, also unmeasured until now).

---

## 2. Expected-unfinished — please don't report these as bugs

- **Charts are labelled placeholders.** The compiler emits `bar_chart`, `line_chart` and
  `timeline`; their painters land in **M1.4**. A card saying it renders in M1.4 is correct.
- **No sorting and no filters.** That is **M1.3**, the next milestone. Search and paging work.
- **No undo/redo, no layout editing, no rename/duplicate/delete.** **M1.5**.
- **The quarantine report shows counts, not rows.** Known debt, listed in the standing report.
- **Sharing a file into Morphic does nothing.** Deliberate: see
  [ADR-0015](../decisions/ADR-0015-share-to-morphic.md). Clipboard paste is the shipped path.
- **The APK is ~48 MB.** Per-ABI splitting is **M1.7**.

## 3. What to send back

1. The **evidence JSON** from Part A (commit and push it, or tell me and I'll fetch it).
2. **Device model, Android version, ABI**, and that you ran it as `--class mid`.
3. **The C1 wall-clock seconds and the C2 milliseconds**, plus reopen time from C3.
4. Anything from Part B that felt wrong: a confusing error, a wrong detection, jank, a
   clipboard surprise, a report that did not explain itself.
5. If a check failed, the `notes:` line from the harness — it names the step and the reason.

With a `mid` pass committed, **M1.1's exit gate can finally be assessed**. The two items that
used to block it independently are now closed: AT-02 has a labelled corpus and a CI scorer, and
the parser fuzz smoke runs on every push. What remains is the device evidence itself and the
10 MB timing from Part C — so this session is now the critical path, not one blocker among three.
