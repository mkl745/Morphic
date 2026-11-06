#!/usr/bin/env python3
"""Audit the permissions a built APK actually requests.

Morphic's contract is that it is fully offline and touches nothing but the file the user
picks (docs/architecture/06 §6, spec §12). Adding the first Flutter plugin in task 1.1.7 is
exactly when that stops being an assumption, so this prints the merged permission list and
fails on anything sensitive.

Note on INTERNET: Flutter's *debug* manifest overlay adds it for the Dart VM service, so a
debug APK legitimately requests it. The main manifest must never declare it, and a release
APK must be checked separately (release workflow). This script therefore reports INTERNET
with its caveat rather than failing a debug build for it.

Usage: check_apk_permissions.py <apk> [--main-manifest PATH]
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys

# Runtime permissions that would contradict the product's privacy contract outright.
FORBIDDEN = {
    "android.permission.CAMERA",
    "android.permission.RECORD_AUDIO",
    "android.permission.ACCESS_FINE_LOCATION",
    "android.permission.ACCESS_COARSE_LOCATION",
    "android.permission.ACCESS_BACKGROUND_LOCATION",
    "android.permission.READ_CONTACTS",
    "android.permission.WRITE_CONTACTS",
    "android.permission.READ_SMS",
    "android.permission.SEND_SMS",
    "android.permission.RECEIVE_SMS",
    "android.permission.READ_CALL_LOG",
    "android.permission.READ_PHONE_STATE",
    "android.permission.CALL_PHONE",
    "android.permission.BODY_SENSORS",
    "android.permission.ACTIVITY_RECOGNITION",
    "android.permission.READ_MEDIA_IMAGES",
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.READ_MEDIA_AUDIO",
}

PERM_RE = re.compile(r"name=['\"]([^'\"]+)['\"]")


def find_aapt() -> str | None:
    """Prefer aapt2, fall back to aapt, searching the SDK's build-tools directories."""
    roots = [
        os.environ.get("ANDROID_HOME", ""),
        os.environ.get("ANDROID_SDK_ROOT", ""),
        os.path.expanduser("~/Android/Sdk"),
        "/usr/local/lib/android/sdk",
    ]
    for tool in ("aapt2", "aapt"):
        for root in roots:
            if not root:
                continue
            hits = sorted(glob.glob(os.path.join(root, "build-tools", "*", tool)))
            if hits:
                return hits[-1]
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("apk")
    ap.add_argument("--main-manifest", default=None)
    args = ap.parse_args()

    if not os.path.isfile(args.apk):
        print(f"FAIL: APK not found: {args.apk}")
        return 1

    failures: list[str] = []

    # The source-of-truth check: the main manifest must never ask for network access.
    if args.main_manifest:
        if not os.path.isfile(args.main_manifest):
            print(f"FAIL: main manifest not found: {args.main_manifest}")
            return 1
        text = open(args.main_manifest, encoding="utf-8").read()
        if "android.permission.INTERNET" in text:
            failures.append("the main AndroidManifest.xml declares INTERNET")
        print("Main manifest INTERNET check: "
              + ("FAIL" if "android.permission.INTERNET" in text else "ok (absent)"))

    aapt = find_aapt()
    if aapt is None:
        print("FAIL: no aapt/aapt2 found in the Android SDK; cannot audit the APK")
        return 1

    # aapt and aapt2 share this subcommand.
    cmd = [aapt, "dump", "permissions", args.apk]

    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"FAIL: {os.path.basename(aapt)} exited {proc.returncode}")
        print(proc.stdout)
        print(proc.stderr)
        return 1

    perms = sorted({m for line in proc.stdout.splitlines()
                    if "permission" in line
                    for m in PERM_RE.findall(line)})

    print(f"\nMerged permissions in {os.path.basename(args.apk)} ({len(perms)}):")
    if not perms:
        print("  (none)")
    for p in perms:
        note = ""
        if p == "android.permission.INTERNET":
            note = "  <- expected in DEBUG only (Flutter VM service overlay)"
        print(f"  {p}{note}")

    bad = sorted(set(perms) & FORBIDDEN)
    if bad:
        failures.append("forbidden permissions requested: " + ", ".join(bad))

    print()
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("PERMISSIONS_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
