import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Optional local visual review. No host paths or proprietary fonts are bundled.
Future<void> loadReviewFonts() async {
  // Optional: REVIEW_CUPERTINO_ICONS / REVIEW_MATERIAL_ICONS point at icon
  // font files so review screenshots show real glyphs instead of boxes.
  const cupertino = String.fromEnvironment('REVIEW_CUPERTINO_ICONS');
  const material = String.fromEnvironment('REVIEW_MATERIAL_ICONS');
  for (final (family, file) in [
    ('packages/cupertino_icons/CupertinoIcons', cupertino),
    ('MaterialIcons', material),
  ]) {
    if (file.isEmpty) continue;
    final data = await File(file).readAsBytes();
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(data)))).load();
  }
  const path = String.fromEnvironment('REVIEW_FONT');
  if (path.isEmpty) return;
  final bytes = await File(path).readAsBytes();
  for (final family in ['.SF Pro Text', 'Roboto', 'monospace']) {
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
}

Future<void> captureReview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  const output = String.fromEnvironment('REVIEW_ARTIFACTS');
  if (output.isEmpty) return;
  await tester.runAsync(() async {
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}
