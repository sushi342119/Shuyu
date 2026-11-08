import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Rendering treatment for a saved exact-text bookmark.
enum ReaderMarkStyle {
  underline('划线'),
  highlight('高亮'),
  outline('边框'),
  none('无样式');

  const ReaderMarkStyle(this.label);
  final String label;
}

/// Keeps saved colors recognizable on both custom light and night paper.
Color readerMarkInk(
  ReaderMarkColor color,
  Color foreground, {
  bool dark = false,
}) {
  final value = color.argb;
  if (value == null) return foreground;
  final ink = Color(value);
  return dark ? Color.lerp(ink, Colors.white, .2)! : ink;
}

/// Highlight fill uses the same palette without changing glyph metrics.
Color readerMarkTint(
  ReaderMarkColor color,
  Color foreground, {
  bool dark = false,
}) {
  final ink = readerMarkInk(color, foreground, dark: dark);
  final alpha = color == ReaderMarkColor.ink
      ? (dark ? .20 : .14)
      : (dark ? .30 : .22);
  return ink.withValues(alpha: alpha);
}

/// A small shared palette; ink follows the reader's current paper contrast.
enum ReaderMarkColor {
  ink('原色', null),
  amber('琥珀', 0xFFC69A32),
  mint('薄荷', 0xFF4A9C83),
  blue('湖蓝', 0xFF5289BB),
  rose('蔷薇', 0xFFC87386),
  violet('紫藤', 0xFF9773B7);

  const ReaderMarkColor(this.label, this.argb);
  final String label;
  final int? argb;
}

/// Editable metadata lives in the same per-book record as its source anchor.
class ReaderAnnotationData {
  const ReaderAnnotationData({
    this.style = ReaderMarkStyle.underline,
    this.color = ReaderMarkColor.ink,
    this.note = '',
    this.updatedAt = 0,
  });

  static const maxNoteLength = 100000;
  final ReaderMarkStyle style;
  final ReaderMarkColor color;
  final String note;
  final int updatedAt;
  bool get isEmpty =>
      (style == ReaderMarkStyle.underline || style == ReaderMarkStyle.none) &&
      color == ReaderMarkColor.ink &&
      note.isEmpty &&
      updatedAt == 0;

  ReaderAnnotationData at(int value) => ReaderAnnotationData(
    style: style,
    color: color,
    note: note,
    updatedAt: value,
  );

  Map<String, Object> toJson() => {
    'style': style.name,
    'color': color.name,
    if (note.isNotEmpty) 'note': note,
    'updatedAt': updatedAt,
  };

