import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'chapter_splitter.dart';
export 'chapter_splitter.dart' show LocalChapterIndex;
import 'local_platform.dart';
import 'local_comic.dart';
export 'local_comic.dart'
    show
        ComicArchivePackage,
        ComicChapterInfo,
        ComicFolderManifest,
        ComicFolderPageEntry,
        ComicInfoMetadata,
        ComicSeriesCandidate,
        ComicSeriesManifest,
        ComicSeriesVolumeEntry,
        groupScannedComicVolumeSeries,
        hasExplicitComicPathHint,
        isCbzFileName,
        isComicImageFileName,
        isComicZipFile,
        isComicZipBytes;
import 'local_epub.dart';
import 'local_mobi.dart';
export 'local_mobi.dart' show isMobiFileName, extractMobiBook, MobiBookData;
import 'book_tags.dart';
import 'filename_tags.dart';
import 'legacy_cover.dart';
import 'local_record_removal.dart';
import 'portable_book_prepare.dart';
import 'recovery_archive.dart';
import 'regex_safety.dart';
import 'wenku_errors.dart';

part 'local_text_worker.dart';
part 'local_chapter_remap_journal.dart';

/// 本地图书 ID 段：避开文库在线 aid（通常远小于此），落在 int32 范围内，
/// 因此书架、历史、进度等既有 `id > 0` 逻辑无需改动。
const localNovelIdBase = 0x40000000;
const localTextMaxSourceBytes = 256 * 1024 * 1024;
const localEpubMaxSourceBytes = 1024 * 1024 * 1024;
const localTextMaxDecodedBytes = 3 * localTextMaxSourceBytes;
const localTextMaxReadCodeUnits = 4 * 1024 * 1024;

bool isLocalNovelId(int id) => id >= localNovelIdBase && id <= 0x7fffffff;
bool isLocalBook(int id) => isLocalNovelId(id);

class LocalOperationTimeoutException implements Exception {
  const LocalOperationTimeoutException(this.operation);
  final String operation;
  @override
  String toString() => '$operation 超时，请重试';
}

/// 扫描不完整时抛出的异常：entries 不可信，不能用于更新书库。
/// [reason] 为原生返回的原因：permission / enumeration_failed /
/// depth_limit / limit / null_result / unknown。
class IncompleteScanException implements Exception {
  const IncompleteScanException(this.reason, {this.isMangaFolder = false});
  final String reason;
  final bool isMangaFolder;

  String get _folderLabel => isMangaFolder ? '漫画文件夹' : '文件夹';

  /// 给用户看的提示文案。
  String get message => switch (reason) {
    'permission' => isMangaFolder
        ? '无法访问漫画文件夹，请重新选择漫画文件夹以授予访问权限'
        : '无法访问该文件夹，请重新选择文件夹以授予访问权限',
    'enumeration_failed' => '无法完整读取该$_folderLabel，请检查是否仍可访问后重试',
    'depth_limit' => '子文件夹层级太深，本次扫描未完成',
    'limit' => '文件数量超出扫描上限，本次扫描未完成',
    'null_result' => '未收到有效的扫描结果，请重试',
    'empty_result' => '扫描未找到文件，已保留原有书库，请确认$_folderLabel后重试',
    _ => '扫描未完成，请重试',
  };
}

enum LocalBookKind { txt, pdf, epub, comic }

LocalBookKind? localBookKindForFileName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.txt')) return LocalBookKind.txt;
  if (lower.endsWith('.pdf')) return LocalBookKind.pdf;
  if (lower.endsWith('.epub')) return LocalBookKind.epub;
  if (lower.endsWith('.cbz')) return LocalBookKind.comic;
  return null;
}

class _NonComicZipSkipException implements Exception {
  const _NonComicZipSkipException();
}

final _bookRevisionCache = Expando<String>();
final _bookChaptersCache = Expando<List<NovelChapter>>();
final _bookNovelCache = Expando<Novel>();
final _bookValidByteSizeCache = Expando<int>();

class _CachedEpubSession {
  _CachedEpubSession({
    required this.localPath,
    required this.fileSize,
    required this.fileModifiedMicros,
    required this.bookRevision,
    required this.sourceFingerprint,
    required this.package,
  });

  final String localPath;
  final int fileSize;
  final int fileModifiedMicros;
  final String bookRevision;
  final String sourceFingerprint;
  final EpubPackage package;
  int activeReaders = 0;
  bool evicted = false;

  Future<void> releaseIfIdle() async {
    if (evicted && activeReaders <= 0) {
      try {
        await package.close();
      } catch (_) {}
    }
  }
}

class _CachedComicSession {
  _CachedComicSession({
    required this.localPath,
    required this.fileSize,
    required this.fileModifiedMicros,
    required this.sourceFingerprint,
    required this.package,
  });

  final String localPath;
  final int fileSize;
  final int fileModifiedMicros;
  final String sourceFingerprint;
  final ComicArchivePackage package;
  int activeReaders = 0;
  bool evicted = false;

  void releaseIfIdle() {
    if (evicted && activeReaders <= 0) {
      try {
        package.close();
      } catch (_) {}
    }
  }
}

/// 是否为 Unicode 空白字符。
bool _isUnicodeWhitespace(int rune) {
  return (rune >= 0x0009 && rune <= 0x000D) ||
      rune == 0x0020 ||
      rune == 0x0085 ||
      rune == 0x00A0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200A) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202F ||
      rune == 0x205F ||
      rune == 0x3000;
}

/// 统计文本的非空白 Unicode 字符数（含标点）。
int _countWords(String text) {
  var count = 0;
  for (final rune in text.runes) {
    if (!_isUnicodeWhitespace(rune)) {
      count++;
    }
  }
  return count;
}

/// 格式化字数：小于1万显示"1234 字"，大于等于1万显示"12.3 万字"。
String _formatWordCount(int count) {
  if (count < 10000) return '$count 字';
  return '${(count / 10000).toStringAsFixed(1)} 万字';
}

String formatLocalWordCount(int count) => _formatWordCount(count);

class LocalBook {
  static const Object _unset = Object();

  const LocalBook({
    required this.id,
    required this.title,
    required this.author,
    required this.fileUri,
    required this.fileName,
    required this.kind,
    required this.size,
    required this.modified,
    required this.chapters,
    required this.pageCount,
    this.wordCount,
    this.customTitle,
    this.customAuthor,
    // 导入来源标识：'saf:<treeUri>' 或 'appFolder:novels'，用于按来源隔离清理。
    // 旧数据缺失时为 ''，不参与自动清理。
    this.sourceId = '',
    // 来源内稳定的文件身份：SAF 用 documentUri，应用文件夹用规范化绝对路径。
    this.sourceKey = '',
    this.chapterSplitVersion = 0,
    this.isMobiSource = false,
    this.textFingerprint = '',
    this.sourceFingerprint = '',
    this.epubChapterHrefs = const <String>[],
    this.coverEntry,
    this.customTocPattern,
    this.customMaxChapterChars = 0,
    this.isComicFolder = false,
    this.isComicSeries = false,
    this.isComicEpub = false,
    this.isMangaSource = false,
    this.isRtlProgression = false,
  });

  final int id;
  final String title;
  final String author;
  final String fileUri;
  final String fileName;
  final LocalBookKind kind;
  final int size;
  final int modified;
  final List<LocalChapterIndex> chapters;
  final int pageCount;

  /// 正文非空白 Unicode 字符数（含标点）；null 表示未统计。
  final int? wordCount;

  final String sourceId;
  final String sourceKey;

  /// 该书最近一次成功应用的章节切分规则版本。
  final int chapterSplitVersion;
  final bool isMobiSource;
  final String textFingerprint;

  /// SHA-256 of original bytes, including encoding/BOM/line endings.
  final String sourceFingerprint;

  /// EPUB spine 章节的 XHTML 路径，与 chapters 等长并行；非 EPUB 书为空。
  final List<String> epubChapterHrefs;

  /// EPUB / CBZ 封面图在 ZIP 内的路径；无封面时为 null。
  final String? coverEntry;

  /// 用户为单本 TXT 指定的目录正则与超长分节上限。
  final String? customTocPattern;
  final int customMaxChapterChars;

  bool get hasCustomChapterSplit =>
      (customTocPattern != null && customTocPattern!.isNotEmpty) ||
      customMaxChapterChars > 0;

  /// 是否为本地图片目录形态的漫画（无单一压缩包文件）。
  final bool isComicFolder;

  /// 是否为同文件夹多卷合并漫画（如 `Mgf_01.pdf` ~ `Mgf_14.pdf` 聚合成一本）。
  final bool isComicSeries;

  /// 是否为目录或多卷清单形态的漫画（无单一容器文件，不走单文件重命名）。
  bool get isDirectoryBackedComic => isComicFolder || isComicSeries;

  /// EPUB 是否被自动识别为固定版式/纯图流漫画 EPUB。
  final bool isComicEpub;

  /// 是否来自独立漫画文件夹或显式漫画目录/命名（无需手动切换漫画模式）。
  final bool isMangaSource;

  /// 是否天然属于漫画书（归档/目录/多卷漫画、漫画 EPUB、或来自漫画目录/漫画命名的 PDF）。
  bool get isIntrinsicManga =>
      kind == LocalBookKind.comic ||
      isComicEpub ||
      (kind == LocalBookKind.pdf &&
          (isMangaSource || sourceId.startsWith('saf_manga:')));

  /// 是否声明为日漫右翻（RTL）装订方向。
  final bool isRtlProgression;

  String get revision => _bookRevisionCache[this] ??= sha256
      .convert(
        utf8.encode(
          jsonEncode([
            textFingerprint,
            chapterSplitVersion,
            chapters.map((c) => c.toJson()).toList(),
          ]),
        ),
      )
      .toString();

  /// 用户手动覆盖的书名/作者，为空时用文件名解析结果。
  final String? customTitle;
  final String? customAuthor;

  /// 展示用书名/作者（优先用户覆盖）。
  String get displayTitle =>
      (customTitle ?? '').trim().isEmpty ? title : customTitle!.trim();
  String get displayAuthor =>
      (customAuthor ?? '').trim().isEmpty ? author : customAuthor!.trim();

  /// 注意：customTitle/customAuthor 传 null 表示清空（恢复文件名解析）；
  /// wordCount 传 null 则表示保留原值（用于字数补算）。
  LocalBook copyWith({
    String? title,
    String? author,
    String? fileUri,
    String? fileName,
    String? sourceKey,
    String? customTitle,
    String? customAuthor,
    int? wordCount,
    List<LocalChapterIndex>? chapters,
    String? sourceId,
    int? chapterSplitVersion,
    String? textFingerprint,
    String? sourceFingerprint,
    List<String>? epubChapterHrefs,
    String? coverEntry,
    Object? customTocPattern = _unset,
    int? customMaxChapterChars,
    bool? isComicFolder,
    bool? isComicSeries,
    bool? isComicEpub,
    bool? isMangaSource,
    bool? isRtlProgression,
  }) => LocalBook(
    id: id,
    title: title ?? this.title,
    author: author ?? this.author,
    fileUri: fileUri ?? this.fileUri,
    fileName: fileName ?? this.fileName,
    kind: kind,
    size: size,
    modified: modified,
    chapters: chapters ?? this.chapters,
    pageCount: pageCount,
    wordCount: wordCount ?? this.wordCount,
    customTitle: customTitle,
    customAuthor: customAuthor,
    sourceId: sourceId ?? this.sourceId,
    sourceKey: sourceKey ?? this.sourceKey,
    chapterSplitVersion: chapterSplitVersion ?? this.chapterSplitVersion,
    isMobiSource: isMobiSource,
    textFingerprint: textFingerprint ?? this.textFingerprint,
    sourceFingerprint: sourceFingerprint ?? this.sourceFingerprint,
    epubChapterHrefs: epubChapterHrefs ?? this.epubChapterHrefs,
    coverEntry: coverEntry ?? this.coverEntry,
    customTocPattern: identical(customTocPattern, _unset)
        ? this.customTocPattern
        : customTocPattern as String?,
    customMaxChapterChars: customMaxChapterChars ?? this.customMaxChapterChars,
    isComicFolder: isComicFolder ?? this.isComicFolder,
    isComicSeries: isComicSeries ?? this.isComicSeries,
    isComicEpub: isComicEpub ?? this.isComicEpub,
    isMangaSource: isMangaSource ?? this.isMangaSource,
    isRtlProgression: isRtlProgression ?? this.isRtlProgression,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'uri': fileUri,
    'name': fileName,
    'kind': kind.name,
    'size': size,
    'modified': modified,
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'pages': pageCount,
    'wordCount': wordCount,
    if (customTitle != null) 'customTitle': customTitle,
    if (customAuthor != null) 'customAuthor': customAuthor,
    if (sourceId.isNotEmpty) 'sourceId': sourceId,
    if (sourceKey.isNotEmpty) 'sourceKey': sourceKey,
    'chapterSplitVersion': chapterSplitVersion,
    if (isMobiSource) 'isMobiSource': true,
    'textFingerprint': textFingerprint,
    'sourceFingerprint': sourceFingerprint,
    if (epubChapterHrefs.isNotEmpty) 'epubChapterHrefs': epubChapterHrefs,
    if (coverEntry?.isNotEmpty ?? false) 'coverEntry': coverEntry,
    if (customTocPattern != null && customTocPattern!.isNotEmpty)
      'customTocPattern': customTocPattern,
    if (customMaxChapterChars > 0)
      'customMaxChapterChars': customMaxChapterChars,
    if (isComicFolder) 'isComicFolder': true,
    if (isComicSeries) 'isComicSeries': true,
    if (isComicEpub) 'isComicEpub': true,
    if (isMangaSource) 'isMangaSource': true,
    if (isRtlProgression) 'isRtlProgression': true,
  };

