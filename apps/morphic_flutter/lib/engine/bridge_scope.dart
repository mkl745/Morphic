/// Provides the [MorphicBridge] + storage root down the widget tree.
///
/// Phase 0 uses a lightweight InheritedWidget instead of a state-management package to
/// keep the first build low-risk (ADR-0002 addendum). M1.1 introduces Riverpod controllers.
library;

import 'package:flutter/widgets.dart';

import 'bridge.dart';
import 'import_runner.dart';

class BridgeScope extends InheritedWidget {
  const BridgeScope({
    super.key,
    required this.bridge,
    required this.storageRoot,
    required super.child,
    this.importRunner,
  });

  final MorphicBridge bridge;
  final String storageRoot;

  /// Where imports run. Null means the screens use a worker isolate; tests inject an
  /// [InlineImportRunner] over a fake bridge, since the host has no native library.
  final ImportRunner? importRunner;

  static BridgeScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<BridgeScope>();
    assert(scope != null, 'BridgeScope not found in widget tree');
    return scope!;
  }

  @override
  bool updateShouldNotify(BridgeScope oldWidget) =>
      bridge != oldWidget.bridge ||
      storageRoot != oldWidget.storageRoot ||
      importRunner != oldWidget.importRunner;
}