  factory ReaderAnnotationData.fromJson(Object? raw) {
    if (raw == null) return const ReaderAnnotationData();
    if (raw is! Map ||
        raw['style'] is! String ||
        raw['color'] is! String ||
        (raw['note'] != null && raw['note'] is! String) ||
        (raw['note'] as String? ?? '').length > maxNoteLength ||
        raw['updatedAt'] is! int ||
        raw['updatedAt'] < 0 ||
        raw['updatedAt'] > 1000000000000000) {
      throw const FormatException('批注格式有误');
    }
    final style = ReaderMarkStyle.values
        .where((value) => value.name == raw['style'])
        .firstOrNull;
    final color = ReaderMarkColor.values
        .where((value) => value.name == raw['color'])
        .firstOrNull;
    if (style == null || color == null) {
      throw const FormatException('标记样式或颜色无效');
    }
    return ReaderAnnotationData(
      style: style,
      color: color,
      note: raw['note'] as String? ?? '',
      updatedAt: raw['updatedAt'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderAnnotationData &&
      style == other.style &&
      color == other.color &&
      note == other.note &&
      updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(style, color, note, updatedAt);
}

/// An underline in original paragraph coordinates, independent of pagination.
///
/// UTF-16 offsets are end-exclusive. Several ranges may share a chapter so a
/// selection that skips hidden text never underlines the skipped source text.
class ReaderUnderlineRange {
  const ReaderUnderlineRange({
    required this.chapterId,
    required this.startParagraph,
    required this.startOffset,
    required this.endParagraph,
    required this.endOffset,
    this.contentRevision = '',
  });

  final int chapterId;
  final int startParagraph;
  final int startOffset;
  final int endParagraph;
  final int endOffset;

  /// Coordinate-format revision for this chapter, including mixed-book series.
  final String contentRevision;

  bool get isValid =>
      chapterId >= 0 &&
      chapterId <= 0x7fffffff &&
      startParagraph >= 0 &&
      endParagraph <= 1000000 &&
      startOffset >= 0 &&
      startOffset <= 100000000 &&
      endOffset >= 0 &&
      endOffset <= 100000000 &&
      (startParagraph < endParagraph ||
          startParagraph == endParagraph && startOffset < endOffset);

  /// Retains the source range while a coordinate migration updates its format.
  ReaderUnderlineRange withRevision(String revision) => ReaderUnderlineRange(
    chapterId: chapterId,
    startParagraph: startParagraph,
    startOffset: startOffset,
    endParagraph: endParagraph,
    endOffset: endOffset,
    contentRevision: revision,
  );

  Map<String, Object> toJson() => {
    'chapterId': chapterId,
    'startParagraph': startParagraph,
    'startOffset': startOffset,
    'endParagraph': endParagraph,
    'endOffset': endOffset,
    if (contentRevision.isNotEmpty) 'contentRevision': contentRevision,
  };

  factory ReaderUnderlineRange.fromJson(Object? raw) {
    final revision = raw is Map<Object?, Object?>
        ? raw['contentRevision']
        : null;
    if (revision != null && revision is! String) {
      throw const FormatException('划线坐标版本格式有误');
    }
    if (raw case {
      'chapterId': final int chapterId,
      'startParagraph': final int startParagraph,
      'startOffset': final int startOffset,
      'endParagraph': final int endParagraph,
      'endOffset': final int endOffset,
    }) {
      final range = ReaderUnderlineRange(
        chapterId: chapterId,
        startParagraph: startParagraph,
        startOffset: startOffset,
        endParagraph: endParagraph,
        endOffset: endOffset,
        contentRevision: revision as String? ?? '',
      );
      if (range.isValid) return range;
    }
    throw const FormatException('划线位置格式有误');
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderUnderlineRange &&
      chapterId == other.chapterId &&
      startParagraph == other.startParagraph &&
      startOffset == other.startOffset &&
      endParagraph == other.endParagraph &&
      endOffset == other.endOffset &&
      contentRevision == other.contentRevision;

  @override
  int get hashCode => Object.hash(
    chapterId,
    startParagraph,
    startOffset,
    endParagraph,
    endOffset,
    contentRevision,
  );
}

/// Indexed chapter mark for rendering without scanning every bookmark note.
class ReaderAnnotationRange {
  const ReaderAnnotationRange(
    this.range,
    this.style,
    this.color, {
    this.bookmarkId = '',
  });
  final ReaderUnderlineRange range;
  final ReaderMarkStyle style;
  final ReaderMarkColor color;
  final String bookmarkId;

  @override
  bool operator ==(Object other) =>
      other is ReaderAnnotationRange &&
      range == other.range &&
      style == other.style &&
      color == other.color &&
      bookmarkId == other.bookmarkId;

  @override
  int get hashCode => Object.hash(range, style, color, bookmarkId);
}

/// Paragraph-clipped mark used by horizontal, paged and vertical renderers.
class ReaderTextMark {
  const ReaderTextMark(
    this.start,
    this.end,
    this.style,
    this.color, {
    this.bookmarkId = '',
  });
  final int start, end;
  final ReaderMarkStyle style;
  final ReaderMarkColor color;
  final String bookmarkId;

  @override
  bool operator ==(Object other) =>
      other is ReaderTextMark &&
      start == other.start &&
      end == other.end &&
      style == other.style &&
      color == other.color &&
      bookmarkId == other.bookmarkId;

  @override
  int get hashCode => Object.hash(start, end, style, color, bookmarkId);
}

/// Clips chapter-level annotation ranges to a single paragraph or fragment
/// `[fragmentStart, fragmentStart + textLength)`.
List<ReaderTextMark> clipReaderParagraphMarks(
  Iterable<ReaderAnnotationRange> annotations, {
  required int paragraph,
  required int textLength,
  int fragmentStart = 0,
}) {
  if (textLength <= 0) return const [];
  final fragmentEnd = fragmentStart + textLength;
  final result = <ReaderTextMark>[];
  for (final item in annotations) {
    if (item.style == ReaderMarkStyle.none) continue;
    final range = item.range;
    if (paragraph < range.startParagraph || paragraph > range.endParagraph) {
      continue;
    }
    final rawStart = paragraph == range.startParagraph ? range.startOffset : 0;
    final rawEnd = paragraph == range.endParagraph
        ? range.endOffset
        : fragmentEnd;
    final clippedStart = (rawStart - fragmentStart).clamp(0, textLength);
    final clippedEnd = (rawEnd - fragmentStart).clamp(0, textLength);
    if (clippedStart < clippedEnd) {
      result.add(
        ReaderTextMark(
          clippedStart,
          clippedEnd,
          item.style,
          item.color,
          bookmarkId: item.bookmarkId,
        ),
      );
    }
  }
  return result;
}

/// Splits [text] at mark and search-match boundaries without changing metrics.
List<InlineSpan> buildReaderMarkedSpans({
  required String text,
  Color? foreground,
  Color? baseTextColor,
  required bool dark,
  List<ReaderTextMark> marks = const [],
  (int start, int end)? matchRange,
  Color? matchBackgroundColor,
  int? findStart,
  int? findEnd,
  Color? findBackground,
}) {
  final effectiveForeground = foreground ?? baseTextColor ?? Colors.black;
  final effectiveMatchRange =
      matchRange ??
      (findStart != null && findEnd != null ? (findStart, findEnd) : null);
  final effectiveMatchBg = matchBackgroundColor ?? findBackground;
  if (text.isEmpty) return const [TextSpan(text: '')];
  final points = <int>{0, text.length};
  for (final mark in marks) {
    if (mark.style == ReaderMarkStyle.none) continue;
    points.add(mark.start.clamp(0, text.length));
    points.add(mark.end.clamp(0, text.length));
  }
  if (effectiveMatchRange case (final mStart, final mEnd)
      when mStart >= 0 && mStart < mEnd && mEnd <= text.length) {
    points.add(mStart);
    points.add(mEnd);
  }
  if (points.length <= 2) {
    return [TextSpan(text: text)];
  }
  final sorted = points.toList()..sort();
  final spans = <InlineSpan>[];
  for (var i = 0; i < sorted.length - 1; i++) {
    final segStart = sorted[i];
    final segEnd = sorted[i + 1];
    if (segStart >= segEnd) continue;
    final inMatch =
        effectiveMatchRange != null &&
        segStart >= effectiveMatchRange.$1 &&
        segEnd <= effectiveMatchRange.$2;
    ReaderTextMark? underlineMark;
    ReaderTextMark? highlightMark;
    for (final mark in marks) {
      if (mark.start <= segStart && mark.end >= segEnd) {
        if (mark.style == ReaderMarkStyle.underline && underlineMark == null) {
          underlineMark = mark;
        } else if (mark.style == ReaderMarkStyle.highlight &&
            highlightMark == null) {
          highlightMark = mark;
        }
      }
    }
    TextStyle? segStyle;
    if (underlineMark != null || highlightMark != null || inMatch) {
      final bg = highlightMark != null
          ? readerMarkTint(
              highlightMark.color,
              effectiveForeground,
              dark: dark,
            )
          : (inMatch ? effectiveMatchBg : null);
      final ulInk = underlineMark != null
          ? readerMarkInk(
              underlineMark.color,
              effectiveForeground,
              dark: dark,
            )
          : null;
      segStyle = TextStyle(
        backgroundColor: bg,
        decoration: underlineMark != null ? TextDecoration.underline : null,
        decorationColor: ulInk,
        decorationThickness: underlineMark != null ? 1.6 : null,
      );
    }
    spans.add(
      TextSpan(
        text: text.substring(segStart, segEnd),
        style: segStyle,
      ),
    );
  }
  return spans;
}

/// Shared archive frame used for both bookmark landing and saved outlines.
/// These are paint outsets, so marking never changes reading line breaks.
Rect readerRegistrationBounds(Rect textBounds) => Rect.fromLTRB(
  textBounds.left - 8,
  textBounds.top - 3,
  textBounds.right + 8,
  textBounds.bottom + 3,
);

/// Draws the same restrained corner rule without adding another UI surface.
void paintReaderRegistrationFrame(
  Canvas canvas,
  Rect rect, {
  required Color ink,
  Color? fill,
}) {
  if (fill != null) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(16)),
      Paint()..color = fill,
    );
  }
  final rule = Paint()
    ..color = ink
    ..strokeWidth = 1.3
    ..style = PaintingStyle.stroke;
  canvas.drawLine(rect.topLeft, rect.bottomLeft, rule);
  canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(7, 0), rule);
  canvas.drawLine(
    rect.bottomRight - const Offset(7, 0),
    rect.bottomRight,
    rule,
  );
}

