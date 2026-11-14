import 'dart:convert';
import 'dart:math' as math;

const defaultChapterExtensionsEnabled = true;

/// UTF-16 offsets in the normalized internal text, shared by import and audit.
class LocalChapterIndex {
  const LocalChapterIndex(
    this.title,
    this.offset,
    this.length, {
    this.volume = '',
    this.byteOffset = -1,
    this.byteLength = -1,
  });
  final String title;
  final int offset;
  final int length;
  final String volume;
  final int byteOffset;
  final int byteLength;
  Map<String, Object?> toJson() => {
    't': title,
    'o': offset,
    'l': length,
    if (volume.isNotEmpty) 'v': volume,
    if (byteOffset >= 0 && byteLength >= 0) 'bo': byteOffset,
    if (byteOffset >= 0 && byteLength >= 0) 'bl': byteLength,
  };
  factory LocalChapterIndex.fromJson(Map<String, Object?> json) =>
      LocalChapterIndex(
        json['t'] as String? ?? '正文',
        (json['o'] as num?)?.toInt() ?? 0,
        (json['l'] as num?)?.toInt() ?? 0,
        volume: json['v'] as String? ?? '',
        byteOffset: (json['bo'] as num?)?.toInt() ?? -1,
        byteLength: (json['bl'] as num?)?.toInt() ?? -1,
      );
}

final _bomPrefix = RegExp(r'^\uFEFF');
final _nonUnixNewline = RegExp(r'[\r\u2028\u2029]');

String normalizeLocalText(String text) => text
    .replaceFirst(_bomPrefix, '')
    .replaceAll('\r\n', '\n')
    .replaceAll(_nonUnixNewline, '\n');

bool validChapterRanges(List<LocalChapterIndex> chapters, int textLength) {
  var end = 0;
  for (final c in chapters) {
    if (c.offset < end || c.length < 0 || c.offset + c.length > textLength) {
      return false;
    }
    end = c.offset + c.length;
  }
  return true;
}

const _number =
    r'[0-9０-９一二三四五六七八九十百千萬万零〇两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟廿卅卌\u2160-\u217F\u2460-\u2473]+';
const _numberRange =
    '$_number(?:[ \\t　]*[-~～—–─━―/／至到]+[ \\t　]*$_number)*';
const _numberSpan =
    '$_number(?:[ \\t　]*[-~～—–─━―、,，/／至到]+[ \\t　]*$_number)*';
final _numbered = RegExp(
  '(?:第[ \\t　]*(?:$_numberSpan|[（(【\\[［〖〔][ \\t　]*$_numberSpan[ \\t　]*[）)】\\]］〗〕])[ \\t　]*(?:[分大小]?[卷捲章节節部集篇]|[章节節回囘话話幕折季期更段册冊编編輯辑讲講场場局夜曲弹彈])|$_numberRange[章节節回囘话話幕折卷捲部集篇段册冊编編輯辑]|分[卷捲节節]阅读[ \\t　]*$_numberRange)',
);
final _weakNumberedUnit = RegExp(r'[段册冊编編輯辑讲講场場局夜曲弹彈]$');
final _headingOrdinal = RegExp('第[ \\t　]*($_number)');
const _cnDigits = {
  '零': 0, '〇': 0, '一': 1, '壹': 1, '二': 2, '两': 2, '兩': 2, '贰': 2,
  '貳': 2, '三': 3, '叁': 3, '參': 3, '四': 4, '肆': 4, '五': 5, '伍': 5,
  '六': 6, '陆': 6, '陸': 6, '七': 7, '柒': 7, '八': 8, '捌': 8, '九': 9,
  '玖': 9,
};
const _cnUnits = {
  '十': 10, '拾': 10, '百': 100, '佰': 100, '千': 1000, '仟': 1000,
  '万': 10000, '萬': 10000,
};

