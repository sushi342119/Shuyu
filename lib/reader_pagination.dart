import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'reader_content.dart';
import 'reader_text.dart';
import 'reader_preferences.dart';
import 'reader_rich_content.dart';

/// EPUB image sizing travels beside the existing image marker. Asset URLs,
/// paragraph indices and old imported chapters keep their original meaning.
class LocalImageLayout {
  const LocalImageLayout({
    this.width,
    this.height,
    this.maxWidth,
    this.maxHeight,
  });
  final String? width, height, maxWidth, maxHeight;
  static const _prefix = '<!--epub-image:';
  static final _length = RegExp(r'^(\d+(?:\.\d+)?|\.\d+)(px|em|rem|%|pt)?$');
  static String? length(String? value) {
    final text = value?.trim().toLowerCase();
    if (text == null || !_length.hasMatch(text)) return null;
    final number = double.tryParse(_length.firstMatch(text)![1]!);
    return number != null && number.isFinite && number > 0 ? text : null;
  }

  factory LocalImageLayout.fromProperties(Map<String, String> values) =>
      LocalImageLayout(
        width: length(values['width']),
        height: length(values['height']),
        maxWidth: length(values['max-width']),
        maxHeight: length(values['max-height']),
      );
  bool get isEmpty =>
      width == null && height == null && maxWidth == null && maxHeight == null;
  String get suffix => isEmpty
      ? ''
      : '$_prefix${[if (width != null) 'w=$width', if (height != null) 'h=$height', if (maxWidth != null) 'mw=$maxWidth', if (maxHeight != null) 'mh=$maxHeight'].join(';')}-->';
  static LocalImageLayout? parseSuffix(String text) {
    if (text.isEmpty) return const LocalImageLayout();
    if (!text.startsWith(_prefix) || !text.endsWith('-->')) return null;
    final values = <String, String>{};
    const keys = {
      'w': 'width',
      'h': 'height',
      'mw': 'max-width',
      'mh': 'max-height',
    };
    for (final part
        in text.substring(_prefix.length, text.length - 3).split(';')) {
      final pair = part.split('=');
      if (pair.length != 2 ||
          !keys.containsKey(pair[0]) ||
          length(pair[1]) == null ||
          values.containsKey(keys[pair[0]])) {
        return null;
      }
      values[keys[pair[0]]!] = pair[1];
    }
    return LocalImageLayout.fromProperties(values);
  }

  static LocalImageLayout fromParagraph(String paragraph) {
    const marker = '<!--image-->';
    final end = paragraph.indexOf(marker, marker.length);
    return end < 0
        ? const LocalImageLayout()
        : parseSuffix(paragraph.substring(end + marker.length).trim()) ??
              const LocalImageLayout();
  }

  Size resolve({
    required Size natural,
    required Size available,
    double fontSize = 19,
  }) {
    double? pixels(String? text, double extent) {
      if (text == null) return null;
      final match = _length.firstMatch(text)!;
      final value = double.parse(match[1]!);
      if (match[2] == '%' && !extent.isFinite) return null;
      return value *
          switch (match[2]) {
            'em' || 'rem' => fontSize,
            '%' => extent / 100,
            'pt' => 96 / 72,
            _ => 1.0,
          };
    }

    final w = pixels(width, available.width),
        h = pixels(height, available.height);
    final ratio = natural.aspectRatio;
    final desired = Size(
      w ?? (h == null ? natural.width : h * ratio),
      h ?? (w == null ? natural.height : w / ratio),
    );
    final bound = Size(
      math.min(
        available.width,
        pixels(maxWidth, available.width) ?? available.width,
      ),
      math.min(
        available.height,
        pixels(maxHeight, available.height) ?? available.height,
      ),
    );
    return applyBoxFit(BoxFit.scaleDown, desired, bound).destination;
  }
}

class ReaderTextAnchor {
  const ReaderTextAnchor(this.paragraph, this.offset);
  final int paragraph, offset;
}

