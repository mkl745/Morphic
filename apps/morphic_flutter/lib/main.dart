import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'engine/bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final storageRoot = '${docs.path}/morphic';
  runApp(MorphicApp(bridge: FfiBridge(), storageRoot: storageRoot));
}
