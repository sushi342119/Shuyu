import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:path_provider/path_provider.dart';

import '../catalog.dart';
import '../local_library.dart'
    show isSourceNovelId, sourceNovelIdBase, sourceNovelIdMax;
import '../reader_purification.dart';
import 'book_source_store.dart';
import 'network_url_safety.dart';
import 'source_image_cache.dart';

class OnlineBookOrigin {
  const OnlineBookOrigin({
    required this.bookId,
    required this.sourceId,
    required this.sourceName,
    required this.sourceBaseUrl,
    required this.bookUrl,
    required this.title,
    this.author = '',
    this.genre = '',
    this.summary = '',
    this.tocUrl,
    this.coverUrl,
    this.isManga = false,
    this.latestChapterTitle,
    this.knownChapterCount = 0,
    this.unreadUpdateCount = 0,
    this.updatedAtMs = 0,
  });

  final int bookId;
  final String sourceId;
  final String sourceName;
  final String sourceBaseUrl;
  final String bookUrl;
  final String title;
  final String author;
  final String genre;
  final String summary;
  final String? tocUrl;
  final String? coverUrl;
  final bool isManga;
  final String? latestChapterTitle;
  final int knownChapterCount;
  final int unreadUpdateCount;
  final int updatedAtMs;

  OnlineBookOrigin copyWith({
    String? sourceId,
    String? sourceName,
    String? sourceBaseUrl,
    String? bookUrl,
    String? title,
    String? author,
    String? genre,
    String? summary,
    String? tocUrl,
    String? coverUrl,
    bool? isManga,
    String? latestChapterTitle,
    int? knownChapterCount,
    int? unreadUpdateCount,
    int? updatedAtMs,
  }) => OnlineBookOrigin(
    bookId: bookId,
    sourceId: sourceId ?? this.sourceId,
    sourceName: sourceName ?? this.sourceName,
    sourceBaseUrl: sourceBaseUrl ?? this.sourceBaseUrl,
    bookUrl: bookUrl ?? this.bookUrl,
    title: title ?? this.title,
    author: author ?? this.author,
    genre: genre ?? this.genre,
    summary: summary ?? this.summary,
    tocUrl: tocUrl ?? this.tocUrl,
    coverUrl: coverUrl ?? this.coverUrl,
    isManga: isManga ?? this.isManga,
    latestChapterTitle: latestChapterTitle ?? this.latestChapterTitle,
    knownChapterCount: knownChapterCount ?? this.knownChapterCount,
    unreadUpdateCount: unreadUpdateCount ?? this.unreadUpdateCount,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, Object?> toJson() => {
    'bookId': bookId,
    'sourceId': sourceId,
    'sourceName': sourceName,
    'sourceBaseUrl': sourceBaseUrl,
    'bookUrl': bookUrl,
    'title': title,
    if (author.isNotEmpty) 'author': author,
    if (genre.isNotEmpty) 'genre': genre,
    if (summary.isNotEmpty) 'summary': summary,
    if (tocUrl != null && tocUrl!.isNotEmpty) 'tocUrl': tocUrl,
    if (coverUrl != null && coverUrl!.isNotEmpty) 'coverUrl': coverUrl,
    if (isManga) 'isManga': true,
    if (latestChapterTitle != null && latestChapterTitle!.isNotEmpty)
      'latestChapterTitle': latestChapterTitle,
    if (knownChapterCount > 0) 'knownChapterCount': knownChapterCount,
    if (unreadUpdateCount > 0) 'unreadUpdateCount': unreadUpdateCount,
    if (updatedAtMs > 0) 'updatedAtMs': updatedAtMs,
  };

  static OnlineBookOrigin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final sourceBaseUrl = '${raw['sourceBaseUrl'] ?? ''}'.trim();
    final bookUrl = '${raw['bookUrl'] ?? ''}'.trim();
    final title = '${raw['title'] ?? ''}'.trim();
    if (bookId is! int ||
        !isSourceNovelId(bookId) ||
        sourceBaseUrl.isEmpty ||
        bookUrl.isEmpty ||
        title.isEmpty) {
      return null;
    }
    try {
      NetworkUrlSafety.parsePublicHttpUrl(sourceBaseUrl, allowHttp: true);
      NetworkUrlSafety.parsePublicHttpUrl(bookUrl, allowHttp: true);
    } on FormatException {
      return null;
    }
    String? safeOptionalUrl(Object? val, {bool allowSpec = false}) {
      if (val is! String || val.trim().isEmpty) return null;
      if (allowSpec) {
        final spec = tryParseSourceImageSpec(val.trim(), allowHttp: true);
        return spec?.toRawSpec();
      }
      try {
        return NetworkUrlSafety.parsePublicHttpUrl(
          val.trim(),
          allowHttp: true,
        ).toString();
      } on FormatException {
        return null;
      }
    }

    return OnlineBookOrigin(
      bookId: bookId,
      sourceId: '${raw['sourceId'] ?? ''}'.trim(),
      sourceName: '${raw['sourceName'] ?? ''}'.trim(),
      sourceBaseUrl: sourceBaseUrl,
      bookUrl: bookUrl,
      title: title,
      author: '${raw['author'] ?? ''}'.trim(),
      genre: '${raw['genre'] ?? ''}'.trim(),
      summary: '${raw['summary'] ?? ''}'.trim(),
      tocUrl: safeOptionalUrl(raw['tocUrl']),
      coverUrl: safeOptionalUrl(raw['coverUrl'], allowSpec: true),
      isManga: raw['isManga'] == true,
      latestChapterTitle: raw['latestChapterTitle'] is String
          ? (raw['latestChapterTitle'] as String).trim()
          : null,
      knownChapterCount: raw['knownChapterCount'] is int
          ? (raw['knownChapterCount'] as int).clamp(0, 200000)
          : 0,
      unreadUpdateCount: raw['unreadUpdateCount'] is int
          ? (raw['unreadUpdateCount'] as int).clamp(0, 200000)
          : 0,
      updatedAtMs: raw['updatedAtMs'] is int ? raw['updatedAtMs'] as int : 0,
    );
  }

