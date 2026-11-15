import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../catalog.dart';
import 'book_source.dart';
import 'rule_engine.dart';

class NormalizedChapterEntry {
  const NormalizedChapterEntry({
    required this.chapter,
    required this.url,
  });

  final NovelChapter chapter;
  final String url;
}

/// Normalizes raw scraped TOC entries into stable, deduplicated, positive-ID
/// [NovelChapter] lists ready for [OfflineCacheStore] and [LibraryState].
abstract final class ChapterNormalizer {
  /// Computes a deterministic 31-bit positive integer (`1 .. 0x7fffffff`) from
  /// [canonicalUrl], probing linearly if [usedIds] already contains the hash.
  static int deterministicChapterId(String canonicalUrl, Set<int> usedIds) {
    final digest = sha256.convert(utf8.encode(canonicalUrl)).bytes;
    var candidate =
        ((digest[0] & 0x7f) << 24) |
        (digest[1] << 16) |
        (digest[2] << 8) |
        digest[3];
    if (candidate <= 0) candidate = 1;
    while (!usedIds.add(candidate)) {
      candidate = candidate >= 0x7ffffffe ? 1 : candidate + 1;
    }
    return candidate;
  }

  static String canonicalizeChapterUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return rawUrl.trim();
    final cleaned = uri.hasFragment ? uri.removeFragment() : uri;
    return cleaned.toString();
  }

  /// Normalizes volume grouping, deduplicates preview headers ("最新章节" lists
  /// duplicated at the top of Biquge-style TOC pages), detects/applies reverse
  /// order, and assigns deterministic chapter IDs.
  static List<NormalizedChapterEntry> normalize(
    List<RawExtractedChapter> rawList, {
    TocReverseMode reverseMode = TocReverseMode.auto,
  }) {
    if (rawList.isEmpty) return const [];

    // 1. Attach volume labels and canonicalize URLs.
    var currentVolume = '';
    final staged = <({String title, String url, String volume})>[];
    for (final raw in rawList) {
      if (raw.isVolume || raw.url.trim().isEmpty) {
        if (raw.title.trim().isNotEmpty) {
          currentVolume = raw.title.trim();
        }
        continue;
      }
      final url = canonicalizeChapterUrl(raw.url);
      if (url.isEmpty) continue;
      staged.add((
        title: raw.title.trim(),
        url: url,
        volume: currentVolume,
      ));
    }
    if (staged.isEmpty) return const [];

    // 2. Smart Biquge-style leading preview deduplication:
    // Many novel sites render the latest N chapters at the very top of the TOC
    // page and repeat them at the bottom of the full chapter list. If a leading
    // prefix consists of URLs that reappear later in the TOC (and starts with a
    // newer chapter number or adjacent duplicate), drop the leading preview so
    // those chapters remain in their true position at the end of the book.
    var startOffset = 0;
    if (staged.length >= 4) {
      final lastIndexByUrl = <String, int>{
        for (var i = 0; i < staged.length; i++) staged[i].url: i,
      };
      final maxPreviewWindow = (staged.length ~/ 2).clamp(1, 20);
      var candidateOffset = 0;
      while (candidateOffset < maxPreviewWindow &&
          (lastIndexByUrl[staged[candidateOffset].url] ?? candidateOffset) >
              candidateOffset) {
        candidateOffset++;
      }
      if (candidateOffset > 0 && candidateOffset < staged.length) {
        final firstLastIdx = lastIndexByUrl[staged.first.url] ?? 0;
        final firstNum = extractChapterNumber(staged.first.title);
        final realStartNum = extractChapterNumber(
          staged[candidateOffset].title,
        );
        final isAdjacentDup = candidateOffset == 1 && firstLastIdx == 1;
        final isPreviewAheadOfStart =
            firstNum == null || realStartNum == null || firstNum > realStartNum;
        if (isAdjacentDup || isPreviewAheadOfStart) {
          startOffset = candidateOffset;
        }
      }
    }

    final deduped = <({String title, String url, String volume})>[];
    final seenUrls = <String>{};
    for (var i = startOffset; i < staged.length; i++) {
      final item = staged[i];
      if (seenUrls.add(item.url)) {
        deduped.add(item);
      }
    }
    if (deduped.isEmpty) return const [];

    // 3. Apply explicit or automatic reverse detection.
    final shouldReverse = switch (reverseMode) {
      TocReverseMode.descending => true,
      TocReverseMode.ascending => false,
      TocReverseMode.auto => _looksDescendingOrder(deduped),
    };
    final ordered = shouldReverse ? deduped.reversed.toList() : deduped;

    // 4. Assign deterministic 31-bit chapter IDs.
    final usedIds = <int>{};
    return [
      for (final entry in ordered)
        NormalizedChapterEntry(
          chapter: NovelChapter(
            entry.title,
            '',
            id: deterministicChapterId(entry.url, usedIds),
            volume: entry.volume,
          ),
          url: entry.url,
        ),
    ];
  }

  static final RegExp _chapterOrdinalPattern = RegExp(
    r'(?:第\s*([0-9一二三四五六七八九十百千万零〇两]+)\s*[章节话話回卷集]|^\s*([0-9]{1,5})(?:[\.、\s_-]|$))',
  );

  static bool _looksDescendingOrder(
    List<({String title, String url, String volume})> items,
  ) {
    if (items.length < 4) return false;
    final sampleCount = items.length < 12 ? items.length : 12;
    final headNumbers = <int>[];
    for (var i = 0; i < sampleCount; i++) {
      final n = extractChapterNumber(items[i].title);
      if (n != null) headNumbers.add(n);
    }
    if (headNumbers.length < 3) return false;
    var descPairs = 0;
    var ascPairs = 0;
    for (var i = 1; i < headNumbers.length; i++) {
      if (headNumbers[i] < headNumbers[i - 1]) descPairs++;
      if (headNumbers[i] > headNumbers[i - 1]) ascPairs++;
    }
    // Only auto-reverse when overwhelmingly descending (e.g. 第300话, 第299话, 第298话)
    return descPairs >= 2 && descPairs > ascPairs * 2 && headNumbers.first > headNumbers.last;
  }

  static int? extractChapterNumber(String title) {
    final m = _chapterOrdinalPattern.firstMatch(title.trim());
    if (m == null) return null;
    final raw = (m.group(1) ?? m.group(2) ?? '').trim();
    if (raw.isEmpty) return null;
    final direct = int.tryParse(raw);
    if (direct != null) return direct;
    return _parseChineseInteger(raw);
  }

  static int? _parseChineseInteger(String text) {
    const digits = <String, int>{
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    const units = <String, int>{
      '十': 10,
      '百': 100,
      '千': 1000,
      '万': 10000,
    };
    var total = 0;
    var section = 0;
    var current = 0;
    var matchedAny = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (digits.containsKey(ch)) {
        current = digits[ch]!;
        matchedAny = true;
      } else if (units.containsKey(ch)) {
        final unit = units[ch]!;
        matchedAny = true;
        if (unit == 10000) {
          section = (section + (current == 0 ? 1 : current)) * unit;
          total += section;
          section = 0;
        } else {
          final mult = (current == 0 && unit == 10 && section == 0) ? 1 : current;
          section += mult * unit;
        }
        current = 0;
      } else {
        return null;
      }
    }
    if (!matchedAny) return null;
    return total + section + current;
  }
}
