/// A real progress observation from the Rust importer (M1.1 task 1.1.7).
///
/// Every field here was measured by the engine. There is no simulated percentage and no
/// invented sub-stage: if Rust did not report it, the UI does not show it.
library;

/// One `ImportProgress` event, forwarded verbatim from `morphic_core::ImportProgress`.
class ImportProgress {
  const ImportProgress({
    required this.phase,
    required this.rowsRead,
    required this.bytesRead,
  });

  /// Parses the engine's JSON. Unknown or missing fields degrade to zero rather than
  /// throwing, because a progress event must never be able to abort an import.
  factory ImportProgress.fromJson(Map<String, dynamic> json) => ImportProgress(
        phase: json['phase'] as String? ?? 'unknown',
        rowsRead: (json['rowsRead'] as num?)?.toInt() ?? 0,
        bytesRead: (json['bytesRead'] as num?)?.toInt() ?? 0,
      );

  /// `sniffing` | `parsing` | `typing` | `done`, as emitted by the engine.
  final String phase;
  final int rowsRead;
  final int bytesRead;

  Map<String, dynamic> toJson() => {
        'phase': phase,
        'rowsRead': rowsRead,
        'bytesRead': bytesRead,
      };

  /// Wording for the current phase. Deliberately describes work, not completion: the
  /// engine gives no total, so a percentage would be a fabrication.
  String get label => switch (phase) {
        'sniffing' => 'Detecting format',
        'parsing' => 'Reading rows',
        'typing' => 'Inferring column types',
        'done' => 'Building workspace',
        _ => 'Working',
      };

  @override
  String toString() => 'ImportProgress($phase, rows: $rowsRead, bytes: $bytesRead)';
}