class ReaderPageFragment {
  const ReaderPageFragment({
    required this.paragraph,
    required this.start,
    required this.end,
    required this.text,
    required this.rect,
    this.indent = false,
    this.image = false,
    this.rule = false,
    this.lineMetrics,
  });
  final int paragraph, start, end;
  final String text;
  final Rect rect;
  final bool indent, image;
  final bool rule;
  final ReaderFragmentLines? lineMetrics;
  int get lineCount => lineMetrics?.count ?? 1;
  Iterable<ReaderPageLine> get lines =>
      lineMetrics?.values ?? [ReaderPageLine(start, end, 0, rect.height)];
}

/// Source boundaries and local line boxes reuse the compact shaping metrics.
/// Only visible reflow builds line objects; pagination does not retain a widget
/// or a native LineMetrics object for every line in a chapter.
class ReaderPageLine {
  const ReaderPageLine(this.start, this.end, this.top, this.height);
  final int start, end;
  final double top, height;
}

class ReaderFragmentLines {
  const ReaderFragmentLines._(
    this._metrics,
    this._first,
    this._end,
    this._prefix,
    this._sourceLength,
  );
  final _HorizontalMetrics _metrics;
  final int _first, _end, _prefix, _sourceLength;
  int get count => _end - _first;
  Iterable<ReaderPageLine> get values sync* {
    var top = 0.0;
    for (var i = _first; i < _end; i++) {
      final start = (_metrics.starts[i] - _prefix).clamp(0, _sourceLength);
      final end = (_metrics.starts[i + 1] - _prefix).clamp(
        start,
        _sourceLength,
      );
      final height = _metrics.heights[i];
      yield ReaderPageLine(start, end, top, height);
      top += height;
    }
  }
}

class ReaderLeaf {
  ReaderLeaf(
    List<ReaderPageFragment> fragments, {
    this.text = '',
    this.vertical = false,
  }) : fragments = List.unmodifiable(fragments);
  final List<ReaderPageFragment> fragments;
  final bool vertical;
  final String text;
  ReaderTextAnchor get anchor => fragments.isEmpty
      ? const ReaderTextAnchor(0, 0)
      : ReaderTextAnchor(fragments.first.paragraph, fragments.first.start);
}

class ReaderPagination {
  ReaderPagination(this.pages, this.size);
  final List<ReaderLeaf> pages;
  final Size size;
  int pageFor(ReaderTextAnchor anchor) {
    var nearest = 0;
    for (var p = 0; p < pages.length; p++) {
      for (final f in pages[p].fragments) {
        if (f.paragraph == anchor.paragraph &&
            (f.image || anchor.offset >= f.start && anchor.offset < f.end)) {
          return p;
        }
        if (f.paragraph < anchor.paragraph ||
            f.paragraph == anchor.paragraph && f.start <= anchor.offset) {
          nearest = p;
        }
      }
    }
    return nearest;
  }
}

class _HorizontalMetrics {
  _HorizontalMetrics(List<ui.LineMetrics> lines, List<int> starts)
    : heights = Float64List(lines.length),
      starts = Uint32List.fromList(starts) {
    for (var i = 0; i < lines.length; i++) {
      heights[i] = lines[i].height;
    }
  }
  // Repacking only needs exact line heights and source boundaries. Do not keep
  // every native line descriptor's baseline, width, ascent and other fields.
  final Float64List heights;
  final Uint32List starts;
}

class _ReaderMeasurements {
  final horizontal = <int, _HorizontalMetrics>{};
}

/// A height change re-packs measured lines/columns; it must not shape an entire
/// chapter again. Two typography/width configurations are retained per reader.
class ReaderTextLayoutCache {
  final _layouts = <Object, _ReaderMeasurements>{};
  _ReaderMeasurements _for(Object key) {
    final cached = _layouts.remove(key);
    if (cached != null) {
      _layouts[key] = cached;
      return cached;
    }
    if (_layouts.length == 2) _layouts.remove(_layouts.keys.first);
    return _layouts[key] = _ReaderMeasurements();
  }
}

