import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

/// Supported raster comic page extensions (all natively decoded by `dart:ui`).
const comicImageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
};

const _ebookExtensions = <String>{
  '.epub',
  '.pdf',
  '.mobi',
  '.azw3',
  '.azw',
  '.prc',
  '.fb2',
  '.docx',
};

const _unsupportedArchiveExtensions = <String>{
  '.cbr',
  '.cb7',
  '.cbt',
  '.rar',
  '.7z',
};

const _categoryFolderNames = <String>{
  '漫画',
  '漫畫',
  '条漫',
  '條漫',
  '韩漫',
  '韓漫',
  '日漫',
  '国漫',
  '國漫',
  '美漫',
  '单行本',
  '單行本',
  '本子',
  '连载',
  '連載',
  '完结',
  '完結',
  '全彩',
  '小说',
  '小說',
  'comic',
  'comics',
  'manga',
  'manhua',
  'manhwa',
  'webtoon',
  'webtoons',
  'novel',
  'novels',
  'pdf',
  'cbz',
  'epub',
  'zip',
  'books',
  'book',
  '书库',
  '書庫',
  '本地书库',
  'download',
  'downloads',
};

final _explicitComicHintPattern = RegExp(
  r'(漫画|漫畫|条漫|條漫|四格漫|韩漫|韓漫|日漫|国漫|國漫|美漫|全彩|彩色版|黑白版|单行本|單行本|画集|畫集)'
  r'|(?<![a-z0-9])(comic|comics|manga|manhua|manhwa|webtoon|webtoons)(?![a-z0-9])'
  r'|\d{3,5}\s*[xX×]\s*\d{3,5}',
  caseSensitive: false,
);

/// Returns true if [pathOrName] explicitly indicates comic/manga content
/// (e.g. `漫画`, `全彩`, `manga`, or image dimensions like `[2080×3000]`).
bool hasExplicitComicPathHint(String pathOrName) {
  if (pathOrName.trim().isEmpty) return false;
  return _explicitComicHintPattern.hasMatch(pathOrName);
}

const maxComicArchiveEntries = 20000;
const maxComicPageBytes = 64 * 1024 * 1024;
const maxComicXmlBytes = 2 * 1024 * 1024;
const maxComicTotalUncompressedBytes = 4 * 1024 * 1024 * 1024;

bool isCbzFileName(String name) => name.toLowerCase().endsWith('.cbz');

bool isZipFileName(String name) => name.toLowerCase().endsWith('.zip');

bool isComicInfoFileName(String name) =>
    _leafName(name).toLowerCase() == 'comicinfo.xml';

bool isUnsupportedComicArchiveFileName(String name) {
  final lower = name.toLowerCase();
  return _unsupportedArchiveExtensions.any(lower.endsWith);
}

bool isComicImageFileName(String name) {
  final leaf = _leafName(name);
  if (leaf.isEmpty || leaf.startsWith('.') || leaf.startsWith('._')) {
    return false;
  }
  final lower = leaf.toLowerCase();
  if (lower == 'thumbs.db' || lower == 'desktop.ini' || lower == '.ds_store') {
    return false;
  }
  final dot = lower.lastIndexOf('.');
  if (dot <= 0) return false;
  return comicImageExtensions.contains(lower.substring(dot));
}

bool _isEbookContainerFileName(String name) {
  final lower = _leafName(name).toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot <= 0) return false;
  return _ebookExtensions.contains(lower.substring(dot));
}

String _leafName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

String _parentDir(String normalizedPath) {
  final slash = normalizedPath.lastIndexOf('/');
  return slash < 0 ? '' : normalizedPath.substring(0, slash);
}

String stripComicExtension(String fileName) {
  final leaf = _leafName(fileName);
  return leaf.replaceFirst(
    RegExp(r'\.(cbz|zip|cbr|cb7|epub|pdf)$', caseSensitive: false),
    '',
  );
}

/// Normalizes an archive or folder relative path. Returns `''` if unsafe.
String normalizeComicEntryPath(String raw) {
  var path = raw.replaceAll('\\', '/').trim();
  while (path.startsWith('./')) {
    path = path.substring(2);
  }
  while (path.startsWith('/')) {
    path = path.substring(1);
  }
  if (path.isEmpty) return '';
  final parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') return '';
    parts.add(part);
  }
  return parts.join('/');
}

bool isIgnoredComicEntryPath(String normalizedPath) {
  if (normalizedPath.isEmpty) return true;
  for (final segment in normalizedPath.split('/')) {
    if (segment.isEmpty ||
        segment.startsWith('.') ||
        segment.startsWith('._')) {
      return true;
    }
    final lower = segment.toLowerCase();
    if (lower == '__macosx' ||
        lower == 'thumbs.db' ||
        lower == 'desktop.ini') {
      return true;
    }
  }
  return false;
}

const _chineseDigitValues = <int, int>{
  0x96F6: 0, // 零
  0x3007: 0, // 〇
  0x4E00: 1, // 一
  0x4E8C: 2, // 二
  0x4E24: 2, // 两
  0x5169: 2, // 兩
  0x4E09: 3, // 三
  0x56DB: 4, // 四
  0x4E94: 5, // 五
  0x516D: 6, // 六
  0x4E03: 7, // 七
  0x516B: 8, // 八
  0x4E5D: 9, // 九
};

int? _parseChineseInt(String token) {
  if (token.isEmpty) return null;
  var total = 0;
  var section = 0;
  var current = 0;
  var hasAny = false;
  for (final rune in token.runes) {
    final digit = _chineseDigitValues[rune];
    if (digit != null) {
      current = digit;
      hasAny = true;
      continue;
    }
    final unit = switch (rune) {
      0x5341 => 10, // 十
      0x767E => 100, // 百
      0x5343 => 1000, // 千
      _ => null,
    };
    if (unit != null) {
      hasAny = true;
      section += (current == 0 ? 1 : current) * unit;
      current = 0;
      continue;
    }
    if (rune == 0x4E07) {
      // 万
      hasAny = true;
      section += current;
      total += (section == 0 ? 1 : section) * 10000;
      section = 0;
      current = 0;
      continue;
    }
    return null;
  }
  if (!hasAny) return null;
  return total + section + current;
}

final _cjkChapterNumberPattern = RegExp(
  r'(第\s*)([零〇一二两兩三四五六七八九十百千万]+)(\s*[话話章卷回集册冊季部篇])',
);

String _normalizeSortableText(String input) {
  // Convert full-width digits ０-９ to ASCII 0-9 and Chinese chapter numbers.
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0xFF10 && rune <= 0xFF19) {
      buffer.writeCharCode(rune - 0xFF10 + 0x30);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  final halfWidth = buffer.toString();
  if (!halfWidth.contains('第')) return halfWidth;
  return halfWidth.replaceAllMapped(_cjkChapterNumberPattern, (match) {
    final parsed = _parseChineseInt(match.group(2)!);
    if (parsed == null) return match.group(0)!;
    return '${match.group(1)}$parsed${match.group(3)}';
  });
}

bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// Natural alphanumeric comparator (`1.jpg < 2.jpg < 10.jpg`, `第一话 < 第十话`).
int compareComicNaturalOrder(String a, String b) {
  if (a == b) return 0;
  final na = _normalizeSortableText(a).toLowerCase();
  final nb = _normalizeSortableText(b).toLowerCase();
  var ia = 0;
  var ib = 0;
  while (ia < na.length && ib < nb.length) {
    final ca = na.codeUnitAt(ia);
    final cb = nb.codeUnitAt(ib);
    if (_isAsciiDigit(ca) && _isAsciiDigit(cb)) {
      var za = ia;
      while (za < na.length && na.codeUnitAt(za) == 0x30) {
        za++;
      }
      var ea = za;
      while (ea < na.length && _isAsciiDigit(na.codeUnitAt(ea))) {
        ea++;
      }
      var zb = ib;
      while (zb < nb.length && nb.codeUnitAt(zb) == 0x30) {
        zb++;
      }
      var eb = zb;
      while (eb < nb.length && _isAsciiDigit(nb.codeUnitAt(eb))) {
        eb++;
      }
      final lenA = ea - za;
      final lenB = eb - zb;
      if (lenA != lenB) return lenA.compareTo(lenB);
      for (var k = 0; k < lenA; k++) {
        final da = na.codeUnitAt(za + k);
        final db = nb.codeUnitAt(zb + k);
        if (da != db) return da.compareTo(db);
      }
      // Same numeric value: fewer leading zeros (or shorter raw token) tie-break.
      final rawLenA = ea - ia;
      final rawLenB = eb - ib;
      if (rawLenA != rawLenB) return rawLenA.compareTo(rawLenB);
      ia = ea;
      ib = eb;
      continue;
    }
    if (ca != cb) return ca.compareTo(cb);
    ia++;
    ib++;
  }
  if (na.length != nb.length) return na.length.compareTo(nb.length);
  return a.compareTo(b);
}

