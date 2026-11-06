#!/usr/bin/env bash
# MORPHIC physical-device smoke test + evidence recorder.
#
# Implements docs/engineering/real-device-testing.md. REFUSES to run against an emulator:
# emulator output must never be mistakable for real-device evidence.
#
# Usage:
#   tools/device_smoke.sh path/to/app-release.apk --tester "Name" --class mid
#   tools/device_smoke.sh app.apk --tester "Name" --class mid --airplane-manual
#
# Writes docs/engineering/device-evidence/<version>-<model>-<timestamp>.json and exits
# non-zero unless every check passed.

set -uo pipefail   # deliberately NOT -e: we record each failure instead of dying silently

APK=""
TESTER="${USER:-unknown}"
DEVICE_CLASS="mid"
AIRPLANE_MANUAL=0
SERIAL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tester) TESTER="$2"; shift 2 ;;
    --class) DEVICE_CLASS="$2"; shift 2 ;;
    --serial) SERIAL="$2"; shift 2 ;;
    --airplane-manual) AIRPLANE_MANUAL=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) APK="$1"; shift ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 2; }

[ -n "$APK" ] || die "pass the APK path (see --help)"
[ -f "$APK" ] || die "APK not found: $APK"
command -v adb >/dev/null 2>&1 || die "adb not on PATH (install Android platform-tools)"
command -v python3 >/dev/null 2>&1 || die "python3 required to write evidence JSON"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || die "cannot cd to repo root"

# --- select exactly one device -------------------------------------------------
if [ -z "$SERIAL" ]; then
  mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  [ "${#DEVICES[@]}" -eq 1 ] || die "expected exactly 1 connected device, found ${#DEVICES[@]} (use --serial)"
  SERIAL="${DEVICES[0]}"
fi
ADB=(adb -s "$SERIAL")
export MORPHIC_ADB_SERIAL="$SERIAL"
prop() { "${ADB[@]}" shell getprop "$1" 2>/dev/null | tr -d '\r'; }

# --- physical-device assertion (the whole point) -------------------------------
QEMU="$(prop ro.kernel.qemu)"
BOOT_QEMU="$(prop ro.boot.qemu)"
MODEL="$(prop ro.product.model)"
DEVICE_ID="$(prop ro.product.device)"
HARDWARE="$(prop ro.hardware)"
for v in "$QEMU" "$BOOT_QEMU"; do
  [ "$v" = "1" ] && die "refusing to run: '$SERIAL' is an EMULATOR (qemu=$v). Real hardware required."
done
case "$(echo "$MODEL $DEVICE_ID $HARDWARE" | tr '[:upper:]' '[:lower:]')" in
  *sdk*|*emulator*|*goldfish*|*ranchu*)
    die "refusing to run: '$SERIAL' identifies as an emulator ($MODEL / $DEVICE_ID / $HARDWARE)." ;;
esac
echo "Physical device confirmed: $MODEL ($DEVICE_ID), serial $SERIAL"

ANDROID_RELEASE="$(prop ro.build.version.release)"
API="$(prop ro.build.version.sdk)"
ABI="$(prop ro.product.cpu.abi)"
APP_VERSION="$(grep '^version:' apps/morphic_flutter/pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
APK_SHA="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$APK")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

declare -A CHECKS=()
NOTES=""
note() { NOTES="${NOTES}${NOTES:+ | }$*"; echo "  note: $*"; }

ui_dump() {
  "${ADB[@]}" shell uiautomator dump /sdcard/morphic-ui.xml >/dev/null 2>&1
  "${ADB[@]}" pull /sdcard/morphic-ui.xml /tmp/ui.xml >/dev/null 2>&1
}
wait_for_text() { # text, attempts
  local text="$1" attempts="${2:-20}" i
  for ((i=0; i<attempts; i++)); do
    sleep 3
    ui_dump
    if grep -q "$text" /tmp/ui.xml 2>/dev/null; then return 0; fi
  done
  return 1
}
row_range() { python3 tools/read_row_range.py /tmp/ui.xml 2>/dev/null; }
scroll_down() { "${ADB[@]}" shell input swipe 540 1600 540 500 300 >/dev/null 2>&1; }
wait_for_range() { # attempts
  # The table is below the metric cards and chart placeholders, and uiautomator only dumps
  # ON-SCREEN nodes, so scroll until the pager footer is actually visible.
  local attempts="${1:-20}" i
  for ((i=0; i<attempts; i++)); do
    sleep 2
    ui_dump
    if [ -n "$(row_range)" ]; then return 0; fi
    if (( i % 2 == 1 )); then scroll_down; fi
  done
  return 1
}
pkg() { "${ADB[@]}" shell pm list packages | grep morphic | head -1 | sed 's/package://' | tr -d '\r'; }
launch() {
  local p; p="$(pkg)"
  [ -n "$p" ] || return 1
  "${ADB[@]}" shell monkey -p "$p" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
}

