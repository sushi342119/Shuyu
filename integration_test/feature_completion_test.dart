import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/feature_completion_state_test.dart' as state;
import '../test/feature_completion_ui_test.dart' as features;

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final directory = Directory('${Directory.systemTemp.path}/ui-refinement');
  await directory.create(recursive: true);
  final file = File('${directory.path}/$name.png');
  await file.writeAsBytes(bytes.buffer.asUint8List());
  debugPrint('UI_REFINEMENT_CAPTURE=${file.path}');
  image.dispose();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('native new feature state', state.main);
  group('native new feature UI', () => features.main(capture: _capture));

}