/// Compares `/` separated entry paths naturally segment by segment.
int compareComicEntryPaths(String a, String b) {
  if (a == b) return 0;
  final pa = a.split('/');
  final pb = b.split('/');
  final minLen = pa.length < pb.length ? pa.length : pb.length;
  for (var i = 0; i < minLen; i++) {
    final isFileA = i == pa.length - 1;
    final isFileB = i == pb.length - 1;
    if (isFileA != isFileB) {
      // Loose root files (like 000_cover.jpg) come before subdirectories.
      return isFileA ? -1 : 1;
    }
    final cmp = compareComicNaturalOrder(pa[i], pb[i]);
    if (cmp != 0) return cmp;
  }
  return pa.length.compareTo(pb.length);
}

/// Parsed `ComicInfo.xml` metadata (ComicRack / Kavita / Komga standard).
class ComicInfoMetadata {
  const ComicInfoMetadata({
    this.title,
    this.series,
    this.number,
    this.volume,
    this.writer,
    this.summary,
    this.genre,
    this.isMangaRtl,
    this.frontCoverImageIndex,
    this.pageBookmarks = const <int, String>{},
  });

  final String? title;
  final String? series;
  final String? number;
  final String? volume;
  final String? writer;
  final String? summary;
  final String? genre;
  final bool? isMangaRtl;
  final int? frontCoverImageIndex;
  final Map<int, String> pageBookmarks;

  String? get displayTitle {
    final s = series?.trim();
    final t = title?.trim();
    final v = volume?.trim();
    final n = number?.trim();
    if (s != null && s.isNotEmpty) {
      if (t != null && t.isNotEmpty && t != s) {
        return t.startsWith(s) ? t : '$s - $t';
      }
      if (v != null && v.isNotEmpty && v != '-1') {
        return '$s 第$v卷';
      }
      if (n != null && n.isNotEmpty && n != '-1') {
        return '$s #$n';
      }
      return s;
    }
    if (t != null && t.isNotEmpty) return t;
    return null;
  }

