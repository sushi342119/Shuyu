import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'reader_purification_import.dart';
import 'reader_underline.dart';
import 'regex_safety.dart' as regex_safety;
export 'regex_safety.dart' show detectUnsafeRegexPattern;

/// Purified display text together with an optional monotonic per-character
/// `[rawStart, rawEnd)` interval map (`length == text.length * 2`) projecting
/// purified code units back to the raw stored paragraph. When [toRaw] is `null`,
/// offsets are 1:1.
@immutable
class PurifiedParagraph {
  const PurifiedParagraph(this.text, {this.rawLength, this.toRaw});

  final String text;
  final int? rawLength;
  final List<int>? toRaw;

  int get sourceLength => rawLength ?? text.length;
  bool get isIdentity => toRaw == null;

  int rawOffsetFor(int purifiedOffset) {
    final map = toRaw;
    final srcLen = sourceLength;
    if (map == null) return purifiedOffset.clamp(0, srcLen);
    if (text.isEmpty || map.isEmpty) return 0;
    if (purifiedOffset <= 0) return map[0].clamp(0, srcLen);
    if (purifiedOffset >= text.length) {
      return map[2 * (text.length - 1) + 1].clamp(0, srcLen);
    }
    return map[2 * purifiedOffset].clamp(0, srcLen);
  }

  (int, int) rawRangeFor(int purifiedStart, int purifiedEnd) {
    final map = toRaw;
    final srcLen = sourceLength;
    if (map == null) {
      final s = purifiedStart.clamp(0, srcLen);
      final e = purifiedEnd.clamp(s, srcLen);
      return (s, e);
    }
    if (text.isEmpty || map.isEmpty) return (0, 0);
    final p0 = purifiedStart.clamp(0, text.length);
    final p1 = purifiedEnd.clamp(p0, text.length);
    if (p0 >= p1) {
      final off = rawOffsetFor(p0);
      return (off, off);
    }
    var s = map[2 * p0];
    var e = map[2 * (p1 - 1) + 1];
    if (e < s) {
      final t = s;
      s = e;
      e = t;
    }
    if (e == s && srcLen > 0) {
      if (s < srcLen) {
        e = s + 1;
      } else {
        s = srcLen - 1;
        e = srcLen;
      }
    }
    return (s.clamp(0, srcLen), e.clamp(0, srcLen));
  }

  (int, int)? purifiedRangeFor(int rawStart, int rawEnd) {
    if (rawEnd <= rawStart || text.isEmpty) return null;
    final map = toRaw;
    if (map == null) {
      final s = rawStart.clamp(0, text.length);
      final e = rawEnd.clamp(s, text.length);
      return s < e ? (s, e) : null;
    }
    if (map.length < text.length * 2) return null;
    var pStart = -1;
    var pEnd = -1;
    for (var i = 0; i < text.length; i++) {
      final segStart = map[2 * i];
      final segEnd = map[2 * i + 1];
      final overlaps = segEnd > segStart
          ? (segEnd > rawStart && segStart < rawEnd)
          : (segStart >= rawStart && segStart < rawEnd);
      if (overlaps) {
        if (pStart < 0) pStart = i;
        pEnd = i + 1;
      }
    }
    if (pStart < 0 || pEnd <= pStart) return null;
    return (pStart, pEnd);
  }
}

List<int> _identityMap(int length) => List<int>.generate(
  length * 2,
  (idx) => (idx >> 1) + (idx & 1),
  growable: false,
);

List<int> _mapReplacementSegments({
  required List<int> prevMap,
  required int prevLength,
  required List<(int start, int end, int repLen)> edits,
}) {
  final out = <int>[];
  var cursor = 0;
  for (final (start, end, repLen) in edits) {
    for (var i = cursor; i < start; i++) {
      out
        ..add(prevMap[2 * i])
        ..add(prevMap[2 * i + 1]);
    }
    if (repLen > 0) {
      if (start < end) {
        final rawStart = prevMap[2 * start];
        final rawEnd = prevMap[2 * (end - 1) + 1];
        final rawSpan = rawEnd - rawStart;
        for (var r = 0; r < repLen; r++) {
          if (repLen == end - start) {
            out
              ..add(prevMap[2 * (start + r)])
              ..add(prevMap[2 * (start + r) + 1]);
          } else if (rawSpan <= 0) {
            out
              ..add(rawStart)
              ..add(rawStart);
          } else {
            out
              ..add(rawStart + ((r * rawSpan) ~/ repLen))
              ..add(rawStart + (((r + 1) * rawSpan) ~/ repLen));
          }
        }
      } else {
        final anchor = start < prevLength
            ? prevMap[2 * start]
            : (prevLength > 0 ? prevMap[2 * (prevLength - 1) + 1] : 0);
        for (var r = 0; r < repLen; r++) {
          out
            ..add(anchor)
            ..add(anchor);
        }
      }
    }
    cursor = end;
  }
  for (var i = cursor; i < prevLength; i++) {
    out
      ..add(prevMap[2 * i])
      ..add(prevMap[2 * i + 1]);
  }
  return out;
}

List<int> _mapManualEdit(String raw, String edited) {
  if (raw == edited) return _identityMap(raw.length);
  var prefix = 0;
  final minLen = raw.length < edited.length ? raw.length : edited.length;
  while (prefix < minLen &&
      raw.codeUnitAt(prefix) == edited.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < (minLen - prefix) &&
      raw.codeUnitAt(raw.length - 1 - suffix) ==
          edited.codeUnitAt(edited.length - 1 - suffix)) {
    suffix++;
  }
  return _mapReplacementSegments(
    prevMap: _identityMap(raw.length),
    prevLength: raw.length,
    edits: [
      (
        prefix,
        raw.length - suffix,
        edited.length - prefix - suffix,
      ),
    ],
  );
}

const _quoteChars = {0x0022, 0x201C, 0x201D}; // " “ ”
const _sentenceEndChars = '。！？!?…~～';
const _openingContextChars = '，：,:—\n\t 　（(【[《<';
const _closingFollowChars = '，。！？!?；;、）】]》>\n\t 　';
const _speechVerbs = '问说喊唱叫骂道着答笑叹想念应劝吼哭哼';

/// Repairs straight quotes `"` and mis-ordered Chinese curly quotes `“”` into
/// properly paired `“...”` using surrounding punctuation and dialogue verbs
/// (inspired by legado-E's `ContentHelp.reSegment`).
String repairReaderQuotes(String input) {
  if (input.isEmpty) return input;
  var hasQuote = false;
  for (var i = 0; i < input.length; i++) {
    if (_quoteChars.contains(input.codeUnitAt(i))) {
      hasQuote = true;
      break;
    }
  }
  if (!hasQuote) return input;

  final buffer = StringBuffer();
  var open = false;
  for (var i = 0; i < input.length; i++) {
    final unit = input.codeUnitAt(i);
    if (!_quoteChars.contains(unit)) {
      buffer.writeCharCode(unit);
      continue;
    }
    final prev = i > 0 ? input[i - 1] : '\n';
    final next = i + 1 < input.length ? input[i + 1] : '\n';

    bool? forceOpen;
    if (i == 0 || prev == '\n' || '：:（(【['.contains(prev)) {
      forceOpen = true;
    } else if (i == input.length - 1 || next == '\n') {
      forceOpen = false;
    } else if (_sentenceEndChars.contains(prev) &&
        (_closingFollowChars.contains(next) || _speechVerbs.contains(next))) {
      forceOpen = false;
    } else if (_openingContextChars.contains(prev) && !open) {
      forceOpen = true;
    }

    final useOpen = forceOpen ?? !open;
    buffer.write(useOpen ? '“' : '”');
    open = useOpen;
  }
  return buffer.toString();
}

(String, List<int>?) _reSegmentDialogueWithMap(
  String input,
  List<int>? prevMap,
) {
  if (input.length < 160 || input.contains('\n')) return (input, prevMap);
  final out = StringBuffer();
  final mapOut = <int>[];
  final baseMap = prevMap ?? _identityMap(input.length);
  var changed = false;
  var sinceBreak = 0;
  var quoteDepth = 0;
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    out.write(ch);
    mapOut
      ..add(baseMap[2 * i])
      ..add(baseMap[2 * i + 1]);
    sinceBreak++;
    if (ch == '“' || ch == '「' || ch == '『') {
      quoteDepth++;
    } else if (ch == '”' || ch == '」' || ch == '』') {
      if (quoteDepth > 0) quoteDepth--;
      if (quoteDepth == 0 && i + 1 < input.length) {
        final prev = i > 0 ? input[i - 1] : '';
        final next = input[i + 1];
        // Break after a complete spoken sentence `"..."` when the next token
        // starts a new quote or when the segment is already long.
        if (_sentenceEndChars.contains(prev) &&
            (next == '“' ||
                next == '「' ||
                (sinceBreak >= 90 &&
                    !_closingFollowChars.contains(next) &&
                    !_speechVerbs.contains(next)))) {
          out.write('\n　　');
          final anchor = baseMap[2 * (i + 1)];
          for (var k = 0; k < 3; k++) {
            mapOut
              ..add(anchor)
              ..add(anchor);
          }
          changed = true;
          sinceBreak = 0;
        }
      }
    } else if (quoteDepth == 0 &&
        sinceBreak >= 140 &&
        _sentenceEndChars.contains(ch) &&
        i + 1 < input.length) {
      final next = input[i + 1];
      if (next != '”' &&
          next != '」' &&
          next != '』' &&
          !_sentenceEndChars.contains(next) &&
          !_closingFollowChars.contains(next)) {
        out.write('\n　　');
        final anchor = baseMap[2 * (i + 1)];
        for (var k = 0; k < 3; k++) {
          mapOut
            ..add(anchor)
            ..add(anchor);
        }
        changed = true;
        sinceBreak = 0;
      }
    }
  }
  if (!changed) return (input, prevMap);
  return (out.toString(), mapOut);
}

/// Splits an overly dense wall-of-text paragraph at clear dialogue and
/// sentence-group boundaries while keeping normal paragraphs intact.
String reSegmentDialogueText(String input) =>
    _reSegmentDialogueWithMap(input, null).$1;

