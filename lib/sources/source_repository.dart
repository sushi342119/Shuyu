import 'dart:async';
import 'dart:collection';

import '../catalog.dart';
import '../local_library.dart' show isSourceNovelId;
import 'book_source.dart';
import 'book_source_store.dart';
import 'chapter_normalizer.dart';
import 'online_book_origins.dart';
import 'rule_engine.dart';
import 'source_http.dart';

class SourceSearchBatch {
  const SourceSearchBatch({
    required this.source,
    required this.items,
    required this.completedSources,
    required this.totalSources,
    this.error,
  });

  final BookSource source;
  final List<Novel> items;
  final int completedSources;
  final int totalSources;
  final Object? error;
}

class SourceDebugStep {
  const SourceDebugStep({
    required this.stage,
    required this.success,
    required this.elapsedMs,
    required this.summary,
    this.detail = '',
  });

  final String stage;
  final bool success;
  final int elapsedMs;
  final String summary;
  final String detail;
}

class SourceSwitchCandidate {
  const SourceSwitchCandidate({
    required this.source,
    required this.item,
  });

  final BookSource source;
  final ExtractedBookItem item;
}

class _CachedPageHtml {
  const _CachedPageHtml(this.finalUrl, this.body, this.fetchedAt);
  final String finalUrl;
  final String body;
  final DateTime fetchedAt;
}

/// Unwraps [SourceNovelRepository] through repository decorators (`Composite`,
/// `Offline`, `RemoteRouter`).
SourceNovelRepository? sourceRepositoryOf(NovelRepository? repository) {
  var current = repository;
  var depth = 0;
  while (current != null && depth < 10) {
    if (current is SourceNovelRepository) return current;
    if (current is RemoteRouterRepository) return current.sources;
    current = current.remoteRepository;
    depth++;
  }
  return null;
}

/// Executes book-source search, category explore, book detail, multi-page TOC,
/// multi-page chapter/manga content, update checks, and source switching.
class SourceNovelRepository extends NovelRepository {
  SourceNovelRepository({
    BookSourceStore? sourceStore,
    OnlineBookOriginStore? originStore,
    SourceHttpClient? httpClient,
    this.maxConcurrentSearches = 4,
    this.maxTocPages = 200,
    this.maxContentPages = 30,
  }) : sourceStore = sourceStore ?? BookSourceStore.shared,
       originStore = originStore ?? OnlineBookOriginStore.shared,
       httpClient = httpClient ?? SourceHttpClient.shared;

  final BookSourceStore sourceStore;
  final OnlineBookOriginStore originStore;
  final SourceHttpClient httpClient;
  final int maxConcurrentSearches;
  final int maxTocPages;
  final int maxContentPages;

  final LinkedHashMap<String, _CachedPageHtml> _recentDetailPages =
      LinkedHashMap<String, _CachedPageHtml>();

  void _rememberDetailHtml(String requestUrl, String finalUrl, String body) {
    _recentDetailPages.remove(requestUrl);
    _recentDetailPages[requestUrl] = _CachedPageHtml(
      finalUrl,
      body,
      DateTime.now(),
    );
    while (_recentDetailPages.length > 16) {
      _recentDetailPages.remove(_recentDetailPages.keys.first);
    }
  }

