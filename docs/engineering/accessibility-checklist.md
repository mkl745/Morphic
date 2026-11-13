# M1.6 accessibility checklist — OPEN / NOT SIGNED

**Status:** this is a test procedure and evidence template, not a completed audit. No person
has performed the TalkBack pass on a qualifying physical mid-class device for these changes.
The 1.6.3 task and AT-18 remain open until the required checks pass and a reviewer signs the
record. Flutter semantics/widget tests simulate assistive-technology actions; they do not
prove what a person hears or can operate with TalkBack on Android. See
[real-device-testing.md](real-device-testing.md) for the separate mandatory ten-check device
gate and [quality-and-performance.md §6](quality-and-performance.md#6-accessibility-gates)
for the accessibility contract.

## Evidence record — to be filled in by the tester

- Tested commit / APK SHA-256 / app version and build stamp: **not recorded**
- Device model and class / physical or virtual / Android version and API / ABI: **not recorded**
- TalkBack version and settings / text scale / theme / orientation: **not recorded**
- Dataset(s), generated component types and exact navigation path: **not recorded**
- Tester, date/time and reviewer: **not recorded**
- Device-smoke JSON path and `tools/check_device_evidence.py` result: **not recorded**
- Accessibility findings, issue links and retest build(s): **not recorded**
- Evidence location (redact private data from screenshots/audio/logs): **not recorded**
- Overall result and reviewer signature: **NOT SIGNED**

Use one record per build/device/configuration; report **pass**, **fail**, or **blocked** for
each check with observations. An omitted component, inaudible speech, unavailable gesture or
unreachable control is not a pass. Preserve failures and their retests rather than overwriting
them. Do not insert a template or simulated result as hardware evidence.

## Supplemental automated evidence

- [`954a06c` / CI 43398112819](https://github.com/mkl745/Morphic/actions/runs/43398112819):
  all six jobs passed, including 638 host behavioral tests and 106 live golden tests. The
  isolated-component ready-state matrix covered 390×844, 560×360, 700×900, 800×500 and
  1100×800 logical-pixel windows, each in light/dark at 1.0×/1.3×. It checked selected short
  labels, semantics, target sizes/reachability and Flutter accessibility guidelines. It also
  measured table text colors against plain and striped row surfaces in both themes.
- The same run's emulator checked the bundled sample's named table values on rows 1 and 257
  and the paging range. It was not a TalkBack or physical-device test, and correctly refused
  its 600-row performance probe as AT-07 evidence.
- Additional full-workspace and empty/error host cases are being added; their results are not
  included above until their own CI run completes. Neither the passing tests nor those cases
  enumerate every text/background pair, target, focus path or UI state.

## Setup

1. Obtain a build matching the tested commit; record the APK checksum and confirm the build
   stamp in Settings → About. Use a physical Pixel 6a/7a-class or stronger qualifying **mid**
   handset and note the actual model, OS and ABI. Run the ten-check device smoke separately;
   it tests behavior, not TalkBack usability.
2. Turn on TalkBack in Android accessibility settings and practice swipe navigation, explore by
   touch, double-tap activation, scrolling and adjustable-control gestures. The tester must be
   able to hear real speech and operate the device. If using remote device streaming, first
   verify speech, gestures and the offline check; otherwise mark blocked and use a local phone.
3. Exercise both light and dark themes, portrait and landscape, and text scales 1.0 and 1.3.
   Verify the selected system font scale, rather than assuming a slider label is exactly 1.3.
   For a USB-connected test phone, an authorized tester can record
   `adb shell settings get system font_scale`, set `adb shell settings put system font_scale 1.3`,
   then restore the original value afterwards. Record the actual configuration used.
4. Use bundled samples/synthetic data. Pick or import a dataset whose generated workspace
   contains a metric, a multi-page table and charts (bar, line and timeline); use additional
   samples if necessary. Record the dataset and actual component types. If a chart cannot be
   generated or reached, that component's check is blocked. The app must not require vision or
   a pointer to complete the vertical slice.

## Manual TalkBack vertical slice

Navigate by TalkBack, not by inspecting a widget tree. Record the actual spoken phrases,
actions, failures and screenshots/logs where useful. Announcements may differ in punctuation
or order by TalkBack version; meaning and successful operation are what matter.

| Check | Expected observation | Status / observations |
|---|---|---|
| Start and generate | From Home, navigate to **Run proof of concept**, run it, understand the detected schema, and activate **Generate workspace**. Focus reaches the workspace and its controls in a sensible order. | Not run |
| Metric | The metric's title, aggregation and actual value (or “No data”) are understandable, including its filter action/state if present. Related explanation and type controls are distinguishable. | Not run |
| Table header | Each column is named; sortable headers report sort state and sort when activated. A long-press action reaches field correction; filter buttons name the column and active state. | Not run |
| Rows and detail | One meaningful stop per row announces the row number, column names and values; null is distinguishable from an empty string. Activate a row, read its complete details, close it and resume navigation without a trap. | Not run |
| Paging | Reach Next page, activate it, hear or find the changed range and the new rows; Previous returns to the original page. Disabled controls do not claim to perform actions. | Not run |
| Filter/sort/search | Apply and remove a filter, sort, and search; focus and announced state/results reflect the actual workspace. Recovery from an empty result is reachable. | Not run |
| Bar chart | The chart summary conveys dimension, measure and categories; bars expose meaningful values/actions, and **View as table** offers the data in text. | Not run |
| Line chart | The summary and series visibility controls are understandable. Adjust through first, middle and last buckets and hear the time and visible series values; hidden series are not spoken as visible. Open **View as table**. | Not run |
| Timeline | Adjust through first, middle and last buckets without filtering; the preview is explicitly not filtering. Activate a middle bucket to apply its range, verify the filter, then activate again to clear. Check lane visibility and **View as table**. | Not run |
| Layout and recovery | Rotate / switch responsive classes as available, return from details, and confirm logical focus and no stranded or duplicate focus stops. Test representative loading, no-data and error/retry paths. | Not run |
| 1.3× / both themes | Repeat the vertical slice and inspect long labels and details at 1.3×; no clipping that prevents understanding or operating the UI. Capture actual observations for each theme/orientation. | Not run |

## Remaining full audit

| Area | Required evidence | Status |
|---|---|---|
| Semantic summaries and focus | Every component and key screen, all states, sensible keyboard and TalkBack order, no missing/duplicate actions, and accessible errors and recovery | Partial automated coverage; manual audit not run |
| Targets | Every interactive target is at least **48 × 48 logical dp**, including visible portions in scrolling areas, both themes, orientations and scales | Selected direct size/guideline tests only; full audit not run |
| Contrast | Every rendered text/background pair at least **4.5:1**, including hidden/disabled/selected/error states in both themes | Selected token and state tests only; full audit not run |
| Responsive / text | Compact, medium and expanded widths, both orientations and scales 1.0–1.3, all content/recovery states without inaccessible clipped text | Representative goldens and selected ready-state host cases; full matrix not run |
| TalkBack | Human completes and records the vertical slice above on physical hardware | Not run |

Run and record the applicable matrix; fix each failure and retest the exact changed build. The
reviewer may sign only when each required result and linked evidence is present. A CI pass,
emulator run, or this blank template alone must never be treated as the signature.
