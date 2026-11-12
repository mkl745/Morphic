/// Default ingest ceilings, mirrored from Rust until the bridge exposes ingest options.
/// A source-level drift test keeps these display values tied to `IngestOptions::default`.
library;

abstract final class ImportLimits {
  static const int rows = 2000000;
  static const int columns = 2048;
  static const int memoryBytes = 512 * 1024 * 1024;
}