(String, List<int>?) _dedupLeadingChapterTitleWithMap(
  String paragraph,
  String? chapterTitle,
  List<int>? prevMap,
) {
  if (chapterTitle == null || chapterTitle.trim().isEmpty) {
    return (paragraph, prevMap);
  }
  final cleanTitle = chapterTitle.trim();
  final leadTrimmedCount = paragraph.length - paragraph.trimLeft().length;
  final trimmed = paragraph.substring(leadTrimmedCount);
  if (trimmed.isEmpty) return (paragraph, prevMap);
  if (trimmed == cleanTitle) {
    return ('', const <int>[]);
  }
  final escaped = RegExp.escape(cleanTitle);
  final match = RegExp(
    '^[$escaped\\s\\p{P}]*$escaped(?:[\\s　]*\\n|[\\s　]{2,})',
    unicode: true,
  ).firstMatch(trimmed);
  if (match != null) {
    final afterMatch = trimmed.substring(match.end);
    final rest = afterMatch.trimLeft();
    if (rest.isEmpty) return (paragraph, prevMap);
    final cut =
        leadTrimmedCount + match.end + (afterMatch.length - rest.length);
    final baseMap = prevMap ?? _identityMap(paragraph.length);
    return (rest, baseMap.sublist(2 * cut));
  }
  return (paragraph, prevMap);
}

/// Removes a leading duplicate chapter title from the first paragraph of a
/// chapter when the body repeats the heading verbatim.
String dedupLeadingChapterTitle(String paragraph, String? chapterTitle) =>
    _dedupLeadingChapterTitleWithMap(paragraph, chapterTitle, null).$1;

@immutable
class ReaderPurificationRule {
  const ReaderPurificationRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.isRegex = false,
    this.enabled = false,
    this.builtIn = false,
    this.scopeBookId,
    this.scopeBookTitle,
    this.applyToTitle = false,
    this.applyToContent = true,
    this.importScope = '',
    this.excludeScope = '',
    this.sourceUrl,
    this.unsupportedReason,
  });

  final String id;
  final String name;
  final String pattern;
  final String replacement;
  final bool isRegex;
  final bool enabled;
  final bool builtIn;
  final int? scopeBookId;
  final String? scopeBookTitle;
  final bool applyToTitle;
  final bool applyToContent;
  final String importScope;
  final String excludeScope;
  final String? sourceUrl;
  final String? unsupportedReason;

  bool appliesToBook(int? bookId, {String? bookTitle}) {
    if (scopeBookId != null && scopeBookId != bookId) return false;
    bool matchesScope(String scope) => scope
        .split(';')
        .any((entry) => bookTitle != null && entry.trim() == bookTitle.trim());
    // Local books have no web source URL. Source-only scopes stay inactive.
    if (importScope.trim().isNotEmpty && !matchesScope(importScope)) {
      return false;
    }
    return excludeScope.trim().isEmpty || !matchesScope(excludeScope);
  }

  String get signature => jsonEncode([
    pattern,
    replacement,
    isRegex,
    scopeBookId,
    importScope,
    excludeScope,
    applyToTitle,
    applyToContent,
  ]);

  ReaderPurificationRule copyWith({
    String? name,
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? enabled,
    int? scopeBookId,
    bool clearScopeBook = false,
    String? scopeBookTitle,
    bool? applyToTitle,
  }) => ReaderPurificationRule(
    id: id,
    name: name ?? this.name,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    isRegex: isRegex ?? this.isRegex,
    enabled: enabled ?? this.enabled,
    builtIn: builtIn,
    scopeBookId: clearScopeBook ? null : (scopeBookId ?? this.scopeBookId),
    scopeBookTitle: clearScopeBook
        ? null
        : (scopeBookTitle ?? this.scopeBookTitle),
    applyToTitle: applyToTitle ?? this.applyToTitle,
    applyToContent: applyToContent,
    importScope: importScope,
    excludeScope: excludeScope,
    sourceUrl: sourceUrl,
    unsupportedReason: unsupportedReason,
  );

  static final Map<String, RegExp> _regExpCache = {};
  static final Set<String> _trippedRuleIds = <String>{};

  /// Detects regex patterns prone to catastrophic backtracking (ReDoS) or
  /// excessive complexity before they can block the UI isolate.
  static String? detectUnsafeRegexPattern(String pattern) =>
      regex_safety.detectUnsafeRegexPattern(pattern);

  static RegExp? _compile(String pattern) {
    if (detectUnsafeRegexPattern(pattern) != null) return null;
    try {
      var regExp = _regExpCache[pattern];
      if (regExp == null) {
        if (_regExpCache.length >= 1024) {
          _regExpCache.remove(_regExpCache.keys.first);
        }
        var source = pattern;
        var caseSensitive = true;
        var dotAll = false;
        final flags = RegExp(r'^\(\?([ims]+)\)').firstMatch(source);
        if (flags != null) {
          caseSensitive = !flags[1]!.contains('i');
          dotAll = flags[1]!.contains('s');
          source = source.substring(flags.end);
        }
        final unicode =
            source.contains(r'\p{') ||
            source.contains(r'\P{') ||
            source.runes.any((r) => r > 0xffff);
        if (unicode) {
          // Java permits escaped non-ASCII punctuation; Unicode ECMAScript
          // expects those same literal characters without an identity escape,
          // while preserving even pairs of literal backslashes (`\\`).
          source = source.replaceAllMapped(
            RegExp(r'(?<!\\)((?:\\\\)*)\\([^\x00-\x7f])'),
            (m) => '${m[1]!}${m[2]!}',
          );
        }
        regExp = RegExp(
          source,
          multiLine: true,
          caseSensitive: caseSensitive,
          dotAll: dotAll,
          unicode: unicode,
        );
        _regExpCache[pattern] = regExp;
      }
      return regExp;
    } on FormatException {
      return null;
    }
  }

  String _expandRegexReplacement(Match match) {
    // Dart replaceAll treats $1 literally; Legado uses Java-style groups.
    final out = StringBuffer();
    for (var i = 0; i < replacement.length; i++) {
      final ch = replacement[i];
      if (ch == r'\' && i + 1 < replacement.length) {
        out.write(switch (replacement[++i]) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          final escaped => escaped,
        });
      } else if (ch == r'$' &&
          i + 1 < replacement.length &&
          RegExp(r'[0-9]').hasMatch(replacement[i + 1])) {
        var group = int.parse(replacement[++i]);
        if (group > match.groupCount) {
          out.write('\$$group');
          continue;
        }
        while (i + 1 < replacement.length) {
          final digit = int.tryParse(replacement[i + 1]);
          if (digit == null || group * 10 + digit > match.groupCount) break;
          group = group * 10 + digit;
          i++;
        }
        out.write(match.group(group) ?? '');
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }

  bool matches(String input) {
    if (!enabled ||
        unsupportedReason != null ||
        _trippedRuleIds.contains(id) ||
        replacement.trimLeft().startsWith('@js:') ||
        pattern.isEmpty ||
        input.isEmpty) {
      return false;
    }
    if (id == 'builtin_smart_quotes') {
      return repairReaderQuotes(input) != input;
    }
    if (id == 'builtin_dialogue_resegment') {
      return reSegmentDialogueText(input) != input;
    }
    if (!isRegex) return input.contains(pattern);
    final regExp = _compile(pattern);
    if (regExp == null) return false;
    final sw = Stopwatch()..start();
    final matched = regExp.hasMatch(input);
    sw.stop();
    if (sw.elapsedMicroseconds > 8000 && _trippedRuleIds.add(id)) {
      ReaderPurificationStore.shared._invalidateCaches();
    }
    return matched;
  }

  String apply(String input) => applyWithMap(input, null).$1;

  (String, List<int>?) applyWithMap(String input, List<int>? prevMap) {
    if (!enabled ||
        unsupportedReason != null ||
        _trippedRuleIds.contains(id) ||
        replacement.trimLeft().startsWith('@js:') ||
        input.isEmpty) {
      return (input, prevMap);
    }
    if (id == 'builtin_smart_quotes') {
      return (repairReaderQuotes(input), prevMap);
    }
    if (id == 'builtin_dialogue_resegment') {
      return _reSegmentDialogueWithMap(input, prevMap);
    }
    if (pattern.isEmpty) return (input, prevMap);
    if (!isRegex) {
      final firstIdx = input.indexOf(pattern);
      if (firstIdx < 0) return (input, prevMap);
      if (pattern.length == replacement.length) {
        return (input.replaceAll(pattern, replacement), prevMap);
      }
      final edits = <(int, int, int)>[];
      final out = StringBuffer();
      var cursor = 0;
      var idx = firstIdx;
      while (idx >= 0) {
        out.write(input.substring(cursor, idx));
        out.write(replacement);
        edits.add((idx, idx + pattern.length, replacement.length));
        cursor = idx + pattern.length;
        idx = input.indexOf(pattern, cursor);
      }
      out.write(input.substring(cursor));
      final nextMap = _mapReplacementSegments(
        prevMap: prevMap ?? _identityMap(input.length),
        prevLength: input.length,
        edits: edits,
      );
      return (out.toString(), nextMap);
    }
    final regExp = _compile(pattern);
    if (regExp == null) return (input, prevMap);
    final sw = Stopwatch()..start();
    final edits = <(int, int, int)>[];
    final out = StringBuffer();
    var cursor = 0;
    for (final match in regExp.allMatches(input)) {
      out.write(input.substring(cursor, match.start));
      final rep = _expandRegexReplacement(match);
      out.write(rep);
      if (rep.length != match.end - match.start || prevMap != null) {
        edits.add((match.start, match.end, rep.length));
      }
      cursor = match.end;
    }
    sw.stop();
    if (sw.elapsedMicroseconds > 8000 && _trippedRuleIds.add(id)) {
      ReaderPurificationStore.shared._invalidateCaches();
    }
    if (cursor == 0 && edits.isEmpty) return (input, prevMap);
    out.write(input.substring(cursor));
    final result = out.toString();
    if (edits.isEmpty) return (result, prevMap);
    final nextMap = _mapReplacementSegments(
      prevMap: prevMap ?? _identityMap(input.length),
      prevLength: input.length,
      edits: edits,
    );
    return (result, nextMap);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'isRegex': isRegex,
    'enabled': enabled,
    'builtIn': builtIn,
    if (scopeBookId != null) 'scopeBookId': scopeBookId,
    if (scopeBookTitle != null && scopeBookTitle!.isNotEmpty)
      'scopeBookTitle': scopeBookTitle,
    if (applyToTitle) 'applyToTitle': true,
    'applyToContent': applyToContent,
    if (importScope.isNotEmpty) 'scope': importScope,
    if (excludeScope.isNotEmpty) 'excludeScope': excludeScope,
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
    if (unsupportedReason != null) 'unsupportedReason': unsupportedReason,
  };

  static ReaderPurificationRule? fromJson(
    Object? raw, {
    int? defaultBookId,
    String? defaultBookTitle,
    bool allowLegacyEnabledField = false,
  }) {
    if (raw is! Map) return null;
    final name = raw['name'] is String ? (raw['name'] as String).trim() : null;
    final pattern = raw['pattern'] is String ? raw['pattern'] as String : null;
    if (name == null || name.isEmpty || pattern == null || pattern.isEmpty) {
      return null;
    }
    final rawId = raw['id'];
    final id = (rawId is String && rawId.isNotEmpty)
        ? rawId
        : 'custom_${DateTime.now().microsecondsSinceEpoch}_${name.hashCode.abs()}';
    final scopeId =
        (raw['scopeBookId'] is num
            ? (raw['scopeBookId'] as num).toInt()
            : null) ??
        defaultBookId;
    final scopeTitle =
        (raw['scopeBookTitle'] is String
            ? raw['scopeBookTitle'] as String
            : null) ??
        (scopeId != null ? defaultBookTitle : null);
    final isRegex = raw['isRegex'] == true;
    final unsafeReason = isRegex ? detectUnsafeRegexPattern(pattern) : null;
    final rawUnsupported = raw['unsupportedReason'] is String
        ? raw['unsupportedReason'] as String
        : unsafeReason;
    final enabled =
        rawUnsupported == null &&
        (raw.containsKey('enabled')
            ? raw['enabled'] == true
            : (allowLegacyEnabledField && raw['isEnabled'] == true));
    final applyTitle = raw['applyToTitle'] == true || raw['scopeTitle'] == true;
    return ReaderPurificationRule(
      id: id,
      name: name,
      pattern: pattern,
      replacement: raw['replacement'] is String
          ? raw['replacement'] as String
          : '',
      isRegex: isRegex,
      enabled: enabled,
      builtIn: raw['builtIn'] == true,
      scopeBookId: scopeId,
      scopeBookTitle: scopeTitle,
      applyToTitle: applyTitle,
      applyToContent:
          raw['applyToContent'] != false && raw['scopeContent'] != false,
      importScope: raw['scope'] is String ? raw['scope'] as String : '',
      excludeScope: raw['excludeScope'] is String
          ? raw['excludeScope'] as String
          : '',
      sourceUrl: raw['sourceUrl'] is String ? raw['sourceUrl'] as String : null,
      unsupportedReason: rawUnsupported,
    );
  }
}

