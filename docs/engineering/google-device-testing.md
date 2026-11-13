# Google device testing — proposed integration, not yet connected

This is a decision and setup guide, not evidence of a cloud run. No Google project, billing,
service account, device session or GitHub credential was created during this work. The current
CI already builds an Android APK and runs a local **emulator** smoke; that run is useful but
cannot satisfy the [physical-device gate](real-device-testing.md).

## 1. Choose the right device and claim

| Option | What it can add | What it cannot establish by itself |
|---|---|---|
| Google cloud **virtual** medium phone | Another emulator/API/ABI regression signal, in addition to current CI | A physical mid-class phone, its performance, or the required physical-device TalkBack pass |
| Google Device Run on a **physical** phone | A hardware instrumentation result, subject to the actual device and tests used | The repository's ten checks, `morphic/device-evidence/1`, TalkBack, or performance budgets merely by passing a generic test |
| Interactive **physical** Android Device Streaming | A person can interact with a remote real device and investigate failures | This project's gate until its exact checks and evidence are run and verified; remote TalkBack audio/gestures and the offline check have not been verified here |
| A locally connected Pixel 6a/7a-class physical phone | The documented `adb` smoke and manual accessibility procedure | A pass without actually running and recording the checks |

Google lists **Firebase Test Lab as deprecated** with shutdown scheduled for **2027-09-30**;
[Developer Device Platform (DDP)](https://docs.cloud.google.com/developer-device-platform/overview)
is its successor and was documented as preview at the time of writing. Android Device Streaming
is DDP's interactive offering, distinct from automated Device Run; do not assume its
availability, TalkBack audio/gesture support, or that turning on airplane mode will leave a
remote ADB session connected. It is
reasonable to *investigate* a remote physical device, but a locally attached phone remains the
documented path until the remote procedure is proven end to end. A device called “medium phone” is
not necessarily a physical, mid-performance handset: verify **hardware type, actual model,
Android version and ABI**, and assess the model against the project's Pixel 6a/7a-class bar.

## 2. Before enabling anything

1. The project owner chooses a Google Cloud/Firebase project and explicitly approves the
   product, expected spending, spending controls, region/retention and the use of test data.
   Review Google's current [DDP pricing](https://docs.cloud.google.com/developer-device-platform/pricing)
   and [Test Lab / Device Streaming quotas and pricing](https://firebase.google.com/docs/test-lab/usage-quotas-pricing);
   they are different products with different terms. Use only bundled/synthetic fixtures, not
   private user datasets. Test logs and screenshots may contain fixture data.
2. Following Google's [DDP quickstart](https://docs.cloud.google.com/developer-device-platform/quickstart),
   the owner can verify billing and enable the documented APIs. These operations can create
   resources or incur charges: **do not run them without approval**. Use current Google docs
   for IAM; limit permissions to the selected project, service and storage bucket.
3. An authorized person can inspect the current catalog (availability and product support
   change):

   ```bash
   gcloud beta device-run devices list --filter="PLATFORM=ANDROID"
   gcloud beta device-run devices describe DEVICE_ID_FROM_THE_LIST
   ```

   Select an explicitly **VIRTUAL** Android phone for supplemental emulator CI, or an
   explicitly **PHYSICAL** qualifying model for exploratory hardware work. Check supported
   automation versus streaming products, OS, ABI and lifecycle/availability in the
   [catalog](https://docs.cloud.google.com/developer-device-platform/device-catalog); the
   example ID is intentionally not hard-coded. Record the resolved identity in run results.

## 3. Suggested CI implementation after approval

- Add an **opt-in, manually dispatched** workflow on a trusted branch, with a protected GitHub
  environment requiring approval and bounded test duration/concurrency. Do not run paid jobs
  automatically on untrusted pull requests. Make missing configuration fail clearly rather than
  silently skip a required job; initially this is an optional supplemental job, not a release
  or milestone gate.
- Use [GitHub OIDC Workload Identity Federation](https://github.com/google-github-actions/auth)
  with `id-token: write` **only on the cloud job**, `contents: read`, and narrowly scoped
  repository/ref/workflow trust conditions plus least-privilege IAM. Use
  [setup-gcloud](https://github.com/google-github-actions/setup-gcloud) and pin actions to
  reviewed commit SHAs. Do **not** upload, paste, or store a long-lived service-account JSON
  key; the project owner configures identity federation in Google Cloud and repository
  variables/environment themselves. Never expose credentials to fork PR code.
- Build the app APK **and a matching Android instrumentation test APK** for the chosen ABI.
  `integration_test/poc_smoke_test.dart` currently exercises FFI and PoC via `flutter test`;
  it is not yet packaged as a Device Run instrumentation APK. Android scaffolding is generated
  in CI, so adding the Flutter Android instrumentation runner/wrapper and packaging it is
  implementation work, not a checkbox or a command that is ready today. Follow Flutter's
  [Android integration-test setup](https://docs.flutter.dev/testing/integration-tests) and
  match the app/test APKs to the same source SHA.
- Once that wrapper exists and has passed a local/emulator rehearsal, submit a bounded,
  **synchronous** instrumentation session using the selected catalog ID (illustrative paths):

  ```bash
  gcloud beta device-run sessions submit instrumentation \
    --device "$DEVICE_ID" --apps "$APP_APK" --test "$TEST_APK" \
    --bucket-name "$APPROVED_BUCKET" --instrumentation-timeout=10m
  ```

  Verify the session/job/test verdict and propagate failure; retain the SHA, device metadata,
  JUnit, logcat and session link. See Google's [instrumentation guide](https://docs.cloud.google.com/developer-device-platform/device-run/android-instrument)
  and [result lookup](https://docs.cloud.google.com/developer-device-platform/device-run/find-logs).
  Device Run uploads input and result files to Cloud Storage; restrict access and set a reviewed
  retention/lifecycle policy. An Android Robo crawl or the present FFI/PoC test is **not** the
  ten-check smoke. Extend explicit tests before claiming anything beyond the cases they run.

## 4. The real-device and TalkBack evidence still needed

On a qualifying, actually physical handset, use the exact, SHA-stamped APK and follow
[real-device-testing.md](real-device-testing.md) and the current smoke script. That script
rejects emulators and writes `morphic/device-evidence/1` with all ten checks, APK hash, device,
class and named tester. Run the checker; keep failures as failures. Additional milestone flows,
AT-07 latency and other device metrics have separate requirements. Do not generate a passing
JSON by translating a generic cloud verdict.

Run the separate [accessibility checklist](accessibility-checklist.md) with a human using
TalkBack and 1.3× text on physical hardware; record observations, failures, device, build,
tester and date. If exploring remote streaming, first establish that TalkBack speech and
necessary gestures can be heard/used and that all ten checks (including a genuine offline
check) can be performed without breaking access. If any requirement cannot be observed or
tested, mark it **blocked**, not passed. Nothing in this guide waives or changes the standing
gate.

For Google's interactive setup, see [Android Device Streaming](https://developer.android.com/studio/run/android-device-streaming)
and choose a physical device in Android Studio's Device Manager after project/permission and
cost approval. End the session when finished. No connection or paid resources are activated by
this document.
