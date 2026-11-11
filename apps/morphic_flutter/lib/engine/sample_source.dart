/// Bundled sample datasets (M1.6 task 1.6.4).
///
/// Synthetic, offline data only. The catalog is the single source of truth for the home
/// first-run suggestion and the import screen's sample row; the bytes themselves live in
/// `assets/samples/` and are loaded through [SampleSource] so widget tests never need the
/// platform asset bundle.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// One bundled dataset and the honest format facts the engine should receive with it.
class SampleDataset {
  const SampleDataset({
    required this.id,
    required this.title,
    required this.description,
    required this.assetPath,
    required this.extension,
    required this.formatHint,
  });

  final String id;
  final String title;
  final String description;
  final String assetPath;

  /// Without a leading dot, exactly as the engine's extension field expects it.
  final String extension;

  /// A known source is not left to the detector; the hint and extension must agree.
  final String formatHint;
}

/// The plan asks for 3–5 samples. Four ship: the three named examples plus the existing
/// 600-row request-latency CSV used by the proof-of-concept screen.
const List<SampleDataset> sampleDatasets = <SampleDataset>[
  SampleDataset(
    id: 'server-logs',
    title: 'Server logs',
    description: 'Structured request events with levels, services and latency.',
    assetPath: 'assets/samples/sample_server_logs.log',
    extension: 'log',
    formatHint: 'log',
  ),
  SampleDataset(
    id: 'sales',
    title: 'Sales CSV',
    description: 'Orders by region and channel with units, price and revenue.',
    assetPath: 'assets/samples/sample_sales.csv',
    extension: 'csv',
    formatHint: 'csv',
  ),
  SampleDataset(
    id: 'sensors',
    title: 'Sensor JSON',
    description: 'Time-stamped temperature and status readings from four sites.',
    assetPath: 'assets/samples/sample_sensors.json',
    extension: 'json',
    formatHint: 'json',
  ),
  SampleDataset(
    id: 'latency',
    title: 'Request latency CSV',
    description: 'The 600-row request log behind the proof-of-concept screen.',
    assetPath: 'assets/samples/sample_logs.csv',
    extension: 'csv',
    formatHint: 'csv',
  ),
];

abstract interface class SampleSource {
  Future<Uint8List> load(SampleDataset dataset);
}

/// Production source: Flutter's asset bundle, with no permission and no network access.
class AssetSampleSource implements SampleSource {
  const AssetSampleSource();

  @override
  Future<Uint8List> load(SampleDataset dataset) async {
    final data = await rootBundle.load(dataset.assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
