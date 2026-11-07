#!/usr/bin/env bash
# MORPHIC AT-07 latency measurement on a physical phone.
#
# The functional harness (device_smoke.sh) checks ten behaviours and times none of them: its
# polling helper sleeps three seconds per attempt, so it cannot see a 150 ms budget. This script
# drives the in-app performance probe and reads the engine's own timings out of logcat.
#
# AT-07: filter + sort over 100k x 10 in <= 150 ms, engine-side, on a mid-class ARM device.
#
# Usage:
#   tools/device_perf.sh --tester "Name" --class mid
#   tools/device_perf.sh --tester "Name" --class mid --push-csv
#
# Prepare once: import the generated 100k x 10 CSV into the app so a workspace holds it.
#   tools/gen_perf_csv.py --out build/perf/sales-10mb.csv
#   adb push build/perf/sales-10mb.csv /sdcard/Download/sales-10mb.csv
#   (open MORPHIC, Import, pick sales-10mb.csv, wait for the workspace)
# then run this script from the repo root with the workspace open.
#
# Writes docs/engineering/device-evidence/<version>-<model>-<timestamp>-perf.json and exits
# non-zero unless the probe ran, the dataset was representative, and the worst sample passed.
#
# --emulator-rehearsal exists so CI can prove this plumbing works end to end. It writes under
# build/ with physicalDevice=false and at07Evidence=false, so a rehearsal can never be
# mistaken for the measurement, even by a careless reader of the evidence directory.

set -uo pipefail

TESTER="${USER:-unknown}"
DEVICE_CLASS="mid"
SERIAL=""
PUSH_CSV=0
REHEARSAL=0
ITERATIONS=7
TIMEOUT_S=180

while [ $# -gt 0 ]; do
  case "$1" in
    --tester) TESTER="$2"; shift 2 ;;
    --class) DEVICE_CLASS="$2"; shift 2 ;;
    --serial) SERIAL="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --push-csv) PUSH_CSV=1; shift ;;
    --emulator-rehearsal) REHEARSAL=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 2; }

command -v adb >/dev/null 2>&1 || die "adb not on PATH (install Android platform-tools)"
command -v python3 >/dev/null 2>&1 || die "python3 required"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || die "cannot cd to repo root"

if [ -z "$SERIAL" ]; then
  mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  [ "${#DEVICES[@]}" -eq 1 ] || die "expected exactly 1 connected device, found ${#DEVICES[@]} (use --serial)"
  SERIAL="${DEVICES[0]}"
fi
ADB=(adb -s "$SERIAL")
export MORPHIC_ADB_SERIAL="$SERIAL"
prop() { "${ADB[@]}" shell getprop "$1" 2>/dev/null | tr -d '\r'; }

MODEL="$(prop ro.product.model)"
DEVICE_ID="$(prop ro.product.device)"
HARDWARE="$(prop ro.hardware)"
QEMU="$(prop ro.kernel.qemu)"
BOOT_QEMU="$(prop ro.boot.qemu)"

IS_EMULATOR=0
for v in "$QEMU" "$BOOT_QEMU"; do [ "$v" = "1" ] && IS_EMULATOR=1; done
case "$(echo "$MODEL $DEVICE_ID $HARDWARE" | tr '[:upper:]' '[:lower:]')" in
  *sdk*|*emulator*|*goldfish*|*ranchu*) IS_EMULATOR=1 ;;
esac

if [ "$IS_EMULATOR" = "1" ] && [ "$REHEARSAL" != "1" ]; then
  die "refusing to measure AT-07 on an EMULATOR ($MODEL). A CI x86 emulator says nothing about a mid-class ARM phone. Use --emulator-rehearsal to test this script's plumbing only."
fi
if [ "$REHEARSAL" = "1" ]; then
  echo "REHEARSAL: output will be marked NOT AT-07 EVIDENCE (emulator=$IS_EMULATOR)."
else
  echo "Physical device confirmed: $MODEL ($DEVICE_ID), serial $SERIAL"
fi

ANDROID_RELEASE="$(prop ro.build.version.release)"
API="$(prop ro.build.version.sdk)"
ABI="$(prop ro.product.cpu.abi)"
SOC="$(prop ro.board.platform)"
APP_VERSION="$(grep '^version:' apps/morphic_flutter/pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

if [ "$PUSH_CSV" = "1" ]; then
  CSV="build/perf/sales-10mb.csv"
  [ -f "$CSV" ] || python3 tools/gen_perf_csv.py --out "$CSV" || die "could not generate the CSV"
  "${ADB[@]}" push "$CSV" /sdcard/Download/sales-10mb.csv >/dev/null || die "push failed"
  echo "Pushed $CSV to /sdcard/Download/ — import it in the app before continuing."
fi

pkg() { "${ADB[@]}" shell pm list packages | grep morphic | head -1 | sed 's/package://' | tr -d '\r'; }
PKG="$(pkg)"
[ -n "$PKG" ] || die "MORPHIC is not installed"

