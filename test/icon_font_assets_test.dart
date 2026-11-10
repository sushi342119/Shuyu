import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _cupertinoFamily = 'packages/cupertino_icons/CupertinoIcons';
const _cupertinoAsset = 'packages/cupertino_icons/assets/CupertinoIcons.ttf';

void main() {
  test('the asset bundle registers the Cupertino icon font', () async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json'))
            as List<dynamic>;
    final fonts = manifest.where(
      (entry) => entry['family'] == _cupertinoFamily,
    );
    expect(
      fonts,
      hasLength(1),
      reason:
          'Plain Icon(CupertinoIcons.*) widgets still need the font even '
          'when ArchiveIcon paints other icons as vectors.',
    );
    expect(
      (fonts.single['fonts'] as List<dynamic>).map((font) => font['asset']),
      contains(_cupertinoAsset),
    );
    final bytes = await rootBundle.load(_cupertinoAsset);
    expect(
      bytes.getUint32(0),
      0x00010000,
      reason: 'A real TrueType font is bundled.',
    );
  });

  testWidgets(
    'settings icons render distinct glyphs instead of missing boxes',
    (tester) async {
      await tester.runAsync(() async {
        final loader = FontLoader(_cupertinoFamily)
          ..addFont(rootBundle.load(_cupertinoAsset));
        await loader.load();
      });

      const icons = [
        CupertinoIcons.moon_stars,
        CupertinoIcons.sun_max,
        CupertinoIcons.paintbrush,
        CupertinoIcons.textformat_alt,
        CupertinoIcons.wand_stars,
        CupertinoIcons.rectangle_on_rectangle,
        CupertinoIcons.clock,
        CupertinoIcons.cloud_download,
        CupertinoIcons.chart_bar,
        CupertinoIcons.bookmark,
        CupertinoIcons.folder,
        CupertinoIcons.book,
        CupertinoIcons.tag,
        CupertinoIcons.arrow_down_circle,
      ];
      // An unassigned code point gives the font's missing-glyph box, which is
      // exactly what users saw after the font package was removed.
      const missing = IconData(
        0x10ffff,
        fontFamily: 'CupertinoIcons',
        fontPackage: 'cupertino_icons',
      );
      final boundary = GlobalKey();

      Future<Uint8List> pixels(IconData icon) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox.square(
                  dimension: 48,
                  child: Icon(icon, size: 32, color: Colors.black),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        return (await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!.buffer.asUint8List();
        }))!;
      }

      final missingPixels = await pixels(missing);
      final rendered = <Uint8List>[];
      for (final icon in icons) {
        final actual = await pixels(icon);
        expect(
          actual,
          isNot(orderedEquals(missingPixels)),
          reason: '${icon.codePoint} must not render the missing-glyph box.',
        );
        for (final previous in rendered) {
          expect(
            actual,
            isNot(orderedEquals(previous)),
            reason: 'Different settings actions must have different icons.',
          );
        }
        rendered.add(actual);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
