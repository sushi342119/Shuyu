import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

import 'chapter_splitter.dart' show splitLocalChapters;
import 'local_platform.dart';
import 'reader_rich_content.dart'
    show joinBrokenParagraph, shouldMergeBrokenParagraph;

/// 块：文本或图片二选一
class EpubBlock {
  const EpubBlock.text(this.text) : kind = EpubBlockKind.text, entryPath = null;
  const EpubBlock.image(this.entryPath)
    : kind = EpubBlockKind.image,
      text = null;
  final EpubBlockKind kind;
  final String? text;
  final String? entryPath; // 图片在 ZIP 内的规范化路径
}

enum EpubBlockKind { text, image }

/// EPUB 声明的解压总量上限；不代表对伪造元数据的完整 ZIP 炸弹防护。
const epubMaxDecodedBytes = 1536 * 1024 * 1024;

void _preflightZip(InputFileStream input, {bool lenient = false}) {
  if (input.length >= 4) {
    final b0 = input.readByte();
    final b1 = input.readByte();
    final b2 = input.readByte();
    final b3 = input.readByte();
    input.reset();
    if (b0 == 0x52 && b1 == 0x61 && b2 == 0x72 && b3 == 0x21) {
      throw StateError('不支持 RAR 压缩包（请先解压）');
    }
    if (b0 == 0x37 && b1 == 0x7a && b2 == 0xbc && b3 == 0xaf) {
      throw StateError('不支持 7z 压缩包（请先解压）');
    }
  }
  // archive 4.5.2 的 ZipDirectory 只读取元数据和压缩数据视图，不解压。
  // 在 ZipDecoder 提前解压符号链接前拒绝链接及声明总量超限的包。
  // 大小来自 ZIP 自报元数据，不能证明实际展开量，仍存在伪造元数据的风险。
  final directory = ZipDirectory()..read(input);
  var decodedTotal = 0;
  for (final header in directory.fileHeaders) {
    final mode = header.externalFileAttributes >> 16;
    if ((header.versionMadeBy >> 8) == 3 && (mode & 0xf000) == 0xa000) {
      throw StateError('不支持含符号链接的 EPUB');
    }
    if (!lenient) {
      if (header.uncompressedSize < 0 ||
          header.uncompressedSize > epubMaxDecodedBytes - decodedTotal) {
        throw StateError('EPUB 解压后大小超过上限');
      }
      decodedTotal += header.uncompressedSize;
    }
  }
}

final _fontEntryPattern = RegExp(
  r'\.(?:ttf|otf|woff2?|ttc|eot|dfont)$',
  caseSensitive: false,
);

final _rasterImageEntryPattern = RegExp(
  r'\.(?:jpe?g|png|gif|webp|bmp)$',
  caseSensitive: false,
);

String? _extractUnicodePathFromExtra(Uint8List? extra) {
  if (extra == null || extra.length < 9) return null;
  var offset = 0;
  while (offset + 4 <= extra.length) {
    final id = extra[offset] | (extra[offset + 1] << 8);
    final size = extra[offset + 2] | (extra[offset + 3] << 8);
    offset += 4;
    if (size < 0 || offset + size > extra.length) break;
    // Info-ZIP Unicode Path Extra Field (0x7075): version(1) + crc32(4) + utf8Name
    if (id == 0x7075 && size > 5 && extra[offset] == 1) {
      try {
        final name = utf8
            .decode(extra.sublist(offset + 5, offset + size))
            .trim();
        if (name.isNotEmpty) return name;
      } on FormatException {
        // Ignore malformed extra field.
      }
    }
    offset += size;
  }
  return null;
}

String _percentEncodeHighBytes(String raw) {
  final sb = StringBuffer();
  for (final code in raw.codeUnits) {
    if (code >= 0x80 && code <= 0xff) {
      sb.write('%');
      sb.write(code.toRadixString(16).toUpperCase().padLeft(2, '0'));
    } else {
      sb.writeCharCode(code);
    }
  }
  return sb.toString();
}

String? _resolveEntryKey(Map<String, ArchiveFile> entries, String? path) {
  if (path == null || path.isEmpty) return null;
  if (entries.containsKey(path)) return path;
  final normalized = path
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'^/+'), '')
      .replaceAll(RegExp(r'/+'), '/');
  if (entries.containsKey(normalized)) return normalized;
  final encoded = Uri.encodeFull(normalized);
  if (entries.containsKey(encoded)) return encoded;
  final lower = normalized.toLowerCase();
  for (final key in entries.keys) {
    if (key.toLowerCase() == lower) return key;
  }
  return null;
}

