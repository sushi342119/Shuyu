import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/painting.dart';
import 'package:characters/characters.dart';
import 'reader_coordinate_map.dart';
import 'reader_languages.dart';

/// Publisher block spacing is metadata, never a synthetic text paragraph.
/// Margins collapse; padding and explicit empty lines remain additive.
class ReaderBlockSpacing {
  const ReaderBlockSpacing({
    this.before = const [],
    this.after = const [],
    this.leading = const [],
    this.trailing = const [],
  });
  final List<String> before, after, leading, trailing;
  bool get empty =>
      before.isEmpty && after.isEmpty && leading.isEmpty && trailing.isEmpty;
  static final _length = RegExp(
    r'^(\d+(?:\.\d+)?|\.\d+)(em|rem|ex|lh|px|pt|%)?$',
  );
  static String? length(String? value) {
    final text = value?.trim().toLowerCase();
    final match = text == null ? null : _length.firstMatch(text);
    if (match == null) return null;
    final number = double.tryParse(match[1]!);
    if (number == null ||
        !number.isFinite ||
        number < 0 ||
        number > 0 && match[2] == null) {
      return null;
    }
    return text;
  }

  factory ReaderBlockSpacing.fromProperties(
    Map<String, String> values, {
    bool vertical = false,
  }) {
    List<String> edge(String kind, bool start) {
      final physical = vertical
          ? (start ? 'right' : 'left')
          : (start ? 'top' : 'bottom');
      final value = length(
        values['$kind-block-${start ? 'start' : 'end'}'] ??
            values['$kind-$physical'],
      );
      return value == null ? const [] : [value];
    }

    return ReaderBlockSpacing(
      before: edge('margin', true),
      after: edge('margin', false),
      leading: edge('padding', true),
      trailing: edge('padding', false),
    );
  }

  ReaderBlockSpacing merge(ReaderBlockSpacing other) => ReaderBlockSpacing(
    before: [...before, ...other.before],
    after: [...after, ...other.after],
    leading: [...leading, ...other.leading],
    trailing: [...trailing, ...other.trailing],
  );
  ReaderBlockSpacing get start =>
      ReaderBlockSpacing(before: before, leading: leading);
  ReaderBlockSpacing get end =>
      ReaderBlockSpacing(after: after, trailing: trailing);

  static double _pixels(
    String value,
    double font,
    double lineHeight,
    double width,
  ) {
    final match = _length.firstMatch(value)!;
    return double.parse(match[1]!) *
        switch (match[2]) {
          'em' || 'rem' => font,
          'ex' => font * .5,
          'lh' => font * lineHeight,
          '%' => width / 100,
          'pt' => 96 / 72,
          _ => 1.0,
        };
  }

  double gapBefore(
    ReaderBlockSpacing? previous, {
    required double font,
    required double lineHeight,
    required double width,
    required double defaultGap,
    bool overrideGap = false,
  }) {
    double maximum(List<String> values) => values.fold(
      0.0,
      (a, b) => math.max(a, _pixels(b, font, lineHeight, width)),
    );
    double total(List<String> values) =>
        values.fold(0.0, (a, b) => a + _pixels(b, font, lineHeight, width));
    if (previous != null && overrideGap) {
      return defaultGap + total(leading) + total(previous.trailing);
    }
    final prior = previous == null
        ? 0.0
        : previous.after.isEmpty
        ? defaultGap
        : maximum(previous.after);
    return math.max(prior, maximum(before)) +
        total(leading) +
        total(previous?.trailing ?? const []);
  }

  Map<String, Object> toJson() => {
    if (before.isNotEmpty) 'before': before,
    if (after.isNotEmpty) 'after': after,
    if (leading.isNotEmpty) 'leading': leading,
    if (trailing.isNotEmpty) 'trailing': trailing,
  };
  factory ReaderBlockSpacing.fromJson(Object? value) {
    if (value is! Map) return const ReaderBlockSpacing();
    List<String> values(String key) => value[key] is! List
        ? const []
        : [
            for (final item in (value[key] as List))
              if (item is String && length(item) != null) item,
          ];
    return ReaderBlockSpacing(
      before: values('before'),
      after: values('after'),
      leading: values('leading'),
      trailing: values('trailing'),
    );
  }
}