/// Reads the ordinal of headings like "第12章" or "第十二回"; null if unknown.
int? headingOrdinal(String title) {
  final matches = _headingOrdinal.allMatches(title).toList(growable: false);
  if (matches.isEmpty) return null;
  var m = matches.first;
  if (matches.length > 1) {
    final afterFirst = title.substring(m.end).trimLeft();
    if (afterFirst.isNotEmpty && _volumeSuffix.hasMatch(afterFirst[0])) {
      m = matches[1];
    }
  }
  final token = m.group(1)!.replaceAllMapped(
    RegExp('[０-９]'),
    (d) => String.fromCharCode(d[0]!.codeUnitAt(0) - 0xFEE0),
  );
  final arabic = int.tryParse(token);
  if (arabic != null) return arabic;
  var total = 0, section = 0, digit = 0;
  for (final ch in token.split('')) {
    final d = _cnDigits[ch];
    if (d != null) {
      digit = d;
      continue;
    }
    final unit = _cnUnits[ch];
    if (unit == null) return null;
    if (unit == 10000) {
      total += (section + digit) * unit;
      section = 0;
    } else {
      section += (digit == 0 ? 1 : digit) * unit;
    }
    digit = 0;
  }
  return total + section + digit;
}
final _volumeNumber = RegExp(
  '(?:卷[ \\t　]*$_numberSpan|[章节節回囘话話幕折部集篇][ \\t　]*之?[ \\t　]*$_numberRange(?=\$|[ \\t　:：、.．—\\-–）)】\\]]))',
);
final _english = RegExp(
  r'(?:chapter|part|section|episode|ep\.?|act|vol(?:ume)?\.?)\s*(?:[0-9０-９]+(?:\s*[-~～—–/]\s*[0-9０-９]+)?|[ivxlcdm]+)(?![a-z0-9０-９])',
  caseSensitive: false,
);
final _englishVolumePrefix = RegExp(r'^vol(?:ume)?\b', caseSensitive: false);
final _bare = RegExp(
  '^(?:[（(][ \\t　]*($_numberSpan)[ \\t　]*[）)]|[【\\[［〖〔《「『〈<][ \\t　]*($_numberSpan)[ \\t　]*[】\\]］〗〕》」』〉>]|第[ \\t　]*($_numberRange)(?:[.．、:：]|[ \\t　]+|\$)|($_numberRange)(?:[.．、:：]|[ \\t　]*[—–─━―]+|[ \\t　]+-[ \\t　]+)|($_numberRange)[ \\t　]+|($_numberRange)\$)',
);
final _special = RegExp(
  r'^(?:序章|序曲|序言|序幕|自序|代序|总序|序(?=$|[ \t　:：、·・—\-–）)】\]])|楔子|引子|引言|前言|前传|前傳|前篇|后篇|後篇|续篇|續篇|中篇|终章|終章|终曲|终幕|終幕|终篇|終篇|终卷|終卷|大结局|大結局|结局|結局|完本感言|完结感言|番外(?:篇|章|卷)?(?:[ \t　]*[0-9０-９一二三四五六七八九十百千万零〇两\u2460-\u2473]+)?|后记|後記|后日谈|後日談|跋|尾声|尾聲|外篇|外传|外傳|别传|別傳|正传|正傳|间章|間章|幕间|幕間|[上中下][篇卷部集册冊]|人物(?:介绍|简介)|设定集|背景设定|作品相关|内容简介)',
);
const _extendedTailPattern = r'[ \t　]*[：:；;—·｜–.|-][^\r\n。！？!?；;]{0,20}';
final _extendedSpecial = RegExp(
  '^(?:扉页|(?:内容|文章|书籍)?简介|文案|作品相关|卷[首尾末](?:语|总结|感言))(?=\$|$_extendedTailPattern\$)',
  unicode: true,
  multiLine: false,
  dotAll: false,
);
final _extendedSpecialTail = RegExp(
  '^$_extendedTailPattern\$',
  unicode: true,
  multiLine: false,
  dotAll: false,
);
final _decoration = RegExp(
  r'^[\s\uFEFF\u200B\u200C\u200D\u2060#＃＊*☆★✦✧✩✪✫✬✭✮✯◆◇◈●○◎◯※¤§■□▪▫▲△▼▽◀◁▶▷♥♡♦♢♠♣•·・‣⁃=＝—\-–─━═┄┅┈┉~～∼_＿+＋|｜丨🍎📖📚🔖🌸🌺🌻🌼🌷🌹✨🔥💧🌙⭐🌟💫]+',
  unicode: true,
);
final _trailingDecoration = RegExp(
  r'[ \t　]*(?:[#＃＊*☆★✦✧◆◇●○◎※=＝─━═┄┅┈┉~～_＿+＋■□▪▫▲△▼▽]+|[-—–]{2,})[ \t　]*$',
);
final _endMarker = RegExp(
  r'^[\s【\[（(]*第?[^\n]{0,16}[卷捲部集篇][\s】\]）)]*(?:完|结束|終|终|END)',
  caseSensitive: false,
);
final _proseSuffix = RegExp(
  r'^(?:回[来去到头答想忆合事家顾]|节[课约省日]|部(?:[队门署]|分(?![ \t　:：、.．—\-–）)】\]\n]|$))|集[合中体]|篇[文章幅]|季[节能度]|期[间待限望刊末]|更[加新换改多好快是]|段[落时间话路情]|场[面景合雨雪戏病所]|局[面势部限长]|夜[里间晚半色]|曲[折线子调]|弹[药指琴出])',
);
final _punctuation = RegExp(r'[。！？!?；;]');
final _weakSentencePunctuation = RegExp(r'[。；;]');
final _commaPunctuation = RegExp(r'[，,]');
final _wordIgnoredChars = RegExp(r'[\s\uFEFF\u200B]');
final _directoryMarkerLine = RegExp(
  r'^[【\[\s]*(?:目\s*录|contents)[】\]\s:：]*$',
  caseSensitive: false,
);
final _openingBracket = RegExp(r'^[【\[［〖〔《「『〈<（(]');
final _volumeSuffix = RegExp(r'[卷捲部集篇]$');
final _sentencePunctuation = RegExp(r'[。！？!?，,；;“”…⋯]');
final _bracketedGroup = RegExp(
  r'【[^】\n]*】|《[^》\n]*》|\[[^\]\n]*\]|［[^］\n]*］|（[^）\n]*）|\([^)\n]*\)|「[^」\n]*」|『[^』\n]*』|〖[^〗\n]*〗|〔[^〕\n]*〕|〈[^〉\n]*〉',
);
final _validHeadingPrefixEnd = RegExp(
  r'[\s　】\]］》」』〗〕）)〉>（(【\[［〖〔《「『〈<\-—–─━~～·・•_＿:：/／|｜丨.．、0-9０-９]$',
);
final _proseBeforeDi = RegExp(
  r'[的了着过是在有把被给让向往到于与和或但而却又也都就才还只要想看见说听知觉得成做作当从自由按照据那这哪谁我你他她它们]$',
);
final _measureWordSuffix = RegExp(
  r'^[ \t　]*[个位名次倍年岁天日秒分点层楼室班队组号条款式项碗杯件本张把座家只条斤元块里米步遍趟声口眼下番种样类代届级等品]',
);
final _bracketPrefix = RegExp(
  r'^(?:(?:【[^】\n]{1,48}】|《[^》\n]{1,48}》|\[[^\]\n]{1,48}\]|［[^］\n]{1,48}］|「[^」\n]{1,48}」|『[^』\n]{1,48}』|〖[^〗\n]{1,48}〗|〔[^〕\n]{1,48}〕|〈[^〉\n]{1,48}〉)[ \t　\-—–─━:：·・/／]*)+',
);
final _titledBarePrefix = RegExp(
  '^([^\\n。！？!?，,；;：:“”‘’""\'\'「」『』【】\\[\\]［］〖〗〔〕《》（）()]{1,40}?)'
  '(?:'
  '([ \\t　]*[-—–─━:：·・]?[ \\t　]*)(?=[（(][ \\t　]*(?:$_numberSpan)[ \\t　]*[）)]|[【\\[［〖〔《「『〈<][ \\t　]*(?:$_numberSpan)[ \\t　]*[】\\]］〗〕》」』〉>])'
  '|'
  '([ \\t　]*[-—–─━:：·・][ \\t　]*|[ \\t　]+)(?=(?:第[ \\t　]*)?(?:$_numberRange)(?:[ \\t　:：、.．\\-—]|\$))'
  ')',
);
final _bareTrailingSeparator = RegExp(r'^[\s:：、.．\-—–─━]');
final _parenthesizedCandidate = RegExp(r'^[（(【\[［〖〔《「『〈<]');
final _specialTailAllowed = RegExp(
  r'^[\s\d０-９一二三四五六七八九十百千万零〇两:：、.．·・【\[［〖〔《「『（(】\]］〗〕》」』）)\-—–~～]',
);
final _bracketVolumeEnd = RegExp(
  r'^[【\[].*[卷捲部集篇].*(?:完|结束|END)[）)】\]]*$',
  caseSensitive: false,
);
final _triPartVolume = RegExp(r'^[上中下][篇卷部集册冊]');
final _forumMarker = RegExp(
  r'\[bbs\]|https?://|viewthread\.php',
  caseSensitive: false,
);
final _anyWhitespace = RegExp(r'\s');
final _headingKeyIgnored = RegExp(r'[\s【】\[\]（）()]');
final _inlineHeadingBoundary = RegExp(
  r'[。！？!?…~～”’」』）)】\]>》][ \t　\uFEFF\u200B#＊*☆★◆◇●○◎※=—\-─━]*'
  r'((?:(?:【[^】\n]{1,24}】|《[^》\n]{1,24}》|\[[^\]\n]{1,24}\])[ \t　]*)?'
  r'(?:[【\[（(《「『])?'
  '(?:第[ \\t　]*$_numberSpan[ \\t　]*[章节節回囘话話幕折卷捲部集篇季期更]'
  r'|chapter[ \t]+[0-9０-９ivxlcdm]+(?![a-z0-9０-９]))'
  r'[^。！？!?，,；;“”’\n]{0,40})$',
  caseSensitive: false,
);
final _midLineHeadingBoundary = RegExp(
  r'[。！？!?…~～”’」』）)】\]>》][ \t　\uFEFF\u200B]*'
  r'((?:第[ \t　]*'
  '$_numberSpan'
  r'[ \t　]*[卷捲部集篇](?:[ \t　:：—\-–]+[^\s\n。！？!?，,；;“”‘’”’」』]{1,18})?[ \t　]+)?'
  r'(?:第[ \t　]*'
  '$_numberSpan'
  r'[ \t　]*[章节節回囘话話幕折]|chapter[ \t]+[0-9０-９ivxlcdm]+(?![a-z0-9０-９]))'
  r'(?:[ \t　:：、—\-–]+[^\s\n。！？!?，,；;“”‘’”’」』]{1,22})?)'
  r'(?:　+|[ \t]{2,})(?=\S)',
  caseSensitive: false,
);
final _inlineSuffixProseStart = RegExp(
  r'^[的了着过是在有把被给让和与或但而却又也都就才还只要想看见说听知觉得成做作当从自那这哪谁我你他她它们里上中下内前后来去]',
);

