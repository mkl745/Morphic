/// The facts an import produced, shaped for display (M1.2 task 1.2.4).
///
/// Everything here comes from the engine's `ImportReport`. Flutter does not re-derive any of
/// it — the row counts, quarantine count and encoding are Rust's observations, and this is
/// only a typed view over that JSON.
library;

/// Human labels for the engine's format identifiers.
const Map<String, String> kFormatLabels = {
  'csv': 'CSV / TSV',
  'json': 'JSON',
  'jsonl': 'JSON Lines',
  'log': 'Structured log',
  'txt': 'Plain text',
};

class ImportFacts {
  const ImportFacts({
    required this.format,
    required this.encoding,
    required this.rowsImported,
    required this.rowsQuarantined,
    required this.fieldCount,
    required this.warnings,
  });

  /// Reads `{doc, profile, report}`. Missing fields degrade to honest unknowns rather than
  /// throwing: an older engine must still render a usable card.
  factory ImportFacts.fromResult(Map<String, dynamic>? result) {
    final report = result?['report'];
    final map = report is Map<String, dynamic> ? report : const <String, dynamic>{};
    int read(String key) => (map[key] as num?)?.toInt() ?? 0;
    final raw = map['warnings'];
    return ImportFacts(
      format: map['format']?.toString() ?? '',
      encoding: map['encoding']?.toString() ?? '',
      rowsImported: read('rowsImported'),
      rowsQuarantined: read('rowsQuarantined'),
      fieldCount: read('fieldCount'),
      warnings: raw is List ? raw.map((e) => e.toString()).toList() : const [],
    );
  }

  final String format;
  final String encoding;
  final int rowsImported;
  final int rowsQuarantined;
  final int fieldCount;
  final List<String> warnings;

  String get formatLabel => kFormatLabels[format] ?? (format.isEmpty ? 'Unknown' : format);

  /// True when the encoding was a fallback rather than a clean read.
  bool get encodingNeededFallback => encoding.contains('fallback');

  bool get hasQuarantine => rowsQuarantined > 0;

  /// Share of attempted rows that did not make it into the table, 0.0–1.0.
  double get quarantineRate {
    final attempted = rowsImported + rowsQuarantined;
    return attempted == 0 ? 0 : rowsQuarantined / attempted;
  }

  /// The engine guarantees the first warning is the detection headline
  /// (`Read as '<fmt>' (<n>% confidence): <evidence>.`). Anything else is a note.
  String? get detectionSummary =>
      warnings.isNotEmpty && warnings.first.startsWith('Read as ') ? warnings.first : null;

  /// Every warning except the headline. These are the caveats the report sheet lists.
  List<String> get notes =>
      detectionSummary == null ? warnings : warnings.sublist(1);

  /// The confidence the engine reported, if the headline carried one. Null when the engine
  /// did not report it — never invented.
  int? get confidencePercent {
    final summary = detectionSummary;
    if (summary == null) return null;
    final match = RegExp(r'\((\d+)% confidence\)').firstMatch(summary);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// A low-confidence read is worth flagging before the user trusts the table.
  bool get isLowConfidence {
    final c = confidencePercent;
    return c != null && c < 90;
  }
}
