/// Turns the engine's typed errors into copy a person can act on (M1.2 task 1.2.4).
///
/// The engine speaks in engine terms — `ingest: resource limit exceeded: …` is accurate and
/// useless to someone who just picked a file. This layer keeps the original text (it is the
/// evidence, and the report sheet always shows it) and adds a headline plus a next step.
///
/// Classification matches the stable prefixes of the Rust `Display` impls. Those strings are
/// pinned by tests in `morphic-ingest` and `morphic-core`, so changing the wording breaks CI
/// rather than silently degrading this to the generic fallback.
library;

/// What went wrong, in terms of what the user can do about it.
enum ImportFailureKind {
  cancelled,
  empty,
  tooLarge,
  tooMuchMemory,
  tooManyColumns,
  tooManyRows,
  malformed,
  unknownFormat,
  storage,
  internal,
}

class ImportFailure {
  const ImportFailure({
    required this.kind,
    required this.headline,
    required this.nextStep,
    required this.raw,
  });

  final ImportFailureKind kind;

  /// One sentence naming the problem in the user's terms.
  final String headline;

  /// What to do next. Always present: an error with no way forward is a dead end.
  final String nextStep;

  /// The engine's own message, preserved verbatim for the report sheet and bug reports.
  final String raw;

  /// Cancellation is a user decision, not a failure. The UI must not render it as an error.
  bool get isCancellation => kind == ImportFailureKind.cancelled;

  /// True when picking a different format is a plausible remedy, so the UI can offer the
  /// format chooser inline instead of sending the user back to the picker.
  bool get suggestFormatOverride =>
      kind == ImportFailureKind.malformed || kind == ImportFailureKind.unknownFormat;

  /// True when the file itself is the problem and a smaller one would work.
  bool get suggestSmallerFile =>
      kind == ImportFailureKind.tooLarge ||
      kind == ImportFailureKind.tooMuchMemory ||
      kind == ImportFailureKind.tooManyColumns ||
      kind == ImportFailureKind.tooManyRows;
}

/// Classify an engine error string. Never throws and never returns null: an unrecognised
/// message becomes [ImportFailureKind.internal] with the original text intact.
ImportFailure describeImportFailure(String raw) {
  final text = raw.toLowerCase();

  bool has(String needle) => text.contains(needle);

  if (has('import cancelled') || has('import canceled')) {
    return ImportFailure(
      kind: ImportFailureKind.cancelled,
      headline: 'Import cancelled.',
      nextStep: 'Nothing was saved. Choose the file again whenever you are ready.',
      raw: raw,
    );
  }

  if (has('the file is empty')) {
    return ImportFailure(
      kind: ImportFailureKind.empty,
      headline: 'That file is empty.',
      nextStep: 'There are no rows to import. Check that you picked the right file.',
      raw: raw,
    );
  }

  // Memory is checked separately from file size: the same file can pass the byte gate and
  // still exceed the working budget once flattened into columns.
  if (has('resource limit exceeded')) {
    if (has('memory') || has('retained') || has('working')) {
      return ImportFailure(
        kind: ImportFailureKind.tooMuchMemory,
        headline: 'That file needs more memory than Morphic allows.',
        nextStep: 'The parsed table passed the size check but outgrew the 512 MiB working budget. '
            'Try a file with fewer columns, or split it into smaller parts.',
        raw: raw,
      );
    }
    return ImportFailure(
      kind: ImportFailureKind.tooLarge,
      headline: 'That file is too large to import.',
      nextStep: 'Morphic reads files up to 256 MiB. Split the file, or export a smaller '
          'range from the app that produced it.',
      raw: raw,
    );
  }

  if (has('columns, which exceeds the limit')) {
    return ImportFailure(
      kind: ImportFailureKind.tooManyColumns,
      headline: 'That file has too many columns.',
      nextStep: 'Remove columns you do not need and import again. Very wide files are '
          'usually a pivot or an export that should be unpivoted first.',
      raw: raw,
    );
  }

  if (has('exceeds the row limit')) {
    return ImportFailure(
      kind: ImportFailureKind.tooManyRows,
      headline: 'That file has more rows than Morphic can hold.',
      nextStep: 'Split it into smaller files, or filter it down before importing.',
      raw: raw,
    );
  }

  if (has('unknown format')) {
    return ImportFailure(
      kind: ImportFailureKind.unknownFormat,
      headline: 'Morphic does not recognise that format.',
      nextStep: 'Choose CSV, JSON, JSON Lines, log or plain text — or leave it on '
          'Detect automatically and let the contents decide.',
      raw: raw,
    );
  }

  if (has('json parse error') || has('csv parse error') || has('no header row')) {
    return ImportFailure(
      kind: ImportFailureKind.malformed,
      headline: 'Morphic was unable to read that file.',
      nextStep: 'If the format was detected wrongly, pick the right one and import '
          'again. Otherwise the file may be truncated or still being written.',
      raw: raw,
    );
  }

  if (has('store:') || has('permission denied') || has('no space left')) {
    return ImportFailure(
      kind: ImportFailureKind.storage,
      headline: 'Morphic was unable to save the workspace.',
      nextStep: 'Check that the device has free storage space, then try again.',
      raw: raw,
    );
  }

  return ImportFailure(
    kind: ImportFailureKind.internal,
    headline: 'Something went wrong while importing.',
    nextStep: 'Try the file again. If it keeps happening, the details below are what a '
        'bug report needs.',
    raw: raw,
  );
}
