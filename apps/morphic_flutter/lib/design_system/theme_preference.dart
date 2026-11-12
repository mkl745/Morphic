/// Local theme preference. It is separate from the engine's workspace documents.
library;

import 'dart:io';

import 'package:flutter/material.dart';

abstract interface class ThemePreferenceStore {
  /// Returns null on first run. An unreadable or invalid value must throw rather than
  /// silently claiming the old choice was restored.
  ThemeMode? read();
  void write(ThemeMode mode);
}

/// A tiny local setting, written by replacement so a partially written value is not loaded.
/// This does not claim the engine's journal/fsync guarantees for UI preferences.
class FileThemePreferenceStore implements ThemePreferenceStore {
  const FileThemePreferenceStore(this.root);
  final String root;

  File get _file => File('$root/theme-preference');

  @override
  ThemeMode? read() {
    if (!_file.existsSync()) return null;
    final value = _file.readAsStringSync().trim();
    for (final mode in ThemeMode.values) {
      if (mode.name == value) return mode;
    }
    throw const FormatException('Invalid theme preference');
  }

  @override
  void write(ThemeMode mode) {
    Directory(root).createSync(recursive: true);
    final next = File('$root/theme-preference.new');
    next.writeAsStringSync(mode.name, flush: true);
    next.renameSync(_file.path);
  }
}

class MorphicThemePreference extends ChangeNotifier {
  MorphicThemePreference(this.store) {
    try {
      _mode = store.read() ?? ThemeMode.dark;
    } catch (_) {
      _message = 'Could not read the saved theme. Choose a theme to save it again.';
    }
  }

  final ThemePreferenceStore store;
  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;
  String? _message;
  String? get message => _message;

  void select(ThemeMode mode) {
    _mode = mode;
    try {
      store.write(mode);
      _message = null;
    } catch (_) {
      _message = 'Could not save the theme. This choice may reset after restart; try again.';
    }
    notifyListeners();
  }
}

class MorphicThemeScope extends InheritedNotifier<MorphicThemePreference> {
  const MorphicThemeScope({
    super.key,
    required MorphicThemePreference preference,
    required super.child,
  }) : super(notifier: preference);

  /// Standalone screen previews may not have the application-level preference.
  static MorphicThemePreference? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MorphicThemeScope>()?.notifier;
}
