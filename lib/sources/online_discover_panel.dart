import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_interactions.dart';
import '../app_ui.dart';
import '../catalog.dart';
import '../library_state.dart';
import 'book_source.dart';
import 'book_source_store.dart';
import 'online_book_origins.dart';
import 'source_manage_page.dart';
import 'source_repository.dart';

enum OnlineTypeFilter {
  all('全部'),
  novel('小说'),
  manga('漫画');

  const OnlineTypeFilter(this.label);
  final String label;

  SourceContentType? get sourceContentType => switch (this) {
    OnlineTypeFilter.all => null,
    OnlineTypeFilter.novel => SourceContentType.text,
    OnlineTypeFilter.manga => SourceContentType.manga,
  };
}

class OnlineDiscoverView extends StatefulWidget {
  const OnlineDiscoverView({
    super.key,
    required this.state,
    required this.repository,
    required this.onOpenBook,
    this.headerSwitcher,
    this.focusSearchSignal,
  });

  final LibraryState state;
  final NovelRepository repository;
  final void Function(BuildContext context, Novel novel, Object? coverHeroTag)
  onOpenBook;
  final Widget? headerSwitcher;
  final ValueNotifier<int>? focusSearchSignal;

  @override
  State<OnlineDiscoverView> createState() => _OnlineDiscoverViewState();
}