/// Paints saved outline annotations from the already laid out [RenderParagraph].
/// It neither measures text a second time nor changes paragraph layout.
class ReaderAnnotationOutlines extends SingleChildRenderObjectWidget {
  const ReaderAnnotationOutlines({
    super.key,
    required this.marks,
    Color? foreground,
    Color? baseTextColor,
    required this.dark,
    this.leadingPlaceholders = 0,
    required super.child,
  }) : foreground = foreground ?? baseTextColor ?? Colors.black;

  final List<ReaderTextMark> marks;
  final Color foreground;
  final bool dark;
  final int leadingPlaceholders;

  @override
  RenderReaderAnnotationOutlines createRenderObject(BuildContext context) =>
      RenderReaderAnnotationOutlines(
        marks: marks,
        foreground: foreground,
        dark: dark,
        leadingPlaceholders: leadingPlaceholders,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderReaderAnnotationOutlines renderObject,
  ) => renderObject.update(
    marks: marks,
    foreground: foreground,
    dark: dark,
    leadingPlaceholders: leadingPlaceholders,
  );
}

class RenderReaderAnnotationOutlines extends RenderProxyBox {
  RenderReaderAnnotationOutlines({
    required List<ReaderTextMark> marks,
    required Color foreground,
    required bool dark,
    required int leadingPlaceholders,
  }) : _marks = marks,
       _foreground = foreground,
       _dark = dark,
       _prefix = leadingPlaceholders;