/// Actual line/glyph boundaries, not viewport-sized scroll jumps. Only the
/// current chapter is measured, yielding between bounded chunks of work.
Future<ReaderPagination?> paginateReader({
  required ReaderContent content,
  required Size size,
  required TextStyle style,
  required ReaderPreferences preferences,
  required TextScaler scaler,
  required bool Function() current,
  ReaderTextAnchor? pageBreak,
  ReaderTextLayoutCache? cache,
  Map<String, Size> localImageSizes = const {},
}) async {
  final pages = <ReaderLeaf>[];
  var fragments = <ReaderPageFragment>[];
  var pageText = StringBuffer();
  var y = 0.0;
  final clock = Stopwatch()..start();
  var forcePageBreak = false;
  ReaderRichParagraph? previousFormat;
  final font = scaler.scale(style.fontSize ?? 19);
  final measured =
      cache?._for((
        content,
        size.width,
        style,
        preferences.mode,
        preferences.indent,
        preferences.justify,
        scaler.scale(style.fontSize ?? 19),
      )) ??
      _ReaderMeasurements();
  void flush() {
    if (fragments.isEmpty) return;
    pages.add(ReaderLeaf(fragments, text: pageText.toString()));
    fragments = [];
    pageText = StringBuffer();
    y = 0;
  }

  for (final index in content.order) {
    if (!current()) return null;
    final text = content.paragraphs[index];
    final format = content.formats[index] ?? const ReaderRichParagraph();
    if (forcePageBreak || format.breakBefore) {
      flush();
      previousFormat = null;
    }
    forcePageBreak = format.breakAfter;
    final gap = format.gapBefore(
      previousFormat,
      font: font,
      lineHeight: style.height ?? 1.72,
      width: size.width,
      defaultGap: preferences.paragraphGap,
      overrideGap: preferences.paragraphGapOverride,
    );
    previousFormat = format;
    y += math.min(
      gap,
      math.max(
        0.0,
        size.height - font * math.max(style.height ?? 1.72, 2.15),
      ),
    );
    if (format.rule) {
      final extent = font * 1.25;
      if (y + extent > size.height && fragments.isNotEmpty) {
        flush();
      }
      fragments.add(
        ReaderPageFragment(
          paragraph: index,
          start: 0,
          end: text.length,
          text: text,
          rect: Rect.fromLTWH(0, y, size.width, extent),
          rule: true,
        ),
      );
      y += extent;
      continue;
    }
    final imageUrl = readerIllustrationUrl(text);
    if (imageUrl?.startsWith('wenku-local:') == true &&
        localImageSizes.containsKey(imageUrl)) {
      final natural = localImageSizes[imageUrl]!;
      final imageSize = LocalImageLayout.fromParagraph(
        text,
      ).resolve(natural: natural, available: size, fontSize: font);
      if (y + imageSize.height > size.height + .1 && fragments.isNotEmpty) {
        flush();
      }
      fragments.add(
        ReaderPageFragment(
          paragraph: index,
          start: 0,
          end: text.length,
          text: text,
          rect: Rect.fromLTWH(
            switch (format.alignment) {
              'left' || 'start' => 0,
              'right' || 'end' => size.width - imageSize.width,
              _ => (size.width - imageSize.width) / 2,
            },
            y,
            imageSize.width,
            imageSize.height,
          ),
          image: true,
        ),
      );
      y += imageSize.height;
      continue;
    }
    if (imageUrl != null || text.trim() == '[插图]') {
      flush();
      fragments.add(
        ReaderPageFragment(
          paragraph: index,
          start: 0,
          end: text.length,
          text: text,
          rect: Offset.zero & size,
          image: true,
        ),
      );
      flush();
      continue;
    }
    if (text.isEmpty) continue;
    final indent = preferences.indent && format.allowsIndent;
    final prefix = indent ? readerIndentPlaceholder : '';
    final display = '$prefix$text';
    var metrics = measured.horizontal[index];
    if (metrics == null) {
      final paragraphStyle = format.textStyle(style);
      final span = readerParagraphSpan(
        children: format.spans(text),
        style: paragraphStyle,
        indent: indent,
        compressPunctuation: preferences.kinsokuCompression,
      );
      final builder = ui.ParagraphBuilder(
        paragraphStyle.getParagraphStyle(
          textDirection: TextDirection.ltr,
          textAlign: format.textAlign(
            preferences.justify ? TextAlign.justify : TextAlign.start,
          ),
          textScaler: scaler,
        ),
      );
      span.build(
        builder,
        textScaler: scaler,
        dimensions: readerIndentDimensions(indent, font),
      );
      final paragraph = builder.build();
      try {
        paragraph.layout(ui.ParagraphConstraints(width: size.width));
        final lines = paragraph.computeLineMetrics();
        final starts = <int>[0];
        // getLineBoundary copies the whole native line-metrics vector on
        // every query. Search the native logical line index instead: this
        // also handles bidi text and oversized graphemes without a visual
        // left-edge hit being mistaken for a source-text boundary.
        for (var line = 1; line < lines.length; line++) {
          var low = starts.last, high = display.length;
          while (low < high) {
            final middle = (low + high) ~/ 2;
            final at = paragraph.getLineNumberAt(middle);
            if (at != null && at < line) {
              low = middle + 1;
            } else {
              high = middle;
            }
          }
          starts.add(low);
          if (clock.elapsedMilliseconds >= 4) {
            await Future<void>.delayed(Duration.zero);
            if (!current()) return null;
            clock.reset();
          }
        }
        starts.add(display.length);
        metrics = measured.horizontal[index] = _HorizontalMetrics(
          lines,
          starts,
        );
      } finally {
        paragraph.dispose();
      }
    }
    final heights = metrics.heights, starts = metrics.starts;
    // A typography change can move the source anchor into the middle of
    // a newly shaped line. Keep that line at top, rather than silently
    // ignoring the break and jumping back an entire page.
    var breakLine = -1;
    if (pageBreak?.paragraph == index) {
      final target = pageBreak!.offset + prefix.length;
      var low = 0, high = heights.length;
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (starts[middle] <= target) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      breakLine = (low - 1).clamp(0, heights.length - 1);
    }
    var line = 0;
    while (line < heights.length) {
      if (line == breakLine) flush();
      if (y + heights[line] > size.height + .1 && fragments.isNotEmpty) {
        flush();
      }
      final first = line;
      var height = 0.0;
      while (line < heights.length &&
          (line == first || line != breakLine) &&
          (height == 0 || y + height + heights[line] <= size.height + .1)) {
        height += heights[line++];
      }
      final start = (starts[first] - prefix.length).clamp(0, text.length);
      final end = (starts[line] - prefix.length).clamp(start, text.length);
      if (end > start) {
        fragments.add(
          ReaderPageFragment(
            paragraph: index,
            start: start,
            end: end,
            text: text.substring(start, end),
            rect: Rect.fromLTWH(0, y, size.width, height),
            indent: start == 0 && indent,
            lineMetrics: ReaderFragmentLines._(
              metrics,
              first,
              line,
              prefix.length,
              text.length,
            ),
          ),
        );
        y += height;
      }
      if (line < heights.length) flush();
    }
    if (clock.elapsedMilliseconds >= 4) {
      await Future<void>.delayed(Duration.zero);
      clock.reset();
    }
  }
  flush();
  if (pages.isEmpty) pages.add(ReaderLeaf(const []));
  return current() ? ReaderPagination(List.unmodifiable(pages), size) : null;
}
