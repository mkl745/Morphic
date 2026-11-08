/// Build identity, so an installed APK can be matched to the commit that produced it.
///
/// # Why this exists
///
/// Settings used to print a hardcoded `MORPHIC 0.1.0 · Phase 0 proof of concept`, and the pubspec
/// had not been bumped since Phase 0. Every CI artifact therefore identified itself identically,
/// and a tester who downloaded a fresh APK had no way to tell it from one built weeks earlier.
/// A version string that cannot distinguish builds is worse than none: it looks like an answer.
///
/// CI stamps the commit and the UTC build time with `--dart-define`. A build made without those
/// flags says so plainly rather than inventing a value — an unstamped local build must not be
/// mistaken for a CI artifact.
library;

/// Mirrors `version:` in pubspec.yaml. `build_info_test.dart` reads the pubspec and fails if the
/// two drift, because a version shown to a user that disagrees with the package is a lie.
const String kAppVersion = '0.2.0';

/// What this build actually is. The old label claimed "Phase 0 proof of concept" long after
/// Phase 0 ended.
const String kPhaseLabel = 'Phase 1 · M1.4';

class BuildInfo {
  const BuildInfo({required this.gitSha, required this.builtAt});

  /// The values CI injected. Both are empty in a plain `flutter run` or `flutter build`.
  static const BuildInfo fromEnvironment = BuildInfo(
    gitSha: String.fromEnvironment('MORPHIC_GIT_SHA'),
    builtAt: String.fromEnvironment('MORPHIC_BUILD_TIME'),
  );

  final String gitSha;
  final String builtAt;

  /// True when CI stamped this build. False for a local or unstamped build.
  bool get isStamped => gitSha.isNotEmpty;

  /// Seven characters is enough to name a commit and still fits a phone line.
  String get shortSha => gitSha.length <= 7 ? gitSha : gitSha.substring(0, 7);

  /// The line a tester reads out or copies into a bug report.
  String get label => isStamped
      ? '$kAppVersion · $shortSha · ${builtAt.isEmpty ? "build time unknown" : builtAt}'
      : '$kAppVersion · unstamped build';

  /// The explanation shown under the label, so nobody has to guess what "unstamped" means.
  String get explanation => isStamped
      ? 'Built by CI from commit $shortSha. Quote this when reporting a problem.'
      : 'This build carries no CI stamp, so it cannot be matched to a commit. '
          'A CI artifact always shows a commit and a build time here.';
}