class ReaderPurificationStore extends ChangeNotifier {
  ReaderPurificationStore._();

  static final ReaderPurificationStore shared = ReaderPurificationStore._();
  static const String preferenceKey = 'reader_purification_rules_v1';
  static const String editsPreferenceKey = 'reader_paragraph_edits_v1';
  static const String enabledPreferenceKey = 'reader_purification_enabled_v1';

  static const List<ReaderPurificationRule> builtInPresets = [
    ReaderPurificationRule(
      id: 'builtin_ocr_ellipsis',
      name: '规范省略号（... → ……）',
      pattern: r'\.{3,}|…{3,}',
      replacement: '……',
      isRegex: true,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_ocr_dash',
      name: '规范破折号（-- / ——）',
      pattern: r'-{2,}|—{3,}',
      replacement: '——',
      isRegex: true,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_trailing_spaces',
      name: '清理段尾多余空格',
      pattern: r'[ \t\u3000]+$',
      replacement: '',
      isRegex: true,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_watermark_credit',
      name: '过滤常见扫图/转载免责声明行',
      pattern: r'^(?:.*(?:仅供个人学习交流|严禁用于商业用途|下载后请于24小时内删除).*)$',
      replacement: '',
      isRegex: true,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_smart_quotes',
      name: '智能修复直引号与弯引号配对（"" → “”）',
      pattern: '__smart_quotes__',
      replacement: '“…”',
      isRegex: false,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_dialogue_resegment',
      name: '粘连长段按对话与句群智能重分段',
      pattern: '__dialogue_resegment__',
      replacement: '分段',
      isRegex: false,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_dedup_chapter_title',
      name: '自动移除正文首段重复章节名',
      pattern: '__dedup_chapter_title__',
      replacement: '',
      isRegex: false,
      enabled: false,
      builtIn: true,
    ),
  ];

  List<ReaderPurificationRule> _rules = [...builtInPresets];
  List<ReaderPurificationRule>? _cachedEnabledRules;
  final Map<String, PurifiedParagraph> _paragraphCache =
      <String, PurifiedParagraph>{};
  final Map<String, List<ReaderPurificationRule>> _chapterEffectiveCache =
      <String, List<ReaderPurificationRule>>{};
  Map<String, String> _paragraphEdits = {};
  Future<void>? _ruleWriteQueue;
  bool _loaded = false;
  bool _enabled = true;
  bool get enabled => _enabled;

  void _invalidateCaches() {
    _cachedEnabledRules = null;
    _paragraphCache.clear();
    _chapterEffectiveCache.clear();
  }

  List<ReaderPurificationRule> get _enabledRules =>
      _cachedEnabledRules ??= _rules
          .where(
            (rule) =>
                rule.enabled &&
                rule.unsupportedReason == null &&
                !ReaderPurificationRule._trippedRuleIds.contains(rule.id),
          )
          .toList(growable: false);

  List<ReaderPurificationRule> get rules => List.unmodifiable(_rules);

  bool get hasEnabledRules => _enabled && _enabledRules.isNotEmpty;

