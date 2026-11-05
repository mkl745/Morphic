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

1. Bump `version:` in `apps/morphic_flutter/pubspec.yaml` (e.g. `0.1.0+1`).
2. Update `CHANGELOG.md`.
3. Commit, then tag: `git tag v0.1.0+1 && git push origin v0.1.0+1`.
4. `release.yml` verifies the tag matches the pubspec version, builds the native libs
   (3 ABIs, 16 KB-aligned), builds the APK + AAB, checksums them, and attaches them to a
   GitHub Release.
5. Download the artifacts, install the APK on the device matrix, and run the AT-01 smoke
   (offline import → workspace) before announcing.

## Play Store (later decision)

Publishing to Play additionally requires: a Play Console account, the signed AAB, a privacy
policy (MORPHIC is local-first/no-network in MVP, which simplifies this), content rating,
and store listing assets. This is a product decision beyond Phase 0; the pipeline already
produces the required signed AAB.

## Verification checklist

- [ ] Tag == pubspec version (CI enforces).
- [ ] 16 KB alignment check passes (CI enforces).
- [ ] SHA256SUMS.txt attached.
- [ ] APK installs and passes offline smoke on low/mid/flagship.