  List<ReaderTextMark> _marks;
  Color _foreground;
  bool _dark;
  int _prefix;

  void update({
    required List<ReaderTextMark> marks,
    required Color foreground,
    required bool dark,
    required int leadingPlaceholders,
  }) {
    if (_marks == marks &&
        _foreground == foreground &&
        _dark == dark &&
        _prefix == leadingPlaceholders) {
      return;
    }
    _marks = marks;
    _foreground = foreground;
    _dark = dark;
    _prefix = leadingPlaceholders;
    markNeedsPaint();
  }

  RenderParagraph? _paragraph(RenderObject? node) {
    if (node is RenderParagraph) return node;
    RenderParagraph? found;
    node?.visitChildren((child) {
      found ??= _paragraph(child);
    });
    return found;
  }

  /// Exposed for tests so outline geometry is verified without pixel snapshots.
  List<({Rect rect, ReaderMarkColor color})> get outlineBounds {
    final paragraph = _paragraph(child);
    if (paragraph == null) return const [];
    final transform = paragraph.getTransformTo(this);
    return [
      for (final mark in _marks)
        if (mark.style == ReaderMarkStyle.outline && mark.start < mark.end)
          ...() {
            final boxes = paragraph.getBoxesForSelection(
              TextSelection(
                baseOffset: mark.start + _prefix,
                extentOffset: mark.end + _prefix,
              ),
            );
            if (boxes.isEmpty) return <({Rect rect, ReaderMarkColor color})>[];
            var bounds = boxes.first.toRect();
            for (final box in boxes.skip(1)) {
              bounds = bounds.expandToInclude(box.toRect());
            }
            return [
              (
                rect: readerRegistrationBounds(
                  MatrixUtils.transformRect(transform, bounds),
                ),
                color: mark.color,
              ),
            ];
          }(),
    ];
  }

  @override
  Rect get paintBounds => super.paintBounds.inflate(8);

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    // Indexed marks are newest first; paint their rules last at intersections.
    for (final outline in outlineBounds.reversed) {
      paintReaderRegistrationFrame(
        context.canvas,
        outline.rect.shift(offset),
        ink: readerMarkInk(
          outline.color,
          _foreground,
          dark: _dark,
        ).withValues(alpha: _dark ? .65 : .42),
      );
    }
  }
}