  static const List<(Color, Color)> _palettes = [
    (Color(0xFF5E87B8), Color(0xFF222C5B)),
    (Color(0xFF66C9BC), Color(0xFF276A8F)),
    (Color(0xFFD99B78), Color(0xFF6E3D3A)),
    (Color(0xFF88A47C), Color(0xFF2F4A3C)),
    (Color(0xFFB38CB4), Color(0xFF473154)),
    (Color(0xFFC9A96E), Color(0xFF5B4526)),
  ];

  Novel toNovel({List<NovelChapter> chapters = const []}) {
    final palette = _palettes[bookId.abs() % _palettes.length];
    final genreLabel = [
      if (isManga) '漫画',
      if (genre.trim().isNotEmpty) genre.trim(),
      if (sourceName.trim().isNotEmpty) sourceName.trim(),
    ].join(' · ');
    return Novel(
      id: bookId,
      title: title,
      author: author,
      genre: genreLabel,
      summary: summary,
      colors: [palette.$1, palette.$2],
      chapters: chapters,
      isManga: isManga,
      coverUrl: coverUrl,
      lastUpdate: latestChapterTitle,
      chapterCount: chapters.isNotEmpty ? chapters.length : knownChapterCount,
    );
  }
}

/// Persistent registry mapping `0x20000000..0x3fffffff` book IDs to their
/// [OnlineBookOrigin] and per-book chapter URL tables.
class OnlineBookOriginStore extends ChangeNotifier {
  OnlineBookOriginStore({
    Future<Directory> Function()? directoryProvider,
    BookSourceStore? sourceStore,
    this.enablePersistence = true,
  }) : _directoryProvider = directoryProvider,
       _sourceStore = sourceStore;

  static OnlineBookOriginStore shared = OnlineBookOriginStore();