bool _isAcceptableWeakSuffix(String suffix, {required bool allowGlued}) {
  if (suffix.length > 120) return allowGlued;
  if (_weakSentencePunctuation.hasMatch(suffix)) {
    return allowGlued && suffix.length > 36;
  }
  if (_punctuation.hasMatch(suffix) && suffix.length > 24) {
    return allowGlued && suffix.length > 36;
  }
  if (_commaPunctuation.hasMatch(suffix)) {
    if (allowGlued && suffix.length > 60) return true;
    final trimmed = suffix.trim();
    final commas = _commaPunctuation.allMatches(trimmed).length;
    if (commas > 1 || trimmed.length > 28 || _punctuation.hasMatch(trimmed)) {
      return false;
    }
  }
  return true;
}

class _Heading {
  _Heading(
    this.title,
    this.start,
    this.content,
    this.wordsBefore,
    this.wordsAfter,
    this.family,
    this.weak,
    this.volume,
    this.key,
    this.startBytes,
    this.contentBytes, {
    this.glued = false,
    this.explicitVolume = '',
  });
  final String title, family, key, explicitVolume;
  final int start, content, wordsBefore, wordsAfter;
  final int startBytes, contentBytes;
  final bool weak, volume, glued;
}

/// Keeps only candidate headings and a bounded line prefix, never a whole book.
/// Leading whitespace is counted separately, so even very long indentation is
/// accepted without growing the line buffer. All coordinates stay in the source.
class ChapterTextIndex {
  ChapterTextIndex({
    this.enableChapterExtensions = defaultChapterExtensionsEnabled,
  });

  final bool enableChapterExtensions;
  int length = 0;
  int byteLength = 0;
  int _lineStart = 0, _lineByteStart = 0;
  int _indent = 0, _indentBytes = 0, _words = 0, _lineWords = 0;
  String _line = '';
  String _fullLine = '';
  String _tail = '';
  bool _leading = true;
  bool _lineTruncated = false;
  bool _fullLineTruncated = false;
  final _headings = <_Heading>[];
  final _directoryMarkers = <int>[];

  // A high surrogate held from the previous chunk: it contributes no bytes
  // until its low surrogate arrives, so a pair split across chunk
  // boundaries is counted once (4 bytes) instead of twice (3 + 3 bytes
  // for two lone-surrogate replacements).
  int _pendingHigh = -1;

  void add(String chunk) {
    // Byte counting runs over countChunk, which carries a held high
    // surrogate from the previous chunk (shift 1) and holds a trailing
    // high surrogate for the next chunk. Character offsets keep using
    // the original chunk, so line splitting is unaffected.
    var countChunk = chunk;
    var shift = 0;
    if (_pendingHigh >= 0) {
      countChunk = String.fromCharCode(_pendingHigh) + chunk;
      _pendingHigh = -1;
      shift = 1;
    }
    if (countChunk.isNotEmpty) {
      final last = countChunk.codeUnitAt(countChunk.length - 1);
      if (last >= 0xD800 && last <= 0xDBFF) {
        _pendingHigh = last;
        countChunk = countChunk.substring(0, countChunk.length - 1);
      }
    }
    // 增量字节计数：segStart 为 countChunk 中尚未计入 runningBytes 的起点。
    // 分段点只在下标 0 或 '\n' 之后，不会拆开代理对，各段 UTF-8 长度之和
    // 等于整段前缀长度。每个码元只编码一次。
    var segStart = 0;
    var runningBytes = byteLength;
    for (var i = 0; i < chunk.length;) {
      final newline = chunk.indexOf('\n', i);
      final end = newline < 0 ? chunk.length : newline;
      var part = chunk.substring(i, end);
      _lineWords += part.replaceAll(_wordIgnoredChars, '').length;
      if (_leading) {
        final trimmed = part.trimLeft();
        final leadCount = part.length - trimmed.length;
        if (leadCount > 0) {
          _indent += leadCount;
          _indentBytes += utf8.encode(part.substring(0, leadCount)).length;
        }
        part = trimmed;
        if (part.isNotEmpty) _leading = false;
      }
      if (_line.length < 2048) {
        final room = 2048 - _line.length;
        _line += part.length > room ? part.substring(0, room) : part;
        if (part.length > room) _lineTruncated = true;
      } else if (part.isNotEmpty) {
        _lineTruncated = true;
      }
      if (!_fullLineTruncated && part.isNotEmpty) {
        const maxFullLine = 262144;
        if (_fullLine.length + part.length <= maxFullLine) {
          _fullLine += part;
        } else {
          _fullLine += part.substring(0, maxFullLine - _fullLine.length);
          _fullLineTruncated = true;
        }
      }
      if (part.isNotEmpty) {
        if (part.length >= 256) {
          _tail = part.substring(part.length - 256);
        } else {
          final combined = _tail + part;
          _tail = combined.length > 256
              ? combined.substring(combined.length - 256)
              : combined;
        }
      }
      if (newline < 0) break;
      final segEnd = newline + 1 + shift;
      runningBytes += utf8.encode(countChunk.substring(segStart, segEnd)).length;
      segStart = segEnd;
      final nextBytes = runningBytes;
      final lineEnd = length + newline;
      _finishLine(lineEnd, nextBytes - 1, lineEnd + 1, nextBytes);
      _lineStart = lineEnd + 1;
      _lineByteStart = nextBytes;
      i = newline + 1;
    }
    length += chunk.length;
    byteLength =
        runningBytes + utf8.encode(countChunk.substring(segStart)).length;
  }

