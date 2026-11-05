# Release Runbook

How to cut a MORPHIC Android release via GitHub Actions (`release.yml`).

## One-time: signing setup

1. Generate an upload keystore (keep it secret, never commit it):
   ```
   keytool -genkeypair -v -keystore morphic-release.keystore -alias morphic \
     -keyalg RSA -keysize 2048 -validity 10000
   ```
2. Base64-encode it: `base64 -w0 morphic-release.keystore`.
3. Add GitHub **encrypted secrets** (Settings → Secrets and variables → Actions):
   - `ANDROID_KEYSTORE_BASE64` — the base64 blob
   - `ANDROID_KEYSTORE_PASSWORD`
   - `ANDROID_KEY_ALIAS` (e.g. `morphic`)
   - `ANDROID_KEY_PASSWORD`
4. Back the keystore up offline. Losing it means you cannot update the app on Play.

Until these secrets exist, `release.yml` builds **unsigned** artifacts and labels them as
such — the pipeline is testable before signing is configured.

## Cutting a release

**Order matters: physical-device evidence must be committed *before* tagging**, because
`release.yml` refuses to build without it.

1. Bump `version:` in `apps/morphic_flutter/pubspec.yaml` (e.g. `0.1.0+1`).
2. Update `CHANGELOG.md`.
3. Build a release-candidate APK locally (or take the CI debug/release artifact) and run the
   mandatory device harness on **each** required class:
   ```
   tools/device_smoke.sh app-release.apk --tester "Name" --class low
   tools/device_smoke.sh app-release.apk --tester "Name" --class mid
   tools/device_smoke.sh app-release.apk --tester "Name" --class flagship
   ```
   Commit the generated `docs/engineering/device-evidence/*.json` files. Verify the gate
   locally: `python3 tools/check_device_evidence.py --version 0.1.0 --require-classes low,mid,flagship`.
4. Commit, then tag: `git tag v0.1.0 && git push origin v0.1.0`.
5. `release.yml` verifies the tag matches the pubspec version, **runs the real-device
   evidence gate**, builds the native libs (3 ABIs, 16 KB-aligned), builds the APK + AAB,
   checksums them, and attaches them to a GitHub Release.
6. Re-run the smoke against the *final* signed artifact before announcing (the evidence in
   step 3 records the APK checksum, so a re-signed artifact should be re-verified).

See [real-device-testing.md](real-device-testing.md) for the rule, matrix, and evidence
format. Emulator runs never satisfy step 3.

## Play Store (later decision)

Publishing to Play additionally requires: a Play Console account, the signed AAB, a privacy
policy (MORPHIC is local-first/no-network in MVP, which simplifies this), content rating,
and store listing assets. This is a product decision beyond Phase 0; the pipeline already
produces the required signed AAB.

## Verification checklist

- [ ] Tag == pubspec version (CI enforces).
- [ ] **Passing physical-device evidence for low + mid + flagship committed (CI enforces —
      the release will not build without it).**
- [ ] 16 KB alignment check passes (CI enforces).
- [ ] SHA256SUMS.txt attached.
- [ ] Final signed APK re-smoked on hardware; airplane-mode + process-death checks pass.