echo "== 1/10 install =="
if "${ADB[@]}" install -r "$APK" >/tmp/morphic-install.log 2>&1; then
  CHECKS[install]=pass
else
  CHECKS[install]=fail; note "install failed: $(tail -2 /tmp/morphic-install.log)"
fi
PKG="$(pkg)"
[ -n "$PKG" ] || die "MORPHIC package not found after install"

echo "== 2/10 cold start =="
"${ADB[@]}" logcat -c >/dev/null 2>&1 || true
"${ADB[@]}" shell am force-stop "$PKG" >/dev/null 2>&1
if launch && wait_for_text "MORPHIC" 15; then CHECKS[coldStart]=pass; else CHECKS[coldStart]=fail; fi

echo "== 3/10 engine FFI =="
if wait_for_text "Rust engine connected" 20; then
  CHECKS[engineFfi]=pass
else
  CHECKS[engineFfi]=fail; note "home never showed the live Rust engine version"
fi

echo "== 4/10 proof of concept (Rust CSV profiling) =="
if python3 tools/tap_poc.py >/tmp/morphic-tap.log 2>&1 && wait_for_text "Detected schema" 15; then
  CHECKS[poc]=pass
  ROWS="$(grep -o '[0-9]* rows' /tmp/ui.xml 2>/dev/null | head -1)"
  [ -n "$ROWS" ] && note "PoC rendered: $ROWS"
else
  CHECKS[poc]=fail; note "PoC did not render a Rust-computed profile ($(tail -1 /tmp/morphic-tap.log))"
fi

echo "== 5/10 generate workspace (real import -> live runtime) =="
RANGE_BEFORE=""
if python3 tools/tap_poc.py "Generate workspace" >/tmp/morphic-tap-gen.log 2>&1 \
   && wait_for_range 20; then
  RANGE_BEFORE="$(row_range)"
  CHECKS[generateWorkspace]=pass
  note "workspace row range: ${RANGE_BEFORE:-unknown}"
else
  CHECKS[generateWorkspace]=fail
  note "Generate workspace did not reach a paged runtime table ($(tail -1 /tmp/morphic-tap-gen.log))"
  python3 tools/ui_texts.py /tmp/ui.xml --limit 25 || true
fi

echo "== 6/10 table paging (engine-driven) =="
if [ "${CHECKS[generateWorkspace]:-fail}" = "pass" ] \
   && python3 tools/tap_poc.py "Next page" >/tmp/morphic-tap-next.log 2>&1; then
  sleep 3
  ui_dump
  RANGE_AFTER="$(row_range)"
  if [ -n "$RANGE_AFTER" ] && [ "$RANGE_AFTER" != "$RANGE_BEFORE" ]; then
    CHECKS[tablePaging]=pass; note "paged: ${RANGE_BEFORE} -> ${RANGE_AFTER}"
  else
    CHECKS[tablePaging]=fail
    note "row range did not advance (${RANGE_BEFORE} -> ${RANGE_AFTER:-none}); a single-page dataset cannot verify paging"
  fi
else
  CHECKS[tablePaging]=fail; note "paging not exercised (needs a workspace with >1 page)"
fi

echo "== 7/10 save + reopen identical =="
if [ "${CHECKS[generateWorkspace]:-fail}" = "pass" ]; then
  "${ADB[@]}" shell am force-stop "$PKG" >/dev/null 2>&1
  sleep 2
  if launch && wait_for_text "Sample Logs" 20 \
     && python3 tools/tap_poc.py "Sample Logs" >/tmp/morphic-tap-reopen.log 2>&1 \
     && wait_for_range 20; then
    RANGE_REOPEN="$(row_range)"
    if [ -n "$RANGE_REOPEN" ] && [ "$RANGE_REOPEN" = "$RANGE_BEFORE" ]; then
      CHECKS[reopenIdentical]=pass; note "reopened to the first page: ${RANGE_REOPEN}"
    else
      CHECKS[reopenIdentical]=fail
      note "reopen state differs (${RANGE_BEFORE} vs ${RANGE_REOPEN:-none})"
    fi
  else
    CHECKS[reopenIdentical]=fail; note "saved workspace not listed or not openable after process death"
  fi
else
  CHECKS[reopenIdentical]=fail; note "skipped: no workspace was generated"
fi

echo "== 8/10 airplane mode (offline guarantee) =="
AIR_OK=0
if [ "$AIRPLANE_MANUAL" = "1" ]; then
  note "airplane mode attested manually by $TESTER"
  AIR_OK=1