  @visibleForTesting
  void resetForTesting() {
    _ruleWriteQueue = null;
    _rules = [...builtInPresets];
    _paragraphEdits = {};
    _loaded = false;
    _enabled = true;
    ReaderPurificationRule._trippedRuleIds.clear();
    _invalidateCaches();
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(enabledPreferenceKey) ?? true;
      final rawEdits = prefs.getString(editsPreferenceKey);
      if (rawEdits != null && rawEdits.isNotEmpty) {
        final decodedEdits = jsonDecode(rawEdits);
        if (decodedEdits is Map) {
          _paragraphEdits = {
            for (final entry in decodedEdits.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
          };
        }
      }
      final raw = prefs.getString(preferenceKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final parsed = <ReaderPurificationRule>[
        for (final item in decoded) ?ReaderPurificationRule.fromJson(item),
      ];
      final byId = {for (final r in parsed) r.id: r};
      final merged = <ReaderPurificationRule>[
        for (final preset in builtInPresets)
          preset.copyWith(enabled: byId[preset.id]?.enabled ?? preset.enabled),
        for (final custom in parsed)
          if (!custom.builtIn &&
              !builtInPresets.any((preset) => preset.id == custom.id))
            custom,
      ];
      _rules = merged;
      _invalidateCaches();
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('ReaderPurificationStore.ensureLoaded failed: $e');
    }
  }

  // Serialize rule edits so a checked import write cannot overwrite an edit
  // made while its platform write is in flight. A failed edit must not block
  // subsequent edits or retries.
  Future<T> _withRuleEdits<T>(Future<T> Function() action) {
    final previous = _ruleWriteQueue;
    final result = previous == null ? action() : previous.then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _ruleWriteQueue = tail;
    unawaited(
      tail.then((_) {
        if (identical(_ruleWriteQueue, tail)) _ruleWriteQueue = null;
      }),
    );
    return result;
  }

  // Imports and explicit batch activation report success only after storage
  // accepts the new rules. Neither path changes the master switch.
  Future<void> _commitImportedRules(List<ReaderPurificationRule> next) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = await prefs.setString(
        preferenceKey,
        jsonEncode([for (final rule in next) rule.toJson()]),
      );
      if (!saved) throw const ReaderPurificationSaveException();
    } catch (_) {
      // Legacy SharedPreferences updates its cache before the platform write.
      // Discard that optimistic cache after a rejected/failed write.
      try {
        await prefs.reload();
      } catch (_) {
        // Preserve the original save failure for the UI.
      }
      throw const ReaderPurificationSaveException();
    }
    _rules = next;
    _invalidateCaches();
    notifyListeners();
  }

  bool _canEnableImportedRule(ReaderPurificationRule rule) =>
      !rule.builtIn &&
      rule.unsupportedReason == null &&
      !rule.replacement.trimLeft().startsWith('@js:') &&
      !ReaderPurificationRule._trippedRuleIds.contains(rule.id) &&
      (!rule.isRegex || ReaderPurificationRule._compile(rule.pattern) != null);

  /// Only IDs returned by the current import are supplied by the confirmation
  /// UI. Never use source URL or enableAllCustomRules for this operation.
  Future<int> enableImportedRules(Iterable<String> ruleIds) {
    final ids = ruleIds.toSet();
    return _withRuleEdits(() async {
      await ensureLoaded();
      var changed = 0;
      final next = _rules.map((rule) {
        if (ids.contains(rule.id) &&
            !rule.enabled &&
            _canEnableImportedRule(rule)) {
          changed++;
          return rule.copyWith(enabled: true);
        }
        return rule;
      }).toList();
      if (changed > 0) await _commitImportedRules(next);
      return changed;
    });
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode([for (final r in _rules) r.toJson()]);
      await prefs.setString(preferenceKey, encoded);
      await prefs.setBool(enabledPreferenceKey, _enabled);
    } catch (e) {
      if (kDebugMode) debugPrint('ReaderPurificationStore._persist failed: $e');
    }
  }

  Future<void> _persistEdits() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_paragraphEdits.isEmpty) {
        await prefs.remove(editsPreferenceKey);
      } else {
        await prefs.setString(editsPreferenceKey, jsonEncode(_paragraphEdits));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('ReaderPurificationStore._persistEdits failed: $e');
    }
  }

  Map<String, Object> exportBackupRecords() => {
    preferenceKey: jsonEncode([for (final rule in _rules) rule.toJson()]),
    enabledPreferenceKey: _enabled,
    if (_paragraphEdits.isNotEmpty)
      editsPreferenceKey: jsonEncode(_paragraphEdits),
  };

  ({
    Map<String, Object> changed,
    List<ReaderPurificationRule> rules,
    Map<String, String> edits,
    bool enabled,
  })
  prepareMergedBackupRecords(
    Map<String, Object> records, {
    required int? Function(int rawId) mapBookId,
    bool importPreferences = false,
  }) {
    var nextEnabled = _enabled;
    if (importPreferences &&
        records[enabledPreferenceKey] is bool) {
      nextEnabled = records[enabledPreferenceKey] as bool;
    }

    var nextRules = [..._rules];
    if (records[preferenceKey] case final String rawRules) {
      final decoded = jsonDecode(rawRules);
      if (decoded is List) {
        final incomingParsed = <ReaderPurificationRule>[];
        for (final item in decoded) {
          final parsed = ReaderPurificationRule.fromJson(item);
          if (parsed == null) continue;
          if (parsed.scopeBookId != null) {
            final mappedId = mapBookId(parsed.scopeBookId!);
            if (mappedId == null) continue;
            incomingParsed.add(parsed.copyWith(scopeBookId: mappedId));
          } else {
            incomingParsed.add(parsed);
          }
        }
        final incomingById = {for (final r in incomingParsed) r.id: r};
        final builtInIds = {for (final p in builtInPresets) p.id};
        final mergedPresets = <ReaderPurificationRule>[
          for (final preset in builtInPresets)
            preset.copyWith(
              enabled:
                  (_rules
                          .where((r) => r.id == preset.id)
                          .firstOrNull
                          ?.enabled ??
                      preset.enabled) ||
                  (incomingById[preset.id]?.enabled ?? false),
            ),
        ];
        final mergedCustom = <ReaderPurificationRule>[
          for (final existing in _rules)
            if (!existing.builtIn && !builtInIds.contains(existing.id))
              existing,
        ];
        final seenIds = {for (final r in mergedCustom) r.id};
        final seenSignatures = {for (final r in mergedCustom) r.signature};
        for (final custom in incomingParsed) {
          if (custom.builtIn || builtInIds.contains(custom.id)) continue;
          if (seenSignatures.contains(custom.signature)) continue;
          var candidate = custom;
          if (!seenIds.add(candidate.id)) {
            var suffix = 1;
            var nextId = '${candidate.id}_import_$suffix';
            while (!seenIds.add(nextId)) {
              suffix++;
              nextId = '${candidate.id}_import_$suffix';
            }
            candidate = ReaderPurificationRule(
              id: nextId,
              name: candidate.name,
              pattern: candidate.pattern,
              replacement: candidate.replacement,
              isRegex: candidate.isRegex,
              enabled: candidate.enabled,
              scopeBookId: candidate.scopeBookId,
              scopeBookTitle: candidate.scopeBookTitle,
              applyToTitle: candidate.applyToTitle,
              applyToContent: candidate.applyToContent,
              importScope: candidate.importScope,
              excludeScope: candidate.excludeScope,
              sourceUrl: candidate.sourceUrl,
              unsupportedReason: candidate.unsupportedReason,
            );
          }
          seenSignatures.add(candidate.signature);
          mergedCustom.add(candidate);
        }
        nextRules = [...mergedPresets, ...mergedCustom];
      }
    }

    final nextEdits = {..._paragraphEdits};
    if (records[editsPreferenceKey] case final String rawEdits) {
      final decoded = jsonDecode(rawEdits);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final k = entry.key;
          final v = entry.value;
          if (k is! String || v is! String) continue;
          final parts = k.split(':');
          if (parts.length != 3) continue;
          final rawBookId = int.tryParse(parts[0]);
          if (rawBookId == null) continue;
          final mappedBookId = mapBookId(rawBookId);
          if (mappedBookId == null) continue;
          final remappedKey = '$mappedBookId:${parts[1]}:${parts[2]}';
          nextEdits.putIfAbsent(remappedKey, () => v);
        }
      }
    }

    final changed = <String, Object>{
      if (records.containsKey(preferenceKey))
        preferenceKey: jsonEncode([for (final r in nextRules) r.toJson()]),
      if (importPreferences && records.containsKey(enabledPreferenceKey))
        enabledPreferenceKey: nextEnabled,
      if (records.containsKey(editsPreferenceKey) && nextEdits.isNotEmpty)
        editsPreferenceKey: jsonEncode(nextEdits),
    };
    return (
      changed: changed,
      rules: nextRules,
      edits: nextEdits,
      enabled: nextEnabled,
    );
  }

  void applyMergedBackupRecords({
    required List<ReaderPurificationRule> rules,
    required Map<String, String> edits,
    required bool enabled,
  }) {
    _loaded = true;
    _rules = rules;
    _paragraphEdits = edits;
    _enabled = enabled;
    _invalidateCaches();
    notifyListeners();
  }

  static String _editKey(int bookId, int chapterIndex, int paragraphIndex) =>
      '$bookId:$chapterIndex:$paragraphIndex';

  String? paragraphEditFor(int bookId, int chapterIndex, int paragraphIndex) =>
      _paragraphEdits[_editKey(bookId, chapterIndex, paragraphIndex)];

  Future<void> setParagraphEdit({
    required int bookId,
    required int chapterIndex,
    required int paragraphIndex,
    required String editedText,
  }) async {
    await ensureLoaded();
    final key = _editKey(bookId, chapterIndex, paragraphIndex);
    _paragraphEdits = {..._paragraphEdits, key: editedText};
    _invalidateCaches();
    notifyListeners();
    await _persistEdits();
  }

  Future<void> clearParagraphEdit({
    required int bookId,
    required int chapterIndex,
    required int paragraphIndex,
  }) async {
    await ensureLoaded();
    final key = _editKey(bookId, chapterIndex, paragraphIndex);
    if (!_paragraphEdits.containsKey(key)) return;
    final next = Map<String, String>.of(_paragraphEdits)..remove(key);
    _paragraphEdits = next;
    _invalidateCaches();
    notifyListeners();
    await _persistEdits();
  }

  Future<void> setEnabled(bool value) => _withRuleEdits(() async {
    await ensureLoaded();
    _enabled = value;
    _invalidateCaches();
    notifyListeners();
    await _persist();
  });

  Future<void> removeSource(String sourceUrl) => _withRuleEdits(() async {
    await ensureLoaded();
    _rules = _rules
        .where((r) => r.builtIn || r.sourceUrl != sourceUrl)
        .toList();
    _invalidateCaches();
    notifyListeners();
    await _persist();
  });

  Future<void> toggleRule(String id, bool enabled) => _withRuleEdits(() async {
    await ensureLoaded();
    _rules = [
      for (final rule in _rules)
        if (rule.id == id && rule.unsupportedReason == null)
          rule.copyWith(enabled: enabled)
        else
          rule,
    ];
    _invalidateCaches();
    notifyListeners();
    await _persist();
  });

  Future<void> enableAllCustomRules([bool enabled = true]) =>
      _withRuleEdits(() async {
        await ensureLoaded();
        _rules = [
          for (final rule in _rules)
            if (!rule.builtIn && rule.unsupportedReason == null)
              rule.copyWith(enabled: enabled)
            else
              rule,
        ];
        _invalidateCaches();
        notifyListeners();
        await _persist();
      });

  Future<void> addCustomRule({
    required String name,
    required String pattern,
    required String replacement,
    required bool isRegex,
    int? scopeBookId,
    String? scopeBookTitle,
    bool applyToTitle = false,
  }) => _withRuleEdits(() async {
    await ensureLoaded();
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || pattern.isEmpty) return;
    final unsafeReason = isRegex
        ? ReaderPurificationRule.detectUnsafeRegexPattern(pattern)
        : null;
    final id = 'custom_${DateTime.now().microsecondsSinceEpoch}';
    _rules = [
      ..._rules,
      ReaderPurificationRule(
        id: id,
        name: trimmedName,
        pattern: pattern,
        replacement: replacement,
        isRegex: isRegex,
        enabled: unsafeReason == null,
        scopeBookId: scopeBookId,
        scopeBookTitle: scopeBookTitle,
        applyToTitle: applyToTitle,
        unsupportedReason: unsafeReason,
      ),
    ];
    _invalidateCaches();
    notifyListeners();
    await _persist();
  });

  Future<void> removeRule(String id) => _withRuleEdits(() async {
    await ensureLoaded();
    _rules = [
      for (final rule in _rules)
        if (rule.id != id || rule.builtIn) rule,
    ];
    _invalidateCaches();
    notifyListeners();
    await _persist();
  });

  /// Exports custom rules as a shareable token (`shuyu://purification?data=...`)
  /// or JSON array compatible with Legado's `replaceRule`.
  String exportRulesShareToken({int? bookId}) {
    final exported = [
      for (final rule in _rules)
        if (!rule.builtIn && (bookId == null || rule.appliesToBook(bookId)))
          rule.toJson(),
    ];
    final jsonStr = jsonEncode(exported);
    final encoded = base64Url.encode(utf8.encode(jsonStr));
    return 'shuyu://purification?data=$encoded';
  }

  /// Accepts a remote HTTPS JSON URL, share token, or pasted JSON.
  /// External imports default to disabled (`enableImported = false`) so
  /// untrusted or expensive rules never auto-run before user confirmation.
  Future<ReaderPurificationImportResult> importRulesFromInput(
    String input, {
    int? defaultBookId,
    String? defaultBookTitle,
    bool enableImported = false,
    bool allowHttp = false,
  }) async {
    final text = input.trim();
    final uri = Uri.tryParse(text);
    final isUrl =
        uri != null &&
        uri.hasScheme &&
        !uri.isScheme('shuyu') &&
        !text.startsWith('[') &&
        !text.startsWith('{');
    final validatedUri = isUrl
        ? ReaderPurificationDownload.parseUrl(text, allowHttp: allowHttp)
        : null;
    final payload = isUrl
        ? await ReaderPurificationDownload.fetch(text, allowHttp: allowHttp)
        : text;
    return _importPayload(
      payload,
      sourceUrl: validatedUri?.toString(),
      defaultBookId: defaultBookId,
      defaultBookTitle: defaultBookTitle,
      enableImported: enableImported,
    );
  }

  Future<int> importRulesFromText(
    String text, {
    int? defaultBookId,
    String? defaultBookTitle,
    bool enableImported = false,
  }) async => (await _importPayload(
    text,
    defaultBookId: defaultBookId,
    defaultBookTitle: defaultBookTitle,
    enableImported: enableImported,
  )).imported;

  Future<ReaderPurificationImportResult> _importPayload(
    String rawText, {
    String? sourceUrl,
    int? defaultBookId,
    String? defaultBookTitle,
    bool enableImported = false,
  }) => _withRuleEdits(() async {
    await ensureLoaded();
    var payload = rawText.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
    final tokenMatch = RegExp(
      r'shuyu://purification\?data=([A-Za-z0-9_\-=]+)',
    ).firstMatch(payload);
    if (tokenMatch != null) {
      payload = utf8.decode(
        base64Url.decode(base64Url.normalize(tokenMatch.group(1)!)),
      );
    }
    final decoded = jsonDecode(payload);
    if (decoded is! List && decoded is! Map) {
      throw const FormatException('规则文件必须是 JSON 数组或规则对象');
    }
    final items = decoded is List ? decoded : [decoded];
    if (items.length > 5000) throw const FormatException('单次最多导入 5000 条规则');
    // Preserve Legado's explicit order; keep input order for ties/missing values.
    final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
    int order(Object? item) => item is Map && item['order'] is num
        ? (item['order'] as num).toInt()
        : 0;
    indexed.sort((a, b) {
      final result = order(a.$2).compareTo(order(b.$2));
      return result == 0 ? a.$1.compareTo(b.$1) : result;
    });
    final signatures = {for (final rule in _rules) rule.signature};
    final added = <ReaderPurificationRule>[];
    var duplicates = 0;
    var invalid = 0;
    var disabled = 0;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (final entry in indexed) {
      final parsed = ReaderPurificationRule.fromJson(
        entry.$2,
        defaultBookId: defaultBookId,
        defaultBookTitle: defaultBookTitle,
        allowLegacyEnabledField: enableImported,
      );
      if (parsed == null || parsed.builtIn) {
        invalid++;
        continue;
      }
      if (!signatures.add(parsed.signature)) {
        duplicates++;
        continue;
      }
      final reason =
          parsed.unsupportedReason ??
          (parsed.replacement.trimLeft().startsWith('@js:')
              ? '暂不支持 JavaScript 替换脚本'
              : parsed.isRegex &&
                    ReaderPurificationRule._compile(parsed.pattern) == null
              ? '正则表达式暂不兼容或存在风险'
              : null);
      if (reason != null) disabled++;
      added.add(
        ReaderPurificationRule(
          id: 'custom_${stamp}_${added.length}',
          name: parsed.name,
          pattern: parsed.pattern,
          replacement: parsed.replacement,
          isRegex: parsed.isRegex,
          enabled: enableImported && reason == null && parsed.enabled,
          scopeBookId: parsed.scopeBookId,
          scopeBookTitle: parsed.scopeBookTitle,
          applyToTitle: parsed.applyToTitle,
          applyToContent: parsed.applyToContent,
          importScope: parsed.importScope,
          excludeScope: parsed.excludeScope,
          sourceUrl: sourceUrl ?? parsed.sourceUrl,
          unsupportedReason: reason,
        ),
      );
    }
    if (added.isNotEmpty) {
      await _commitImportedRules([..._rules, ...added]);
    }
    return ReaderPurificationImportResult(
      imported: added.length,
      disabled: disabled,
      duplicates: duplicates,
      invalid: invalid,
      enabledCount: added.where((rule) => rule.enabled).length,
      importedRuleIds: added.map((rule) => rule.id),
      enableableRuleIds: added
          .where(_canEnableImportedRule)
          .map((rule) => rule.id),
    );
  });

  /// Returns the enabled rules that actually match the given chapter content
  /// or chapter title, allowing the reader to inspect and toggle active rules.
  List<ReaderPurificationRule> effectiveRulesForChapter(
    Iterable<String> paragraphs, {
    int? bookId,
    String? bookTitle,
    String? chapterTitle,
  }) {
    if (!_enabled) return const [];
    final enabledRules = _enabledRules;
    if (enabledRules.isEmpty) return const [];
    final paragraphList = paragraphs.toList(growable: false);
    final cacheKey =
        '${bookId ?? ''}\x00${bookTitle ?? ''}\x00${chapterTitle ?? ''}\x00'
        '${paragraphList.length}\x00'
        '${paragraphList.isEmpty ? 0 : Object.hashAll(paragraphList)}';
    final cached = _chapterEffectiveCache[cacheKey];
    if (cached != null) return cached;

    final active = <ReaderPurificationRule>[];
    for (final rule in enabledRules) {
      if (!rule.appliesToBook(bookId, bookTitle: bookTitle)) {
        continue;
      }
      if (rule.id == 'builtin_dedup_chapter_title') {
        if (paragraphList.isNotEmpty &&
            dedupLeadingChapterTitle(paragraphList.first, chapterTitle) !=
                paragraphList.first) {
          active.add(rule);
        }
        continue;
      }
      if (rule.applyToTitle &&
          chapterTitle != null &&
          rule.matches(chapterTitle)) {
        active.add(rule);
        continue;
      }
      if (!rule.applyToContent) continue;
      for (final p in paragraphList) {
        if (rule.matches(p)) {
          active.add(rule);
          break;
        }
      }
    }
    final unmodifiable = List<ReaderPurificationRule>.unmodifiable(active);
    if (_chapterEffectiveCache.length >= 64) {
      _chapterEffectiveCache.remove(_chapterEffectiveCache.keys.first);
    }
    _chapterEffectiveCache[cacheKey] = unmodifiable;
    return unmodifiable;
  }

  bool hasChapterEdits(int bookId, int chapterIndex) {
    if (_paragraphEdits.isEmpty) return false;
    final prefix = '$bookId:$chapterIndex:';
    return _paragraphEdits.keys.any((key) => key.startsWith(prefix));
  }

  String purifyTitle(
    String title, {
    int? bookId,
    String? bookTitle,
  }) {
    if (!hasEnabledRules || title.isEmpty) return title;
    var current = title;
    for (final rule in _enabledRules) {
      if (!rule.applyToTitle) continue;
      if (!rule.appliesToBook(bookId, bookTitle: bookTitle)) continue;
      if (rule.id == 'builtin_dedup_chapter_title') continue;
      current = rule.apply(current);
    }
    return current;
  }

  PurifiedParagraph purifyParagraphWithMap(
    String text, {
    int? bookId,
    String? bookTitle,
    int? chapterIndex,
    int? paragraphIndex,
    String? chapterTitle,
    bool isFirstParagraph = false,
  }) {
    if (bookId != null && chapterIndex != null && paragraphIndex != null) {
      final edited = paragraphEditFor(bookId, chapterIndex, paragraphIndex);
      if (edited != null) {
        return edited == text
            ? PurifiedParagraph(text)
            : PurifiedParagraph(
                edited,
                rawLength: text.length,
                toRaw: _mapManualEdit(text, edited),
              );
      }
    }
    if (!hasEnabledRules || text.isEmpty) return PurifiedParagraph(text);
    final trimmed = text.trim();
    if (trimmed == '[插图]' ||
        trimmed.startsWith('<!--image-->') ||
        trimmed.startsWith('http://') ||
        trimmed.startsWith('https://')) {
      return PurifiedParagraph(text);
    }
    final cacheKey =
        '${bookId ?? ''}\x00${bookTitle ?? ''}\x00'
        '${isFirstParagraph ? (chapterTitle ?? '') : ''}\x00'
        '${text.length}\x00$text';
    final cached = _paragraphCache[cacheKey];
    if (cached != null) return cached;

    var current = text;
    List<int>? map;
    for (final rule in _enabledRules) {
      if (!rule.appliesToBook(bookId, bookTitle: bookTitle)) {
        continue;
      }
      if (rule.id == 'builtin_dedup_chapter_title') {
        if (isFirstParagraph && chapterTitle != null) {
          final (next, nextMap) = _dedupLeadingChapterTitleWithMap(
            current,
            chapterTitle,
            map,
          );
          current = next;
          map = nextMap;
        }
        continue;
      }
      if (rule.applyToContent) {
        final (next, nextMap) = rule.applyWithMap(current, map);
        current = next;
        map = nextMap;
      }
    }
    final result = map == null && current == text
        ? PurifiedParagraph(text)
        : PurifiedParagraph(current, rawLength: text.length, toRaw: map);
    if (_paragraphCache.length >= 2048) {
      _paragraphCache.remove(_paragraphCache.keys.first);
    }
    _paragraphCache[cacheKey] = result;
    return result;
  }

  String purifyParagraph(
    String text, {
    int? bookId,
    String? bookTitle,
    int? chapterIndex,
    int? paragraphIndex,
    String? chapterTitle,
    bool isFirstParagraph = false,
  }) => purifyParagraphWithMap(
    text,
    bookId: bookId,
    bookTitle: bookTitle,
    chapterIndex: chapterIndex,
    paragraphIndex: paragraphIndex,
    chapterTitle: chapterTitle,
    isFirstParagraph: isFirstParagraph,
  ).text;

  List<ReaderAnnotationRange> mapAnnotationsToPurified(
    Iterable<ReaderAnnotationRange> annotations, {
    required PurifiedParagraph Function(int paragraphIndex) resolveParagraph,
  }) {
    final mapped = <ReaderAnnotationRange>[];
    for (final item in annotations) {
      final r = item.range;
      if (r.startParagraph == r.endParagraph) {
        final p = resolveParagraph(r.startParagraph);
        if (p.isIdentity) {
          mapped.add(item);
          continue;
        }
        final projected = p.purifiedRangeFor(r.startOffset, r.endOffset);
        if (projected == null) continue;
        final nextRange = ReaderUnderlineRange(
          chapterId: r.chapterId,
          startParagraph: r.startParagraph,
          startOffset: projected.$1,
          endParagraph: r.endParagraph,
          endOffset: projected.$2,
          contentRevision: r.contentRevision,
        );
        if (nextRange.isValid) {
          mapped.add(
            ReaderAnnotationRange(
              nextRange,
              item.style,
              item.color,
              bookmarkId: item.bookmarkId,
            ),
          );
        }
      } else {
        final startP = resolveParagraph(r.startParagraph);
        final endP = resolveParagraph(r.endParagraph);
        if (startP.isIdentity && endP.isIdentity) {
          mapped.add(item);
          continue;
        }
        final projStart = startP.purifiedRangeFor(
          r.startOffset,
          startP.sourceLength,
        );
        final projEnd = endP.purifiedRangeFor(0, r.endOffset);
        var sPara = r.startParagraph;
        var sOff = projStart?.$1 ?? startP.text.length;
        var ePara = r.endParagraph;
        var eOff = projEnd?.$2 ?? 0;
        if (projStart == null && sPara < ePara) {
          sPara++;
          sOff = 0;
        }
        if (projEnd == null && ePara > sPara) {
          ePara--;
          eOff = resolveParagraph(ePara).text.length;
        }
        final nextRange = ReaderUnderlineRange(
          chapterId: r.chapterId,
          startParagraph: sPara,
          startOffset: sOff,
          endParagraph: ePara,
          endOffset: eOff,
          contentRevision: r.contentRevision,
        );
        if (nextRange.isValid) {
          mapped.add(
            ReaderAnnotationRange(
              nextRange,
              item.style,
              item.color,
              bookmarkId: item.bookmarkId,
            ),
          );
        }
      }
    }
    return mapped;
  }
}

