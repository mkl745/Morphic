/// Tests for build identity (the fix for "every artifact says 0.1.0").
///
/// The original defect was not a wrong constant — it was a UI that printed a hardcoded string no
/// build could change, so a tester could not tell a fresh APK from an old one. These tests pin both
/// halves: the label must vary with the stamp, and the Settings screen must actually render it.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/build_info.dart';
import 'package:morphic_flutter/engine/bridge_scope.dart';
import 'package:morphic_flutter/features/settings/settings_screen.dart';

import 'support/scripted_bridge.dart';

void main() {
  test('an unstamped build admits it, rather than inventing an identity', () {
    const info = BuildInfo(gitSha: '', builtAt: '');
    expect(info.isStamped, isFalse);
    expect(info.label, contains('unstamped'));
    expect(info.explanation, contains('cannot be matched to a commit'));
    // The default a local `flutter run` gets must be the honest one.
    expect(BuildInfo.fromEnvironment.isStamped, isFalse);
  });

  test('a stamped build names the commit and the build time', () {
    const info = BuildInfo(
      gitSha: '3da708fc348ce3cc4cdd91fc57138a8224113d89',
      builtAt: '2026-11-08T18:20:24Z',
    );
    expect(info.isStamped, isTrue);
    expect(info.shortSha, '3da708f');
    expect(info.label, contains('3da708f'));
    expect(info.label, contains('2026-11-08T18:20:24Z'));
    expect(info.label, contains(kAppVersion));
    expect(info.explanation, contains('3da708f'));
  });

  test('a short or absent sha is not sliced into nonsense', () {
    expect(const BuildInfo(gitSha: 'abc', builtAt: '').shortSha, 'abc');
    expect(const BuildInfo(gitSha: 'abcdefg', builtAt: '').shortSha, 'abcdefg');
    // A sha without a time is still a usable identity; it must not print an empty gap.
    const info = BuildInfo(gitSha: 'abcdef1234', builtAt: '');
    expect(info.label, contains('build time unknown'));
  });

  test('two different commits can never produce the same label', () {
    // The whole point. If this ever passes with equal labels the stamp is decorative.
    const a = BuildInfo(gitSha: '1111111aaaa', builtAt: 't');
    const b = BuildInfo(gitSha: '2222222bbbb', builtAt: 't');
    expect(a.label, isNot(b.label));
  });

  test('the displayed version matches pubspec.yaml', () {
    // A version shown to a user that disagrees with the package is a lie, and the two live in
    // different files precisely where drift is easy.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
        .firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec must declare a version');
    expect(kAppVersion, match!.group(1));
  });

  test('the phase label no longer claims Phase 0', () {
    expect(kPhaseLabel, isNot(contains('Phase 0')));
    expect(kPhaseLabel, contains('Phase 1'));
  });

  testWidgets('Settings renders the build identity, not a fixed string', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: BridgeScope(
        bridge: ScriptedBridge(),
        storageRoot: '/tmp/morphic-test',
        child: const SettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('MORPHIC $kAppVersion · $kPhaseLabel'), findsOneWidget);
    final shown = tester.widget<SelectableText>(find.byKey(const Key('about-build')));
    expect(shown.data, BuildInfo.fromEnvironment.label);
    expect(find.byKey(const Key('about-build-explanation')), findsOneWidget);
    // The old hardcoded line must be gone, not merely joined by a new one.
    expect(find.textContaining('Phase 0 proof of concept'), findsNothing);
  });
}