ui_dump() {
  "${ADB[@]}" shell uiautomator dump /sdcard/morphic-ui.xml >/dev/null 2>&1
  "${ADB[@]}" pull /sdcard/morphic-ui.xml /tmp/ui.xml >/dev/null 2>&1
}
tap() { # label, attempts
  local label="$1" attempts="${2:-8}" i
  for ((i=0; i<attempts; i++)); do
    ui_dump
    if python3 tools/tap_poc.py "$label" >/tmp/morphic-perf-tap.log 2>&1; then return 0; fi
    sleep 2
  done
  echo "  could not tap '$label': $(tail -3 /tmp/morphic-perf-tap.log)" >&2
  return 1
}

echo "== 1/4 open the probe =="
tap "Performance probe" 10 || die "the workspace app bar has no 'Performance probe' action. Open a workspace first (see --help)."

echo "== 2/4 run it =="
# Clear logcat first so a previous run's line cannot be mistaken for this one.
"${ADB[@]}" logcat -c >/dev/null 2>&1 || true
tap "Run probe" 10 || die "the probe screen has no 'Run probe' button"

echo "== 3/4 wait for the engine's own timings =="
PERF_JSON=""
for ((i=0; i<TIMEOUT_S; i+=3)); do
  sleep 3
  "${ADB[@]}" logcat -d 2>/dev/null | grep -o 'MORPHIC_PERF_JSON {.*}' | tail -1 \
    | sed 's/^MORPHIC_PERF_JSON //' > /tmp/morphic-perf.json
  if [ -s /tmp/morphic-perf.json ] && python3 -c "import json,sys;json.load(open('/tmp/morphic-perf.json'))" 2>/dev/null; then
    PERF_JSON="$(cat /tmp/morphic-perf.json)"
    break
  fi
done
[ -n "$PERF_JSON" ] || die "no MORPHIC_PERF_JSON line after ${TIMEOUT_S}s. Is the probe running? Check: adb logcat -d | grep MORPHIC_PERF"

VERDICT="$("${ADB[@]}" logcat -d 2>/dev/null | grep -o 'MORPHIC_PERF [A-Z].*' | tail -1 | sed 's/^MORPHIC_PERF //')"
echo "  $VERDICT"

echo "== 4/4 record =="
if [ "$REHEARSAL" = "1" ]; then
  OUT_DIR="build/perf-rehearsal"
else
  OUT_DIR="docs/engineering/device-evidence"
fi
mkdir -p "$OUT_DIR"
SAFE_MODEL="$(echo "$MODEL" | tr -c 'A-Za-z0-9._-' '-')"
OUT="$OUT_DIR/${APP_VERSION}-${SAFE_MODEL}-${STAMP}-perf.json"

OUT="$OUT" APP_VERSION="$APP_VERSION" GIT_SHA="$GIT_SHA" MODEL="$MODEL" SOC="$SOC" \
ANDROID_RELEASE="$ANDROID_RELEASE" API="$API" ABI="$ABI" DEVICE_CLASS="$DEVICE_CLASS" \
TESTER="$TESTER" STAMP="$STAMP" REHEARSAL="$REHEARSAL" IS_EMULATOR="$IS_EMULATOR" \
ITERATIONS="$ITERATIONS" VERDICT="$VERDICT" \
python3 - <<'PY'
import json, os, sys

e = os.environ
probe = json.load(open("/tmp/morphic-perf.json"))
rehearsal = e["REHEARSAL"] == "1"
physical = e["IS_EMULATOR"] != "1"
# Three independent reasons a run may not certify AT-07. All must clear.
at07 = physical and not rehearsal and probe.get("representative") is True and probe.get("passes") is True
doc = {
    "schema": "morphic/perf-evidence/1",
    "acceptanceTest": "AT-07",
    "appVersion": e["APP_VERSION"],
    "gitSha": e["GIT_SHA"],
    "physicalDevice": physical,
    "rehearsal": rehearsal,
    "at07Evidence": at07,
    "device": {
        "model": e["MODEL"], "soc": e["SOC"], "android": e["ANDROID_RELEASE"],
        "api": e["API"], "abi": e["ABI"], "class": e["DEVICE_CLASS"],
    },
    "tester": e["TESTER"],
    "timestampUtc": e["STAMP"],
    "iterationsRequested": int(e["ITERATIONS"]),
    "probe": probe,
    "verdict": e["VERDICT"],
    "result": "pass" if at07 else "fail",
}
with open(e["OUT"], "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print("evidence written:", e["OUT"])
if not physical or rehearsal:
    print("NOT AT-07 EVIDENCE: emulator or rehearsal run.")
elif probe.get("representative") is not True:
    print(f"NOT AT-07 EVIDENCE: {probe.get('rowCount')} rows, AT-07 names 100000.")
elif probe.get("passes") is not True:
    print(f"AT-07 FAIL: worst {probe.get('worstMs')} ms > {probe.get('budgetMs')} ms.")
else:
    print(f"AT-07 PASS on {e['MODEL']}: worst {probe.get('worstMs')} ms.")
sys.exit(0 if at07 else 1)
PY
RESULT=$?

echo
echo "================ AT-07: $([ $RESULT -eq 0 ] && echo PASS || echo NOT MET) ================"
[ "$REHEARSAL" = "1" ] || echo "Commit $OUT with the milestone."
exit $RESULT