Future<void> showReaderPurificationSheet({
  required BuildContext context,
  bool reduceMotion = false,
  int? bookId,
  String? bookTitle,
  int? chapterIndex,
  String? chapterTitle,
  List<String>? chapterParagraphs,
  int? initialParagraphIndex,
  String? initialPattern,
}) async {
  await ReaderPurificationStore.shared.ensureLoaded();
  if (!context.mounted) return;
  await showJellySheet<void>(
    context: context,
    reduceMotion: reduceMotion,
    builder: (sheetContext) => _ReaderPurificationSheet(
      reduceMotion: reduceMotion,
      bookId: bookId,
      bookTitle: bookTitle,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      chapterParagraphs: chapterParagraphs,
      initialParagraphIndex: initialParagraphIndex,
      initialPattern: initialPattern,
    ),
  );
}

class _ReaderPurificationSheet extends StatefulWidget {
  const _ReaderPurificationSheet({
    required this.reduceMotion,
    this.bookId,
    this.bookTitle,
    this.chapterIndex,
    this.chapterTitle,
    this.chapterParagraphs,
    this.initialParagraphIndex,
    this.initialPattern,
  });

  final bool reduceMotion;
  final int? bookId;
  final String? bookTitle;
  final int? chapterIndex;
  final String? chapterTitle;
  final List<String>? chapterParagraphs;
  final int? initialParagraphIndex;
  final String? initialPattern;