  factory LocalBook.fromJson(Map<String, Object?> json) {
    final chapters = json['chapters'];
    final rawCustomToc = json['customTocPattern'] as String?;
    return LocalBook(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String? ?? '未知标题',
      author: json['author'] as String? ?? '',
      fileUri: json['uri'] as String? ?? '',
      fileName: json['name'] as String? ?? '',
      kind: json['kind'] == 'pdf'
          ? LocalBookKind.pdf
          : json['kind'] == 'epub'
              ? LocalBookKind.epub
              : json['kind'] == 'comic'
                  ? LocalBookKind.comic
                  : LocalBookKind.txt,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modified: (json['modified'] as num?)?.toInt() ?? 0,
      chapters: chapters is List
          ? chapters
                .whereType<Map<String, Object?>>()
                .map(LocalChapterIndex.fromJson)
                .toList()
          : const [],
      pageCount: (json['pages'] as num?)?.toInt() ?? 0,
      wordCount: (json['wordCount'] as num?)?.toInt(),
      customTitle: json['customTitle'] as String?,
      customAuthor: json['customAuthor'] as String?,
      sourceId: json['sourceId'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? '',
      chapterSplitVersion: (json['chapterSplitVersion'] as num?)?.toInt() ?? 0,
      isMobiSource: json['isMobiSource'] == true,
      textFingerprint: json['textFingerprint'] as String? ?? '',
      sourceFingerprint: json['sourceFingerprint'] as String? ?? '',
      epubChapterHrefs: (json['epubChapterHrefs'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
      coverEntry:
          json['coverEntry'] is String ? json['coverEntry'] as String : null,
      customTocPattern: (rawCustomToc == null || rawCustomToc.trim().isEmpty)
          ? null
          : rawCustomToc.trim(),
      customMaxChapterChars:
          (json['customMaxChapterChars'] as num?)?.toInt() ?? 0,
      isComicFolder: json['isComicFolder'] == true,
      isComicSeries: json['isComicSeries'] == true,
      isComicEpub: json['isComicEpub'] == true,
      isMangaSource: json['isMangaSource'] == true,
      isRtlProgression: json['isRtlProgression'] == true,
    );
  }
}

class LocalScanResult {
  const LocalScanResult({
    required this.added,
    required this.refreshed,
    required this.removed,
    required this.total,
    required this.skipped,
    this.backfilled = 0,
    this.failures = const {},
    this.switchedRemovedIds = const [],
    this.chapterRemaps = const [],
  });
  final int added;
  final int refreshed;
  final int removed;
  final int total;
  final int skipped;

  /// 静默补算了字数的旧书数量（不计入 added/refreshed，不弹提示）。
  final int backfilled;
  final Map<String, String> failures;

  /// 文件夹切换时被清理的旧来源书籍 ID（调用方据此清理书架/标签/进度）。
  final List<int> switchedRemovedIds;

  /// 章节重切（切分规则升级）导致章节表变化的书：调用方须据此迁移阅读
  /// 进度（旧章节序号在新章节表下指向不同内容）。这里返回的是持久化
  /// 的待迁移任务（见 [LocalChapterRemap]），不只是本轮新发现的变化：
  /// 上轮已落盘新章节表、但进度尚未迁移确认的任务，下次扫描仍会返回。
  final List<LocalChapterRemap> chapterRemaps;
}

typedef LocalScanProgress = ({
  bool scanning,
  int processed,
  int total,
  int added,
  int revision,
});

const LocalScanProgress _idleScanProgress = (
  scanning: false,
  processed: 0,
  total: 0,
  added: 0,
  revision: 0,
);

final Expando<ValueNotifier<LocalScanProgress>> _localScanProgressNotifiers =
    Expando<ValueNotifier<LocalScanProgress>>('localScanProgress');

/// 返回给定 [store] 的扫描与变更进度通知器（基于 [Expando]，不触发 Fake.noSuchMethod）。
ValueNotifier<LocalScanProgress> localScanProgressFor(LocalLibraryStore store) {
  return _localScanProgressNotifiers[store] ??=
      ValueNotifier<LocalScanProgress>(_idleScanProgress);
}

/// 章节切分规则版本；与应用版本独立。
const _chapterSplitVersion = 5;
const _extendedChapterSplitVersion = 6;
const _localOperationTimeout = Duration(seconds: 12);

const _shelfPalette = [
  [Color(0xFF2B4C7E), Color(0xFF4A74AD)],
  [Color(0xFF1E5B6E), Color(0xFF398599)],
  [Color(0xFF38437A), Color(0xFF5E6BA8)],
  [Color(0xFF2C4259), Color(0xFF516E8C)],
  [Color(0xFF25567B), Color(0xFF4782AC)],
  [Color(0xFF434A75), Color(0xFF6A73A3)],
];

String formatLocalSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 源文件已删除，但书籍记录保存失败（记录已恢复，可重试）。
class BookCleanupFailed implements Exception {
  const BookCleanupFailed(this.message);
  final String message;
}

List _decodeIndexJson(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map || decoded['books'] is! List) {
    throw const FormatException('本地书库索引格式错误');
  }
  return decoded['books'] as List;
}

List<String> _encodeBooksJson(List<LocalBook> books) => [
  for (final book in books) jsonEncode(book.toJson()),
];

void _recordScanFailure(Map<String, String> failures, String name, Object error) {
  final detail = describeLocalScanError(error);
  failures['$name ($detail)'] = detail;
}

({List<LocalBook> books, List<Object?> unparsed}) _parseIndexEntries(
  List entries,
) {
  final books = <LocalBook>[];
  final unparsed = <Object?>[];
  final loadedIds = <int>{};
  for (final entry in entries) {
    try {
      if (entry is! Map<String, Object?>) {
        throw const FormatException('invalid book record');
      }
      final loaded = LocalBook.fromJson(entry);
      if (isLocalNovelId(loaded.id) && loadedIds.add(loaded.id)) {
        books.add(loaded);
      } else {
        throw const FormatException('invalid or duplicate book id');
      }
    } catch (_) {
      unparsed.add(entry);
    }
  }
  return (books: books, unparsed: unparsed);
}

Future<({List<LocalBook> books, List<Object?> unparsed})>
_decodeAndParseIndexFile(File file) async {
  final raw = await file.readAsString();
  if (raw.length < 65536) return _parseIndexEntries(_decodeIndexJson(raw));
  return Isolate.run(() => _parseIndexEntries(_decodeIndexJson(raw)));
}

({bool indexReadable, bool hasBadEntry}) _inspectIndexJson(
  String raw,
  Set<String> preserved,
) {
  try {
    final entries = _decodeIndexJson(raw);
    final ids = <int>{};
    try {
      for (final entry in entries) {
        if (preserved.isNotEmpty && preserved.contains(jsonEncode(entry))) {
          continue;
        }
        final book = LocalBook.fromJson(
          Map<String, Object?>.from(entry as Map),
        );
        if (!isLocalNovelId(book.id) || !ids.add(book.id)) {
          throw const FormatException('invalid index record');
        }
      }
    } catch (_) {
      return (indexReadable: true, hasBadEntry: true);
    }
    return (indexReadable: true, hasBadEntry: false);
  } catch (_) {
    return (indexReadable: false, hasBadEntry: false);
  }
}

/// 本地图书仓库：SAF 文件夹扫描、TXT 章节切分、PDF 页数。
/// 实现 [NovelRepository]，本地图书 id 落在 [localNovelIdBase] 段。
class LocalLibraryStore extends NovelRepository with ChangeNotifier {
  LocalLibraryStore._(
    this._prefs,
    this._supportDir,
    this._operationTimeout,
    this._textWorker,
  ) {
    _liveStores.add(this);
    _ensureCoverLoaderRegistered();
  }

  static final Set<LocalLibraryStore> _liveStores = <LocalLibraryStore>{};
  static bool _coverLoaderRegistered = false;

  static void _ensureCoverLoaderRegistered() {
    if (_coverLoaderRegistered) return;
    _coverLoaderRegistered = true;
    LegacyCover.registerLocalLoader(
      canLoad: (id) {
        for (final store in _liveStores.toList().reversed) {
          final book = store.bookFor(id);
          if (book != null) return store._canLoadCoverForBook(book);
        }
        return false;
      },
      load: (id) async {
        for (final store in _liveStores.toList().reversed) {
          final book = store.bookFor(id);
          if (book != null) return store.extractLocalCoverBytes(id);
        }
        throw const FormatException('本地书籍没有远程封面');
      },
    );
  }

  final SharedPreferences _prefs;
  final Directory _supportDir;
  final Duration _operationTimeout;
  final _LocalTextWorker _textWorker;
  int get _activeChapterSplitVersion => _textWorker.enableChapterExtensions
      ? _extendedChapterSplitVersion
      : _chapterSplitVersion;
  int _chapterSplitVersionFor(LocalBook book) =>
      book.kind == LocalBookKind.txt &&
          !book.isMobiSource &&
          !isMobiFileName(book.fileName)
      ? _activeChapterSplitVersion
      : _chapterSplitVersion;
  final _LocalTextWorker _readerWorker = _LocalTextWorker();
  final List<LocalBook> _books = [];
  final List<Object?> _unparsedIndexEntries = [];
  bool _disposed = false;
  int _indexGeneration = 0;
  final Map<int, int> _bookPositions = {};
  final Map<int, LocalBook> _savedBookRefs = {};
  final Map<int, ({LocalBook book, String encoded})> _encodedBookJsonCache = {};
  ({int size, int modified})? _lastValidIndexStat;
  final LinkedHashMap<int, String> _textCache = LinkedHashMap();
  final Map<int, Future<String>> _textReads = {};
  static const _textCacheBudget = 8 * 1024 * 1024;
  var _textCacheBytes = 0;
  int _nextIdCursor = localNovelIdBase;
  int _reservedIdEnd = localNovelIdBase;
  final Set<int> _dirtyBookIds = {};
  final Map<String, String> _tagMigrationFailures = {};
  Future<LocalScanResult>? _activeScan;

  void _updateScanProgress({
    bool? scanning,
    int? processed,
    int? total,
    int? added,
    bool bumpRevision = false,
  }) {
    if (_disposed) return;
    final notifier = localScanProgressFor(this);
    final current = notifier.value;
    notifier.value = (
      scanning: scanning ?? current.scanning,
      processed: processed ?? current.processed,
      total: total ?? current.total,
      added: added ?? current.added,
      revision: bumpRevision ? current.revision + 1 : current.revision,
    );
  }

  /// EPUB 源文件指纹缓存：路径 -> (大小, 修改时间, 已算出的 sha256)。
  /// 只有大小或修改时间变化才重算；书修订变化/删除/重扫时整体清空。
  final Map<String, ({int size, int modified, String digest})>
  _epubFingerprintCache = {};

  /// 已解压的 EPUB 图片字节，键为“书 id + 修订 + entryPath”。
  /// 总量超过 [_epubImageCacheBudget] 时按插入顺序淘汰旧条目。
  final LinkedHashMap<String, Uint8List> _epubImageCache = LinkedHashMap();
  static const _epubImageCacheBudget = 64 * 1024 * 1024;
  var _epubImageCacheBytes = 0;

  /// 已切片的 TXT 单章正文缓存，键为“书 id + 修订 + 章序号”，避免 1~8 MB 小说首次开章或大书切章重复解码。
  final LinkedHashMap<String, String> _chapterSliceCache = LinkedHashMap();
  static const _chapterSliceCacheBudget = 4 * 1024 * 1024;
  static const _chapterSliceCacheMaxEntries = 48;
  var _chapterSliceCacheBytes = 0;

  /// 已打开的 EPUB 会话缓存（LRU 最多保留 3 本），避免每次切章重复哈希、解压中央目录与解析 OPF/NCX。
  final LinkedHashMap<int, _CachedEpubSession> _epubSessionCache =
      LinkedHashMap();
  static const _epubSessionCacheMaxEntries = 3;
  final LinkedHashMap<int, _CachedComicSession> _comicSessionCache =
      LinkedHashMap();
  final Map<int, ComicFolderManifest> _comicManifestCache = {};
  final Map<int, ComicSeriesManifest> _comicSeriesCache = {};
  final LinkedHashMap<String, String> _comicSeriesVolumeFiles =
      LinkedHashMap();
  static const _comicSeriesVolumeCacheMaxEntries = 2;

  /// 串行化所有变更操作，防止扫描/删除/编辑竞态（修复#4）。
  Future<void> _mutationLock = Future.value();

  Future<T> _synchronized<T>(
    Future<T> Function() action, {
    Duration? timeout,
    String operation = '本地操作',
    bool recoverChapterRemaps = true,
  }) {
    if (_disposed) return Future.error(StateError('本地书库已关闭'));
    var expired = false;
    var started = false;
    final next = _mutationLock.then((_) async {
      // A caller that timed out in the queue must never start mutating later.
      if (expired) throw LocalOperationTimeoutException('$operation等待本地操作锁');
      started = true;
      if (recoverChapterRemaps) await _recoverChapterRemaps();
      return action();
    });
    // Keep ownership until the real action finishes. Future.timeout alone
    // cannot cancel file/prefs writes and must not unlock them early.
    _mutationLock = next.then<void>((_) {}, onError: (_) {});
    if (timeout == null) return next;
    return next.timeout(
      timeout,
      onTimeout: () {
        expired = true;
        throw LocalOperationTimeoutException(
          started ? operation : '$operation等待本地操作锁',
        );
      },
    );
  }

  static Future<LocalLibraryStore> load({
    bool enableChapterExtensions = defaultChapterExtensionsEnabled,
    Duration operationTimeout = _localOperationTimeout,
    Duration workerReadyTimeout = const Duration(seconds: 3),
    Duration workerReplyTimeout = const Duration(minutes: 2),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final support = await getApplicationSupportDirectory();
    final store = LocalLibraryStore._(
      prefs,
      support,
      operationTimeout,
      _LocalTextWorker(
        enableChapterExtensions: enableChapterExtensions,
        readyTimeout: workerReadyTimeout,
        replyTimeout: workerReplyTimeout,
      ),
    );
    await store._loadIndex();
    // 索引已加载进 _books 后，先记录已持久化的章节表快照，
    // 再向 UI 发布书库前恢复仅移出待办。
    store._captureSavedRemapRanges();
    try {
      await store._synchronized(() async {
        await store._recordRemovalJournal.recover();
        await store._saveIndex();
        await store._recoverDataCleanup();
        await store._migrateInternalTagsToFilenames();
      });
    } catch (_) {
      store.dispose();
      rethrow;
    }
    return store;
  }

  Directory get _booksDir => Directory('${_supportDir.path}/local_books');
  Directory get directory => _booksDir;

  String? get folderUri => _prefs.getString('local_library_folder');
  String? get mangaFolderUri => _prefs.getString('local_library_manga_folder');

  List<LocalBook> get books => List.unmodifiable(_books);

  /// Last per-book failures while copying internal tags into source filenames.
  Map<String, String> get tagMigrationFailures =>
      Map.unmodifiable(_tagMigrationFailures);

  LocalBook? bookFor(int id) {
    final index = _indexForBook(id);
    return index < 0 ? null : _books[index];
  }

  Novel? novelFor(int id) {
    final found = bookFor(id);
    return found == null ? null : toNovel(found);
  }

  List<Novel> get novels =>
      List.unmodifiable([for (final item in _books) toNovel(item)]);

  LocalBookKind? kindFor(int id) => bookFor(id)?.kind;

  Future<void> _loadIndex() async {
    final file = File('${_booksDir.path}/index.json');
    _nextIdCursor =
        localNovelIdBase + (_prefs.getInt('local_library_next') ?? 0);
    _reservedIdEnd = _nextIdCursor;
    final backup = File('${file.path}.bak');
    if (!await file.exists() && !await backup.exists()) return;
    late ({List<LocalBook> books, List<Object?> unparsed}) parsed;
    var loadedFromPrimary = false;
    try {
      parsed = await _decodeAndParseIndexFile(file);
      loadedFromPrimary = true;
    } catch (_) {
      try {
        parsed = await _decodeAndParseIndexFile(backup);
      } catch (_) {
        throw const FormatException('本地书库索引及备份无法读取，已停止写入');
      }
    }
    for (final loaded in parsed.books) {
      final book = loaded.isDirectoryBackedComic ||
              parseFilenameTags(loaded.fileName).tags.isEmpty
          ? loaded
          : _withFilenameMetadata(loaded, loaded.fileName);
      _books.add(book);
      if (book.title != loaded.title || book.author != loaded.author) {
        _dirtyBookIds.add(book.id);
      }
    }
    _unparsedIndexEntries.addAll(parsed.unparsed);
    if (loadedFromPrimary && _unparsedIndexEntries.isEmpty) {
      try {
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file) {
          _lastValidIndexStat = (
            size: stat.size,
            modified: stat.modified.microsecondsSinceEpoch,
          );
        }
      } catch (_) {}
    }
    // 校正 ID 计数器，防止复用（修复#17）。
    var maxId = localNovelIdBase - 1;
    for (final book in _books) {
      if (book.id > maxId) maxId = book.id;
    }
    for (final entry in _unparsedIndexEntries) {
      if (entry is Map && entry['id'] is int) {
        final id = entry['id'] as int;
        if (isLocalNovelId(id) && id > maxId) maxId = id;
      }
    }
    final saved = _prefs.getInt('local_library_next') ?? 0;
    final need = maxId - localNovelIdBase + 1;
    final next = saved > need ? saved : need;
    _nextIdCursor = localNovelIdBase + next;
    _reservedIdEnd = _nextIdCursor;
    if (need > saved) await _prefs.setInt('local_library_next', need);
    _rebuildBookPositions();
    _savedBookRefs
      ..clear()
      ..addEntries(_books.map((book) => MapEntry(book.id, book)));
  }

  int get unreadableIndexRecordCount => _unparsedIndexEntries.length;

  void _rebuildBookPositions() {
    _bookPositions
      ..clear()
      ..addEntries(
        _books.asMap().entries.map(
          (entry) => MapEntry(entry.value.id, entry.key),
        ),
      );
  }

  int _indexForBook(int id) => _bookPositions[id] ?? -1;

  void _replaceBook(int index, LocalBook book) {
    if (index < 0 || index >= _books.length || _books[index].id != book.id) {
      throw StateError('书籍记录已变化，请重新扫描');
    }
    if (_books[index].revision != book.revision ||
        _books[index].sourceFingerprint != book.sourceFingerprint) {
      _invalidateTextCache(book.id);
    }
    _books[index] = book;
    _bookPositions[book.id] = index;
    _dirtyBookIds.add(book.id);
  }

  void _addBook(LocalBook book) {
    _bookPositions[book.id] = _books.length;
    _books.add(book);
    _dirtyBookIds.add(book.id);
  }

  void _removeBook(LocalBook book) {
    final index = _indexForBook(book.id);
    if (index < 0) return;
    _dirtyBookIds.add(book.id);
    _books.removeAt(index);
    _rebuildBookPositions();
    _invalidateTextCache(book.id);
  }

  void _removeBooks(Iterable<LocalBook> books) {
    final ids = books.map((book) => book.id).toSet();
    if (ids.isEmpty) return;
    _dirtyBookIds.addAll(ids);
    _books.removeWhere((book) => ids.contains(book.id));
    _rebuildBookPositions();
    for (final id in ids) {
      _invalidateTextCache(id);
    }
  }

  void _invalidateTextCache(int id) {
    final old = _textCache.remove(id);
    if (old != null) _textCacheBytes -= old.length * 2;
    _textReads.remove(id);
    final slicePrefix = '$id\u0000';
    final staleSlices = [
      for (final key in _chapterSliceCache.keys)
        if (key.startsWith(slicePrefix)) key,
    ];
    for (final key in staleSlices) {
      _chapterSliceCacheBytes -= _chapterSliceCache.remove(key)!.length * 2;
    }
    _invalidateEpubCaches(id);
    LegacyCover.evict(id);
  }

  void _cacheChapterSlice(String key, String text) {
    final size = text.length * 2;
    if (size > _chapterSliceCacheBudget) return;
    final old = _chapterSliceCache.remove(key);
    if (old != null) _chapterSliceCacheBytes -= old.length * 2;
    while (_chapterSliceCache.isNotEmpty &&
        (_chapterSliceCache.length >= _chapterSliceCacheMaxEntries ||
            _chapterSliceCacheBytes + size > _chapterSliceCacheBudget)) {
      final oldest = _chapterSliceCache.keys.first;
      _chapterSliceCacheBytes -= _chapterSliceCache.remove(oldest)!.length * 2;
    }
    _chapterSliceCache[key] = text;
    _chapterSliceCacheBytes += size;
  }

  void _evictEpubSession(_CachedEpubSession session) {
    session.evicted = true;
    unawaited(session.releaseIfIdle());
  }

  void _evictComicSession(_CachedComicSession session) {
    session.evicted = true;
    session.releaseIfIdle();
  }

  /// 书修订变化、删除或重扫时调用：清掉该书的图片字节缓存，
  /// 指纹缓存按路径存放，无法可靠映射到书，直接整体清空（代价只是下次重算一次）。
  void _invalidateEpubCaches(int id) {
    _epubFingerprintCache.clear();
    final session = _epubSessionCache.remove(id);
    if (session != null) _evictEpubSession(session);
    final comicSession = _comicSessionCache.remove(id);
    if (comicSession != null) _evictComicSession(comicSession);
    _comicManifestCache.remove(id);
    _comicSeriesCache.remove(id);
    final volPrefix = '$id:';
    for (final k in _comicSeriesVolumeFiles.keys
        .where((k) => k.startsWith(volPrefix))
        .toList()) {
      _comicSeriesVolumeFiles.remove(k);
    }
    final prefix = '$id\u0000';
    final stale = [
      for (final key in _epubImageCache.keys)
        if (key.startsWith(prefix)) key,
    ];
    for (final key in stale) {
      _epubImageCacheBytes -= _epubImageCache.remove(key)!.length;
    }
  }

  void _clearEpubCaches() {
    _epubFingerprintCache.clear();
    for (final session in _epubSessionCache.values) {
      _evictEpubSession(session);
    }
    _epubSessionCache.clear();
    for (final session in _comicSessionCache.values) {
      _evictComicSession(session);
    }
    _comicSessionCache.clear();
    _comicManifestCache.clear();
    _comicSeriesCache.clear();
    _comicSeriesVolumeFiles.clear();
    _epubImageCache.clear();
    _epubImageCacheBytes = 0;
  }

  /// EPUB 的 revision 只由章节标题等组成，不含源文件内容；
  /// 键里再加已校验的源文件指纹，图片换了但标题没变时也不会命中旧字节。
  String _epubImageKey(LocalBook book, String entryPath) =>
      '${book.id}\u0000${book.revision}\u0000${book.sourceFingerprint}'
      '\u0000$entryPath';

  void _cacheEpubImage(String key, Uint8List bytes) {
    if (bytes.length > _epubImageCacheBudget) return;
    final old = _epubImageCache.remove(key);
    if (old != null) _epubImageCacheBytes -= old.length;
    while (_epubImageCache.isNotEmpty &&
        _epubImageCacheBytes + bytes.length > _epubImageCacheBudget) {
      final oldest = _epubImageCache.keys.first;
      _epubImageCacheBytes -= _epubImageCache.remove(oldest)!.length;
    }
    _epubImageCache[key] = bytes;
    _epubImageCacheBytes += bytes.length;
  }

  void _cacheText(int id, String text) {
    final size = text.length * 2;
    if (size > _textCacheBudget) return;
    final old = _textCache.remove(id);
    if (old != null) _textCacheBytes -= old.length * 2;
    _textCache[id] = text;
    _textCacheBytes += size;
    while (_textCacheBytes > _textCacheBudget && _textCache.isNotEmpty) {
      final first = _textCache.entries.first;
      _textCache.remove(first.key);
      _textCacheBytes -= first.value.length * 2;
    }
  }

  LocalBook _withFilenameMetadata(
    LocalBook book,
    String fileName, {
    String? fileUri,
    String? sourceKey,
  }) {
    final parsedAuthor = _authorFromName(fileName);
    return book.copyWith(
      title: _titleFromName(fileName),
      author: parsedAuthor.isNotEmpty || book.kind != LocalBookKind.comic
          ? parsedAuthor
          : book.author,
      fileUri: fileUri ?? book.fileUri,
      fileName: fileName,
      sourceKey: sourceKey ?? book.sourceKey,
      customTitle: book.customTitle,
      customAuthor: book.customAuthor,
    );
  }

  Future<LocalBook> _renameSourceFile(LocalBook book, String targetName) async {
    if (targetName == book.fileName) return book;
    final openEpub = _epubSessionCache.remove(book.id);
    if (openEpub != null) {
      openEpub.evicted = true;
      await openEpub.releaseIfIdle();
    }
    final openComic = _comicSessionCache.remove(book.id);
    if (openComic != null) {
      openComic.evicted = true;
      openComic.releaseIfIdle();
    }
    if (utf8.encode(targetName).length > 255) {
      throw ArgumentError('文件名超过 255 字节，请缩短书名或标签');
    }
    if (targetName.isEmpty ||
        targetName.contains(RegExp(r'[/\\\x00]')) ||
        targetName == '.' ||
        targetName == '..') {
      throw ArgumentError('标签无法写入文件名：包含路径分隔符或空字符');
    }
    if (book.fileUri.startsWith('content:')) {
      final identity = LocalSourceIdentity.forBook(
        sourceId: book.sourceId,
        sourceKey: book.sourceKey,
        fileUri: book.fileUri,
        folderUri: folderUri,
      );
      final treeUriStr = identity.sourceId.startsWith('saf_manga:')
          ? identity.sourceId.substring('saf_manga:'.length)
          : identity.sourceId.startsWith('saf:')
              ? identity.sourceId.substring('saf:'.length)
              : null;
      final tree = treeUriStr != null ? Uri.tryParse(treeUriStr) : null;
      final document = Uri.tryParse(book.fileUri);
      if (tree == null ||
          tree.scheme != 'content' ||
          tree.pathSegments.length != 2 ||
          tree.pathSegments.first != 'tree' ||
          document == null ||
          document.authority != tree.authority ||
          document.hasQuery ||
          document.hasFragment ||
          document.pathSegments.length != 4 ||
          document.pathSegments[0] != 'tree' ||
          document.pathSegments[1] != tree.pathSegments[1] ||
          document.pathSegments[2] != 'document') {
        throw StateError('文件不在来源目录内');
      }
      try {
        final result = await LocalPlatform.renameLocalDocument(
          book.fileUri,
          targetName,
          expectedFileName: book.fileName,
        );
        return _withFilenameMetadata(
          book,
          result.fileName,
          fileUri: result.fileUri,
          sourceKey: result.sourceKey,
        );
      } on LocalRenameException catch (error) {
        // A successful native rollback may issue a different URI. Preserve
        // that confirmed location even though the tag edit itself failed.
        if (error.fileUri != null &&
            error.fileName != null &&
            (error.fileUri != book.fileUri ||
                error.fileName != book.fileName)) {
          _replaceBook(
            _indexForBook(book.id),
            _withFilenameMetadata(
              book,
              error.fileName!,
              fileUri: error.fileUri,
              sourceKey: error.fileUri,
            ),
          );
          try {
            await _saveIndex();
          } catch (_) {
            /* Keep dirty location for retry. */
          }
        }
        rethrow;
      }
    }

    final source = _sourceFile(book);
    final isCloudImported = book.sourceId == 'cloud:imported';
    final allowedDir = isCloudImported
        ? Directory('${_booksDir.path}/cloud_originals')
        : Directory(await appFolderPath);
    if (!await allowedDir.exists()) {
      throw StateError('文件不在本地书库目录内');
    }
    final root = await allowedDir.resolveSymbolicLinks();
    final resolved = await source.resolveSymbolicLinks();
    final separator = Platform.pathSeparator;
    if (!resolved.startsWith('$root$separator')) {
      throw StateError('文件不在本地书库目录内');
    }
    final parent = source.parent;
    var diskTargetName = targetName;
    if (isCloudImported) {
      final currentDiskName = source.uri.pathSegments.isNotEmpty
          ? source.uri.pathSegments.last
          : source.path.split(separator).last;
      final prefixMatch = RegExp(
        r'^[0-9a-f]{16}_',
      ).firstMatch(currentDiskName);
      if (prefixMatch != null) {
        diskTargetName = '${prefixMatch.group(0)!}$targetName';
      }
    }
    if (utf8.encode(diskTargetName).length > 255) {
      throw ArgumentError('文件名超过 255 字节，请缩短书名或标签');
    }
    final target = File('${parent.path}/$diskTargetName');
    if (target.path != source.path && await target.exists()) {
      throw StateError('同名文件已存在');
    }
    final renamed = await source.rename(target.path);
    return _withFilenameMetadata(
      book,
      targetName,
      fileUri: Uri.file(renamed.path).toString(),
      sourceKey: renamed.path,
    );
  }

  File _sourceFile(LocalBook book) {
    final locator = book.sourceKey.isNotEmpty ? book.sourceKey : book.fileUri;
    if (locator.isEmpty) throw StateError('文件路径无效');
    if (locator.startsWith('file:')) {
      if (locator.startsWith('file://') &&
          !locator.contains('%') &&
          File(locator.substring('file://'.length)).isAbsolute) {
        return File(locator.substring('file://'.length));
      }
      final parsed = Uri.tryParse(locator);
      if (parsed != null && parsed.scheme == 'file') {
        return File.fromUri(parsed);
      }
      if (locator.startsWith('file://')) {
        return File(locator.substring('file://'.length));
      }
    }
    return File(locator);
  }

  /// Saves a renamed source location before committing its tag mapping. A
  /// rejected source rename never changes the index or internal tags.
  Future<LocalBook> _commitFilename(
    LocalBook original,
    String targetName, {
    Future<void> Function()? commitTags,
  }) async {
    final updated = await _renameSourceFile(original, targetName);
    try {
      if (!identical(original, updated)) {
        _replaceBook(_indexForBook(original.id), updated);
        await _saveIndex();
      }
      if (commitTags != null) {
        // A previous folder-switch fallback must not resurrect deselected
        // tags when the next scan restores stashed records for this filename.
        await _clearTagStashKeys([original], clearBookTags: false);
        await commitTags();
      }
      return updated;
    } catch (error, stack) {
      if (!identical(original, updated)) {
        await _restoreRenamedBooks([original], cause: error);
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _restoreRenamedBooks(
    Iterable<LocalBook> originals, {
    required Object cause,
  }) async {
    final failures = <String>[];
    for (final original in originals.toList().reversed) {
      final current = bookFor(original.id);
      if (current == null) continue;
      try {
        final restored = await _renameBack(original, current);
        _replaceBook(_indexForBook(original.id), restored);
      } catch (error) {
        // Keep the actual new URI available if the provider rejects rollback.
        failures.add(
          '${original.displayTitle}：${describeSafeError(error, fallback: '回滚失败')}',
        );
      }
    }
    try {
      await _saveIndex();
    } catch (error) {
      failures.add(
        '恢复后的索引保存失败：${describeSafeError(error, fallback: '索引保存失败')}',
      );
    }
    if (failures.isNotEmpty) {
      throw StateError(
        '${describeSafeError(cause, fallback: '文件操作失败')}；回滚未完成：${failures.join('；')}',
      );
    }
  }

  /// No global "done" bit: matching filenames are already migrated; failed
  /// books retain their internal tags and are retried on the next scan/load.
  Future<void> _migrateInternalTagsToFilenames({
    String? sourceId,
    Map<String, String>? failures,
  }) async {
    final tagStore = TagStore.maybeShared;
    if (tagStore == null) return;
    _tagMigrationFailures.clear();
    for (final original in _books.toList()) {
      if (sourceId != null && original.sourceId != sourceId) continue;
      final current = bookFor(original.id);
      if (current == null || current.isDirectoryBackedComic) continue;
      try {
        await tagStore.mergeTagNamesForBook(
          current.id,
          parseFilenameTags(current.fileName).tags,
        );
        final names = tagStore.tagNamesForBook(current.id);
        final parsedNames = parseFilenameTags(current.fileName).tags.toSet();
        // Avoid touching already migrated filenames or reordering their tags.
        if (names.every(parsedNames.contains)) continue;
        final targetName = appendFilenameTags(current.fileName, names);
        await _commitFilename(current, targetName);
      } catch (error) {
        final key = current.displayTitle;
        final message = describeSafeError(error, fallback: '标签迁移失败');
        _tagMigrationFailures[key] = message;
        failures?[key] = message;
      }
    }
  }

  Future<void> _saveIndex() async {
    if (_dirtyBookIds.isEmpty) return;
    final changedIds = Set<int>.of(_dirtyBookIds);
    final snapshot = {for (final book in _books) book.id: book};
    _encodedBookJsonCache.removeWhere(
      (id, cached) => !identical(snapshot[id], cached.book),
    );
    final uncached = [
      for (final book in snapshot.values)
        if (!_encodedBookJsonCache.containsKey(book.id)) book,
    ];
    if (uncached.isNotEmpty) {
      final encodedList = uncached.length < 64
          ? _encodeBooksJson(uncached)
          : await Isolate.run(() => _encodeBooksJson(uncached));
      for (var i = 0; i < uncached.length; i++) {
        final book = uncached[i];
        _encodedBookJsonCache[book.id] = (book: book, encoded: encodedList[i]);
      }
    }
    final dir = _booksDir;
    if (!await dir.exists()) await dir.create(recursive: true);
    final encodedEntries = <String>[
      for (final book in snapshot.values)
        _encodedBookJsonCache[book.id]!.encoded,
      for (final entry in _unparsedIndexEntries) jsonEncode(entry),
    ];
    final json = '{"books":[${encodedEntries.join(',')}]}';
    // 原子写入：先写临时文件再重命名，避免崩溃丢索引（修复#5）。
    final tmp = File('${dir.path}/index.json.tmp');
    final target = File('${dir.path}/index.json');
    await tmp.writeAsString(json, flush: true);
    // 保留上一次的备份：只要旧 index 能整体解码就先刷 .bak，
    // 坏条只额外留一份 .corrupt，不再让坏条阻止 .bak 刷新。
    if (await target.exists()) {
      var indexReadable = false;
      var hasBadEntry = false;
      final stat = await target.stat();
      final validStat = _lastValidIndexStat;
      if (stat.type == FileSystemEntityType.file &&
          stat.size >= 65536 &&
          validStat != null &&
          stat.size == validStat.size &&
          stat.modified.microsecondsSinceEpoch == validStat.modified) {
        indexReadable = true;
      } else {
        try {
          final raw = await target.readAsString();
          final preserved = _unparsedIndexEntries.isEmpty
              ? const <String>{}
              : _unparsedIndexEntries.map(jsonEncode).toSet();
          final inspected = raw.length < 65536
              ? _inspectIndexJson(raw, preserved)
              : await Isolate.run(() => _inspectIndexJson(raw, preserved));
          indexReadable = inspected.indexReadable;
          hasBadEntry = inspected.hasBadEntry;
        } catch (_) {
          // 整体无法解码：不刷新 .bak，只留损坏副本。
        }
      }
      if (indexReadable) {
        await target.copy('${dir.path}/index.json.bak');
      }
      if (!indexReadable || hasBadEntry) {
        await target.copy('${dir.path}/index.json.corrupt');
      }
    }
    await tmp.rename(target.path);
    if (_unparsedIndexEntries.isEmpty) {
      try {
        final stat = await target.stat();
        if (stat.type == FileSystemEntityType.file) {
          _lastValidIndexStat = (
            size: stat.size,
            modified: stat.modified.microsecondsSinceEpoch,
          );
        }
      } catch (_) {}
    } else {
      _lastValidIndexStat = null;
    }
    _indexGeneration++;
    // 索引成功提交后，只更新实际变化书籍的章节表快照。
    for (final id in changedIds) {
      final book = snapshot[id];
      if (book == null) {
        _savedBookRefs.remove(id);
        _savedRemapRanges.remove(id);
      } else {
        _savedBookRefs[id] = book;
        _savedRemapRanges[id] = [
          for (final chapter in book.chapters)
            (offset: chapter.offset, length: chapter.length),
        ];
      }
      if (identical(bookFor(id), book)) _dirtyBookIds.remove(id);
    }
    await _recoverChapterRemaps();
    notifyListeners();
  }

  Future<void> Function(LocalChapterRemap)? migrateProgress;

  bool isMigrationPending(int id) =>
      (_dirtyBookIds.contains(id) && _savedBookRefs.containsKey(id)) ||
      pendingChapterRemaps.any((remap) => remap.bookId == id);

  bool acceptsChapter(int id, NovelChapter chapter) {
    final book = bookFor(id);
    return book != null &&
        (book.kind != LocalBookKind.txt || _isBookReadyWithoutLock(book)) &&
        !isMigrationPending(id) &&
        book.revision == chapter.revision;
  }

  static int _remapSequence = 0;

  LocalChapterRemap _remapFor(LocalBook old, LocalBook next) {
    final queued = _readPendingChapterRemaps()
        .where((task) => task.bookId == old.id)
        .lastOrNull;
    if (queued != null &&
        queued.oldRevision == old.revision &&
        queued.newRevision == next.revision) {
      return queued;
    }
    return LocalChapterRemap.create(
      migrationId:
          'chremap-${old.id}-${DateTime.now().microsecondsSinceEpoch}-${_remapSequence++}',
      bookId: old.id,
      oldRevision: old.revision,
      newRevision: next.revision,
      oldTextPath: textPathFor(old),
      newTextPath: textPathFor(next),
      newTitles: next.chapters.map((chapter) => chapter.title).toList(),
      oldChapters: [
        for (final chapter in old.chapters)
          (offset: chapter.offset, length: chapter.length),
      ],
      newChapters: [
        for (final chapter in next.chapters)
          (offset: chapter.offset, length: chapter.length),
      ],
    );
  }

  Future<LocalBook> _upgradeEpubChaptersIfNeeded(LocalBook book) async {
    if (book.kind != LocalBookKind.epub ||
        book.chapterSplitVersion == _chapterSplitVersion ||
        book.sourceFingerprint.isEmpty) {
      return book;
    }
    final index = _indexForBook(book.id);
    if (index < 0) return book;
    try {
      final localPath = await _epubLocalPath(
        id: book.id,
        fileUri: book.fileUri,
        size: book.size,
        sourceKey: book.sourceKey,
        sourceFingerprint: book.sourceFingerprint,
      );
      if (await _epubSourceFingerprint(localPath) != book.sourceFingerprint) {
        return book;
      }
      final package = await EpubPackage.open(localPath, lenient: true);
      try {
        final spine = package.chapters;
        if (spine.isEmpty) return book;
        final updated = book.copyWith(
          chapters: [
            for (final c in spine) LocalChapterIndex(c.title, 0, 0, volume: ''),
          ],
          epubChapterHrefs: [for (final c in spine) c.href],
          coverEntry: package.coverEntry ?? book.coverEntry,
          chapterSplitVersion: _chapterSplitVersion,
          isComicEpub: package.isComicLayout,
          isRtlProgression: package.isRtlProgression,
          customTitle: book.customTitle,
          customAuthor: book.customAuthor,
        );
        _replaceBook(index, updated);
        await _saveIndex();
        return updated;
      } finally {
        await package.close();
      }
    } catch (_) {
      return book;
    }
  }

  /// Re-splits a local TXT book using a custom regex pattern or oversized
  /// chapter subdivision, persists the updated chapter index, and returns the
  /// updated [Novel].
  Future<Novel?> resplitTxtChapters(
    int id, {
    String? customPattern,
    int maxChapterChars = 0,
  }) => _synchronized(() async {
    final index = _indexForBook(id);
    if (index < 0) return null;
    final book = _books[index];
    Novel novelWithChapters(LocalBook b) => toNovel(b).withChapters([
      for (var i = 0; i < b.chapters.length; i++)
        NovelChapter(
          b.chapters[i].title,
          '',
          id: i,
          revision: b.revision,
          volume: b.chapters[i].volume,
        ),
    ]);
    if (book.kind != LocalBookKind.txt) return novelWithChapters(book);
    final trimmedPattern = customPattern?.trim();
    final effectivePattern =
        (trimmedPattern == null || trimmedPattern.isEmpty)
        ? null
        : trimmedPattern;
    if (effectivePattern != null) {
      final unsafe = detectUnsafeRegexPattern(effectivePattern);
      if (unsafe != null) {
        throw FormatException(unsafe);
      }
      RegExp(effectivePattern, multiLine: true);
    }
    final effectiveMaxChars = maxChapterChars > 0 ? maxChapterChars : 0;
    final ensured = await _ensureBookTextPath(book);
    final nextChapters = await _textWorker.splitCustom(
      ensured.path,
      customPattern: effectivePattern,
      maxChapterChars: effectiveMaxChars,
      enableChapterExtensions:
          _chapterSplitVersionFor(book) == _extendedChapterSplitVersion,
    );
    if (nextChapters.isEmpty) return novelWithChapters(book);
    final updated = book.copyWith(
      chapters: nextChapters,
      chapterSplitVersion: _chapterSplitVersionFor(book),
      customTitle: book.customTitle,
      customAuthor: book.customAuthor,
      customTocPattern: effectivePattern,
      customMaxChapterChars: effectiveMaxChars,
    );
    final chaptersChanged =
        updated.revision != book.revision && book.chapters.isNotEmpty;
    if (chaptersChanged) {
      await _stageChapterRemaps([_remapFor(book, updated)]);
    }
    _replaceBook(index, updated);
    await _saveIndex();
    if (chaptersChanged && migrateProgress != null) {
      await _ensureReadyInLock(id);
    }
    return novelWithChapters(bookFor(id) ?? updated);
  });

  bool _isBookReadyWithoutLock(LocalBook book) {
    if (book.kind == LocalBookKind.pdf || book.kind == LocalBookKind.comic) {
      return true;
    }
    if (book.kind == LocalBookKind.epub) {
      return book.chapterSplitVersion == _chapterSplitVersion ||
          book.sourceFingerprint.isEmpty ||
          _activeScan != null;
    }
    return book.chapterSplitVersion == _chapterSplitVersionFor(book) ||
        (book.chapterSplitVersion >= 3 && _activeScan != null);
  }

  Future<void> ensureReady(int id) async {
    final book = bookFor(id);
    if (book == null) throw StateError('书库中没有这本书的记录，请重新扫描导入');
    if ((identical(_savedBookRefs[id], book) ||
            !_savedBookRefs.containsKey(id)) &&
        !isMigrationPending(id) &&
        _isBookReadyWithoutLock(book)) {
      return;
    }
    await _synchronized(
      () => _ensureReadyInLock(id),
      timeout: _operationTimeout,
      operation: '详情准备',
    );
  }

  Future<void> _ensureReadyInLock(int id) async {
    if (_dirtyBookIds.contains(id)) await _saveIndex();
    final book = bookFor(id);
    if (book == null) throw StateError('书库中没有这本书的记录，请重新扫描导入');
    if (book.kind == LocalBookKind.epub) {
      if (book.chapterSplitVersion != _chapterSplitVersion &&
          book.sourceFingerprint.isNotEmpty) {
        await _upgradeEpubChaptersIfNeeded(book);
      }
      return;
    }
    if (book.kind != LocalBookKind.txt) return;
    if (book.chapterSplitVersion != _chapterSplitVersionFor(book)) {
      final remaps = <LocalChapterRemap>[];
      final updates = <int, LocalBook>{};
      final outcome = await _refreshBookIfNeeded(
        book,
        chapterRemaps: remaps,
        chapterUpdates: updates,
        chaptersStale: true,
      );
      if (outcome.failed) {
        if (!outcome.sourceUnavailable || book.chapters.isEmpty) {
          throw StateError('章节重建失败：${book.displayTitle}');
        }
      } else {
        await _stageChapterRemaps(remaps);
        for (final update in updates.values) {
          _replaceBook(_indexForBook(update.id), update);
        }
        await _saveIndex();
      }
    }
    while (true) {
      final tasks = pendingChapterRemaps.where((r) => r.bookId == id).toList();
      if (tasks.isEmpty) break;
      final migrate = migrateProgress;
      if (migrate == null) throw StateError('阅读进度待迁移，请完成书库刷新');
      final task = tasks.first;
      try {
        await migrate(task).timeout(
          _operationTimeout,
          onTimeout: () => throw const LocalOperationTimeoutException('阅读进度迁移'),
        );
      } on LocalOperationTimeoutException {
        // The durable task is already pending. Do not wait for another write
        // just to record this timeout, and never confirm a timed out migration.
        rethrow;
      } catch (error, stack) {
        try {
          await _writePendingChapterRemaps(
            _readPendingChapterRemaps().map(
              (r) => r.bookId == id && r.migrationId == task.migrationId
                  ? r.withFailure(error)
                  : r,
            ),
          );
        } catch (_) {
          // A diagnostic write must not replace the original migration error.
        }
        Error.throwWithStackTrace(error, stack);
      }
      await _writePendingChapterRemaps(
        _readPendingChapterRemaps().where(
          (r) => r.bookId != id || r.migrationId != task.migrationId,
        ),
      );
      notifyListeners();
    }
    if (isMigrationPending(id)) throw StateError('章节更新尚未提交');
  }

  /// ---- 章节迁移任务（可恢复）----
  List<LocalChapterRemap>? _remapsDuringWrite;

  /// 最后一次成功加载／保存的章节表（按书 id）。
  /// 只用它筛选可执行任务：任务可以先于索引落盘写入 journal，
  /// 但只有新章节表已经随索引提交后，任务才能交给调用方迁移，
  /// 否则进度会迁到尚未落盘的表上，造成串章。
  Map<int, List<({int offset, int length})>> _savedRemapRanges = {};

  Future<void> _reserveIds(int count) async {
    if (count == 0) return;
    final end = (_nextIdCursor + count).clamp(_nextIdCursor, 0x80000000);
    if (end <= _reservedIdEnd) return;
    await _checkedSet(
      () => _prefs.setInt('local_library_next', end - localNovelIdBase),
      'local_library_next',
    );
    _reservedIdEnd = end;
  }

  int _nextId() {
    if (_nextIdCursor >= _reservedIdEnd || _nextIdCursor > 0x7fffffff) {
      throw StateError('本地书籍数量已达上限');
    }
    return _nextIdCursor++;
  }

  /// 打开系统文件夹选择器；用户取消返回 null。
  /// prefs 写入必须检查返回值：SharedPreferences 的 set 方法失败时返回 false
  /// 而非抛异常；关键路径上返回 false 必须视为失败并中断，避免静默丢数据。
  static Future<void> _checkedSet(
    Future<bool> Function() write,
    String what,
  ) async {
    try {
      final ok = await write();
      if (!ok) throw StateError('写入失败: $what');
    } catch (_) {
      try {
        await SharedPreferences.getInstance()
            .then((prefs) => prefs.reload())
            .timeout(const Duration(seconds: 1));
      } catch (_) {
        /* Preserve the original write error. */
      }
      rethrow;
    }
  }

  Future<String?> pickFolder({String? requiredFolder}) => _pickLibraryFolder(
    prefKey: 'local_library_folder',
    otherPrefKey: 'local_library_manga_folder',
    otherLabel: '漫画文件夹',
    pendingCleanupsKey: 'local_library_pending_cleanups',
    requiredFolder: requiredFolder,
  );

  Future<String?> pickMangaFolder({String? requiredFolder}) =>
      _pickLibraryFolder(
        prefKey: 'local_library_manga_folder',
        otherPrefKey: 'local_library_folder',
        otherLabel: '小说文件夹',
        pendingCleanupsKey: 'local_library_manga_pending_cleanups',
        requiredFolder: requiredFolder,
      );

  Future<String?> _pickLibraryFolder({
    required String prefKey,
    required String otherPrefKey,
    required String otherLabel,
    required String pendingCleanupsKey,
    String? requiredFolder,
  }) async {
    // 系统文件夹选择器（用户交互）不能在锁内；但 prefs 的读写要进 _synchronized，
    // 与 scan() 互斥，避免切换与扫描交错导致待清理列表或 folderUri 不一致。
    final uri = await LocalPlatform.pickLocalFolder();
    if (requiredFolder != null && uri != null && uri != requiredFolder) {
      throw StateError('重新授权必须选择原文件夹');
    }
    if (uri != null && uri.isNotEmpty) {
      await _synchronized(() async {
        final otherUri = _prefs.getString(otherPrefKey);
        if (otherUri != null && otherUri.isNotEmpty && otherUri == uri) {
          throw StateError('该目录已设为$otherLabel，请选择独立的文件夹');
        }
        final oldUri = _prefs.getString(prefKey);
        // 文件夹切换：把旧来源记入待清理列表，待新文件夹扫描成功后再清理旧书。
        // 不能在这里直接删——新文件夹可能扫描失败，删了用户就两头空了。
        // 用列表而非单个槽位：连续切换 A→B→C 时，A 和 B 都要保留到清理完成。
        if (oldUri != null && oldUri.isNotEmpty && oldUri != uri) {
          final pending = _prefs.getStringList(pendingCleanupsKey) ?? [];
          if (!pending.contains(oldUri)) {
            pending.add(oldUri);
            await _checkedSet(
              () => _prefs.setStringList(pendingCleanupsKey, pending),
              pendingCleanupsKey,
            );
          }
        }
        await _checkedSet(() => _prefs.setString(prefKey, uri), prefKey);
      });
    }
    return uri;
  }

  /// 查看待清理关联数据（书架/标签/阅读进度）的书籍 ID 队列（不清空）。
  /// scan() 把切换时删除的旧书 ID 记入此队列；调用方逐个做幂等清理，
  /// 成功后用 [confirmAssociatedCleanupIds] 确认删除。
  /// "先读→清理→按成功条目确认" 避免"取出并清空"的中断丢失窗口。
  Future<List<int>> peekAssociatedCleanupIds() async {
    final raw = _prefs.getStringList('local_library_associated_cleanup') ?? [];
    final ids = <int>[];
    for (final s in raw) {
      final id = int.tryParse(s);
      if (id != null && bookFor(id) == null) ids.add(id);
    }
    return ids;
  }

  Future<void> _queueAssociatedCleanup(Iterable<LocalBook> books) async {
    final ids = {
      ...?_prefs.getStringList('local_library_associated_cleanup'),
      ...books.map((book) => '${book.id}'),
    };
    if (ids.isEmpty) return;
    await _checkedSet(
      () => _prefs.setStringList(
        'local_library_associated_cleanup',
        ids.toList(),
      ),
      'associated cleanup',
    );
  }

  Future<void> _queueDataCleanup(
    Iterable<LocalBook> books, {
    required bool clearStash,
  }) async {
    if (books.isEmpty) return;
    const key = 'local_book_data_cleanup_v1';
    final raw = _prefs.get(key);
    List entries;
    try {
      if (raw != null && raw is! String) {
        throw const FormatException('invalid cleanup queue');
      }
      entries = raw == null ? <dynamic>[] : jsonDecode(raw as String) as List;
      for (final entry in entries) {
        if (entry is! Map ||
            entry['book'] is! Map ||
            entry['book']['id'] is! int) {
          throw const FormatException('invalid cleanup record');
        }
      }
    } catch (_) {
      await archiveRecoveryRecord(
        _prefs,
        '${key}_quarantine',
        raw ?? '',
        reason: 'invalid_cleanup',
      );
      entries = [];
    }
    final ids = books.map((book) => book.id).toSet();
    entries.removeWhere(
      (entry) => entry is Map && ids.contains(entry['book']?['id']),
    );
    entries.addAll(
      books.map((book) => {'book': book.toJson(), 'clearStash': clearStash}),
    );
    await _checkedSet(() => _prefs.setString(key, jsonEncode(entries)), key);
    await _queueAssociatedCleanup(books);
  }

  Future<void> _recoverDataCleanup() async {
    await _removeStagingFiles();
    await _recoverFailedCopyCleanups();
    const key = 'local_book_data_cleanup_v1';
    final raw = _prefs.get(key);
    if (raw == null) return;
    final List entries;
    try {
      if (raw is! String) throw const FormatException('invalid cleanup queue');
      entries = jsonDecode(raw) as List;
    } catch (error) {
      recordRecoveryFailure(key, error);
      return;
    }
    final remaining = <dynamic>[];
    for (final entry in entries) {
      try {
        final book = LocalBook.fromJson(
          Map<String, Object?>.from(entry['book'] as Map),
        );
        if (bookFor(book.id) != null || _savedBookRefs.containsKey(book.id)) {
          remaining.add(entry);
          continue;
        }
        if (entry['clearStash'] == true) await _clearTagStashKeys([book]);
        if (!await _retryBookDataCleanup(book)) remaining.add(entry);
      } catch (error) {
        recordRecoveryFailure(key, error);
        remaining.add(entry);
      }
    }
    if (remaining.length != entries.length) {
      await _checkedSet(
        () => remaining.isEmpty
            ? _prefs.remove(key)
            : _prefs.setString(key, jsonEncode(remaining)),
        key,
      );
    }
  }

  Future<bool> _retryBookDataCleanup(LocalBook book) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (await _deleteBookData(book)) return true;
      } catch (error) {
        recordRecoveryFailure('copy_cleanup:${book.id}', error);
      }
    }
    recordRecoveryFailure('copy_cleanup:${book.id}', StateError('删除副本失败'));
    return false;
  }

  Future<void> _recoverFailedCopyCleanups() async {
    const key = 'local_library_failed_copy_cleanups_v1';
    final raw = _prefs.get(key);
    if (raw == null) return;
    if (raw is! List<String>) {
      recordRecoveryFailure(key, const FormatException('清理归档格式错误'));
      return;
    }
    final remaining = <String>[];
    for (final record in raw) {
      try {
        final archived = jsonDecode(record) as Map;
        final book = LocalBook.fromJson(
          Map<String, Object?>.from(jsonDecode(archived['raw'] as String) as Map),
        );
        if (bookFor(book.id) != null || _savedBookRefs.containsKey(book.id) ||
            !await _retryBookDataCleanup(book)) {
          remaining.add(record);
        }
      } catch (error) {
        recordRecoveryFailure(key, error);
        remaining.add(record);
      }
    }
    if (remaining.length == raw.length) return;
    try {
      await _checkedSet(
        () => remaining.isEmpty ? _prefs.remove(key) : _prefs.setStringList(key, remaining),
        key,
      );
    } catch (error) {
      recordRecoveryFailure(key, error);
    }
  }

  Future<void> _removeStagingFiles() async {
    final dir = _booksDir;
    if (!await dir.exists()) return;
    final referencedPaths = <String>{
      for (final book in _books) textPathFor(book),
      for (final book in _savedBookRefs.values) textPathFor(book),
      for (final remap in _readPendingChapterRemaps()) ...[
        if (remap.oldTextPath.isNotEmpty) remap.oldTextPath,
        if (remap.newTextPath.isNotEmpty) remap.newTextPath,
      ],
    };
    final snapshotPattern = RegExp(r'^book_\d+(?:_[0-9a-f]+)?\.txt$');
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File) continue;
      final base = entry.uri.pathSegments.isNotEmpty
          ? entry.uri.pathSegments.last
          : entry.path.split(Platform.pathSeparator).last;
      final isTemp =
          base.endsWith('.staging') ||
          base.endsWith('.staging.importing') ||
          base.endsWith('.upgrading') ||
          base == 'index.json.tmp';
      final isOrphanSnapshot =
          snapshotPattern.hasMatch(base) &&
          !referencedPaths.contains(entry.path);
      if (!isTemp && !isOrphanSnapshot) continue;
      try {
        await entry.delete();
      } on FileSystemException {
        // A concurrent import owns the file; its finally block will clean it.
      }
    }
  }