class _OnlineDiscoverViewState extends State<OnlineDiscoverView> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'online-discover-search');
  final ScrollController _scrollCtrl = ScrollController();

  OnlineTypeFilter _typeFilter = OnlineTypeFilter.all;
  String? _selectedSourceId;
  int _selectedKindIndex = 0;

  // Streaming search state
  StreamSubscription<SourceSearchBatch>? _searchSub;
  Completer<void>? _searchCompleter;
  String _activeQuery = '';
  bool _searching = false;
  int _completedSources = 0;
  int _totalSources = 0;
  final List<Novel> _searchResults = <Novel>[];
  final Set<int> _seenSearchBookIds = <int>{};
  Object? _lastSearchError;

  // Explore feed state
  bool _loadingExplore = false;
  Object? _exploreError;
  Object? _exploreLoadMoreError;
  int _explorePage = 1;
  bool _exploreHasMore = false;
  final List<Novel> _exploreBooks = <Novel>[];

  SourceNovelRepository get _sourceRepo =>
      sourceRepositoryOf(widget.repository) ?? SourceNovelRepository();

  BookSourceStore get _store => _sourceRepo.sourceStore;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    widget.focusSearchSignal?.addListener(_onFocusSearchRequested);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncExploreSelection(loadIfNeeded: true);
    });
  }

  @override
  void didUpdateWidget(covariant OnlineDiscoverView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusSearchSignal != widget.focusSearchSignal) {
      oldWidget.focusSearchSignal?.removeListener(_onFocusSearchRequested);
      widget.focusSearchSignal?.addListener(_onFocusSearchRequested);
    }
  }

  @override
  void dispose() {
    widget.focusSearchSignal?.removeListener(_onFocusSearchRequested);
    _store.removeListener(_onStoreChanged);
    _searchSub?.cancel();
    if (_searchCompleter != null && !_searchCompleter!.isCompleted) {
      _searchCompleter!.complete();
    }
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onFocusSearchRequested() {
    if (!mounted) return;
    if (_scrollCtrl.hasClients && _scrollCtrl.offset > 0) {
      unawaited(
        _scrollCtrl.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    }
    _searchFocus.requestFocus();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    _syncExploreSelection(loadIfNeeded: _activeQuery.isEmpty);
    setState(() {});
  }

  static final RegExp _nicheGroupPattern = RegExp(
    r'(?:18\+|r18|\bh\b|海棠|po18|废文)',
    caseSensitive: false,
  );

  static bool _isNicheGroup(BookSource s) =>
      _nicheGroupPattern.hasMatch(s.group) ||
      _nicheGroupPattern.hasMatch(s.name);

  List<BookSource> _eligibleExploreSources() {
    final contentType = _typeFilter.sourceContentType;
    final raw = _store.activeExploreSources
        .where((s) => contentType == null || s.contentType == contentType)
        .toList(growable: false);
    final indexed = <(int, BookSource)>[
      for (var i = 0; i < raw.length; i++) (i, raw[i]),
    ];
    indexed.sort((a, b) {
      final wCmp = b.$2.weight.compareTo(a.$2.weight);
      if (wCmp != 0) return wCmp;
      final nicheCmp = (_isNicheGroup(a.$2) ? 1 : 0).compareTo(
        _isNicheGroup(b.$2) ? 1 : 0,
      );
      if (nicheCmp != 0) return nicheCmp;
      final compatA = a.$2.compatibility == SourceCompatibility.full ? 0 : 1;
      final compatB = b.$2.compatibility == SourceCompatibility.full ? 0 : 1;
      if (compatA != compatB) return compatA.compareTo(compatB);
      return a.$1.compareTo(b.$1);
    });
    return [for (final item in indexed) item.$2];
  }

  void _switchToNextExploreSource(List<BookSource> sources) {
    if (sources.length < 2) return;
    final currentIdx = sources.indexWhere((s) => s.id == _selectedSourceId);
    final nextIdx = (currentIdx + 1) % sources.length;
    setState(() {
      _selectedSourceId = sources[nextIdx].id;
      _selectedKindIndex = 0;
    });
    unawaited(_loadExplore(reset: true));
  }

  BookSource? _currentExploreSource(List<BookSource> sources) {
    if (sources.isEmpty) return null;
    if (_selectedSourceId != null) {
      for (final s in sources) {
        if (s.id == _selectedSourceId) return s;
      }
    }
    return sources.first;
  }

  void _syncExploreSelection({required bool loadIfNeeded}) {
    final sources = _eligibleExploreSources();
    if (sources.isEmpty) {
      _selectedSourceId = null;
      _selectedKindIndex = 0;
      _exploreBooks.clear();
      _exploreError = null;
      _exploreLoadMoreError = null;
      _exploreHasMore = false;
      return;
    }
    final active = _currentExploreSource(sources)!;
    final changedSource = active.id != _selectedSourceId;
    _selectedSourceId = active.id;
    if (_selectedKindIndex >= active.exploreKinds.length) {
      _selectedKindIndex = 0;
    }
    if (loadIfNeeded && (changedSource || _exploreBooks.isEmpty)) {
      unawaited(_loadExplore(reset: true));
    }
  }

  Future<void> _loadExplore({required bool reset}) async {
    final sources = _eligibleExploreSources();
    final source = _currentExploreSource(sources);
    if (source == null || source.exploreKinds.isEmpty) return;
    if (_loadingExplore && !reset) return;

    final kindIdx = _selectedKindIndex.clamp(0, source.exploreKinds.length - 1);
    final kind = source.exploreKinds[kindIdx];
    if (!reset && !kind.supportsPagination) {
      if (_exploreHasMore && mounted) {
        setState(() => _exploreHasMore = false);
      }
      return;
    }
    final nextPage = reset ? 1 : _explorePage + 1;

    setState(() {
      _loadingExplore = true;
      _exploreLoadMoreError = null;
      if (reset) {
        _exploreError = null;
        _exploreHasMore = false;
        _exploreBooks.clear();
      }
    });

    try {
      final page = await _sourceRepo.browseExplore(
        source,
        kind,
        page: nextPage,
      );
      if (!mounted) return;
      setState(() {
        _explorePage = nextPage;
        final existing = {for (final b in _exploreBooks) b.id};
        var addedCount = 0;
        for (final item in page.items) {
          if (existing.add(item.id)) {
            _exploreBooks.add(item);
            addedCount++;
          }
        }
        _exploreHasMore = kind.supportsPagination && addedCount > 0;
        _loadingExplore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (reset || _exploreBooks.isEmpty) {
          _exploreError = error;
        } else {
          _exploreLoadMoreError = error;
        }
        _loadingExplore = false;
      });
    }
  }

  Future<void> _handlePullRefresh() {
    if (_activeQuery.isNotEmpty) {
      _startSearch(_activeQuery);
      return _searchCompleter?.future ?? Future<void>.value();
    }
    return _loadExplore(reset: true);
  }

  void _startSearch(String rawQuery) {
    final q = rawQuery.trim();
    _searchSub?.cancel();
    if (_searchCompleter != null && !_searchCompleter!.isCompleted) {
      _searchCompleter!.complete();
    }
    if (q.isEmpty) {
      setState(() {
        _activeQuery = '';
        _searching = false;
        _searchResults.clear();
        _seenSearchBookIds.clear();
        _lastSearchError = null;
      });
      if (_exploreBooks.isEmpty) {
        unawaited(_loadExplore(reset: true));
      }
      return;
    }

    unawaited(widget.state.recordSearch(q).catchError((Object _) {}));
    final completer = Completer<void>();
    _searchCompleter = completer;

    setState(() {
      _activeQuery = q;
      _searching = true;
      _completedSources = 0;
      _totalSources = 0;
      _searchResults.clear();
      _seenSearchBookIds.clear();
      _lastSearchError = null;
    });

    final lowerNeedle = q.toLowerCase();
    int rankOf(Novel n) {
      final t = n.title.trim().toLowerCase();
      final a = n.author.trim().toLowerCase();
      if (t == lowerNeedle) return 0;
      if (t.startsWith(lowerNeedle)) return 1;
      if (t.contains(lowerNeedle)) return 2;
      if (a == lowerNeedle || a.contains(lowerNeedle)) return 3;
      return 4;
    }

    _searchSub = _sourceRepo
        .searchStream(
          q,
          page: 1,
          contentTypeFilter: _typeFilter.sourceContentType,
        )
        .listen(
          (batch) {
            if (!mounted) return;
            setState(() {
              _completedSources = batch.completedSources;
              _totalSources = batch.totalSources;
              if (batch.error != null) {
                _lastSearchError ??= batch.error;
              }
              var addedAny = false;
              for (final item in batch.items) {
                if (_seenSearchBookIds.add(item.id)) {
                  _searchResults.add(item);
                  addedAny = true;
                }
              }
              if (addedAny) {
                _searchResults.sort(
                  (a, b) => rankOf(a).compareTo(rankOf(b)),
                );
              }
            });
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
            if (mounted) setState(() => _searching = false);
          },
          onError: (Object err) {
            if (!completer.isCompleted) completer.complete();
            if (mounted) {
              setState(() {
                _lastSearchError = err;
                _searching = false;
              });
            }
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final exploreSources = _eligibleExploreSources();
    final activeSource = _currentExploreSource(exploreSources);
    final topInset =
        MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (_activeQuery.isEmpty &&
            notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical &&
            !_loadingExplore &&
            _exploreHasMore &&
            _exploreError == null &&
            _exploreLoadMoreError == null &&
            notification.metrics.extentAfter < 500) {
          unawaited(_loadExplore(reset: false));
        }
        return false;
      },
      child: RefreshIndicator(
        edgeOffset: topInset,
        onRefresh: _handlePullRefresh,
        child: CustomScrollView(
          key: const PageStorageKey('discover-online-sources'),
          controller: _scrollCtrl,
          cacheExtent: 600,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              24,
              MediaQuery.paddingOf(context).top +
                  FrostedHeader.toolbarHeight +
                  8,
              24,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.headerSwitcher != null) ...[
                    widget.headerSwitcher!,
                    const SizedBox(height: 12),
                  ],
                  _buildSearchBar(context),
                  const SizedBox(height: 10),
                  _buildTypeAndManageRow(context),
                  const SizedBox(height: 12),
                  if (_activeQuery.isNotEmpty)
                    _buildSearchStatusHeader(scheme)
                  else if (activeSource != null)
                    _buildExploreSelectors(
                      context,
                      exploreSources,
                      activeSource,
                    ),
                ],
              ),
            ),
          ),
          if (_activeQuery.isNotEmpty)
            _buildSearchResultsSliver(context)
          else
            _buildExploreBodySliver(context, exploreSources, activeSource),
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 120,
            ),
            sliver: const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),
        ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final contentType = _typeFilter.sourceContentType;
    final searchCount = contentType == null
        ? _store.activeSearchSources.length
        : _store.activeSearchSources
              .where((s) => s.contentType == contentType)
              .length;
    final typeLabel = _typeFilter == OnlineTypeFilter.all
        ? '在线'
        : _typeFilter.label;
    return LiquidGlass(
      radius: 18,
      elevated: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.search,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _searchCtrl,
                builder: (context, val, _) => TextField(
                  key: const ValueKey('online-discover-search-input'),
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 14),
                  onSubmitted: _startSearch,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    hintText: '搜索 $searchCount 个$typeLabel书源…',
                    suffixIcon: val.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空',
                            icon: const Icon(
                              CupertinoIcons.xmark_circle_fill,
                              size: 17,
                            ),
                            onPressed: () {
                              _searchCtrl.clear();
                              _startSearch('');
                            },
                          ),
                  ),
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('online-discover-search-submit'),
              onPressed: () {
                _searchFocus.unfocus();
                _startSearch(_searchCtrl.text);
              },
              child: const Text('搜索'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeAndManageRow(BuildContext context) {
    return Row(
      children: [
        for (final filter in OnlineTypeFilter.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              key: ValueKey('online-type-chip-${filter.name}'),
              label: Text(filter.label),
              selected: _typeFilter == filter,
              visualDensity: VisualDensity.compact,
              onSelected: (selected) {
                if (!selected || _typeFilter == filter) return;
                setState(() => _typeFilter = filter);
                if (_activeQuery.isNotEmpty) {
                  _startSearch(_activeQuery);
                } else {
                  _syncExploreSelection(loadIfNeeded: true);
                }
              },
            ),
          ),
        const Spacer(),
        TextButton.icon(
          key: const ValueKey('online-discover-manage-sources'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: () => pushNovelPage<void>(
            context,
            BookSourceManagePage(
              state: widget.state,
              repository: widget.repository,
            ),
            reduceMotion: widget.state.reduceMotion,
          ),
          icon: const Icon(CupertinoIcons.slider_horizontal_3, size: 15),
          label: Text('书源 (${_store.enabledCount})'),
        ),
      ],
    );
  }

  Widget _buildSearchStatusHeader(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          if (_searching) ...[
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              _searching
                  ? '正在检索（$_completedSources / ${_totalSources == 0 ? _store.activeSearchSources.length : _totalSources} 源）· 已找到 ${_searchResults.length} 部'
                  : '「$_activeQuery」共检索到 ${_searchResults.length} 部作品',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExploreSelectors(
    BuildContext context,
    List<BookSource> exploreSources,
    BookSource activeSource,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (exploreSources.length > 1) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final src in exploreSources)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        src.isManga ? '${src.name} · 漫' : src.name,
                      ),
                      selected: src.id == activeSource.id,
                      visualDensity: VisualDensity.compact,
                      onSelected: (sel) {
                        if (!sel || src.id == activeSource.id) return;
                        setState(() {
                          _selectedSourceId = src.id;
                          _selectedKindIndex = 0;
                        });
                        unawaited(_loadExplore(reset: true));
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (activeSource.exploreKinds.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < activeSource.exploreKinds.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      backgroundColor: i == _selectedKindIndex
                          ? Theme.of(
                              context,
                            ).colorScheme.primaryContainer.withValues(alpha: .7)
                          : null,
                      visualDensity: VisualDensity.compact,
                      label: Text(activeSource.exploreKinds[i].title),
                      onPressed: () {
                        if (_selectedKindIndex == i) return;
                        setState(() => _selectedKindIndex = i);
                        unawaited(_loadExplore(reset: true));
                      },
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _buildSearchResultsSliver(BuildContext context) {
    if (_searchResults.isEmpty && _searching) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 64),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_searchResults.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: ContentNotice(
            icon: CupertinoIcons.search,
            title: '未找到匹配书籍',
            message: _lastSearchError != null
                ? '部分书源请求异常（${describeSourceError(_lastSearchError!)}），可尝试更换关键词或在书源管理中检查测试。'
                : '换个关键词试试，或在「书源」中导入更多可用书源。',
            onRetry: () => _startSearch(_activeQuery),
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      sliver: SliverList.builder(
        itemCount: _searchResults.length,
        itemBuilder: (context, index) =>
            _buildOnlineBookTile(context, _searchResults[index]),
      ),
    );
  }

  Widget _buildExploreBodySliver(
    BuildContext context,
    List<BookSource> exploreSources,
    BookSource? activeSource,
  ) {
    final scheme = Theme.of(context).colorScheme;
    if (activeSource == null) {
      final recent = widget.state.recentSearches;
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          child: ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已启用 ${_store.activeSearchSources.length} 个搜索书源',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '当前启用的书源未提供静态分类榜单（或分类由动态脚本生成），直接在上方搜索栏输入书名或作者即可跨源检索阅读。',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (recent.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    '最近搜索',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final q in recent.take(8))
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(q),
                          onPressed: () {
                            _searchCtrl.text = q;
                            _startSearch(q);
                          },
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    if (_exploreBooks.isEmpty && _loadingExplore) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 64),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (_exploreBooks.isEmpty && _exploreError != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ContentNotice(
                icon: CupertinoIcons.wifi_exclamationmark,
                title: '分类列表加载失败',
                message:
                    '「${activeSource.name}」：${describeSourceError(_exploreError!)}',
                onRetry: () => _loadExplore(reset: true),
              ),
              if (exploreSources.length > 1) ...[
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () => _switchToNextExploreSource(exploreSources),
                  icon: const Icon(
                    CupertinoIcons.arrow_right_arrow_left,
                    size: 15,
                  ),
                  label: const Text('切换下一个书源'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (_exploreBooks.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Center(
            child: Text(
              '该分类下暂无内容，可切换其他分类或直接搜索',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }

    final showFooter =
        _loadingExplore ||
        _exploreLoadMoreError != null ||
        (!_exploreHasMore && _exploreBooks.length >= 6);

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      sliver: SliverList.builder(
        itemCount: _exploreBooks.length + (showFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _exploreBooks.length) {
            if (_loadingExplore) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            if (_exploreLoadMoreError != null) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: TextButton.icon(
                    key: const ValueKey('online-explore-load-more-retry'),
                    onPressed: () => _loadExplore(reset: false),
                    icon: const Icon(CupertinoIcons.refresh, size: 14),
                    label: Text(
                      '加载下一页失败（${describeSourceError(_exploreLoadMoreError!)}）· 点击重试',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  '— 已显示全部 ${_exploreBooks.length} 部作品 —',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
                  ),
                ),
              ),
            );
          }
          return _buildOnlineBookTile(context, _exploreBooks[index]);
        },
      ),
    );
  }

  Widget _buildOnlineBookTile(BuildContext context, Novel book) {
    final scheme = Theme.of(context).colorScheme;
    final origin = OnlineBookOriginStore.shared.byBookId(book.id);
    final heroTag = CoverHeroTag('online-discover', book.id);
    final sourceLabel = origin?.sourceName ?? '';
    final latest = book.lastUpdate ?? origin?.latestChapterTitle ?? '';

    return RepaintBoundary(
      child: InkWell(
        key: ValueKey('online-book-tile-${book.id}'),
        onTap: () => widget.onOpenBook(context, book, heroTag),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NovelCover(book, width: 56, height: 76, heroTag: heroTag),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          ArchiveDesign.fileCode(book.id),
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (book.isManga) const MangaBadge(label: '漫画'),
                        if (sourceLabel.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              sourceLabel,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    if (book.author.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (latest.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        '最新：$latest',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ] else if (book.summary.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        book.summary.replaceAll(RegExp(r'\s+'), ' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 26),
                child: Icon(
                  CupertinoIcons.chevron_right,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