class ReaderRuby {
  const ReaderRuby(this.start, this.end, this.text);
  final int start, end;
  final String text;
  Map<String, Object> toJson() => {'start': start, 'end': end, 'text': text};
}

class ReaderNoteReference {
  const ReaderNoteReference(this.start, this.end, this.id);
  final int start, end;
  final String id;
  Map<String, Object> toJson() => {'start': start, 'end': end, 'id': id};
}

class ReaderEmphasis {
  const ReaderEmphasis(this.start, this.end, this.mask);
  final int start, end, mask;
  Map<String, int> toJson() => {'start': start, 'end': end, 'mask': mask};
}

class _ReaderEmphasisIndex {
  _ReaderEmphasisIndex(List<ReaderEmphasis> runs) {
    final events = <(int, int, int)>[
      for (final run in runs)
        if (run.start < run.end) ...[
          (run.start, run.mask, 1),
          (run.end, run.mask, -1),
        ],
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final active = <int, int>{};
    var i = 0, mask = 0;
    while (i < events.length) {
      final offset = events[i].$1;
      do {
        final (_, flag, change) = events[i++];
        final count = (active[flag] ?? 0) + change;
        if (count == 0) {
          active.remove(flag);
        } else {
          active[flag] = count;
        }
      } while (i < events.length && events[i].$1 == offset);
      // EPUB has three flags (eight possible masks). Count complete masks so
      // ending one overlapping run never clears a flag still used by another.
      var next = 0;
      for (final flag in active.keys) {
        next |= flag;
      }
      if (next != mask) {
        _offsets.add(offset);
        _masks.add(next);
        mask = next;
      }
    }
  }

  final _offsets = <int>[], _masks = <int>[];
  int debugComparisons = 0;

  int at(int offset) {
    var low = 0, high = _offsets.length;
    while (low < high) {
      assert(() {
        debugComparisons++;
        return true;
      }());
      final middle = (low + high) ~/ 2;
      if (_offsets[middle] <= offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == 0 ? 0 : _masks[low - 1];
  }
}

class ReaderRichParagraph {
  const ReaderRichParagraph({
    this.alignment = '',
    this.writing = '',
    this.rule = false,
    this.ruby = const [],
    this.references = const [],
    this.emphasis = const [],
    this.breakBefore = false,
    this.breakAfter = false,
    this.spacing = const ReaderBlockSpacing(),
    this.language = '',
    this.opacity = 1,
  });
  final String alignment, writing;
  final bool rule;
  final List<ReaderRuby> ruby;
  final List<ReaderNoteReference> references;
  final List<ReaderEmphasis> emphasis;
  final bool breakBefore, breakAfter;
  final ReaderBlockSpacing spacing;
  final String language;
  final double opacity;
  double gapBefore(
    ReaderRichParagraph? previous, {
    required double font,
    required double lineHeight,
    required double width,
    required double defaultGap,
    bool overrideGap = false,
  }) => spacing.gapBefore(
    previous?.spacing,
    font: font,
    lineHeight: lineHeight,
    width: width,
    defaultGap: defaultGap,
    overrideGap: overrideGap,
  );
  bool get allowsIndent =>
      !const {'center', 'right', 'end'}.contains(alignment);
  bool get empty =>
      alignment.isEmpty &&
      writing.isEmpty &&
      !rule &&
      ruby.isEmpty &&
      references.isEmpty &&
      emphasis.isEmpty &&
      !breakBefore &&
      !breakAfter &&
      spacing.empty &&
      language.isEmpty &&
      opacity == 1;

  static TextStyle emphasized(TextStyle base, int mask) => mask == 0
      ? base
      : base.copyWith(
          fontWeight: mask & 1 != 0 ? FontWeight.w700 : base.fontWeight,
          fontStyle: mask & 2 != 0 ? FontStyle.italic : base.fontStyle,
          decoration: mask & 4 != 0
              ? TextDecoration.underline
              : base.decoration,
        );
  List<InlineSpan> spans(String text) {
    if (emphasis.isEmpty) return [TextSpan(text: text)];
    final indexed = _ReaderEmphasisIndex(emphasis);
    final boundaries = <int>{
      0,
      text.length,
      for (final run in emphasis) ...[
        run.start.clamp(0, text.length),
        run.end.clamp(0, text.length),
      ],
    }.toList()..sort();
    return [
      for (var i = 0; i < boundaries.length - 1; i++)
        TextSpan(
          text: text.substring(boundaries[i], boundaries[i + 1]),
          style: emphasized(const TextStyle(), indexed.at(boundaries[i])),
        ),
    ];
  }

  TextAlign textAlign(TextAlign fallback) => switch (alignment) {
    'right' || 'end' => TextAlign.end,
    'center' => TextAlign.center,
    'left' || 'start' => TextAlign.start,
    'justify' => TextAlign.justify,
    _ => fallback,
  };
  TextStyle textStyle(TextStyle original) {
    final ink = opacity == 1 || original.color == null
        ? original
        : original.copyWith(
            color: original.color!.withValues(
              alpha: original.color!.a * opacity,
            ),
          );
    return ruby.isEmpty
        ? ink
        : ink.copyWith(
            // CJK fonts can have taller ink than their nominal font size. Ruby
            // needs real leading above the base, shared by paint and pagination.
            height: (original.height ?? 1.72) < 2.5 ? 2.5 : original.height,
            leadingDistribution: TextLeadingDistribution.proportional,
          );
  }

  Map<String, Object> toJson() => {
    if (language.isNotEmpty) 'lang': language,
    if (opacity != 1) 'opacity': opacity,
    if (alignment.isNotEmpty) 'align': alignment,
    if (writing.isNotEmpty) 'writing': writing,
    if (rule) 'rule': true,
    if (breakBefore) 'breakBefore': true,
    if (breakAfter) 'breakAfter': true,
    if (!spacing.empty) 'spacing': spacing.toJson(),
    if (emphasis.isNotEmpty)
      'emphasis': emphasis.map((r) => r.toJson()).toList(),
    if (ruby.isNotEmpty) 'ruby': ruby.map((r) => r.toJson()).toList(),
    if (references.isNotEmpty)
      'refs': references.map((r) => r.toJson()).toList(),
  };
  ReaderRichParagraph slice(int start, int end) => ReaderRichParagraph(
    alignment: alignment,
    writing: writing,
    language: language,
    opacity: opacity,
    rule: rule,
    breakBefore: breakBefore && start == 0,
    breakAfter: breakAfter,
    spacing: ReaderBlockSpacing(
      before: start == 0 ? spacing.before : const [],
      leading: start == 0 ? spacing.leading : const [],
      after: spacing.after,
      trailing: spacing.trailing,
    ),
    emphasis: [
      for (final r in emphasis)
        if (r.start < end && r.end > start)
          ReaderEmphasis(
            (r.start - start).clamp(0, end - start),
            (r.end - start).clamp(0, end - start),
            r.mask,
          ),
    ],
    ruby: [
      for (final r in ruby)
        if (r.start < end && r.end > start)
          ReaderRuby(
            (r.start - start).clamp(0, end - start),
            (r.end - start).clamp(0, end - start),
            rubyPart(r, start, end),
          ),
    ],
    references: [
      for (final r in references)
        if (r.start < end && r.end > start)
          ReaderNoteReference(
            (r.start - start).clamp(0, end - start),
            (r.end - start).clamp(0, end - start),
            r.id,
          ),
    ],
  );
  static String rubyPart(ReaderRuby ruby, int start, int end) {
    final letters = ruby.text.characters.toList();
    return _rubyPart(ruby, start, end, letters);
  }

  static String _rubyPart(
    ReaderRuby ruby,
    int start,
    int end,
    List<String> letters,
  ) {
    final a =
        (((start - ruby.start).clamp(0, ruby.end - ruby.start)) /
                (ruby.end - ruby.start) *
                letters.length)
            .floor();
    final b =
        (((end - ruby.start).clamp(0, ruby.end - ruby.start)) /
                (ruby.end - ruby.start) *
                letters.length)
            .floor();
    return letters.sublist(a, b).join();
  }

  factory ReaderRichParagraph.fromJson(Map value, int length) {
    bool range(Map r) =>
        r['start'] is int &&
        r['end'] is int &&
        r['start'] >= 0 &&
        r['end'] > r['start'] &&
        r['end'] <= length;
    return ReaderRichParagraph(
      alignment: '${value['align'] ?? ''}',
      writing: '${value['writing'] ?? ''}',
      language: readerLanguageCode('${value['lang'] ?? ''}'),
      opacity:
          value['opacity'] is num &&
              (value['opacity'] as num).isFinite &&
              value['opacity'] >= 0 &&
              value['opacity'] <= 1
          ? (value['opacity'] as num).toDouble()
          : 1,
      rule: value['rule'] == true,
      breakBefore: value['breakBefore'] == true,
      breakAfter: value['breakAfter'] == true,
      spacing: ReaderBlockSpacing.fromJson(value['spacing']),
      emphasis: [
        for (final r
            in value['emphasis'] is List ? value['emphasis'] as List : const [])
          if (r is Map &&
              range(r) &&
              r['mask'] is int &&
              r['mask'] >= 0 &&
              r['mask'] <= 7)
            ReaderEmphasis(r['start'], r['end'], r['mask']),
      ],
      ruby: [
        for (final r
            in value['ruby'] is List ? value['ruby'] as List : const [])
          if (r is Map &&
              range(r) &&
              r['text'] is String &&
              r['text'].length <= 2000)
            ReaderRuby(r['start'], r['end'], r['text']),
      ],
      references: [
        for (final r
            in value['refs'] is List ? value['refs'] as List : const [])
          if (r is Map && range(r) && r['id'] is String)
            ReaderNoteReference(r['start'], r['end'], r['id']),
      ],
    );
  }
}

/// Optional local EPUB metadata. Body coordinates are always plain UTF-16 text;
/// annotations never become copied text, speech, or an extra paragraph.
final _paragraphHeadingPattern = RegExp(
  r'^(?:(?:【[^】\n]{1,32}】|《[^》\n]{1,32}》)?[ \t　]*[（(【\[]?第\s*[\d０-９零一二三四五六七八九十百千万千萬〇两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟廿卅卌\u2160-\u217F\u2460-\u2473\-~～—–─━、,，/至到]+\s*[章节節回囘话話幕折卷捲部集篇段季期更册冊编編輯辑讲講场場局夜曲弹彈]'
  r'|(?:序章|序曲|序言|序幕|楔子|引子|尾声|番外|后记|前言|目录|终章|大结局|结局|[上中下][篇卷部集])(?:\s|$|[：:·・（(【\[])'
  r'|(?:chapter|part|section|episode|ep\.?|act|vol(?:ume)?\.?)\s+[\divxlcdm]+\b'
  r'|卷[一二三四五六七八九十百千万零〇两\d０-９]+(?:\s|$|[：:·・])'
  r'|(?:[\d０-９]{1,4}|[一二三四五六七八九十百零〇]{1,6})[.．、:：]\s*\S'
  r'|(?:[（(【\[［〖〔]\s*[\d０-９零一二三四五六七八九十百千万〇两\u2160-\u217F\u2460-\u2473\-~～—–、]+\s*[）)】\]］〗〕])'
  r'|(?:分[卷节]阅读\s*\d+|段落|性能段落|下一章段落|正文\s*[\d\-]+)\s*\d*)',
  caseSensitive: false,
);
final _midSentenceEndPattern = RegExp(r'[,，、―—\-“‘「『（(《〈【\[]$');
final _terminalSentenceEndPattern = RegExp(
  r'[。！？!?…⋯～~；;：:.。”’」』）)】\]》〉〕}"\x27]$',
);
final _cjkEndPattern = RegExp(r'[\u3400-\u9fff]$');
final _cjkOrPunctStartPattern = RegExp(
  r'^[\u3400-\u9fff，,。！？!?、；;：:”’」』）)】\]》〉〕]',
);
final _prosePunctPattern = RegExp(r'[，,。！？!?、；;：:“”‘’「」『』（）()]');
final _indentStartPattern = RegExp(r'^(?:[　\t]| {2,})');
final _openQuoteEndPattern = RegExp(r'[“‘「『（(《〈【\[]$');
final _asciiWordEndPattern = RegExp(r'[A-Za-z0-9]$');
final _asciiWordStartPattern = RegExp(r'^[A-Za-z0-9]');

int _charCount(String text, int codeUnit) {
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == codeUnit) count++;
  }
  return count;
}

bool _hasUnclosedQuote(String text) =>
    _charCount(text, 0x201C) > _charCount(text, 0x201D) || // “ ”
    _charCount(text, 0x300C) > _charCount(text, 0x300D) || // 「 」
    _charCount(text, 0x300E) > _charCount(text, 0x300F) || // 『 』
    _charCount(text, 0xFF08) > _charCount(text, 0xFF09); // （ ）

/// Joins two fragments that belong to the same paragraph without introducing
/// extra spaces between CJK characters.
String joinBrokenParagraph(String prev, String next) {
  final p = prev.trimRight();
  final n = next.trimLeft();
  if (p.isEmpty) return next;
  if (n.isEmpty) return prev;
  final needsSpace =
      _asciiWordEndPattern.hasMatch(p) && _asciiWordStartPattern.hasMatch(n);
  return needsSpace ? '$p $n' : '$p$n';
}

/// Returns true when [prev] was hard-wrapped mid-sentence and [next] continues
/// the same paragraph.
bool shouldMergeBrokenParagraph(String prev, String next) {
  final p = prev.trimRight();
  final n = next.trimLeft();
  if (p.isEmpty || n.isEmpty) return false;
  if (p == '[插图]' ||
      n == '[插图]' ||
      p.startsWith('<!--') ||
      n.startsWith('<!--')) {
    return false;
  }
  if (_paragraphHeadingPattern.hasMatch(p.trimLeft()) ||
      _paragraphHeadingPattern.hasMatch(n)) {
    return false;
  }
  if (_indentStartPattern.hasMatch(next) && !_openQuoteEndPattern.hasMatch(p)) {
    return false;
  }
  if (_midSentenceEndPattern.hasMatch(p) &&
      _cjkOrPunctStartPattern.hasMatch(n)) {
    return true;
  }
  if (_hasUnclosedQuote(p) && !RegExp(r'[。！？!?…⋯]$').hasMatch(p)) {
    return true;
  }
  if (_cjkEndPattern.hasMatch(p) &&
      _cjkOrPunctStartPattern.hasMatch(n) &&
      p.trimLeft().length >= 12 &&
      (_prosePunctPattern.hasMatch(p) || _prosePunctPattern.hasMatch(n))) {
    return true;
  }
  return false;
}

bool _shouldJoinSingleNewline(String prev, String nextRaw) {
  final p = prev.trimRight();
  final n = nextRaw.trimLeft();
  if (p.isEmpty || n.isEmpty) return false;
  if (p == '[插图]' ||
      n == '[插图]' ||
      p.startsWith('<!--') ||
      n.startsWith('<!--')) {
    return false;
  }
  if (_paragraphHeadingPattern.hasMatch(p.trimLeft()) ||
      _paragraphHeadingPattern.hasMatch(n)) {
    return false;
  }
  if (_indentStartPattern.hasMatch(nextRaw) &&
      !_openQuoteEndPattern.hasMatch(p)) {
    return false;
  }
  if (_midSentenceEndPattern.hasMatch(p)) return true;
  if (_hasUnclosedQuote(p) && !RegExp(r'[。！？!?…⋯]$').hasMatch(p)) {
    return true;
  }
  if (_terminalSentenceEndPattern.hasMatch(p)) return false;
  if (p.trimLeft().length < 10 &&
      !_prosePunctPattern.hasMatch(p) &&
      !_prosePunctPattern.hasMatch(n)) {
    return false;
  }
  return _cjkEndPattern.hasMatch(p) && _cjkOrPunctStartPattern.hasMatch(n);
}

class ReflowedReaderParagraph {
  const ReflowedReaderParagraph(
    this.text,
    this.charStarts,
    this.charEnds, {
    this.origin = 0,
  });