  _CachedPageHtml? _takeFreshDetailHtml(String url) {
    final entry = _recentDetailPages[url];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.fetchedAt) >
        const Duration(seconds: 45)) {
      _recentDetailPages.remove(url);
      return null;
    }
    return entry;
  }

  BookSource _resolveSourceForOrigin(OnlineBookOrigin origin) {
    final found =
        sourceStore.byId(origin.sourceId) ??
        sourceStore.findByBaseUrl(origin.sourceBaseUrl);
    if (found == null) {
      throw StateError(
        '未找到书源「${origin.sourceName.isEmpty ? origin.sourceBaseUrl : origin.sourceName}」，请在设置中导入该书源或使用换源',
      );
    }
    if (!found.compatibility.canEnable) {
      throw StateError('书源「${found.name}」依赖动态脚本，当前不支持抓取');
    }
    return sourceStore.hydrated(found);
  }

  @override
  Future<List<Novel>> list() async => (await browse()).items;

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) async {
    final exploreSources = sourceStore.activeExploreSources;
    if (exploreSources.isEmpty) {
      return NovelPage(items: const [], page: page, totalPages: 1);
    }
    final firstSource = exploreSources.first;
    final firstKind = firstSource.exploreKinds.first;
    return browseExplore(firstSource, firstKind, page: page);
  }

  /// Fetches a specific category/ranking feed from a single [BookSource].
  Future<NovelPage> browseExplore(
    BookSource rawSource,
    SourceExploreKind kind, {
    int page = 1,
  }) async {
    final source = sourceStore.hydrated(rawSource);
    final req = source.buildRequest(kind.url, page: page);
    final resp = await httpClient.send(
      req,
      minIntervalMs: source.minIntervalMs,
      rateKey: source.id,
    );
    final items = await SourceRuleEngine.parseBookList(
      body: resp.body,
      baseUrl: resp.finalUri.toString(),
      rule: source.effectiveExploreRule,
    );
    final novels = <Novel>[];
    for (final item in items) {
      final origin = originStore.upsertDiscovered(
        sourceId: source.id,
        sourceName: source.name,
        sourceBaseUrl: source.baseUrl,
        bookUrl: item.bookUrl,
        title: item.title,
        author: item.author,
        genre: item.genre,
        summary: item.summary,
        coverUrl: item.coverUrl,
        isManga: source.isManga,
        latestChapterTitle: item.latestChapter,
        persist: false,
      );
      novels.add(origin.toNovel());
    }
    if (novels.isNotEmpty) {
      unawaited(originStore.flush());
    }
    return NovelPage(
      items: List.unmodifiable(novels),
      page: page,
      totalPages: novels.isEmpty ? page : null,
    );
  }

  /// Streams search results progressively across active book sources with
  /// bounded concurrency (`maxConcurrentSearches`).
  Stream<SourceSearchBatch> searchStream(
    String query, {
    int page = 1,
    String? onlySourceId,
    SourceContentType? contentTypeFilter,
  }) {
    final keyword = query.trim();
    final controller = StreamController<SourceSearchBatch>();
    if (keyword.isEmpty) {
      controller.close();
      return controller.stream;
    }

    var candidates = sourceStore.activeSearchSources;
    if (onlySourceId != null && onlySourceId.isNotEmpty) {
      final single = sourceStore.byId(onlySourceId);
      candidates = single != null && single.canSearch ? [single] : const [];
    }
    if (contentTypeFilter != null) {
      candidates = candidates
          .where((s) => s.contentType == contentTypeFilter)
          .toList(growable: false);
    }

    if (candidates.isEmpty) {
      controller.close();
      return controller.stream;
    }

    var nextIndex = 0;
    var completed = 0;
    var cancelled = false;
    final total = candidates.length;

    controller.onCancel = () {
      cancelled = true;
    };

    Future<void> worker() async {
      while (!cancelled) {
        if (nextIndex >= total) return;
        final rawSource = candidates[nextIndex++];
        final source = sourceStore.hydrated(rawSource);
        try {
          final novels = await _searchSingleSource(
            source,
            keyword,
            page: page,
          );
          completed++;
          if (!cancelled && !controller.isClosed) {
            controller.add(
              SourceSearchBatch(
                source: rawSource,
                items: novels,
                completedSources: completed,
                totalSources: total,
              ),
            );
          }
        } catch (error) {
          completed++;
          if (!cancelled && !controller.isClosed) {
            controller.add(
              SourceSearchBatch(
                source: rawSource,
                items: const [],
                completedSources: completed,
                totalSources: total,
                error: error,
              ),
            );
          }
        }
      }
    }

    final workerCount = total < maxConcurrentSearches
        ? total
        : maxConcurrentSearches;
    Future.wait([for (var i = 0; i < workerCount; i++) worker()]).whenComplete(
      () {
        unawaited(originStore.flush());
        if (!controller.isClosed) {
          controller.close();
        }
      },
    );

    return controller.stream;
  }

  Future<List<Novel>> _searchSingleSource(
    BookSource hydratedSource,
    String keyword, {
    int page = 1,
  }) async {
    final req = hydratedSource.buildRequest(
      hydratedSource.searchUrl,
      keyword: keyword,
      page: page,
    );
    final resp = await httpClient.send(
      req,
      minIntervalMs: hydratedSource.minIntervalMs,
      rateKey: hydratedSource.id,
    );

    // Some sites redirect a single exact search match directly to the book detail page!
    final items = await SourceRuleEngine.parseBookList(
      body: resp.body,
      baseUrl: resp.finalUri.toString(),
      rule: hydratedSource.ruleSearch,
    );

    if (items.isEmpty && hydratedSource.ruleBookInfo.name.isNotEmpty) {
      final directDetail = await SourceRuleEngine.parseBookDetail(
        body: resp.body,
        pageUrl: resp.finalUri.toString(),
        rule: hydratedSource.ruleBookInfo,
      );
      if (directDetail.title != null && directDetail.title!.isNotEmpty) {
        final origin = originStore.upsertDiscovered(
          sourceId: hydratedSource.id,
          sourceName: hydratedSource.name,
          sourceBaseUrl: hydratedSource.baseUrl,
          bookUrl: resp.finalUri.toString(),
          title: directDetail.title!,
          author: directDetail.author ?? '',
          genre: directDetail.genre ?? '',
          summary: directDetail.summary ?? '',
          tocUrl: directDetail.tocUrl,
          coverUrl: directDetail.coverUrl,
          isManga: hydratedSource.isManga,
          latestChapterTitle: directDetail.latestChapter,
          persist: false,
        );
        _rememberDetailHtml(
          origin.bookUrl,
          resp.finalUri.toString(),
          resp.body,
        );
        return [origin.toNovel()];
      }
    }

    final novels = <Novel>[];
    for (final item in items) {
      final origin = originStore.upsertDiscovered(
        sourceId: hydratedSource.id,
        sourceName: hydratedSource.name,
        sourceBaseUrl: hydratedSource.baseUrl,
        bookUrl: item.bookUrl,
        title: item.title,
        author: item.author,
        genre: item.genre,
        summary: item.summary,
        coverUrl: item.coverUrl,
        isManga: hydratedSource.isManga,
        latestChapterTitle: item.latestChapter,
        persist: false,
      );
      novels.add(origin.toNovel());
    }
    return novels;
  }

  @override
  Future<List<Novel>> search(String query) async =>
      (await searchPage(query)).items;

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      return NovelPage(items: const [], page: page, totalPages: 1);
    }

    final collected = <Novel>[];
    final seenIds = <int>{};
    Object? firstError;
    var anySuccess = false;

    await for (final batch in searchStream(keyword, page: page)) {
      if (batch.error == null) {
        anySuccess = true;
      } else {
        firstError ??= batch.error;
      }
      for (final book in batch.items) {
        if (seenIds.add(book.id)) {
          collected.add(book);
        }
      }
    }

    if (collected.isEmpty && !anySuccess && firstError != null) {
      Error.throwWithStackTrace(firstError, StackTrace.current);
    }

    final lowerNeedle = keyword.toLowerCase();
    int scoreOf(Novel n) {
      final t = n.title.trim().toLowerCase();
      final a = n.author.trim().toLowerCase();
      if (t == lowerNeedle) return 0;
      if (t.startsWith(lowerNeedle)) return 1;
      if (t.contains(lowerNeedle)) return 2;
      if (a == lowerNeedle || a.contains(lowerNeedle)) return 3;
      return 4;
    }

    collected.sort((a, b) => scoreOf(a).compareTo(scoreOf(b)));
    return NovelPage(
      items: List.unmodifiable(collected),
      page: page,
      totalPages: collected.isEmpty ? page : null,
    );
  }

  @override
  Future<Novel?> find(int id) async {
    if (!isSourceNovelId(id)) return null;
    final origin = originStore.byBookId(id);
    return origin?.toNovel();
  }

  @override
  Future<Novel> detail(Novel novel) async {
    var origin = originStore.byBookId(novel.id);
    if (origin == null) {
      throw StateError('未找到该在线书籍的书源记录');
    }
    final source = _resolveSourceForOrigin(origin);
    final req = source.buildRequest(
      origin.bookUrl,
      baseOverride: source.baseUrl,
    );
    final resp = await httpClient.send(
      req,
      minIntervalMs: source.minIntervalMs,
      rateKey: source.id,
    );
    _rememberDetailHtml(origin.bookUrl, resp.finalUri.toString(), resp.body);

    final parsed = await SourceRuleEngine.parseBookDetail(
      body: resp.body,
      pageUrl: resp.finalUri.toString(),
      rule: source.ruleBookInfo,
    );

    origin = originStore.upsertDiscovered(
      sourceId: source.id,
      sourceName: source.name,
      sourceBaseUrl: source.baseUrl,
      bookUrl: origin.bookUrl,
      title: parsed.title ?? origin.title,
      author: parsed.author ?? origin.author,
      genre: parsed.genre ?? origin.genre,
      summary: parsed.summary ?? origin.summary,
      tocUrl: parsed.tocUrl ?? origin.tocUrl,
      coverUrl: parsed.coverUrl ?? origin.coverUrl,
      isManga: source.isManga || origin.isManga,
      latestChapterTitle: parsed.latestChapter ?? origin.latestChapterTitle,
    );
    return origin.toNovel(chapters: novel.chapters);
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    final origin = originStore.byBookId(id);
    if (origin == null) {
      throw StateError('未找到该在线书籍的书源记录');
    }
    final source = _resolveSourceForOrigin(origin);
    final entries = await _fetchNormalizedToc(source, origin);

    final urlsById = <int, String>{
      for (final e in entries) e.chapter.id: e.url,
    };
    await originStore.saveChapterUrls(id, urlsById);

    final chapters = [for (final e in entries) e.chapter];
    final latestTitle = chapters.isNotEmpty
        ? chapters.last.title
        : origin.latestChapterTitle;
    await originStore.updateOrigin(
      origin.copyWith(
        knownChapterCount: chapters.length,
        latestChapterTitle: latestTitle,
        unreadUpdateCount: 0,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return List.unmodifiable(chapters);
  }

  Future<List<NormalizedChapterEntry>> _fetchNormalizedToc(
    BookSource hydratedSource,
    OnlineBookOrigin origin,
  ) async {
    var currentUrl = (origin.tocUrl != null && origin.tocUrl!.isNotEmpty)
        ? origin.tocUrl!
        : origin.bookUrl;

    final rawChapters = <RawExtractedChapter>[];
    final visitedUrls = <String>{};

    for (var pageIdx = 0; pageIdx < maxTocPages; pageIdx++) {
      if (!visitedUrls.add(currentUrl)) break;

      String body;
      String effectivePageUrl;

      final cached = pageIdx == 0 ? _takeFreshDetailHtml(currentUrl) : null;
      if (cached != null) {
        body = cached.body;
        effectivePageUrl = cached.finalUrl;
      } else {
        final req = hydratedSource.buildRequest(
          currentUrl,
          baseOverride: origin.bookUrl,
        );
        final resp = await httpClient.send(
          req,
          minIntervalMs: hydratedSource.minIntervalMs,
          rateKey: hydratedSource.id,
        );
        body = resp.body;
        effectivePageUrl = resp.finalUri.toString();
      }

      // If `tocUrl` was not yet resolved on `origin` and `ruleBookInfo.tocUrl`
      // is configured, extract it on page 0 first!
      if (pageIdx == 0 &&
          (origin.tocUrl == null || origin.tocUrl!.isEmpty) &&
          hydratedSource.ruleBookInfo.tocUrl.trim().isNotEmpty) {
        final detailInfo = await SourceRuleEngine.parseBookDetail(
          body: body,
          pageUrl: effectivePageUrl,
          rule: hydratedSource.ruleBookInfo,
        );
        if (detailInfo.tocUrl != null &&
            detailInfo.tocUrl!.isNotEmpty &&
            detailInfo.tocUrl != currentUrl) {
          currentUrl = detailInfo.tocUrl!;
          visitedUrls.remove(origin.bookUrl);
          continue;
        }
      }

      final tocPage = await SourceRuleEngine.parseTocPage(
        body: body,
        pageUrl: effectivePageUrl,
        rule: hydratedSource.ruleToc,
      );
      rawChapters.addAll(tocPage.chapters);

      final next = tocPage.nextTocUrl;
      if (next == null || next.isEmpty || visitedUrls.contains(next)) {
        break;
      }
      currentUrl = next;
    }

    return ChapterNormalizer.normalize(
      rawChapters,
      reverseMode: hydratedSource.ruleToc.reverse,
    );
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    final origin = originStore.byBookId(novelId);
    if (origin == null) {
      throw StateError('未找到该在线书籍的书源记录');
    }
    final source = _resolveSourceForOrigin(origin);

    var targetUrl = await originStore.resolveChapterUrl(novelId, chapter.id);
    if (targetUrl == null || targetUrl.isEmpty) {
      await chapters(novelId);
      targetUrl = await originStore.resolveChapterUrl(novelId, chapter.id);
    }
    if (targetUrl == null || targetUrl.isEmpty) {
      throw const FormatException('未找到该章节的源站链接，请刷新目录后重试');
    }

    return _fetchChapterBodyFromUrl(
      source: source,
      initialChapterUrl: targetUrl,
      chapterTitle: chapter.title,
      baseBookUrl: origin.bookUrl,
    );
  }

  Future<String> _fetchChapterBodyFromUrl({
    required BookSource source,
    required String initialChapterUrl,
    required String chapterTitle,
    required String baseBookUrl,
  }) async {
    var currentUrl = initialChapterUrl;
    final visited = <String>{};
    final parts = <String>[];
    final seenMangaImages = <String>{};

    for (var pageIdx = 0; pageIdx < maxContentPages; pageIdx++) {
      if (!visited.add(currentUrl)) break;
      final req = source.buildRequest(
        currentUrl,
        baseOverride: baseBookUrl,
      );
      final resp = await httpClient.send(
        req,
        minIntervalMs: source.minIntervalMs,
        rateKey: source.id,
      );
      final page = await SourceRuleEngine.parseChapterPage(
        body: resp.body,
        pageUrl: resp.finalUri.toString(),
        rule: source.ruleContent,
        contentType: source.contentType,
      );

      if (source.isManga) {
        for (final line in page.body.split('\n\n')) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty && seenMangaImages.add(trimmed)) {
            parts.add(trimmed);
          }
        }
      } else {
        var chunk = page.body.trim();
        if (chunk.isNotEmpty) {
          chunk = _stripLeadingDuplicateHeading(chunk, chapterTitle);
          if (chunk.isNotEmpty) parts.add(chunk);
        }
      }

      final next = page.nextContentUrl;
      if (next == null || next.isEmpty || visited.contains(next)) {
        break;
      }
      // Guard against sites whose "下一章" link shares a selector with "下一页":
      // sub-pages of the same chapter almost always share the chapter stem
      // (e.g. `1001.html` -> `1001_2.html` or `?page=2`).
      if (!_looksLikeSameChapterSubpage(initialChapterUrl, next)) {
        break;
      }
      currentUrl = next;
    }

    final joined = parts.join('\n\n').trim();
    if (joined.isEmpty) {
      throw FormatException(
        source.isManga
            ? '未提取到漫画章节图片（可能需配置 Cookie 或该源图床已变更）'
            : '未提取到章节正文内容',
      );
    }
    return joined;
  }

  static bool _looksLikeSameChapterSubpage(String firstUrl, String candidate) {
    final u1 = Uri.tryParse(firstUrl);
    final u2 = Uri.tryParse(candidate);
    if (u1 == null || u2 == null) return false;
    if (u1.host.toLowerCase() != u2.host.toLowerCase()) return false;
    if (u1.path == u2.path && u1.query != u2.query) return true;

    String stem(String p) =>
        p.replaceFirst(RegExp(r'\.[a-zA-Z0-9]{1,6}$'), '');
    final s1 = stem(u1.path);
    final s2 = stem(u2.path);
    if (s2.startsWith('${s1}_') ||
        s2.startsWith('$s1-') ||
        s2.startsWith('$s1/')) {
      return true;
    }
    return false;
  }

  static String _stripLeadingDuplicateHeading(String chunk, String title) {
    final cleanTitle = title.replaceAll(RegExp(r'\s+'), '');
    if (cleanTitle.isEmpty) return chunk;
    final paragraphs = chunk.split('\n\n');
    if (paragraphs.length <= 1) return chunk;
    final firstClean = paragraphs.first
        .replaceAll(RegExp(r'[\s（(]\d+\s*/\s*\d+[)）]'), '')
        .replaceAll(RegExp(r'\s+'), '');
    if (firstClean == cleanTitle ||
        (firstClean.length < cleanTitle.length + 8 &&
            firstClean.startsWith(cleanTitle))) {
      return paragraphs.sublist(1).join('\n\n').trim();
    }
    return chunk;
  }

  /// Checks TOC updates for online shelf books (`isSourceNovelId`) with bounded
  /// concurrency and updates `unreadUpdateCount` + `latestChapterTitle`.
  Future<({int checked, int updatedBooks, int newChapters})> checkShelfUpdates(
    Iterable<int> bookIds,
  ) async {
    final ids = bookIds.where(isSourceNovelId).toList(growable: false);
    if (ids.isEmpty) return (checked: 0, updatedBooks: 0, newChapters: 0);

    var index = 0;
    var checked = 0;
    var updatedBooks = 0;
    var totalNewChapters = 0;

    Future<void> worker() async {
      while (index < ids.length) {
        final bookId = ids[index++];
        final origin = originStore.byBookId(bookId);
        if (origin == null) continue;
        try {
          final source = _resolveSourceForOrigin(origin);
          final entries = await _fetchNormalizedToc(source, origin);
          checked++;
          if (entries.isEmpty) continue;
          final urlsById = <int, String>{
            for (final e in entries) e.chapter.id: e.url,
          };
          await originStore.saveChapterUrls(bookId, urlsById);
          final prevCount = origin.knownChapterCount;
          final delta = prevCount > 0 && entries.length > prevCount
              ? entries.length - prevCount
              : 0;
          if (delta > 0) {
            updatedBooks++;
            totalNewChapters += delta;
          }
          await originStore.updateOrigin(
            origin.copyWith(
              knownChapterCount: entries.length,
              latestChapterTitle: entries.last.chapter.title,
              unreadUpdateCount: origin.unreadUpdateCount + delta,
              updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        } catch (_) {
          // Individual source failures never abort checking remaining shelf books.
        }
      }
    }

    final workers = ids.length < 3 ? ids.length : 3;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return (
      checked: checked,
      updatedBooks: updatedBooks,
      newChapters: totalNewChapters,
    );
  }

  /// Searches other enabled book sources of the same content type for [bookId]
  /// so the user can switch sources (`换源`) when a site goes down or lags.
  Future<List<SourceSwitchCandidate>> findAlternativeSources(int bookId) async {
    final origin = originStore.byBookId(bookId);
    if (origin == null) return const [];
    final targetType = origin.isManga
        ? SourceContentType.manga
        : SourceContentType.text;

    final sources = sourceStore.activeSearchSources
        .where(
          (s) => s.contentType == targetType && s.id != origin.sourceId,
        )
        .toList(growable: false);
    if (sources.isEmpty) return const [];

    final matches = <SourceSwitchCandidate>[];
    var idx = 0;

    Future<void> worker() async {
      while (idx < sources.length) {
        final rawSource = sources[idx++];
        final source = sourceStore.hydrated(rawSource);
        try {
          final req = source.buildRequest(
            source.searchUrl,
            keyword: origin.title,
            page: 1,
          );
          final resp = await httpClient.send(
            req,
            minIntervalMs: source.minIntervalMs,
            rateKey: source.id,
          );
          final items = await SourceRuleEngine.parseBookList(
            body: resp.body,
            baseUrl: resp.finalUri.toString(),
            rule: source.ruleSearch,
          );
          for (final item in items) {
            if (_isLikelySameBook(origin, item)) {
              matches.add(SourceSwitchCandidate(source: rawSource, item: item));
              break;
            }
          }
        } catch (_) {}
      }
    }

    final workers = sources.length < 4 ? sources.length : 4;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return matches;
  }

  static bool _isLikelySameBook(
    OnlineBookOrigin origin,
    ExtractedBookItem candidate,
  ) {
    final t1 = origin.title.trim().toLowerCase();
    final t2 = candidate.title.trim().toLowerCase();
    if (t1 == t2) return true;
    if (t2.contains(t1) || t1.contains(t2)) {
      if (origin.author.isEmpty || candidate.author.isEmpty) return true;
      return candidate.author.trim().toLowerCase() ==
          origin.author.trim().toLowerCase();
    }
    return false;
  }

  /// Switches [bookId] to [candidate] and fetches the new source's TOC,
  /// returning `(novel, alignedChapterIndex)` aligned to [previousChapterTitle].
  Future<({Novel novel, List<NovelChapter> chapters, int alignedIndex})>
  switchSourceForBook(
    int bookId,
    SourceSwitchCandidate candidate, {
    String? previousChapterTitle,
    int previousChapterIndex = 0,
  }) async {
    final hydrated = sourceStore.hydrated(candidate.source);
    String? tocUrl;
    String? coverUrl = candidate.item.coverUrl;
    String? latest = candidate.item.latestChapter;

    try {
      final detailReq = hydrated.buildRequest(
        candidate.item.bookUrl,
        baseOverride: hydrated.baseUrl,
      );
      final detailResp = await httpClient.send(
        detailReq,
        minIntervalMs: hydrated.minIntervalMs,
        rateKey: hydrated.id,
      );
      _rememberDetailHtml(
        candidate.item.bookUrl,
        detailResp.finalUri.toString(),
        detailResp.body,
      );
      final info = await SourceRuleEngine.parseBookDetail(
        body: detailResp.body,
        pageUrl: detailResp.finalUri.toString(),
        rule: hydrated.ruleBookInfo,
      );
      tocUrl = info.tocUrl;
      coverUrl = info.coverUrl ?? coverUrl;
      latest = info.latestChapter ?? latest;
    } catch (_) {}

    final tempOrigin = OnlineBookOrigin(
      bookId: bookId,
      sourceId: hydrated.id,
      sourceName: hydrated.name,
      sourceBaseUrl: hydrated.baseUrl,
      bookUrl: candidate.item.bookUrl,
      title: candidate.item.title,
      author: candidate.item.author,
      tocUrl: tocUrl,
      coverUrl: coverUrl,
      isManga: hydrated.isManga,
      latestChapterTitle: latest,
    );

    final entries = await _fetchNormalizedToc(hydrated, tempOrigin);
    if (entries.isEmpty) {
      throw const FormatException('目标书源目录为空，无法切换到该书源');
    }

    final urlsById = <int, String>{
      for (final e in entries) e.chapter.id: e.url,
    };
    final chapters = [for (final e in entries) e.chapter];
    final updatedOrigin = await originStore.switchBookSource(
      bookId: bookId,
      newSourceId: hydrated.id,
      newSourceName: hydrated.name,
      newSourceBaseUrl: hydrated.baseUrl,
      newBookUrl: candidate.item.bookUrl,
      newTocUrl: tocUrl,
      newCoverUrl: coverUrl,
      newLatestChapterTitle: chapters.last.title,
      newChapterCount: chapters.length,
      newChapterUrls: urlsById,
    );

    final aligned = alignChapterIndex(
      chapters,
      previousTitle: previousChapterTitle,
      fallbackIndex: previousChapterIndex,
    );
    final fullNovel = updatedOrigin.toNovel(chapters: chapters);
    return (novel: fullNovel, chapters: chapters, alignedIndex: aligned);
  }

  static int alignChapterIndex(
    List<NovelChapter> chapters, {
    String? previousTitle,
    int fallbackIndex = 0,
  }) {
    if (chapters.isEmpty) return 0;
    if (previousTitle != null && previousTitle.trim().isNotEmpty) {
      String norm(String s) =>
          s.replaceAll(RegExp(r'[\s·:：\-—_（）()【】\[\]]+'), '').toLowerCase();
      final targetNorm = norm(previousTitle);
      for (var i = 0; i < chapters.length; i++) {
        if (norm(chapters[i].title) == targetNorm) return i;
      }
      final targetNo = ChapterNormalizer.extractChapterNumber(previousTitle);
      if (targetNo != null) {
        for (var i = 0; i < chapters.length; i++) {
          if (ChapterNormalizer.extractChapterNumber(chapters[i].title) ==
              targetNo) {
            return i;
          }
        }
      }
    }
    return fallbackIndex.clamp(0, chapters.length - 1);
  }

  /// Runs a step-by-step diagnostic pipeline (`搜索/分类` -> `详情` -> `目录` -> `正文/图片`)
  /// on [rawSource] without polluting user shelf state.
  Future<List<SourceDebugStep>> debugSourcePipeline(
    BookSource rawSource, {
    String keyword = '我的',
  }) async {
    final steps = <SourceDebugStep>[];
    final source = sourceStore.hydrated(rawSource);

    if (!source.compatibility.canEnable) {
      steps.add(
        SourceDebugStep(
          stage: '兼容性检查',
          success: false,
          elapsedMs: 0,
          summary: source.compatibility.label,
          detail: source.compatibilityNotes.join('\n'),
        ),
      );
      return steps;
    }

    // Step 1: Search or Explore
    ExtractedBookItem? sampleBook;
    final sw1 = Stopwatch()..start();
    try {
      if (source.canSearch) {
        final req = source.buildRequest(source.searchUrl, keyword: keyword);
        final resp = await httpClient.send(
          req,
          minIntervalMs: 0,
          rateKey: 'debug_${source.id}',
        );
        final list = await SourceRuleEngine.parseBookList(
          body: resp.body,
          baseUrl: resp.finalUri.toString(),
          rule: source.ruleSearch,
        );
        sw1.stop();
        if (list.isEmpty) {
          steps.add(
            SourceDebugStep(
              stage: '1. 搜索测试（「$keyword」）',
              success: false,
              elapsedMs: sw1.elapsedMilliseconds,
              summary: 'HTTP ${resp.statusCode}，但未匹配到书籍列表',
              detail: '请求地址：${resp.finalUri}',
            ),
          );
          return steps;
        }
        sampleBook = list.first;
        steps.add(
          SourceDebugStep(
            stage: '1. 搜索测试（「$keyword」）',
            success: true,
            elapsedMs: sw1.elapsedMilliseconds,
            summary: '找到 ${list.length} 本，首本《${sampleBook.title}》',
            detail:
                '作者：${sampleBook.author.isEmpty ? "未知" : sampleBook.author}\n地址：${sampleBook.bookUrl}',
          ),
        );
      } else if (source.exploreKinds.isNotEmpty) {
        final firstKind = source.exploreKinds.first;
        final req = source.buildRequest(firstKind.url, page: 1);
        final resp = await httpClient.send(
          req,
          minIntervalMs: 0,
          rateKey: 'debug_${source.id}',
        );
        final list = await SourceRuleEngine.parseBookList(
          body: resp.body,
          baseUrl: resp.finalUri.toString(),
          rule: source.effectiveExploreRule,
        );
        sw1.stop();
        if (list.isEmpty) {
          steps.add(
            SourceDebugStep(
              stage: '1. 分类测试（「${firstKind.title}」）',
              success: false,
              elapsedMs: sw1.elapsedMilliseconds,
              summary: '未解析到分类书籍列表',
              detail: '请求地址：${resp.finalUri}',
            ),
          );
          return steps;
        }
        sampleBook = list.first;
        steps.add(
          SourceDebugStep(
            stage: '1. 分类测试（「${firstKind.title}」）',
            success: true,
            elapsedMs: sw1.elapsedMilliseconds,
            summary: '找到 ${list.length} 本，首本《${sampleBook.title}》',
            detail: '地址：${sampleBook.bookUrl}',
          ),
        );
      } else {
        steps.add(
          const SourceDebugStep(
            stage: '1. 入口检查',
            success: false,
            elapsedMs: 0,
            summary: '该书源既无可用搜索规则也无发现分类',
          ),
        );
        return steps;
      }
    } catch (error) {
      sw1.stop();
      steps.add(
        SourceDebugStep(
          stage: '1. 搜索/分类请求',
          success: false,
          elapsedMs: sw1.elapsedMilliseconds,
          summary: '请求失败：$error',
        ),
      );
      return steps;
    }

    // Step 2: Detail
    String? tocUrl;
    String detailHtml = '';
    String detailFinalUrl = sampleBook.bookUrl;
    final sw2 = Stopwatch()..start();
    try {
      final req = source.buildRequest(
        sampleBook.bookUrl,
        baseOverride: source.baseUrl,
      );
      final resp = await httpClient.send(
        req,
        minIntervalMs: 0,
        rateKey: 'debug_${source.id}',
      );
      detailHtml = resp.body;
      detailFinalUrl = resp.finalUri.toString();
      final detail = await SourceRuleEngine.parseBookDetail(
        body: detailHtml,
        pageUrl: detailFinalUrl,
        rule: source.ruleBookInfo,
      );
      tocUrl = detail.tocUrl;
      sw2.stop();
      steps.add(
        SourceDebugStep(
          stage: '2. 详情解析',
          success: true,
          elapsedMs: sw2.elapsedMilliseconds,
          summary: '《${detail.title ?? sampleBook.title}》',
          detail: [
            if (detail.author != null) '作者：${detail.author}',
            if (detail.latestChapter != null) '最新：${detail.latestChapter}',
            if (detail.coverUrl != null) '封面：${detail.coverUrl}',
            if (tocUrl != null) '目录页：$tocUrl',
          ].join('\n'),
        ),
      );
    } catch (error) {
      sw2.stop();
      steps.add(
        SourceDebugStep(
          stage: '2. 详情解析',
          success: false,
          elapsedMs: sw2.elapsedMilliseconds,
          summary: '详情获取失败：$error',
        ),
      );
      return steps;
    }

    // Step 3: TOC (first page for fast diagnostics)
    NormalizedChapterEntry? firstChapter;
    final sw3 = Stopwatch()..start();
    try {
      String tocBody = detailHtml;
      String tocPageUrl = detailFinalUrl;
      if (tocUrl != null && tocUrl.isNotEmpty && tocUrl != sampleBook.bookUrl) {
        final tocReq = source.buildRequest(
          tocUrl,
          baseOverride: detailFinalUrl,
        );
        final tocResp = await httpClient.send(
          tocReq,
          minIntervalMs: 0,
          rateKey: 'debug_${source.id}',
        );
        tocBody = tocResp.body;
        tocPageUrl = tocResp.finalUri.toString();
      }
      final tocPage = await SourceRuleEngine.parseTocPage(
        body: tocBody,
        pageUrl: tocPageUrl,
        rule: source.ruleToc,
      );
      final normalized = ChapterNormalizer.normalize(
        tocPage.chapters,
        reverseMode: source.ruleToc.reverse,
      );
      sw3.stop();
      if (normalized.isEmpty) {
        steps.add(
          SourceDebugStep(
            stage: '3. 目录提取',
            success: false,
            elapsedMs: sw3.elapsedMilliseconds,
            summary: '提取到 0 个有效章节',
            detail: '目录地址：$tocPageUrl',
          ),
        );
        return steps;
      }
      firstChapter = normalized.first;
      steps.add(
        SourceDebugStep(
          stage: '3. 目录提取',
          success: true,
          elapsedMs: sw3.elapsedMilliseconds,
          summary: '首屏解析出 ${normalized.length} 章，首章「${firstChapter.chapter.title}」',
          detail:
              '末章：${normalized.last.chapter.title}\n首章链接：${firstChapter.url}',
        ),
      );
    } catch (error) {
      sw3.stop();
      steps.add(
        SourceDebugStep(
          stage: '3. 目录提取',
          success: false,
          elapsedMs: sw3.elapsedMilliseconds,
          summary: '目录解析失败：$error',
        ),
      );
      return steps;
    }

    // Step 4: First chapter content / manga images
    final sw4 = Stopwatch()..start();
    try {
      final body = await _fetchChapterBodyFromUrl(
        source: source,
        initialChapterUrl: firstChapter.url,
        chapterTitle: firstChapter.chapter.title,
        baseBookUrl: sampleBook.bookUrl,
      );
      sw4.stop();
      if (source.isManga) {
        final imageCount = body
            .split('\n\n')
            .where((l) => l.trim().isNotEmpty)
            .length;
        steps.add(
          SourceDebugStep(
            stage: '4. 漫画图片提取',
            success: true,
            elapsedMs: sw4.elapsedMilliseconds,
            summary: '成功提取 $imageCount 张漫画页图片地址',
            detail: body.split('\n\n').take(3).join('\n'),
          ),
        );
      } else {
        final preview = body.length > 160 ? '${body.substring(0, 160)}…' : body;
        steps.add(
          SourceDebugStep(
            stage: '4. 正文提取',
            success: true,
            elapsedMs: sw4.elapsedMilliseconds,
            summary: '成功提取 ${body.length} 字正文',
            detail: preview,
          ),
        );
      }
    } catch (error) {
      sw4.stop();
      steps.add(
        SourceDebugStep(
          stage: '4. ${source.isManga ? "漫画图片" : "正文"}提取',
          success: false,
          elapsedMs: sw4.elapsedMilliseconds,
          summary: '提取失败：$error',
        ),
      );
    }
    return steps;
  }
}

/// Routes `0x20000000..0x3fffffff` book IDs and active online searches to
/// [SourceNovelRepository], keeping legacy `1..0x1fffffff` Wenku8 IDs isolated.
class RemoteRouterRepository extends NovelRepository {
  const RemoteRouterRepository({
    required this.legacy,
    required this.sources,
  });

  final NovelRepository legacy;
  final SourceNovelRepository sources;

  @override
  NovelRepository? get remoteRepository => sources;

  @override
  Future<List<Novel>> list() =>
      sources.sourceStore.hasActiveSources ? sources.list() : legacy.list();

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => sources.sourceStore.hasActiveSources
      ? sources.browse(sort: sort, page: page, refresh: refresh)
      : legacy.browse(sort: sort, page: page, refresh: refresh);

  @override
  Future<List<Novel>> search(String query) =>
      sources.sourceStore.hasActiveSources
      ? sources.search(query)
      : legacy.search(query);

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) => sources.sourceStore.hasActiveSources
      ? sources.searchPage(query, page: page, refresh: refresh)
      : legacy.searchPage(query, page: page, refresh: refresh);

  @override
  Future<Novel?> find(int id) =>
      isSourceNovelId(id) ? sources.find(id) : legacy.find(id);

  @override
  Future<Novel> detail(Novel novel) =>
      isSourceNovelId(novel.id) ? sources.detail(novel) : legacy.detail(novel);

  @override
  Future<List<NovelChapter>> chapters(int id) =>
      isSourceNovelId(id) ? sources.chapters(id) : legacy.chapters(id);

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) =>
      isSourceNovelId(novelId)
      ? sources.chapterContent(novelId, chapter)
      : legacy.chapterContent(novelId, chapter);
}