/// Validates stored annotation ranges without importing application state.
List<ReaderUnderlineRange> decodeReaderUnderlineRanges(
  Object? raw, {
  Map<Object?, Object?>? position,
}) {
  if (raw == null) return const [];
  if (raw is! List || raw.isEmpty || raw.length > 1000) {
    throw const FormatException('划线位置数量或格式有误');
  }
  final ranges = List<ReaderUnderlineRange>.unmodifiable(
    raw.map(ReaderUnderlineRange.fromJson),
  );
  if (!_consistentRevisions(ranges)) {
    throw const FormatException('同一章节的划线坐标版本不一致');
  }
  final first = ranges.first;
  if (position != null &&
      (position['chapterId'] != first.chapterId ||
          position['paragraphIndex'] != first.startParagraph ||
          position['textOffset'] != first.startOffset ||
          (position['contentRevision'] ?? '') != first.contentRevision)) {
    throw const FormatException('划线起点与书签位置不一致');
  }
  return ranges;
}

int _comparePoint(int aParagraph, int aOffset, int bParagraph, int bOffset) =>
    aParagraph == bParagraph
    ? aOffset.compareTo(bOffset)
    : aParagraph.compareTo(bParagraph);

/// Returns true when any range in [a] shares a chapter and character span with [b].
bool readerUnderlineRangesOverlap(
  Iterable<ReaderUnderlineRange> a,
  Iterable<ReaderUnderlineRange> b,
) {
  for (final left in a) {
    for (final right in b) {
      if (left.chapterId != right.chapterId) continue;
      if (_comparePoint(
                left.startParagraph,
                left.startOffset,
                right.endParagraph,
                right.endOffset,
              ) <
              0 &&
          _comparePoint(
                right.startParagraph,
                right.startOffset,
                left.endParagraph,
                left.endOffset,
              ) <
              0) {
        return true;
      }
    }
  }
  return false;
}

bool _consistentRevisions(Iterable<ReaderUnderlineRange> ranges) {
  final revisions = <int, String>{};
  for (final range in ranges) {
    if (revisions.containsKey(range.chapterId) &&
        revisions[range.chapterId] != range.contentRevision) {
      return false;
    }
    revisions[range.chapterId] = range.contentRevision;
  }
  return true;
}

/// Removes duplicate/overlapping fragment boundaries, not unselected gaps.
List<ReaderUnderlineRange> canonicalReaderUnderlineRanges(
  Iterable<ReaderUnderlineRange> ranges, {
  Iterable<int>? chapterOrder,
}) {
  final input = ranges.toList();
  if (input.isEmpty ||
      input.length > 1000 ||
      input.any((r) => !r.isValid) ||
      !_consistentRevisions(input)) {
    throw const FormatException('划线位置数量或格式有误');
  }
  final indices = chapterOrder == null
      ? null
      : {for (final (index, id) in chapterOrder.indexed) id: index};
  input.sort((a, b) {
    final chapter = indices == null
        ? a.chapterId.compareTo(b.chapterId)
        : (indices[a.chapterId] ?? -1).compareTo(indices[b.chapterId] ?? -1);
    if (chapter != 0) return chapter;
    final start = _comparePoint(
      a.startParagraph,
      a.startOffset,
      b.startParagraph,
      b.startOffset,
    );
    return start != 0
        ? start
        : _comparePoint(
            a.endParagraph,
            a.endOffset,
            b.endParagraph,
            b.endOffset,
          );
  });
  final merged = <ReaderUnderlineRange>[];
  for (final range in input) {
    final last = merged.lastOrNull;
    if (last == null ||
        last.chapterId != range.chapterId ||
        last.contentRevision != range.contentRevision ||
        _comparePoint(
              last.endParagraph,
              last.endOffset,
              range.startParagraph,
              range.startOffset,
            ) <
            0) {
      merged.add(range);
      continue;
    }
    if (_comparePoint(
          range.endParagraph,
          range.endOffset,
          last.endParagraph,
          last.endOffset,
        ) >
        0) {
      merged[merged.length - 1] = ReaderUnderlineRange(
        chapterId: last.chapterId,
        startParagraph: last.startParagraph,
        startOffset: last.startOffset,
        endParagraph: range.endParagraph,
        endOffset: range.endOffset,
        contentRevision: last.contentRevision,
      );
    }
  }
  return List.unmodifiable(merged);
}