  factory ReflowedReaderParagraph.contiguous(String text, int start) =>
      ReflowedReaderParagraph(
        text,
        List<int>.generate(text.length, (i) => start + i, growable: false),
        List<int>.generate(text.length, (i) => start + i + 1, growable: false),
        origin: start,
      );

  final String text;
  final List<int> charStarts;
  final List<int> charEnds;
  final int origin;

  int rawStart(int offset) {
    if (text.isEmpty) return origin;
    if (offset <= 0) return charStarts.first;
    if (offset >= text.length) return charEnds.last;
    return charStarts[offset];
  }

  int rawEnd(int offset) {
    if (text.isEmpty) return origin;
    if (offset <= 0) return charStarts.first;
    if (offset >= text.length) return charEnds.last;
    return charEnds[offset - 1];
  }
}

ReflowedReaderParagraph _joinReflowedParagraph(
  ReflowedReaderParagraph prev,
  ReflowedReaderParagraph next,
) {
  final p = prev.text.trimRight();
  final n = next.text.trimLeft();
  if (p.isEmpty) return next;
  if (n.isEmpty) return prev;
  final pLen = p.length;
  final nDrop = next.text.length - n.length;
  final needsSpace =
      _asciiWordEndPattern.hasMatch(p) && _asciiWordStartPattern.hasMatch(n);
  if (!needsSpace) {
    return ReflowedReaderParagraph(
      '$p$n',
      [
        ...prev.charStarts.sublist(0, pLen),
        ...next.charStarts.sublist(nDrop),
      ],
      [
        ...prev.charEnds.sublist(0, pLen),
        ...next.charEnds.sublist(nDrop),
      ],
      origin: prev.origin,
    );
  }
  return ReflowedReaderParagraph(
    '$p $n',
    [
      ...prev.charStarts.sublist(0, pLen),
      prev.charEnds[pLen - 1],
      ...next.charStarts.sublist(nDrop),
    ],
    [
      ...prev.charEnds.sublist(0, pLen),
      next.charStarts[nDrop],
      ...next.charEnds.sublist(nDrop),
    ],
    origin: prev.origin,
  );
}

ReflowedReaderParagraph _stripLeadingIndent(ReflowedReaderParagraph input) {
  final match = _indentStartPattern.firstMatch(input.text);
  final drop = match?.end ?? 0;
  if (drop <= 0) return input;
  return ReflowedReaderParagraph(
    input.text.substring(drop),
    input.charStarts.sublist(drop),
    input.charEnds.sublist(drop),
    origin: drop < input.charStarts.length
        ? input.charStarts[drop]
        : input.rawEnd(input.text.length),
  );
}

/// Reflows plain-text novel paragraphs while recording exact UTF-16 source
/// character boundaries for every character in each reflowed paragraph.
List<ReflowedReaderParagraph> reflowReaderParagraphsWithOffsets(String source) {
  final expanded = <ReflowedReaderParagraph>[];
  var blockStart = 0;
  while (true) {
    final sep = source.indexOf('\n\n', blockStart);
    final blockEnd = sep < 0 ? source.length : sep;
    final block = source.substring(blockStart, blockEnd);
    if (!block.contains('\n')) {
      expanded.add(ReflowedReaderParagraph.contiguous(block, blockStart));
    } else {
      final lines = <ReflowedReaderParagraph>[];
      var lineStart = blockStart;
      while (lineStart <= blockEnd) {
        final nl = source.indexOf('\n', lineStart);
        final lineEnd = (nl < 0 || nl > blockEnd) ? blockEnd : nl;
        final rawLine = source.substring(lineStart, lineEnd);
        final trimmed = rawLine.trimRight();
        if (trimmed.trim().isNotEmpty) {
          lines.add(ReflowedReaderParagraph.contiguous(trimmed, lineStart));
        }
        if (nl < 0 || nl >= blockEnd) break;
        lineStart = nl + 1;
      }
      if (lines.isEmpty) {
        expanded.add(ReflowedReaderParagraph.contiguous(block, blockStart));
      } else {
        var current = lines.first;
        for (var i = 1; i < lines.length; i++) {
          final next = lines[i];
          if (_shouldJoinSingleNewline(current.text, next.text)) {
            current = _joinReflowedParagraph(current, next);
          } else {
            expanded.add(current);
            current = _stripLeadingIndent(next);
          }
        }
        expanded.add(current);
      }
    }
    if (sep < 0) break;
    blockStart = sep + 2;
  }
  if (expanded.length <= 1) return expanded;
  final merged = <ReflowedReaderParagraph>[expanded.first];
  for (var i = 1; i < expanded.length; i++) {
    final next = expanded[i];
    if (shouldMergeBrokenParagraph(merged.last.text, next.text)) {
      merged[merged.length - 1] = _joinReflowedParagraph(merged.last, next);
    } else {
      merged.add(next);
    }
  }
  return merged;
}

({int paragraph, int offset}) locateReflowedStart(
  List<ReflowedReaderParagraph> paragraphs,
  int localOffset,
) {
  if (paragraphs.isEmpty) return (paragraph: 0, offset: 0);
  for (var p = 0; p < paragraphs.length; p++) {
    final item = paragraphs[p];
    if (item.text.isEmpty) {
      if (item.origin >= localOffset) return (paragraph: p, offset: 0);
      continue;
    }
    if (item.charEnds.last <= localOffset) continue;
    var low = 0;
    var high = item.charEnds.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (item.charEnds[mid] <= localOffset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return (paragraph: p, offset: low.clamp(0, item.text.length));
  }
  final last = paragraphs.length - 1;
  return (paragraph: last, offset: paragraphs[last].text.length);
}

({int paragraph, int offset}) locateReflowedEnd(
  List<ReflowedReaderParagraph> paragraphs,
  int localEnd,
) {
  if (paragraphs.isEmpty) return (paragraph: 0, offset: 0);
  for (var p = paragraphs.length - 1; p >= 0; p--) {
    final item = paragraphs[p];
    if (item.text.isEmpty) {
      if (item.origin <= localEnd) return (paragraph: p, offset: 0);
      continue;
    }
    if (item.charStarts.first >= localEnd) continue;
    var low = 0;
    var high = item.charStarts.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (item.charStarts[mid] < localEnd) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final idx = low - 1;
    final endOffset = localEnd >= item.charEnds[idx] ? idx + 1 : idx;
    return (paragraph: p, offset: endOffset.clamp(0, item.text.length));
  }
  return (paragraph: 0, offset: 0);
}

String extractReflowedRangeText(
  List<ReflowedReaderParagraph> paragraphs,
  int startParagraph,
  int startOffset,
  int endParagraph,
  int endOffset,
) {
  if (startParagraph < 0 ||
      endParagraph < startParagraph ||
      endParagraph >= paragraphs.length) {
    return '';
  }
  if (startParagraph == endParagraph) {
    final text = paragraphs[startParagraph].text;
    if (startOffset < 0 || endOffset < startOffset || endOffset > text.length) {
      return '';
    }
    return text.substring(startOffset, endOffset);
  }
  final buffer = StringBuffer();
  for (var p = startParagraph; p <= endParagraph; p++) {
    final text = paragraphs[p].text;
    final from = p == startParagraph ? startOffset.clamp(0, text.length) : 0;
    final to = p == endParagraph
        ? endOffset.clamp(from, text.length)
        : text.length;
    if (p > startParagraph) buffer.write('\n');
    buffer.write(text.substring(from, to));
  }
  return buffer.toString();
}

/// Reflows plain-text novel paragraphs by repairing hard-wrapped single/double
/// newlines inside a sentence while keeping genuine paragraphs separate.
List<String> reflowReaderParagraphs(String source) {
  final rawBlocks = source.split('\n\n');
  final expanded = <String>[];
  for (final block in rawBlocks) {
    if (!block.contains('\n')) {
      expanded.add(block);
      continue;
    }
    final lines = block
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      expanded.add(block);
      continue;
    }
    var current = lines.first;
    for (var i = 1; i < lines.length; i++) {
      final next = lines[i];
      if (_shouldJoinSingleNewline(current, next)) {
        current = joinBrokenParagraph(current, next);
      } else {
        expanded.add(current);
        current = next.replaceFirst(_indentStartPattern, '');
      }
    }
    expanded.add(current);
  }
  if (expanded.length <= 1) return expanded;
  final merged = <String>[expanded.first];
  for (var i = 1; i < expanded.length; i++) {
    final next = expanded[i];
    if (shouldMergeBrokenParagraph(merged.last, next)) {
      merged[merged.length - 1] = joinBrokenParagraph(merged.last, next);
    } else {
      merged.add(next);
    }
  }
  return merged;
}

class ReaderRichBody {
  const ReaderRichBody(
    this.paragraphs, {
    this.formats = const {},
    this.notes = const {},
    this.revision = '',
    this.coordinateMap,
  });
  static const prefix = '<!--reader-rich-v1:';
  final List<String> paragraphs;
  final Map<int, ReaderRichParagraph> formats;
  final Map<String, String> notes;
  final String revision;
  final ReaderCoordinateMap? coordinateMap;
  String encode() {
    if (paragraphs.isEmpty) return '';
    final body = paragraphs.join('\n\n');
    if (formats.isEmpty &&
        notes.isEmpty &&
        revision.isEmpty &&
        coordinateMap == null) {
      return body;
    }
    final meta = jsonEncode({
      'count': paragraphs.length,
      'blocks': {for (final e in formats.entries) '${e.key}': e.value.toJson()},
      'notes': notes,
      if (revision.isNotEmpty) 'revision': revision,
      if (coordinateMap != null) 'coordinates': coordinateMap!.toJson(),
    });
    return '$body\n\n$prefix${base64Url.encode(utf8.encode(meta))}-->';
  }