  /// 确认已完成关联清理的 ID，从队列中移除。
  /// 未确认的 ID 保留，下次可重试。
  Future<void> confirmAssociatedCleanupIds(List<int> done) async {
    if (done.isEmpty) return;
    final raw = _prefs.getStringList('local_library_associated_cleanup') ?? [];
    if (raw.isEmpty) return;
    final doneSet = done.map((e) => '$e').toSet();
    final remaining = raw.where((s) => !doneSet.contains(s)).toList();
    if (remaining.isEmpty) {
      await _prefs.remove('local_library_associated_cleanup');
    } else {
      await _checkedSet(
        () =>
            _prefs.setStringList('local_library_associated_cleanup', remaining),
        'local_library_associated_cleanup',
      );
    }
  }

  /// ---- 标签暂存（文件夹切换时保留标签）----
  ///
  /// 切走文件夹时，被删书籍的标签按 `jsonEncode([sourceId, fileName])` 暂存；
  /// 切回后扫描成功时，文件名对上就恢复到新 ID 上。
  /// 只处理标签，不动书架和阅读进度。
  static const _tagStashKey = 'local_library_tag_stash';

  /// 暂存 key：用被删书籍自己的 sourceId（不是当前 sourceId）。
  /// jsonEncode 避免分隔符歧义。
  static String _tagStashKeyFor(LocalBook book) =>
      jsonEncode([book.sourceId, book.fileName]);