  @override
  State<_ReaderPurificationSheet> createState() =>
      _ReaderPurificationSheetState();
}

enum _PurificationRuleFilter { all, effective, enabled, builtIn, custom }

class _ReaderPurificationSheetState extends State<_ReaderPurificationSheet> {
  final _nameCtrl = TextEditingController();
  final _patternCtrl = TextEditingController();
  final _replacementCtrl = TextEditingController();
  final _editParagraphCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  bool _showUrlImport = false;
  bool _allowHttpUrl = false;
  bool _importing = false;
  String? _importError;
  bool _isRegex = false;
  bool _onlyCurrentBook = false;
  bool _applyToTitle = false;
  bool _adding = false;
  _PurificationRuleFilter _filter = _PurificationRuleFilter.all;
  bool _editingParagraph = false;
  int _selectedParagraphIndex = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPattern?.trim() ?? '';
    if (initial.isNotEmpty) {
      _adding = true;
      _patternCtrl.text = initial;
      final preview = initial.length > 10
          ? '${initial.substring(0, 10)}…'
          : initial;
      _nameCtrl.text = '替换「$preview」';
      _onlyCurrentBook = widget.bookId != null;
    }
    final paragraphs = widget.chapterParagraphs;
    if (paragraphs != null && paragraphs.isNotEmpty) {
      _selectedParagraphIndex = (widget.initialParagraphIndex ?? 0).clamp(
        0,
        paragraphs.length - 1,
      );
      _syncParagraphEditorText();
    }
  }

  void _syncParagraphEditorText() {
    final paragraphs = widget.chapterParagraphs;
    if (paragraphs == null || paragraphs.isEmpty) return;
    final idx = _selectedParagraphIndex.clamp(0, paragraphs.length - 1);
    final bookId = widget.bookId;
    final chapterIndex = widget.chapterIndex;
    final override = (bookId != null && chapterIndex != null)
        ? ReaderPurificationStore.shared.paragraphEditFor(
            bookId,
            chapterIndex,
            idx,
          )
        : null;
    _editParagraphCtrl.text = override ?? paragraphs[idx];
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _replacementCtrl.dispose();
    _editParagraphCtrl.dispose();
    _urlCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitCustomRule() async {
    final name = _nameCtrl.text.trim();
    final pattern = _patternCtrl.text;
    final replacement = _replacementCtrl.text;
    if (name.isEmpty || pattern.isEmpty) {
      setState(() => _error = '请填写规则名称与匹配内容');
      return;
    }
    if (_isRegex) {
      final unsafeReason = ReaderPurificationRule.detectUnsafeRegexPattern(
        pattern,
      );
      if (unsafeReason != null) {
        setState(() => _error = unsafeReason);
        return;
      }
      if (ReaderPurificationRule._compile(pattern) == null) {
        setState(() => _error = '正则表达式语法有误或不兼容');
        return;
      }
    }
    await ReaderPurificationStore.shared.addCustomRule(
      name: name,
      pattern: pattern,
      replacement: replacement,
      isRegex: _isRegex,
      scopeBookId: _onlyCurrentBook ? widget.bookId : null,
      scopeBookTitle: _onlyCurrentBook ? widget.bookTitle : null,
      applyToTitle: _applyToTitle,
    );
    if (!mounted) return;
    setState(() {
      _nameCtrl.clear();
      _patternCtrl.clear();
      _replacementCtrl.clear();
      _isRegex = false;
      _applyToTitle = false;
      _adding = false;
      _error = null;
    });
  }

  Future<void> _saveParagraphEdit() async {
    final bookId = widget.bookId;
    final chapterIndex = widget.chapterIndex;
    final paragraphs = widget.chapterParagraphs;
    if (bookId == null ||
        chapterIndex == null ||
        paragraphs == null ||
        paragraphs.isEmpty) {
      return;
    }
    final idx = _selectedParagraphIndex.clamp(0, paragraphs.length - 1);
    final updated = _editParagraphCtrl.text;
    if (updated == paragraphs[idx]) {
      await ReaderPurificationStore.shared.clearParagraphEdit(
        bookId: bookId,
        chapterIndex: chapterIndex,
        paragraphIndex: idx,
      );
    } else {
      await ReaderPurificationStore.shared.setParagraphEdit(
        bookId: bookId,
        chapterIndex: chapterIndex,
        paragraphIndex: idx,
        editedText: updated,
      );
    }
    if (!mounted) return;
    showNovelFeedback(context, '已保存本段纠错修改');
  }

  Future<void> _exportRules() async {
    final token = ReaderPurificationStore.shared.exportRulesShareToken();
    await Clipboard.setData(ClipboardData(text: token));
    if (!mounted) return;
    showNovelFeedback(context, '已复制净化规则分享口令到剪贴板');
  }

  Future<void> _importRules() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      showNovelFeedback(context, '请先复制规则链接、分享口令或 JSON');
      return;
    }
    await _runImport(raw);
  }

  Future<void> _runImport(String input) async {
    if (_importing) return;
    setState(() {
      _importing = true;
      _importError = null;
    });
    try {
      final result = await ReaderPurificationStore.shared.importRulesFromInput(
        input,
        defaultBookId: _onlyCurrentBook ? widget.bookId : null,
        defaultBookTitle: _onlyCurrentBook ? widget.bookTitle : null,
        allowHttp: _allowHttpUrl,
      );
      if (!mounted) return;
      if (result.imported > 0) setState(() => _showUrlImport = false);
      final activated = result.enableableRuleIds.isEmpty
          ? null
          : await _confirmImportedRules(result, input);
      if (!mounted) return;
      showNovelFeedback(
        context,
        activated == null
            ? result.message
            : '已启用本次 $activated 条规则'
                  '${ReaderPurificationStore.shared.enabled ? "" : "；正文净化总开关关闭，暂不生效"}',
      );
    } catch (error) {
      if (!mounted) return;
      final message = switch (error) {
        ReaderPurificationSaveException() => '规则保存失败，请重试',
        TimeoutException() => '下载超时，请检查网络后重试',
        SocketException() => '无法连接规则链接，请检查网络或链接地址',
        HttpException() => error.message,
        FormatException() =>
          '规则无法导入：${error.message}。支持 JSON 规则链接、书屿口令和阅读 Legado JSON',
        _ => '导入失败，请检查链接和规则格式后重试',
      };
      setState(() {
        _importError = message;
        _showUrlImport = true;
      });
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<int?> _confirmImportedRules(
    ReaderPurificationImportResult result,
    String input,
  ) {
    final uri = Uri.tryParse(input.trim());
    final source =
        uri != null && (uri.isScheme('https') || uri.isScheme('http'))
        ? uri.host
        : '剪贴板 JSON／分享口令';
    var saving = false;
    String? saveError;
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) => PopScope(
          canPop: !saving,
          child: AlertDialog(
            key: const ValueKey('purification-import-confirm'),
            title: const Text('规则已保存，尚未启用'),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('来源：$source'),
                const SizedBox(height: 8),
                Text(result.message),
                const SizedBox(height: 12),
                Text(
                  '是否启用本次新增的全部 ${result.enableableRuleIds.length} 条兼容规则？请确认信任此来源。',
                ),
                if (!ReaderPurificationStore.shared.enabled) ...[
                  const SizedBox(height: 8),
                  const Text('正文净化总开关关闭，启用规则后仍需手动打开总开关。'),
                ],
                if (saveError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    saveError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                key: const ValueKey('purification-import-save-only'),
                onPressed: saving
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('仅保存'),
              ),
              TextButton(
                key: const ValueKey('purification-import-enable-batch'),
                onPressed: saving
                    ? null
                    : () async {
                        if (saving) return;
                        updateDialog(() {
                          saving = true;
                          saveError = null;
                        });
                        try {
                          final count = await ReaderPurificationStore.shared
                              .enableImportedRules(result.enableableRuleIds);
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop(count);
                          }
                        } catch (_) {
                          if (!dialogContext.mounted) return;
                          updateDialog(() {
                            saving = false;
                            saveError = '启用保存失败，规则仍未启用，请重试';
                          });
                        }
                      },
                child: Text(
                  saving
                      ? '正在保存…'
                      : '启用本次 ${result.enableableRuleIds.length} 条',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submitUrlField() {
    try {
      ReaderPurificationDownload.parseUrl(
        _urlCtrl.text,
        allowHttp: _allowHttpUrl,
      );
    } on FormatException catch (error) {
      setState(() => _importError = error.message);
      return;
    }
    _runImport(_urlCtrl.text);
  }

  String _ruleSubtitle(ReaderPurificationRule rule) {
    if (rule.builtIn && rule.pattern.startsWith('__')) {
      return switch (rule.id) {
        'builtin_smart_quotes' => '根据标点与对话语境，自动配对直引号与弯引号',
        'builtin_dialogue_resegment' => '粘连长段落在对话引号与句群边界处智能分段',
        'builtin_dedup_chapter_title' => '当正文首段重复章节名时自动剔除冗余标题',
        _ => '内置智能排版算法（阅读渲染时实时处理）',
      };
    }
    final target = rule.replacement.isEmpty ? '（删除）' : rule.replacement;
    return '${rule.pattern}  →  $target';
  }

  Widget _buildQuickAction({
    Key? buttonKey,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool selected = false,
  }) {
    return Expanded(
      child: GlassTextButton(
        key: buttonKey,
        compact: true,
        selected: selected ? true : null,
        onPressed: onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip({
    Key? chipKey,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: dark ? .24 : .12)
          : scheme.onSurface.withValues(alpha: dark ? .07 : .05),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        key: chipKey,
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRuleBadge(
    BuildContext context,
    String text, {
    bool highlight = false,
    bool warning = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = warning
        ? scheme.error
        : highlight
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final bg = warning
        ? scheme.error.withValues(alpha: .12)
        : highlight
        ? scheme.primary.withValues(alpha: .14)
        : scheme.onSurface.withValues(alpha: .07);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 110),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSourceChip({
    required String source,
    required int count,
    required VoidCallback? onDelete,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final host = Uri.tryParse(source)?.host;
    final displayHost = (host != null && host.isNotEmpty) ? host : source;
    return Tooltip(
      message: source,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: dark ? .15 : .08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: scheme.primary.withValues(alpha: dark ? .28 : .18),
            width: 0.7,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ArchiveIcon(CupertinoIcons.globe, size: 13, color: scheme.primary),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 210),
                child: Text(
                  '$displayHost · $count 条',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: onDelete,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: ArchiveIcon(CupertinoIcons.xmark_circle_fill,
                    size: 15,
                    color: scheme.onSurfaceVariant.withValues(
                      alpha: onDelete == null ? .38 : .75,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactSwitchRow({
    required String label,
    Key? switchKey,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Switch.adaptive(
            key: switchKey,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = ReaderPurificationStore.shared;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final hasChapter = widget.chapterParagraphs != null;
        final effectiveRules = hasChapter
            ? store.effectiveRulesForChapter(
                widget.chapterParagraphs!,
                bookId: widget.bookId,
                bookTitle: widget.bookTitle,
                chapterTitle: widget.chapterTitle,
              )
            : const <ReaderPurificationRule>[];
        final effectiveIds = {for (final r in effectiveRules) r.id};
        final allRules = store.rules;
        final enabledCount = allRules
            .where((r) => r.enabled && r.unsupportedReason == null)
            .length;
        final builtInCount = allRules.where((r) => r.builtIn).length;
        final customCount = allRules.length - builtInCount;

        final sourceCounts = <String, int>{};
        for (final rule in allRules) {
          final src = rule.sourceUrl;
          if (src != null && src.isNotEmpty) {
            sourceCounts[src] = (sourceCounts[src] ?? 0) + 1;
          }
        }

        final activeFilter =
            (_filter == _PurificationRuleFilter.effective && !hasChapter) ||
                (_filter == _PurificationRuleFilter.custom && customCount == 0)
            ? _PurificationRuleFilter.all
            : _filter;

        final query = _searchCtrl.text.trim().toLowerCase();
        final rules = allRules.where((r) {
          final matchesFilter = switch (activeFilter) {
            _PurificationRuleFilter.all => true,
            _PurificationRuleFilter.effective => effectiveIds.contains(r.id),
            _PurificationRuleFilter.enabled => r.enabled,
            _PurificationRuleFilter.builtIn => r.builtIn,
            _PurificationRuleFilter.custom => !r.builtIn,
          };
          if (!matchesFilter) return false;
          if (query.isEmpty) return true;
          return r.name.toLowerCase().contains(query) ||
              r.pattern.toLowerCase().contains(query) ||
              r.replacement.toLowerCase().contains(query);
        }).toList();

        final canEditChapter =
            widget.bookId != null &&
            widget.chapterIndex != null &&
            widget.chapterParagraphs != null &&
            widget.chapterParagraphs!.isNotEmpty;

        final anyPanelOpen = _showUrlImport || _adding || _editingParagraph;
        final listMaxHeight = anyPanelOpen
            ? 240.0
            : (MediaQuery.sizeOf(context).height * 0.44).clamp(260.0, 420.0);

        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            14,
            20,
            MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 1. Header + Master Switch ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '正文替换与净化规则',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            store.enabled
                                ? '已启用 $enabledCount / ${allRules.length} 条 · 仅优化阅读显示，保留原文件'
                                : '净化规则已暂停 · 原始文本与文件不受影响',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Switch.adaptive(
                      key: const ValueKey('purification-master-switch'),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      value: store.enabled,
                      onChanged: store.setEnabled,
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // ── 2. Unified Action Toolbar ──
                Row(
                  children: [
                    _buildQuickAction(
                      buttonKey: const ValueKey('purification-toggle-add'),
                      icon: _adding
                          ? CupertinoIcons.chevron_up_circle
                          : CupertinoIcons.plus_circle,
                      label: _adding ? '收起新建' : '新增规则',
                      selected: _adding,
                      onPressed: () => setState(() {
                        _adding = !_adding;
                        if (_adding) {
                          _editingParagraph = false;
                          _showUrlImport = false;
                        }
                        _error = null;
                      }),
                    ),
                    const SizedBox(width: 8),
                    _buildQuickAction(
                      buttonKey: const ValueKey('purification-import-url'),
                      icon: CupertinoIcons.link,
                      label: _importing ? '正在导入…' : '链接导入',
                      selected: _showUrlImport,
                      onPressed: _importing
                          ? null
                          : () => setState(() {
                              _showUrlImport = !_showUrlImport;
                              if (_showUrlImport) {
                                _adding = false;
                                _editingParagraph = false;
                              }
                              _importError = null;
                            }),
                    ),
                    const SizedBox(width: 8),
                    _buildQuickAction(
                      buttonKey: const ValueKey(
                        'purification-import-clipboard',
                      ),
                      icon: CupertinoIcons.doc_on_clipboard,
                      label: '剪贴板导入',
                      onPressed: _importing ? null : _importRules,
                    ),
                    const SizedBox(width: 8),
                    _buildQuickAction(
                      buttonKey: const ValueKey(
                        'purification-export-clipboard',
                      ),
                      icon: CupertinoIcons.square_arrow_up,
                      label: '导出口令',
                      onPressed: _exportRules,
                    ),
                    if (canEditChapter) ...[
                      const SizedBox(width: 8),
                      _buildQuickAction(
                        buttonKey: const ValueKey('purification-toggle-edit'),
                        icon: CupertinoIcons.pencil_outline,
                        label: _editingParagraph ? '收起纠错' : '段落纠错',
                        selected: _editingParagraph,
                        onPressed: () => setState(() {
                          _editingParagraph = !_editingParagraph;
                          if (_editingParagraph) {
                            _adding = false;
                            _showUrlImport = false;
                            _syncParagraphEditorText();
                          }
                        }),
                      ),
                    ],
                  ],
                ),

                // ── 3. Expandable Panels (URL Import / Paragraph Edit / Add Rule) ──
                if (_showUrlImport) ...[
                  const SizedBox(height: 12),
                  ContentPanel(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            ArchiveIcon(CupertinoIcons.link,
                              size: 15,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text(
                                '从网络链接导入规则',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              '兼容阅读 Legado JSON',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          key: const ValueKey('purification-url-field'),
                          controller: _urlCtrl,
                          enabled: !_importing,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: '规则链接',
                            hintText: 'https://…/rules.json',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: _importing
                              ? null
                              : (_) => _submitUrlField(),
                        ),
                        const SizedBox(height: 6),
                        const Text('导入后保存到本机，确认后启用'),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '允许不安全的 HTTP 链接（局域网或旧源）',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Switch.adaptive(
                              key: const ValueKey('purification-allow-http'),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              value: _allowHttpUrl,
                              onChanged: _importing
                                  ? null
                                  : (value) => setState(() {
                                      _allowHttpUrl = value;
                                      _importError = null;
                                    }),
                            ),
                          ],
                        ),
                        if (_importError != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              _importError!,
                              style: TextStyle(
                                color: scheme.error,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            GlassTextButton(
                              compact: true,
                              onPressed: _importing
                                  ? null
                                  : () => setState(() {
                                      _showUrlImport = false;
                                      _importError = null;
                                    }),
                              child: const Text('取消'),
                            ),
                            const SizedBox(width: 8),
                            GlassTextButton(
                              key: const ValueKey(
                                'purification-import-url-submit',
                              ),
                              compact: true,
                              onPressed: _importing ? null : _submitUrlField,
                              child: Text(_importing ? '正在下载并导入…' : '导入规则'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                if (_editingParagraph && canEditChapter) ...[
                  const SizedBox(height: 12),
                  ContentPanel(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '段落纠错（第 ${_selectedParagraphIndex + 1} / ${widget.chapterParagraphs!.length} 段）',
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const ArchiveIcon(CupertinoIcons.chevron_left,
                                size: 18,
                              ),
                              visualDensity: VisualDensity.compact,
                              tooltip: '上一段',
                              onPressed: _selectedParagraphIndex > 0
                                  ? () => setState(() {
                                      _selectedParagraphIndex--;
                                      _syncParagraphEditorText();
                                    })
                                  : null,
                            ),
                            IconButton(
                              icon: const ArchiveIcon(CupertinoIcons.chevron_right,
                                size: 18,
                              ),
                              visualDensity: VisualDensity.compact,
                              tooltip: '下一段',
                              onPressed:
                                  _selectedParagraphIndex + 1 <
                                      widget.chapterParagraphs!.length
                                  ? () => setState(() {
                                      _selectedParagraphIndex++;
                                      _syncParagraphEditorText();
                                    })
                                  : null,
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          key: const ValueKey('purification-paragraph-editor'),
                          controller: _editParagraphCtrl,
                          minLines: 3,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            labelText: '直接修正当前段落错别字或排版',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (store.paragraphEditFor(
                                  widget.bookId!,
                                  widget.chapterIndex!,
                                  _selectedParagraphIndex,
                                ) !=
                                null)
                              GlassTextButton(
                                compact: true,
                                onPressed: () async {
                                  await store.clearParagraphEdit(
                                    bookId: widget.bookId!,
                                    chapterIndex: widget.chapterIndex!,
                                    paragraphIndex: _selectedParagraphIndex,
                                  );
                                  if (!mounted) return;
                                  setState(_syncParagraphEditorText);
                                },
                                child: const Text('还原原文'),
                              ),
                            const SizedBox(width: 8),
                            GlassTextButton(
                              key: const ValueKey(
                                'purification-save-paragraph',
                              ),
                              compact: true,
                              onPressed: _saveParagraphEdit,
                              child: const Text('保存段落修改'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                if (_adding) ...[
                  const SizedBox(height: 12),
                  ContentPanel(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '新增自定义规则',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _nameCtrl,
                          decoration: const InputDecoration(
                            labelText: '规则名称（如：修正人名译名）',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _patternCtrl,
                          decoration: const InputDecoration(
                            labelText: '查找内容 / 正则表达式',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _replacementCtrl,
                          decoration: const InputDecoration(
                            labelText: '替换为（留空表示删除匹配内容）',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _buildCompactSwitchRow(
                          label: '使用正则表达式',
                          value: _isRegex,
                          onChanged: (v) => setState(() => _isRegex = v),
                        ),
                        if (widget.bookId != null)
                          _buildCompactSwitchRow(
                            label: '仅对《${widget.bookTitle ?? "当前书籍"}》生效',
                            switchKey: const ValueKey(
                              'purification-scope-current-book',
                            ),
                            value: _onlyCurrentBook,
                            onChanged: (v) =>
                                setState(() => _onlyCurrentBook = v),
                          ),
                        _buildCompactSwitchRow(
                          label: '同时净化章节标题',
                          switchKey: const ValueKey('purification-apply-title'),
                          value: _applyToTitle,
                          onChanged: (v) => setState(() => _applyToTitle = v),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            _error!,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerRight,
                          child: GlassTextButton(
                            key: const ValueKey('purification-save-rule'),
                            compact: true,
                            onPressed: _submitCustomRule,
                            child: const Text('保存并启用规则'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // ── 4. Imported Rule Sources Strip ──
                if (sourceCounts.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final entry in sourceCounts.entries)
                        _buildSourceChip(
                          source: entry.key,
                          count: entry.value,
                          onDelete: _importing
                              ? null
                              : () => store.removeSource(entry.key),
                        ),
                    ],
                  ),
                ],

                // ── 5. Category Filters & Search ──
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildFilterChip(
                        label: '全部 (${allRules.length})',
                        selected: activeFilter == _PurificationRuleFilter.all,
                        onTap: () => setState(
                          () => _filter = _PurificationRuleFilter.all,
                        ),
                      ),
                      if (hasChapter) ...[
                        const SizedBox(width: 6),
                        _buildFilterChip(
                          chipKey: const ValueKey(
                            'purification-filter-effective',
                          ),
                          label: '本章已命中 (${effectiveRules.length})',
                          selected:
                              activeFilter == _PurificationRuleFilter.effective,
                          onTap: () => setState(
                            () => _filter =
                                activeFilter ==
                                    _PurificationRuleFilter.effective
                                ? _PurificationRuleFilter.all
                                : _PurificationRuleFilter.effective,
                          ),
                        ),
                      ],
                      const SizedBox(width: 6),
                      _buildFilterChip(
                        label: '已启用 ($enabledCount)',
                        selected:
                            activeFilter == _PurificationRuleFilter.enabled,
                        onTap: () => setState(
                          () => _filter =
                              activeFilter == _PurificationRuleFilter.enabled
                              ? _PurificationRuleFilter.all
                              : _PurificationRuleFilter.enabled,
                        ),
                      ),
                      const SizedBox(width: 6),
                      _buildFilterChip(
                        label: '内置预设 ($builtInCount)',
                        selected:
                            activeFilter == _PurificationRuleFilter.builtIn,
                        onTap: () => setState(
                          () => _filter =
                              activeFilter == _PurificationRuleFilter.builtIn
                              ? _PurificationRuleFilter.all
                              : _PurificationRuleFilter.builtIn,
                        ),
                      ),
                      if (customCount > 0) ...[
                        const SizedBox(width: 6),
                        _buildFilterChip(
                          label: '自定义/导入 ($customCount)',
                          selected:
                              activeFilter == _PurificationRuleFilter.custom,
                          onTap: () => setState(
                            () => _filter =
                                activeFilter == _PurificationRuleFilter.custom
                                ? _PurificationRuleFilter.all
                                : _PurificationRuleFilter.custom,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (allRules.length >
                    ReaderPurificationStore.builtInPresets.length) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _searchCtrl,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '搜索规则名称或匹配表达式…',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      prefixIcon: const ArchiveIcon(CupertinoIcons.search, size: 16),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 32,
                      ),
                      suffixIcon: query.isEmpty
                          ? null
                          : IconButton(
                              icon: const ArchiveIcon(CupertinoIcons.clear_circled_solid,
                                size: 16,
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() {});
                              },
                            ),
                    ),
                  ),
                ],

                // ── 6. Rules List Card ──
                const SizedBox(height: 10),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: store.enabled ? 1.0 : 0.55,
                  child: ContentPanel(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: listMaxHeight),
                      child: rules.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(vertical: 28),
                              child: Center(
                                child: Text(
                                  query.isNotEmpty
                                      ? '未找到匹配的净化规则'
                                      : activeFilter ==
                                            _PurificationRuleFilter.effective
                                      ? '本章正文暂未触发任何净化规则'
                                      : '暂无符合条件的净化规则',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: rules.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 10, thickness: 0.5),
                              itemBuilder: (context, index) {
                                final rule = rules[index];
                                final isHit = effectiveIds.contains(rule.id);
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Flexible(
                                                  child: Text(
                                                    rule.name,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 13.5,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                _buildRuleBadge(
                                                  context,
                                                  rule.builtIn
                                                      ? '内置'
                                                      : rule.isRegex
                                                      ? '正则'
                                                      : '文本',
                                                ),
                                                if (isHit) ...[
                                                  const SizedBox(width: 4),
                                                  _buildRuleBadge(
                                                    context,
                                                    '本章命中',
                                                    highlight: true,
                                                  ),
                                                ],
                                                if (rule.scopeBookId !=
                                                    null) ...[
                                                  const SizedBox(width: 4),
                                                  _buildRuleBadge(
                                                    context,
                                                    '仅《${rule.scopeBookTitle ?? rule.scopeBookId}》',
                                                  ),
                                                ],
                                                if (rule
                                                    .importScope
                                                    .isNotEmpty) ...[
                                                  const SizedBox(width: 4),
                                                  Tooltip(
                                                    message: rule.importScope,
                                                    child: _buildRuleBadge(
                                                      context,
                                                      '限定范围',
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              rule.unsupportedReason != null
                                                  ? '${rule.unsupportedReason!} · ${_ruleSubtitle(rule)}'
                                                  : _ruleSubtitle(rule),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                fontFamily:
                                                    rule.builtIn &&
                                                        rule.pattern.startsWith(
                                                          '__',
                                                        )
                                                    ? null
                                                    : 'monospace',
                                                color:
                                                    rule.unsupportedReason !=
                                                        null
                                                    ? scheme.error
                                                    : scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (!rule.builtIn)
                                        SizedBox(
                                          width: 32,
                                          height: 32,
                                          child: IconButton(
                                            padding: EdgeInsets.zero,
                                            icon: ArchiveIcon(CupertinoIcons.delete,
                                              size: 16,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                            tooltip: '删除规则',
                                            onPressed: () =>
                                                store.removeRule(rule.id),
                                          ),
                                        ),
                                      Switch.adaptive(
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        value: rule.enabled,
                                        onChanged:
                                            rule.unsupportedReason != null
                                            ? null
                                            : (v) => store.toggleRule(
                                                rule.id,
                                                v,
                                              ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