  void _finishLine(int lineEnd, int lineEndBytes, int next, int nextBytes) {
    final line = _line.trimRight();
    if (_directoryMarkerLine.hasMatch(line)) {
      _directoryMarkers.add(_lineStart);
    }
    final h = _parse(line, next, nextBytes);
    if (h != null) _headings.add(h);
    if (h == null || h.content < next) {
      final inlineH = _parseInlineEnd(
        _tail,
        lineEnd,
        lineEndBytes,
        next,
        nextBytes,
      );
      if (!_fullLineTruncated && _fullLine.length >= 40) {
        final minOffset = h == null ? _lineStart + _indent + 1 : h.content;
        final maxOffset = inlineH?.start ?? lineEnd;
        _parseMidLineHeadings(_fullLine, minOffset, maxOffset);
      }
      if (inlineH != null &&
          (_headings.isEmpty || inlineH.start > _headings.last.content)) {
        _headings.add(inlineH);
      }
    }
    if (_headings.length + _directoryMarkers.length > 100000) {
      throw const FormatException('TXT 章节索引过大：候选标题与目录标记超过 100000 条');
    }
    _words += _lineWords;
    _lineWords = 0;
    _line = '';
    _fullLine = '';
    _tail = '';
    _indent = 0;
    _indentBytes = 0;
    _leading = true;
    _lineTruncated = false;
    _fullLineTruncated = false;
  }

  static bool _hasUnclosedQuoteBefore(String text, int limit) {
    var dq = 0, cjk1 = 0, cjk2 = 0;
    for (var i = 0; i < limit; i++) {
      switch (text.codeUnitAt(i)) {
        case 0x201C:
          dq++;
        case 0x201D:
          if (dq > 0) dq--;
        case 0x300C:
          cjk1++;
        case 0x300D:
          if (cjk1 > 0) cjk1--;
        case 0x300E:
          cjk2++;
        case 0x300F:
          if (cjk2 > 0) cjk2--;
      }
    }
    return dq > 0 || cjk1 > 0 || cjk2 > 0;
  }

  void _parseMidLineHeadings(String fullLine, int minOffset, int maxOffset) {
    final baseOffset = _lineStart + _indent;
    final baseBytes = _lineByteStart + _indentBytes;
    var lastAcceptedEnd = 0;
    for (final match in _midLineHeadingBoundary.allMatches(fullLine)) {
      if (match.start < lastAcceptedEnd) continue;
      final candidateRaw = match.group(1)!;
      final candidateOffsetInMatch =
          fullLine.indexOf(candidateRaw, match.start);
      if (candidateOffsetInMatch < 0) continue;
      final headingEndInFull = candidateOffsetInMatch + candidateRaw.length;
      final start = baseOffset + candidateOffsetInMatch;
      final content = baseOffset + headingEndInFull;
      if (start < minOffset || content >= maxOffset) continue;
      if (_hasUnclosedQuoteBefore(fullLine, candidateOffsetInMatch)) continue;

      final candidate = candidateRaw.trim();
      if (candidate.isEmpty ||
          _endMarker.hasMatch(candidate) ||
          _bracketVolumeEnd.hasMatch(candidate)) {
        continue;
      }
      var explicitVol = '';
      var m = _numbered.firstMatch(candidate) ?? _english.firstMatch(candidate);
      if (m == null) continue;
      if (_volumeSuffix.hasMatch(m.group(0)!)) {
        final sub =
            _numbered.allMatches(candidate, m.end).firstOrNull ??
            _english.allMatches(candidate, m.end).firstOrNull;
        if (sub == null || _volumeSuffix.hasMatch(sub.group(0)!)) continue;
        explicitVol = candidate
            .substring(0, sub.start)
            .replaceFirst(RegExp(r'[\s　:：—\-–·・|｜/／]+$'), '')
            .trim();
        m = sub;
      }
      final token = m.group(0)!;
      final suffix = candidate.substring(m.end);
      if (_proseSuffix.hasMatch('${token[token.length - 1]}$suffix')) {
        continue;
      }
      final prevWords = fullLine
          .substring(lastAcceptedEnd, candidateOffsetInMatch)
          .replaceAll(_wordIgnoredChars, '')
          .length;
      final remLimit = (maxOffset - baseOffset).clamp(0, fullLine.length);
      final nextWords = fullLine
          .substring(headingEndInFull, remLimit)
          .replaceAll(_wordIgnoredChars, '')
          .length;
      if (prevWords < 12 || nextWords < 12) continue;

      final prefixSlice = fullLine.substring(0, candidateOffsetInMatch);
      final startBytes = baseBytes + utf8.encode(prefixSlice).length;
      final contentBytes = startBytes + utf8.encode(candidateRaw).length;
      final wordsBefore =
          _words + prefixSlice.replaceAll(_wordIgnoredChars, '').length;
      final wordsAfter =
          wordsBefore + candidateRaw.replaceAll(_wordIgnoredChars, '').length;
      final family = token.toLowerCase().startsWith('chapter')
          ? 'english'
          : token[token.length - 1];
      final key = candidate.replaceAll(_headingKeyIgnored, '');
      _headings.add(
        _Heading(
          candidate,
          start,
          content,
          wordsBefore,
          wordsAfter,
          family,
          false,
          false,
          key,
          startBytes,
          contentBytes,
          explicitVolume: explicitVol,
        ),
      );
      lastAcceptedEnd = match.end;
    }
  }

  _Heading? _parseInlineEnd(
    String tail,
    int lineEnd,
    int lineEndBytes,
    int next,
    int nextBytes,
  ) {
    if (tail.isEmpty) return null;
    final trimmedTail = tail.trimRight();
    if (trimmedTail.isEmpty) return null;
    final match = _inlineHeadingBoundary.firstMatch(trimmedTail);
    if (match == null) return null;
    final candidate = match.group(1)!.trim();
    if (candidate.isEmpty ||
        _endMarker.hasMatch(candidate) ||
        _bracketVolumeEnd.hasMatch(candidate)) {
      return null;
    }
    var inner = candidate;
    final open = _openingBracket.firstMatch(inner);
    if (open != null) {
      final afterOpen = inner.substring(1);
      if (_numbered.matchAsPrefix(afterOpen) != null ||
          _english.matchAsPrefix(afterOpen) != null) {
        inner = afterOpen;
      }
    }
    final m = _numbered.firstMatch(inner) ?? _english.firstMatch(inner);
    if (m == null) return null;
    final token = m.group(0)!;
    final suffix = inner.substring(m.end);
    if (_proseSuffix.hasMatch('${token[token.length - 1]}$suffix')) {
      return null;
    }
    if (suffix.isNotEmpty) {
      final startsWithSep = RegExp(
        r'^[\s　:：、.．—\-–）)】\]》」』]',
      ).hasMatch(suffix);
      if (!startsWithSep &&
          (suffix.length > 16 || _inlineSuffixProseStart.hasMatch(suffix))) {
        return null;
      }
    }
    final rawSuffix = tail.substring(match.end - match.group(1)!.length);
    final start = lineEnd - rawSuffix.length;
    if (start <= _lineStart + _indent) return null;
    final startBytes = lineEndBytes - utf8.encode(rawSuffix).length;
    final inlineWords = rawSuffix.replaceAll(_wordIgnoredChars, '').length;
    final wordsBefore = _words + (_lineWords - inlineWords).clamp(0, _lineWords);
    final wordsAfter = _words + _lineWords;
    final isVolume = _volumeSuffix.hasMatch(token);
    final family = token.toLowerCase().startsWith('chapter')
        ? 'english'
        : token[token.length - 1];
    final key = candidate.replaceAll(_headingKeyIgnored, '');
    return _Heading(
      candidate,
      start,
      next,
      wordsBefore,
      wordsAfter,
      family,
      false,
      isVolume,
      key,
      startBytes,
      nextBytes,
    );
  }