  Map<String, List<String>> _readTagStash() {
    try {
      final raw = _prefs.getString(_tagStashKey);
      if (raw == null) return {};
      final map = jsonDecode(raw);
      if (map is! Map<String, Object?>) return {};
      final out = <String, List<String>>{};
      map.forEach((k, v) {
        if (v is List) {
          final ids = v.whereType<String>().toList();
          if (ids.isNotEmpty) out[k] = ids;
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeTagStash(Map<String, List<String>> stash) => _checkedSet(
    () => _prefs.setString(_tagStashKey, jsonEncode(stash)),
    _tagStashKey,
  );

  /// 文件夹切换删除书籍前暂存标签（_synchronized 内调用）。
  /// 明确覆盖规则：有标签则覆盖暂存，无标签则删除已有条目，
  /// 避免用户清空标签后旧条目复活。
  /// TagStore 未就绪时跳过（测试环境），不阻塞删除流程。
  Future<void> _stashTagsForRemoved(List<LocalBook> books) async {
    final tagStore = TagStore.maybeShared;
    if (tagStore == null || books.isEmpty) return;
    final stash = _readTagStash();
    var changed = false;
    for (final book in books) {
      final key = _tagStashKeyFor(book);
      final ids = tagStore.tagsForBook(book.id).map((t) => t.id).toList();
      if (ids.isEmpty) {
        if (stash.remove(key) != null) changed = true;
      } else {
        stash[key] = ids;
        changed = true;
      }
    }
    if (changed) await _writeTagStash(stash);
  }

  /// 清除指定书籍对应的暂存条目（文件被删 / 用户明确删除书籍时）。
  /// 不创建新暂存，只清理，避免同名新文件误恢复旧标签。
  Future<void> _clearTagStashKeys(
    Iterable<LocalBook> books, {
    bool clearBookTags = true,
  }) async {
    final stash = _readTagStash();
    var changed = false;
    for (final book in books) {
      final keys = stash.keys.where((key) {
        try {
          final parts = jsonDecode(key);
          return parts is List &&
              parts.length == 2 &&
              parts[0] == book.sourceId &&
              parts[1] is String &&
              stripFilenameTags(parts[1] as String) ==
                  stripFilenameTags(book.fileName);
        } catch (_) {
          return key == _tagStashKeyFor(book);
        }
      }).toList();
      for (final key in keys) {
        stash.remove(key);
        changed = true;
      }
      if (clearBookTags) {
        await TagStore.maybeShared?.setTagsForBook(book.id, const []);
      }
    }
    if (changed) await _writeTagStash(stash);
  }

  /// 扫描成功后恢复暂存标签并清理失效条目（_synchronized 内，_saveIndex 之后）。
  /// - 和现有标签合并，恢复成功或标签已失效后消费条目。
  /// - 恢复前用现存标签定义过滤，过滤后为空也消费条目。
  /// - 完整扫描成功后，清理该来源下已不存在文件对应的条目，
  ///   避免以后新建同名文件时恢复旧标签。
  /// TagStore 未就绪时跳过。
  Future<void> _restoreStashedTags(String sourceId) async {
    final tagStore = TagStore.maybeShared;
    if (tagStore == null) return;
    final stash = _readTagStash();
    if (stash.isEmpty) return;
    // 该来源现存书籍的 key→book。
    final live = <String, LocalBook>{};
    for (final b in _books) {
      if (b.sourceId == sourceId) live[_tagStashKeyFor(b)] = b;
    }
    bool belongsToSource(String key) {
      try {
        final parts = jsonDecode(key);
        return parts is List && parts.length == 2 && parts[0] == sourceId;
      } catch (_) {
        return false;
      }
    }

    var changed = false;
    for (final key in stash.keys.where(belongsToSource).toList()) {
      final stashed = stash[key]!;
      final book = live[key];
      if (book == null) {
        // 文件已不存在（切走期间被删）：清理条目，不恢复。
        stash.remove(key);
        changed = true;
        continue;
      }
      final validIds = stashed
          .where((id) => tagStore.tagById(id) != null)
          .toList();
      if (validIds.isEmpty) {
        // 标签定义已全部失效：消费条目，不恢复。
        stash.remove(key);
        changed = true;
        continue;
      }
      // 恢复成功后才删条目：setTagsForBook 抛错时异常向上传播，
      // _writeTagStash 不会执行，prefs 里的条目保留，下次扫描可重试。
      await tagStore.setTagsForBook(book.id, {
        ...tagStore.tagsForBook(book.id).map((tag) => tag.id),
        ...validIds,
      });
      stash.remove(key);
      changed = true;
    }
    if (changed) await _writeTagStash(stash);
  }

  Future<void> forgetFolder() async {
    await _prefs.remove('local_library_folder');
  }

  Future<void> forgetMangaFolder() async {
    await _prefs.remove('local_library_manga_folder');
  }

  /// ---- 「仅移出书库」忽略名单 ----
  ///
  /// 源文件删不掉时用户可选择仅移出书库（源文件保留）。被移出文件的
  /// [sourceId, sourceKey] 记入此名单，扫描时跳过，避免下次扫描又导入回来；
  /// 文件后来从磁盘消失（用户手动删除等）时，名单条目在扫描中自动清理。
  static const _ignoredSourcesKey = 'local_library_ignored_sources';

  /// 忽略名单的内存缓存：prefs 读取异常时用上次成功读到的名单兜底，
  /// 避免把「读不到」误判成「名单为空」而重新导入已移出的书。
  Set<String>? _ignoredCache;

  Set<String> _readIgnoredSources() {
    try {
      final set = (_prefs.getStringList(_ignoredSourcesKey) ?? []).toSet();
      _ignoredCache = Set.of(set);
      return set;
    } catch (_) {
      final cache = _ignoredCache;
      if (cache != null) return Set.of(cache);
      rethrow;
    }
  }

  Future<void> _writeIgnoredSources(Set<String> ignored) async {
    await _checkedSet(
      () => _prefs.setStringList(_ignoredSourcesKey, ignored.toList()),
      _ignoredSourcesKey,
    );
    _ignoredCache = Set.of(ignored);
  }

  /// ---- 仅移出待办（可恢复）----
  static const _pendingRecordRemovalKey = 'local.pending_record_removal.v1';

  Set<String> _readIgnoredSourcesForRemoval() {
    try {
      final values = _prefs.getStringList(_ignoredSourcesKey);
      final ignored = (values ?? <String>[]).toSet();
      _ignoredCache = Set<String>.of(ignored);
      return ignored;
    } catch (_) {
      final cached = _ignoredCache;
      if (cached != null) return Set<String>.of(cached);
      rethrow;
    }
  }

  RecordRemovalJournal get _recordRemovalJournal => RecordRemovalJournal(
    readIntent: () => _prefs.get(_pendingRecordRemovalKey),
    archiveIntent: (raw) => archiveRecoveryRecord(
      _prefs,
      'local_library_quarantined_record_removals_v1',
      raw,
      reason: 'invalid_removal_intent',
    ),
    writeIntent: (raw) async {
      if (raw == null) {
        await _checkedSet(
          () => _prefs.remove(_pendingRecordRemovalKey),
          _pendingRecordRemovalKey,
        );
      } else {
        await _checkedSet(
          () => _prefs.setString(_pendingRecordRemovalKey, raw),
          _pendingRecordRemovalKey,
        );
      }
    },
    readIgnored: _readIgnoredSourcesForRemoval,
    writeIgnored: _writeIgnoredSources,
    finishRemoval: (id) async {
      final book = bookFor(id);
      if (book != null) {
        // 待办已提交；这些步骤可以在恢复时重复执行。
        await _queueDataCleanup([book], clearStash: true);
        await _clearTagStashKeys([book]);
        final deleted = await _retryBookDataCleanup(book);
        if (!deleted) {
          try {
            await archiveRecoveryRecord(
              _prefs,
              'local_library_failed_copy_cleanups_v1',
              jsonEncode(book.toJson()),
              reason: 'copy_cleanup_failed',
              details: {'attempts': 3},
            );
          } catch (error) {
            recordRecoveryFailure('copy_cleanup_archive:${book.id}', error);
          }
        }
        _removeBook(book);
      }
      await TagStore.maybeShared?.setTagsForBook(id, const []);
      // 保存失败会保留 dirty ID；已从内存移除的记录仍会在这里重试。
      // 已成功落盘的重复恢复无需再写索引。
      await _saveIndex();
    },
  );

  /// 书籍的有效忽略 key：统一走 [LocalSourceIdentity]，与两处扫描
  /// 的键生成规则一致。旧 appFolder 记录即使当前选中 SAF 文件夹，
  /// 仍属于 appFolder:novels，不会被当前文件夹覆盖。
  String _effectiveIgnoredKeyFor(LocalBook book) {
    return LocalSourceIdentity.forBook(
      sourceId: book.sourceId,
      sourceKey: book.sourceKey,
      fileUri: book.fileUri,
      folderUri: folderUri,
    ).ignoredKey;
  }

  /// 扫描已选文件夹：新增导入、内容变化的重新导入、源文件已删的移除。
  Future<T> _scanTransaction<T>(
    Future<T> Function(Map<String, File?> epubCacheBackups) action,
  ) async {
    await _recordRemovalJournal.recover();
    await _recoverDataCleanup();
    final books = List<LocalBook>.of(_books);
    final dirty = Set<int>.of(_dirtyBookIds);
    final generation = _indexGeneration;
    final epubCacheBackups = <String, File?>{};
    var rollbackEpubCaches = false;
    try {
      return await action(epubCacheBackups);
    } catch (_) {
      if (generation == _indexGeneration) {
        rollbackEpubCaches = true;
        _books
          ..clear()
          ..addAll(books);
        _dirtyBookIds
          ..clear()
          ..addAll(dirty);
        _rebuildBookPositions();
        _textCache.clear();
        _textReads.clear();
        _textCacheBytes = 0;
        _clearEpubCaches();
      }
      rethrow;
    } finally {
      for (final entry in epubCacheBackups.entries) {
        final backup = entry.value;
        if (rollbackEpubCaches) {
          if (backup == null) {
            final cache = File(entry.key);
            if (await cache.exists()) await cache.delete();
          } else {
            await backup.rename(entry.key);
          }
        }
        if (backup != null) await backup.parent.delete(recursive: true);
      }
    }
  }

  Future<LocalScanResult> scan({
    bool force = false,
    bool verifyUnchangedFingerprints = true,
  }) {
    if (!force && _activeScan != null) return _activeScan!;
    late final Future<LocalScanResult> running;
    running = _runScan(
      force: force,
      verifyUnchangedFingerprints: verifyUnchangedFingerprints,
    );
    if (!force) _activeScan = running;
    return running;
  }

  Future<LocalScanResult> _runScan({
    required bool force,
    required bool verifyUnchangedFingerprints,
  }) async {
    try {
      return await _synchronized(
        () => _scanTransaction((epubCacheBackups) async {
          // 扫描入口必须先恢复，尤其不能先扫描导入、最后才恢复。
          await _recordRemovalJournal.recover();
          final novelTreeUri = folderUri;
          final mangaTreeUri = mangaFolderUri;
          if (novelTreeUri == null && mangaTreeUri == null) {
            throw StateError('请先选择小说文件夹');
          }
          _updateScanProgress(
            scanning: true,
            processed: 0,
            total: 0,
            added: 0,
          );

          final roots = <({String treeUri, bool isMangaRoot})>[
            if (novelTreeUri != null && novelTreeUri.isNotEmpty)
              (treeUri: novelTreeUri, isMangaRoot: false),
            if (mangaTreeUri != null && mangaTreeUri.isNotEmpty)
              (treeUri: mangaTreeUri, isMangaRoot: true),
          ];

          final failures = <String, String>{};
          final chapterRemaps = <LocalChapterRemap>[];
          final chapterUpdates = <int, LocalBook>{};
          final allRemovedBooks = <LocalBook>[];
          final allToDelete = <LocalBook>[];
          final allReconciledData = <LocalBook>[];
          final switchedRemovedIds = <int>[];
          final pendingCleanupCommits =
              <({String prefKey, List<String> remaining})>[];
          final scannedSourceIds = <String>[];
          final ignored = _readIgnoredSources();
          var ignoredDirty = false;
          var added = 0,
              refreshed = 0,
              removed = 0,
              skipped = 0,
              backfilled = 0;

          for (final root in roots) {
            final treeUri = root.treeUri;
            final isMangaRoot = root.isMangaRoot;
            final sourceId = isMangaRoot
                ? 'saf_manga:$treeUri'
                : 'saf:$treeUri';
            scannedSourceIds.add(sourceId);
            LocalSourceIdentity identityFor(String key) => isMangaRoot
                ? LocalSourceIdentity.safManga(treeUri, key)
                : LocalSourceIdentity.saf(treeUri, key);

            final scanResult = await LocalPlatform.scanLocalFolder(treeUri);
            // 扫描不完整时 entries 不可信：直接抛错，不更新书库，
            // 也不清理旧书（调用方据此提示用户，而非显示"书库无变化"）。
            if (!scanResult.complete) {
              throw IncompleteScanException(
                scanResult.reason ?? 'unknown',
                isMangaFolder: isMangaRoot,
              );
            }
            final rawEntries = scanResult.entries;
            final rawBookEntries = <Map<String, Object?>>[];
            final folderCandidates = <ScannedFolderEntry>[];
            final comicInfoUrisByDir = <String, String>{};
            final nonImageRelPaths = <String>[];
            for (final entry in rawEntries) {
              final name = entry['name'] as String? ?? '';
              final uri = entry['uri'] as String? ?? '';
              final rawRel = entry['relPath'] as String?;
              final relPath =
                  (rawRel != null && rawRel.isNotEmpty) ? rawRel : name;
              if (name.isNotEmpty &&
                  uri.isNotEmpty &&
                  (isComicImageFileName(name) || isComicInfoFileName(name))) {
                if (name.toLowerCase() == 'comicinfo.xml') {
                  final norm = relPath.replaceAll('\\', '/');
                  final slash = norm.lastIndexOf('/');
                  final dir = slash < 0 ? '' : norm.substring(0, slash);
                  comicInfoUrisByDir.putIfAbsent(dir, () => uri);
                }
                folderCandidates.add(
                  ScannedFolderEntry(
                    relPath: relPath,
                    name: name,
                    uri: uri,
                    size: (entry['size'] as num?)?.toInt() ?? 0,
                    modifiedMs: (entry['modified'] as num?)?.toInt() ?? 0,
                    parentUri: entry['parentUri'] as String?,
                  ),
                );
              } else {
                if (relPath.isNotEmpty) nonImageRelPaths.add(relPath);
                if (name.isEmpty ||
                    localBookKindForFileName(name) != null ||
                    isMobiFileName(name) ||
                    isZipFileName(name) ||
                    name.toLowerCase().endsWith('.cbr') ||
                    name.toLowerCase().endsWith('.cb7')) {
                  rawBookEntries.add(entry);
                }
              }
            }
            final rootDisplayName = scanResult.rootName.isNotEmpty
                ? scanResult.rootName
                : '本地漫画';
            final comicFolders = groupScannedComicFolders(
              entries: folderCandidates,
              rootKeyPrefix: sourceId,
              rootFolderUri: treeUri,
              rootDisplayName: rootDisplayName,
              dirUrisByRelPath: scanResult.dirUris,
              nonImageRelPaths: nonImageRelPaths,
            );
            final seriesScanCandidates = <ScannedFolderEntry>[];
            for (final entry in rawBookEntries) {
              final name = entry['name'] as String? ?? '';
              final uri = entry['uri'] as String? ?? '';
              if (name.isEmpty || uri.isEmpty) continue;
              final lower = name.toLowerCase();
              if (lower.endsWith('.cbr') || lower.endsWith('.cb7')) continue;
              final rawRel = entry['relPath'] as String?;
              final relPath =
                  (rawRel != null && rawRel.isNotEmpty) ? rawRel : name;
              seriesScanCandidates.add(
                ScannedFolderEntry(
                  relPath: relPath,
                  name: name,
                  uri: uri,
                  size: (entry['size'] as num?)?.toInt() ?? 0,
                  modifiedMs: (entry['modified'] as num?)?.toInt() ?? 0,
                  parentUri: entry['parentUri'] as String?,
                ),
              );
            }
            final groupedSeries = groupScannedComicVolumeSeries(
              entries: seriesScanCandidates,
              isMangaRoot: isMangaRoot,
              rootKeyPrefix: sourceId,
              rootFolderUri: treeUri,
              rootDisplayName: rootDisplayName,
              dirUrisByRelPath: scanResult.dirUris,
              comicInfoUrisByDir: comicInfoUrisByDir,
            );
            final seriesGroups = groupedSeries.seriesGroups;
            final groupedMemberUris = <String>{
              for (final g in seriesGroups)
                for (final f in g.files) f.uri,
            };
            final entries = [
              for (final entry in rawBookEntries)
                if (!groupedMemberUris.contains(entry['uri'] as String? ?? ''))
                  entry,
            ];

            if (entries.isEmpty &&
                comicFolders.isEmpty &&
                seriesGroups.isEmpty &&
                _books.any((book) => book.sourceId == sourceId)) {
              throw IncompleteScanException(
                'empty_result',
                isMangaFolder: isMangaRoot,
              );
            }

            // 按 sourceKey 索引当前来源的书籍，避免误删其他来源（修复#1）。
            final byKey = {
              for (final book in _books)
                if (book.sourceId == sourceId && book.sourceKey.isNotEmpty)
                  book.sourceKey: book,
            };
            // 兼容旧数据：没有 sourceId 的书用 fileUri 匹配（仅主小说文件夹）。
            final byUriLegacy = isMangaRoot
                ? const <String, LocalBook>{}
                : {
                    for (final book in _books)
                      if (book.sourceId.isEmpty) book.fileUri: book,
                  };
            final seen = <String>{};
            final totalUnits =
                entries.length + comicFolders.length + seriesGroups.length;
            await _reserveIds(
              entries.where((entry) {
                    final uri = entry['uri'] as String? ?? '';
                    return uri.isNotEmpty &&
                        !byKey.containsKey(uri) &&
                        !byUriLegacy.containsKey(uri) &&
                        !ignored.contains(identityFor(uri).ignoredKey);
                  }).length +
                  comicFolders.where((manifest) {
                    final key =
                        'comic_folder:${manifest.folderRelPath.isEmpty ? "." : manifest.folderRelPath}';
                    return !byKey.containsKey(key) &&
                        !ignored.contains(identityFor(key).ignoredKey);
                  }).length +
                  seriesGroups.where((candidate) {
                    final key = _seriesSourceKeyFor(sourceId, candidate);
                    return !byKey.containsKey(key) &&
                        !ignored.contains(identityFor(key).ignoredKey);
                  }).length,
            );
            var processed = 0;
            _updateScanProgress(
              scanning: true,
              processed: 0,
              total: totalUnits,
              added: added,
            );
            for (final entry in entries) {
              processed++;
              if (totalUnits <= 50 ||
                  processed == 1 ||
                  processed == totalUnits ||
                  processed % 10 == 0) {
                _updateScanProgress(
                  scanning: true,
                  processed: processed,
                  total: totalUnits,
                  added: added,
                );
              }
              final uri = entry['uri'] as String? ?? '';
              final name = entry['name'] as String? ?? '';
              if (uri.isEmpty) continue;
              final lowerName = name.toLowerCase();
              if (lowerName.endsWith('.cbr')) {
                failures[name] = '暂不支持 RAR/CBR 压缩格式，请转换为 CBZ 或 ZIP 后导入';
                skipped++;
                continue;
              }
              if (lowerName.endsWith('.cb7')) {
                failures[name] = '暂不支持 7z/CB7 压缩格式，请转换为 CBZ 或 ZIP 后导入';
                skipped++;
                continue;
              }
              final sourceKey = uri;
              seen.add(sourceKey);
              if (name.isEmpty) continue;
              if (ignored.contains(identityFor(sourceKey).ignoredKey)) {
                skipped++;
                final existing = byKey[sourceKey] ?? byUriLegacy[uri];
                if (existing != null) {
                  _removeBook(existing);
                  allReconciledData.add(existing);
                  removed++;
                }
                continue;
              }
              final rawRel = entry['relPath'] as String?;
              final relPath =
                  (rawRel != null && rawRel.isNotEmpty) ? rawRel : name;
              final entryIsManga =
                  isMangaRoot ||
                  hasExplicitComicPathHint(relPath) ||
                  hasExplicitComicPathHint(name);
              final size = (entry['size'] as num?)?.toInt() ?? 0;
              final modified = (entry['modified'] as num?)?.toInt() ?? 0;
              var existing = byKey[sourceKey] ?? byUriLegacy[uri];
              if (existing != null) {
                if (existing.fileName != name ||
                    existing.fileUri != uri ||
                    existing.sourceKey != sourceKey) {
                  existing = _withFilenameMetadata(
                    existing,
                    name,
                    fileUri: uri,
                    sourceKey: sourceKey,
                  );
                  chapterUpdates[existing.id] = existing;
                }
                if (entryIsManga && !existing.isMangaSource) {
                  existing = existing.copyWith(isMangaSource: true);
                  chapterUpdates[existing.id] = existing;
                }
                if ((existing.kind == LocalBookKind.pdf ||
                        existing.kind == LocalBookKind.comic ||
                        (existing.kind == LocalBookKind.epub &&
                            (existing.chapterSplitVersion ==
                                    _chapterSplitVersion ||
                                (!verifyUnchangedFingerprints &&
                                    existing.chapters.length > 1)))) &&
                    !force &&
                    existing.size == size &&
                    existing.modified == modified) {
                  continue;
                }
                if (!force &&
                    existing.kind == LocalBookKind.txt &&
                    existing.size == size &&
                    existing.modified == modified &&
                    (existing.chapterSplitVersion ==
                            _chapterSplitVersionFor(existing) ||
                        (!verifyUnchangedFingerprints &&
                            existing.chapterSplitVersion >= 3 &&
                            existing.chapters.length > 1)) &&
                    existing.wordCount != null &&
                    existing.sourceFingerprint.isNotEmpty) {
                  if (!verifyUnchangedFingerprints) {
                    continue;
                  }
                  try {
                    if (await _sourceHasFingerprint(
                      existing,
                      existing.sourceFingerprint,
                    )) {
                      continue;
                    }
                  } catch (error) {
                    _recordScanFailure(failures, name, error);
                    skipped++;
                    continue;
                  }
                }
                LocalBook? book;
                try {
                  await _preserveCachedSnapshot(existing);
                  book = await _importEntry(
                    epubCacheBackups: epubCacheBackups,
                    uri: uri,
                    name: name,
                    size: size,
                    modified: modified,
                    sourceId: sourceId,
                    sourceKey: sourceKey,
                    isMangaSource: entryIsManga,
                    existing: existing,
                  );
                } on _NonComicZipSkipException {
                  seen.remove(sourceKey);
                  continue;
                } catch (error) {
                  _recordScanFailure(failures, name, error);
                  skipped++;
                  continue;
                }
                if (book == null) {
                  failures[name] = 'PDF 没有可读取的页面';
                  skipped++;
                  continue;
                }
                if (!force &&
                    book.revision == existing.revision &&
                    book.size == existing.size &&
                    book.modified == existing.modified &&
                    book.wordCount == existing.wordCount &&
                    book.isMangaSource == existing.isMangaSource &&
                    book.sourceFingerprint == existing.sourceFingerprint) {
                  continue;
                }
                if (book.kind == LocalBookKind.txt &&
                    existing.chapters.isNotEmpty &&
                    book.revision != existing.revision) {
                  chapterRemaps.add(_remapFor(existing, book));
                }
                if (existing.wordCount == null && book.wordCount != null) {
                  backfilled++;
                }
                chapterUpdates[book.id] = book;
                refreshed++;
              } else {
                LocalBook? book;
                try {
                  book = await _importEntry(
                    epubCacheBackups: epubCacheBackups,
                    uri: uri,
                    name: name,
                    size: size,
                    modified: modified,
                    sourceId: sourceId,
                    sourceKey: sourceKey,
                    isMangaSource: entryIsManga,
                  );
                } on _NonComicZipSkipException {
                  seen.remove(sourceKey);
                  continue;
                } catch (error) {
                  _recordScanFailure(failures, name, error);
                  skipped++;
                  continue;
                }
                if (book == null) {
                  failures[name] = 'PDF 没有可读取的页面';
                  skipped++;
                  continue;
                }
                _addBook(book);
                added++;
                _updateScanProgress(
                  scanning: true,
                  processed: processed,
                  total: totalUnits,
                  added: added,
                );
              }
            }
            for (final manifest in comicFolders) {
              processed++;
              if (totalUnits <= 50 ||
                  processed == 1 ||
                  processed == totalUnits ||
                  processed % 10 == 0) {
                _updateScanProgress(
                  scanning: true,
                  processed: processed,
                  total: totalUnits,
                  added: added,
                );
              }
              final sourceKey =
                  'comic_folder:${manifest.folderRelPath.isEmpty ? "." : manifest.folderRelPath}';
              seen.add(sourceKey);
              if (ignored.contains(identityFor(sourceKey).ignoredKey)) {
                skipped++;
                final existingIgnored = byKey[sourceKey];
                if (existingIgnored != null) {
                  _removeBook(existingIgnored);
                  allReconciledData.add(existingIgnored);
                  removed++;
                }
                continue;
              }
              final fingerprint = _computeFolderManifestFingerprint(manifest);
              final existing = byKey[sourceKey];
              if (existing != null &&
                  !force &&
                  existing.sourceFingerprint == fingerprint &&
                  await _comicManifestFile(existing.id).exists()) {
                continue;
              }
              try {
                final book = await _importComicFolder(
                  manifest: manifest,
                  sourceId: sourceId,
                  sourceKey: sourceKey,
                  defaultFileUri: manifest.folderUri.isNotEmpty
                      ? manifest.folderUri
                      : treeUri,
                  fingerprint: fingerprint,
                  existing: existing,
                );
                if (book == null) {
                  skipped++;
                  continue;
                }
                if (existing != null) {
                  chapterUpdates[book.id] = book;
                  refreshed++;
                } else {
                  _addBook(book);
                  added++;
                  _updateScanProgress(
                    scanning: true,
                    processed: processed,
                    total: totalUnits,
                    added: added,
                  );
                }
              } catch (error) {
                _recordScanFailure(failures, manifest.title, error);
                skipped++;
              }
            }
            for (final candidate in seriesGroups) {
              processed++;
              if (totalUnits <= 50 ||
                  processed == 1 ||
                  processed == totalUnits ||
                  processed % 10 == 0) {
                _updateScanProgress(
                  scanning: true,
                  processed: processed,
                  total: totalUnits,
                  added: added,
                );
              }
              final sourceKey = _seriesSourceKeyFor(sourceId, candidate);
              seen.add(sourceKey);
              if (ignored.contains(identityFor(sourceKey).ignoredKey)) {
                skipped++;
                final existingIgnored = byKey[sourceKey];
                if (existingIgnored != null) {
                  _removeBook(existingIgnored);
                  allReconciledData.add(existingIgnored);
                  removed++;
                }
                continue;
              }
              final fingerprint = _computeSeriesCandidateFingerprint(candidate);
              final existing = byKey[sourceKey];
              if (existing != null &&
                  !force &&
                  existing.sourceFingerprint == fingerprint &&
                  await _comicSeriesManifestFile(existing.id).exists()) {
                continue;
              }
              try {
                final book = await _importComicSeries(
                  candidate: candidate,
                  sourceId: sourceId,
                  sourceKey: sourceKey,
                  defaultFileUri: candidate.folderUri.isNotEmpty
                      ? candidate.folderUri
                      : treeUri,
                  fingerprint: fingerprint,
                  existing: existing,
                );
                if (book == null) {
                  skipped++;
                  continue;
                }
                if (existing != null) {
                  chapterUpdates[book.id] = book;
                  refreshed++;
                } else {
                  _addBook(book);
                  added++;
                  _updateScanProgress(
                    scanning: true,
                    processed: processed,
                    total: totalUnits,
                    added: added,
                  );
                }
              } catch (error) {
                _recordScanFailure(failures, candidate.title, error);
                skipped++;
              }
            }

            final staleIgnored = ignored.where((key) {
              try {
                final parts = jsonDecode(key);
                return parts is List &&
                    parts.length == 2 &&
                    parts[0] == sourceId &&
                    !seen.contains(parts[1]);
              } catch (_) {
                return false;
              }
            }).toList();
            if (staleIgnored.isNotEmpty) {
              ignored.removeAll(staleIgnored);
              ignoredDirty = true;
            }

            final removedBooks = _books
                .where(
                  (b) =>
                      b.sourceId == sourceId &&
                      b.sourceKey.isNotEmpty &&
                      !seen.contains(b.sourceKey),
                )
                .toList();
            removed += removedBooks.length;
            allRemovedBooks.addAll(removedBooks);
            _removeBooks(removedBooks);

            final pendingKey = isMangaRoot
                ? 'local_library_manga_pending_cleanups'
                : 'local_library_pending_cleanups';
            final pendingCleanups = _prefs.getStringList(pendingKey) ?? [];
            final currentUri = isMangaRoot ? mangaFolderUri : folderUri;
            final toClean = pendingCleanups
                .where((u) => u.isNotEmpty && u != currentUri)
                .toList();
            if (toClean.isNotEmpty) {
              final prefix = isMangaRoot ? 'saf_manga:' : 'saf:';
              for (final oldUri in toClean) {
                final oldSourceId = '$prefix$oldUri';
                allToDelete.addAll(
                  _books.where((b) => b.sourceId == oldSourceId),
                );
              }
              final remaining = pendingCleanups
                  .where((u) => !toClean.contains(u))
                  .toList();
              pendingCleanupCommits.add((
                prefKey: pendingKey,
                remaining: remaining,
              ));
            }
          }

          if (ignoredDirty) {
            try {
              await _writeIgnoredSources(ignored);
            } catch (_) {}
          }

          switchedRemovedIds.addAll(allToDelete.map((b) => b.id));
          if (allToDelete.isNotEmpty) {
            await _stashTagsForRemoved(allToDelete);
          }
          if (switchedRemovedIds.isNotEmpty) {
            final queued =
                _prefs.getStringList('local_library_associated_cleanup') ?? [];
            final merged = <String>{...queued};
            for (final id in switchedRemovedIds) {
              merged.add('$id');
            }
            await _checkedSet(
              () => _prefs.setStringList(
                'local_library_associated_cleanup',
                merged.toList(),
              ),
              'local_library_associated_cleanup',
            );
          }
          _removeBooks(allToDelete);
          await _stageChapterRemaps(chapterRemaps);
          for (final book in chapterUpdates.values) {
            final index = _indexForBook(book.id);
            if (index >= 0) _replaceBook(index, book);
          }
          await _queueDataCleanup(allRemovedBooks, clearStash: true);
          await _queueDataCleanup([
            ...allToDelete,
            ...allReconciledData,
          ], clearStash: false);
          await _saveIndex();
          await _recoverDataCleanup();
          for (final commit in pendingCleanupCommits) {
            if (commit.remaining.isEmpty) {
              await _prefs.remove(commit.prefKey);
            } else {
              await _checkedSet(
                () => _prefs.setStringList(commit.prefKey, commit.remaining),
                commit.prefKey,
              );
            }
          }
          for (final sid in scannedSourceIds) {
            await _restoreStashedTags(sid);
            await _migrateInternalTagsToFilenames(
              sourceId: sid,
              failures: failures,
            );
          }
          return LocalScanResult(
            added: added,
            refreshed: refreshed,
            removed: removed,
            total: _books.length,
            skipped: skipped,
            backfilled: backfilled,
            failures: failures,
            switchedRemovedIds: switchedRemovedIds,
            chapterRemaps: pendingChapterRemaps,
          );
        }),
      );
    } finally {
      if (!force) _activeScan = null;
      _updateScanProgress(scanning: false, bumpRevision: true);
    }
  }

  /// 备用方案：扫描应用外部文件夹中的 TXT（无需 SAF，直接用 dart:io 读取）。
  /// 用户需手动将小说 TXT 放入 [appFolderPath]/novels/ 目录。
  Future<String> get appFolderPath async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) throw StateError('无法获取应用外部存储目录');
    final novels = Directory('${dir.path}/novels');
    if (!await novels.exists()) await novels.create(recursive: true);
    return novels.path;
  }

  Future<LocalScanResult> scanAppFolder({bool force = false}) async {
    try {
      return await _synchronized(
        () => _scanTransaction((_) async {
          // 与 scan() 同规则：先恢复仅移出待办，再扫描导入。
          await _recordRemovalJournal.recover();
          final folderPath = await appFolderPath;
          const sourceId = 'appFolder:novels';
          final dir = Directory(folderPath);
          final byKey = {
            for (final book in _books)
              if (book.sourceId == sourceId && book.sourceKey.isNotEmpty)
                book.sourceKey: book,
          };
          final byUriLegacy = {
            for (final book in _books)
              if (book.sourceId.isEmpty && book.fileUri.startsWith('file://'))
                book.fileUri: book,
          };
          final seen = <String>{};
          final ignored = _readIgnoredSources();
          final failures = <String, String>{};
          final chapterRemaps = <LocalChapterRemap>[];
          final chapterUpdates = <int, LocalBook>{};
          final reconciledData = <LocalBook>[];
          var added = 0, refreshed = 0, removed = 0, skipped = 0, backfilled = 0;
          final rawFiles = <File>[];
          final fileRelPaths = <String, String>{};
          final comicInfoUrisByDir = <String, String>{};
          final folderCandidates = <ScannedFolderEntry>[];
          final nonImageRelPaths = <String>[];
          final dirUris = <String, String>{};
          Future<void> walkAppDir(
            Directory current,
            String relPrefix,
            int depth,
          ) async {
            if (depth > 14) return;
            await for (final entity in current.list(followLinks: false)) {
              final seg = entity.path.split(Platform.pathSeparator).last;
              if (seg.isEmpty ||
                  seg.startsWith('.') ||
                  seg.toLowerCase() == '__macosx') {
                continue;
              }
              final relPath = relPrefix.isEmpty ? seg : '$relPrefix/$seg';
              if (entity is Directory) {
                dirUris[relPath] = entity.path;
                await walkAppDir(entity, relPath, depth + 1);
              } else if (entity is File) {
                if (isComicImageFileName(seg) || isComicInfoFileName(seg)) {
                  if (seg.toLowerCase() == 'comicinfo.xml') {
                    final slash = relPath.lastIndexOf('/');
                    final dirKey = slash < 0 ? '' : relPath.substring(0, slash);
                    comicInfoUrisByDir.putIfAbsent(dirKey, () => entity.path);
                  }
                  try {
                    final st = await entity.stat();
                    if (st.type == FileSystemEntityType.file) {
                      folderCandidates.add(
                        ScannedFolderEntry(
                          relPath: relPath,
                          name: seg,
                          uri: entity.path,
                          size: st.size,
                          modifiedMs: st.modified.millisecondsSinceEpoch,
                          parentUri: entity.parent.path,
                        ),
                      );
                    }
                  } catch (_) {}
                } else {
                  nonImageRelPaths.add(relPath);
                  final lower = seg.toLowerCase();
                  if (localBookKindForFileName(lower) != null ||
                      isMobiFileName(lower) ||
                      lower.endsWith('.cbr') ||
                      lower.endsWith('.cb7')) {
                    rawFiles.add(entity);
                    fileRelPaths[entity.path] = relPath;
                  } else if (isZipFileName(lower)) {
                    if (await isComicZipFile(entity.path)) {
                      rawFiles.add(entity);
                      fileRelPaths[entity.path] = relPath;
                    }
                  }
                }
              }
            }
          }

          await walkAppDir(dir, '', 0);
          final comicFolders = groupScannedComicFolders(
            entries: folderCandidates,
            rootKeyPrefix: sourceId,
            rootFolderUri: Uri.file(dir.path).toString(),
            rootDisplayName: '本地漫画',
            dirUrisByRelPath: dirUris,
            nonImageRelPaths: nonImageRelPaths,
          );
          final seriesScanCandidates = <ScannedFolderEntry>[];
          for (final file in rawFiles) {
            final seg = file.path.split(Platform.pathSeparator).last;
            final lower = seg.toLowerCase();
            if (lower.endsWith('.cbr') || lower.endsWith('.cb7')) continue;
            try {
              final st = await file.stat();
              if (st.type == FileSystemEntityType.file) {
                seriesScanCandidates.add(
                  ScannedFolderEntry(
                    relPath: fileRelPaths[file.path] ?? seg,
                    name: seg,
                    uri: Uri.file(file.path).toString(),
                    size: st.size,
                    modifiedMs: st.modified.millisecondsSinceEpoch,
                    parentUri: Uri.file(file.parent.path).toString(),
                  ),
                );
              }
            } catch (_) {}
          }
          final groupedSeries = groupScannedComicVolumeSeries(
            entries: seriesScanCandidates,
            isMangaRoot: false,
            rootKeyPrefix: sourceId,
            rootFolderUri: Uri.file(dir.path).toString(),
            rootDisplayName: '本地漫画',
            dirUrisByRelPath: {
              for (final e in dirUris.entries)
                e.key: Uri.file(e.value).toString(),
            },
            comicInfoUrisByDir: comicInfoUrisByDir,
          );
          final seriesGroups = groupedSeries.seriesGroups;
          final groupedMemberUris = <String>{
            for (final g in seriesGroups)
              for (final f in g.files) f.uri,
          };
          final files = [
            for (final f in rawFiles)
              if (!groupedMemberUris.contains(Uri.file(f.path).toString())) f,
          ];
          if (files.isEmpty &&
              comicFolders.isEmpty &&
              seriesGroups.isEmpty &&
              _books.any((book) => book.sourceId == sourceId)) {
            throw const IncompleteScanException('empty_result');
          }
          final totalUnits =
              files.length + comicFolders.length + seriesGroups.length;
          await _reserveIds(
            files
                    .where(
                      (file) =>
                          !byKey.containsKey(file.path) &&
                          !byUriLegacy.containsKey('file://${file.path}') &&
                          !byUriLegacy.containsKey(
                            Uri.file(file.path).toString(),
                          ) &&
                          !ignored.contains(
                            LocalSourceIdentity.appFolder(file.path).ignoredKey,
                          ),
                    )
                    .length +
                comicFolders.where((manifest) {
                  final folderPath = manifest.folderRelPath.isEmpty
                      ? dir.path
                      : '${dir.path}/${manifest.folderRelPath}';
                  return !byKey.containsKey(folderPath) &&
                      !ignored.contains(
                        LocalSourceIdentity.appFolder(folderPath).ignoredKey,
                      );
                }).length +
                seriesGroups.where((candidate) {
                  final key = _seriesSourceKeyFor(
                    sourceId,
                    candidate,
                    appRootPath: dir.path,
                  );
                  return !byKey.containsKey(key) &&
                      !ignored.contains(
                        LocalSourceIdentity.appFolder(key).ignoredKey,
                      );
                }).length,
          );
          var processed = 0;
          _updateScanProgress(
            scanning: true,
            processed: 0,
            total: totalUnits,
            added: 0,
          );
          for (final file in files) {
            processed++;
            if (totalUnits <= 50 ||
                processed == 1 ||
                processed == totalUnits ||
                processed % 10 == 0) {
              _updateScanProgress(
                scanning: true,
                processed: processed,
                total: totalUnits,
                added: added,
              );
            }
            final name = file.path.split(Platform.pathSeparator).last;
            final lower = name.toLowerCase();
            if (lower.endsWith('.cbr')) {
              failures[name] = '暂不支持 RAR/CBR 压缩格式，请转换为 CBZ 或 ZIP 后导入';
              skipped++;
              continue;
            }
            if (lower.endsWith('.cb7')) {
              failures[name] = '暂不支持 7z/CB7 压缩格式，请转换为 CBZ 或 ZIP 后导入';
              skipped++;
              continue;
            }
            final usesUriFile =
                lower.endsWith('.epub') ||
                lower.endsWith('.cbz') ||
                lower.endsWith('.zip') ||
                lower.endsWith('.pdf');
            final uri = usesUriFile
                ? Uri.file(file.path).toString()
                : 'file://${file.path}';
            final legacy =
                byUriLegacy[uri] ?? byUriLegacy['file://${file.path}'];
            final sourceKey = file.path;
            seen.add(sourceKey);
            // 「仅移出书库」的书跳过导入；记录仍在时对账移除（与 scan() 同规则）。
            // 忽略键统一走 LocalSourceIdentity，与 _effectiveIgnoredKeyFor 一致。
            if (ignored.contains(
              LocalSourceIdentity.appFolder(file.path).ignoredKey,
            )) {
              skipped++;
              final existingIgnored = byKey[sourceKey] ?? legacy;
              if (existingIgnored != null) {
                _removeBook(existingIgnored);
                reconciledData.add(existingIgnored);
                removed++;
              }
              continue;
            }
            final relPath = fileRelPaths[file.path] ?? name;
            final entryIsManga =
                hasExplicitComicPathHint(relPath) ||
                hasExplicitComicPathHint(name);
            final FileStat stat;
            try {
              stat = await file.stat();
              if (stat.type != FileSystemEntityType.file) {
                throw const FileSystemException('文件暂不可读');
              }
            } catch (error) {
              _recordScanFailure(failures, name, error);
              skipped++;
              continue;
            }
            final size = stat.size;
            final modified = stat.modified.millisecondsSinceEpoch;
            var existing = byKey[sourceKey] ?? legacy;
            if (existing != null) {
              if (existing.fileName != name ||
                  existing.fileUri != uri ||
                  existing.sourceKey != sourceKey) {
                existing = _withFilenameMetadata(
                  existing,
                  name,
                  fileUri: uri,
                  sourceKey: sourceKey,
                );
                chapterUpdates[existing.id] = existing;
              }
              if (entryIsManga && !existing.isMangaSource) {
                existing = existing.copyWith(isMangaSource: true);
                chapterUpdates[existing.id] = existing;
              }
              if ((existing.kind == LocalBookKind.pdf ||
                      existing.kind == LocalBookKind.comic ||
                      (existing.kind == LocalBookKind.epub &&
                          existing.chapterSplitVersion ==
                              _chapterSplitVersion &&
                          existing.chapters.isNotEmpty)) &&
                  !force &&
                  existing.size == size &&
                  existing.modified == modified) {
                continue;
              }
              if (!force &&
                  existing.kind == LocalBookKind.txt &&
                  existing.size == size &&
                  existing.modified == modified &&
                  existing.chapterSplitVersion ==
                      _chapterSplitVersionFor(existing) &&
                  existing.wordCount != null &&
                  existing.sourceFingerprint.isNotEmpty) {
                try {
                  if (await _sourceHasFingerprint(
                    existing,
                    existing.sourceFingerprint,
                  )) {
                    continue;
                  }
                } catch (error) {
                  _recordScanFailure(failures, name, error);
                  skipped++;
                  continue;
                }
              }
              LocalBook? book;
              try {
                await _preserveCachedSnapshot(existing);
                book = await _importDirectFile(
                  path: file.path,
                  name: name,
                  size: size,
                  modified: modified,
                  sourceId: sourceId,
                  sourceKey: sourceKey,
                  isMangaSource: entryIsManga,
                  existing: existing,
                );
              } on _NonComicZipSkipException {
                seen.remove(sourceKey);
                continue;
              } catch (error) {
                _recordScanFailure(failures, name, error);
                skipped++;
                continue;
              }
              if (book == null) {
                failures[name] = lower.endsWith('.pdf')
                    ? 'PDF 没有可读取的页面'
                    : '文件内容为空';
                skipped++;
                continue;
              }
              if (!force &&
                  book.revision == existing.revision &&
                  book.size == existing.size &&
                  book.modified == existing.modified &&
                  book.wordCount == existing.wordCount &&
                  book.isMangaSource == existing.isMangaSource &&
                  book.sourceFingerprint == existing.sourceFingerprint) {
                continue;
              }
              if (book.kind == LocalBookKind.txt &&
                  existing.chapters.isNotEmpty &&
                  book.revision != existing.revision) {
                chapterRemaps.add(_remapFor(existing, book));
              }
              if (existing.wordCount == null && book.wordCount != null) {
                backfilled++;
              }
              chapterUpdates[book.id] = book;
              refreshed++;
            } else {
              LocalBook? book;
              try {
                book = await _importDirectFile(
                  path: file.path,
                  name: name,
                  size: size,
                  modified: modified,
                  sourceId: sourceId,
                  sourceKey: sourceKey,
                  isMangaSource: entryIsManga,
                );
              } on _NonComicZipSkipException {
                seen.remove(sourceKey);
                continue;
              } catch (error) {
                _recordScanFailure(failures, name, error);
                skipped++;
                continue;
              }
              if (book == null) {
                failures[name] = lower.endsWith('.pdf')
                    ? 'PDF 没有可读取的页面'
                    : '文件内容为空';
                skipped++;
                continue;
              }
              _addBook(book);
              added++;
              _updateScanProgress(
                scanning: true,
                processed: processed,
                total: totalUnits,
                added: added,
              );
            }
          }
          for (final manifest in comicFolders) {
            processed++;
            if (totalUnits <= 50 ||
                processed == 1 ||
                processed == totalUnits ||
                processed % 10 == 0) {
              _updateScanProgress(
                scanning: true,
                processed: processed,
                total: totalUnits,
                added: added,
              );
            }
            final folderPath = manifest.folderRelPath.isEmpty
                ? dir.path
                : '${dir.path}/${manifest.folderRelPath}';
            final sourceKey = folderPath;
            seen.add(sourceKey);
            if (ignored.contains(
              LocalSourceIdentity.appFolder(sourceKey).ignoredKey,
            )) {
              skipped++;
              final existingIgnored = byKey[sourceKey];
              if (existingIgnored != null) {
                _removeBook(existingIgnored);
                reconciledData.add(existingIgnored);
                removed++;
              }
              continue;
            }
            final fingerprint = _computeFolderManifestFingerprint(manifest);
            final existing = byKey[sourceKey];
            if (existing != null &&
                !force &&
                existing.sourceFingerprint == fingerprint &&
                await _comicManifestFile(existing.id).exists()) {
              continue;
            }
            try {
              final book = await _importComicFolder(
                manifest: manifest,
                sourceId: sourceId,
                sourceKey: sourceKey,
                defaultFileUri: Uri.file(folderPath).toString(),
                fingerprint: fingerprint,
                existing: existing,
              );
              if (book == null) {
                skipped++;
                continue;
              }
              if (existing != null) {
                chapterUpdates[book.id] = book;
                refreshed++;
              } else {
                _addBook(book);
                added++;
                _updateScanProgress(
                  scanning: true,
                  processed: processed,
                  total: totalUnits,
                  added: added,
                );
              }
            } catch (error) {
              _recordScanFailure(failures, manifest.title, error);
              skipped++;
            }
          }
          for (final candidate in seriesGroups) {
            processed++;
            if (totalUnits <= 50 ||
                processed == 1 ||
                processed == totalUnits ||
                processed % 10 == 0) {
              _updateScanProgress(
                scanning: true,
                processed: processed,
                total: totalUnits,
                added: added,
              );
            }
            final sourceKey = _seriesSourceKeyFor(
              sourceId,
              candidate,
              appRootPath: dir.path,
            );
            seen.add(sourceKey);
            if (ignored.contains(
              LocalSourceIdentity.appFolder(sourceKey).ignoredKey,
            )) {
              skipped++;
              final existingIgnored = byKey[sourceKey];
              if (existingIgnored != null) {
                _removeBook(existingIgnored);
                reconciledData.add(existingIgnored);
                removed++;
              }
              continue;
            }
            final fingerprint = _computeSeriesCandidateFingerprint(candidate);
            final existing = byKey[sourceKey];
            if (existing != null &&
                !force &&
                existing.sourceFingerprint == fingerprint &&
                await _comicSeriesManifestFile(existing.id).exists()) {
              continue;
            }
            try {
              final book = await _importComicSeries(
                candidate: candidate,
                sourceId: sourceId,
                sourceKey: sourceKey,
                defaultFileUri: candidate.folderUri.isNotEmpty
                    ? candidate.folderUri
                    : Uri.file(dir.path).toString(),
                fingerprint: fingerprint,
                existing: existing,
              );
              if (book == null) {
                skipped++;
                continue;
              }
              if (existing != null) {
                chapterUpdates[book.id] = book;
                refreshed++;
              } else {
                _addBook(book);
                added++;
                _updateScanProgress(
                  scanning: true,
                  processed: processed,
                  total: totalUnits,
                  added: added,
                );
              }
            } catch (error) {
              _recordScanFailure(failures, candidate.title, error);
              skipped++;
            }
          }
          // 只清理当前来源的书籍（修复#1）。
          final appRemovedBooks = _books
              .where(
                (b) =>
                    b.sourceId == sourceId &&
                    b.sourceKey.isNotEmpty &&
                    !seen.contains(b.sourceKey),
              )
              .toList();
          // 文件已从磁盘删除：不暂存标签，同时清除可能残留的暂存条目。
          removed += appRemovedBooks.length;
          _removeBooks(appRemovedBooks);
          // 忽略名单清理：本来源下源文件已消失的条目自动移除（与 scan() 同规则，
          // 写失败不中断扫描）。
          final staleIgnored = ignored.where((key) {
            try {
              final parts = jsonDecode(key);
              return parts is List &&
                  parts.length == 2 &&
                  parts[0] == sourceId &&
                  !seen.contains(parts[1]);
            } catch (_) {
              return false;
            }
          }).toList();
          if (staleIgnored.isNotEmpty) {
            ignored.removeAll(staleIgnored);
            try {
              await _writeIgnoredSources(ignored);
            } catch (_) {}
          }
          await _stageChapterRemaps(chapterRemaps);
          for (final book in chapterUpdates.values) {
            final index = _indexForBook(book.id);
            if (index >= 0) _replaceBook(index, book);
          }
          await _queueDataCleanup(appRemovedBooks, clearStash: true);
          await _queueDataCleanup(reconciledData, clearStash: false);
          await _saveIndex();
          await _recoverDataCleanup();
          // 完整扫描成功：恢复暂存标签并清理失效条目（与 scan() 同规则）。
          await _restoreStashedTags(sourceId);
          await _migrateInternalTagsToFilenames(
            sourceId: sourceId,
            failures: failures,
          );
          return LocalScanResult(
            added: added,
            refreshed: refreshed,
            removed: removed,
            total: _books.length,
            skipped: skipped,
            backfilled: backfilled,
            failures: failures,
            // 返回持久化队列而非仅本轮新发现的迁移（与 scan() 同规则）。
            chapterRemaps: pendingChapterRemaps,
          );
        }),
      );
    } finally {
      _updateScanProgress(scanning: false, bumpRevision: true);
    }
  }

  /// 直接从文件路径导入 TXT / EPUB / CBZ / ZIP漫画 / PDF / MOBI / AZW3。
  Future<LocalBook?> _importDirectFile({
    required String path,
    required String name,
    required int size,
    required int modified,
    required String sourceId,
    required String sourceKey,
    bool isMangaSource = false,
    LocalBook? existing,
  }) async {
    final isZipCandidate = isZipFileName(name);
    final kind = localBookKindForFileName(name) ??
        (isZipCandidate ? LocalBookKind.comic : null);
    if (kind == LocalBookKind.comic) {
      if (isZipCandidate && !await isComicZipFile(path)) {
        throw const _NonComicZipSkipException();
      }
      final comicId = existing?.id ?? _nextId();
      return _importComicArchive(
        localPath: path,
        uri: Uri.file(path).toString(),
        name: name,
        size: size,
        modified: modified,
        sourceId: sourceId,
        sourceKey: sourceKey,
        isMangaSource: isMangaSource,
        existing: existing,
        id: comicId,
      );
    }
    if (kind == LocalBookKind.pdf) {
      final pdfUri = Uri.file(path).toString();
      final pages = await LocalPlatform.pdfPageCount(pdfUri);
      if (pages <= 0) return null;
      final pdfId = existing?.id ?? _nextId();
      final sourceFingerprint = await _streamFileSha256(File(path));
      return LocalBook(
        id: pdfId,
        title: _titleFromName(name),
        author: _authorFromName(name),
        fileUri: pdfUri,
        fileName: name,
        kind: LocalBookKind.pdf,
        size: size,
        modified: modified,
        chapters: const [],
        pageCount: pages,
        sourceFingerprint: sourceFingerprint,
        sourceId: sourceId,
        sourceKey: sourceKey,
        isMangaSource: isMangaSource,
        customTitle: existing?.customTitle,
        customAuthor: existing?.customAuthor,
        chapterSplitVersion: _chapterSplitVersion,
      );
    }
    if (kind == LocalBookKind.epub) {
      final epubId = existing?.id ?? _nextId();
      try {
        return await _importEpub(
          localPath: path,
          uri: Uri.file(path).toString(),
          name: name,
          size: size,
          modified: modified,
          sourceId: sourceId,
          sourceKey: sourceKey,
          isMangaSource: isMangaSource,
          existing: existing,
          id: epubId,
        );
      } on StateError {
        final fallback = await _tryImportMisnamedEpubFile(
          localPath: path,
          uri: 'file://$path',
          name: name,
          size: size,
          modified: modified,
          sourceId: sourceId,
          sourceKey: sourceKey,
          isMangaSource: isMangaSource,
          id: epubId,
          existing: existing,
        );
        if (fallback != null) return fallback;
        rethrow;
      }
    }
    if (size > localTextMaxSourceBytes) {
      throw const FormatException('TXT 文件过大：超过 256 MiB 导入上限');
    }
    final id = existing?.id ?? _nextId();
    if (isMobiFileName(name)) {
      final rawBytes = await File(path).readAsBytes();
      final mobi = extractMobiBook(rawBytes, fallbackTitle: _titleFromName(name));
      if (mobi.text.isEmpty) return null;
      final sourceFingerprint = sha256.convert(rawBytes).toString();
      final textFingerprint = sha256.convert(utf8.encode(mobi.text)).toString();
      final target = '${_booksDir.path}/book_${id}_$textFingerprint.txt';
      await File(target).writeAsString(mobi.text, flush: true);
      return LocalBook(
        id: id,
        title: mobi.title.isNotEmpty ? mobi.title : _titleFromName(name),
        author: mobi.author.isNotEmpty ? mobi.author : _authorFromName(name),
        fileUri: 'file://$path',
        fileName: name,
        kind: LocalBookKind.txt,
        size: size,
        modified: modified,
        textFingerprint: textFingerprint,
        sourceFingerprint: sourceFingerprint,
        chapters: mobi.chapters,
        pageCount: 0,
        wordCount: _countWords(mobi.text),
        sourceId: sourceId,
        sourceKey: sourceKey,
        customTitle: existing?.customTitle,
        customAuthor: existing?.customAuthor,
        chapterSplitVersion: _chapterSplitVersion,
      );
    }
    final processed = await _importText(path, id, direct: true);
    if (processed.inputLength == 0) return null;
    var chapters = processed.chapters;
    if (existing != null && existing.hasCustomChapterSplit) {
      final customChapters = await _textWorker.splitCustom(
        '${_booksDir.path}/book_${id}_${processed.fingerprint}.txt',
        customPattern: existing.customTocPattern,
        maxChapterChars: existing.customMaxChapterChars,
        enableChapterExtensions:
            _activeChapterSplitVersion == _extendedChapterSplitVersion,
      );
      if (customChapters.isNotEmpty) {
        chapters = customChapters;
      }
    }
    return LocalBook(
      id: id,
      title: _titleFromName(name),
      author: _authorFromName(name),
      fileUri: 'file://$path',
      fileName: name,
      kind: LocalBookKind.txt,
      size: size,
      modified: modified,
      textFingerprint: processed.fingerprint,
      sourceFingerprint: processed.sourceFingerprint,
      chapters: chapters,
      pageCount: 0,
      wordCount: processed.wordCount,
      sourceId: sourceId,
      sourceKey: sourceKey,
      customTitle: existing?.customTitle,
      customAuthor: existing?.customAuthor,
      chapterSplitVersion: _activeChapterSplitVersion,
      customTocPattern: existing?.customTocPattern,
      customMaxChapterChars: existing?.customMaxChapterChars ?? 0,
    );
  }

  Future<void> removeBook(int id) => _synchronized(() async {
    final book = bookFor(id);
    if (book == null) return;
    await _clearTagStashKeys([book]);
    await _deleteBookData(book);
    _removeBook(book);
    await _saveIndex();
  });

  /// 删除源文件并移除书籍记录（书架/标签/阅读进度由调用方清理）。
  /// 源文件删除失败时抛错且保留记录；记录保存失败时恢复内存记录并抛
  /// [BookCleanupFailed]（重试时文件不存在视为已删，可继续完成清理）。
  Future<void> deleteBookFile(int id) => _synchronized(() async {
    final book = bookFor(id);
    if (book == null) return;
    await _deleteBookFileUnlocked(book);
  });

  /// Duplicate cleanup uses the reviewed snapshots and rechecks source bytes
  /// while holding the same mutation lock as scanning/importing/renaming.
  /// No fallback to record-only removal: a failure must not be called deleted.
  Future<void> deleteDuplicateBookFile(
    LocalBook expected, {
    required LocalBook keeper,
  }) => _synchronized(() async {
    if (expected.id == keeper.id ||
        !identical(bookFor(expected.id), expected) ||
        !identical(bookFor(keeper.id), keeper)) {
      throw StateError('书库已变化，请重新查重后再删除');
    }
    if ((expected.sourceFingerprint.isEmpty &&
            expected.kind != LocalBookKind.pdf) ||
        (keeper.sourceFingerprint.isEmpty &&
            keeper.kind != LocalBookKind.pdf)) {
      throw StateError('缺少源文件指纹，请先扫描文件夹后再清理');
    }
    final source = await _duplicateSourceIdentity(expected);
    for (final other in _books) {
      if (other.id != expected.id &&
          await _duplicateSourceIdentity(other) == source) {
        throw StateError('多个记录指向同一源文件，已跳过以保护保留的书籍');
      }
    }
    // Also verify the retained source is accessible and unchanged. Otherwise
    // an externally deleted/modified keeper could leave no valid copy.
    for (final book in [keeper, expected]) {
      await _verifyDuplicateBookUnchanged(book);
    }
    await _deleteBookFileUnlocked(expected);
  });

  Future<String> _streamFileSha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> _verifyDuplicateBookUnchanged(LocalBook book) async {
    if (book.isComicFolder) {
      final manifest = await loadComicFolderManifest(book.id);
      if (manifest == null ||
          _computeFolderManifestFingerprint(manifest) !=
              book.sourceFingerprint) {
        throw StateError('源文件已变化，请重新扫描后再清理');
      }
      return;
    }
    if (book.isComicSeries) {
      final manifest = await loadComicSeriesManifest(book.id);
      if (manifest == null ||
          manifest.volumes.isEmpty ||
          manifest.totalBytes != book.size ||
          manifest.pageCount != book.pageCount) {
        throw StateError('源文件已变化，请重新扫描后再清理');
      }
      for (final vol in manifest.volumes) {
        if (vol.uri.startsWith('content:')) {
          if (vol.kind == 'pdf') {
            final pages = await LocalPlatform.pdfPageCount(vol.uri);
            if (pages != vol.pageCount) {
              throw StateError('源文件已变化，请重新扫描后再清理');
            }
          }
        } else {
          final f = vol.uri.startsWith('file:')
              ? File.fromUri(Uri.parse(vol.uri))
              : File(vol.uri);
          final stat = await f.stat();
          if (stat.type != FileSystemEntityType.file || stat.size != vol.size) {
            throw StateError('源文件已变化，请重新扫描后再清理');
          }
        }
      }
      return;
    }
    if (book.sourceFingerprint.isEmpty) {
      if (book.fileUri.startsWith('content:')) {
        final pages = await LocalPlatform.pdfPageCount(book.fileUri);
        if (pages <= 0 || (book.pageCount > 0 && pages != book.pageCount)) {
          throw StateError('源文件已变化，请重新扫描后再清理');
        }
      } else {
        final stat = await _sourceFile(book).stat();
        if (stat.type != FileSystemEntityType.file ||
            (book.size > 0 && stat.size != book.size)) {
          throw StateError('源文件已变化，请重新扫描后再清理');
        }
      }
      return;
    }
    String actual;
    if (book.fileUri.startsWith('content:')) {
      if (book.kind != LocalBookKind.txt &&
          book.size > localTextMaxSourceBytes) {
        final cacheFile = await _epubCacheFile(book.id);
        final staged = await _stageEpubCopy(
          book.fileUri,
          book.size,
          cacheFile.parent,
        );
        try {
          actual = await _streamFileSha256(staged);
        } finally {
          await staged.parent.delete(recursive: true);
        }
      } else {
        actual = await LocalPlatform.fingerprintLocalText(book.fileUri);
      }
    } else {
      actual = book.kind == LocalBookKind.txt
          ? await _textWorker.fingerprint(_sourceFile(book).path)
          : await _streamFileSha256(_sourceFile(book));
    }
    if (actual != book.sourceFingerprint) {
      throw StateError('源文件已变化，请重新扫描后再清理');
    }
  }

  Future<String> _duplicateSourceIdentity(LocalBook book) async {
    if (book.isComicFolder) {
      return 'comic_folder:${book.sourceId}:${book.sourceKey}';
    }
    if (book.isComicSeries) {
      return 'comic_series:${book.sourceId}:${book.sourceKey}';
    }
    final locator = book.sourceKey.isNotEmpty ? book.sourceKey : book.fileUri;
    final uri = Uri.tryParse(locator);
    if (uri?.scheme == 'content') {
      final segments = uri!.pathSegments;
      final document = segments.lastIndexOf('document');
      if (document >= 0 && document + 1 < segments.length) {
        return 'content:${uri.authority}:${segments[document + 1]}';
      }
      return locator;
    }
    final file = _sourceFile(book);
    try {
      return await file.resolveSymbolicLinks();
    } on FileSystemException {
      return file.absolute.uri.normalizePath().toFilePath();
    }
  }

  Future<void> _deleteBookFileUnlocked(LocalBook book) async {
    await _queueDataCleanup([book], clearStash: true);
    if (book.isComicFolder) {
      final manifest = await loadComicFolderManifest(book.id);
      if (book.fileUri.startsWith('content:')) {
        if (book.fileUri != folderUri &&
            book.fileUri != mangaFolderUri &&
            manifest != null &&
            manifest.folderRelPath.isNotEmpty &&
            manifest.folderUri == book.fileUri) {
          await LocalPlatform.deleteLocalDocument(book.fileUri);
        } else if (manifest != null) {
          for (final page in manifest.pages) {
            await LocalPlatform.deleteLocalDocument(page.uri);
          }
          if (manifest.comicInfoUri != null &&
              manifest.comicInfoUri!.isNotEmpty) {
            try {
              await LocalPlatform.deleteLocalDocument(manifest.comicInfoUri!);
            } catch (_) {}
          }
        } else {
          throw const LocalDeleteException('missing_manifest', '漫画目录清单缺失，请重新扫描');
        }
      } else {
        if (manifest != null) {
          for (final page in manifest.pages) {
            final f = page.uri.startsWith('file:')
                ? File.fromUri(Uri.parse(page.uri))
                : File(page.uri);
            if (await f.exists()) await f.delete();
          }
          if (manifest.comicInfoUri != null &&
              manifest.comicInfoUri!.isNotEmpty) {
            final info = manifest.comicInfoUri!.startsWith('file:')
                ? File.fromUri(Uri.parse(manifest.comicInfoUri!))
                : File(manifest.comicInfoUri!);
            if (await info.exists()) await info.delete();
          }
        }
        if (book.sourceKey.isNotEmpty) {
          final appRoot = await appFolderPath;
          final dir = Directory(book.sourceKey);
          if (dir.path != appRoot && await dir.exists()) {
            try {
              if (await dir.list().isEmpty) {
                await dir.delete();
              }
            } catch (_) {}
          }
        }
      }
    } else if (book.isComicSeries) {
      final manifest = await loadComicSeriesManifest(book.id);
      if (manifest == null) {
        throw const LocalDeleteException('missing_manifest', '多卷漫画清单缺失，请重新扫描');
      }
      if (manifest.volumes.any((v) => v.uri.startsWith('content:'))) {
        for (final vol in manifest.volumes) {
          await LocalPlatform.deleteLocalDocument(vol.uri);
        }
        if (manifest.comicInfoUri != null &&
            manifest.comicInfoUri!.isNotEmpty) {
          try {
            await LocalPlatform.deleteLocalDocument(manifest.comicInfoUri!);
          } catch (_) {}
        }
      } else {
        for (final vol in manifest.volumes) {
          final f = vol.uri.startsWith('file:')
              ? File.fromUri(Uri.parse(vol.uri))
              : File(vol.uri);
          if (await f.exists()) await f.delete();
        }
        if (manifest.comicInfoUri != null &&
            manifest.comicInfoUri!.isNotEmpty) {
          final info = manifest.comicInfoUri!.startsWith('file:')
              ? File.fromUri(Uri.parse(manifest.comicInfoUri!))
              : File(manifest.comicInfoUri!);
          if (await info.exists()) await info.delete();
        }
        if (manifest.folderRelPath.isNotEmpty) {
          try {
            final appRoot = await appFolderPath;
            final dir = Directory('$appRoot/${manifest.folderRelPath}');
            if (dir.path != appRoot && await dir.exists()) {
              if (await dir.list().isEmpty) {
                await dir.delete();
              }
            }
          } catch (_) {}
        }
      }
    } else if (book.fileUri.startsWith('content:')) {
      await LocalPlatform.deleteLocalDocument(book.fileUri);
    } else {
      final file = _sourceFile(book);
      if (await file.exists()) await file.delete();
    }
    final index = _indexForBook(book.id);
    final generation = _indexGeneration;
    _removeBook(book);
    try {
      await _saveIndex();
    } catch (e) {
      if (generation == _indexGeneration) {
        _books.insert(index, book);
        _rebuildBookPositions();
      }
      throw const BookCleanupFailed('书籍记录保存失败');
    }
    try {
      await _recoverDataCleanup();
    } catch (_) {
      throw const BookCleanupFailed('书籍关联记录尚未清理完成');
    }
  }

  /// 仅移出书库：删除内部副本与书籍记录，源文件保留在手机存储中。
  /// 记录加入忽略名单，后续扫描不会把同一源文件重新导入（扫描侧另有对账，
  /// 见 scan 中 ignored 分支）。
  /// 事务顺序（见 [RecordRemovalJournal]）：先写准备待办，再写忽略名单，
  /// 再写提交待办，最后清理标签/副本并保存索引。提交前失败回滚忽略名单，
  /// 书仍保留在库中；提交后失败抛 [RecordRemovalPending]，下次启动或
  /// 扫描时继续完成移除，不再声称“任何失败都留在库中”。书架/标签/
  /// 阅读进度的清理由调用方负责（与 [deleteBookFile] 相同约定）。
  Future<void> removeBookRecordOnly(int id) => _synchronized(() async {
    // 必须先恢复，不能用新操作覆盖旧待办。
    await _recordRemovalJournal.recover();
    if (bookFor(id) case final book?) await _queueAssociatedCleanup([book]);
    final book = bookFor(id);
    if (book == null) return;
    final hasIgnoreKey = book.sourceKey.isNotEmpty || book.fileUri.isNotEmpty;
    String? ignoreKey;
    if (hasIgnoreKey) {
      try {
        ignoreKey = _effectiveIgnoredKeyFor(book);
      } catch (_) {
        // 来源无法确认时拒绝此次移出，不能先删记录再让下次扫描
        // 重新导入：记录保留，用户先扫描原目录回填来源后再移出。
        throw const BookCleanupFailed('无法确认源文件身份，请先扫描原目录后重试');
      }
    }
    try {
      await _recordRemovalJournal.remove(bookId: id, ignoreKey: ignoreKey);
    } on RecordRemovalPending {
      rethrow;
    } catch (_) {
      // 走到这里表示提交前失败，且回滚已经完成。
      throw const BookCleanupFailed('移除未提交，书籍仍保留在库中');
    }
  });

  /// 从书名派生安全的文件名（保留原扩展名及其大小写）。
  /// 返回 null 表示书名无法派生出合法文件名。
  static String? safeFileNameForTitle(
    String fileName,
    String title, {
    Iterable<String>? tags,
  }) {
    final effectiveTags = tags ?? parseFilenameTags(fileName).tags;
    final dot = fileName.lastIndexOf('.');
    final ext = dot > 0 ? fileName.substring(dot) : '';
    var stem = title.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
    stem = stem.replaceAll(RegExp(r'[. ]+$'), '');
    if (stem.isEmpty || stem == '.' || stem == '..') return null;
    if (RegExp(
      r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
      caseSensitive: false,
    ).hasMatch(stem)) {
      stem = '_$stem';
    }
    var name = '$stem$ext';
    final suffix = appendFilenameTags(ext, effectiveTags);
    final keep = 200 - utf8.encode(suffix).length;
    if (keep <= 0) return null;
    if (utf8.encode(name).length > keep + utf8.encode(ext).length) {
      final buffer = StringBuffer();
      var bytes = 0;
      for (final rune in stem.runes) {
        final character = String.fromCharCode(rune);
        final count = utf8.encode(character).length;
        if (bytes + count > keep) break;
        buffer.write(character);
        bytes += count;
      }
      if (buffer.isEmpty) return null;
      name = '$buffer$ext';
    }
    return appendFilenameTags(name, effectiveTags);
  }

  /// 预览编辑书名与标签后的目标文件名；返回 null 表示书名无法派生合法文件名。
  static String? previewEditedFileName(
    LocalBook book, {
    required String title,
    Iterable<String>? tagNames,
  }) {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) return null;
    if (book.isDirectoryBackedComic) return book.fileName;
    final renamed = cleanTitle != book.displayTitle;
    if (!renamed && tagNames == null) return book.fileName;
    final effectiveTags = tagNames ??
        <String>{
          ...parseFilenameTags(book.fileName).tags,
          ...?TagStore.maybeShared?.tagNamesForBook(book.id),
        };
    if (renamed) {
      return safeFileNameForTitle(
        book.fileName,
        cleanTitle,
        tags: effectiveTags,
      );
    }
    return appendFilenameTags(
      stripFilenameTags(book.fileName),
      effectiveTags,
    );
  }

  /// Changes source filename first; failed renames leave internal tags intact.
  Future<LocalBook> setTagsForBook(int id, Iterable<String> tagIds) {
    final ids = tagIds.toSet();
    return _synchronized(() async {
      final book = bookFor(id);
      if (book == null) throw StateError('书籍不存在');
      final store = TagStore.shared;
      final names = <String>[];
      for (final id in ids) {
        final tag = store.tagById(id);
        if (tag == null) throw StateError('标签已不存在，请重新选择');
        names.add(tag.name);
      }
      if (book.isDirectoryBackedComic) {
        await _clearTagStashKeys([book], clearBookTags: false);
        await store.setTagsForBook(id, ids);
        notifyListeners();
        return book;
      }
      final target = appendFilenameTags(
        stripFilenameTags(book.fileName),
        names,
      );
      return _commitFilename(
        book,
        target,
        commitTags: () => store.setTagsForBook(id, ids),
      );
    });
  }

  Future<void> renameTag(String id, String name) => _synchronized(() async {
    TagStore.validateTagName(name);
    final tag = TagStore.shared.tagById(id);
    if (tag == null || tag.name == name) return;
    if (TagStore.shared.tags.any((t) => t.id != id && t.name == name)) {
      throw ArgumentError('同名标签已存在');
    }
    await _editTagSources(id, name, () => TagStore.shared.renameTag(id, name));
  });

  Future<void> deleteTag(String id) => _synchronized(() async {
    if (TagStore.shared.tagById(id) == null) return;
    await _editTagSources(id, null, () => TagStore.shared.deleteTag(id));
  });

  Future<void> _editTagSources(
    String tagId,
    String? replacement,
    Future<void> Function() commit,
  ) async {
    final changed = <LocalBook>[];
    try {
      for (final book in _books.toList()) {
        if (book.isDirectoryBackedComic) continue;
        final tags = TagStore.shared.tagsForBook(book.id);
        if (!tags.any((tag) => tag.id == tagId)) continue;
        final names = <String>{
          for (final tag in tags)
            if (tag.id != tagId) tag.name else ?replacement,
        };
        final target = appendFilenameTags(
          stripFilenameTags(book.fileName),
          names,
        );
        final updated = await _renameSourceFile(book, target);
        if (identical(updated, book)) continue;
        changed.add(book);
        _replaceBook(_indexForBook(book.id), updated);
      }
      await _saveIndex();
      await commit();
    } catch (error, stack) {
      if (changed.isNotEmpty) await _restoreRenamedBooks(changed, cause: error);
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// 编辑书名/作者（及可选的标签集合）；书名或标签变化时一次性重命名源文件
  /// （保留扩展名），book.id 不变。成功返回更新后的 LocalBook；失败时抛错且不改动记录。
  Future<LocalBook> editBookFile(
    int id, {
    required String title,
    required String author,
    Iterable<String>? tagIds,
  }) => _synchronized(() async {
    final index = _indexForBook(id);
    if (index < 0) throw StateError('书籍不存在');
    final book = _books[index];
    final cleanTitle = title.trim();
    final cleanAuthor = author.trim();
    if (cleanTitle.isEmpty) throw ArgumentError('书名不能为空');

    Set<String>? resolvedTagIds;
    List<String>? explicitTagNames;
    if (tagIds != null) {
      final store = TagStore.shared;
      resolvedTagIds = tagIds.toSet();
      explicitTagNames = <String>[];
      for (final tagId in resolvedTagIds) {
        final tag = store.tagById(tagId);
        if (tag == null) throw StateError('标签已不存在，请重新选择');
        explicitTagNames.add(tag.name);
      }
    }

    final targetName = previewEditedFileName(
      book,
      title: cleanTitle,
      tagNames: explicitTagNames,
    );
    if (targetName == null) throw ArgumentError('书名无法用作文件名');

    var updated = book;
    if (!book.isDirectoryBackedComic && targetName != book.fileName) {
      updated = await _renameSourceFile(book, targetName);
    }
    updated = updated.copyWith(
      customTitle: cleanTitle,
      customAuthor: cleanAuthor.isEmpty ? null : cleanAuthor,
    );
    try {
      _replaceBook(index, updated);
      await _saveIndex();
      if (resolvedTagIds != null) {
        await _clearTagStashKeys([book], clearBookTags: false);
        await TagStore.shared.setTagsForBook(id, resolvedTagIds);
      }
    } catch (error, stack) {
      if (!book.isDirectoryBackedComic) {
        await _restoreRenamedBooks([book], cause: error);
      }
      Error.throwWithStackTrace(error, stack);
    }
    notifyListeners();
    return updated;
  });

  /// 把重命名后的文件改回原名（editBookFile 回滚用）。
  /// 返回回滚后的实际文件信息（SAF 回滚可能产生新 URI）。
  Future<LocalBook> _renameBack(LocalBook original, LocalBook current) async {
    final restored = await _renameSourceFile(current, original.fileName);
    return original.copyWith(
      fileUri: restored.fileUri,
      sourceKey: restored.sourceKey,
      customTitle: original.customTitle,
      customAuthor: original.customAuthor,
    );
  }

  /// 内部副本清理是否完整成功。
  Future<bool> _deleteBookData(LocalBook book) async {
    _invalidateTextCache(book.id);
    var ok = true;
    try {
      final textFile = File(textPathFor(book));
      if (await textFile.exists()) await textFile.delete();
      final dir = _booksDir;
      if (await dir.exists()) {
        final prefix = 'book_${book.id}_';
        final legacyName = 'book_${book.id}.txt';
        final upgradingName = 'book_${book.id}.upgrading';
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final base = entity.uri.pathSegments.isNotEmpty
              ? entity.uri.pathSegments.last
              : entity.path.split(Platform.pathSeparator).last;
          if (base == legacyName ||
              base == upgradingName ||
              (base.startsWith(prefix) && base.endsWith('.txt'))) {
            if (await entity.exists()) await entity.delete();
          }
        }
      }
    } catch (_) {
      ok = false;
    }
    if (book.sourceId == 'cloud:imported' && book.sourceKey.isNotEmpty) {
      final shared = _books.any(
        (other) => other.id != book.id && other.sourceKey == book.sourceKey,
      );
      if (!shared) {
        try {
          final cloudDir = Directory('${_booksDir.path}/cloud_originals');
          final cloudFile = File(book.sourceKey);
          if (await cloudDir.exists() && await cloudFile.exists()) {
            final root = await cloudDir.resolveSymbolicLinks();
            final resolved = await cloudFile.resolveSymbolicLinks();
            if (resolved.startsWith('$root${Platform.pathSeparator}')) {
              await cloudFile.delete();
            }
          }
        } catch (_) {
          ok = false;
        }
      }
    }
    try {
      final manifestFile = _comicManifestFile(book.id);
      if (await manifestFile.exists()) await manifestFile.delete();
    } catch (_) {
      ok = false;
    }
    try {
      final seriesManifestFile = _comicSeriesManifestFile(book.id);
      if (await seriesManifestFile.exists()) await seriesManifestFile.delete();
    } catch (_) {
      ok = false;
    }
    if (book.kind == LocalBookKind.pdf) {
      try {
        await LocalPlatform.clearPdfCache(book.fileUri);
      } catch (_) {
        ok = false;
      }
    }
    if (book.kind == LocalBookKind.epub &&
        !book.fileUri.startsWith('file://')) {
      try {
        final cacheDir = await getApplicationCacheDirectory();
        final cached = File('${cacheDir.path}/local_epub/${book.id}.epub');
        if (await cached.exists()) {
          await cached.delete();
        }
      } catch (_) {
        ok = false;
      }
    }
    if (book.kind == LocalBookKind.comic &&
        !book.isDirectoryBackedComic &&
        !book.fileUri.startsWith('file://')) {
      try {
        final cacheDir = await getApplicationCacheDirectory();
        final cached = File('${cacheDir.path}/local_comic/${book.id}.cbz');
        if (await cached.exists()) {
          await cached.delete();
        }
      } catch (_) {
        ok = false;
      }
    }
    if (book.isComicSeries) {
      try {
        final cacheDir = await getApplicationCacheDirectory();
        final seriesDir = Directory('${cacheDir.path}/local_comic_series');
        if (await seriesDir.exists()) {
          final prefix = 'vol_${book.id}_';
          await for (final entity in seriesDir.list()) {
            if (entity is File &&
                entity.path.split(Platform.pathSeparator).last.startsWith(prefix)) {
              await entity.delete();
            }
          }
        }
      } catch (_) {
        /* Best-effort series volume cache cleanup. */
      }
    }
    try {
      final cacheDir = await getApplicationCacheDirectory();
      final coverDir = Directory('${cacheDir.path}/local_covers');
      if (await coverDir.exists()) {
        final prefix = 'cover_${book.id}_';
        await for (final entity in coverDir.list()) {
          if (entity is File &&
              entity.path.split('/').last.startsWith(prefix)) {
            await entity.delete();
          }
        }
      }
    } catch (_) {
      /* Cover cache cleanup is best-effort. */
    }
    return ok;
  }

  Future<String> _epubLocalPath({
    required int id,
    required String fileUri,
    required int size,
    required String sourceKey,
    required String sourceFingerprint,
  }) async {
    if (fileUri.startsWith('file://')) {
      if (sourceKey.isNotEmpty && File(sourceKey).isAbsolute) {
        return sourceKey;
      }
      final legacyPath = fileUri.substring('file://'.length);
      if (await File(legacyPath).exists()) return legacyPath;
      return Uri.parse(fileUri).toFilePath();
    }
    if (size > localEpubMaxSourceBytes) {
      throw const FormatException('EPUB 文件超过 1 GiB，无法导入');
    }
    final cacheFile = await _epubCacheFile(id);
    if (await cacheFile.exists() &&
        (size <= 0 || await cacheFile.length() == size) &&
        sourceFingerprint.isNotEmpty &&
        await _epubSourceFingerprint(cacheFile.path) == sourceFingerprint) {
      return cacheFile.path;
    }
    final staged = await _stageEpubCopy(fileUri, size, cacheFile.parent);
    try {
      if (sourceFingerprint.isNotEmpty &&
          await _epubSourceFingerprint(staged.path) != sourceFingerprint) {
        throw StateError('EPUB 源文件已变化，请重新扫描');
      }
      await staged.rename(cacheFile.path);
      return cacheFile.path;
    } finally {
      await staged.parent.delete(recursive: true);
    }
  }

  Future<File> _epubCacheFile(int id) async {
    final cacheRoot = await getApplicationCacheDirectory();
    final dir = Directory('${cacheRoot.path}/local_epub');
    await dir.create(recursive: true);
    return File('${dir.path}/$id.epub');
  }

  Future<File> _stageEpubCopy(String uri, int size, Directory cacheDir) async {
    if (size > localEpubMaxSourceBytes) {
      throw const FormatException('EPUB 文件超过 1 GiB，无法导入');
    }
    final stagingDir = await cacheDir.createTemp('import-');
    final staged = File('${stagingDir.path}/book.epub');
    try {
      await LocalPlatform.copyDocumentToFile(uri, staged.path);
      final actualLength = await staged.exists() ? await staged.length() : -1;
      if (actualLength <= 0 || (size > 0 && actualLength != size)) {
        throw StateError('EPUB 缓存长度不一致，请重新扫描');
      }
      return staged;
    } catch (_) {
      await stagingDir.delete(recursive: true);
      rethrow;
    }
  }

  /// 整本 sha256；按“路径 + 大小 + 修改时间”缓存，未变化时不重读文件。
  /// 文件被改写（大小或修改时间变化）时必然重算，调用方据此走“请重新扫描”。
  Future<String> _epubSourceFingerprint(String path) async {
    final file = File(path);
    final before = await file.stat();
    final cached = _epubFingerprintCache[path];
    final modified = before.modified.microsecondsSinceEpoch;
    if (cached != null &&
        before.type == FileSystemEntityType.file &&
        cached.size == before.size &&
        cached.modified == modified) {
      return cached.digest;
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final after = await file.stat();
    // 哈希期间文件被改写时不缓存，下次重算。
    if (before.type == FileSystemEntityType.file &&
        after.size == before.size &&
        after.modified.microsecondsSinceEpoch == modified) {
      _epubFingerprintCache[path] = (
        size: before.size,
        modified: modified,
        digest: digest,
      );
    } else {
      _epubFingerprintCache.remove(path);
    }
    return digest;
  }

  Future<LocalBook?> _importComicArchive({
    required String localPath,
    required String uri,
    required String name,
    required int size,
    required int modified,
    required String sourceId,
    required String sourceKey,
    bool isMangaSource = false,
    LocalBook? existing,
    int? id,
  }) async {
    if (size > localEpubMaxSourceBytes) {
      throw const FormatException('漫画压缩包超过 1 GiB，无法导入');
    }
    final bookId = id ?? existing?.id ?? _nextId();
    final pkg = await ComicArchivePackage.openFile(localPath);
    try {
      if (pkg.pageCount <= 0) return null;
      final meta = pkg.metadata;
      final parsedTitle = _titleFromName(name);
      final parsedAuthor = _authorFromName(name);
      final hasFilenameTags = parseFilenameTags(name).tags.isNotEmpty;
      final metaTitle = meta?.displayTitle;
      final metaWriter = meta?.writer;
      final title = (!hasFilenameTags &&
              metaTitle != null &&
              metaTitle.isNotEmpty)
          ? metaTitle
          : parsedTitle;
      final author = parsedAuthor.isNotEmpty
          ? parsedAuthor
          : (metaWriter != null && metaWriter.isNotEmpty ? metaWriter : '');
      final chapters = [
        for (final c in pkg.chapters)
          LocalChapterIndex(c.title, c.startPage, c.pageCount, volume: ''),
      ];
      return LocalBook(
        id: bookId,
        kind: LocalBookKind.comic,
        title: title,
        author: author,
        fileUri: uri,
        fileName: name,
        size: size,
        modified: modified,
        sourceId: sourceId,
        sourceKey: sourceKey,
        chapters: chapters,
        coverEntry: pkg.coverEntry,
        sourceFingerprint: await _epubSourceFingerprint(localPath),
        textFingerprint: '',
        wordCount: null,
        pageCount: pkg.pageCount,
        chapterSplitVersion: _chapterSplitVersion,
        isMangaSource: isMangaSource,
        isRtlProgression: pkg.isRtl ?? true,
        customTitle: existing?.customTitle,
        customAuthor: existing?.customAuthor,
      );
    } finally {
      await pkg.close();
    }
  }

  static String _computeFolderManifestFingerprint(ComicFolderManifest manifest) {
    final sb = StringBuffer();
    sb.write(manifest.folderRelPath);
    sb.write('\n');
    sb.write(manifest.comicInfoUri ?? '');
    sb.write('\n');
    for (final p in manifest.pages) {
      sb
        ..write(p.relPath)
        ..write('|')
        ..write(p.size)
        ..write('|')
        ..write(p.modifiedMs)
        ..write('\n');
    }
    return sha256.convert(utf8.encode(sb.toString())).toString();
  }

  Future<LocalBook?> _importComicFolder({
    required ComicFolderManifest manifest,
    required String sourceId,
    required String sourceKey,
    required String defaultFileUri,
    required String fingerprint,
    LocalBook? existing,
  }) async {
    if (manifest.pages.isEmpty) return null;
    final bookId = existing?.id ?? _nextId();
    var resolvedManifest = manifest;
    final infoUri = manifest.comicInfoUri;
    if (infoUri != null && infoUri.isNotEmpty) {
      try {
        final Uint8List infoBytes;
        if (infoUri.startsWith('content:')) {
          infoBytes = await LocalPlatform.readLocalBytes(infoUri);
        } else if (infoUri.startsWith('file:')) {
          infoBytes = await File.fromUri(Uri.parse(infoUri)).readAsBytes();
        } else {
          infoBytes = await File(infoUri).readAsBytes();
        }
        final xmlText = utf8.decode(infoBytes, allowMalformed: true);
        final parsed = ComicInfoMetadata.tryParseXml(xmlText);
        if (parsed != null) {
          resolvedManifest = applyMetadataToFolderManifest(manifest, parsed);
        }
      } catch (_) {
        /* Optional ComicInfo.xml parse failure never blocks folder import. */
      }
    }

    if (!await _booksDir.exists()) {
      await _booksDir.create(recursive: true);
    }
    final manifestFile = _comicManifestFile(bookId);
    final tmp = File('${manifestFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(resolvedManifest.toJson()), flush: true);
    await tmp.rename(manifestFile.path);
    _comicManifestCache[bookId] = resolvedManifest;

    final chapters = [
      for (final c in resolvedManifest.chapters)
        LocalChapterIndex(c.title, c.startPage, c.pageCount, volume: ''),
    ];
    final folderDisplayName = resolvedManifest.folderRelPath.isEmpty
        ? resolvedManifest.title
        : resolvedManifest.folderRelPath.split('/').last;
    return LocalBook(
      id: bookId,
      kind: LocalBookKind.comic,
      title: resolvedManifest.title,
      author: resolvedManifest.author,
      fileUri: resolvedManifest.folderUri.isNotEmpty
          ? resolvedManifest.folderUri
          : defaultFileUri,
      fileName: folderDisplayName,
      size: resolvedManifest.totalBytes,
      modified: resolvedManifest.latestModifiedMs,
      sourceId: sourceId,
      sourceKey: sourceKey,
      chapters: chapters,
      sourceFingerprint: fingerprint,
      textFingerprint: '',
      wordCount: null,
      pageCount: resolvedManifest.pages.length,
      chapterSplitVersion: _chapterSplitVersion,
      isComicFolder: true,
      isMangaSource: true,
      isRtlProgression: resolvedManifest.isRtl ?? true,
      customTitle: existing?.customTitle,
      customAuthor: existing?.customAuthor,
    );
  }

  static String _seriesSourceKeyFor(
    String sourceId,
    ComicSeriesCandidate candidate, {
    String? appRootPath,
  }) {
    final hashIdx = candidate.seriesKey.indexOf('#');
    final rawSuffix = hashIdx >= 0
        ? candidate.seriesKey.substring(hashIdx + 1)
        : candidate.seriesKey;
    if (appRootPath != null) {
      final safeRel = rawSuffix.replaceAll(':', '/');
      return '$appRootPath/.series/$safeRel';
    }
    return rawSuffix;
  }

  static String _computeSeriesCandidateFingerprint(
    ComicSeriesCandidate candidate,
  ) {
    final sb = StringBuffer()
      ..write(candidate.seriesKey)
      ..write('\n')
      ..write(candidate.title)
      ..write('\n')
      ..write(candidate.comicInfoUri ?? '')
      ..write('\n');
    for (final f in candidate.files) {
      sb
        ..write(f.relPath)
        ..write('|')
        ..write(f.uri)
        ..write('|')
        ..write(f.size)
        ..write('|')
        ..write(f.modifiedMs)
        ..write('\n');
    }
    return sha256.convert(utf8.encode(sb.toString())).toString();
  }

  Future<LocalBook?> _importComicSeries({
    required ComicSeriesCandidate candidate,
    required String sourceId,
    required String sourceKey,
    required String defaultFileUri,
    required String fingerprint,
    LocalBook? existing,
  }) async {
    if (candidate.files.isEmpty) return null;
    final bookId = existing?.id ?? _nextId();
    final oldManifest = existing != null
        ? await loadComicSeriesManifest(existing.id)
        : null;
    final oldByUri = <String, ComicSeriesVolumeEntry>{
      if (oldManifest != null)
        for (final v in oldManifest.volumes) v.uri: v,
    };

    final volumes = <ComicSeriesVolumeEntry>[];
    final chapters = <ComicChapterInfo>[];
    var runningStartPage = 0;
    ComicInfoMetadata? firstVolumeMeta;
    bool? firstVolumeIsRtl;

    for (final f in candidate.files) {
      final lower = f.name.toLowerCase();
      final volKind = lower.endsWith('.pdf')
          ? 'pdf'
          : lower.endsWith('.epub')
              ? 'epub'
              : 'cbz';
      final old = oldByUri[f.uri];
      if (old != null &&
          old.kind == volKind &&
          old.size == f.size &&
          old.modifiedMs == f.modifiedMs &&
          old.pageCount > 0 &&
          (volKind != 'epub' || old.epubPages.isNotEmpty)) {
        final reused = ComicSeriesVolumeEntry(
          uri: old.uri,
          name: old.name,
          relPath: f.relPath,
          kind: old.kind,
          size: old.size,
          modifiedMs: old.modifiedMs,
          startPage: runningStartPage,
          pageCount: old.pageCount,
          title: old.title,
          coverEntry: old.coverEntry,
          epubPages: old.epubPages,
        );
        volumes.add(reused);
        chapters.add(
          ComicChapterInfo(
            title: reused.displayTitle,
            startPage: runningStartPage,
            pageCount: reused.pageCount,
          ),
        );
        runningStartPage += reused.pageCount;
        continue;
      }

      if (volKind == 'pdf') {
        try {
          final pages = await LocalPlatform.pdfPageCount(f.uri);
          if (pages <= 0) continue;
          final volTitle = stripComicExtension(f.name);
          final entry = ComicSeriesVolumeEntry(
            uri: f.uri,
            name: f.name,
            relPath: f.relPath,
            kind: 'pdf',
            size: f.size,
            modifiedMs: f.modifiedMs,
            startPage: runningStartPage,
            pageCount: pages,
            title: volTitle,
          );
          volumes.add(entry);
          chapters.add(
            ComicChapterInfo(
              title: entry.displayTitle,
              startPage: runningStartPage,
              pageCount: pages,
            ),
          );
          runningStartPage += pages;
        } catch (_) {
          /* Skip unreadable volume without aborting entire series. */
        }
        continue;
      }

      if (f.size > localEpubMaxSourceBytes) continue;
      File? staged;
      try {
        final String localPath;
        if (f.uri.startsWith('content:')) {
          final cacheRoot = await getApplicationCacheDirectory();
          await cacheRoot.create(recursive: true);
          staged = await _stageEpubCopy(f.uri, f.size, cacheRoot);
          localPath = staged.path;
        } else if (f.uri.startsWith('file:')) {
          localPath = Uri.parse(f.uri).toFilePath();
        } else {
          localPath = f.uri;
        }

        if (volKind == 'cbz') {
          if (lower.endsWith('.zip') && !await isComicZipFile(localPath)) {
            continue;
          }
          final pkg = await ComicArchivePackage.openFile(localPath);
          try {
            if (pkg.pageCount <= 0) continue;
            firstVolumeMeta ??= pkg.metadata;
            firstVolumeIsRtl ??= pkg.isRtl;
            final volTitle = stripComicExtension(f.name);
            final entry = ComicSeriesVolumeEntry(
              uri: f.uri,
              name: f.name,
              relPath: f.relPath,
              kind: 'cbz',
              size: f.size,
              modifiedMs: f.modifiedMs,
              startPage: runningStartPage,
              pageCount: pkg.pageCount,
              title: volTitle,
              coverEntry: pkg.coverEntry,
            );
            volumes.add(entry);
            chapters.add(
              ComicChapterInfo(
                title: entry.displayTitle,
                startPage: runningStartPage,
                pageCount: pkg.pageCount,
              ),
            );
            runningStartPage += pkg.pageCount;
          } finally {
            await pkg.close();
          }
        } else {
          final epub = await EpubPackage.open(localPath, lenient: true);
          try {
            final extracted = await epub.extractMangaPages();
            if (extracted.pages.isEmpty) continue;
            firstVolumeIsRtl ??= epub.isRtlProgression;
            final volTitle = stripComicExtension(f.name);
            final entry = ComicSeriesVolumeEntry(
              uri: f.uri,
              name: f.name,
              relPath: f.relPath,
              kind: 'epub',
              size: f.size,
              modifiedMs: f.modifiedMs,
              startPage: runningStartPage,
              pageCount: extracted.pages.length,
              title: volTitle,
              coverEntry: epub.coverEntry ?? extracted.pages.first,
              epubPages: extracted.pages,
            );
            volumes.add(entry);
            chapters.add(
              ComicChapterInfo(
                title: entry.displayTitle,
                startPage: runningStartPage,
                pageCount: extracted.pages.length,
              ),
            );
            runningStartPage += extracted.pages.length;
          } finally {
            await epub.close();
          }
        }
      } catch (_) {
        /* Skip unreadable volume without aborting entire series. */
      } finally {
        if (staged != null) {
          try {
            await staged.parent.delete(recursive: true);
          } catch (_) {}
        }
      }
    }

    if (volumes.isEmpty || runningStartPage <= 0) return null;

    var resolvedManifest = ComicSeriesManifest(
      seriesKey: candidate.seriesKey,
      folderUri: candidate.folderUri,
      folderRelPath: candidate.folderRelPath,
      comicInfoUri: candidate.comicInfoUri,
      title: candidate.title,
      author: '本地多卷漫画',
      summary: '',
      isRtl: firstVolumeIsRtl,
      volumes: List<ComicSeriesVolumeEntry>.unmodifiable(volumes),
      chapters: List<ComicChapterInfo>.unmodifiable(chapters),
    );

    final infoUri = candidate.comicInfoUri;
    if (infoUri != null && infoUri.isNotEmpty) {
      try {
        final Uint8List infoBytes;
        if (infoUri.startsWith('content:')) {
          infoBytes = await LocalPlatform.readLocalBytes(infoUri);
        } else if (infoUri.startsWith('file:')) {
          infoBytes = await File.fromUri(Uri.parse(infoUri)).readAsBytes();
        } else {
          infoBytes = await File(infoUri).readAsBytes();
        }
        final xmlText = utf8.decode(infoBytes, allowMalformed: true);
        final parsed = ComicInfoMetadata.tryParseXml(xmlText);
        if (parsed != null) {
          resolvedManifest = applyMetadataToSeriesManifest(
            resolvedManifest,
            parsed,
            preferFolderTitle: true,
          );
        }
      } catch (_) {}
    } else if (firstVolumeMeta != null) {
      resolvedManifest = applyMetadataToSeriesManifest(
        resolvedManifest,
        firstVolumeMeta,
        preferFolderTitle: true,
      );
    }

    if (!await _booksDir.exists()) {
      await _booksDir.create(recursive: true);
    }
    final manifestFile = _comicSeriesManifestFile(bookId);
    final tmp = File('${manifestFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(resolvedManifest.toJson()), flush: true);
    await tmp.rename(manifestFile.path);
    _comicSeriesCache[bookId] = resolvedManifest;

    final localChapters = [
      for (final c in resolvedManifest.chapters)
        LocalChapterIndex(c.title, c.startPage, c.pageCount, volume: ''),
    ];
    final folderDisplayName = resolvedManifest.folderRelPath.isEmpty
        ? resolvedManifest.title
        : resolvedManifest.folderRelPath.split('/').last;
    return LocalBook(
      id: bookId,
      kind: LocalBookKind.comic,
      title: resolvedManifest.title,
      author: resolvedManifest.author,
      fileUri: resolvedManifest.folderUri.isNotEmpty
          ? resolvedManifest.folderUri
          : defaultFileUri,
      fileName: folderDisplayName,
      size: resolvedManifest.totalBytes,
      modified: resolvedManifest.latestModifiedMs,
      sourceId: sourceId,
      sourceKey: sourceKey,
      chapters: localChapters,
      sourceFingerprint: fingerprint,
      textFingerprint: '',
      wordCount: null,
      pageCount: resolvedManifest.pageCount,
      chapterSplitVersion: _chapterSplitVersion,
      isComicSeries: true,
      isMangaSource: true,
      isRtlProgression: resolvedManifest.isRtl ?? true,
      customTitle: existing?.customTitle,
      customAuthor: existing?.customAuthor,
    );
  }

  Future<LocalBook?> _importEpub({
    required String localPath,
    required String uri,
    required String name,
    required int size,
    required int modified,
    required String sourceId,
    required String sourceKey,
    bool isMangaSource = false,
    LocalBook? existing,
    int? id,
  }) async {
    if (size > localEpubMaxSourceBytes) {
      throw const FormatException('EPUB 文件超过 1 GiB，无法导入');
    }
    final bookId = id ?? existing?.id ?? _nextId();
    final epub = await EpubPackage.open(localPath, lenient: true);
    try {
      final spine = epub.chapters;
      if (spine.isEmpty) return null;
      var isComic = epub.isComicLayout;
      if (!isComic && isMangaSource) {
        try {
          final extracted = await epub.extractMangaPages();
          if (extracted.pages.length >= 2) {
            isComic = true;
          }
        } catch (_) {}
      }
      final chapters = [
        for (final c in spine) LocalChapterIndex(c.title, 0, 0, volume: ''),
      ];
      final hrefs = [for (final c in spine) c.href];
      return LocalBook(
        id: bookId,
        kind: LocalBookKind.epub,
        title: _titleFromName(name),
        author: _authorFromName(name),
        fileUri: uri,
        fileName: name,
        size: size,
        modified: modified,
        sourceId: sourceId,
        sourceKey: sourceKey,
        chapters: chapters,
        epubChapterHrefs: hrefs,
        coverEntry: epub.coverEntry,
        sourceFingerprint: await _epubSourceFingerprint(localPath),
        textFingerprint: '',
        wordCount: null,
        pageCount: 0,
        chapterSplitVersion: _chapterSplitVersion,
        isComicEpub: isComic,
        isMangaSource: isComic && isMangaSource,
        isRtlProgression: epub.isRtlProgression,
        customTitle: existing?.customTitle,
        customAuthor: existing?.customAuthor,
      );
    } finally {
      await epub.close();
    }
  }

  /// 当扩展名为 `.epub` 的文件实际是改了后缀名的 `.mobi`、`.pdf` 或纯文本 `.txt` 时，
  /// 自动按真实格式回退导入，避免网文资源因扩展名不符报错。
  Future<LocalBook?> _tryImportMisnamedEpubFile({
    required String localPath,
    required String uri,
    required String name,
    required int size,
    required int modified,
    required String sourceId,
    required String sourceKey,
    required int id,
    bool isMangaSource = false,
    LocalBook? existing,
  }) async {
    try {
      final file = File(localPath);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size < 4 ||
          stat.size > localTextMaxSourceBytes) {
        return null;
      }
      final head = await file.openRead(0, 4096).fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      if (head.length < 4) return null;
      // 排除 ZIP / RAR / 7z 等二进制归档头。
      if ((head[0] == 0x50 && head[1] == 0x4B) ||
          (head[0] == 0x52 &&
              head[1] == 0x61 &&
              head[2] == 0x72 &&
              head[3] == 0x21) ||
          (head.length >= 6 &&
              head[0] == 0x37 &&
              head[1] == 0x7A &&
              head[2] == 0xBC &&
              head[3] == 0xAF)) {
        return null;
      }
      // 改了 .epub 后缀名的 PDF 文件。
      if (head[0] == 0x25 &&
          head[1] == 0x50 &&
          head[2] == 0x44 &&
          head[3] == 0x46) {
        final pages = await LocalPlatform.pdfPageCount(uri);
        if (pages <= 0) return null;
        return LocalBook(
          id: id,
          title: _titleFromName(name),
          author: _authorFromName(name),
          fileUri: uri,
          fileName: name,
          kind: LocalBookKind.pdf,
          size: size,
          modified: modified,
          textFingerprint: '',
          sourceFingerprint: existing?.sourceFingerprint ?? '',
          chapters: const [],
          pageCount: pages,
          wordCount: null,
          sourceId: sourceId,
          sourceKey: sourceKey,
          isMangaSource: isMangaSource,
          customTitle: existing?.customTitle,
          customAuthor: existing?.customAuthor,
          chapterSplitVersion: _chapterSplitVersion,
        );
      }
      if (head.length >= 68) {
        final magic = ascii.decode(head.sublist(60, 68), allowInvalid: true);
        if (magic == 'BOOKMOBI' || magic == 'TEXtREAd') {
          final rawBytes = await file.readAsBytes();
          final mobi = extractMobiBook(
            rawBytes,
            fallbackTitle: _titleFromName(name),
          );
          if (mobi.text.isEmpty) return null;
          final sourceFingerprint = sha256.convert(rawBytes).toString();
          final textFingerprint = sha256
              .convert(utf8.encode(mobi.text))
              .toString();
          final target = '${_booksDir.path}/book_${id}_$textFingerprint.txt';
          await File(target).writeAsString(mobi.text, flush: true);
          return LocalBook(
            id: id,
            title: mobi.title.isNotEmpty ? mobi.title : _titleFromName(name),
            author: mobi.author.isNotEmpty
                ? mobi.author
                : _authorFromName(name),
            fileUri: uri,
            fileName: name,
            kind: LocalBookKind.txt,
            size: size,
            modified: modified,
            textFingerprint: textFingerprint,
            sourceFingerprint: sourceFingerprint,
            chapters: mobi.chapters,
            isMobiSource: true,
            pageCount: 0,
            wordCount: _countWords(mobi.text),
            sourceId: sourceId,
            sourceKey: sourceKey,
            customTitle: existing?.customTitle,
            customAuthor: existing?.customAuthor,
            chapterSplitVersion: _chapterSplitVersion,
          );
        }
      }
      final hasUtf16Bom =
          (head[0] == 0xFF && head[1] == 0xFE) ||
          (head[0] == 0xFE && head[1] == 0xFF);
      final nulCount = head.where((b) => b == 0).length;
      var evenNul = 0;
      var oddNul = 0;
      for (var i = 0; i < head.length; i++) {
        if (head[i] == 0) {
          if (i.isEven) {
            evenNul++;
          } else {
            oddNul++;
          }
        }
      }
      final likelyUtf16NoBom =
          (evenNul == 0 && oddNul > head.length ~/ 10) ||
          (oddNul == 0 && evenNul > head.length ~/ 10);
      if (!hasUtf16Bom && !likelyUtf16NoBom && nulCount > head.length ~/ 20) {
        return null;
      }
      final processed = await _importText(localPath, id, direct: true);
      if (processed.inputLength == 0) return null;
      return LocalBook(
        id: id,
        title: _titleFromName(name),
        author: _authorFromName(name),
        fileUri: uri,
        fileName: name,
        kind: LocalBookKind.txt,
        size: size,
        modified: modified,
        textFingerprint: processed.fingerprint,
        sourceFingerprint: processed.sourceFingerprint,
        chapters: processed.chapters,
        pageCount: 0,
        wordCount: processed.wordCount,
        sourceId: sourceId,
        sourceKey: sourceKey,
        customTitle: existing?.customTitle,
        customAuthor: existing?.customAuthor,
        chapterSplitVersion: _activeChapterSplitVersion,
      );
    } catch (_) {
      return null;
    }
  }

  Future<LocalBook?> _importEntry({
    required Map<String, File?> epubCacheBackups,
    required String uri,
    required String name,
    required int size,
    required int modified,
    required String sourceId,
    required String sourceKey,
    bool isMangaSource = false,
    LocalBook? existing,
  }) async {
    final isZipCandidate = isZipFileName(name);
    final kind = localBookKindForFileName(name) ??
        (isZipCandidate ? LocalBookKind.comic : LocalBookKind.txt);
    // 刷新时保留原 ID，避免书架/进度失效（修复#3）。
    final id = existing?.id ?? _nextId();
    final title = _titleFromName(name);
    final author = _authorFromName(name);
    if (kind == LocalBookKind.comic) {
      if (size > localEpubMaxSourceBytes) {
        throw const FormatException('漫画压缩包超过 1 GiB，无法导入');
      }
      final cacheFile = await _comicCacheFile(id);
      final staged = await _stageEpubCopy(uri, size, cacheFile.parent);
      try {
        if (isZipCandidate && !await isComicZipFile(staged.path)) {
          throw const _NonComicZipSkipException();
        }
        final book = await _importComicArchive(
          localPath: staged.path,
          uri: uri,
          name: name,
          size: size,
          modified: modified,
          sourceId: sourceId,
          sourceKey: sourceKey,
          isMangaSource: isMangaSource,
          existing: existing,
          id: id,
        );
        if (book != null) {
          if (!epubCacheBackups.containsKey(cacheFile.path)) {
            File? backup;
            if (await cacheFile.exists()) {
              final backupDir = await cacheFile.parent.createTemp('rollback-');
              try {
                backup = await cacheFile.copy('${backupDir.path}/book.cbz');
              } catch (_) {
                await backupDir.delete(recursive: true);
                rethrow;
              }
            }
            epubCacheBackups[cacheFile.path] = backup;
          }
          await staged.rename(cacheFile.path);
        }
        return book;
      } finally {
        await staged.parent.delete(recursive: true);
      }
    }
    if (kind == LocalBookKind.epub) {
      if (size > localEpubMaxSourceBytes) {
        throw const FormatException('EPUB 文件超过 1 GiB，无法导入');
      }
      final cacheFile = await _epubCacheFile(id);
      final staged = await _stageEpubCopy(uri, size, cacheFile.parent);
      try {
        LocalBook? book;
        try {
          book = await _importEpub(
            localPath: staged.path,
            uri: uri,
            name: name,
            size: size,
            modified: modified,
            sourceId: sourceId,
            sourceKey: sourceKey,
            isMangaSource: isMangaSource,
            existing: existing,
            id: id,
          );
        } on StateError {
          final fallback = await _tryImportMisnamedEpubFile(
            localPath: staged.path,
            uri: uri,
            name: name,
            size: size,
            modified: modified,
            sourceId: sourceId,
            sourceKey: sourceKey,
            isMangaSource: isMangaSource,
            id: id,
            existing: existing,
          );
          if (fallback != null) return fallback;
          rethrow;
        }
        if (book != null) {
          if (!epubCacheBackups.containsKey(cacheFile.path)) {
            File? backup;
            if (await cacheFile.exists()) {
              final backupDir = await cacheFile.parent.createTemp('rollback-');
              try {
                backup = await cacheFile.copy('${backupDir.path}/book.epub');
              } catch (_) {
                await backupDir.delete(recursive: true);
                rethrow;
              }
            }
            epubCacheBackups[cacheFile.path] = backup;
          }
          await staged.rename(cacheFile.path);
        }
        return book;
      } finally {
        await staged.parent.delete(recursive: true);
      }
    }
    if (kind == LocalBookKind.pdf) {
      final pages = await LocalPlatform.pdfPageCount(uri);
      if (pages <= 0) return null;
      return LocalBook(
        id: id,
        title: title,
        author: author,
        fileUri: uri,
        fileName: name,
        kind: kind,
        size: size,
        modified: modified,
        chapters: const [],
        pageCount: pages,
        sourceId: sourceId,
        sourceKey: sourceKey,
        isMangaSource: isMangaSource,
        customTitle: existing?.customTitle,
        customAuthor: existing?.customAuthor,
        chapterSplitVersion: _chapterSplitVersion,
      );
    }
    if (size > localTextMaxSourceBytes) {
      throw const FormatException('TXT 文件过大：超过 256 MiB 导入上限');
    }
    if (isMobiFileName(name)) {
      final cacheFile = await _epubCacheFile(id);
      final staged = await _stageEpubCopy(uri, size, cacheFile.parent);
      try {
        final rawBytes = await staged.readAsBytes();
        final mobi = extractMobiBook(rawBytes, fallbackTitle: title);
        if (mobi.text.isEmpty) return null;
        final sourceFingerprint = sha256.convert(rawBytes).toString();
        final textFingerprint = sha256
            .convert(utf8.encode(mobi.text))
            .toString();
        final target = '${_booksDir.path}/book_${id}_$textFingerprint.txt';
        await File(target).writeAsString(mobi.text, flush: true);
        return LocalBook(
          id: id,
          title: mobi.title.isNotEmpty ? mobi.title : title,
          author: mobi.author.isNotEmpty ? mobi.author : author,
          fileUri: uri,
          fileName: name,
          kind: LocalBookKind.txt,
          size: size,
          modified: modified,
          textFingerprint: textFingerprint,
          sourceFingerprint: sourceFingerprint,
          chapters: mobi.chapters,
          pageCount: 0,
          wordCount: _countWords(mobi.text),
          sourceId: sourceId,
          sourceKey: sourceKey,
          customTitle: existing?.customTitle,
          customAuthor: existing?.customAuthor,
          chapterSplitVersion: _chapterSplitVersion,
        );
      } finally {
        await staged.parent.delete(recursive: true);
      }
    }
    final processed = await _importText(uri, id);
    if (processed.inputLength == 0) return null;
    var chapters = processed.chapters;
    if (existing != null && existing.hasCustomChapterSplit) {
      final customChapters = await _textWorker.splitCustom(
        '${_booksDir.path}/book_${id}_${processed.fingerprint}.txt',
        customPattern: existing.customTocPattern,
        maxChapterChars: existing.customMaxChapterChars,
        enableChapterExtensions:
            _activeChapterSplitVersion == _extendedChapterSplitVersion,
      );
      if (customChapters.isNotEmpty) {
        chapters = customChapters;
      }
    }
    return LocalBook(
      id: id,
      title: title,
      author: author,
      fileUri: uri,
      fileName: name,
      kind: kind,
      size: size,
      modified: modified,
      textFingerprint: processed.fingerprint,
      sourceFingerprint: processed.sourceFingerprint,
      chapters: chapters,
      pageCount: 0,
      wordCount: processed.wordCount,
      sourceId: sourceId,
      sourceKey: sourceKey,
      customTitle: existing?.customTitle,
      customAuthor: existing?.customAuthor,
      chapterSplitVersion: _activeChapterSplitVersion,
      customTocPattern: existing?.customTocPattern,
      customMaxChapterChars: existing?.customMaxChapterChars ?? 0,
    );
  }

  static String _titleFromName(String name) {
    var title = stripFilenameTags(name);
    final dot = title.lastIndexOf('.');
    if (dot > 0) title = title.substring(0, dot);
    final dash = title.lastIndexOf(' - ');
    if (dash > 0) title = title.substring(0, dash);
    title = title.trim();
    return title.isEmpty ? name : title;
  }

  static String _authorFromName(String name) {
    var base = stripFilenameTags(name);
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    final dash = base.lastIndexOf(' - ');
    if (dash > 0) {
      final author = base.substring(dash + 3).trim();
      if (author.isNotEmpty && author.length <= 24) return author;
    }
    return '';
  }

  /// 章节切分：标题行做章节名，正文从标题行下一行开始。
  static List<LocalChapterIndex> _splitChapters(String text) =>
      splitLocalChapters(text);

  @visibleForTesting
  static List<LocalChapterIndex> splitChaptersForTest(String text) =>
      _splitChapters(text);

  @visibleForTesting
  int chapterSplitVersionForTest(LocalBook book) => _chapterSplitVersionFor(book);

  @visibleForTesting
  static String titleFromNameForTest(String name) => _titleFromName(name);

  @visibleForTesting
  static String authorFromNameForTest(String name) => _authorFromName(name);

  Future<bool> _sourceHasFingerprint(LocalBook book, String expected) async {
    final direct =
        book.sourceId == 'appFolder:novels' ||
        book.sourceId == 'cloud:imported';
    final actual = direct
        ? (book.kind == LocalBookKind.txt
              ? await _textWorker.fingerprint(book.sourceKey)
              : await _streamFileSha256(File(book.sourceKey)))
        : await LocalPlatform.fingerprintLocalText(book.fileUri);
    return actual == expected;
  }

  Future<Novel> importCloudFile(
    String name,
    String path, {
    String? decodedText,
  }) => _synchronized(() async {
    final dir = Directory('${_booksDir.path}/cloud_originals');
    if (!await dir.exists()) await dir.create(recursive: true);
    var effectiveName = name.trim().isEmpty ? '未命名书籍.txt' : name.trim();
    var bytes = await File(path).readAsBytes();
    final kind = localBookKindForFileName(effectiveName);
    if (kind == LocalBookKind.comic) {
      checkComicArchiveMagicBytes(bytes);
    }
    if (kind == null && !isMobiFileName(effectiveName)) {
      final prepared = await PortableBookPreparer.prepareFile(
        effectiveName,
        path,
      );
      if (prepared.isEmpty) {
        throw const FormatException('未识别到可导入的书籍内容');
      }
      final doc = prepared.first;
      if (doc.cbzBytes != null) {
        effectiveName =
            '${effectiveName.replaceFirst(RegExp(r'\.[^.]+$'), '')}.cbz';
        bytes = doc.cbzBytes!;
      } else if (doc.epubBytes != null) {
        effectiveName =
            '${effectiveName.replaceFirst(RegExp(r'\.[^.]+$'), '')}.epub';
        bytes = doc.epubBytes!;
      } else if (doc.pdfBytes != null) {
        effectiveName =
            '${effectiveName.replaceFirst(RegExp(r'\.[^.]+$'), '')}.pdf';
        bytes = doc.pdfBytes!;
      } else {
        effectiveName =
            '${effectiveName.replaceFirst(RegExp(r'\.[^.]+$'), '')}.txt';
        bytes =
            doc.rawTextBytes ?? Uint8List.fromList(utf8.encode(doc.text ?? ''));
      }
    } else if (kind == LocalBookKind.txt &&
        decodedText != null &&
        decodedText.isNotEmpty) {
      bytes = Uint8List.fromList(utf8.encode(decodedText));
    }
    final safeName = effectiveName.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    final digest = sha256.convert(bytes).toString().substring(0, 16);
    final stored = File('${dir.path}/${digest}_$safeName');
    await stored.writeAsBytes(bytes, flush: true);
    const sourceId = 'cloud:imported';
    final sourceKey = stored.path;
    final existing = _books
        .where((b) => b.sourceId == sourceId && b.sourceKey == sourceKey)
        .firstOrNull;
    if (existing == null) {
      await _reserveIds(1);
    }
    final stat = await stored.stat();
    final book = await _importDirectFile(
      path: stored.path,
      name: effectiveName,
      size: stat.size,
      modified: stat.modified.millisecondsSinceEpoch,
      sourceId: sourceId,
      sourceKey: sourceKey,
      existing: existing,
    );
    if (book == null) throw const FormatException('书籍内容为空');
    if (existing != null) {
      final idx = _indexForBook(existing.id);
      if (idx >= 0) _replaceBook(idx, book);
    } else {
      _addBook(book);
    }
    await _saveIndex();
    return toNovel(book);
  });

  Future<({int imported, int failed})> importCloudBatch(
    String name,
    String path,
  ) async {
    if (!name.toLowerCase().endsWith('.zip')) {
      await importCloudFile(name, path);
      return (imported: 1, failed: 0);
    }
    if (await isComicZipFile(path)) {
      final stem = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      await importCloudFile('$stem.cbz', path);
      return (imported: 1, failed: 0);
    }
    final prepared = await PortableBookPreparer.prepareFile(name, path);
    if (prepared.isEmpty) return (imported: 0, failed: 1);
    final tempDir = await Directory.systemTemp.createTemp('wenku8_cloud_zip_');
    var imported = 0;
    var failed = 0;
    try {
      for (final (i, doc) in prepared.indexed) {
        final ext = doc.cbzBytes != null
            ? '.cbz'
            : doc.epubBytes != null
                ? '.epub'
                : doc.pdfBytes != null
                    ? '.pdf'
                    : '.txt';
        final entryName = doc.name.toLowerCase().endsWith(ext)
            ? doc.name
            : '${doc.name.replaceFirst(RegExp(r'\.[^.]+$'), '')}$ext';
        final tempFile = File('${tempDir.path}/item_$i$ext');
        final bytes =
            doc.cbzBytes ??
            doc.epubBytes ??
            doc.pdfBytes ??
            doc.rawTextBytes ??
            Uint8List.fromList(utf8.encode(doc.text ?? ''));
        await tempFile.writeAsBytes(bytes, flush: true);
        try {
          await importCloudFile(entryName, tempFile.path);
          imported++;
        } catch (_) {
          failed++;
        }
      }
    } finally {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
    return (imported: imported, failed: failed);
  }

  Future<({String name, Uint8List bytes, String? text})?> exportSyncOriginal(
    int id,
  ) async {
    final book = bookFor(id);
    if (book == null) return null;
    if (book.fileUri.startsWith('file://')) {
      final file = _sourceFile(book);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        String? text;
        if (book.kind == LocalBookKind.txt) {
          final textFile = File(textPathFor(book));
          if (await textFile.exists()) {
            text = await textFile.readAsString();
          }
        }
        return (name: book.fileName, bytes: bytes, text: text);
      }
    }
    if (book.kind == LocalBookKind.txt) {
      final textFile = File(textPathFor(book));
      if (await textFile.exists()) {
        final text = await textFile.readAsString();
        final bytes = Uint8List.fromList(utf8.encode(text));
        return (
          name: book.fileName.isNotEmpty
              ? book.fileName
              : '${book.displayTitle}.txt',
          bytes: bytes,
          text: text,
        );
      }
    }
    return null;
  }

  Future<_TextMetadata> _importText(
    String source,
    int id, {
    bool direct = false,
  }) async {
    String? temporary;
    try {
      var path = source;
      String? sourceFingerprint;
      if (!direct || LocalPlatform.android) {
        final prepared = await LocalPlatform.prepareLocalTextSource(
          direct ? Uri.file(source).toString() : source,
        );
        path = temporary = prepared.path;
        sourceFingerprint = prepared.fingerprint;
      }
      final result = await _textWorker.analyze(
        path,
        outputPath: '${_booksDir.path}/book_$id.staging',
        normalize: true,
        maxBytes: temporary == null
            ? localTextMaxSourceBytes
            : localTextMaxDecodedBytes,
        preserveBom: temporary != null,
        sourceFingerprint: sourceFingerprint,
      );
      if (result.length == 0) {
        throw const FormatException('TXT 文件为空');
      }
      if (result.inputLength > 0) {
        final staged = File('${_booksDir.path}/book_$id.staging');
        final target = '${_booksDir.path}/book_${id}_${result.fingerprint}.txt';
        if (!await File(target).exists()) {
          await staged.rename(target);
        } else {
          await staged.delete();
        }
      }
      return result;
    } on FormatException catch (error) {
      if (error.message.startsWith('TXT ')) rethrow;
      throw const FormatException('TXT 解码失败');
    } finally {
      if (temporary != null) {
        try {
          await File(temporary).delete();
        } catch (_) {
          /* Cache cleanup is best effort. */
        }
      }
    }
  }

  Future<void> _preserveCachedSnapshot(LocalBook book) async {
    final cached = _textCache[book.id];
    if (cached == null) return;
    final file = File(textPathFor(book));
    if (!await file.exists()) await file.writeAsString(cached, flush: true);
  }

  String textPathFor(LocalBook book) => book.textFingerprint.isEmpty
      ? '${_booksDir.path}/book_${book.id}.txt'
      : '${_booksDir.path}/book_${book.id}_${book.textFingerprint}.txt';

  Future<({String path, bool recovered})> _ensureBookTextPath(
    LocalBook book,
  ) async {
    final file = File(textPathFor(book));
    if (await file.exists()) return (path: file.path, recovered: false);
    final direct =
        book.sourceId == 'appFolder:novels' ||
        book.sourceId == 'cloud:imported';
    final result = await _importText(
      direct ? book.sourceKey : book.fileUri,
      book.id,
      direct: direct,
    );
    if (book.textFingerprint.isNotEmpty &&
        result.fingerprint != book.textFingerprint) {
      throw StateError('源文件内容已变化，请重新扫描：${book.displayTitle}');
    }
    final path = '${_booksDir.path}/book_${book.id}_${result.fingerprint}.txt';
    if (book.textFingerprint.isEmpty) await File(path).copy(file.path);
    return (path: file.path, recovered: true);
  }

  Future<String> _readBookText(LocalBook book) {
    final cached = _textCache.remove(book.id);
    if (cached != null) {
      _textCache[book.id] = cached;
      return Future.value(cached);
    }
    final pending = _textReads[book.id];
    if (pending != null) return pending;
    late final Future<String> future;
    future =
        (() async {
          final path = await _readableTextPath(book);
          final text = await _readerWorker.read(path, preserveBom: true);
          if (identical(_textReads[book.id], future)) {
            if (bookFor(book.id)?.revision == book.revision &&
                bookFor(book.id)?.textFingerprint == book.textFingerprint) {
              _cacheText(book.id, text);
            }
          }
          return text;
        })().whenComplete(() {
          if (identical(_textReads[book.id], future)) {
            _textReads.remove(book.id);
          }
        });
    _textReads[book.id] = future;
    return future;
  }

  Future<String> _readableTextPath(LocalBook book) async {
    final path = textPathFor(book);
    if (await File(path).exists()) return path;
    return _synchronized(
      () async {
        if (bookFor(book.id)?.revision != book.revision) {
          throw const StaleLocalChapterException();
        }
        return (await _ensureBookTextPath(book)).path;
      },
      timeout: _operationTimeout,
      operation: '正文恢复',
    );
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    _updateScanProgress(bumpRevision: true);
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _liveStores.remove(this);
    // Finish queued file operations before releasing the worker and cache.
    _mutationLock.then((_) {
      _textWorker.dispose();
      _readerWorker.dispose();
      _textCache.clear();
      _textCacheBytes = 0;
      _chapterSliceCache.clear();
      _chapterSliceCacheBytes = 0;
      _clearEpubCaches();
    });
    super.dispose();
  }

  final _refreshErrors = <int, String>{};

  /// 章节切分规则升级或旧数据缺字数时，一次读取并处理正文，复用结果。
  Future<({
    bool wordCountBackfilled,
    bool chaptersRefreshed,
    bool failed,
    bool sourceUnavailable,
  })>
  _refreshBookIfNeeded(
    LocalBook existing, {
    required List<LocalChapterRemap> chapterRemaps,
    required Map<int, LocalBook> chapterUpdates,
    required bool chaptersStale,
  }) async {
    final needsWordCount =
        existing.kind == LocalBookKind.txt && existing.wordCount == null;
    if (!needsWordCount && !chaptersStale) {
      return (
        wordCountBackfilled: false,
        chaptersRefreshed: false,
        failed: false,
        sourceUnavailable: false,
      );
    }
    final index = _indexForBook(existing.id);
    if (index < 0) {
      return (
        wordCountBackfilled: false,
        chaptersRefreshed: false,
        failed: true,
        sourceUnavailable: false,
      );
    }
    if (existing.kind == LocalBookKind.pdf ||
        existing.kind == LocalBookKind.comic) {
      _replaceBook(
        index,
        existing.copyWith(
          chapterSplitVersion: _chapterSplitVersion,
          customTitle: existing.customTitle,
          customAuthor: existing.customAuthor,
        ),
      );
      return (
        wordCountBackfilled: false,
        chaptersRefreshed: false,
        failed: false,
        sourceUnavailable: false,
      );
    }
    var readingSource = true;
    try {
      final current = _books[index];
      final source = await _ensureBookTextPath(current);
      final processed = await _textWorker.analyze(
        source.path,
        enableChapterExtensions:
            _chapterSplitVersionFor(current) == _extendedChapterSplitVersion,
        normalize: true,
        outputPath: '${_booksDir.path}/book_${current.id}.upgrading',
      );
      readingSource = false;
      final upgrading = File('${_booksDir.path}/book_${current.id}.upgrading');
      if (processed.inputLength == 0) {
        if (await upgrading.exists()) await upgrading.delete();
        return (
          wordCountBackfilled: false,
          chaptersRefreshed: false,
          failed: true,
          sourceUnavailable: false,
        );
      }
      final normalized = File(
        '${_booksDir.path}/book_${current.id}_${processed.fingerprint}.txt',
      );
      if (!await normalized.exists()) {
        await upgrading.rename(normalized.path);
      } else if (await upgrading.exists()) {
        await upgrading.delete();
      }
      final canSplit = chaptersStale && processed.length > 0;
      var candidateChapters = processed.chapters;
      if (canSplit && current.hasCustomChapterSplit) {
        final customChapters = await _textWorker.splitCustom(
          normalized.path,
          customPattern: current.customTocPattern,
          maxChapterChars: current.customMaxChapterChars,
          enableChapterExtensions:
              _chapterSplitVersionFor(current) == _extendedChapterSplitVersion,
        );
        if (customChapters.isNotEmpty) {
          candidateChapters = customChapters;
        }
      }
      final old = current.chapters;
      var chaptersChanged = false;
      if (canSplit) {
        if (candidateChapters.length != old.length) {
          chaptersChanged = true;
        } else {
          for (var i = 0; i < old.length; i++) {
            if (candidateChapters[i].title != old[i].title ||
                candidateChapters[i].offset != old[i].offset ||
                candidateChapters[i].length != old[i].length ||
                candidateChapters[i].volume != old[i].volume) {
              chaptersChanged = true;
              break;
            }
          }
        }
      }
      final updated = current.copyWith(
        wordCount: processed.wordCount,
        textFingerprint: processed.fingerprint,
        chapters: chaptersChanged ? candidateChapters : current.chapters,
        chapterSplitVersion: canSplit
            ? _chapterSplitVersionFor(current)
            : current.chapterSplitVersion,
        customTitle: current.customTitle,
        customAuthor: current.customAuthor,
      );
      if (chaptersChanged || current.revision != updated.revision) {
        chapterRemaps.add(_remapFor(current, updated));
        // Candidate tables stay private until the whole remap journal commits.
        chapterUpdates[current.id] = updated;
      } else {
        _replaceBook(index, updated);
      }
      return (
        wordCountBackfilled: needsWordCount,
        chaptersRefreshed: chaptersChanged,
        failed: false,
        sourceUnavailable: false,
      );
    } catch (error) {
      _refreshErrors[existing.id] = describeSafeError(
        error,
        fallback: '本地文件刷新失败',
      );
      return (
        wordCountBackfilled: false,
        chaptersRefreshed: false,
        failed: true,
        sourceUnavailable: readingSource &&
            (error is MissingPluginException ||
                (error is FileSystemException &&
                    (error.path == textPathFor(existing) ||
                        error.path == existing.sourceKey)) ||
                error is _TextSourceException ||
                error is TextWorkerUnavailable),
      );
    }
  }

  Novel toNovel(LocalBook book) {
    final cached = _bookNovelCache[book];
    if (cached != null) return cached;
    final kindLabel = book.kind == LocalBookKind.pdf
        ? (book.isIntrinsicManga ? '漫画 · PDF' : 'PDF')
        : book.kind == LocalBookKind.epub
            ? (book.isIntrinsicManga ? '漫画 · EPUB' : 'EPUB')
            : book.kind == LocalBookKind.comic
                ? '漫画'
                : 'TXT';
    final countLabel = book.kind == LocalBookKind.pdf
        ? '${book.pageCount} 页'
        : book.kind == LocalBookKind.comic
            ? (book.isComicSeries
                ? '${book.chapters.length} 卷 · ${book.pageCount} 页'
                : book.chapters.length > 1
                    ? '${book.chapters.length} 话 · ${book.pageCount} 页'
                    : '${book.pageCount} 页')
            : '${book.chapters.length} 章';
    final palette = _shelfPalette[book.id % _shelfPalette.length];
    // 组装简介：本地书籍 · TXT · 123 章 · 45.6 万字 · 2.5 MB
    // 只有 TXT 且已统计字数时才显示字数段
    final parts = <String>[
      '本地书籍',
      kindLabel,
      countLabel,
      if (book.kind == LocalBookKind.txt && book.wordCount != null)
        _formatWordCount(book.wordCount!),
      formatLocalSize(book.size),
    ];
    final novel = Novel(
      id: book.id,
      title: book.displayTitle,
      author: book.displayAuthor,
      genre: '本地',
      summary: parts.join(' · '),
      colors: palette,
      isComplete: true,
      chapterCount: book.kind == LocalBookKind.pdf ||
              book.kind == LocalBookKind.comic
          ? book.pageCount
          : book.chapters.length,
    );
    _bookNovelCache[book] = novel;
    return novel;
  }

  // ---- NovelRepository ----

  @override
  Future<List<Novel>> list() async => _books.map(toNovel).toList();

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    // All local novels are complete; every sort keeps the existing book order.
    const pageSize = 20;
    final total = _books.length;
    final start = ((page - 1) * pageSize).clamp(0, total);
    final end = (start + pageSize).clamp(start, total);
    final items = [for (var i = start; i < end; i++) toNovel(_books[i])];
    return NovelPage(
      items: List.unmodifiable(items),
      page: page,
      totalPages: (total / pageSize).ceil(),
      totalItems: total,
    );
  }

  @override
  Future<Novel?> find(int id) async {
    final book = bookFor(id);
    return book == null ? null : toNovel(book);
  }

  @override
  Future<List<Novel>> search(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return _books
        .where(
          (b) =>
              b.displayTitle.toLowerCase().contains(q) ||
              b.displayAuthor.toLowerCase().contains(q) ||
              b.title.toLowerCase().contains(q) ||
              b.author.toLowerCase().contains(q) ||
              b.fileName.toLowerCase().contains(q),
        )
        .map(toNovel)
        .toList();
  }

  @override
  Future<Novel> detail(Novel novel) async {
    final book = bookFor(novel.id);
    if (book == null) throw StateError('书库中没有这本书的记录，请重新扫描导入');
    return toNovel(book);
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    await ensureReady(id);
    final book = bookFor(id);
    if (book == null) return const [];
    final cached = _bookChaptersCache[book];
    if (cached != null) return cached;
    final List<NovelChapter> built;
    if (book.kind == LocalBookKind.pdf) {
      built = List.unmodifiable(
        List.generate(
          book.pageCount,
          (i) => NovelChapter('第 ${i + 1} 页', '', id: i),
        ),
      );
    } else if (book.kind == LocalBookKind.comic) {
      final revision = book.revision;
      final multiChapter = book.chapters.length > 1;
      final pages = <NovelChapter>[];
      if (multiChapter) {
        var chIdx = 0;
        for (var p = 0; p < book.pageCount; p++) {
          while (chIdx + 1 < book.chapters.length &&
              p >= book.chapters[chIdx + 1].offset) {
            chIdx++;
          }
          final ch = book.chapters[chIdx];
          final pageInCh = (p - ch.offset) + 1;
          pages.add(
            NovelChapter(
              '${ch.title} · 第 $pageInCh 页',
              '',
              id: p,
              revision: revision,
              volume: ch.title,
            ),
          );
        }
      } else {
        for (var p = 0; p < book.pageCount; p++) {
          pages.add(
            NovelChapter(
              '第 ${p + 1} 页',
              '',
              id: p,
              revision: revision,
            ),
          );
        }
      }
      built = List.unmodifiable(pages);
    } else {
      final revision = book.revision;
      built = List.unmodifiable([
        for (var i = 0; i < book.chapters.length; i++)
          NovelChapter(
            book.chapters[i].title,
            '',
            id: i,
            revision: revision,
            volume: book.chapters[i].volume,
          ),
      ]);
    }
    _bookChaptersCache[book] = built;
    return built;
  }

  bool _validByteChapterRangesForBook(LocalBook book, int fileByteSize) {
    if (_bookValidByteSizeCache[book] == fileByteSize) return true;
    if (book.chapters.isEmpty) return false;
    var charEnd = 0;
    var byteEnd = 0;
    for (final c in book.chapters) {
      if (c.offset < charEnd || c.length < 0) return false;
      if (c.byteOffset < byteEnd ||
          c.byteLength < c.length ||
          c.byteLength > c.length * 3) {
        return false;
      }
      if (c.byteOffset + c.byteLength > fileByteSize) return false;
      charEnd = c.offset + c.length;
      byteEnd = c.byteOffset + c.byteLength;
    }
    if (byteEnd != fileByteSize) return false;
    _bookValidByteSizeCache[book] = fileByteSize;
    return true;
  }

  Future<String?> _readDirectUtf8ChapterSlice(
    String path,
    LocalChapterIndex ref,
  ) async {
    if (ref.length > localTextMaxReadCodeUnits ||
        ref.byteOffset < 0 ||
        ref.byteLength < 0) {
      return null;
    }
    if (ref.length == 0) return ref.byteLength == 0 ? '' : null;
    final raf = await File(path).open();
    final Uint8List buffer;
    try {
      await raf.setPosition(ref.byteOffset);
      buffer = Uint8List(ref.byteLength);
      var filled = 0;
      while (filled < ref.byteLength) {
        final n = await raf.readInto(buffer, filled, ref.byteLength);
        if (n <= 0) return null;
        filled += n;
      }
    } finally {
      await raf.close();
    }
    final String decoded;
    try {
      decoded = utf8.decode(buffer, allowMalformed: false);
    } on FormatException {
      return null;
    }
    if (decoded.length != ref.length ||
        decoded.startsWith('\uFEFF') ||
        decoded.contains('\r') ||
        decoded.contains('\u2028') ||
        decoded.contains('\u2029')) {
      return null;
    }
    return decoded;
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    final book = bookFor(novelId);
    if (book == null ||
        book.kind != LocalBookKind.txt ||
        book.chapters.isEmpty) {
      return '';
    }
    if (!acceptsChapter(novelId, chapter) ||
        chapter.id < 0 ||
        chapter.id >= book.chapters.length) {
      throw const StaleLocalChapterException();
    }
    final index = chapter.id;
    final ref = book.chapters[index];
    if (_textCache.containsKey(book.id)) {
      final text = await _readBookText(book);
      if (!validChapterRanges(book.chapters, text.length)) {
        throw StateError('章节范围损坏，请重新扫描');
      }
      if (bookFor(novelId)?.revision != chapter.revision ||
          isMigrationPending(novelId)) {
        throw const StaleLocalChapterException();
      }
      return text.substring(ref.offset, ref.offset + ref.length).trim();
    }
    final path = await _readableTextPath(book);
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      await file.length();
    }
    final sliceKey =
        '${book.id}\u0000${chapter.revision}\u0000${stat.size}\u0000'
        '${stat.modified.microsecondsSinceEpoch}\u0000$index';
    final cachedSlice = _chapterSliceCache.remove(sliceKey);
    if (cachedSlice != null) {
      _chapterSliceCache[sliceKey] = cachedSlice;
      if (bookFor(novelId)?.revision != chapter.revision ||
          isMigrationPending(novelId)) {
        throw const StaleLocalChapterException();
      }
      return cachedSlice;
    }

    String content;
    if (stat.size <= 64 * 1024 && ref.length <= localTextMaxReadCodeUnits) {
      final text = await _readBookText(book);
      if (!validChapterRanges(book.chapters, text.length)) {
        throw StateError('章节范围损坏，请重新扫描');
      }
      content = text.substring(ref.offset, ref.offset + ref.length);
    } else {
      String? directSlice;
      if (stat.size <= localTextMaxDecodedBytes &&
          ref.length <= localTextMaxReadCodeUnits &&
          _validByteChapterRangesForBook(book, stat.size)) {
        directSlice = await _readDirectUtf8ChapterSlice(path, ref);
      }
      if (directSlice != null) {
        content = directSlice;
      } else if (stat.size <= _textCacheBudget ~/ 2 &&
          ref.length <= localTextMaxReadCodeUnits) {
        final text = await _readBookText(book);
        if (!validChapterRanges(book.chapters, text.length)) {
          throw StateError('章节范围损坏，请重新扫描');
        }
        content = text.substring(ref.offset, ref.offset + ref.length);
      } else {
        content = await _readerWorker.readRange(
          path,
          ref.offset,
          ref.length,
          byteOffset: ref.byteOffset >= 0 ? ref.byteOffset : null,
          byteLength: ref.byteLength >= 0 ? ref.byteLength : null,
        );
      }
    }
    if (bookFor(novelId)?.revision != chapter.revision ||
        isMigrationPending(novelId)) {
      throw const StaleLocalChapterException();
    }
    final trimmed = content.trim();
    if (!_disposed && !_textCache.containsKey(book.id)) {
      _cacheChapterSlice(sliceKey, trimmed);
    }
    return trimmed;
  }

  Future<({EpubPackage package, _CachedEpubSession? session})>
  _acquireEpubSession(LocalBook book, String localPath) async {
    if (_disposed || book.sourceFingerprint.isEmpty) {
      return (
        package: await EpubPackage.open(localPath, lenient: true),
        session: null,
      );
    }
    final stat = await File(localPath).stat();
    final modifiedMicros = stat.modified.microsecondsSinceEpoch;
    final existing = _epubSessionCache.remove(book.id);
    if (existing != null) {
      if (!existing.evicted &&
          stat.type == FileSystemEntityType.file &&
          existing.localPath == localPath &&
          existing.fileSize == stat.size &&
          existing.fileModifiedMicros == modifiedMicros &&
          existing.bookRevision == book.revision &&
          existing.sourceFingerprint == book.sourceFingerprint) {
        existing.activeReaders++;
        _epubSessionCache[book.id] = existing;
        return (package: existing.package, session: existing);
      }
      _evictEpubSession(existing);
    }
    final package = await EpubPackage.open(localPath, lenient: true);
    if (_disposed || bookFor(book.id)?.revision != book.revision) {
      return (package: package, session: null);
    }
    final concurrent = _epubSessionCache.remove(book.id);
    if (concurrent != null) {
      if (!concurrent.evicted &&
          stat.type == FileSystemEntityType.file &&
          concurrent.localPath == localPath &&
          concurrent.fileSize == stat.size &&
          concurrent.fileModifiedMicros == modifiedMicros &&
          concurrent.bookRevision == book.revision &&
          concurrent.sourceFingerprint == book.sourceFingerprint) {
        await package.close();
        concurrent.activeReaders++;
        _epubSessionCache[book.id] = concurrent;
        return (package: concurrent.package, session: concurrent);
      }
      _evictEpubSession(concurrent);
    }
    final session = _CachedEpubSession(
      localPath: localPath,
      fileSize: stat.size,
      fileModifiedMicros: modifiedMicros,
      bookRevision: book.revision,
      sourceFingerprint: book.sourceFingerprint,
      package: package,
    )..activeReaders = 1;
    while (_epubSessionCache.length >= _epubSessionCacheMaxEntries) {
      final oldestKey = _epubSessionCache.keys.first;
      final oldest = _epubSessionCache.remove(oldestKey);
      if (oldest != null) _evictEpubSession(oldest);
    }
    _epubSessionCache[book.id] = session;
    return (package: package, session: session);
  }

  Future<({List<EpubBlock> blocks, Map<String, Uint8List> images})> epubChapter(
    int novelId,
    int chapterIndex,
  ) async {
    var book = bookFor(novelId);
    if (book == null || book.kind != LocalBookKind.epub) {
      throw StateError('EPUB 章节索引缺失或越界，请重新扫描');
    }
    if (book.chapterSplitVersion != _chapterSplitVersion &&
        book.sourceFingerprint.isNotEmpty &&
        _activeScan == null) {
      final current = book;
      book = await _synchronized(() => _upgradeEpubChaptersIfNeeded(current));
    }
    if (chapterIndex < 0 ||
        chapterIndex >= book.chapters.length ||
        book.epubChapterHrefs.length != book.chapters.length) {
      throw StateError('EPUB 章节索引缺失或越界，请重新扫描');
    }
    final localPath = await _epubLocalPath(
      id: book.id,
      fileUri: book.fileUri,
      size: book.size,
      sourceKey: book.sourceKey,
      sourceFingerprint: book.sourceFingerprint,
    );
    if (book.sourceFingerprint.isNotEmpty &&
        await _epubSourceFingerprint(localPath) != book.sourceFingerprint) {
      final stale = _epubSessionCache.remove(book.id);
      if (stale != null) _evictEpubSession(stale);
      throw StateError('EPUB 源文件已变化，请重新扫描');
    }
    final acquired = await _acquireEpubSession(book, localPath);
    final package = acquired.package;
    final session = acquired.session;
    try {
      if (package.chapters.length != book.chapters.length ||
          package.chapters[chapterIndex].href !=
              book.epubChapterHrefs[chapterIndex]) {
        if (session != null && identical(_epubSessionCache[book.id], session)) {
          _epubSessionCache.remove(book.id);
          session.evicted = true;
        }
        throw StateError('EPUB 章节对应关系已变化，请重新扫描');
      }
      final source = await package.chapterBlocks(chapterIndex);
      // 首次打开某章仍需逐张解压本章图片后才返回正文；缓存只省去
      // 换章回看/重进阅读器时的重复解压。无源指纹的旧记录无法校验内容，不走缓存。
      final useImageCache = book.sourceFingerprint.isNotEmpty;
      final images = <String, Uint8List>{};
      final failed = <String>{};
      for (final block in source) {
        if (block.kind != EpubBlockKind.image) continue;
        final path = block.entryPath;
        if (path == null || images.containsKey(path) || failed.contains(path)) {
          continue;
        }
        final key = _epubImageKey(book, path);
        final hit = useImageCache ? _epubImageCache[key] : null;
        if (hit != null) {
          images[path] = hit;
          continue;
        }
        try {
          final bytes = await package.readEntry(path);
          if (bytes.isEmpty) {
            failed.add(path);
          } else {
            images[path] = bytes;
            final current = bookFor(novelId);
            if (useImageCache &&
                !_disposed &&
                current?.revision == book.revision &&
                current?.sourceFingerprint == book.sourceFingerprint) {
              _cacheEpubImage(key, bytes);
            }
          }
        } catch (_) {
          failed.add(path);
        }
      }
      final blocks = <EpubBlock>[
        for (final b in source)
          if (b.kind != EpubBlockKind.image || images.containsKey(b.entryPath))
            b,
      ];
      return (blocks: blocks, images: images);
    } finally {
      if (session == null) {
        await package.close();
      } else {
        session.activeReaders--;
        await session.releaseIfIdle();
      }
    }
  }

  File _comicManifestFile(int id) =>
      File('${_booksDir.path}/comic_manifest_$id.json');

  File _comicSeriesManifestFile(int id) =>
      File('${_booksDir.path}/comic_series_$id.json');

  Future<File> _comicCacheFile(int id) async {
    final cacheRoot = await getApplicationCacheDirectory();
    final dir = Directory('${cacheRoot.path}/local_comic');
    await dir.create(recursive: true);
    return File('${dir.path}/$id.cbz');
  }

  Future<String> _comicLocalPath({
    required int id,
    required String fileUri,
    required int size,
    required String sourceKey,
    required String sourceFingerprint,
  }) async {
    if (fileUri.startsWith('file://') || !fileUri.contains('://')) {
      if (sourceKey.isNotEmpty && File(sourceKey).isAbsolute) {
        return sourceKey;
      }
      if (fileUri.startsWith('file://')) {
        final legacyPath = fileUri.substring('file://'.length);
        if (await File(legacyPath).exists()) return legacyPath;
        return Uri.parse(fileUri).toFilePath();
      }
      return fileUri;
    }
    if (size > localEpubMaxSourceBytes) {
      throw const FormatException('漫画压缩包超过 1 GiB，无法打开');
    }
    final cacheFile = await _comicCacheFile(id);
    if (await cacheFile.exists() &&
        (size <= 0 || await cacheFile.length() == size) &&
        (sourceFingerprint.isEmpty ||
            await _epubSourceFingerprint(cacheFile.path) == sourceFingerprint)) {
      return cacheFile.path;
    }
    final staged = await _stageEpubCopy(fileUri, size, cacheFile.parent);
    try {
      if (sourceFingerprint.isNotEmpty &&
          await _epubSourceFingerprint(staged.path) != sourceFingerprint) {
        throw StateError('漫画源文件已变化，请重新扫描');
      }
      await staged.rename(cacheFile.path);
      return cacheFile.path;
    } finally {
      await staged.parent.delete(recursive: true);
    }
  }

  Future<({ComicArchivePackage package, _CachedComicSession? session})>
  _acquireComicSession(LocalBook book, String localPath) async {
    if (_disposed || book.sourceFingerprint.isEmpty) {
      return (
        package: await ComicArchivePackage.openFile(localPath),
        session: null,
      );
    }
    final stat = await File(localPath).stat();
    final modifiedMicros = stat.modified.microsecondsSinceEpoch;
    final existing = _comicSessionCache.remove(book.id);
    if (existing != null) {
      if (!existing.evicted &&
          stat.type == FileSystemEntityType.file &&
          existing.localPath == localPath &&
          existing.fileSize == stat.size &&
          existing.fileModifiedMicros == modifiedMicros &&
          existing.sourceFingerprint == book.sourceFingerprint) {
        existing.activeReaders++;
        _comicSessionCache[book.id] = existing;
        return (package: existing.package, session: existing);
      }
      _evictComicSession(existing);
    }
    final package = await ComicArchivePackage.openFile(localPath);
    if (_disposed || bookFor(book.id)?.sourceFingerprint != book.sourceFingerprint) {
      return (package: package, session: null);
    }
    final session = _CachedComicSession(
      localPath: localPath,
      fileSize: stat.size,
      fileModifiedMicros: modifiedMicros,
      sourceFingerprint: book.sourceFingerprint,
      package: package,
    )..activeReaders = 1;
    while (_comicSessionCache.length >= _epubSessionCacheMaxEntries) {
      final oldestKey = _comicSessionCache.keys.first;
      final oldest = _comicSessionCache.remove(oldestKey);
      if (oldest != null) _evictComicSession(oldest);
    }
    _comicSessionCache[book.id] = session;
    return (package: package, session: session);
  }

  Future<ComicFolderManifest?> loadComicFolderManifest(int bookId) async {
    final cached = _comicManifestCache[bookId];
    if (cached != null) return cached;
    final file = _comicManifestFile(bookId);
    if (!await file.exists()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      final manifest = ComicFolderManifest.fromJson(
        Map<String, Object?>.from(raw),
      );
      if (!_disposed) _comicManifestCache[bookId] = manifest;
      return manifest;
    } catch (_) {
      return null;
    }
  }

  Future<ComicSeriesManifest?> loadComicSeriesManifest(int bookId) async {
    final cached = _comicSeriesCache[bookId];
    if (cached != null) return cached;
    final file = _comicSeriesManifestFile(bookId);
    if (!await file.exists()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      final manifest = ComicSeriesManifest.fromJson(
        Map<String, Object?>.from(raw),
      );
      if (!_disposed) _comicSeriesCache[bookId] = manifest;
      return manifest;
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveSeriesVolumeLocalPath(
    int bookId,
    ComicSeriesVolumeEntry vol,
  ) async {
    if (vol.uri.startsWith('file://') || !vol.uri.contains('://')) {
      if (vol.uri.startsWith('file://')) {
        final legacyPath = vol.uri.substring('file://'.length);
        if (await File(legacyPath).exists()) return legacyPath;
        return Uri.parse(vol.uri).toFilePath();
      }
      return vol.uri;
    }
    if (vol.size > localEpubMaxSourceBytes) {
      throw const FormatException('漫画分卷文件超过 1 GiB，无法打开');
    }
    final lruKey = '$bookId:${vol.uri}';
    final existingPath = _comicSeriesVolumeFiles.remove(lruKey);
    if (existingPath != null) {
      final f = File(existingPath);
      if (await f.exists() && (vol.size <= 0 || await f.length() == vol.size)) {
        _comicSeriesVolumeFiles[lruKey] = existingPath;
        return existingPath;
      }
    }
    final cacheRoot = await getApplicationCacheDirectory();
    final dir = Directory('${cacheRoot.path}/local_comic_series');
    await dir.create(recursive: true);
    final ext = vol.kind == 'epub' ? 'epub' : 'cbz';
    final sig = sha256
        .convert(utf8.encode('${vol.uri}_${vol.size}_${vol.modifiedMs}'))
        .toString()
        .substring(0, 12);
    final cacheFile = File('${dir.path}/series_${bookId}_$sig.$ext');
    if (!await cacheFile.exists() ||
        (vol.size > 0 && await cacheFile.length() != vol.size)) {
      final staged = await _stageEpubCopy(vol.uri, vol.size, dir);
      try {
        await staged.rename(cacheFile.path);
      } finally {
        await staged.parent.delete(recursive: true);
      }
    }
    while (_comicSeriesVolumeFiles.length >= _comicSeriesVolumeCacheMaxEntries) {
      final oldestKey = _comicSeriesVolumeFiles.keys.first;
      final oldestPath = _comicSeriesVolumeFiles.remove(oldestKey);
      if (oldestPath != null && oldestPath != cacheFile.path) {
        try {
          final oldFile = File(oldestPath);
          if (await oldFile.exists()) await oldFile.delete();
        } catch (_) {}
      }
    }
    _comicSeriesVolumeFiles[lruKey] = cacheFile.path;
    return cacheFile.path;
  }

  Future<Uint8List> readComicSeriesPage(
    int bookId,
    int globalPage, {
    int pdfDecodeWidth = 1440,
  }) async {
    final book = bookFor(bookId);
    if (book == null ||
        book.kind != LocalBookKind.comic ||
        !book.isComicSeries) {
      throw StateError('多卷漫画不存在，请重新扫描');
    }
    final manifest = await loadComicSeriesManifest(bookId);
    final resolved = manifest?.resolveGlobalPage(globalPage);
    if (resolved == null) {
      throw RangeError.index(globalPage, book, 'globalPage');
    }
    final vol = resolved.volume;
    final localPage = resolved.localPage;
    final cacheKey = _epubImageKey(
      book,
      'series:$globalPage:${vol.kind == "pdf" ? pdfDecodeWidth : 0}',
    );
    final useCache = book.sourceFingerprint.isNotEmpty;
    if (useCache) {
      final hit = _epubImageCache.remove(cacheKey);
      if (hit != null) {
        _epubImageCache[cacheKey] = hit;
        return hit;
      }
    }
    Uint8List bytes;
    if (vol.kind == 'pdf') {
      final renderedPath = await LocalPlatform.renderPdfPage(
        vol.uri,
        localPage,
        pdfDecodeWidth,
      );
      if (renderedPath.isEmpty) {
        throw StateError('PDF 漫画页面渲染失败');
      }
      final renderedFile = File(renderedPath);
      if (!await renderedFile.exists()) {
        throw StateError('PDF 漫画渲染缓存不存在');
      }
      bytes = await renderedFile.readAsBytes();
    } else if (vol.kind == 'cbz') {
      final localPath = await _resolveSeriesVolumeLocalPath(bookId, vol);
      final pkg = await ComicArchivePackage.openFile(localPath);
      try {
        bytes = pkg.readPageSync(localPage);
      } finally {
        await pkg.close();
      }
    } else if (vol.kind == 'epub') {
      final localPath = await _resolveSeriesVolumeLocalPath(bookId, vol);
      final epub = await EpubPackage.open(localPath, lenient: true);
      try {
        final pages = vol.epubPages.isNotEmpty
            ? vol.epubPages
            : (await epub.extractMangaPages()).pages;
        if (localPage < 0 || localPage >= pages.length) {
          throw RangeError.index(localPage, pages, 'localPage');
        }
        bytes = await epub.readEntry(pages[localPage]);
      } finally {
        await epub.close();
      }
    } else {
      throw UnsupportedError('不支持的漫画分卷格式: ${vol.kind}');
    }
    if (useCache && !_disposed && bytes.isNotEmpty) {
      _cacheEpubImage(cacheKey, bytes);
    }
    return bytes;
  }

  Future<Uint8List> readComicFolderPage(ComicFolderPageEntry entry) async {
    final uri = entry.uri;
    if (uri.startsWith('content:')) {
      return LocalPlatform.readLocalBytes(uri);
    }
    final file = uri.startsWith('file:')
        ? File.fromUri(Uri.parse(uri))
        : File(uri);
    return file.readAsBytes();
  }

  Future<Uint8List> readComicArchivePage(int bookId, int pageIndex) async {
    final book = bookFor(bookId);
    if (book == null ||
        book.kind != LocalBookKind.comic ||
        book.isDirectoryBackedComic) {
      throw StateError('漫画归档不存在，请重新扫描');
    }
    final cacheKey = _epubImageKey(book, 'page:$pageIndex');
    final useCache = book.sourceFingerprint.isNotEmpty;
    if (useCache) {
      final hit = _epubImageCache.remove(cacheKey);
      if (hit != null) {
        _epubImageCache[cacheKey] = hit;
        return hit;
      }
    }
    final localPath = await _comicLocalPath(
      id: book.id,
      fileUri: book.fileUri,
      size: book.size,
      sourceKey: book.sourceKey,
      sourceFingerprint: book.sourceFingerprint,
    );
    final acquired = await _acquireComicSession(book, localPath);
    final package = acquired.package;
    final session = acquired.session;
    try {
      final bytes = package.readPageSync(pageIndex);
      if (useCache && !_disposed && bytes.isNotEmpty) {
        _cacheEpubImage(cacheKey, bytes);
      }
      return bytes;
    } finally {
      if (session == null) {
        package.close();
      } else {
        session.activeReaders--;
        session.releaseIfIdle();
      }
    }
  }

  Future<
    ({
      List<String> pages,
      List<({String title, int startPage, int pageCount})> chapters,
      List<int> pageToSpineChapter,
      bool isRtl,
    })
  >
  loadEpubMangaDescriptor(int bookId) async {
    var book = bookFor(bookId);
    if (book == null || book.kind != LocalBookKind.epub) {
      throw StateError('EPUB 书籍不存在，请重新扫描');
    }
    if (book.chapterSplitVersion != _chapterSplitVersion &&
        book.sourceFingerprint.isNotEmpty &&
        _activeScan == null) {
      final current = book;
      book = await _synchronized(() => _upgradeEpubChaptersIfNeeded(current));
    }
    final localPath = await _epubLocalPath(
      id: book.id,
      fileUri: book.fileUri,
      size: book.size,
      sourceKey: book.sourceKey,
      sourceFingerprint: book.sourceFingerprint,
    );
    final acquired = await _acquireEpubSession(book, localPath);
    final package = acquired.package;
    final session = acquired.session;
    try {
      final extracted = await package.extractMangaPages();
      return (
        pages: extracted.pages,
        chapters: extracted.chapters,
        pageToSpineChapter: extracted.pageToSpineChapter,
        isRtl: package.isRtlProgression,
      );
    } finally {
      if (session == null) {
        await package.close();
      } else {
        session.activeReaders--;
        await session.releaseIfIdle();
      }
    }
  }

  Future<Uint8List> readEpubMangaEntry(int bookId, String entryPath) async {
    final book = bookFor(bookId);
    if (book == null || book.kind != LocalBookKind.epub) {
      throw StateError('EPUB 书籍不存在，请重新扫描');
    }
    final cacheKey = _epubImageKey(book, entryPath);
    final useCache = book.sourceFingerprint.isNotEmpty;
    if (useCache) {
      final hit = _epubImageCache.remove(cacheKey);
      if (hit != null) {
        _epubImageCache[cacheKey] = hit;
        return hit;
      }
    }
    final localPath = await _epubLocalPath(
      id: book.id,
      fileUri: book.fileUri,
      size: book.size,
      sourceKey: book.sourceKey,
      sourceFingerprint: book.sourceFingerprint,
    );
    final acquired = await _acquireEpubSession(book, localPath);
    final package = acquired.package;
    final session = acquired.session;
    try {
      final bytes = await package.readEntry(entryPath);
      if (useCache && !_disposed && bytes.isNotEmpty) {
        _cacheEpubImage(cacheKey, bytes);
      }
      return bytes;
    } finally {
      if (session == null) {
        await package.close();
      } else {
        session.activeReaders--;
        await session.releaseIfIdle();
      }
    }
  }

  bool _canLoadCoverForBook(LocalBook book) {
    if (_disposed) return false;
    return switch (book.kind) {
      LocalBookKind.comic => book.pageCount > 0,
      LocalBookKind.epub =>
        (book.coverEntry != null && book.coverEntry!.isNotEmpty) ||
            book.isComicEpub,
      LocalBookKind.pdf => book.pageCount > 0,
      LocalBookKind.txt => false,
    };
  }

  Future<Uint8List> extractLocalCoverBytes(int id) async {
    final book = bookFor(id);
    if (book == null || !_canLoadCoverForBook(book)) {
      throw const FormatException('本地书籍没有可用封面');
    }
    File? diskCache;
    try {
      final cacheRoot = await getApplicationCacheDirectory();
      final coverDir = Directory('${cacheRoot.path}/local_covers');
      await coverDir.create(recursive: true);
      final sigSource = book.sourceFingerprint.isNotEmpty
          ? book.sourceFingerprint
          : '${book.size}_${book.modified}_${book.coverEntry ?? ""}';
      final sig = sha256.convert(utf8.encode(sigSource)).toString().substring(0, 12);
      diskCache = File('${coverDir.path}/cover_${book.id}_$sig.bin');
      if (await diskCache.exists()) {
        final cached = await diskCache.readAsBytes();
        if (cached.isNotEmpty) return cached;
      }
    } catch (_) {
      diskCache = null;
    }

    Uint8List bytes = Uint8List(0);
    if (book.kind == LocalBookKind.comic) {
      if (book.isComicFolder) {
        final manifest = await loadComicFolderManifest(book.id);
        if (manifest != null && manifest.pages.isNotEmpty) {
          final idx = manifest.coverPageIndex.clamp(0, manifest.pages.length - 1);
          bytes = await readComicFolderPage(manifest.pages[idx]);
        }
      } else if (book.isComicSeries) {
        final manifest = await loadComicSeriesManifest(book.id);
        if (manifest != null && manifest.volumes.isNotEmpty) {
          final firstVol = manifest.volumes.first;
          final explicitCover = firstVol.coverEntry;
          if (explicitCover != null && explicitCover.isNotEmpty) {
            try {
              if (firstVol.kind == 'epub') {
                final localPath = await _resolveSeriesVolumeLocalPath(
                  book.id,
                  firstVol,
                );
                final epub = await EpubPackage.open(localPath, lenient: true);
                try {
                  bytes = await epub.readEntry(explicitCover);
                } finally {
                  await epub.close();
                }
              } else if (firstVol.kind == 'cbz') {
                final localPath = await _resolveSeriesVolumeLocalPath(
                  book.id,
                  firstVol,
                );
                final pkg = await ComicArchivePackage.openFile(localPath);
                try {
                  bytes = pkg.readEntrySync(explicitCover);
                } finally {
                  await pkg.close();
                }
              }
            } catch (_) {}
          }
          if (bytes.isEmpty) {
            bytes = await readComicSeriesPage(
              book.id,
              0,
              pdfDecodeWidth: 540,
            );
          }
        }
      } else {
        final localPath = await _comicLocalPath(
          id: book.id,
          fileUri: book.fileUri,
          size: book.size,
          sourceKey: book.sourceKey,
          sourceFingerprint: book.sourceFingerprint,
        );
        final acquired = await _acquireComicSession(book, localPath);
        try {
          final coverEntry = book.coverEntry ?? acquired.package.coverEntry;
          bytes = coverEntry.isNotEmpty
              ? acquired.package.readEntrySync(coverEntry)
              : acquired.package.readPageSync(0);
        } finally {
          if (acquired.session == null) {
            await acquired.package.close();
          } else {
            acquired.session!.activeReaders--;
            acquired.session!.releaseIfIdle();
          }
        }
      }
    } else if (book.kind == LocalBookKind.epub) {
      if (book.coverEntry != null && book.coverEntry!.isNotEmpty) {
        bytes = await readEpubMangaEntry(book.id, book.coverEntry!);
      } else if (book.isComicEpub) {
        final desc = await loadEpubMangaDescriptor(book.id);
        if (desc.pages.isNotEmpty) {
          bytes = await readEpubMangaEntry(book.id, desc.pages.first);
        }
      }
    } else if (book.kind == LocalBookKind.pdf) {
      final renderedPath = await LocalPlatform.renderPdfPage(
        book.fileUri,
        0,
        480,
      );
      if (renderedPath.isNotEmpty) {
        final renderedFile = File(renderedPath);
        if (await renderedFile.exists()) {
          bytes = await renderedFile.readAsBytes();
        }
      }
    }

    if (bytes.isEmpty) {
      throw const FormatException('本地书籍没有可用封面');
    }
    if (diskCache != null && bytes.length <= 24 * 1024 * 1024) {
      try {
        await diskCache.writeAsBytes(bytes, flush: false);
      } catch (_) {}
    }
    return bytes;
  }
}

/// 从仓库中取出本地书库；仓库不是复合仓库时返回 null。
LocalLibraryStore? localLibraryOf(NovelRepository? repository) =>
    repository is LocalLibraryStore
    ? repository
    : repository is CompositeNovelRepository
    ? repository.local
    : null;

/// 本地优先的复合仓库：本地 id 走 [LocalLibraryStore]，其余走在线仓库。
class CompositeNovelRepository extends NovelRepository {
  const CompositeNovelRepository({required this.local, required this.remote});

  final LocalLibraryStore local;
  final NovelRepository remote;

  @override
  NovelRepository? get remoteRepository => remote;

  @override
  Future<List<Novel>> list() => remote.list();

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => remote.browse(sort: sort, page: page, refresh: refresh);

  @override
  Future<Novel?> find(int id) =>
      isLocalNovelId(id) ? local.find(id) : remote.find(id);

  @override
  Future<List<Novel>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final results = [...await local.search(query)];
    results.addAll(await remote.search(query));
    return results;
  }

  @override
  Future<Novel> detail(Novel novel) =>
      isLocalNovelId(novel.id) ? local.detail(novel) : remote.detail(novel);

  @override
  Future<List<NovelChapter>> chapters(int id) =>
      isLocalNovelId(id) ? local.chapters(id) : remote.chapters(id);

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) =>
      isLocalNovelId(novelId)
      ? local.chapterContent(novelId, chapter)
      : remote.chapterContent(novelId, chapter);
}

class StaleLocalChapterException implements Exception {
  const StaleLocalChapterException();
  @override
  String toString() => '章节目录已更新，请等待进度迁移后重新载入';
}

/// 本地书籍的来源身份：同一来源只生成一种忽略键。
///
/// appFolder 与 SAF 的来源字段不能互相覆盖：旧 appFolder 记录即使当前
/// 选中了 SAF 文件夹，仍属于 appFolder:novels；旧 SAF 记录则属于
/// 当初授权的 SAF 树。忽略键格式为 jsonEncode([sourceId, sourceKey])，
/// 与旧名单条目格式一致。
class LocalSourceIdentity {
  const LocalSourceIdentity._(this.sourceId, this.sourceKey);

  final String sourceId;
  final String sourceKey;

  String get ignoredKey => jsonEncode([sourceId, sourceKey]);

  factory LocalSourceIdentity.appFolder(String path) {
    return LocalSourceIdentity._(
      'appFolder:novels',
      _filePath(path),
    );
  }

  factory LocalSourceIdentity.saf(String treeUri, String sourceKey) {
    if (treeUri.isEmpty || sourceKey.isEmpty) {
      throw StateError('SAF 来源信息不完整');
    }
    return LocalSourceIdentity._('saf:$treeUri', sourceKey);
  }

  factory LocalSourceIdentity.safManga(String treeUri, String sourceKey) {
    if (treeUri.isEmpty || sourceKey.isEmpty) {
      throw StateError('SAF 来源信息不完整');
    }
    return LocalSourceIdentity._('saf_manga:$treeUri', sourceKey);
  }

  factory LocalSourceIdentity.forBook({
    required String sourceId,
    required String sourceKey,
    required String fileUri,
    required String? folderUri,
  }) {
    final storedKey = sourceKey.isNotEmpty ? sourceKey : fileUri;
    if (storedKey.isEmpty) {
      throw StateError('书籍没有可识别的源定位符');
    }
    // 已回填的记录保留自己的来源，不能被当前所选目录覆盖。
    if (sourceId == 'appFolder:novels') {
      return LocalSourceIdentity.appFolder(storedKey);
    }
    if (sourceId.isNotEmpty) {
      return LocalSourceIdentity._(sourceId, storedKey);
    }
    // 旧记录优先根据源 fileUri 判断所属来源。
    final locator = fileUri.isNotEmpty ? fileUri : storedKey;
    final uri = Uri.tryParse(locator);
    if (uri?.scheme == 'content') {
      // 旧 SAF 记录的树必须从它自身的 URI 里取，不能借用当前目录：
      // 当前目录已换成 B 时，借用 folderUri 会写出 B 的忽略键，
      // 以后扫描 A 时仍会重新导入。
      final parts = uri!.pathSegments;
      final documentAt = locator.indexOf('/document/');
      if (parts.length < 4 ||
          parts[0] != 'tree' ||
          parts[2] != 'document' ||
          documentAt < 0) {
        throw StateError('旧 SAF 记录缺少原目录身份，请先扫描原目录');
      }
      // 保留源 URI 中树前缀的原始编码，不借用当前 folderUri。
      return LocalSourceIdentity.saf(
        locator.substring(0, documentAt),
        storedKey,
      );
    }
    if (uri == null || !uri.hasScheme || uri.scheme == 'file') {
      // 旧 appFolder 记录即使当前选中了 SAF 文件夹，
      // 仍然使用 appFolder:novels + 源文件路径。
      return LocalSourceIdentity.appFolder(locator);
    }
    throw StateError('无法识别旧书籍的来源：${uri.scheme}');
  }

  static String _filePath(String value) {
    if (value.isEmpty) throw StateError('源文件路径不能为空');
    final uri = Uri.tryParse(value);
    if (uri?.scheme == 'file') {
      return uri!.toFilePath();
    }
    if (uri != null && uri.hasScheme) {
      throw StateError('appFolder 来源不是文件路径');
    }
    return value;
  }
}

/// Serialized request/reply transport. A dead or unresponsive isolate gets one
/// replacement; application errors from a live worker are returned unchanged.
class LocalTextWorkerClient {
  LocalTextWorkerClient(
    this.entryPoint, {
    this.readyTimeout = const Duration(seconds: 3),
    this.replyTimeout = const Duration(seconds: 12),
  });

  final void Function(SendPort) entryPoint;
  final Duration readyTimeout;
  final Duration replyTimeout;
  _WorkerSession? _session;
  Future<void> _queue = Future.value();
  bool _closed = false;

  Future<Object?> run(Map<String, Object?> job) {
    final next = _queue.then((_) => _run(job));
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<Object?> _run(Map<String, Object?> job) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_closed) throw StateError('Text worker disposed');
      if (_session?.closed == true) _session = null;
      final session = _session ??= _WorkerSession();
      try {
        if (session.requests == null) {
          await session
              .start(entryPoint)
              .timeout(
                readyTimeout,
                onTimeout: () => throw const TextWorkerUnavailable('文本处理启动超时'),
              );
        }
        if (session.closed) throw const TextWorkerUnavailable('文本处理已退出');
        final reply = ReceivePort();
        try {
          session.requests!.send((reply.sendPort, job));
          final response =
              await Future.any<Object?>([
                reply.first,
                session.failure.future.then<Object?>((error) => throw error),
              ]).timeout(
                replyTimeout,
                onTimeout: () => throw const TextWorkerUnavailable('文本处理回复超时'),
              );
          if (response is! List || response.length < 2) {
            throw const TextWorkerUnavailable('文本处理回复无效');
          }
          if (response[0] == false) {
            Error.throwWithStackTrace(
              response[1] as Object,
              response.length > 2 && response[2] is StackTrace
                  ? response[2] as StackTrace
                  : StackTrace.current,
            );
          }
          return response[1];
        } finally {
          reply.close();
        }
      } on TextWorkerUnavailable {
        session.close();
        if (identical(_session, session)) _session = null;
        if (attempt == 1 || _closed) rethrow;
      }
    }
    throw const TextWorkerUnavailable('文本处理失败，请重试');
  }

  void dispose() {
    _closed = true;
    _session?.close();
    _session = null;
  }
}

class TextWorkerUnavailable implements Exception {
  const TextWorkerUnavailable(this.message);
  final String message;
  @override
  String toString() => '$message，请重试';
}

class _WorkerSession {
  final ready = ReceivePort();
  final exited = ReceivePort();
  final errors = ReceivePort();
  final failure = Completer<TextWorkerUnavailable>();
  Isolate? isolate;
  SendPort? requests;
  bool closed = false;