  static ComicInfoMetadata? tryParseBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxComicXmlBytes) return null;
    try {
      final text = utf8.decode(bytes, allowMalformed: true);
      return tryParseXml(text);
    } catch (_) {
      return null;
    }
  }

  static ComicInfoMetadata? tryParseXml(String xmlText) {
    if (xmlText.trim().isEmpty || xmlText.length > maxComicXmlBytes) {
      return null;
    }
    try {
      final doc = XmlDocument.parse(xmlText);
      final root = doc.rootElement;
      if (root.name.local.toLowerCase() != 'comicinfo') return null;

      String? readTag(String lowerName) {
        for (final child in root.children.whereType<XmlElement>()) {
          if (child.name.local.toLowerCase() == lowerName) {
            final value = child.innerText.trim();
            if (value.isNotEmpty) return value;
          }
        }
        return null;
      }

      final writer = readTag('writer') ??
          readTag('penciller') ??
          readTag('artist') ??
          readTag('author');
      final mangaRaw = readTag('manga')?.toLowerCase();
      final bool? isMangaRtl = switch (mangaRaw) {
        'yesandrighttoleft' || 'yes' || 'true' => true,
        'no' || 'false' => false,
        _ => null,
      };

      int? frontCover;
      final bookmarks = <int, String>{};
      for (final pagesEl in root.children.whereType<XmlElement>()) {
        if (pagesEl.name.local.toLowerCase() != 'pages') continue;
        for (final pageEl in pagesEl.children.whereType<XmlElement>()) {
          if (pageEl.name.local.toLowerCase() != 'page') continue;
          int? imageIndex;
          String? pageType;
          String? bookmark;
          for (final attr in pageEl.attributes) {
            switch (attr.name.local.toLowerCase()) {
              case 'image':
                imageIndex = int.tryParse(attr.value.trim());
              case 'type':
                pageType = attr.value.trim();
              case 'bookmark':
                bookmark = attr.value.trim();
            }
          }
          if (imageIndex == null || imageIndex < 0) continue;
          if (frontCover == null &&
              pageType != null &&
              pageType.toLowerCase() == 'frontcover') {
            frontCover = imageIndex;
          }
          if (bookmark != null && bookmark.isNotEmpty) {
            bookmarks.putIfAbsent(imageIndex, () => bookmark!);
          }
        }
      }

      return ComicInfoMetadata(
        title: readTag('title'),
        series: readTag('series'),
        number: readTag('number'),
        volume: readTag('volume'),
        writer: writer,
        summary: readTag('summary'),
        genre: readTag('genre'),
        isMangaRtl: isMangaRtl,
        frontCoverImageIndex: frontCover,
        pageBookmarks: Map<int, String>.unmodifiable(bookmarks),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Checks magic header bytes so misnamed `.cbr`/`.cb7` files report a clear error.
void checkComicArchiveMagicBytes(List<int> prefix) {
  if (prefix.length >= 4 &&
      prefix[0] == 0x52 &&
      prefix[1] == 0x61 &&
      prefix[2] == 0x72 &&
      prefix[3] == 0x21) {
    throw const FormatException('该漫画包实际为 RAR/CBR 格式，请转换为 ZIP/CBZ 后导入');
  }
  if (prefix.length >= 6 &&
      prefix[0] == 0x37 &&
      prefix[1] == 0x7A &&
      prefix[2] == 0xBC &&
      prefix[3] == 0xAF &&
      prefix[4] == 0x27 &&
      prefix[5] == 0x1C) {
    throw const FormatException('该漫画包实际为 7z/CB7 格式，请转换为 ZIP/CBZ 后导入');
  }
}

/// Inspects a ZIP central directory without decompressing entries to decide
/// whether a `.zip` file is a single comic archive rather than a multi-book bundle.
bool isComicZipDirectory(ZipDirectory directory) {
  final headers = directory.fileHeaders;
  if (headers.isEmpty || headers.length > maxComicArchiveEntries) return false;
  var imageCount = 0;
  var hasComicInfo = false;
  var txtCount = 0;
  var maxTxtBytes = 0;
  for (final header in headers) {
    final rawName = header.filename;
    if (rawName.endsWith('/')) continue;
    final normalized = normalizeComicEntryPath(rawName);
    if (isIgnoredComicEntryPath(normalized)) continue;
    if (isComicInfoFileName(normalized)) {
      hasComicInfo = true;
      continue;
    }
    if (_isEbookContainerFileName(normalized) ||
        isCbzFileName(normalized) ||
        isZipFileName(normalized)) {
      return false;
    }
    if (normalized.toLowerCase().endsWith('.txt')) {
      txtCount++;
      final size = header.uncompressedSize;
      if (size > maxTxtBytes) maxTxtBytes = size;
      continue;
    }
    if (isComicImageFileName(normalized)) {
      imageCount++;
    }
  }
  if (imageCount <= 0) return false;
  if (hasComicInfo) return true;
  if (txtCount == 0) return true;
  return imageCount >= 3 && maxTxtBytes <= 32 * 1024;
}

/// Fast file-based check whether a `.zip` on disk is a comic archive.
Future<bool> isComicZipFile(String filePath) async {
  InputFileStream? stream;
  try {
    final file = File(filePath);
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length < 22) return false;
    stream = InputFileStream(filePath);
    final dir = ZipDirectory()..read(stream);
    return isComicZipDirectory(dir);
  } catch (_) {
    return false;
  } finally {
    await stream?.close();
  }
}

/// Fast in-memory check whether `.zip` bytes represent a single comic archive.
bool isComicZipBytes(Uint8List bytes) {
  if (bytes.length < 22) return false;
  try {
    final dir = ZipDirectory()..read(InputMemoryStream(bytes));
    return isComicZipDirectory(dir);
  } catch (_) {
    return false;
  }
}

class ComicChapterInfo {
  const ComicChapterInfo({
    required this.title,
    required this.startPage,
    required this.pageCount,
  });

  final String title;
  final int startPage;
  final int pageCount;

  int get endPage => startPage + pageCount;

  Map<String, Object?> toJson() => {
    'title': title,
    'startPage': startPage,
    'pageCount': pageCount,
  };

  factory ComicChapterInfo.fromJson(Map<String, dynamic> json) =>
      ComicChapterInfo(
        title: (json['title'] as String?) ?? '正文',
        startPage: (json['startPage'] as num?)?.toInt() ?? 0,
        pageCount: (json['pageCount'] as num?)?.toInt() ?? 0,
      );
}

bool _isCoverLikeStem(String fileName) {
  final leaf = _leafName(fileName).toLowerCase();
  final dot = leaf.lastIndexOf('.');
  final stem = dot > 0 ? leaf.substring(0, dot) : leaf;
  return stem == 'cover' ||
      stem == 'folder' ||
      stem == 'front' ||
      stem == 'frontcover' ||
      stem == '000_cover' ||
      stem == '00_cover' ||
      stem == '封面';
}

({
  List<String> pages,
  List<ComicChapterInfo> chapters,
  int coverPageIndex,
}) _buildArchiveStructure({
  required List<String> rawImagePaths,
  required ComicInfoMetadata? metadata,
  required String fallbackTitle,
}) {
  final byDir = <String, List<String>>{};
  for (final path in rawImagePaths) {
    byDir.putIfAbsent(_parentDir(path), () => <String>[]).add(path);
  }
  final sortedDirs = byDir.keys.toList()
    ..sort((a, b) {
      if (a.isEmpty) return -1;
      if (b.isEmpty) return 1;
      return compareComicEntryPaths(a, b);
    });
  for (final list in byDir.values) {
    list.sort((a, b) => compareComicNaturalOrder(_leafName(a), _leafName(b)));
  }

  final pages = <String>[
    for (final dir in sortedDirs) ...byDir[dir]!,
  ];

  // Build chapters from ComicInfo bookmarks when present, otherwise from subdirs.
  final chapters = <ComicChapterInfo>[];
  final bookmarks = metadata?.pageBookmarks ?? const <int, String>{};
  final validBookmarks = bookmarks.entries
      .where((e) => e.key >= 0 && e.key < pages.length)
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  if (validBookmarks.isNotEmpty) {
    if (validBookmarks.first.key > 0) {
      chapters.add(
        ComicChapterInfo(
          title: '序章',
          startPage: 0,
          pageCount: validBookmarks.first.key,
        ),
      );
    }
    for (var i = 0; i < validBookmarks.length; i++) {
      final start = validBookmarks[i].key;
      final end = i + 1 < validBookmarks.length
          ? validBookmarks[i + 1].key
          : pages.length;
      if (end > start) {
        chapters.add(
          ComicChapterInfo(
            title: validBookmarks[i].value,
            startPage: start,
            pageCount: end - start,
          ),
        );
      }
    }
  } else if (sortedDirs.length >= 2) {
    // Disambiguate duplicate leaf folder names (e.g. Vol.1/Ch.1 vs Vol.2/Ch.1).
    final leafCounts = <String, int>{};
    for (final dir in sortedDirs) {
      if (dir.isEmpty) continue;
      final leaf = _leafName(dir);
      leafCounts[leaf] = (leafCounts[leaf] ?? 0) + 1;
    }
    var offset = 0;
    for (final dir in sortedDirs) {
      final dirPages = byDir[dir]!;
      final String title;
      if (dir.isEmpty) {
        title = dirPages.length <= 2 ? '封面' : '本篇';
      } else {
        final leaf = _leafName(dir);
        title = (leafCounts[leaf] ?? 0) > 1
            ? dir.replaceAll('/', ' · ')
            : leaf;
      }
      chapters.add(
        ComicChapterInfo(
          title: title,
          startPage: offset,
          pageCount: dirPages.length,
        ),
      );
      offset += dirPages.length;
    }
  } else {
    chapters.add(
      ComicChapterInfo(
        title: (metadata?.displayTitle?.trim().isNotEmpty ?? false)
            ? metadata!.displayTitle!.trim()
            : (fallbackTitle.trim().isNotEmpty ? fallbackTitle.trim() : '全一卷'),
        startPage: 0,
        pageCount: pages.length,
      ),
    );
  }

  int coverPageIndex = 0;
  final explicitCover = metadata?.frontCoverImageIndex;
  if (explicitCover != null &&
      explicitCover >= 0 &&
      explicitCover < pages.length) {
    coverPageIndex = explicitCover;
  } else {
    final limit = pages.length < 10 ? pages.length : 10;
    for (var i = 0; i < limit; i++) {
      if (_isCoverLikeStem(pages[i])) {
        coverPageIndex = i;
        break;
      }
    }
  }

  return (
    pages: List<String>.unmodifiable(pages),
    chapters: List<ComicChapterInfo>.unmodifiable(chapters),
    coverPageIndex: coverPageIndex,
  );
}

/// Streaming CBZ / ZIP comic reader backed by `ZipDirectory` without unpacking
/// the entire archive into memory.
class ComicArchivePackage {
  ComicArchivePackage._({
    required InputStream stream,
    required Map<String, ZipFileHeader> headers,
    required this.title,
    required this.author,
    required this.summary,
    required this.isRtl,
    required this.pages,
    required this.chapters,
    required this.coverPageIndex,
    required this.metadata,
  }) : _stream = stream,
       _headers = headers;

  final InputStream _stream;
  final Map<String, ZipFileHeader> _headers;
  final String title;
  final String author;
  final String summary;
  final bool? isRtl;
  final List<String> pages;
  final List<ComicChapterInfo> chapters;
  final int coverPageIndex;
  final ComicInfoMetadata? metadata;
  bool _closed = false;

  int get pageCount => pages.length;

  String get coverEntry => pages[coverPageIndex];

  static Future<ComicArchivePackage> openFile(
    String filePath, {
    String? fallbackTitle,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw const FormatException('漫画文件不存在');
    }
    final prefix = await file.openRead(0, 8).fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    checkComicArchiveMagicBytes(prefix);
    final stream = InputFileStream(filePath);
    try {
      return _openFromStream(
        stream,
        fallbackTitle: fallbackTitle ?? stripComicExtension(filePath),
      );
    } catch (_) {
      await stream.close();
      rethrow;
    }
  }

  static ComicArchivePackage openBytes(
    Uint8List bytes, {
    String fallbackTitle = '本地漫画',
  }) {
    checkComicArchiveMagicBytes(bytes.take(8).toList());
    final stream = InputMemoryStream(bytes);
    return _openFromStream(stream, fallbackTitle: fallbackTitle);
  }

  static ComicArchivePackage _openFromStream(
    InputStream stream, {
    required String fallbackTitle,
  }) {
    final ZipDirectory directory;
    try {
      directory = ZipDirectory()..read(stream);
    } catch (_) {
      throw const FormatException('无法解析漫画压缩包（仅支持标准 ZIP / CBZ 格式）');
    }
    if (directory.fileHeaders.length > maxComicArchiveEntries) {
      throw const FormatException('漫画压缩包内文件数量超出安全上限');
    }

    final headers = <String, ZipFileHeader>{};
    final imagePaths = <String>[];
    String? comicInfoPath;
    var comicInfoDepth = 999;
    var totalUncompressed = 0;

    for (final header in directory.fileHeaders) {
      final rawName = header.filename;
      if (rawName.endsWith('/')) continue;
      // Reject Unix symlinks stored in ZIP external attributes.
      final unixMode = (header.externalFileAttributes >> 16) & 0xF000;
      if (unixMode == 0xA000) continue;

      final normalized = normalizeComicEntryPath(rawName);
      if (isIgnoredComicEntryPath(normalized)) continue;

      final size = header.uncompressedSize;
      if (size < 0 || size > maxComicPageBytes) {
        if (isComicImageFileName(normalized)) {
          throw const FormatException('漫画单页图片体积超出 64 MiB 安全上限');
        }
        continue;
      }
      totalUncompressed += size;
      if (totalUncompressed > maxComicTotalUncompressedBytes) {
        throw const FormatException('漫画压缩包解压总大小超出安全上限');
      }

      if (isComicInfoFileName(normalized)) {
        final depth = '/'.allMatches(normalized).length;
        if (depth < comicInfoDepth) {
          comicInfoDepth = depth;
          comicInfoPath = normalized;
        }
        headers[normalized] = header;
        continue;
      }

      if (isComicImageFileName(normalized)) {
        if (headers.putIfAbsent(normalized, () => header) == header) {
          imagePaths.add(normalized);
        }
      }
    }

    if (imagePaths.isEmpty) {
      throw const FormatException('漫画包中未找到受支持的图片页（JPG/PNG/WebP/GIF/BMP）');
    }

    ComicInfoMetadata? metadata;
    if (comicInfoPath != null) {
      final xmlBytes = _readHeaderBytes(headers[comicInfoPath]!, maxComicXmlBytes);
      if (xmlBytes != null) {
        metadata = ComicInfoMetadata.tryParseBytes(xmlBytes);
      }
    }

    final cleanFallback = fallbackTitle.trim().isEmpty
        ? '本地漫画'
        : fallbackTitle.trim();
    final structure = _buildArchiveStructure(
      rawImagePaths: imagePaths,
      metadata: metadata,
      fallbackTitle: cleanFallback,
    );

    final resolvedTitle = (metadata?.displayTitle?.trim().isNotEmpty ?? false)
        ? metadata!.displayTitle!.trim()
        : cleanFallback;
    final resolvedAuthor = (metadata?.writer?.trim().isNotEmpty ?? false)
        ? metadata!.writer!.trim()
        : '本地导入';
    final resolvedSummary = metadata?.summary?.trim() ?? '';

    return ComicArchivePackage._(
      stream: stream,
      headers: headers,
      title: resolvedTitle,
      author: resolvedAuthor,
      summary: resolvedSummary,
      isRtl: metadata?.isMangaRtl,
      pages: structure.pages,
      chapters: structure.chapters,
      coverPageIndex: structure.coverPageIndex,
      metadata: metadata,
    );
  }

  static Uint8List? _readHeaderBytes(ZipFileHeader header, int maxBytes) {
    final expected = header.uncompressedSize;
    if (expected < 0 || expected > maxBytes) return null;
    final file = header.file;
    if (file == null) return null;
    Uint8List content;
    try {
      content = file.readBytes();
      if (content.isEmpty && expected == 0 && file.compressedSize > 0) {
        final saved = file.uncompressedSize;
        try {
          file.uncompressedSize = maxBytes;
          content = file.readBytes();
        } finally {
          file.uncompressedSize = saved;
        }
      }
    } catch (_) {
      final saved = file.uncompressedSize;
      try {
        file.uncompressedSize = maxBytes;
        content = file.readBytes();
      } finally {
        file.uncompressedSize = saved;
      }
    }
    if (content.length > maxBytes) return null;
    return content;
  }

  Uint8List readPageSync(int pageIndex) {
    if (_closed) throw StateError('ComicArchivePackage is already closed');
    if (pageIndex < 0 || pageIndex >= pages.length) {
      throw RangeError.index(pageIndex, pages, 'pageIndex');
    }
    return readEntrySync(pages[pageIndex]);
  }

  Uint8List readEntrySync(String entryPath) {
    if (_closed) throw StateError('ComicArchivePackage is already closed');
    final header = _headers[entryPath];
    if (header == null) {
      throw FormatException('未找到漫画页面：$entryPath');
    }
    final bytes = _readHeaderBytes(header, maxComicPageBytes);
    if (bytes == null || bytes.isEmpty) {
      throw FormatException('漫画页面无法读取或超出大小上限：$entryPath');
    }
    return bytes;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _stream.close();
  }
}

/// A single page entry inside a folder-based comic.
class ComicFolderPageEntry {
  const ComicFolderPageEntry({
    required this.uri,
    required this.name,
    required this.size,
    required this.modifiedMs,
    this.relPath = '',
  });

  /// Either a SAF document `content://...` URI or an absolute local file path.
  final String uri;
  final String name;
  final String relPath;
  final int size;
  final int modifiedMs;

  Map<String, Object?> toJson() => {
    'uri': uri,
    'name': name,
    if (relPath.isNotEmpty) 'relPath': relPath,
    'size': size,
    'modifiedMs': modifiedMs,
  };

  factory ComicFolderPageEntry.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] as String?) ?? '';
    return ComicFolderPageEntry(
      uri: (json['uri'] as String?) ?? '',
      name: name,
      relPath: (json['relPath'] as String?) ?? name,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modifiedMs: (json['modifiedMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Persisted manifest for a local image-folder comic (single-volume or multi-chapter).
class ComicFolderManifest {
  const ComicFolderManifest({
    required this.folderKey,
    required this.folderUri,
    required this.title,
    required this.author,
    required this.summary,
    required this.isRtl,
    required this.pages,
    required this.chapters,
    required this.coverPageIndex,
    this.folderRelPath = '',
    this.comicInfoUri,
  });

  final String folderKey;
  final String folderUri;
  final String folderRelPath;
  final String? comicInfoUri;
  final String title;
  final String author;
  final String summary;
  final bool? isRtl;
  final List<ComicFolderPageEntry> pages;
  final List<ComicChapterInfo> chapters;
  final int coverPageIndex;

  int get pageCount => pages.length;

  int get totalBytes =>
      pages.fold<int>(0, (sum, entry) => sum + entry.size);

  int get latestModifiedMs => pages.fold<int>(
    0,
    (maxMs, entry) => entry.modifiedMs > maxMs ? entry.modifiedMs : maxMs,
  );

  ComicFolderPageEntry get coverPage => pages[coverPageIndex];

  Map<String, Object?> toJson() => {
    'version': 1,
    'folderKey': folderKey,
    'folderUri': folderUri,
    'folderRelPath': folderRelPath,
    if (comicInfoUri != null && comicInfoUri!.isNotEmpty)
      'comicInfoUri': comicInfoUri,
    'title': title,
    'author': author,
    'summary': summary,
    if (isRtl != null) 'isRtl': isRtl,
    'coverPageIndex': coverPageIndex,
    'chapters': [for (final c in chapters) c.toJson()],
    'pages': [for (final p in pages) p.toJson()],
  };

  factory ComicFolderManifest.fromJson(Map<String, dynamic> json) {
    final rawPages = (json['pages'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map>()
        .map((m) => ComicFolderPageEntry.fromJson(Map<String, dynamic>.from(m)))
        .where((p) => p.uri.isNotEmpty)
        .toList();
    if (rawPages.isEmpty) {
      throw const FormatException('漫画目录清单为空');
    }
    final rawChapters =
        (json['chapters'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map>()
            .map((m) => ComicChapterInfo.fromJson(Map<String, dynamic>.from(m)))
            .where((c) => c.pageCount > 0 && c.startPage >= 0)
            .toList();
    final chapters = rawChapters.isNotEmpty
        ? rawChapters
        : <ComicChapterInfo>[
            ComicChapterInfo(
              title: (json['title'] as String?) ?? '全一卷',
              startPage: 0,
              pageCount: rawPages.length,
            ),
          ];
    final rawCover = (json['coverPageIndex'] as num?)?.toInt() ?? 0;
    final coverIndex = rawCover >= 0 && rawCover < rawPages.length
        ? rawCover
        : 0;
    return ComicFolderManifest(
      folderKey: (json['folderKey'] as String?) ?? '',
      folderUri: (json['folderUri'] as String?) ?? '',
      folderRelPath: (json['folderRelPath'] as String?) ?? '',
      comicInfoUri: json['comicInfoUri'] as String?,
      title: (json['title'] as String?) ?? '本地漫画',
      author: (json['author'] as String?) ?? '本地导入',
      summary: (json['summary'] as String?) ?? '',
      isRtl: json['isRtl'] as bool?,
      pages: List<ComicFolderPageEntry>.unmodifiable(rawPages),
      chapters: List<ComicChapterInfo>.unmodifiable(chapters),
      coverPageIndex: coverIndex,
    );
  }
}

/// Candidate file entry produced by either SAF tree scan or app-folder directory walk.
class ScannedFolderEntry {
  const ScannedFolderEntry({
    required this.uri,
    required this.name,
    required this.relPath,
    required this.size,
    required this.modifiedMs,
    this.parentUri,
  });

  final String uri;
  final String name;
  final String relPath;
  final int size;
  final int modifiedMs;
  final String? parentUri;
}

final _pureChapterLabelPattern = RegExp(
  r'^('
  r'[\[\(【（]?\s*\d+(\.\d+)?(\s*[-~_]\s*\d+(\.\d+)?)?\s*[\]\)】）]?(\s*[话話章卷回集册冊pP])?$'
  r'|第\s*[\d零〇一二两兩三四五六七八九十百千万]+(\.\d+)?\s*[话話章卷回集册冊季部篇].*'
  r'|[卷话話章回集册冊]\s*[\d零〇一二两兩三四五六七八九十百千万]+.*'
  r'|(ch|chap|chapter|vol|volume|ep|episode|part|stage|act|file|case|round)[\s._#-]*\d+.*'
  r'|(番外|特别篇|特別篇|外传|外傳|序章|序话|最終話|最终话|单行本|單行本|附录|附錄|特典|omake|extra|special|oneshot|prologue|epilogue).*'
  r'|[上中下前后全][卷篇册冊部集]$'
  r')$',
  caseSensitive: false,
);

bool _isPureChapterDirName(String leafName) {
  final trimmed = leafName.trim();
  if (trimmed.isEmpty) return false;
  return _pureChapterLabelPattern.hasMatch(trimmed);
}

bool _isCategoryFolderName(String leafName) =>
    _categoryFolderNames.contains(leafName.trim().toLowerCase());

final _leadingBracketTagsPattern = RegExp(
  r'^(\s*[\[\(【（][^\]\)】）]*[\]\)】）]\s*)+',
);

String _stripLeadingBracketTags(String text) =>
    text.replaceFirst(_leadingBracketTagsPattern, '').trim();

String _sharedLeadingTitlePrefix(List<String> names) {
  if (names.length < 2) return '';
  final cleaned = [
    for (final name in names)
      (_stripLeadingBracketTags(name).isNotEmpty
          ? _stripLeadingBracketTags(name)
          : name.trim()),
  ];
  final first = cleaned.first;
  var prefixLen = first.length;
  for (var i = 1; i < cleaned.length && prefixLen > 0; i++) {
    final other = cleaned[i];
    final limit = prefixLen < other.length ? prefixLen : other.length;
    var j = 0;
    while (j < limit && first.codeUnitAt(j) == other.codeUnitAt(j)) {
      j++;
    }
    prefixLen = j;
  }
  final raw = first.substring(0, prefixLen).trim();
  return _stripLeadingBracketTags(raw);
}

/// Groups scanned image files into single-volume or multi-chapter [ComicFolderManifest]
/// entries while ignoring stray cover images sitting next to ebook files.
List<ComicFolderManifest> groupScannedComicFolders({
  required List<ScannedFolderEntry> entries,
  required String rootKeyPrefix,
  required String rootFolderUri,
  required String rootDisplayName,
  Map<String, String> dirUrisByRelPath = const <String, String>{},
  List<String> nonImageRelPaths = const <String>[],
}) {
  final imagesByDir = <String, List<ScannedFolderEntry>>{};
  final comicInfoByDir = <String, ScannedFolderEntry>{};
  final dirsWithBooks = <String>{};

  for (final rawNonImg in nonImageRelPaths) {
    final rel = normalizeComicEntryPath(rawNonImg);
    if (isIgnoredComicEntryPath(rel)) continue;
    final leaf = _leafName(rel);
    if (leaf.toLowerCase().endsWith('.txt') ||
        _isEbookContainerFileName(leaf) ||
        isCbzFileName(leaf) ||
        isZipFileName(leaf)) {
      dirsWithBooks.add(_parentDir(rel));
    }
  }

  for (final entry in entries) {
    final rel = normalizeComicEntryPath(entry.relPath);
    if (isIgnoredComicEntryPath(rel)) continue;
    final dir = _parentDir(rel);
    final leaf = entry.name.isNotEmpty ? entry.name : _leafName(rel);

    if (isComicInfoFileName(leaf)) {
      comicInfoByDir.putIfAbsent(dir, () => entry);
      continue;
    }
    if (leaf.toLowerCase().endsWith('.txt') ||
        _isEbookContainerFileName(leaf) ||
        isCbzFileName(leaf) ||
        isZipFileName(leaf)) {
      dirsWithBooks.add(dir);
      continue;
    }
    if (isComicImageFileName(leaf) && entry.size > 0) {
      imagesByDir.putIfAbsent(dir, () => <ScannedFolderEntry>[]).add(entry);
    }
  }

  if (imagesByDir.isEmpty) return const [];

  // Filter out stray 1-2 cover/illustration images sitting alongside novel files.
  final validImageDirs = <String>{};
  for (final mapEntry in imagesByDir.entries) {
    final dir = mapEntry.key;
    final imgs = mapEntry.value;
    if (dirsWithBooks.contains(dir) &&
        imgs.length < 3 &&
        !comicInfoByDir.containsKey(dir)) {
      continue;
    }
    imgs.sort((a, b) => compareComicNaturalOrder(a.name, b.name));
    validImageDirs.add(dir);
  }
  if (validImageDirs.isEmpty) return const [];

  // Group candidate leaf directories by their parent directory to detect multi-chapter series.
  final childrenByParent = <String, List<String>>{};
  for (final dir in validImageDirs) {
    if (dir.isEmpty) continue;
    final parent = _parentDir(dir);
    childrenByParent.putIfAbsent(parent, () => <String>[]).add(dir);
  }

  final consumedDirs = <String>{};
  final seriesGroups = <String, List<String>>{}; // seriesDir -> ordered member dirs

  // Evaluate deeper parents first so nested `Category/Series/Ch1` merges into `Series`,
  // not `Category`.
  final candidateParents = childrenByParent.keys.toList()
    ..sort((a, b) => '/'.allMatches(b).length.compareTo('/'.allMatches(a).length));

  for (final parent in candidateParents) {
    final childDirs = childrenByParent[parent]!
        .where((d) => !consumedDirs.contains(d))
        .toList();
    if (childDirs.isEmpty) continue;

    final parentLeaf = parent.isEmpty ? rootDisplayName : _leafName(parent);
    final isCategory = _isCategoryFolderName(parentLeaf);
    final parentHasComicInfo = comicInfoByDir.containsKey(parent);
    final parentDirectImages = validImageDirs.contains(parent)
        ? imagesByDir[parent]!
        : const <ScannedFolderEntry>[];
    final parentHasOnlyCoverImages =
        parentDirectImages.isNotEmpty &&
        parentDirectImages.length <= 2 &&
        parentDirectImages.every((e) => _isCoverLikeStem(e.name));
    final parentHasBooks = dirsWithBooks.contains(parent);

    final childLeaves = [for (final d in childDirs) _leafName(d)];
    final pureChapterCount =
        childLeaves.where(_isPureChapterDirName).length;
    final majorityPureChapters =
        pureChapterCount * 2 >= childLeaves.length && pureChapterCount > 0;

    final sharedPrefix = _sharedLeadingTitlePrefix(childLeaves);
    final lowerParentLeaf = parentLeaf.trim().toLowerCase();
    final childrenMatchParentName = lowerParentLeaf.length >= 2 &&
        !isCategory &&
        childLeaves.where((n) => n.toLowerCase().contains(lowerParentLeaf)).length *
                2 >=
            childLeaves.length;
    final childrenShareSeriesStem =
        !isCategory && sharedPrefix.length >= 3 && childLeaves.length >= 2;

    final bool shouldMerge;
    if (parentHasComicInfo || parentHasOnlyCoverImages) {
      shouldMerge = !parentHasBooks;
    } else if (parent.isEmpty) {
      // Root folder picked by user: only merge if subfolders are clearly chapters
      // (or match root folder's non-category series name) and root has no loose ebooks.
      shouldMerge = !parentHasBooks &&
          !isCategory &&
          (majorityPureChapters ||
              (childDirs.length >= 2 && childrenMatchParentName));
    } else {
      shouldMerge = !parentHasBooks &&
          !isCategory &&
          (majorityPureChapters ||
              childrenMatchParentName ||
              childrenShareSeriesStem);
    }

    if (!shouldMerge) continue;

    childDirs.sort(compareComicEntryPaths);
    final members = <String>[
      if (validImageDirs.contains(parent) && !consumedDirs.contains(parent))
        parent,
      ...childDirs,
    ];
    for (final m in members) {
      consumedDirs.add(m);
    }
    seriesGroups[parent] = members;
  }

  // Remaining unconsumed image directories each become a single-volume comic book.
  for (final dir in validImageDirs) {
    if (consumedDirs.contains(dir)) continue;
    seriesGroups[dir] = <String>[dir];
  }

  final sortedSeriesDirs = seriesGroups.keys.toList()
    ..sort((a, b) {
      if (a.isEmpty) return -1;
      if (b.isEmpty) return 1;
      return compareComicEntryPaths(a, b);
    });

  final results = <ComicFolderManifest>[];
  for (final seriesDir in sortedSeriesDirs) {
    final memberDirs = seriesGroups[seriesDir]!;
    final title = seriesDir.isEmpty
        ? (rootDisplayName.trim().isNotEmpty ? rootDisplayName.trim() : '本地漫画')
        : _leafName(seriesDir);

    final pages = <ComicFolderPageEntry>[];
    final chapters = <ComicChapterInfo>[];
    for (final dir in memberDirs) {
      final dirImages = imagesByDir[dir]!;
      final start = pages.length;
      for (final img in dirImages) {
        pages.add(
          ComicFolderPageEntry(
            uri: img.uri,
            name: img.name,
            relPath: normalizeComicEntryPath(img.relPath),
            size: img.size,
            modifiedMs: img.modifiedMs,
          ),
        );
      }
      if (memberDirs.length == 1) {
        chapters.add(
          ComicChapterInfo(
            title: title,
            startPage: 0,
            pageCount: dirImages.length,
          ),
        );
      } else {
        final chapterTitle = dir == seriesDir
            ? (dirImages.length <= 2 ? '封面' : '本篇')
            : dir.substring(seriesDir.isEmpty ? 0 : seriesDir.length + 1).replaceAll('/', ' · ');
        chapters.add(
          ComicChapterInfo(
            title: chapterTitle,
            startPage: start,
            pageCount: dirImages.length,
          ),
        );
      }
    }

    var coverIndex = 0;
    final scanLimit = pages.length < 10 ? pages.length : 10;
    for (var i = 0; i < scanLimit; i++) {
      if (_isCoverLikeStem(pages[i].name)) {
        coverIndex = i;
        break;
      }
    }

    final resolvedFolderUri = dirUrisByRelPath[seriesDir] ??
        (memberDirs.length == 1
            ? (imagesByDir[memberDirs.first]!.first.parentUri ?? rootFolderUri)
            : rootFolderUri);
    final folderKey = seriesDir.isEmpty
        ? '$rootKeyPrefix#comic_root'
        : '$rootKeyPrefix#comic_dir:$seriesDir';
    final comicInfo = comicInfoByDir[seriesDir] ??
        (memberDirs.isNotEmpty ? comicInfoByDir[memberDirs.first] : null);

    results.add(
      ComicFolderManifest(
        folderKey: folderKey,
        folderUri: resolvedFolderUri,
        folderRelPath: seriesDir,
        comicInfoUri: comicInfo?.uri,
        title: title,
        author: '本地漫画目录',
        summary: '',
        isRtl: null,
        pages: List<ComicFolderPageEntry>.unmodifiable(pages),
        chapters: List<ComicChapterInfo>.unmodifiable(chapters),
        coverPageIndex: coverIndex,
      ),
    );
  }

  return results;
}

/// Applies parsed [ComicInfoMetadata] onto an initial [ComicFolderManifest].
ComicFolderManifest applyMetadataToFolderManifest(
  ComicFolderManifest base,
  ComicInfoMetadata metadata,
) {
  final resolvedTitle = (metadata.displayTitle?.trim().isNotEmpty ?? false)
      ? metadata.displayTitle!.trim()
      : base.title;
  final resolvedAuthor = (metadata.writer?.trim().isNotEmpty ?? false)
      ? metadata.writer!.trim()
      : base.author;
  final resolvedSummary = (metadata.summary?.trim().isNotEmpty ?? false)
      ? metadata.summary!.trim()
      : base.summary;
  final explicitCover = metadata.frontCoverImageIndex;
  final resolvedCover = explicitCover != null &&
          explicitCover >= 0 &&
          explicitCover < base.pages.length
      ? explicitCover
      : base.coverPageIndex;

  var resolvedChapters = base.chapters;
  if (base.chapters.length == 1 && metadata.pageBookmarks.isNotEmpty) {
    final validBookmarks = metadata.pageBookmarks.entries
        .where((e) => e.key >= 0 && e.key < base.pages.length)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (validBookmarks.isNotEmpty) {
      final built = <ComicChapterInfo>[];
      if (validBookmarks.first.key > 0) {
        built.add(
          ComicChapterInfo(
            title: '序章',
            startPage: 0,
            pageCount: validBookmarks.first.key,
          ),
        );
      }
      for (var i = 0; i < validBookmarks.length; i++) {
        final start = validBookmarks[i].key;
        final end = i + 1 < validBookmarks.length
            ? validBookmarks[i + 1].key
            : base.pages.length;
        if (end > start) {
          built.add(
            ComicChapterInfo(
              title: validBookmarks[i].value,
              startPage: start,
              pageCount: end - start,
            ),
          );
        }
      }
      if (built.isNotEmpty) {
        resolvedChapters = List<ComicChapterInfo>.unmodifiable(built);
      }
    }
  }

  return ComicFolderManifest(
    folderKey: base.folderKey,
    folderUri: base.folderUri,
    folderRelPath: base.folderRelPath,
    comicInfoUri: base.comicInfoUri,
    title: resolvedTitle,
    author: resolvedAuthor,
    summary: resolvedSummary,
    isRtl: metadata.isMangaRtl ?? base.isRtl,
    pages: base.pages,
    chapters: resolvedChapters,
    coverPageIndex: resolvedCover,
  );
}

/// Persisted volume entry inside a [ComicSeriesManifest] (e.g. `Mgf_01.pdf` .. `Mgf_14.pdf`).
class ComicSeriesVolumeEntry {
  const ComicSeriesVolumeEntry({
    required this.uri,
    required this.name,
    required this.relPath,
    required this.kind,
    required this.size,
    required this.modifiedMs,
    required this.startPage,
    required this.pageCount,
    this.title = '',
    this.coverEntry,
    this.epubPages = const <String>[],
  });

  final String uri;
  final String name;
  final String relPath;

  /// `'pdf'`, `'cbz'`, or `'epub'`.
  final String kind;
  final int size;
  final int modifiedMs;
  final int startPage;
  final int pageCount;
  final String title;

  /// Optional cover entry path inside CBZ/ZIP archive or EPUB package.
  final String? coverEntry;

  /// Ordered image entry paths inside an EPUB volume when `kind == 'epub'`.
  final List<String> epubPages;

  String get displayTitle =>
      title.trim().isNotEmpty ? title.trim() : stripComicExtension(name);

  Map<String, Object?> toJson() => {
    'uri': uri,
    'name': name,
    'relPath': relPath,
    'kind': kind,
    'size': size,
    'modifiedMs': modifiedMs,
    'startPage': startPage,
    'pageCount': pageCount,
    if (title.isNotEmpty) 'title': title,
    if (coverEntry != null && coverEntry!.isNotEmpty) 'coverEntry': coverEntry,
    if (epubPages.isNotEmpty) 'epubPages': epubPages,
  };

  factory ComicSeriesVolumeEntry.fromJson(Map<String, dynamic> json) {
    final rawEpubPages =
        (json['epubPages'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toList();
    return ComicSeriesVolumeEntry(
      uri: (json['uri'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      relPath: (json['relPath'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? 'pdf',
      size: (json['size'] as num?)?.toInt() ?? 0,
      modifiedMs: (json['modifiedMs'] as num?)?.toInt() ?? 0,
      startPage: (json['startPage'] as num?)?.toInt() ?? 0,
      pageCount: (json['pageCount'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?) ?? '',
      coverEntry: json['coverEntry'] as String?,
      epubPages: List<String>.unmodifiable(rawEpubPages),
    );
  }
}

/// Persisted manifest for a multi-volume comic series grouped from multiple
/// `.pdf` / `.cbz` / `.zip` / `.epub` files in the same folder.
class ComicSeriesManifest {
  const ComicSeriesManifest({
    required this.seriesKey,
    required this.folderUri,
    required this.title,
    required this.author,
    required this.summary,
    required this.isRtl,
    required this.volumes,
    required this.chapters,
    this.folderRelPath = '',
    this.comicInfoUri,
  });

  final String seriesKey;
  final String folderUri;
  final String folderRelPath;
  final String? comicInfoUri;
  final String title;
  final String author;
  final String summary;
  final bool? isRtl;
  final List<ComicSeriesVolumeEntry> volumes;
  final List<ComicChapterInfo> chapters;

  int get pageCount => volumes.fold<int>(0, (sum, v) => sum + v.pageCount);

  int get totalBytes => volumes.fold<int>(0, (sum, v) => sum + v.size);

  int get latestModifiedMs => volumes.fold<int>(
    0,
    (maxMs, v) => v.modifiedMs > maxMs ? v.modifiedMs : maxMs,
  );

  /// Binary-searches the volume containing [globalPage] (0-indexed) and returns
  /// `(volume, localPage)`. Returns `null` if [globalPage] is out of range.
  ({ComicSeriesVolumeEntry volume, int localPage})? resolveGlobalPage(
    int globalPage,
  ) {
    if (globalPage < 0 || volumes.isEmpty) return null;
    var lo = 0;
    var hi = volumes.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final vol = volumes[mid];
      if (globalPage < vol.startPage) {
        hi = mid - 1;
      } else if (globalPage >= vol.startPage + vol.pageCount) {
        lo = mid + 1;
      } else {
        return (volume: vol, localPage: globalPage - vol.startPage);
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'seriesKey': seriesKey,
    'folderUri': folderUri,
    'folderRelPath': folderRelPath,
    if (comicInfoUri != null && comicInfoUri!.isNotEmpty)
      'comicInfoUri': comicInfoUri,
    'title': title,
    'author': author,
    'summary': summary,
    if (isRtl != null) 'isRtl': isRtl,
    'chapters': [for (final c in chapters) c.toJson()],
    'volumes': [for (final v in volumes) v.toJson()],
  };

  factory ComicSeriesManifest.fromJson(Map<String, dynamic> json) {
    final rawVolumes =
        (json['volumes'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map>()
            .map(
              (m) =>
                  ComicSeriesVolumeEntry.fromJson(Map<String, dynamic>.from(m)),
            )
            .where((v) => v.uri.isNotEmpty && v.pageCount > 0)
            .toList();
    if (rawVolumes.isEmpty) {
      throw const FormatException('多卷漫画清单为空');
    }
    final rawChapters =
        (json['chapters'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map>()
            .map((m) => ComicChapterInfo.fromJson(Map<String, dynamic>.from(m)))
            .where((c) => c.pageCount > 0 && c.startPage >= 0)
            .toList();
    final chapters = rawChapters.isNotEmpty
        ? rawChapters
        : <ComicChapterInfo>[
            for (final v in rawVolumes)
              ComicChapterInfo(
                title: v.displayTitle,
                startPage: v.startPage,
                pageCount: v.pageCount,
              ),
          ];
    return ComicSeriesManifest(
      seriesKey: (json['seriesKey'] as String?) ?? '',
      folderUri: (json['folderUri'] as String?) ?? '',
      folderRelPath: (json['folderRelPath'] as String?) ?? '',
      comicInfoUri: json['comicInfoUri'] as String?,
      title: (json['title'] as String?) ?? '本地漫画',
      author: (json['author'] as String?) ?? '本地多卷漫画',
      summary: (json['summary'] as String?) ?? '',
      isRtl: json['isRtl'] as bool?,
      volumes: List<ComicSeriesVolumeEntry>.unmodifiable(rawVolumes),
      chapters: List<ComicChapterInfo>.unmodifiable(chapters),
    );
  }
}

/// Candidate multi-volume comic series grouped during folder scan before opening
/// individual volume containers.
class ComicSeriesCandidate {
  const ComicSeriesCandidate({
    required this.seriesKey,
    required this.folderUri,
    required this.folderRelPath,
    required this.title,
    required this.files,
    this.comicInfoUri,
  });

  final String seriesKey;
  final String folderUri;
  final String folderRelPath;
  final String title;
  final List<ScannedFolderEntry> files;
  final String? comicInfoUri;

  int get totalBytes => files.fold<int>(0, (sum, f) => sum + f.size);

  int get latestModifiedMs => files.fold<int>(
    0,
    (maxMs, f) => f.modifiedMs > maxMs ? f.modifiedMs : maxMs,
  );
}

final _resolutionTagPattern = RegExp(r'\d{3,5}\s*[xX×]\s*\d{3,5}');
final _copyDuplicateSuffixPattern = RegExp(r'^(.*\S)\s*\((\d{1,3})\)$');

final _volumeMarkerPattern = RegExp(
  r'第\s*[\d零〇一二两兩三四五六七八九十百千万]+(?:\.\d+)?\s*[话話章卷回集册冊季部篇]'
  r'|[卷话話章回集册冊]\s*[\d零〇一二两兩三四五六七八九十百千万]+'
  r'|[上中下前后全][卷篇册冊部集]$'
  r'|(?<![a-z0-9])(vol|volume|ch|chap|chapter|ep|episode|part|book)[\s._#-]*\d+'
  r'|(?:^|[\s._\-\[\(【（#vV])\d{1,4}(?:\.\d+)?(?:\s*[-~]\s*\d{1,4})?(?:[\]\)】）\s]|[话話章卷回集册冊]|$)'
  r'|(?<=[\u4e00-\u9fff\u3040-\u30ff])\d{1,4}(?:\.\d+)?$',
  caseSensitive: false,
);

final _trailingVolumeSuffixPattern = RegExp(
  r'[\s._\-~·:：]*[\[\(【（]?\s*(?:'
  r'第\s*[\d零〇一二两兩三四五六七八九十百千万]+(?:\.\d+)?\s*[话話章卷回集册冊季部篇].*'
  r'|[卷话話章回集册冊]\s*[\d零〇一二两兩三四五六七八九十百千万]+.*'
  r'|(?:vol|volume|ch|chap|chapter|ep|episode|part|book)[\s._#-]*\d+(?:\.\d+)?.*'
  r'|[上中下前后][卷篇册冊部集]'
  r'|\d{1,4}(?:\.\d+)?(?:\s*[-~]\s*\d{1,4})?\s*[话話章卷回集册冊]?'
  r')\s*[\]\)】）]?\s*$',
  caseSensitive: false,
);

String _cleanVolumeCandidateStem(String fileName) {
  var stem = stripComicExtension(fileName).trim();
  final tagIdx = stem.indexOf(' ✦');
  if (tagIdx > 0) {
    stem = stem.substring(0, tagIdx).trim();
  }
  return stem;
}

bool _hasVolumeOrChapterMarker(String stem, Set<String> lowerStemsInDir) {
  final trimmed = stem.trim();
  if (trimmed.isEmpty) return false;
  // Exclude browser/OS duplicate copy names like `手册 (1)` when `手册` exists in the same folder.
  final copyMatch = _copyDuplicateSuffixPattern.firstMatch(trimmed);
  if (copyMatch != null) {
    final base = copyMatch.group(1)!.trim().toLowerCase();
    if (lowerStemsInDir.contains(base)) {
      return false;
    }
  }
  final withoutRes = trimmed.replaceAll(_resolutionTagPattern, ' ').trim();
  if (withoutRes.isEmpty) return false;
  if (_isPureChapterDirName(withoutRes) ||
      _isPureChapterDirName(_stripLeadingBracketTags(withoutRes))) {
    return true;
  }
  return _volumeMarkerPattern.hasMatch(withoutRes);
}

String _extractNormalizedSeriesStem(String stem) {
  var cleaned = stem.replaceAll(_resolutionTagPattern, '').trim();
  final withoutTags = _stripLeadingBracketTags(cleaned);
  if (withoutTags.isNotEmpty) {
    cleaned = withoutTags;
  }
  final stripped = cleaned.replaceFirst(_trailingVolumeSuffixPattern, '').trim();
  return stripped
      .replaceAll(RegExp(r'^[\s._\-~·:：]+|[\s._\-~·:：]+$'), '')
      .trim();
}

String _cleanSeriesFolderTitle(String rawFolderName) {
  final raw = rawFolderName.trim();
  if (raw.isEmpty) return '本地漫画';
  var cleaned = raw;
  final withoutLeading = _stripLeadingBracketTags(cleaned).trim();
  if (withoutLeading.isNotEmpty) {
    cleaned = withoutLeading;
  }
  final trailingFormatPattern = RegExp(
    r'(?:\s+|(?<=[\]】\)）]))(?:pdf|cbz|zip|epub|mobi|azw3)\s*$',
    caseSensitive: false,
  );
  final trailingBracketTagsPattern = RegExp(
    r'(?:\s*[\[【][^\]】]{1,48}[\]】])+\s*$',
  );
  for (var i = 0; i < 3; i++) {
    final prev = cleaned;
    final strippedFormat = cleaned.replaceFirst(trailingFormatPattern, '').trim();
    if (strippedFormat.isNotEmpty) {
      cleaned = strippedFormat;
    }
    final strippedBrackets = cleaned
        .replaceFirst(trailingBracketTagsPattern, '')
        .trim();
    if (strippedBrackets.isNotEmpty) {
      cleaned = strippedBrackets;
    }
    if (cleaned == prev) break;
  }
  cleaned = cleaned
      .replaceAll(RegExp(r'^[\s._\-~·:：]+|[\s._\-~·:：]+$'), '')
      .trim();
  return cleaned.isNotEmpty ? cleaned : raw;
}

bool _isEligibleSeriesVolumeFile(
  String leafName, {
  required bool isMangaRoot,
  required bool dirHasComicHint,
}) {
  final lower = leafName.toLowerCase();
  if (lower.endsWith('.cbz')) return true;
  if (lower.endsWith('.pdf') ||
      lower.endsWith('.zip') ||
      lower.endsWith('.epub')) {
    return isMangaRoot || dirHasComicHint || hasExplicitComicPathHint(leafName);
  }
  return false;
}

/// Groups multiple comic volume files (`.pdf`, `.cbz`, `.zip`, `.epub`) inside the
/// same series folder into ordered [ComicSeriesCandidate] entries and returns any
/// remaining ungrouped files.
({
  List<ComicSeriesCandidate> seriesGroups,
  List<ScannedFolderEntry> remainingEntries,
})
groupScannedComicVolumeSeries({
  required List<ScannedFolderEntry> entries,
  required bool isMangaRoot,
  required String rootKeyPrefix,
  required String rootFolderUri,
  required String rootDisplayName,
  Map<String, String> dirUrisByRelPath = const <String, String>{},
  Map<String, String> comicInfoUrisByDir = const <String, String>{},
}) {
  if (entries.length < 2) {
    return (seriesGroups: const [], remainingEntries: entries);
  }

  final comicInfoByDir = <String, String>{...comicInfoUrisByDir};
  final candidatesByDir = <String, List<ScannedFolderEntry>>{};

  for (final entry in entries) {
    final rel = normalizeComicEntryPath(entry.relPath);
    if (isIgnoredComicEntryPath(rel)) continue;
    final dir = _parentDir(rel);
    final leaf = entry.name.isNotEmpty ? entry.name : _leafName(rel);
    if (isComicInfoFileName(leaf)) {
      comicInfoByDir.putIfAbsent(dir, () => entry.uri);
      continue;
    }
    if (entry.size <= 0) continue;
    final dirHasHint =
        dir.isNotEmpty &&
        (hasExplicitComicPathHint(dir) || comicInfoByDir.containsKey(dir));
    if (_isEligibleSeriesVolumeFile(
      leaf,
      isMangaRoot: isMangaRoot,
      dirHasComicHint: dirHasHint,
    )) {
      candidatesByDir.putIfAbsent(dir, () => <ScannedFolderEntry>[]).add(entry);
    }
  }

  if (candidatesByDir.isEmpty) {
    return (seriesGroups: const [], remainingEntries: entries);
  }

  final consumedUris = <String>{};
  final results = <ComicSeriesCandidate>[];
  final sortedDirs = candidatesByDir.keys.toList()
    ..sort((a, b) {
      if (a.isEmpty) return -1;
      if (b.isEmpty) return 1;
      return compareComicEntryPaths(a, b);
    });

  for (final dir in sortedDirs) {
    final dirFiles = candidatesByDir[dir]!;
    if (dirFiles.length < 2) continue;

    final parentLeaf = dir.isEmpty ? rootDisplayName : _leafName(dir);
    final isCategory = _isCategoryFolderName(parentLeaf);
    final stems = [
      for (final f in dirFiles)
        _cleanVolumeCandidateStem(f.name.isNotEmpty ? f.name : _leafName(f.relPath)),
    ];
    final lowerStemSet = {for (final s in stems) s.toLowerCase()};
    final numberedFlags = [
      for (final s in stems) _hasVolumeOrChapterMarker(s, lowerStemSet),
    ];
    final numberedCount = numberedFlags.where((v) => v).length;
    final pureVolumeCount = stems
        .where(
          (s) =>
              _isPureChapterDirName(s) ||
              _isPureChapterDirName(_stripLeadingBracketTags(s)),
        )
        .length;
    final majorityPureVolumes =
        pureVolumeCount * 2 >= stems.length && pureVolumeCount >= 2;
    final sharedPrefix = _sharedLeadingTitlePrefix(stems);
    final lowerParentLeaf = parentLeaf.trim().toLowerCase();
    final childrenMatchParentName =
        lowerParentLeaf.length >= 2 &&
        !isCategory &&
        stems.where((s) => s.toLowerCase().contains(lowerParentLeaf)).length *
                2 >=
            stems.length;

    // Pass 1: Dedicated non-category series directory (e.g. `迷宫饭[AI全彩][2080×3000]PDF/Mgf_01..14.pdf`).
    final mergeWholeDir =
        !isCategory &&
        numberedCount >= 2 &&
        numberedCount * 2 >= dirFiles.length &&
        (majorityPureVolumes ||
            sharedPrefix.length >= 2 ||
            childrenMatchParentName ||
            comicInfoByDir.containsKey(dir));

    if (mergeWholeDir) {
      final ordered = List<ScannedFolderEntry>.from(dirFiles)
        ..sort((a, b) => compareComicNaturalOrder(a.name, b.name));
      for (final f in ordered) {
        consumedUris.add(f.uri);
      }
      final title = _cleanSeriesFolderTitle(parentLeaf);
      final resolvedFolderUri =
          dirUrisByRelPath[dir] ?? ordered.first.parentUri ?? rootFolderUri;
      final seriesKey = dir.isEmpty
          ? '$rootKeyPrefix#comic_series_root'
          : '$rootKeyPrefix#comic_series:$dir';
      results.add(
        ComicSeriesCandidate(
          seriesKey: seriesKey,
          folderUri: resolvedFolderUri,
          folderRelPath: dir,
          title: title,
          files: List<ScannedFolderEntry>.unmodifiable(ordered),
          comicInfoUri: comicInfoByDir[dir],
        ),
      );
      continue;
    }

    // Pass 2: Mixed/category folder containing multiple distinct numbered series
    // (e.g. `漫画/迷宫饭 01.cbz`, `漫画/迷宫饭 02.cbz`, `漫画/孤独摇滚 01.cbz`, `漫画/孤独摇滚 02.cbz`).
    final byStem = <String, List<(ScannedFolderEntry, bool, String)>>{};
    for (var i = 0; i < dirFiles.length; i++) {
      final normStem = _extractNormalizedSeriesStem(stems[i]);
      if (normStem.length < 2 || _isCategoryFolderName(normStem)) continue;
      final key = normStem.toLowerCase();
      byStem
          .putIfAbsent(key, () => <(ScannedFolderEntry, bool, String)>[])
          .add((dirFiles[i], numberedFlags[i], normStem));
    }

    final stemKeys = byStem.keys.toList()..sort(compareComicNaturalOrder);
    for (final key in stemKeys) {
      final group = byStem[key]!;
      if (group.length < 2) continue;
      final groupNumbered = group.where((g) => g.$2).length;
      if (groupNumbered < 2 || groupNumbered * 2 < group.length) continue;

      final ordered = [for (final g in group) g.$1]
        ..sort((a, b) => compareComicNaturalOrder(a.name, b.name));
      for (final f in ordered) {
        consumedUris.add(f.uri);
      }
      final displayTitle = group.first.$3;
      final resolvedFolderUri =
          dirUrisByRelPath[dir] ?? ordered.first.parentUri ?? rootFolderUri;
      final relKey = dir.isEmpty ? key : '$dir/$key';
      results.add(
        ComicSeriesCandidate(
          seriesKey: '$rootKeyPrefix#comic_series_stem:$relKey',
          folderUri: resolvedFolderUri,
          folderRelPath: dir,
          title: displayTitle,
          files: List<ScannedFolderEntry>.unmodifiable(ordered),
        ),
      );
    }
  }

  if (results.isEmpty) {
    return (seriesGroups: const [], remainingEntries: entries);
  }

  final remaining = [
    for (final e in entries)
      if (!consumedUris.contains(e.uri) &&
          !isComicInfoFileName(
            e.name.isNotEmpty ? e.name : _leafName(e.relPath),
          ))
        e,
  ];
  return (seriesGroups: results, remainingEntries: remaining);
}

/// Applies parsed [ComicInfoMetadata] onto a [ComicSeriesManifest].
ComicSeriesManifest applyMetadataToSeriesManifest(
  ComicSeriesManifest base,
  ComicInfoMetadata metadata, {
  bool preferFolderTitle = true,
}) {
  final seriesName = metadata.series?.trim();
  final resolvedTitle = (seriesName != null && seriesName.isNotEmpty)
      ? seriesName
      : (!preferFolderTitle &&
            (metadata.displayTitle?.trim().isNotEmpty ?? false))
      ? metadata.displayTitle!.trim()
      : base.title;
  final resolvedAuthor = (metadata.writer?.trim().isNotEmpty ?? false)
      ? metadata.writer!.trim()
      : base.author;
  final resolvedSummary = (metadata.summary?.trim().isNotEmpty ?? false)
      ? metadata.summary!.trim()
      : base.summary;
  return ComicSeriesManifest(
    seriesKey: base.seriesKey,
    folderUri: base.folderUri,
    folderRelPath: base.folderRelPath,
    comicInfoUri: base.comicInfoUri,
    title: resolvedTitle,
    author: resolvedAuthor,
    summary: resolvedSummary,
    isRtl: metadata.isMangaRtl ?? base.isRtl,
    volumes: base.volumes,
    chapters: base.chapters,
  );
}