  _Heading? _parse(String raw, int next, int nextBytes) {
    if (raw.isEmpty) return null;
    final baseLine = raw.replaceFirst(_decoration, '');
    final baseSkipped = raw.length - baseLine.length;
    if (_endMarker.hasMatch(baseLine) || _bracketVolumeEnd.hasMatch(raw)) {
      return null;
    }
    var line = baseLine;
    var skipped = baseSkipped;
    // Enclosing book names are meaningful display prefixes. Only syntactic
    // opening brackets around a heading are removed for matching.
    var opening = _openingBracket.firstMatch(line);
    if (opening != null) {
      final afterOpening = line.substring(1);
      final startsWithHeading =
          _numbered.matchAsPrefix(afterOpening) != null ||
          _volumeNumber.matchAsPrefix(afterOpening) != null ||
          _english.matchAsPrefix(afterOpening) != null ||
          _special.matchAsPrefix(afterOpening) != null;
      if (startsWithHeading) {
        skipped++;
        line = afterOpening;
      } else {
        opening = null;
      }
    }
    final extended = enableChapterExtensions && !_lineTruncated
        ? _extendedSpecial.firstMatch(line)
        : null;
    RegExpMatch? m =
        extended ??
        _numbered.firstMatch(line) ??
        _volumeNumber.firstMatch(line) ??
        _english.firstMatch(line);
    var explicitVolume = '';
    if (extended == null &&
        m != null &&
        (_volumeSuffix.hasMatch(m.group(0)!) ||
            m.group(0)!.startsWith('卷'))) {
      final volMatch = m;
      final rest = line.substring(volMatch.end);
      final sub = _numbered.firstMatch(rest) ?? _english.firstMatch(rest);
      if (sub != null && sub.start <= 36) {
        final subToken = sub.group(0)!;
        final subSuffix = rest.substring(sub.end);
        if (!_volumeSuffix.hasMatch(subToken) &&
            !_proseSuffix.hasMatch(
              '${subToken[subToken.length - 1]}$subSuffix',
            )) {
          final nextMatch =
              _numbered.allMatches(line, volMatch.end).firstOrNull ??
              _english.allMatches(line, volMatch.end).firstOrNull;
          if (nextMatch != null) {
            explicitVolume = line
                .substring(0, nextMatch.start)
                .replaceFirst(RegExp(r'[\s　:：—\-–·・|｜/／]+$'), '')
                .trim();
            m = nextMatch;
          }
        }
      }
    }
    var weak = false;
    String family = extended == null ? '' : 'special';
    var strippedPrefix = '';
    if (m != null && extended == null) {
      var mValid = true;
      var mWeak = false;
      final token = m.group(0)!;
      final suffix = line.substring(m.end);
      if (m.start > 0) {
        final prefix = line.substring(0, m.start);
        final unbracketedPrefix = prefix.replaceAll(_bracketedGroup, '');
        final prefixDisallowed = explicitVolume.isNotEmpty
            ? _punctuation
            : _sentencePunctuation;
        if (prefix.length > 48 ||
            prefixDisallowed.hasMatch(unbracketedPrefix)) {
          mValid = false;
        } else if (explicitVolume.isNotEmpty ||
            _validHeadingPrefixEnd.hasMatch(prefix) ||
            _volumeSuffix.hasMatch(prefix) ||
            prefix == '正文') {
          mValid = true;
        } else if (token.startsWith('第') &&
            prefix.length <= 20 &&
            !_sentencePunctuation.hasMatch(line) &&
            !_proseBeforeDi.hasMatch(prefix)) {
          mValid = true;
          mWeak = true;
        } else {
          mValid = false;
        }
      }
      if (mValid) {
        final lowerToken = token.toLowerCase();
        final isEnglish =
            lowerToken.startsWith('chapter') ||
            lowerToken.startsWith('part') ||
            lowerToken.startsWith('section') ||
            lowerToken.startsWith('ep') ||
            lowerToken.startsWith('act') ||
            lowerToken.startsWith('vol');
        final isSplitSection = token.startsWith('分');
        if (!token.startsWith('第') &&
            !token.startsWith('卷') &&
            !isSplitSection &&
            !lowerToken.startsWith('chapter')) {
          mWeak = true;
        }
        if (_weakNumberedUnit.hasMatch(token)) {
          mWeak = true;
        }
        if (_proseSuffix.hasMatch('${token[token.length - 1]}$suffix')) {
          mValid = false;
        }
        final mIsVolume =
            !isSplitSection &&
            (_volumeSuffix.hasMatch(token) ||
                _triPartVolume.hasMatch(token) ||
                _englishVolumePrefix.hasMatch(token));
        if (mValid && mIsVolume) {
          final volumeGlued =
              !mWeak &&
              RegExp(r'^[\s　:：、.．—\-–）)】\]]').hasMatch(suffix) &&
              (suffix.length > 60 ||
                  (suffix.length > 28 && _punctuation.hasMatch(suffix)));
          if (!volumeGlued &&
              (_weakSentencePunctuation.hasMatch(suffix) ||
                  suffix.length > 120 ||
                  (_punctuation.hasMatch(suffix) && suffix.length > 24))) {
            mValid = false;
          }
        }
        if (mValid && mWeak && !_isAcceptableWeakSuffix(suffix, allowGlued: false)) {
          mValid = false;
        }
        if (mValid) {
          weak = mWeak;
          family = isSplitSection
              ? 'split_part'
              : (isEnglish ? 'english' : token[token.length - 1]);
        }
      }
      if (!mValid) {
        m = null;
        explicitVolume = '';
        if (opening != null &&
            _special.matchAsPrefix(line) == null) {
          opening = null;
          line = baseLine;
          skipped = baseSkipped;
        }
      }
    }
    if (m == null) {
      // 【01】、[01]、【书名】（13）、《书名》（01）、书名（1）、===01=== 等。
      var base = 0;
      final cleanLine = line.replaceFirst(_trailingDecoration, '');
      var candidate = cleanLine.isNotEmpty ? cleanLine : line;
      m = _bare.firstMatch(candidate);
      if (m == null) {
        final bracket = _bracketPrefix.firstMatch(candidate);
        if (bracket != null) {
          base = bracket.end;
          candidate = candidate.substring(base);
          m = _bare.firstMatch(candidate);
        }
      }
      if (m == null) {
        final titled = _titledBarePrefix.firstMatch(candidate);
        if (titled != null) {
          final afterPrefix = candidate.substring(titled.end);
          final bareMatch = _bare.firstMatch(afterPrefix);
          if (bareMatch != null) {
            final trailing = afterPrefix.substring(bareMatch.end);
            final isParenthesized =
                _parenthesizedCandidate.hasMatch(afterPrefix);
            final sep = titled.group(2) ?? titled.group(3) ?? '';
            final numToken = bareMatch.group(0)!.trim();
            final isZeroPaddedOrDi =
                numToken.startsWith('第') ||
                RegExp(r'^[0０][0-9０-９]').hasMatch(numToken);
            final hasExplicitSep = RegExp(r'[-—–─━:：·・]').hasMatch(sep);
            final validTitled = isParenthesized
                ? (trailing.isEmpty ||
                    (trailing.length <= 24 &&
                        !_punctuation.hasMatch(trailing) &&
                        !_weakSentencePunctuation.hasMatch(trailing) &&
                        !_measureWordSuffix.hasMatch(trailing)))
                : ((trailing.isEmpty &&
                        !_proseBeforeDi.hasMatch(titled.group(1)!)) ||
                    ((hasExplicitSep || isZeroPaddedOrDi) &&
                        (trailing.isEmpty ||
                            ((_bareTrailingSeparator.hasMatch(trailing) ||
                                    _bareTrailingSeparator.hasMatch(
                                      bareMatch.group(
                                        0,
                                      )![bareMatch.group(0)!.length - 1],
                                    )) &&
                                trailing.length <= 24 &&
                                !_punctuation.hasMatch(trailing) &&
                                !_weakSentencePunctuation.hasMatch(trailing) &&
                                !_measureWordSuffix.hasMatch(
                                  trailing.trimLeft(),
                                )))));
            if (validTitled) {
              base += titled.end;
              candidate = afterPrefix;
              m = bareMatch;
            }
          }
        }
      }
      if (m != null) {
        family = _parenthesizedCandidate.hasMatch(candidate)
            ? 'parenthesized'
            : 'bare';
        weak = true;
        if (base > 0) {
          strippedPrefix = line.substring(0, base);
          skipped += base;
          line = candidate;
        } else {
          line = candidate;
        }
      } else {
        m = _special.firstMatch(line);
        if (m == null) return null;
        family = 'special';
        final tail = line.substring(m.end);
        if (tail.isNotEmpty && !_specialTailAllowed.hasMatch(tail)) {
          return null;
        }
        if (_punctuation.hasMatch(tail) && tail.length > 12) return null;
      }
    }
    if (extended != null) {
      final tail = line.substring(m.end);
      if (tail.isNotEmpty && !_extendedSpecialTail.hasMatch(tail)) {
        return null;
      }
    }
    final token = m.group(0)!;
    final isVolume =
        family != 'split_part' &&
        ((_volumeSuffix.hasMatch(token) && family != 'special') ||
            _triPartVolume.hasMatch(token) ||
            _englishVolumePrefix.hasMatch(token));
    final suffix = line.substring(m.end);
    if (family != 'split_part' &&
        _proseSuffix.hasMatch('${token[token.length - 1]}$suffix')) {
      return null;
    }
    // In-body numbered lists need repeated evidence and never accept sentences.
    final allowWeakGlued = family == 'parenthesized' && strippedPrefix.isEmpty;
    if (weak && !_isAcceptableWeakSuffix(suffix, allowGlued: allowWeakGlued)) {
      return null;
    }
    final forum = _forumMarker.firstMatch(line);
    var titleEnd = forum?.start ?? line.length;
    var content = next;
    final glued =
        extended == null &&
        forum == null &&
        ((!weak &&
                (suffix.length > 96 ||
                    (suffix.length > 28 && _punctuation.hasMatch(suffix)))) ||
            (allowWeakGlued &&
                (suffix.length > 96 ||
                    (suffix.length > 36 &&
                        (_punctuation.hasMatch(suffix) ||
                            _weakSentencePunctuation.hasMatch(suffix))))));
    if (glued) {
      // The title/body boundary is unknowable without semantics. Keep the
      // entire ambiguous suffix in the body, rather than discarding a guess.
      titleEnd = m.end;
      content = _lineStart + _indent + skipped + m.end;
    }
    if (titleEnd < m.end) return null;
    var title = line.substring(0, titleEnd).trim();
    if (opening != null) title = '${opening.group(0)}$title';
    if (title.isEmpty) return null;
    // Restore a book-name prefix stripped solely to parse a bracketed/parenthesized number.
    if (weak && strippedPrefix.isNotEmpty) {
      title = '$strippedPrefix$title';
    }
    final wordsAfter = glued
        ? _words +
              raw
                  .substring(
                    0,
                    (content - _lineStart - _indent).clamp(0, raw.length),
                  )
                  .replaceAll(_anyWhitespace, '')
                  .length
        : _words + _lineWords;
    final key = title.replaceAll(_headingKeyIgnored, '');
    final contentUnits = (content - _lineStart - _indent).clamp(0, raw.length);
    final contentBytes = glued
        ? _lineByteStart +
              _indentBytes +
              utf8.encode(raw.substring(0, contentUnits)).length
        : nextBytes;
    return _Heading(
      title,
      _lineStart,
      content,
      _words,
      wordsAfter,
      family,
      weak,
      isVolume,
      key,
      _lineByteStart,
      contentBytes,
      glued: glued,
      explicitVolume: explicitVolume,
    );
  }