elif "${ADB[@]}" shell cmd connectivity airplane-mode enable >/dev/null 2>&1; then
  sleep 3
  AIR_OK=1
else
  note "could not toggle airplane mode via adb; toggle it manually and re-run with --airplane-manual"
fi
if [ "$AIR_OK" = "1" ]; then
  "${ADB[@]}" shell am force-stop "$PKG" >/dev/null 2>&1
  if launch && wait_for_text "Rust engine connected" 20 \
     && python3 tools/tap_poc.py >/dev/null 2>&1 && wait_for_text "Detected schema" 15; then
    CHECKS[airplaneMode]=pass
  else
    CHECKS[airplaneMode]=fail; note "slice failed with radios off"
  fi
  [ "$AIRPLANE_MANUAL" = "1" ] || "${ADB[@]}" shell cmd connectivity airplane-mode disable >/dev/null 2>&1
else
  CHECKS[airplaneMode]=fail
fi

echo "== 9/10 process death & relaunch =="
"${ADB[@]}" shell am force-stop "$PKG" >/dev/null 2>&1
sleep 2
if launch && wait_for_text "Rust engine connected" 20; then
  CHECKS[processDeath]=pass
else
  CHECKS[processDeath]=fail
fi

echo "== 10/10 crash log =="
if "${ADB[@]}" logcat -d -s AndroidRuntime:E >/tmp/morphic-crash.log 2>&1 \
   && ! grep -q "FATAL EXCEPTION" /tmp/morphic-crash.log; then
  CHECKS[noCrash]=pass
else
  CHECKS[noCrash]=fail; note "fatal exception present in AndroidRuntime log"
fi

RESULT=pass
for k in install coldStart engineFfi poc generateWorkspace tablePaging reopenIdentical airplaneMode processDeath noCrash; do
  [ "${CHECKS[$k]:-fail}" = "pass" ] || RESULT=fail
done

OUT_DIR="docs/engineering/device-evidence"
mkdir -p "$OUT_DIR"
SAFE_MODEL="$(echo "$MODEL" | tr -c 'A-Za-z0-9._-' '-')"
OUT="$OUT_DIR/${APP_VERSION}-${SAFE_MODEL}-${STAMP}.json"

APP_VERSION="$APP_VERSION" GIT_SHA="$GIT_SHA" APK_SHA="$APK_SHA" MODEL="$MODEL" \
ANDROID_RELEASE="$ANDROID_RELEASE" API="$API" ABI="$ABI" DEVICE_CLASS="$DEVICE_CLASS" \
TESTER="$TESTER" STAMP="$STAMP" RESULT="$RESULT" NOTES="$NOTES" \
C_install="${CHECKS[install]:-fail}" C_coldStart="${CHECKS[coldStart]:-fail}" \
C_engineFfi="${CHECKS[engineFfi]:-fail}" C_poc="${CHECKS[poc]:-fail}" \
C_airplaneMode="${CHECKS[airplaneMode]:-fail}" C_processDeath="${CHECKS[processDeath]:-fail}" \
C_generateWorkspace="${CHECKS[generateWorkspace]:-fail}" \
C_tablePaging="${CHECKS[tablePaging]:-fail}" \
C_reopenIdentical="${CHECKS[reopenIdentical]:-fail}" \
C_noCrash="${CHECKS[noCrash]:-fail}" OUT="$OUT" \
python3 - <<'PY'
import json, os
e = os.environ
checks = {k: e["C_" + k] for k in
          ("install","coldStart","engineFfi","poc","generateWorkspace","tablePaging",
           "reopenIdentical","airplaneMode","processDeath","noCrash")}
doc = {
    "schema": "morphic/device-evidence/1",
    "appVersion": e["APP_VERSION"],
    "gitSha": e["GIT_SHA"],
    "apkSha256": e["APK_SHA"],
    "physicalDevice": True,
    "device": {"model": e["MODEL"], "android": e["ANDROID_RELEASE"], "api": e["API"],
               "abi": e["ABI"], "class": e["DEVICE_CLASS"]},
    "tester": e["TESTER"],
    "timestampUtc": e["STAMP"],
    "checks": checks,
    "result": e["RESULT"],
    "notes": e["NOTES"],
}
with open(e["OUT"], "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print("evidence written:", e["OUT"])
PY

echo
echo "================ RESULT: $RESULT ================"
for k in install coldStart engineFfi poc generateWorkspace tablePaging reopenIdentical airplaneMode processDeath noCrash; do
  printf '  %-18s %s\n' "$k" "${CHECKS[$k]:-fail}"
done
[ -n "$NOTES" ] && echo "  notes: $NOTES"
echo "Commit $OUT with the milestone."
[ "$RESULT" = "pass" ] || exit 1
