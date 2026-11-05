# Real-Device Testing — MANDATORY GATE

**Status: standing rule, set by the product owner on 2026-11-05.**

> A milestone may not be declared complete, and a build may not be released, until the
> relevant flows have passed on **physical Android hardware**. Emulator results are
> necessary but **never sufficient**.

This document exists because "it passed on the emulator" is not evidence that MORPHIC works
on the phones people actually own. Emulators differ from hardware in exactly the places this
product is most exposed: SAF/file-picker behaviour, real flash I/O latency and `fsync`
semantics, thermal throttling, OEM activity-kill policies, 16 KB page kernels, GPU/driver
behaviour, and real memory pressure.

## 1. What counts as a real device

A device is **physical** only if all of these hold:

- `adb shell getprop ro.kernel.qemu` is empty or `0`
- `adb shell getprop ro.boot.qemu` is empty or `0`
- `ro.product.model` / `ro.product.device` do not identify as `sdk` / `emulator` / `goldfish` / `ranchu`

[`tools/device_smoke.sh`](../../tools/device_smoke.sh) enforces this and **refuses to run**
against an emulator, so emulator output can never be mistaken for device evidence.

## 2. Device matrix

| Class | Reference | Required for |
|---|---|---|
| **mid** | Pixel 6a / 7a class | **every milestone exit** (minimum bar) |
| **low** | 4 GB RAM, A-series class | release (M1.7) + any perf claim about low-end |
| **flagship** | current Snapdragon 8-series | release (M1.7) |

Record the actual model, Android version, and ABI — "mid-range" is a class, not evidence.

## 3. Required checks per milestone exit

Run on the mid-class device (all classes before release):

1. **Install** the exact release-candidate APK (checksum recorded).
2. **Cold start** to an interactive home.
3. **Engine FFI**: home shows the live Rust engine version.
4. **Vertical slice / PoC**: import or generate → Rust-computed result renders.
5. **Airplane mode**: repeat the slice with radios off — proves the offline guarantee.
6. **Process death & relaunch**: force-stop, relaunch, confirm state restored.
7. **No crash**: `AndroidRuntime` fatal log is empty for the session.

From M1.3 add filter/sort/search; from M1.4 chart interaction; from M1.5 layout editing and
kill-mid-save recovery; from M1.6 TalkBack and text-scale 1.3.

## 4. How to run it

```bash
# Build or download the release-candidate APK, then with ONE physical device attached:
adb devices                       # confirm your handset, not an emulator
tools/device_smoke.sh path/to/app-release.apk --tester "Your Name" --class mid
```

The script installs, drives the UI over `uiautomator`, runs the checks above, and writes
`docs/engineering/device-evidence/<version>-<model>-<timestamp>.json`. Commit that file with
the milestone. It exits non-zero if any check fails, so it is usable as a local gate.

## 5. Evidence format

```json
{
  "schema": "morphic/device-evidence/1",
  "appVersion": "0.1.0",
  "gitSha": "…",
  "apkSha256": "…",
  "physicalDevice": true,
  "device": { "model": "Pixel 7a", "android": "15", "api": "35", "abi": "arm64-v8a", "class": "mid" },
  "tester": "…",
  "timestampUtc": "…",
  "checks": { "install": "pass", "coldStart": "pass", "engineFfi": "pass",
              "poc": "pass", "airplaneMode": "pass", "processDeath": "pass", "noCrash": "pass" },
  "result": "pass",
  "notes": "anything anomalous, honestly"
}
```

A `result` of anything other than `pass` does not satisfy the gate. Partial runs are kept
(not deleted) so failures stay visible.

## 6. Enforcement

- **CI release gate**: `release.yml` runs `tools/check_device_evidence.py`, which fails the
  release if no `pass` evidence exists for the version being tagged. A release therefore
  cannot be cut from a sandbox or a laptop that never touched hardware.
- **Milestone reviews**: the exit checklist in
  [phase-1-mvp-plan.md](../roadmap/phase-1-mvp-plan.md) requires the evidence path.
- **Perf claims**: numbers in [perf-log.md](perf-log.md) must cite physical devices; emulator
  numbers are labelled `emulator` and may not be used to validate a budget.

## 7. Honest limitation of the current automation

The development sandbox has **no USB/ADB access to physical hardware**. Consequently:

- CI proves compilation, unit/widget behaviour, 16 KB alignment, and an **emulator** runtime
  pass. It cannot produce device evidence.
- Device evidence must be produced by a human running `tools/device_smoke.sh` on a handset.
- Until that file exists for a version, the version is **not** device-verified, and any
  status document must say so. Phase 0 is in exactly this state — see
  [phase-0-status.md](../roadmap/phase-0-status.md).