  final Future<Directory> Function()? _directoryProvider;
  final BookSourceStore? _sourceStore;
  final bool enablePersistence;

  final Map<int, OnlineBookOrigin> _originsById = <int, OnlineBookOrigin>{};
  final Map<String, int> _idByUrlKey = <String, int>{};
  final Map<int, Map<int, String>> _chapterUrlsByBook =
      <int, Map<int, String>>{};

  Directory? _resolvedDir;
  bool _loaded = false;
  Future<void> _writeChain = Future<void>.value();

  bool get isLoaded => _loaded;
  Iterable<OnlineBookOrigin> get origins => _originsById.values;

  BookSourceStore get _effectiveSourceStore =>
      _sourceStore ?? BookSourceStore.shared;

  OnlineBookOrigin? byBookId(int bookId) => _originsById[bookId];

  /// Wires global image-header and purification-scope resolvers to this store.
  void bindGlobalResolvers() {
    SourceImageCache.shared.bookContextResolver = (bookId) {
      final origin = _originsById[bookId];
      if (origin == null) return (coverUrl: null, headers: const {});
      final src =
          _effectiveSourceStore.byId(origin.sourceId) ??
          _effectiveSourceStore.findByBaseUrl(origin.sourceBaseUrl);
      final baseHeaders = src != null
          ? _effectiveSourceStore.effectiveHeadersFor(src)
          : const <String, String>{};
      final merged = <String, String>{
        'Referer': origin.bookUrl,
        ...baseHeaders,
      };
      return (coverUrl: origin.coverUrl, headers: merged);
    };
    ReaderPurificationStore.shared.bookSourceUrlResolver =
        (bookId) => _originsById[bookId]?.sourceBaseUrl;
  }

  static String _urlIdentityKey(String sourceBaseUrl, String bookUrl) {
    var base = sourceBaseUrl.trim().toLowerCase();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    var target = bookUrl.trim();
    final parsed = Uri.tryParse(target);
    if (parsed != null && parsed.hasFragment) {
      target = parsed.removeFragment().toString();
    }
    return '$base\n$target';
  }

  static int _computeHashBookId(String key) {
    final digest = sha256.convert(utf8.encode(key)).bytes;
    final raw29 =
        ((digest[0] & 0x1f) << 24) |
        (digest[1] << 16) |
        (digest[2] << 8) |
        digest[3];
    return sourceNovelIdBase + raw29;
  }

  int _allocateOrFindBookId(String sourceBaseUrl, String bookUrl) {
    final key = _urlIdentityKey(sourceBaseUrl, bookUrl);
    final existing = _idByUrlKey[key];
    if (existing != null) return existing;

    var candidate = _computeHashBookId(key);
    while (_originsById.containsKey(candidate)) {
      final other = _originsById[candidate]!;
      if (_urlIdentityKey(other.sourceBaseUrl, other.bookUrl) == key) {
        _idByUrlKey[key] = candidate;
        return candidate;
      }
      candidate = candidate >= sourceNovelIdMax
          ? sourceNovelIdBase
          : candidate + 1;
    }
    return candidate;
  }

  Future<Directory> _dir() async {
    final existing = _resolvedDir;
    if (existing != null) return existing;
    final dir = _directoryProvider != null
        ? await _directoryProvider()
        : Directory(
            '${(await getApplicationSupportDirectory()).path}/sources',
          );
    await dir.create(recursive: true);
    _resolvedDir = dir;
    return dir;
  }

