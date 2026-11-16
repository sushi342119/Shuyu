import 'package:flutter/widgets.dart';

// A fixed inline box is not discarded as leading whitespace by SkParagraph's
// justification. One placeholder code unit maps back to zero source characters.
const readerIndentPlaceholder = '\ufffc';

final _explicitLeadingIndentPattern = RegExp(r'^(?:[\u3000\t]| {2,})');

/// Whether a body paragraph should receive a 2-em first-line placeholder box.
///
/// Headings, non-left-aligned blocks, empty/illustration lines, and paragraphs
/// that already start with explicit indentation are excluded to avoid indenting
/// titles or double-indenting manually formatted lines.
bool shouldIndentReaderParagraph(
  String text, {
  required bool enabled,
  bool allowsIndent = true,
  bool heading = false,
}) {
  if (!enabled || !allowsIndent || heading) return false;
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed == '[插图]') return false;
  if (_explicitLeadingIndentPattern.hasMatch(text)) return false;
  return true;
}

const cjkClosingPunctuation = '，。！？、；：）》」』】〕］｝’”';
const cjkOpeningPunctuation = '（《「『【〔［｛‘“';

@pragma('vm:prefer-inline')
bool _isCjkClosingCodeUnit(int code) => switch (code) {
  0xFF0C || // ，
  0x3002 || // 。
  0xFF01 || // ！
  0xFF1F || // ？
  0x3001 || // 、
  0xFF1B || // ；
  0xFF1A || // ：
  0xFF09 || // ）
  0x300B || // 》
  0x300D || // 」
  0x300F || // 』
  0x3011 || // 】
  0x3015 || // 〕
  0xFF3D || // ］
  0xFF5D || // ｝
  0x2019 || // ’
  0x201D => true, // ”
  _ => false,
};

@pragma('vm:prefer-inline')
bool _isCjkOpeningCodeUnit(int code) => switch (code) {
  0xFF08 || // （
  0x300A || // 《
  0x300C || // 「
  0x300E || // 『
  0x3010 || // 【
  0x3014 || // 〔
  0xFF3B || // ［
  0xFF5B || // ｛
  0x2018 || // ‘
  0x201C => true, // “
  _ => false,
};

@pragma('vm:prefer-inline')
bool _isCompressibleCjkCodeUnitPair(int prev, int curr) =>
    _isCjkClosingCodeUnit(prev) &&
    (_isCjkClosingCodeUnit(curr) || _isCjkOpeningCodeUnit(curr));

bool isCompressibleCjkPunctuationPair(String previous, String current) {
  if (previous.isEmpty || current.isEmpty) return false;
  return _isCompressibleCjkCodeUnitPair(
    previous.codeUnitAt(0),
    current.codeUnitAt(0),
  );
}

List<InlineSpan> compressCjkPunctuationSpans(
  List<InlineSpan> spans,
  TextStyle baseStyle,
) {
  if (spans.isEmpty) return spans;
  final font = baseStyle.fontSize ?? 19.0;
  final baseSpacing = baseStyle.letterSpacing ?? 0.0;
  TextStyle? compressedStyle;
  List<InlineSpan>? result;
  for (var spanIdx = 0; spanIdx < spans.length; spanIdx++) {
    final span = spans[spanIdx];
    if (span is! TextSpan || span.text == null || span.children != null) {
      result?.add(span);
      continue;
    }
    final text = span.text!;
    final len = text.length;
    if (len < 2) {
      result?.add(span);
      continue;
    }
    // Fast scan using UTF-16 code units without per-character String allocation.
    var firstMatch = -1;
    for (var i = 0; i + 1 < len; i++) {
      if (_isCompressibleCjkCodeUnitPair(
        text.codeUnitAt(i),
        text.codeUnitAt(i + 1),
      )) {
        firstMatch = i;
        break;
      }
    }
    if (firstMatch < 0) {
      result?.add(span);
      continue;
    }
    result ??= spans.sublist(0, spanIdx);
    compressedStyle ??= baseStyle.copyWith(
      letterSpacing: baseSpacing - font * 0.28,
    );
    final effectiveStyle = span.style == null
        ? compressedStyle
        : span.style!.copyWith(
            letterSpacing:
                (span.style!.letterSpacing ?? baseSpacing) - font * 0.28,
          );
    if (firstMatch > 0) {
      result.add(
        TextSpan(text: text.substring(0, firstMatch), style: span.style),
      );
    }
    var segStart = firstMatch;
    var inCompressed = true;
    for (var i = firstMatch + 1; i < len; i++) {
      final pairCompress =
          i + 1 < len &&
          _isCompressibleCjkCodeUnitPair(
            text.codeUnitAt(i),
            text.codeUnitAt(i + 1),
          );
      if (pairCompress != inCompressed) {
        if (i > segStart) {
          result.add(
            TextSpan(
              text: text.substring(segStart, i),
              style: inCompressed ? effectiveStyle : span.style,
            ),
          );
        }
        segStart = i;
        inCompressed = pairCompress;
      }
    }
    if (segStart < len) {
      result.add(
        TextSpan(
          text: text.substring(segStart),
          style: inCompressed ? effectiveStyle : span.style,
        ),
      );
    }
  }
  return result ?? spans;
}

/// Builds source text with geometry-only indentation and optional continuation.
/// A continuation occupies the clipped next line, so a page edge is not treated
/// as a paragraph ending by justification; it never enters copied source text.
TextSpan readerParagraphSpan({
  required List<InlineSpan> children,
  required TextStyle style,
  required bool indent,
  double? continuationWidth,
  bool compressPunctuation = false,
}) => TextSpan(
  style: style,
  children: [
    if (indent)
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: ExcludeSemantics(
          // Text.rich scales inline widgets with its TextScaler already.
          child: SizedBox(width: (style.fontSize ?? 19) * 2, height: 0),
        ),
      ),
    ...(compressPunctuation
        ? compressCjkPunctuationSpans(children, style)
        : children),
    if (continuationWidth != null)
      WidgetSpan(
        child: ExcludeSemantics(
          child: SelectionContainer.disabled(
            // A geometry-only next line keeps a page break a soft wrap. It
            // contributes no selectable text and is clipped by the fragment.
            child: SizedBox(width: continuationWidth, height: 0),
          ),
        ),
      ),
  ],
);

List<PlaceholderDimensions> readerIndentDimensions(bool indent, double font) =>
    [
      if (indent)
        PlaceholderDimensions(
          size: Size(font * 2, 0),
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          baselineOffset: 0,
        ),
    ];
