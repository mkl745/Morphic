# ADR-0015 — Share-to-Morphic: `share_handler` rejected on AGP 9; adopt `better_share_handler` in M1.6

- **Status:** Accepted (2026-11-06)
- **Context phase:** M1.2 task 1.2.5 (the task says *evaluate* `share_handler`)
- **Amends:** [ADR-0012](ADR-0012-dependency-policy.md) / dependency-strategy §2, which lists
  `share_handler` *(stretch)* against M1.6

## Context

Task 1.2.5 has two stretch items: clipboard import and a share-to-Morphic intent, the second
explicitly scoped as an *evaluation*. Clipboard import shipped in this task. This ADR records
the share evaluation and what it would take to land the feature.

Three findings decide the outcome.

### 1. `share_handler` does not support this project's Android toolchain

The project builds with **AGP 9.1.x / Flutter 3.47 / Built-in Kotlin** (ADR-0010). This is the
exact combination that made `file_picker` 11.x unusable in task 1.1.7: a plugin that applies
the Kotlin Gradle Plugin itself fails to compile its Kotlin sources, and
`GeneratedPluginRegistrant` then cannot find the plugin class.

`share_handler` is federated (`share_handler_android`, `share_handler_ios`,
`share_handler_platform_interface`) and its published setup predates AGP 9. A maintained
fork, **`better_share_handler`**, states AGP 9 support explicitly, ships Android/iOS/Dart in
one package instead of three, and requires Flutter 3.44+ / Dart 3.12+ — floors this project
already exceeds. It keeps the same API (`getInitialSharedMedia()`, `sharedMediaStream`,
`SharedMedia.content`, `SharedMedia.attachments`) and adds
`resetInitialSharedMedia()`, which matters for not re-importing the same share on every
launch.

**Conclusion:** if share-to-Morphic is adopted, the package is `better_share_handler`, not
`share_handler`. The dependency-strategy entry should be corrected when the feature lands.

### 2. The Android manifest is generated, not committed

`apps/morphic_flutter/android/` does not exist in the repository. CI creates it fresh:

```
flutter create --platforms=android --org dev.morphic --project-name morphic_flutter /tmp/morphic_scaffold
cp -rn /tmp/morphic_scaffold/android apps/morphic_flutter/
```

Every share plugin requires `ACTION_SEND` / `ACTION_SEND_MULTIPLE` intent filters in
`android/app/src/main/AndroidManifest.xml`, plus `android:launchMode="singleTask"` on
MainActivity to avoid a new activity per share. With no committed manifest there is nowhere
to put them.

Adopting share therefore requires a **new build step**: a `tools/patch_android_manifest.py`
that idempotently inserts the filters after scaffolding, run in both `ci.yml` and
`release.yml`, with its own tests. That is real architectural work, not a package bump — and
it is the same shape of change as the (already deferred) decision to commit `android/`.

### 3. It is not on the M1.2 critical path, and the policy already places it in M1.6

The M1.2 exit is AT-03/04/05: format breadth, log extraction, malformed-input safety. Share
contributes to none of them. Dependency-strategy §2 assigns `share_handler` to **M1.6
stretch**, and the plan marks 1.2.5's share item ◇.

There is also a verification limit worth stating plainly: this sandbox cannot reach
`pub.dev`, so a new plugin's API and its native build cannot be checked before pushing. The
`file_picker` 11.x failure cost a full CI round for exactly that reason. Adding a plugin *and*
a manifest patcher *and* a share stream in one blind change is how silent breakage survives.

## Decision

1. **Do not add a share plugin in M1.2.** Clipboard import ships now; it needs no plugin, no
   permission and no manifest change, and it covers the same user intent ("get this text into
   Morphic") for the most common case.
2. **Correct the recorded candidate.** When share-to-Morphic is implemented, evaluate
   `better_share_handler` first; `share_handler` is disqualified on AGP 9 grounds.
3. **Keep the M1.6 placement**, and treat the manifest-patching step as a prerequisite task
   rather than a detail discovered mid-implementation.

## Implementation plan for M1.6

Recorded now so the evaluation is actionable rather than a deferral with no content:

1. `tools/patch_android_manifest.py` — idempotent insertion of the `text/plain` and file
   MIME filters plus `launchMode="singleTask"`; unit-tested against a scaffolded manifest;
   wired into `ci.yml` and `release.yml` immediately after the scaffolding step.
2. Re-run `tools/check_apk_permissions.py`. A share receiver should add **zero** permissions;
   if the plugin's manifest merges any in, that is a blocker, not an accepted cost.
3. `PlatformShareSource` behind an interface, mirroring `PlatformFileSource` and
   `PlatformClipboardSource`, so the screen and controller stay testable without the plugin.
4. Handle both entry paths: `getInitialSharedMedia()` for a cold start (then
   `resetInitialSharedMedia()` so it is not replayed), and `sharedMediaStream` for a warm app.
5. Route shared **text** through `ImportController.importClipboard`-style logic (no extension,
   contents decide the format) and shared **files** through `importPicked`.
6. iOS is out of MVP scope; the plugin's Share Extension setup is not required for Android.

## Consequences

- **Positive:** M1.2 finishes without an unverifiable native dependency; the AGP 9 finding is
  captured before it costs a CI round; the manifest gap is named as work rather than
  discovered late.
- **Negative:** users cannot share into Morphic yet. Clipboard paste covers text, which is the
  majority case, but not "share this .csv from Files".
- **Follow-up:** dependency-strategy §2 still names `share_handler`; correct it in the M1.6
  task that adopts the feature, not before, so the table keeps describing what is actually
  integrated.