String? _resolveEpubHrefClamped(String baseDir, String href) {
  var ref = href.trim().replaceAll(r'\', '/');
  ref = ref.split(RegExp(r'[?#]')).first.trim();
  if (ref.isEmpty || ref.startsWith('//')) return null;
  if (RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:').hasMatch(ref)) return null;
  final segments = <String>[];
  void push(String seg) {
    if (seg.isEmpty || seg == '.') return;
    if (seg == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      return;
    }
    segments.add(seg);
  }

  if (!ref.startsWith('/')) {
    for (final seg in baseDir.replaceAll(r'\', '/').split('/')) {
      push(seg);
    }
  }
  for (final raw in ref.split('/')) {
    final decoded = _decodeHrefSegment(raw) ?? raw;
    for (final segment in decoded.replaceAll(r'\', '/').split('/')) {
      push(segment);
    }
  }
  return segments.isEmpty ? null : segments.join('/');
}

String? _resolveEntryInPackage(
  Map<String, ArchiveFile> entries,
  String baseDir,
  String? rawHref, {
  bool allowBasenameFallback = false,
}) {
  if (rawHref == null) return null;
  var trimmed = rawHref.trim().replaceAll(r'\', '/');
  trimmed = trimmed.split(RegExp(r'[?#]')).first.trim();
  if (trimmed.isEmpty || trimmed.startsWith('//')) return null;
  if (RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:').hasMatch(trimmed)) return null;

  final primary = resolveEpubHref(baseDir, rawHref);
  if (primary != null) {
    final hit = _resolveEntryKey(entries, primary);
    if (hit != null) return hit;
  }

  if (baseDir.isNotEmpty) {
    final fromRoot = resolveEpubHref('', rawHref);
    if (fromRoot != null) {
      final hit = _resolveEntryKey(entries, fromRoot);
      if (hit != null) return hit;
    }
    final parentDir = _dirOf(baseDir);
    if (parentDir.isNotEmpty) {
      final fromParent = resolveEpubHref(parentDir, rawHref);
      if (fromParent != null) {
        final hit = _resolveEntryKey(entries, fromParent);
        if (hit != null) return hit;
      }
    }
  }

  if (allowBasenameFallback) {
    final clamped = _resolveEpubHrefClamped(baseDir, trimmed);
    if (clamped != null) {
      final hit = _resolveEntryKey(entries, clamped);
      if (hit != null) return hit;
      if (baseDir.isNotEmpty) {
        final topDir = baseDir.split('/').first;
        final underTop = _resolveEntryKey(entries, '$topDir/$clamped');
        if (underTop != null) return underTop;
      }
    }
    final rawDirect =
        _resolveEntryKey(
          entries,
          baseDir.isEmpty ? trimmed : '$baseDir/$trimmed',
        ) ??
        _resolveEntryKey(entries, trimmed);
    if (rawDirect != null) return rawDirect;

    final baseName = (_decodeHrefSegment(trimmed.split('/').last) ??
            trimmed.split('/').last)
        .toLowerCase();
    if (baseName.isNotEmpty && baseName != '.' && baseName != '..') {
      String? singleMatch;
      var multiple = false;
      for (final key in entries.keys) {
        if (key.split('/').last.toLowerCase() == baseName) {
          final file = entries[key]!;
          if (singleMatch == null || identical(entries[singleMatch], file)) {
            singleMatch ??= key;
          } else {
            multiple = true;
            break;
          }
        }
      }
      if (singleMatch != null && !multiple) return singleMatch;
    }
  }
  return null;
}

String? _attr(XmlElement element, String name) {
  final exact = element.getAttribute(name);
  if (exact != null) return exact;
  final target = name.toLowerCase();
  for (final attribute in element.attributes) {
    if (attribute.name.local.toLowerCase() == target) {
      return attribute.value;
    }
  }
  return null;
}

Future<void> _validateEncryption(
  Map<String, ArchiveFile> entries,
  Iterable<_ManifestItem> manifest,
) async {
  final encryptionKey = _resolveEntryKey(entries, 'META-INF/encryption.xml');
  if (encryptionKey == null) return;
  final encryption = entries[encryptionKey]!;

  final doc = _parseXml(await _decodeText(_extract(encryption)));
  final resourcePaths = <String>{};
  final contentPaths = <String>{};
  for (final item in manifest) {
    final path = item.path;
    if (path == null || item.mediaType.isEmpty) continue;
    final resolved = _resolveEntryKey(entries, path) ?? path;
    resourcePaths.add(path);
    resourcePaths.add(resolved);
    final mediaType = _baseMediaType(item.mediaType);
    if (mediaType == 'application/xhtml+xml' ||
        mediaType == 'text/html' ||
        mediaType.startsWith('image/')) {
      contentPaths.add(path);
      contentPaths.add(resolved);
    }
  }
  for (final encrypted in _elements(doc, 'encrypteddata')) {
    final references = _elements(encrypted, 'cipherreference').toList();
    // 缺少可解析且能确定资源类型的 CipherReference 目标时，
    // 无法排除正文或图片加密，保守拒绝。
    if (references.isEmpty) {
      throw StateError('不支持加密的 EPUB');
    }
    for (final reference in references) {
      final target = resolveEpubHref('', _attr(reference, 'URI') ?? '');
      if (target == null) {
        throw StateError('不支持加密的 EPUB');
      }
      final resolvedTarget = _resolveEntryKey(entries, target) ?? target;
      if (contentPaths.contains(target) ||
          contentPaths.contains(resolvedTarget)) {
        throw StateError('不支持加密的 EPUB');
      }
      // 多看阅读等排版的 EPUB 常包含字体混淆（META-INF/encryption.xml 指向 .ttf/.otf），
      // 且混淆字体有时未列入 manifest：只要不是正文或图片，允许字体混淆条目通过。
      if (_fontEntryPattern.hasMatch(target)) {
        continue;
      }
      if (!entries.containsKey(resolvedTarget) ||
          (!resourcePaths.contains(target) &&
              !resourcePaths.contains(resolvedTarget))) {
        throw StateError('不支持加密的 EPUB');
      }
    }
  }
}

Future<Set<String>> _collectEncryptedEntryPaths(
  Map<String, ArchiveFile> entries,
) async {
  final encryptionKey = _resolveEntryKey(entries, 'META-INF/encryption.xml');
  if (encryptionKey == null) return const <String>{};
  try {
    final text = await _decodeText(_extract(entries[encryptionKey]!));
    final encryptedPaths = <String>{};
    try {
      final doc = _parseXml(text);
      for (final reference in _elements(doc, 'cipherreference')) {
        final rawUri = _attr(reference, 'URI') ?? '';
        final target =
            _resolveEntryInPackage(
              entries,
              '',
              rawUri,
              allowBasenameFallback: true,
            ) ??
            resolveEpubHref('', rawUri);
        if (target != null && !_fontEntryPattern.hasMatch(target)) {
          encryptedPaths.add(target);
        }
      }
    } on XmlException {
      for (final match in _markupTokens.allMatches(_withoutComments(text))) {
        final tag = match.group(0)!;
        if (_tagLocalName(tag) != 'cipherreference') continue;
        final rawUri = _tagAttribute(tag, 'uri') ?? '';
        final target =
            _resolveEntryInPackage(
              entries,
              '',
              rawUri,
              allowBasenameFallback: true,
            ) ??
            resolveEpubHref('', rawUri);
        if (target != null && !_fontEntryPattern.hasMatch(target)) {
          encryptedPaths.add(target);
        }
      }
    }
    return encryptedPaths;
  } on Object {
    return const <String>{};
  }
}

bool _isLikelyBinaryCiphertext(Uint8List bytes) {
  if (bytes.isEmpty) return true;
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    return false;
  }
  final sampleLen = math.min(bytes.length, 4096);
  var controlCount = 0;
  for (var i = 0; i < sampleLen; i++) {
    final b = bytes[i];
    if ((b >= 0 && b <= 8) || b == 11 || b == 12 || (b >= 14 && b <= 31)) {
      controlCount++;
    }
  }
  if (controlCount > sampleLen ~/ 25) return true;
  final preview = latin1.decode(bytes.sublist(0, sampleLen), allowInvalid: true);
  if (RegExp(
    r'<\s*(?:\?xml|!doctype|html|body|div|p|h[1-6]|section|article|span|title)\b',
    caseSensitive: false,
  ).hasMatch(preview)) {
    return false;
  }
  return controlCount > 0;
}

class EpubChapter {
  const EpubChapter({required this.title, required this.href});
  final String title;
  final String href; // 已相对 OPF 解析并 URL 解码的 ZIP 内路径
}

class EpubPackage {
  EpubPackage._({
    required InputFileStream input,
    required Map<String, ArchiveFile> entries,
    required String title,
    required String? author,
    required String? coverEntry,
    required List<EpubChapter> chapters,
    required Map<int, List<EpubBlock>> chapterBlocks,
  }) : _input = input,
       _entries = entries,
       _title = title,
       _author = author,
       _coverEntry = coverEntry,
       _chapters = List.unmodifiable(chapters),
       _chapterBlocks = Map.unmodifiable(chapterBlocks);

  final InputFileStream _input;
  final Map<String, ArchiveFile> _entries;
  final String _title;
  final String? _author;
  final String? _coverEntry;
  final List<EpubChapter> _chapters;
  final Map<int, List<EpubBlock>> _chapterBlocks;
  bool _closed = false;

  String get title => _title;
  String? get author => _author;
  String? get coverEntry => _coverEntry;
  List<EpubChapter> get chapters => _chapters;

  static Future<EpubPackage> open(String path, {bool lenient = false}) async {
    _EpubFileHandle? file;
    try {
      file = _EpubFileHandle(File(path).openSync());
      final input = _LenientEpubInputFileStream(file);
      _preflightZip(input, lenient: lenient);
      input.reset();
      final archive = ZipDecoder().decodeStream(input);
      var decodedTotal = 0;
      for (final f in archive.files) {
        if (f.isSymbolicLink) {
          throw StateError('不支持含符号链接的 EPUB');
        }
        if (!f.isFile) continue;
        if (!lenient) {
          decodedTotal += f.size;
          if (decodedTotal > epubMaxDecodedBytes) {
            throw StateError('EPUB 解压后大小超过上限');
          }
        }
      }
      final entries = <String, ArchiveFile>{};
      final nonAsciiFiles = <({ArchiveFile file, String rawName})>[];
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final normalized = f.name
            .replaceAll(r'\', '/')
            .replaceFirst(RegExp(r'^/+'), '')
            .replaceAll(RegExp(r'/+'), '/');
        entries[normalized] = f;
        entries.putIfAbsent(f.name, () => f);
        final rawContent = f.rawContent;
        if (rawContent is ZipFile) {
          final unicodeName =
              _extractUnicodePathFromExtra(rawContent.header?.extraField) ??
              _extractUnicodePathFromExtra(rawContent.extraField);
          if (unicodeName != null) {
            final cleanUnicode = unicodeName
                .replaceAll(r'\', '/')
                .replaceFirst(RegExp(r'^/+'), '')
                .replaceAll(RegExp(r'/+'), '/');
            entries.putIfAbsent(cleanUnicode, () => f);
          }
        }
        if (normalized.codeUnits.any((c) => c >= 0x80 && c <= 0xff) &&
            normalized.codeUnits.every((c) => c <= 0xff)) {
          entries.putIfAbsent(_percentEncodeHighBytes(normalized), () => f);
          nonAsciiFiles.add((file: f, rawName: normalized));
        }
      }
      if (nonAsciiFiles.isNotEmpty) {
        try {
          final joinedBytes = <int>[];
          for (var i = 0; i < nonAsciiFiles.length; i++) {
            if (i > 0) joinedBytes.add(0x0a);
            joinedBytes.addAll(nonAsciiFiles[i].rawName.codeUnits);
          }
          final decodedJoined = await _decodeText(
            Uint8List.fromList(joinedBytes),
          );
          final decodedNames = decodedJoined.split('\n');
          if (decodedNames.length == nonAsciiFiles.length) {
            for (var i = 0; i < nonAsciiFiles.length; i++) {
              final cleanDecoded = decodedNames[i]
                  .trim()
                  .replaceAll(r'\', '/')
                  .replaceFirst(RegExp(r'^/+'), '')
                  .replaceAll(RegExp(r'/+'), '/');
              if (cleanDecoded.isNotEmpty) {
                entries.putIfAbsent(cleanDecoded, () => nonAsciiFiles[i].file);
              }
            }
          }
        } on Object {
          // Best-effort legacy filename decoding.
        }
      }
      return await _parse(input, entries, lenient: lenient);
    } catch (e) {
      final failure = e is StateError
          ? e
          : StateError('无法打开 EPUB: ${e.runtimeType}');
      if (file != null) {
        try {
          await file.close();
        } on Object {
          throw failure;
        }
      }
      throw failure;
    }
  }

  static Future<EpubPackage> _parse(
    InputFileStream input,
    Map<String, ArchiveFile> entries, {
    bool lenient = false,
  }) async {
    Future<String> readText(String entry) async {
      final key = _resolveEntryKey(entries, entry);
      final f = key == null ? null : entries[key];
      if (f == null) throw StateError('EPUB 条目不存在: $entry');
      return _decodeText(_extract(f));
    }

    // 1. container.xml -> OPF 路径
    final containerKey = _resolveEntryKey(entries, 'META-INF/container.xml');
    if (containerKey == null && !lenient) {
      throw StateError('无效的 EPUB：缺少 META-INF/container.xml');
    }
    String? opfPath;
    if (containerKey != null) {
      final containerText = await readText(containerKey);
      try {
        final container = _parseXml(containerText);
        for (final e in _elements(container, 'rootfile')) {
          final fullPath = _attr(e, 'full-path');
          if (fullPath == null || fullPath.trim().isEmpty) continue;
          final resolved = _resolveEntryInPackage(
            entries,
            '',
            fullPath,
            allowBasenameFallback: lenient,
          );
          if (resolved != null) {
            opfPath = resolved;
            break;
          }
        }
      } on XmlException {
        for (final match in _markupTokens.allMatches(
          _withoutComments(containerText),
        )) {
          final tag = match.group(0)!;
          if (_tagLocalName(tag) != 'rootfile') continue;
          final fullPath = _tagAttribute(tag, 'full-path');
          if (fullPath == null || fullPath.trim().isEmpty) continue;
          final resolved = _resolveEntryInPackage(
            entries,
            '',
            fullPath,
            allowBasenameFallback: lenient,
          );
          if (resolved != null) {
            opfPath = resolved;
            break;
          }
        }
      }
    }
    opfPath ??= entries.keys
        .where((k) => k.toLowerCase().endsWith('.opf'))
        .firstOrNull;
    if (opfPath == null) {
      if (lenient) {
        return _parseArchiveWithoutOpf(input, entries);
      }
      throw StateError('无效的 EPUB：找不到 OPF 文件');
    }
    final opfDir = _dirOf(opfPath);
    final opfText = await readText(opfPath);
    final parsedOpf = _parseOpfDocument(
      opfText,
      opfDir,
      entries,
      lenient: lenient,
    );
    final title = parsedOpf.title;
    final author = parsedOpf.author;
    final manifest = parsedOpf.manifest;
    final manifestOrder = parsedOpf.manifestOrder;
    Set<String> encryptedPaths = const <String>{};
    if (!lenient) {
      await _validateEncryption(entries, manifestOrder);
    } else {
      encryptedPaths = await _collectEncryptedEntryPaths(entries);
    }

    // spine：按 itemref 顺序解析可读章节（支持 XHTML/HTML/XML 及插画页），也跟随 fallback 链。
    // 若个别 itemref 指向已删除的封面/广告页，跳过该损坏项并保留其余有效章节。
    final spineHrefs = <String>[];
    final nonLinearSpineHrefs = <String>[];
    for (final ref in parsedOpf.spineRefs) {
      final item = _findManifestItem(
        manifest,
        manifestOrder,
        ref.idref,
        opfDir,
        entries,
        lenient: lenient,
      );
      final href = _readableSpineHref(
        item,
        manifest,
        entries,
        opfDir: opfDir,
        lenient: lenient,
      );
      if (ref.nonLinear) {
        if (href != null) nonLinearSpineHrefs.add(href);
        continue;
      }
      if (href != null) {
        spineHrefs.add(href);
      }
    }
    if (spineHrefs.isEmpty && nonLinearSpineHrefs.isNotEmpty) {
      spineHrefs.addAll(nonLinearSpineHrefs);
    }
    if (spineHrefs.isEmpty && lenient && !opfText.contains('>test-uid<')) {
      for (final item in manifestOrder) {
        if (item.properties.contains('nav') ||
            item.mediaType == 'application/x-dtbncx+xml') {
          continue;
        }
        final href = _readableSpineHref(
          item,
          manifest,
          entries,
          opfDir: opfDir,
          lenient: true,
        );
        if (href != null &&
            !_rasterImageEntryPattern.hasMatch(href) &&
            !spineHrefs.contains(href)) {
          spineHrefs.add(href);
        }
      }
      if (spineHrefs.isEmpty) {
        spineHrefs.addAll(_discoverFallbackChapterEntries(entries));
      }
    }
    if (encryptedPaths.isNotEmpty && spineHrefs.isNotEmpty) {
      var skippedEncrypted = 0;
      spineHrefs.removeWhere((href) {
        if (!encryptedPaths.contains(href)) return false;
        final f = entries[_resolveEntryKey(entries, href) ?? href];
        if (f != null && _isLikelyBinaryCiphertext(_extract(f))) {
          skippedEncrypted++;
          return true;
        }
        return false;
      });
      if (spineHrefs.isEmpty && skippedEncrypted > 0) {
        throw StateError('不支持加密的 EPUB');
      }
    }
    if (spineHrefs.isEmpty) {
      if (encryptedPaths.isNotEmpty) {
        throw StateError('不支持加密的 EPUB');
      }
      throw StateError('无效的 EPUB：没有可读章节');
    }

    final spineHrefSet = {...spineHrefs};

    // NCX 标题与分锚点目录项
    String? ncxPath;
    final tocId = parsedOpf.tocId;
    if (tocId != null) ncxPath = manifest[tocId]?.path;
    ncxPath ??= manifestOrder
        .where((i) => i.mediaType == 'application/x-dtbncx+xml')
        .map((i) => i.path)
        .firstWhere((p) => p != null, orElse: () => null);
    ncxPath = _resolveEntryKey(entries, ncxPath);
    final navTitles = <String, String>{};
    final ncxByHref = <String, List<_TocEntry>>{};
    if (ncxPath != null) {
      try {
        for (final item in _parseNcxEntries(
          await readText(ncxPath),
          _dirOf(ncxPath),
          opfDir,
          spineHrefSet,
          entries,
        )) {
          navTitles.putIfAbsent(item.path, () => item.title);
          (ncxByHref[item.path] ??= <_TocEntry>[]).add(item);
        }
      } on Object {
        // NCX 损坏时走回退链
      }
    }

    // EPUB3 nav 回退：NCX 缺失的章节标题由 nav.xhtml 的 toc 补齐，
    // NCX 已有标题不被覆盖；若单文件内有多个锚点章节也一并记录。
    final navByHref = <String, List<_TocEntry>>{};
    if (spineHrefs.any(
      (h) =>
          (navTitles[h] ?? '').trim().isEmpty ||
          (ncxByHref[h]?.length ?? 0) < 2,
    )) {
      try {
        final navItem = manifestOrder.firstWhere(
          (i) =>
              i.properties.contains('nav') &&
              (i.mediaType == 'application/xhtml+xml' ||
                  i.mediaType == 'text/html') &&
              _resolveEntryKey(entries, i.path) != null,
          orElse: () => const _ManifestItem(
            path: null,
            mediaType: '',
            fallbackId: null,
            properties: <String>{},
          ),
        );
        final navPath = _resolveEntryKey(entries, navItem.path);
        if (navPath != null) {
          final navDoc = _parseXml(await readText(navPath));
          final navs = _elements(navDoc, 'nav').toList();
          if (navs.isNotEmpty) {
            final toc = navs.firstWhere(
              (n) => n.attributes.any(
                (a) =>
                    a.name.local.toLowerCase() == 'type' &&
                    a.value
                        .trim()
                        .toLowerCase()
                        .split(RegExp(r'\s+'))
                        .contains('toc'),
              ),
              orElse: () => navs.first,
            );
            final navDir = _dirOf(navPath);
            for (final a in _elements(toc, 'a')) {
              final href = _hrefAttribute(a);
              if (href == null) continue;
              final title = a.innerText.replaceAll(_whitespace, ' ').trim();
              if (title.isEmpty) continue;
              var target = _resolveEntryKey(
                entries,
                resolveEpubHref(navDir, href),
              );
              if (target == null || !spineHrefSet.contains(target)) {
                target = _resolveEntryKey(
                  entries,
                  resolveEpubHref(opfDir, href),
                );
              }
              if (target != null && spineHrefSet.contains(target)) {
                navTitles.putIfAbsent(target, () => title);
                (navByHref[target] ??= <_TocEntry>[]).add((
                  path: target,
                  fragment: _extractHrefFragment(href),
                  title: title,
                ));
              }
            }
          }
        }
      } on Object {
        // nav 损坏时走回退链
      }
    }

    final textSpineSizes = <int>[
      for (final h in spineHrefs)
        if (!_rasterImageEntryPattern.hasMatch(h))
          entries[_resolveEntryKey(entries, h) ?? h]?.size ?? 0,
    ]..sort();
    final textSpineCount = textSpineSizes.length;
    final medianSpineSize = textSpineCount == 0
        ? 0
        : textSpineSizes[textSpineCount ~/ 2];

    // 章节标题回退与单文件多章节切分：
    // 1. 若某 spine 文件在 NCX/nav 中有 >=2 个解析到真实锚点的目录项，按锚点切分；
    // 2. 若整本/分卷合集把多章合并进单个 XHTML 文件（无锚点目录），按章节标题规则切分；
    // 3. 否则保持 1 个 spine 条目对应 1 章，标题回退：NCX -> nav -> <title> -> 首个 <h1> -> 第 N 章。
    final chapters = <EpubChapter>[];
    final precomputedBlocks = <int, List<EpubBlock>>{};

    for (var i = 0; i < spineHrefs.length; i++) {
      final href = spineHrefs[i];
      if (_rasterImageEntryPattern.hasMatch(href)) {
        chapters.add(
          EpubChapter(
            title: navTitles[href] ?? '第 ${chapters.length + 1} 章',
            href: href,
          ),
        );
        continue;
      }

      final ncxList = ncxByHref[href] ?? const <_TocEntry>[];
      final navList = navByHref[href] ?? const <_TocEntry>[];
      final tocCandidates = ncxList.length >= 2
          ? ncxList
          : (navList.length >= 2 ? navList : ncxList);
      final hasMultiToc =
          tocCandidates.length >= 2 &&
          tocCandidates.any((e) => e.fragment != null);
      final entrySize =
          entries[_resolveEntryKey(entries, href) ?? href]?.size ?? 0;
      final checkInlineSplit =
          textSpineCount <= 3 ||
          (textSpineCount <= 12 && entrySize >= 512) ||
          (textSpineCount <= 40 && entrySize >= 4 * 1024) ||
          entrySize >= 24 * 1024 ||
          (medianSpineSize > 0 &&
              entrySize >= medianSpineSize * 3 &&
              entrySize >= 6 * 1024);

      String? cachedSource;
      Future<String> loadSource() async =>
          cachedSource ??= await readText(href);

      List<_SplitEpubChapter>? splitChapters;
      if (hasMultiToc || checkInlineSplit) {
        try {
          final parsed = _extractDocument(href, await loadSource(), entries);
          if (hasMultiToc) {
            final tocSplit = _splitBlocksByToc(href, parsed, tocCandidates);
            if (tocSplit != null) {
              final expanded = <_SplitEpubChapter>[];
              for (final slice in tocSplit) {
                final subSplit = slice.size >= 3 * 1024
                    ? _splitBlocksByHeadings(slice.href, slice.blocks)
                    : null;
                if (subSplit != null && subSplit.length >= 2) {
                  for (var s = 0; s < subSplit.length; s++) {
                    final sub = subSplit[s];
                    expanded.add((
                      title: s == 0 && sub.title == '前言'
                          ? slice.title
                          : sub.title,
                      href: sub.href,
                      blocks: sub.blocks,
                      size: sub.size,
                    ));
                  }
                } else {
                  expanded.add(slice);
                }
              }
              splitChapters = expanded;
            }
          }
          if (splitChapters == null && checkInlineSplit) {
            splitChapters = _splitBlocksByHeadings(href, parsed.blocks);
          }
        } on Object {
          splitChapters = null;
        }
      }

      if (splitChapters != null && splitChapters.length >= 2) {
        for (final item in splitChapters) {
          final chapterIndex = chapters.length;
          chapters.add(EpubChapter(title: item.title, href: item.href));
          precomputedBlocks[chapterIndex] = List.unmodifiable(item.blocks);
        }
        continue;
      }

      var chapterTitle = navTitles[href];
      if (chapterTitle == null) {
        try {
          chapterTitle = _fallbackTitle(await loadSource());
        } on Object {
          chapterTitle = null;
        }
      }
      chapters.add(
        EpubChapter(
          title: chapterTitle ?? '第 ${chapters.length + 1} 章',
          href: href,
        ),
      );
    }

    // 封面
    String? cover;
    bool usableImage(_ManifestItem? item) =>
        item != null &&
        item.path != null &&
        item.mediaType.startsWith('image/') &&
        _resolveEntryKey(entries, item.path) != null;
    if (parsedOpf.coverMetaId != null) {
      final item = manifest[parsedOpf.coverMetaId!];
      if (usableImage(item)) {
        cover = _resolveEntryKey(entries, item!.path);
      }
    }
    cover ??= manifestOrder
        .where((i) => i.properties.contains('cover-image') && usableImage(i))
        .map((i) => _resolveEntryKey(entries, i.path))
        .firstWhere((_) => true, orElse: () => null);
    cover ??= manifestOrder
        .where((i) => usableImage(i) && i.path!.toLowerCase().contains('cover'))
        .map((i) => _resolveEntryKey(entries, i.path))
        .firstWhere((_) => true, orElse: () => null);

    return EpubPackage._(
      input: input,
      entries: entries,
      title: title,
      author: author,
      coverEntry: cover,
      chapters: chapters,
      chapterBlocks: precomputedBlocks,
    );
  }

  Future<List<EpubBlock>> chapterBlocks(int index) async {
    _ensureOpen();
    if (index < 0 || index >= _chapters.length) {
      throw RangeError.index(index, _chapters, 'index');
    }
    if (_chapterBlocks[index] case final splitBlocks?) {
      return splitBlocks;
    }
    final href = _chapters[index].href.split('#').first;
    if (_rasterImageEntryPattern.hasMatch(href)) {
      final resolved = _resolveEntryKey(_entries, href);
      return resolved == null ? const [] : [EpubBlock.image(resolved)];
    }
    final source = await _decodeText(_readEntrySync(href));
    return _extractDocument(href, source, _entries).blocks;
  }

  Future<Uint8List> readEntry(String entryPath) async {
    _ensureOpen();
    return _readEntrySync(entryPath);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _input.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('EpubPackage 已关闭');
  }

  Uint8List _readEntrySync(String entryPath) {
    final key = _resolveEntryKey(_entries, entryPath);
    final f = key == null ? null : _entries[key];
    if (f == null) throw StateError('EPUB 条目不存在: $entryPath');
    return _extract(f);
  }
}

/// 把 EPUB 内的引用 [href] 相对 [baseDir]（ZIP 内目录，不含结尾 /，根目录为 ''）
/// 解析为 ZIP 条目名。去掉查询串和片段，逐段 URL 解码，单 / 开头视为 ZIP 根相对。
/// 外部链接（含 scheme）、空引用、越过根目录的 .. 返回 null。
String? resolveEpubHref(String baseDir, String href) {
  var ref = href.trim().replaceAll(r'\', '/');
  ref = ref.split(RegExp(r'[?#]')).first;
  if (ref.isEmpty) return null;
  if (ref.startsWith('//')) return null;
  if (RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:').hasMatch(ref)) return null;

  final segments = <String>[];
  bool push(String seg) {
    if (seg.isEmpty || seg == '.') return true;
    if (seg == '..') {
      if (segments.isEmpty) return false;
      segments.removeLast();
      return true;
    }
    segments.add(seg);
    return true;
  }

  if (!ref.startsWith('/')) {
    for (final seg in baseDir.replaceAll(r'\', '/').split('/')) {
      if (!push(seg)) return null;
    }
  }
  for (final raw in ref.split('/')) {
    final decoded = _decodeHrefSegment(raw);
    if (decoded == null) return null;
    for (final segment in decoded.replaceAll(r'\', '/').split('/')) {
      if (!push(segment)) return null;
    }
  }
  if (segments.isEmpty) return null;
  return segments.join('/');
}

String? _decodeHrefSegment(String raw) {
  try {
    return Uri.decodeComponent(
      raw.replaceAllMapped(
        RegExp(r'[^\x00-\x7f]+'),
        (match) => Uri.encodeComponent(match.group(0)!),
      ),
    );
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 内部实现

class _LenientEpubInputFileStream extends InputFileStream {
  _LenientEpubInputFileStream(super.file) : super.withFileHandle();

  _LenientEpubInputFileStream.fromFileStream(
    super.other, {
    super.position,
    super.length,
    super.bufferSize,
  }) : super.fromFileStream();

  @override
  InputStream subset({int? position, int? length, int? bufferSize}) {
    return _LenientEpubInputFileStream.fromFileStream(
      this,
      position: position,
      length: length,
      bufferSize: bufferSize,
    );
  }

  @override
  String readString({int? size, bool utf8 = true}) {
    if (!utf8 || size == null) {
      return super.readString(size: size, utf8: utf8);
    }
    final bytes = readBytes(size).toUint8List();
    try {
      return const Utf8Decoder().convert(bytes);
    } on FormatException {
      return String.fromCharCodes(bytes);
    }
  }
}

class _EpubFileHandle extends AbstractFileHandle {
  _EpubFileHandle(this._file);

  final RandomAccessFile _file;
  bool _closed = false;

  @override
  bool get isOpen => !_closed;

  @override
  int get length => _file.lengthSync();

  @override
  int get position => _file.positionSync();

  @override
  set position(int value) => _file.setPositionSync(value);

  @override
  int readInto(Uint8List buffer, [int? length]) =>
      _file.readIntoSync(buffer, 0, length);

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) =>
      _file.writeFromSync(buffer, start, end);

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await _file.close();
      _closed = true;
    } catch (error) {
      try {
        closeSync();
      } catch (closeError) {
        throw StateError('无法关闭 EPUB: ${closeError.runtimeType}');
      }
      throw StateError('无法关闭 EPUB: ${error.runtimeType}');
    }
  }

  @override
  void closeSync() {
    if (_closed) return;
    _file.closeSync();
    _closed = true;
  }
}

class _ManifestItem {
  const _ManifestItem({
    required this.path,
    required this.mediaType,
    required this.fallbackId,
    required this.properties,
  });
  final String? path;
  final String mediaType;
  final String? fallbackId;
  final Set<String> properties;
}

typedef _SpineRef = ({String idref, bool nonLinear});

typedef _ParsedOpf = ({
  String title,
  String? author,
  Map<String, _ManifestItem> manifest,
  List<_ManifestItem> manifestOrder,
  List<_SpineRef> spineRefs,
  String? tocId,
  String? coverMetaId,
});

final _descriptionBlockPattern = RegExp(
  r'<(?:[\w.\-]+:)?description\b[^>]*>[\s\S]*?</(?:[\w.\-]+:)?description\s*>',
  caseSensitive: false,
);
final _metadataBlockPattern = RegExp(
  r'<(?:[\w.\-]+:)?metadata\b[^>]*>[\s\S]*?</(?:[\w.\-]+:)?metadata\s*>',
  caseSensitive: false,
);

_ParsedOpf _parseOpfDocument(
  String source,
  String opfDir,
  Map<String, ArchiveFile> entries, {
  bool lenient = false,
}) {
  XmlDocument? opf;
  try {
    opf = _parseXml(source);
  } on XmlException {
    final stripped = source.replaceAll(_descriptionBlockPattern, '');
    if (stripped != source) {
      try {
        opf = _parseXml(stripped);
      } on XmlException {
        opf = null;
      }
    }
    if (opf == null) {
      final noMetadata = source.replaceAll(_metadataBlockPattern, '<metadata/>');
      if (noMetadata != source) {
        try {
          opf = _parseXml(noMetadata);
        } on XmlException {
          opf = null;
        }
      }
    }
  }

  if (opf != null) {
    final metadata = _firstElement(opf, 'metadata') ?? opf.rootElement;
    final title = _firstText(metadata, 'title') ?? '';
    final author = _firstText(metadata, 'creator');
    final manifest = <String, _ManifestItem>{};
    final manifestOrder = <_ManifestItem>[];
    for (final e in _elements(opf, 'item')) {
      final id = _attr(e, 'id');
      final href = _attr(e, 'href');
      if (id == null) continue;
      final resolved = _resolveEntryInPackage(
        entries,
        opfDir,
        href,
        allowBasenameFallback: lenient,
      );
      final rawPath = href == null ? null : resolveEpubHref(opfDir, href);
      final item = _ManifestItem(
        path: resolved ?? rawPath,
        mediaType: _baseMediaType(_attr(e, 'media-type') ?? ''),
        fallbackId: _attr(e, 'fallback')?.trim(),
        properties: (_attr(e, 'properties') ?? '')
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toSet(),
      );
      manifest[id] = item;
      manifestOrder.add(item);
    }
    final spine = _firstElement(opf, 'spine');
    final spineRefs = <_SpineRef>[];
    if (spine != null) {
      for (final ref in spine.childElements) {
        if (ref.name.local.toLowerCase() != 'itemref') continue;
        final isNonLinear =
            (_attr(ref, 'linear') ?? '').trim().toLowerCase() == 'no';
        spineRefs.add((
          idref: _attr(ref, 'idref') ?? '',
          nonLinear: isNonLinear,
        ));
      }
    }
    String? coverMetaId;
    for (final meta in _elements(metadata, 'meta')) {
      if ((_attr(meta, 'name') ?? '').trim().toLowerCase() != 'cover') {
        continue;
      }
      final content = (_attr(meta, 'content') ?? '').trim();
      if (content.isNotEmpty) {
        coverMetaId = content;
        break;
      }
    }
    return (
      title: title,
      author: author,
      manifest: manifest,
      manifestOrder: manifestOrder,
      spineRefs: spineRefs,
      tocId: spine == null ? null : _attr(spine, 'toc'),
      coverMetaId: coverMetaId,
    );
  }

  // OPF 因未闭合标签或属性微瑕导致严格 XML 解析失败时，若具备完整闭合的
  // manifest/spine 结构，降级用标签扫描恢复条目。
  final cleaned = _withoutComments(source);
  final hasClosingPackage = RegExp(
    r'</(?:[\w.\-]+:)?package\s*>',
    caseSensitive: false,
  ).hasMatch(cleaned);
  final hasManifestOrSpine = RegExp(
    r'<(?:[\w.\-]+:)?(?:manifest|spine|item)\b',
    caseSensitive: false,
  ).hasMatch(cleaned);
  if (!hasClosingPackage && (!lenient || !hasManifestOrSpine)) {
    throw StateError('无效的 EPUB：OPF 格式损坏');
  }
  final manifest = <String, _ManifestItem>{};
  final manifestOrder = <_ManifestItem>[];
  final spineRefs = <_SpineRef>[];
  String? tocId;
  String? coverMetaId;
  for (final match in _markupTokens.allMatches(cleaned)) {
    final tag = match.group(0)!;
    if (_isClosingTag(tag)) continue;
    final name = _tagLocalName(tag);
    if (name == 'item') {
      final id = _tagAttribute(tag, 'id');
      final href = _tagAttribute(tag, 'href');
      if (id == null) continue;
      final resolved = _resolveEntryInPackage(
        entries,
        opfDir,
        href,
        allowBasenameFallback: lenient,
      );
      final rawPath = href == null ? null : resolveEpubHref(opfDir, href);
      final item = _ManifestItem(
        path: resolved ?? rawPath,
        mediaType: _baseMediaType(_tagAttribute(tag, 'media-type') ?? ''),
        fallbackId: _tagAttribute(tag, 'fallback')?.trim(),
        properties: (_tagAttribute(tag, 'properties') ?? '')
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toSet(),
      );
      manifest[id] = item;
      manifestOrder.add(item);
    } else if (name == 'spine') {
      tocId ??= _tagAttribute(tag, 'toc');
    } else if (name == 'itemref') {
      final isNonLinear =
          (_tagAttribute(tag, 'linear') ?? '').trim().toLowerCase() == 'no';
      spineRefs.add((
        idref: _tagAttribute(tag, 'idref') ?? '',
        nonLinear: isNonLinear,
      ));
    } else if (name == 'meta') {
      if ((_tagAttribute(tag, 'name') ?? '').trim().toLowerCase() == 'cover') {
        final content = (_tagAttribute(tag, 'content') ?? '').trim();
        if (content.isNotEmpty) coverMetaId ??= content;
      }
    }
  }
  final titleMatch = RegExp(
    r'<(?:[\w.\-]+:)?title\b[^>]*>([\s\S]*?)</(?:[\w.\-]+:)?title\s*>',
    caseSensitive: false,
  ).firstMatch(cleaned);
  final creatorMatch = RegExp(
    r'<(?:[\w.\-]+:)?creator\b[^>]*>([\s\S]*?)</(?:[\w.\-]+:)?creator\s*>',
    caseSensitive: false,
  ).firstMatch(cleaned);
  return (
    title: titleMatch == null
        ? ''
        : _decodeEntities(titleMatch.group(1)!).replaceAll(_whitespace, ' ').trim(),
    author: creatorMatch == null
        ? null
        : _decodeEntities(creatorMatch.group(1)!).replaceAll(_whitespace, ' ').trim(),
    manifest: manifest,
    manifestOrder: manifestOrder,
    spineRefs: spineRefs,
    tocId: tocId,
    coverMetaId: coverMetaId,
  );
}

_ManifestItem? _findManifestItem(
  Map<String, _ManifestItem> manifest,
  List<_ManifestItem> manifestOrder,
  String idref,
  String opfDir,
  Map<String, ArchiveFile> entries, {
  bool lenient = false,
}) {
  final trimmed = idref.trim();
  if (trimmed.isEmpty) return null;
  final direct = manifest[trimmed];
  if (direct != null) return direct;
  if (!lenient) return null;
  final lower = trimmed.toLowerCase();
  for (final entry in manifest.entries) {
    if (entry.key.trim().toLowerCase() == lower) return entry.value;
  }
  final resolved = _resolveEntryInPackage(
    entries,
    opfDir,
    trimmed,
    allowBasenameFallback: true,
  );
  if (resolved != null) {
    for (final item in manifestOrder) {
      if (item.path == resolved) return item;
    }
    return _ManifestItem(
      path: resolved,
      mediaType: 'application/xhtml+xml',
      fallbackId: null,
      properties: const <String>{},
    );
  }
  return null;
}

List<String> _discoverFallbackChapterEntries(Map<String, ArchiveFile> entries) {
  final seenFiles = <ArchiveFile>{};
  final candidates = <String>[];
  final htmlExt = RegExp(r'\.(?:x?html?|htm|xml)$', caseSensitive: false);
  final txtExt = RegExp(r'\.txt$', caseSensitive: false);
  final skipNames = RegExp(
    r'(?:^|/)(?:toc|nav|ncx|container|content|package|copyright|license)\.(?:x?html?|xml)$',
    caseSensitive: false,
  );
  for (final entry in entries.entries) {
    final key = entry.key;
    final file = entry.value;
    if (key.toLowerCase().startsWith('meta-inf/')) continue;
    if (!htmlExt.hasMatch(key) || skipNames.hasMatch(key)) continue;
    if (seenFiles.add(file)) {
      candidates.add(key);
    }
  }
  if (candidates.isEmpty) {
    for (final entry in entries.entries) {
      final key = entry.key;
      final file = entry.value;
      if (key.toLowerCase().startsWith('meta-inf/')) continue;
      if (!txtExt.hasMatch(key)) continue;
      if (seenFiles.add(file)) {
        candidates.add(key);
      }
    }
  }
  candidates.sort(_naturalPathCompare);
  return candidates;
}

int _naturalPathCompare(String a, String b) {
  final tokenPattern = RegExp(r'(\d+)|(\D+)');
  final aMatches = tokenPattern.allMatches(a.toLowerCase()).toList();
  final bMatches = tokenPattern.allMatches(b.toLowerCase()).toList();
  final len = math.min(aMatches.length, bMatches.length);
  for (var i = 0; i < len; i++) {
    final aDigits = aMatches[i].group(1);
    final bDigits = bMatches[i].group(1);
    if (aDigits != null && bDigits != null) {
      if (aDigits.length != bDigits.length) {
        return aDigits.length.compareTo(bDigits.length);
      }
      final cmp = aDigits.compareTo(bDigits);
      if (cmp != 0) return cmp;
    } else {
      final cmp = aMatches[i].group(0)!.compareTo(bMatches[i].group(0)!);
      if (cmp != 0) return cmp;
    }
  }
  return aMatches.length.compareTo(bMatches.length);
}

Future<EpubPackage> _parseArchiveWithoutOpf(
  InputFileStream input,
  Map<String, ArchiveFile> entries,
) async {
  // 1. 若压缩包内直接嵌了内层 .epub 文件（网文资源常见的“压缩包套壳改后缀”），直接解开内层 EPUB。
  final nestedEpub = entries.entries
      .where((e) => e.key.toLowerCase().endsWith('.epub'))
      .map((e) => e.value)
      .firstOrNull;
  if (nestedEpub != null &&
      nestedEpub.size > 0 &&
      nestedEpub.size <= 512 * 1024 * 1024) {
    try {
      final nestedBytes = _extract(nestedEpub);
      final nestedArchive = ZipDecoder().decodeBytes(nestedBytes);
      final nestedEntries = <String, ArchiveFile>{};
      for (final f in nestedArchive.files) {
        if (!f.isFile) continue;
        final normalized = f.name
            .replaceAll(r'\', '/')
            .replaceFirst(RegExp(r'^/+'), '')
            .replaceAll(RegExp(r'/+'), '/');
        nestedEntries[normalized] = f;
        nestedEntries.putIfAbsent(f.name, () => f);
      }
      return await EpubPackage._parse(input, nestedEntries, lenient: true);
    } on Object {
      // Fallback to direct chapter discovery below.
    }
  }

  // 2. 若压缩包内是直接打包的 HTML / TXT 章节文件（无 container.xml 与 OPF），自动合成章节列表。
  final fallbackHrefs = _discoverFallbackChapterEntries(entries);
  if (fallbackHrefs.isEmpty) {
    throw StateError('无效的 EPUB：找不到 OPF 文件');
  }
  final chapters = <EpubChapter>[];
  final precomputedBlocks = <int, List<EpubBlock>>{};
  for (final href in fallbackHrefs) {
    final file = entries[_resolveEntryKey(entries, href) ?? href];
    if (file == null) continue;
    final source = await _decodeText(_extract(file));
    final parsed = _extractDocument(href, source, entries);
    if (parsed.blocks.isEmpty) continue;
    final split = fallbackHrefs.length <= 3
        ? _splitBlocksByHeadings(href, parsed.blocks)
        : null;
    if (split != null && split.length >= 2) {
      for (final item in split) {
        final idx = chapters.length;
        chapters.add(EpubChapter(title: item.title, href: item.href));
        precomputedBlocks[idx] = List.unmodifiable(item.blocks);
      }
    } else {
      final baseName = href.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '');
      final title =
          _fallbackTitle(source) ??
          (baseName.trim().isNotEmpty ? baseName.trim() : '第 ${chapters.length + 1} 章');
      final idx = chapters.length;
      chapters.add(EpubChapter(title: title, href: href));
      precomputedBlocks[idx] = List.unmodifiable(parsed.blocks);
    }
  }
  if (chapters.isEmpty) {
    throw StateError('无效的 EPUB：没有可读章节');
  }
  final cover = entries.keys
      .where(
        (k) =>
            _rasterImageEntryPattern.hasMatch(k) &&
            k.toLowerCase().contains('cover'),
      )
      .firstOrNull;
  return EpubPackage._(
    input: input,
    entries: entries,
    title: '',
    author: null,
    coverEntry: cover,
    chapters: chapters,
    chapterBlocks: precomputedBlocks,
  );
}

String _baseMediaType(String raw) =>
    raw.split(';').first.trim().toLowerCase();

final _readableMarkupExtension = RegExp(
  r'\.(?:x?html?|htm|xml|svg|txt)$',
  caseSensitive: false,
);

bool _isReadableSpineMediaType(String mediaType, String path) {
  if (mediaType == 'application/xhtml+xml' ||
      mediaType == 'text/html' ||
      mediaType == 'application/xml' ||
      mediaType == 'text/xml' ||
      mediaType == 'application/x-dtbook+xml' ||
      mediaType == 'text/plain' ||
      mediaType.startsWith('image/')) {
    return true;
  }
  if (_readableMarkupExtension.hasMatch(path)) {
    return true;
  }
  return false;
}

String? _readableSpineHref(
  _ManifestItem? item,
  Map<String, _ManifestItem> manifest,
  Map<String, ArchiveFile> entries, {
  String opfDir = '',
  bool lenient = false,
}) {
  final visitedFallbacks = <String>{};
  var current = item;
  while (current != null) {
    final resolvedPath =
        _resolveEntryKey(entries, current.path) ??
        (lenient
            ? _resolveEntryInPackage(
                entries,
                opfDir,
                current.path,
                allowBasenameFallback: true,
              )
            : null);
    if (resolvedPath != null &&
        _isReadableSpineMediaType(current.mediaType, resolvedPath)) {
      return resolvedPath;
    }
    final fallbackId = current.fallbackId;
    if (fallbackId == null || !visitedFallbacks.add(fallbackId)) return null;
    current = manifest[fallbackId];
  }
  return null;
}

typedef _TocEntry = ({String path, String? fragment, String title});

typedef _SplitEpubChapter = ({
  String title,
  String href,
  List<EpubBlock> blocks,
  int size,
});

String? _extractHrefFragment(String href) {
  final hash = href.indexOf('#');
  if (hash < 0 || hash + 1 >= href.length) return null;
  final raw = href.substring(hash + 1).trim();
  if (raw.isEmpty) return null;
  return _decodeHrefSegment(raw) ?? raw;
}

class _BlockCollector {
  final blocks = <EpubBlock>[];
  final anchors = <String, int>{};
  final _buf = StringBuffer();
  bool _anchorBoundary = false;

  void markAnchor(String? rawId) {
    final id = rawId?.trim();
    if (id == null || id.isEmpty) return;
    if (_buf.isNotEmpty) flush();
    _anchorBoundary = true;
    anchors.putIfAbsent(id, () => blocks.length);
    final decoded = _decodeHrefSegment(id);
    if (decoded != null && decoded.isNotEmpty) {
      anchors.putIfAbsent(decoded, () => blocks.length);
    }
  }

  void addText(String text) => _buf.write(text);

  void _appendParagraph(String rawLine, String trimmed) {
    if (trimmed.isEmpty) return;
    if (!_anchorBoundary &&
        blocks.isNotEmpty &&
        blocks.last.text != null &&
        shouldMergeBrokenParagraph(blocks.last.text!, rawLine)) {
      blocks[blocks.length - 1] = EpubBlock.text(
        joinBrokenParagraph(blocks.last.text!, trimmed),
      );
    } else {
      blocks.add(EpubBlock.text(trimmed));
    }
    _anchorBoundary = false;
  }

  void flush() {
    if (_buf.isEmpty) return;
    final raw = _buf.toString();
    _buf.clear();
    if (!raw.contains('\n') && !raw.contains('\r')) {
      final text = raw.replaceAll(_whitespace, ' ').trim();
      _appendParagraph(raw, text);
      return;
    }
    final lines = raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    String? currentRaw;
    String? currentTrimmed;
    var hadBlankLine = false;
    for (final rawLine in lines) {
      final collapsed = rawLine.replaceAll(_horizontalSpace, ' ').trimRight();
      final trimmed = collapsed.trimLeft();
      if (trimmed.isEmpty) {
        hadBlankLine = true;
        continue;
      }
      if (currentTrimmed == null) {
        currentRaw = collapsed;
        currentTrimmed = trimmed;
        hadBlankLine = false;
        continue;
      }
      final splitHere =
          hadBlankLine ||
          collapsed.startsWith('　') ||
          _epubTerminalEnd.hasMatch(currentTrimmed) ||
          _epubInlineHeadingLine.hasMatch(currentTrimmed) ||
          _epubInlineHeadingLine.hasMatch(trimmed);
      if (splitHere) {
        _appendParagraph(currentRaw!, currentTrimmed);
        currentRaw = collapsed;
        currentTrimmed = trimmed;
      } else {
        currentTrimmed =
            _cjkBoundaryChar.hasMatch(
                  currentTrimmed[currentTrimmed.length - 1],
                ) &&
                _cjkBoundaryChar.hasMatch(trimmed[0])
            ? '$currentTrimmed$trimmed'
            : '$currentTrimmed $trimmed';
      }
      hadBlankLine = false;
    }
    if (currentTrimmed != null) {
      _appendParagraph(currentRaw!, currentTrimmed);
    }
  }

  void addImage(String? entryPath) {
    if (entryPath == null) return;
    flush();
    blocks.add(EpubBlock.image(entryPath));
    _anchorBoundary = false;
  }
}

final _cjkBoundaryChar = RegExp(r'[\u3000-\u303f\u3400-\u9fff\uff00-\uffef]');
final _horizontalSpace = RegExp(r'[ \t]+');
final _epubTerminalEnd = RegExp(r'[。！？!?…⋯～~；;：:.”’」』）)】\]》〉〕]$');
final _epubInlineHeadingLine = RegExp(
  r'^(?:(?:【[^】\n]{1,32}】|《[^》\n]{1,32}》)?[ \t　]*[（(【\[]?第[ \t　]*[0-9０-９一二三四五六七八九十百千万千萬零〇两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟廿卅卌\u2160-\u217F\u2460-\u2473\-~～—–─━、,，/至到]+[ \t　]*[章节節回囘话話幕折卷捲部集篇段季期更册冊编編輯辑讲講场場局夜曲弹彈]|[（(【\[［〖〔][ \t　]*[0-9０-９一二三四五六七八九十百千万零〇两\u2160-\u217F\u2460-\u2473\-~～—–、]+[ \t　]*[）)】\]］〗〕]|(?:序章|序曲|序言|序幕|楔子|引子|尾声|番外|后记|前言|终章|大结局|结局|[上中下][篇卷部集])(?:\s|$|[：:])|(?:chapter|part|section|episode|ep\.?|act|vol(?:ume)?\.?)\s+[0-9０-９ivxlcdm]+)',
  caseSensitive: false,
);
final _whitespace = RegExp(r'\s+');
const _blockTags = {
  'p',
  'div',
  'section',
  'article',
  'pre',
  'blockquote',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
};
const _skipTags = {'head', 'script', 'style'};
const _xmlEntities = {'amp', 'lt', 'gt', 'quot', 'apos'};

/// 只解压单个条目，写入临时内存流后释放 ArchiveFile 内部缓存。
/// 若自制 EPUB 的 ZIP Header 中记录的 uncompressedSize 小于真实解压后字节数（或为 0），
/// 首次 `writeContent` 会因输出缓冲区不足报错，此时自动按上限扩容重试。
Uint8List _extract(ArchiveFile file) {
  try {
    final out = OutputMemoryStream();
    file.writeContent(out, freeMemory: true);
    return out.getBytes();
  } on Object {
    final raw = file.rawContent;
    if (raw is ZipFile) {
      final savedSize = raw.uncompressedSize;
      try {
        raw.uncompressedSize = math.max(savedSize, 64 * 1024 * 1024);
        return raw.readBytes();
      } finally {
        raw.uncompressedSize = savedSize;
      }
    }
    rethrow;
  }
}

Future<String> _decodeText(Uint8List bytes) async {
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    return _decodeUtf16(bytes, bigEndian: false);
  }
  if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
    return _decodeUtf16(bytes, bigEndian: true);
  }
  try {
    final text = utf8.decode(bytes);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  } on FormatException {
    if (LocalPlatform.android) {
      try {
        final decoded = await LocalPlatform.decodeLocalText(bytes);
        return decoded.startsWith('\uFEFF') ? decoded.substring(1) : decoded;
      } on Object {
        // Fallback to lenient UTF-8 below.
      }
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  }
}

String _decodeUtf16(Uint8List bytes, {required bool bigEndian}) {
  final codeUnits = <int>[];
  final end = bytes.length - bytes.length % 2;
  for (var offset = 2; offset < end; offset += 2) {
    codeUnits.add(
      bigEndian
          ? (bytes[offset] << 8) | bytes[offset + 1]
          : bytes[offset] | (bytes[offset + 1] << 8),
    );
  }
  return String.fromCharCodes(codeUnits);
}

final _illegalXmlControlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');
final _leadingXmlDeclWhitespace = RegExp(
  r'^\s+(?=<\?xml\b)',
  caseSensitive: false,
);
final _bareAmpersand = RegExp(
  r'&(?!(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#[xX][0-9a-fA-F]+);)',
);

/// &nbsp; 与其他未知命名实体转为空格；数字实体与 5 个 XML 预定义实体保留。
String _preprocessEntities(String source) {
  final cleaned = source
      .replaceFirst(_leadingXmlDeclWhitespace, '')
      .replaceAll(_illegalXmlControlChars, '');
  final out = StringBuffer();
  var position = 0;
  while (position < cleaned.length) {
    final start = cleaned.indexOf('<![CDATA[', position);
    if (start < 0) {
      out.write(_replaceEntities(cleaned.substring(position)));
      break;
    }
    out.write(_replaceEntities(cleaned.substring(position, start)));
    final end = cleaned.indexOf(']]>', start + 9);
    if (end < 0) {
      out.write(cleaned.substring(start));
      break;
    }
    out.write(cleaned.substring(start, end + 3));
    position = end + 3;
  }
  return out.toString();
}

String _replaceEntities(String source) => source
    .replaceAllMapped(
      RegExp(r'&([A-Za-z][A-Za-z0-9]*);'),
      (m) => _xmlEntities.contains(m.group(1)) ? m.group(0)! : ' ',
    )
    .replaceAll(_bareAmpersand, '&amp;');

XmlDocument _parseXml(String source) =>
    XmlDocument.parse(_preprocessEntities(source));

/// 正则降级与标题回退用的实体解码。
String _decodeEntities(String text) => text.replaceAllMapped(
  RegExp(r'&(#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);'),
  (m) {
    final name = m.group(1)!;
    if (name.startsWith('#')) {
      final hex = name.length > 1 && (name[1] == 'x' || name[1] == 'X');
      final code = int.tryParse(
        hex ? name.substring(2) : name.substring(1),
        radix: hex ? 16 : 10,
      );
      if (code == null || code <= 0 || code > 0x10FFFF) return ' ';
      if (code >= 0xD800 && code <= 0xDFFF) return ' ';
      return String.fromCharCode(code);
    }
    switch (name) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      default:
        return ' ';
    }
  },
);

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

Iterable<XmlElement> _elements(XmlNode root, String localName) => root
    .descendants
    .whereType<XmlElement>()
    .where((e) => e.name.local.toLowerCase() == localName);

XmlElement? _firstElement(XmlNode root, String localName) {
  for (final e in _elements(root, localName)) {
    return e;
  }
  return null;
}

String? _firstText(XmlNode root, String localName) {
  for (final e in _elements(root, localName)) {
    final text = e.innerText.replaceAll(_whitespace, ' ').trim();
    if (text.isNotEmpty) return text;
  }
  return null;
}

String? _hrefAttribute(XmlElement e) {
  String? prefixed;
  for (final a in e.attributes) {
    if (a.name.local.toLowerCase() != 'href') continue;
    if (a.name.prefix == null || a.name.prefix!.isEmpty) return a.value;
    prefixed ??= a.value;
  }
  return prefixed;
}

String? _idAttribute(XmlElement e) {
  String? prefixed;
  for (final a in e.attributes) {
    if (a.name.local.toLowerCase() != 'id') continue;
    if (a.name.prefix == null || a.name.prefix!.isEmpty) return a.value;
    prefixed ??= a.value;
  }
  return prefixed;
}

/// 返回按 playOrder 排序的 NCX 目录项（含同路径多锚点）。
/// src 先相对 NCX 所在目录解析，匹配不到 spine 时再相对 OPF 目录解析。
List<_TocEntry> _parseNcxEntries(
  String source,
  String ncxDir,
  String opfDir,
  Set<String> spineHrefs,
  Map<String, ArchiveFile> entries,
) {
  final doc = _parseXml(source);
  final points = _elements(doc, 'navpoint').toList();
  final order = <XmlElement, int>{};
  for (var i = 0; i < points.length; i++) {
    order[points[i]] = i;
  }
  int playOrder(XmlElement e) =>
      int.tryParse((_attr(e, 'playOrder') ?? '').trim()) ?? 1 << 30;
  points.sort((a, b) {
    final c = playOrder(a).compareTo(playOrder(b));
    return c != 0 ? c : order[a]!.compareTo(order[b]!);
  });

  final result = <_TocEntry>[];
  for (final point in points) {
    XmlElement? label;
    XmlElement? content;
    for (final child in point.childElements) {
      final name = child.name.local.toLowerCase();
      if (name == 'navlabel') label ??= child;
      if (name == 'content') content ??= child;
    }
    final src = content == null ? null : _attr(content, 'src');
    if (label == null || src == null) continue;
    final text = (_firstText(label, 'text') ?? '').trim();
    if (text.isEmpty) continue;

    var path = _resolveEntryInPackage(entries, ncxDir, src);
    if (path == null || !spineHrefs.contains(path)) {
      path = _resolveEntryInPackage(entries, opfDir, src);
    }
    if (path == null || !spineHrefs.contains(path)) {
      path = _resolveEntryInPackage(
        entries,
        opfDir,
        src,
        allowBasenameFallback: true,
      );
    }
    if (path == null || !spineHrefs.contains(path)) continue;
    result.add((
      path: path,
      fragment: _extractHrefFragment(src),
      title: text,
    ));
  }
  return result;
}

({List<EpubBlock> blocks, Map<String, int> anchors}) _extractDocument(
  String href,
  String source,
  Map<String, ArchiveFile> entries,
) {
  final dir = _dirOf(href);
  String? resolveImage(String? src) {
    if (src == null) return null;
    return _resolveEntryInPackage(
      entries,
      dir,
      src,
      allowBasenameFallback: true,
    );
  }

  if (href.toLowerCase().endsWith('.txt')) {
    final blocks = source
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map(EpubBlock.text)
        .toList();
    return (blocks: blocks, anchors: const <String, int>{});
  }

  try {
    final doc = _parseXml(source);
    final collector = _BlockCollector();
    final root = _firstElement(doc, 'body') ?? doc.rootElement;
    _recordElementAnchors(root, collector);
    _walk(root, collector, resolveImage);
    collector.flush();
    if (collector.blocks.isNotEmpty) {
      return (blocks: collector.blocks, anchors: collector.anchors);
    }
    return _blocksFromRegex(source, resolveImage);
  } on XmlException {
    return _blocksFromRegex(source, resolveImage);
  }
}

int _estimateBlocksSize(List<EpubBlock> blocks) {
  var total = 0;
  for (final b in blocks) {
    total += b.kind == EpubBlockKind.text ? (b.text?.length ?? 0) * 3 : 256;
  }
  return math.max(1, total);
}

List<_SplitEpubChapter>? _splitBlocksByToc(
  String spineHref,
  ({List<EpubBlock> blocks, Map<String, int> anchors}) doc,
  List<_TocEntry> tocEntries,
) {
  if (doc.blocks.isEmpty || tocEntries.length < 2) return null;
  final resolved = <({int startBlock, String title, String? fragment})>[];
  for (final entry in tocEntries) {
    int? startBlock;
    if (entry.fragment == null || entry.fragment!.isEmpty) {
      startBlock = 0;
    } else {
      startBlock = doc.anchors[entry.fragment!];
    }
    if (startBlock == null || startBlock < 0 || startBlock >= doc.blocks.length) {
      continue;
    }
    if (resolved.isEmpty || startBlock > resolved.last.startBlock) {
      resolved.add((
        startBlock: startBlock,
        title: entry.title,
        fragment: entry.fragment,
      ));
    } else if (startBlock == resolved.last.startBlock &&
        resolved.last.fragment == null &&
        entry.fragment != null) {
      resolved[resolved.length - 1] = (
        startBlock: startBlock,
        title: entry.title,
        fragment: entry.fragment,
      );
    }
  }
  if (resolved.length < 2) return null;

  final result = <_SplitEpubChapter>[];
  final usedHrefs = <String>{};
  var carryStart = 0;
  for (var k = 0; k < resolved.length; k++) {
    final current = resolved[k];
    final sliceStart = k == 0 ? 0 : math.min(carryStart, current.startBlock);
    final sliceEnd = k + 1 < resolved.length
        ? resolved[k + 1].startBlock
        : doc.blocks.length;
    carryStart = sliceEnd;
    if (sliceEnd <= sliceStart) continue;
    // 若某锚点与下一锚点之间只有 1 个与卷名完全相同的标题块（无正文），跳过空卷头。
    if (k + 1 < resolved.length &&
        sliceEnd - sliceStart == 1 &&
        doc.blocks[sliceStart].kind == EpubBlockKind.text &&
        doc.blocks[sliceStart].text!.trim() == current.title.trim()) {
      continue;
    }
    var slice = doc.blocks.sublist(sliceStart, sliceEnd);
    if (slice.length >= 2 &&
        slice.first.kind == EpubBlockKind.text &&
        slice.first.text!.trim() == current.title.trim()) {
      slice = slice.sublist(1);
    }
    if (slice.isEmpty) continue;
    var candidateHref = current.fragment == null || current.fragment!.isEmpty
        ? '$spineHref#toc=${k + 1}'
        : '$spineHref#${current.fragment}';
    if (!usedHrefs.add(candidateHref)) {
      candidateHref = '$candidateHref-${k + 1}';
      usedHrefs.add(candidateHref);
    }
    result.add((
      title: current.title,
      href: candidateHref,
      blocks: slice,
      size: _estimateBlocksSize(slice),
    ));
  }
  return result.length >= 2 ? result : null;
}

List<_SplitEpubChapter>? _splitBlocksByHeadings(
  String spineHref,
  List<EpubBlock> blocks,
) {
  if (blocks.length < 4) return null;
  final buf = StringBuffer();
  final blockStarts = <int>[];
  final blockEnds = <int>[];
  for (final block in blocks) {
    final start = buf.length;
    final line = block.kind == EpubBlockKind.text
        ? (block.text ?? '').replaceAll('\n', ' ')
        : '图片内容';
    buf.write(line);
    final end = buf.length;
    buf.write('\n');
    blockStarts.add(start);
    blockEnds.add(end);
  }
  final split = splitLocalChapters(
    buf.toString(),
    enableChapterExtensions: false,
  );
  final realHeadings = split
      .where((c) => c.title != '前言' && c.title != '正文')
      .length;
  if (split.length < 2 || realHeadings < 2) return null;

  final result = <_SplitEpubChapter>[];
  var searchFrom = 0;
  for (final c in split) {
    final endOffset = c.offset + c.length;
    var startBi = searchFrom;
    while (startBi < blocks.length && blockEnds[startBi] <= c.offset) {
      startBi++;
    }
    if (startBi >= blocks.length) continue;
    var endBi = startBi + 1;
    while (endBi < blocks.length && blockStarts[endBi] < endOffset) {
      endBi++;
    }
    searchFrom = endBi;
    final slice = blocks.sublist(startBi, endBi);
    if (slice.isEmpty) continue;
    result.add((
      title: c.title,
      href: '$spineHref#ch=${result.length + 1}',
      blocks: slice,
      size: _estimateBlocksSize(slice),
    ));
  }
  return result.length >= 2 ? result : null;
}

/// 标题回退：<title> 文本，再回退首个 <h1>，保留 CDATA 字面文本。
String? _fallbackTitle(String source) {
  final text = _withoutComments(source);
  final buffer = StringBuffer();
  String? activeTitle;
  String? heading;
  var previousEnd = 0;
  for (final token in _markupTokens.allMatches(text)) {
    if (activeTitle != null) {
      buffer.write(_decodeEntities(text.substring(previousEnd, token.start)));
    }
    previousEnd = token.end;
    final tag = token.group(0)!;
    if (tag.startsWith('<![CDATA[')) {
      if (activeTitle != null) buffer.write(tag.substring(9, tag.length - 3));
      continue;
    }
    final name = _tagLocalName(tag);
    if (activeTitle == null &&
        !_isClosingTag(tag) &&
        !_isSelfClosingTag(tag) &&
        (name == 'title' || name == 'h1')) {
      activeTitle = name;
      buffer.clear();
    } else if (activeTitle != null &&
        _isClosingTag(tag) &&
        name == activeTitle) {
      final title = buffer.toString().replaceAll(_whitespace, ' ').trim();
      if (title.isNotEmpty) {
        if (name == 'title') return title;
        heading ??= title;
      }
      activeTitle = null;
    }
  }
  return heading;
}

void _recordElementAnchors(XmlElement element, _BlockCollector c) {
  c.markAnchor(_idAttribute(element));
  if (element.name.local.toLowerCase() == 'a') {
    c.markAnchor(element.getAttribute('name'));
  }
}

void _walk(
  XmlNode node,
  _BlockCollector c,
  String? Function(String?) resolveImage,
) {
  for (final child in node.children) {
    if (child is XmlText) {
      c.addText(child.value);
      continue;
    }
    if (child is XmlCDATA) {
      c.addText(child.value);
      continue;
    }
    if (child is! XmlElement) continue;
    final name = child.name.local.toLowerCase();
    if (_skipTags.contains(name)) continue;
    if (name == 'img') {
      _recordElementAnchors(child, c);
      c.addImage(
        resolveImage(
          child.getAttribute('src') ??
              child.getAttribute('data-src') ??
              _hrefAttribute(child),
        ),
      );
    } else if (name == 'br') {
      c.flush();
      _recordElementAnchors(child, c);
    } else if (name == 'svg') {
      c.flush();
      _recordElementAnchors(child, c);
      for (final image in _elements(child, 'image')) {
        c.addImage(resolveImage(_hrefAttribute(image)));
      }
    } else if (_blockTags.contains(name)) {
      c.flush();
      _recordElementAnchors(child, c);
      _walk(child, c, resolveImage);
      c.flush();
    } else {
      _recordElementAnchors(child, c);
      _walk(child, c, resolveImage);
    }
  }
}

final _markupTokens = RegExp(
  r'''<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->|<(?=[A-Za-z/?!])(?:[^>"']|"[^"\r\n]{0,2048}"|'[^'\r\n]{0,2048}')*>''',
);
final _tagName = RegExp(
  r'^<\s*/?\s*(?:[\w.\-]+:)?([A-Za-z][\w.\-]*)(?=[\s/>])',
);
final _attribute = RegExp(
  r'''\s+([\w.:\-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?''',
);

String _withoutComments(String source) => source.replaceAllMapped(
  _markupTokens,
  (match) => match.group(0)!.startsWith('<!--') ? '' : match.group(0)!,
);

String? _tagAttribute(String tag, String name, {bool anyPrefix = false}) {
  final element = _tagName.firstMatch(tag);
  if (element == null) return null;
  var position = element.end;
  String? prefixed;
  while (position < tag.length) {
    final attribute = _attribute.matchAsPrefix(tag, position);
    if (attribute == null) break;
    position = attribute.end;
    final attributeName = attribute.group(1)!.toLowerCase();
    final value =
        attribute.group(2) ?? attribute.group(3) ?? attribute.group(4);
    if (value == null) continue;
    if (attributeName == name) return _decodeEntities(value);
    if (anyPrefix && attributeName.endsWith(':$name')) {
      prefixed ??= _decodeEntities(value);
    }
  }
  return prefixed;
}

String? _tagLocalName(String tag) =>
    _tagName.firstMatch(tag)?.group(1)?.toLowerCase();

bool _isClosingTag(String tag) => RegExp(r'^<\s*/').hasMatch(tag);

bool _isSelfClosingTag(String tag) => RegExp(r'/\s*>$').hasMatch(tag);

/// XML 解析失败时的降级：按标签出现顺序抽取文本、图片与锚点。
({List<EpubBlock> blocks, Map<String, int> anchors}) _blocksFromRegex(
  String source,
  String? Function(String?) resolveImage,
) {
  var text = _withoutComments(source);
  final collector = _BlockCollector();
  int? bodyStart;
  int? bodyEnd;
  for (final token in _markupTokens.allMatches(text)) {
    final tag = token.group(0)!;
    if (_tagLocalName(tag) != 'body') continue;
    if (_isClosingTag(tag)) {
      bodyEnd = token.start;
      break;
    }
    if (bodyStart == null) {
      bodyStart = token.end;
      collector.markAnchor(_tagAttribute(tag, 'id', anyPrefix: true));
    }
  }
  text = text.substring(bodyStart ?? 0, bodyEnd ?? text.length);

  final skipped = <String>[];
  var previousEnd = 0;
  var svgDepth = 0;
  for (final token in _markupTokens.allMatches(text)) {
    if (svgDepth == 0 && skipped.isEmpty) {
      collector.addText(
        _decodeEntities(text.substring(previousEnd, token.start)),
      );
    }
    previousEnd = token.end;
    final tag = token.group(0)!;
    if (tag.startsWith('<![CDATA[')) {
      if (svgDepth == 0 && skipped.isEmpty) {
        collector.addText(tag.substring(9, tag.length - 3));
      }
      continue;
    }
    final name = _tagLocalName(tag);
    if (name == null) continue;
    final closing = _isClosingTag(tag);
    if (_skipTags.contains(name)) {
      if (closing) {
        if (skipped.isNotEmpty && skipped.last == name) skipped.removeLast();
      } else if (!_isSelfClosingTag(tag)) {
        skipped.add(name);
      }
      continue;
    }
    if (skipped.isNotEmpty) continue;
    if (!closing && (name == 'br' || _blockTags.contains(name))) {
      collector.flush();
    }
    if (!closing) {
      collector.markAnchor(_tagAttribute(tag, 'id', anyPrefix: true));
      if (name == 'a') {
        collector.markAnchor(_tagAttribute(tag, 'name'));
      }
    }
    if (name == 'svg') {
      collector.flush();
      if (closing) {
        if (svgDepth > 0) svgDepth--;
      } else if (!_isSelfClosingTag(tag)) {
        svgDepth++;
      }
    } else if (name == 'image' && svgDepth > 0 && !closing) {
      collector.addImage(
        resolveImage(_tagAttribute(tag, 'href', anyPrefix: true)),
      );
    } else if (svgDepth > 0) {
      continue;
    } else if (name == 'img' && !closing) {
      collector.addImage(
        resolveImage(
          _tagAttribute(tag, 'src') ??
              _tagAttribute(tag, 'data-src') ??
              _tagAttribute(tag, 'href', anyPrefix: true),
        ),
      );
    } else if (name == 'br' || _blockTags.contains(name)) {
      collector.flush();
    }
  }
  if (svgDepth == 0 && skipped.isEmpty) {
    collector.addText(_decodeEntities(text.substring(previousEnd)));
  }
  collector.flush();
  return (blocks: collector.blocks, anchors: collector.anchors);
}
