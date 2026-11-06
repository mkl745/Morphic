# Phone test quickstart

For the product owner's physical-device pass. Rule and evidence format:
[real-device-testing.md](real-device-testing.md).

**An emulator does not count.** `tools/device_smoke.sh` inspects `ro.kernel.qemu`,
`ro.boot.qemu`, and the model/hardware strings and **refuses to run** on an emulator, so
emulator output can never be mistaken for hardware evidence.

## 1. Get an APK

Every green CI run on this branch uploads a debug APK built for all 3 ABIs:

1. Open the [Actions runs](https://github.com/mkl745/Morphic/actions) for the latest green run.
2. Download the `morphic-debug-apk` artifact and unzip it.

A debug APK is fine for this pass. Release builds stay blocked until evidence exists — that
is the gate working, not a bug.

## 2. Prepare the phone

- Enable **Developer options → USB debugging**, connect by USB, accept the RSA prompt.
- `adb devices` must list exactly one device as `device` (not `unauthorized`).
- Install `adb` (Android platform-tools) and `python3` on your computer.

## 3. Run the harness

From the repository root:

```bash
tools/device_smoke.sh ~/Downloads/app-debug.apk --tester "Your Name" --class mid
```

`--class` is `low`, `mid`, or `flagship`. **M1.1 exit needs `mid`.** If your device refuses
the adb airplane-mode toggle:

```bash
# turn airplane mode ON by hand first, then:
tools/device_smoke.sh app-debug.apk --tester "Your Name" --class mid --airplane-manual
```

It writes `docs/engineering/device-evidence/<version>-<model>-<timestamp>.json` and exits
non-zero if any check fails. **Commit that JSON and push** — that file is the evidence.

## 4. What the 10 checks verify

| # | Check | What it proves |
|---|---|---|
| 1 | `install` | APK installs on real hardware |
| 2 | `coldStart` | App reaches Home |
| 3 | `engineFfi` | Home shows the live Rust engine version (FFI works on this ABI) |
| 4 | `poc` | Rust profiled the sample CSV; schema is displayed |
| 5 | `generateWorkspace` | Real import → generated workspace with a **paged** table |
| 6 | `tablePaging` | Next page advances the row range — paging runs in Rust |
| 7 | `reopenIdentical` | Kill the app, reopen from Home, same first-page range |
| 8 | `airplaneMode` | The whole slice still works with radios off |
| 9 | `processDeath` | Survives force-stop and relaunch |
| 10 | `noCrash` | No `FATAL EXCEPTION` in logcat |

Checks 5–7 are new: they exercise the M1.1 vertical slice rather than only the Phase 0 proof
of concept, and the release gate now requires them.

## 5. What is implemented vs. not — please don't report these as bugs

**Reachable now:** Home engine status → *Run proof of concept* → Rust profile →
*Generate workspace* → live workspace with a real metric card and a paged, searchable table
→ saved → reopen from Home.

**Not implemented yet, and expected to look unfinished:**

- **No file picker.** The only importable data is the bundled sample CSV. Choosing your own
  file is task **1.1.7**.
- **Charts show a labelled placeholder.** The compiler already emits `line_chart`,
  `bar_chart`, and `timeline`; their painters land in **M1.4**. A card saying
  "`line_chart` renders in M1.4" is correct behaviour, not a failure.
- **Progress is coarse.** Import reports `reading → importing → done`. Per-row Rust progress
  events exist and are tested in Rust, but are not yet forwarded to Dart (**1.1.7**).
- **No column sorting.** That is **M1.3**. Search and paging do work.
- **Reopen re-reads the source file.** Deliberate M1.1 trade-off; a columnar snapshot is
  **1.1.6**. On a large file, reopen will be slower than it eventually should be.
- **The sample CSV is tiny (12 rows).** It fits on one page, so `tablePaging` may report
  *"a single-page dataset cannot verify paging"*. That is an honest limitation of the
  fixture, not a paging defect — see below.

## 6. The one measurement I still need

The 10 MB → workspace **≤ 3 s** budget cannot be measured with the bundled 12-row sample.
Until a larger fixture is bundled or the file picker lands, that number is **unmeasured** —
please don't let a fast sample stand in for it.

If you want to measure it manually now, note the wall-clock time from tapping
*Generate workspace* to the table appearing, and tell me the file size and device model.

## 7. What to send back

1. The committed evidence JSON (or just tell me it passed and I'll fetch it).
2. **Device model + Android version**, and whether you consider it low/mid/flagship.
3. Anything that felt wrong: jank while scrolling the table, unreadable contrast, a confusing
   empty state, a slow reopen.
4. If a check failed, the `notes:` line from the harness output — it says which step and why.