  Future<void> start(void Function(SendPort) entryPoint) async {
    exited.listen((_) => _fail('文本处理进程已退出'));
    errors.listen((_) => _fail('文本处理进程异常退出'));
    try {
      // Install listeners before entryPoint can run, including early exits.
      final spawning = Isolate.spawn(
        entryPoint,
        ready.sendPort,
        onExit: exited.sendPort,
        onError: errors.sendPort,
        errorsAreFatal: true,
      );
      isolate = await spawning;
      if (closed) {
        isolate!.kill(priority: Isolate.immediate);
        throw const TextWorkerUnavailable('文本处理已取消');
      }
      final port = await Future.any<Object?>([
        ready.first,
        failure.future.then<Object?>((error) => throw error),
      ]);
      if (port is! SendPort) {
        throw const TextWorkerUnavailable('文本处理握手无效');
      }
      if (closed) throw const TextWorkerUnavailable('文本处理已取消');
      requests = port;
    } on TextWorkerUnavailable {
      rethrow;
    } catch (_) {
      throw const TextWorkerUnavailable('文本处理无法启动');
    } finally {
      ready.close();
    }
  }

  void _fail(String message) {
    requests = null;
    if (!failure.isCompleted) failure.complete(TextWorkerUnavailable(message));
    // Clear the old SendPort even when the worker exits between requests.
    close();
  }

  void close() {
    if (closed) return;
    closed = true;
    requests = null;
    if (!failure.isCompleted) {
      failure.complete(const TextWorkerUnavailable('文本处理已终止'));
    }
    isolate?.kill(priority: Isolate.immediate);
    ready.close();
    exited.close();
    errors.close();
  }
}