  Future<void> load() async {
    bindGlobalResolvers();
    _originsById.clear();
    _idByUrlKey.clear();
    _chapterUrlsByBook.clear();

    if (!enablePersistence) {
      _loaded = true;
      notifyListeners();
      return;
    }

    final dir = await _dir();
    final file = File('${dir.path}/online_book_origins_v1.json');

    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        final list = switch (decoded) {
          final Map m when m['origins'] is List => m['origins'] as List,
          final List l => l,
          _ => const <Object?>[],
        };
        for (final item in list) {
          final origin = OnlineBookOrigin.fromJson(item);
          if (origin == null) continue;
          _originsById[origin.bookId] = origin;
          _idByUrlKey[_urlIdentityKey(origin.sourceBaseUrl, origin.bookUrl)] =
              origin.bookId;
        }
      } catch (_) {}
    }

    _loaded = true;
    notifyListeners();
  }

  Future<void> _persistOrigins() {
    if (!enablePersistence) return Future<void>.value();
    _writeChain = _writeChain.catchError((Object _) {}).then((_) async {
      final dir = await _dir();
      final file = File('${dir.path}/online_book_origins_v1.json');
      final payload = jsonEncode({
        'version': 1,
        'origins': [for (final o in _originsById.values) o.toJson()],
      });
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(file.path);
    });
    return _writeChain;
  }

  /// Registers or updates an online book discovered via search/explore/detail.
  OnlineBookOrigin upsertDiscovered({
    required String sourceId,
    required String sourceName,
    required String sourceBaseUrl,
    required String bookUrl,
    required String title,
    String author = '',
    String genre = '',
    String summary = '',
    String? tocUrl,
    String? coverUrl,
    bool isManga = false,
    String? latestChapterTitle,
    int? knownChapterCount,
    bool persist = true,
  }) {
    final bookId = _allocateOrFindBookId(sourceBaseUrl, bookUrl);
    final prev = _originsById[bookId];
    final next = OnlineBookOrigin(
      bookId: bookId,
      sourceId: sourceId,
      sourceName: sourceName,
      sourceBaseUrl: sourceBaseUrl,
      bookUrl: bookUrl,
      title: title.trim().isNotEmpty ? title.trim() : (prev?.title ?? '未命名'),
      author: author.trim().isNotEmpty ? author.trim() : (prev?.author ?? ''),
      genre: genre.trim().isNotEmpty ? genre.trim() : (prev?.genre ?? ''),
      summary: summary.trim().isNotEmpty
          ? summary.trim()
          : (prev?.summary ?? ''),
      tocUrl: (tocUrl != null && tocUrl.trim().isNotEmpty)
          ? tocUrl.trim()
          : prev?.tocUrl,
      coverUrl: (coverUrl != null && coverUrl.trim().isNotEmpty)
          ? coverUrl.trim()
          : prev?.coverUrl,
      isManga: isManga || (prev?.isManga ?? false),
      latestChapterTitle:
          (latestChapterTitle != null && latestChapterTitle.trim().isNotEmpty)
          ? latestChapterTitle.trim()
          : prev?.latestChapterTitle,
      knownChapterCount: knownChapterCount ?? (prev?.knownChapterCount ?? 0),
      unreadUpdateCount: prev?.unreadUpdateCount ?? 0,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    _originsById[bookId] = next;
    _idByUrlKey[_urlIdentityKey(sourceBaseUrl, bookUrl)] = bookId;
    if (persist) {
      unawaited(_persistOrigins());
    }
    return next;
  }

  Future<void> updateOrigin(OnlineBookOrigin updated) async {
    final prev = _originsById[updated.bookId];
    if (prev != null) {
      _idByUrlKey.remove(_urlIdentityKey(prev.sourceBaseUrl, prev.bookUrl));
    }
    _originsById[updated.bookId] = updated;
    _idByUrlKey[_urlIdentityKey(updated.sourceBaseUrl, updated.bookUrl)] =
        updated.bookId;
    await _persistOrigins();
    notifyListeners();
  }

  /// Switches an existing [bookId] to a different book source while preserving
  /// its `bookId` (so shelf membership, tags, reading history, stats, and
  /// bookmarks all stay intact).
  Future<OnlineBookOrigin> switchBookSource({
    required int bookId,
    required String newSourceId,
    required String newSourceName,
    required String newSourceBaseUrl,
    required String newBookUrl,
    String? newTocUrl,
    String? newCoverUrl,
    String? newLatestChapterTitle,
    int? newChapterCount,
    Map<int, String>? newChapterUrls,
  }) async {
    final prev = _originsById[bookId];
    if (prev == null) {
      throw StateError('找不到原书籍来源记录');
    }
    _idByUrlKey.remove(_urlIdentityKey(prev.sourceBaseUrl, prev.bookUrl));
    final updated = prev.copyWith(
      sourceId: newSourceId,
      sourceName: newSourceName,
      sourceBaseUrl: newSourceBaseUrl,
      bookUrl: newBookUrl,
      tocUrl: newTocUrl ?? '',
      coverUrl: newCoverUrl ?? prev.coverUrl,
      latestChapterTitle: newLatestChapterTitle ?? prev.latestChapterTitle,
      knownChapterCount: newChapterCount ?? prev.knownChapterCount,
      unreadUpdateCount: 0,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _originsById[bookId] = updated;
    _idByUrlKey[_urlIdentityKey(newSourceBaseUrl, newBookUrl)] = bookId;
    if (newChapterUrls != null) {
      await saveChapterUrls(bookId, newChapterUrls);
    } else {
      _chapterUrlsByBook.remove(bookId);
    }
    await _persistOrigins();
    notifyListeners();
    return updated;
  }

  Future<void> clearUnreadUpdates(int bookId) async {
    final prev = _originsById[bookId];
    if (prev == null || prev.unreadUpdateCount == 0) return;
    _originsById[bookId] = prev.copyWith(unreadUpdateCount: 0);
    await _persistOrigins();
    notifyListeners();
  }

  Future<void> saveChapterUrls(int bookId, Map<int, String> urlsById) async {
    final unmodifiable = Map<int, String>.unmodifiable(urlsById);
    _chapterUrlsByBook[bookId] = unmodifiable;
    if (!enablePersistence) return;
    try {
      final dir = await _dir();
      final tocDir = Directory('${dir.path}/tocs');
      await tocDir.create(recursive: true);
      final target = File('${tocDir.path}/toc_$bookId.json');
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({for (final e in unmodifiable.entries) '${e.key}': e.value}),
        flush: true,
      );
      await tmp.rename(target.path);
    } catch (_) {}
  }

  Future<String?> resolveChapterUrl(int bookId, int chapterId) async {
    var map = _chapterUrlsByBook[bookId];
    if (map == null && enablePersistence) {
      try {
        final dir = await _dir();
        final file = File('${dir.path}/tocs/toc_$bookId.json');
        if (await file.exists()) {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            map = {
              for (final e in decoded.entries)
                if (int.tryParse('${e.key}') case final int cid)
                  if (e.value is String) cid: e.value as String,
            };
            _chapterUrlsByBook[bookId] = Map.unmodifiable(map);
          }
        }
      } catch (_) {}
    }
    return map?[chapterId];
  }

  List<Map<String, Object?>> exportForBackup({Set<int>? filterBookIds}) => [
    for (final origin in _originsById.values)
      if (filterBookIds == null || filterBookIds.contains(origin.bookId))
        origin.toJson(),
  ];

  Future<int> restoreFromBackup(List<Object?> rawOrigins) async {
    var count = 0;
    for (final item in rawOrigins) {
      final origin = OnlineBookOrigin.fromJson(item);
      if (origin == null) continue;
      final existing = _originsById[origin.bookId];
      if (existing != null) {
        if (existing.updatedAtMs >= origin.updatedAtMs &&
            existing.updatedAtMs > 0) {
          continue;
        }
        _idByUrlKey.remove(
          _urlIdentityKey(existing.sourceBaseUrl, existing.bookUrl),
        );
      }
      _originsById[origin.bookId] = origin;
      _idByUrlKey[_urlIdentityKey(origin.sourceBaseUrl, origin.bookUrl)] =
          origin.bookId;
      count++;
    }
    if (count > 0) {
      await _persistOrigins();
      notifyListeners();
    }
    return count;
  }

  Future<void> flush() => _persistOrigins();
}