  static ReaderRichBody decode(String source) {
    if (!source.contains(prefix)) {
      return ReaderRichBody(reflowReaderParagraphs(source));
    }
    final paragraphs = <String>[],
        formats = <int, ReaderRichParagraph>{},
        notes = <String, String>{};
    var revision = '';
    ReaderCoordinateMap? coordinates;
    for (final part in source.split('\n\n')) {
      if (!part.startsWith(prefix) || !part.endsWith('-->')) {
        paragraphs.add(part);
        continue;
      }
      final value = jsonDecode(
        utf8.decode(
          base64Url.decode(part.substring(prefix.length, part.length - 3)),
        ),
      );
      if (value is! Map ||
          value['count'] is! int ||
          value['count'] > paragraphs.length ||
          value['count'] < 0 ||
          value['blocks'] is! Map ||
          value['notes'] is! Map) {
        throw const FormatException('原书排版数据格式有误');
      }
      final base = paragraphs.length - (value['count'] as int);
      revision = value['revision'] is String
          ? value['revision']
          : 'epub-rich-v1';
      if (value['coordinates'] != null) {
        coordinates = ReaderCoordinateMap.fromJson(
          value['coordinates'],
          paragraphs.join('\n\n').length,
        );
      }
      for (final e in (value['blocks'] as Map).entries) {
        final index = int.tryParse('${e.key}');
        if (index != null &&
            index >= 0 &&
            base + index < paragraphs.length &&
            e.value is Map) {
          formats[base + index] = ReaderRichParagraph.fromJson(
            e.value,
            paragraphs[base + index].length,
          );
        }
      }
      for (final e in (value['notes'] as Map).entries) {
        if (e.key is String && e.value is String && e.value.length <= 32000) {
          notes[e.key] = e.value;
        }
      }
    }
    return ReaderRichBody(
      paragraphs,
      formats: formats,
      notes: notes,
      revision: revision,
      coordinateMap: coordinates,
    );
  }
}