  List<LocalChapterIndex> finish() {
    // A trailing unpaired high surrogate encodes as one replacement
    // character (3 bytes) in whole-string UTF-8 encoding.
    if (_pendingHigh >= 0) {
      byteLength += 3;
      _pendingHigh = -1;
    }
    _finishLine(length, byteLength, length, byteLength);
    final families = <String, int>{};
    for (final h in _headings) {
      families.update(h.family, (n) => n + 1, ifAbsent: () => 1);
    }
    final weakEvidence = <String, int>{};
    final strongEvidence = <String, int>{};
    for (var i = 0; i < _headings.length; i++) {
      final h = _headings[i];
      final next = i + 1 < _headings.length ? _headings[i + 1] : null;
      final minWords = h.glued ? 45 : 8;
      if ((next?.wordsBefore ?? _words) - h.wordsAfter > minWords) {
        if (h.weak) {
          weakEvidence.update(h.family, (n) => n + 1, ifAbsent: () => 1);
        } else {
          strongEvidence.update(h.family, (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    final dominant =
        families.entries
            .where(
              (e) =>
                  e.key != 'special' &&
                  ![
                    '卷',
                    '部',
                    '篇',
                    '集',
                    'bare',
                    'parenthesized',
                  ].contains(e.key),
            )
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    final mainFamily = dominant.isEmpty ? null : dominant.first.key;
    // A minority-style heading ("第13节" among "第N章") is still a chapter when
    // its number continues the main sequence on either side.
    bool continuesMainSequence(int index) {
      if (mainFamily == null) return false;
      final own = headingOrdinal(_headings[index].title);
      if (own == null) return false;
      int? neighbour(int step) {
        for (var j = index + step; j >= 0 && j < _headings.length; j += step) {
          if (_headings[j].family == mainFamily) {
            return headingOrdinal(_headings[j].title);
          }
        }
        return null;
      }

      final before = neighbour(-1), after = neighbour(1);
      return (before != null && before + 1 == own) ||
          (after != null && own + 1 == after);
    }

    var index = -1;
    var headings = _headings.where((h) {
      index++;
      if (h.weak) {
        final weakCount = weakEvidence[h.family] ?? 0;
        final canBorrowStrong =
            h.family != 'bare' &&
            h.family != 'parenthesized' &&
            !_weakNumberedUnit.hasMatch(h.family);
        final totalEvidence =
            weakCount + (canBorrowStrong ? (strongEvidence[h.family] ?? 0) : 0);
        if (totalEvidence < 2 || weakCount == 0) {
          return h.wordsAfter <
                  (index + 1 < _headings.length
                      ? _headings[index + 1].wordsBefore
                      : _words) &&
              continuesMainSequence(index);
        }
      }
      if (dominant.isNotEmpty &&
          dominant.first.value >= 8 &&
          ['回', '节', '部', '集'].contains(h.family) &&
          (families[h.family] ?? 0) < 2 &&
          h.family != dominant.first.key &&
          !continuesMainSequence(index)) {
        return false;
      }
      return true;
    }).toList();
    // Front matter TOCs contain consecutive headings with no body and often
    // repeat at the real chapter. Do not make those entries empty chapters.
    final lastHeadingByKey = <String, int>{};
    for (var i = 0; i < headings.length; i++) {
      lastHeadingByKey[headings[i].key] = i;
    }
    final directory = <_Heading>{};
    final directoryKeys = <String>{};
    var markerCursor = 0;
    var inMarkedToc = false;
    for (var i = 0; i + 1 < headings.length; i++) {
      final h = headings[i], after = headings[i + 1];
      while (markerCursor < _directoryMarkers.length &&
          _directoryMarkers[markerCursor] <= h.start) {
        inMarkedToc = true;
        markerCursor++;
      }
      final gapWords = after.wordsBefore - h.wordsAfter;
      final repeated = (lastHeadingByKey[h.key] ?? i) > i;
      final afterRepeated = (lastHeadingByKey[after.key] ?? (i + 1)) > (i + 1);
      final afterBodyWords =
          (i + 2 < headings.length ? headings[i + 2].wordsBefore : _words) -
          after.wordsAfter;
      final isVolumeBeforeRealChapter =
          h.volume && !repeated && !afterRepeated && afterBodyWords > 0;
      if (gapWords == 0 &&
          (repeated || (inMarkedToc && !isVolumeBeforeRealChapter))) {
        directory.add(h);
        directoryKeys.add(h.key);
        continue;
      }
      final afterRestartsToc =
          afterRepeated ||
          directoryKeys.contains(after.key) ||
          after.volume ||
          after.family == 'special';
      if (i > 0 &&
          directory.contains(headings[i - 1]) &&
          repeated &&
          (gapWords <= 40 || (inMarkedToc || afterRestartsToc))) {
        directory.add(h);
        directoryKeys.add(h.key);
        inMarkedToc = false;
        continue;
      }
      if (gapWords > 0 && !repeated) {
        inMarkedToc = false;
      }
    }
    headings = headings.where((h) => !directory.contains(h)).toList();
    if (headings.isEmpty) {
      return [
        LocalChapterIndex(
          '正文',
          0,
          length,
          byteOffset: 0,
          byteLength: byteLength,
        ),
      ];
    }
    final chapters = <LocalChapterIndex>[];
    var volume = '';
    final volumes = headings.where((h) => h.volume).toList();
    var volumeCursor = 0;
    // Preserve ALL nonempty front matter, including TOC text as front matter;
    // it has no independent chapter entries and never hides opening prose.
    if (headings.first.wordsBefore > 0) {
      chapters.add(
        LocalChapterIndex(
          '前言',
          0,
          headings.first.start,
          byteOffset: 0,
          byteLength: headings.first.startBytes,
        ),
      );
    }
    for (var i = 0; i < headings.length; i++) {
      final h = headings[i];
      final next = i + 1 < headings.length ? headings[i + 1] : null;
      final end = next?.start ?? length;
      final bodyWords = (next?.wordsBefore ?? _words) - h.wordsAfter;
      while (volumeCursor < volumes.length &&
          volumes[volumeCursor].start <= h.start) {
        volume = volumes[volumeCursor++].title;
      }
      if (h.explicitVolume.isNotEmpty) {
        volume = h.explicitVolume;
      }
      if (bodyWords <= 0) continue;
      chapters.add(
        LocalChapterIndex(
          h.title,
          h.content,
          end - h.content,
          volume: h.volume ? '' : volume,
          byteOffset: h.contentBytes,
          byteLength: (next?.startBytes ?? byteLength) - h.contentBytes,
        ),
      );
    }
    if (chapters.isEmpty) {
      return [
        LocalChapterIndex(
          '正文',
          0,
          length,
          byteOffset: 0,
          byteLength: byteLength,
        ),
      ];
    }
    if (!validChapterRanges(chapters, length)) {
      throw StateError('Invalid chapter ranges');
    }
    return List.unmodifiable(chapters);
  }
}

List<LocalChapterIndex> splitLocalChapters(
  String normalizedText, {
  bool enableChapterExtensions = defaultChapterExtensionsEnabled,
}) => (ChapterTextIndex(
  enableChapterExtensions: enableChapterExtensions,
)..add(normalizedText)).finish();

/// Built-in TXT TOC rule presets inspired by legado-E's `txtTocRule.json`.
enum TxtTocRulePreset {
  auto('智能识别（默认）', '', '多族启发式自动识别章节与卷名'),
  standard(
    '标准章节（第X章/回/话/节）',
    r'^[ \t　]*(?:【[^】\n]{1,32}】|《[^》\n]{1,32}》)?[ \t　]*[（(【\[]?第[ \t　]*[0-9０-９一二三四五六七八九十百千萬万零〇两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟廿卅卌\u2160-\u217F\u2460-\u2473\-~～—–─━、,，/至到]+[ \t　]*[章节節回囘话話幕折卷捲部集篇季期更段册冊编編輯辑讲講场場局夜曲弹彈].*$',
    '第1章 标题 / 第一百零二回 标题',
  ),
  numbered(
    '序号与括号标题（1. / (1) / 【01】）',
    r'^[ \t　]*(?:(?:【[^】\n]{1,32}】|《[^》\n]{1,32}》|[^\n。！？!?，,；;：:“”‘’【】《》（）()]{1,24})[ \t　]*)?(?:[（(【\[［〖〔《「『][ \t　]*[0-9０-９一二三四五六七八九十百千万零〇两\u2160-\u217F\u2460-\u2473\-~～—–─━、,，/至到]+[ \t　]*[）)】\]］〗〕》」』]|[0-9０-９一二三四五六七八九十百千万零〇两\u2160-\u217F\u2460-\u2473]{1,6}[、.．:： \t　]).{0,40}$',
    '1. 标题 / （12）标题 / 【01】标题',
  ),
  symbol(
    '特殊符号标题（===标题=== / ***标题）',
    r'^[ \t　]*(?:={2,6}|[*＊☆◆●—\-─━]{2,6})[ \t　]*[^=\n*＊]{1,40}?[ \t　]*={0,6}$',
    '=== 第一章 === / *** 楔子 ***',
  ),
  fixedLength(
    '按字数自动分节（无目录小说）',
    '__fixed_length__',
    '按约 8000 字在自然段边界自动切分章节',
  );

  const TxtTocRulePreset(this.label, this.pattern, this.example);
  final String label;
  final String pattern;
  final String example;
}

/// Subdivides any chapter whose UTF-16 length exceeds [maxChapterChars] at
/// natural newline boundaries (`\n`), preserving exact UTF-16 and UTF-8 ranges.
List<LocalChapterIndex> subdivideOversizedChapters(
  String normalizedText,
  List<LocalChapterIndex> chapters, {
  int maxChapterChars = 12000,
}) {
  if (maxChapterChars <= 0 || normalizedText.isEmpty) return chapters;
  final result = <LocalChapterIndex>[];
  for (final ch in chapters) {
    if (ch.length <= maxChapterChars) {
      result.add(ch);
      continue;
    }
    final chapterEnd = (ch.offset + ch.length).clamp(0, normalizedText.length);
    var cursor = ch.offset.clamp(0, chapterEnd);
    var byteCursor = ch.byteOffset >= 0
        ? ch.byteOffset
        : utf8.encode(normalizedText.substring(0, cursor)).length;
    var partIndex = 1;
    while (cursor < chapterEnd) {
      final remaining = chapterEnd - cursor;
      if (remaining <= maxChapterChars) {
        final slice = normalizedText.substring(cursor, chapterEnd);
        final sliceBytes = utf8.encode(slice).length;
        result.add(
          LocalChapterIndex(
            partIndex == 1 ? ch.title : '${ch.title}（$partIndex）',
            cursor,
            remaining,
            volume: ch.volume,
            byteOffset: byteCursor,
            byteLength: sliceBytes,
          ),
        );
        break;
      }
      var target = cursor + maxChapterChars;
      // Prefer splitting right after a newline near target.
      var newline = normalizedText.indexOf('\n', target);
      if (newline < 0 || newline >= chapterEnd || newline - target > 2000) {
        newline = normalizedText.lastIndexOf('\n', target);
      }
      var splitAt = (newline > cursor && newline < chapterEnd)
          ? newline + 1
          : target;
      if (splitAt > cursor && splitAt < chapterEnd) {
        final prevUnit = normalizedText.codeUnitAt(splitAt - 1);
        final nextUnit = normalizedText.codeUnitAt(splitAt);
        if (prevUnit >= 0xD800 &&
            prevUnit <= 0xDBFF &&
            nextUnit >= 0xDC00 &&
            nextUnit <= 0xDFFF) {
          splitAt--;
          if (splitAt <= cursor) {
            splitAt = math.min(chapterEnd, target + 1);
          }
        }
      }
      final slice = normalizedText.substring(cursor, splitAt);
      final sliceBytes = utf8.encode(slice).length;
      result.add(
        LocalChapterIndex(
          '${ch.title}（$partIndex）',
          cursor,
          splitAt - cursor,
          volume: ch.volume,
          byteOffset: byteCursor,
          byteLength: sliceBytes,
        ),
      );
      cursor = splitAt;
      byteCursor += sliceBytes;
      partIndex++;
    }
  }
  return result.isEmpty ? chapters : List.unmodifiable(result);
}

/// Splits [normalizedText] using either a custom regex [customPattern],
/// fixed-length segmentation (`__fixed_length__`), or the default heuristic
/// splitter, optionally subdividing chapters larger than [maxChapterChars].
List<LocalChapterIndex> splitLocalChaptersCustom(
  String normalizedText, {
  String? customPattern,
  int maxChapterChars = 0,
  bool enableChapterExtensions = defaultChapterExtensionsEnabled,
}) {
  final pattern = customPattern?.trim() ?? '';
  if (pattern == TxtTocRulePreset.fixedLength.pattern) {
    final fullBytes = utf8.encode(normalizedText).length;
    final single = [
      LocalChapterIndex(
        '正文',
        0,
        normalizedText.length,
        byteOffset: 0,
        byteLength: fullBytes,
      ),
    ];
    return subdivideOversizedChapters(
      normalizedText,
      single,
      maxChapterChars: maxChapterChars > 0 ? maxChapterChars : 8000,
    );
  }
  if (pattern.isEmpty) {
    final base = splitLocalChapters(
      normalizedText,
      enableChapterExtensions: enableChapterExtensions,
    );
    return maxChapterChars > 0
        ? subdivideOversizedChapters(
            normalizedText,
            base,
            maxChapterChars: maxChapterChars,
          )
        : base;
  }

  final regExp = RegExp(pattern, multiLine: true);
  final rawChapters = <LocalChapterIndex>[];
  var lineStart = 0;
  var lineByteStart = 0;
  final matches = <({String title, int start, int content, int startBytes, int contentBytes})>[];

  while (lineStart <= normalizedText.length) {
    final nl = normalizedText.indexOf('\n', lineStart);
    final lineEnd = nl < 0 ? normalizedText.length : nl;
    final nextStart = nl < 0 ? normalizedText.length : nl + 1;
    final line = normalizedText.substring(lineStart, lineEnd);
    final lineBytes = utf8.encode(line).length + (nl < 0 ? 0 : 1);
    final nextBytes = lineByteStart + lineBytes;
    final trimmed = line.trim();
    if (trimmed.isNotEmpty && trimmed.length <= 120 && regExp.hasMatch(line)) {
      matches.add((
        title: trimmed,
        start: lineStart,
        content: nextStart,
        startBytes: lineByteStart,
        contentBytes: nextBytes,
      ));
    }
    lineStart = nextStart;
    lineByteStart = nextBytes;
    if (nl < 0) break;
  }

  final totalBytes = lineByteStart;
  if (matches.isEmpty) {
    final fallback = [
      LocalChapterIndex(
        '正文',
        0,
        normalizedText.length,
        byteOffset: 0,
        byteLength: totalBytes,
      ),
    ];
    return maxChapterChars > 0
        ? subdivideOversizedChapters(
            normalizedText,
            fallback,
            maxChapterChars: maxChapterChars,
          )
        : fallback;
  }

  if (matches.first.start > 0 &&
      normalizedText.substring(0, matches.first.start).trim().isNotEmpty) {
    rawChapters.add(
      LocalChapterIndex(
        '前言',
        0,
        matches.first.start,
        byteOffset: 0,
        byteLength: matches.first.startBytes,
      ),
    );
  }

  for (var i = 0; i < matches.length; i++) {
    final m = matches[i];
    final next = i + 1 < matches.length ? matches[i + 1] : null;
    final end = next?.start ?? normalizedText.length;
    final endBytes = next?.startBytes ?? totalBytes;
    if (end <= m.content) continue;
    rawChapters.add(
      LocalChapterIndex(
        m.title,
        m.content,
        end - m.content,
        byteOffset: m.contentBytes,
        byteLength: endBytes - m.contentBytes,
      ),
    );
  }

  if (rawChapters.isEmpty) {
    return [
      LocalChapterIndex(
        '正文',
        0,
        normalizedText.length,
        byteOffset: 0,
        byteLength: totalBytes,
      ),
    ];
  }

  return maxChapterChars > 0
      ? subdivideOversizedChapters(
          normalizedText,
          rawChapters,
          maxChapterChars: maxChapterChars,
        )
      : List.unmodifiable(rawChapters);
}
