part of 'pages.dart';

final _readerWhitespace = RegExp(r'\s+');

/// showGlassMenu 的外层 null 表示关闭菜单；实例中的 tagId == null 表示选择“全部”或“未设标签”。
class _TagMenuChoice {
  const _TagMenuChoice(this.tagId, {this.untagged = false});

  final String? tagId;
  final bool untagged;
}

class DiscoverPage extends StatefulWidget {
  const DiscoverPage({
    super.key,
    required this.books,
    required this.state,
    required this.repository,
    required this.onSearch,
    this.showHeader = true,
    this.feed,
    this.categoryTitle,
    this.onChooseCategory,
  });
  final List<Novel> books;
  final LibraryState state;
  final NovelRepository repository;
  final VoidCallback onSearch;
  final bool showHeader;
  final NovelFeedController? feed;
  final String? categoryTitle;
  final void Function(BuildContext context)? onChooseCategory;

  /// 顶部栏由 HomeShell 通过 widget 实例直接取用，不依赖 State。
  Widget buildHeader(BuildContext context) => Row(
    children: [
      const Expanded(child: ArchiveMasthead(title: '书屿', brand: true)),
      GlassIconButton(
        icon: CupertinoIcons.search,
        label: '搜索',
        onPressed: onSearch,
      ),
    ],
  );

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  final TagStore _tagStore = TagStore.shared;
  bool _loadMoreQueued = false;

  /// Tag selection now lives in [LibraryFilter.shared], shared with the shelf
  /// (design §5.1/§5.5). This getter is the single selected tag, or null when
  /// none or several are chosen; the carousel filters by the full selection.
  String? get _selectedTagId {
    final ids = LibraryFilter.shared.tagIds;
    return ids.length == 1 ? ids.first : null;
  }

  set _selectedTagId(String? id) => LibraryFilter.shared.setSingleTag(id);

  @override
  void initState() {
    super.initState();
    _tagStore.addListener(_onTagsChanged);
    LibraryFilter.shared.addListener(_onFilterChanged);
  }

  @override
  void dispose() {
    _tagStore.removeListener(_onTagsChanged);
    LibraryFilter.shared.removeListener(_onFilterChanged);
    super.dispose();
  }

  void _onFilterChanged() {
    if (mounted) setState(() {});
  }

  void _onTagsChanged() {
    if (!mounted) return;
    // 标签改名、增删、书籍归属变化都要刷新；选中标签被删除则回退到全部。
    LibraryFilter.shared.prune(_tagStore);
    setState(() {});
  }

  void _showAllTags() {
    if (!mounted || !LibraryFilter.shared.hasTags) return;
    LibraryFilter.shared.setSingleTag(null);
  }

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    return feed == null
        ? _buildContent(context, widget.books)
        : AnimatedBuilder(
            animation: feed,
            builder: (context, _) => LoadedContentSequence(
              generation: feed.resultRevision,
              firstIndex: feed.resultStartIndex == 0
                  ? 0
                  : feed.resultStartIndex + 2,
              child: _buildContent(context, feed.items),
            ),
          );
  }

  /// 轮播区域：只在这里应用标签过滤。
  Widget _buildCarouselArea(
    BuildContext context,
    List<Novel> carouselBooks, {
    Widget? footerAction,
  }) {
    if (carouselBooks.isNotEmpty) {
      return ArchiveFileCarousel(
        // 同一标签下保持轮播 State（分页追加不重置焦点）；
        // 切换标签或切回全部时重建，从初始位置展示。
        key: ValueKey(
          'archive-files-${widget.feed?.sort.name ?? 'recent'}-${LibraryFilter.shared.untaggedOnly ? 'untagged' : LibraryFilter.shared.hasTags ? (LibraryFilter.shared.tagIds.toList()..sort()).join(',') : 'all'}',
        ),
        books: carouselBooks,
        footerAction: footerAction,
        reduceMotion: widget.state.reduceMotion,
        animateEntrance: true,
        onOpen: (book, tag) => openDetail(
          context,
          book,
          widget.state,
          widget.repository,
          coverHeroTag: tag,
        ),
      );
    }
    final hasSourceBooks = (widget.feed?.items ?? widget.books).isNotEmpty;
    if (LibraryFilter.shared.hasTags && hasSourceBooks) {
      // 分页加载中：已加载部分暂无匹配不代表最终结果。
      final stillLoading = widget.feed?.loading == true;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                stillLoading
                    ? '已加载书籍中暂无匹配，正在继续加载…'
                    : (LibraryFilter.shared.untaggedOnly
                          ? '暂无未设标签的书籍'
                          : '该标签下暂无书籍'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              CupertinoButton(
                onPressed: _showAllTags,
                child: const Text('查看全部'),
              ),
              if (footerAction != null)
                Align(alignment: Alignment.centerRight, child: footerAction),
            ],
          ),
        ),
      );
    }
    final local = localLibraryOf(widget.repository);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 90),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('暂无书籍'),
            if (local != null) ...[
              const SizedBox(height: 14),
              GlassTextButton(
                key: const ValueKey('discover-import-local'),
                onPressed: () => pushNovelPage<void>(
                  context,
                  LocalLibraryPage(
                    state: widget.state,
                    local: local,
                    repository: widget.repository,
                    pickFolderOnOpen: true,
                  ),
                  reduceMotion: widget.state.reduceMotion,
                ),
                child: const Text('导入本地书籍（TXT / EPUB / PDF）'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, List<Novel> books) {
    final feed = widget.feed;
    final allBooks = books;
    // 只过滤轮播；随机抽阅与概览始终基于全量。标签与书架共用一份
    // 选择，按书架上的 AND / OR 规则匹配。
    final filter = LibraryFilter.shared;
    final List<Novel> carouselBooks = !filter.hasTags
        ? allBooks
        : allBooks
              .where(
                (book) => filter.matchesTags(
                  book.id,
                  widget.state.tagMatchMode,
                  store: _tagStore,
                ),
              )
              .toList(growable: false);

    Widget body;
    if (allBooks.isEmpty && feed?.loading == true) {
      body = LibrarySkeleton(header: _categoryHeader(context));
    } else if (allBooks.isEmpty && feed?.error != null) {
      body = ContentNotice(
        icon: CupertinoIcons.wifi_exclamationmark,
        title: '书籍加载失败',
        message: '检查网络后再试，已保存的书架与阅读记录仍保留。',
        onRetry: feed!.retry,
      );
    } else {
      body = NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 &&
              notification.metrics.axis == Axis.vertical &&
              feed?.loading == false &&
              feed?.hasMore == true &&
              feed?.error == null &&
              notification.metrics.extentAfter <
                  math.max(800, notification.metrics.viewportDimension * 1.5)) {
            if (!_loadMoreQueued) {
              _loadMoreQueued = true;
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                try {
                  await feed?.loadMore();
                } finally {
                  _loadMoreQueued = false;
                }
              });
            }
          }
          return false;
        },
        child: KeyedSubtree(
          key: ValueKey(feed?.sort),
          child: CustomScrollView(
            key: const PageStorageKey('discover'),
            physics: const AlwaysScrollableScrollPhysics(),
            cacheExtent: 500,
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LoadedContentItem(
                        index: 0,
                        child: _categoryHeader(context),
                      ),
                      const SizedBox(height: 8),
                      if (allBooks.isEmpty)
                        _buildCarouselArea(context, carouselBooks),
                      if (allBooks.isNotEmpty) ...[
                        NovelRandomPickSection(
                          books: allBooks,
                          state: widget.state,
                          carouselBuilder: (resetButton) => _buildCarouselArea(
                            context,
                            carouselBooks,
                            footerAction: resetButton,
                          ),
                          matchMode: widget.state.tagMatchMode,
                          pace: widget.state.randomPickPace,
                          onOpenDetail: (book) => openDetail(
                            context,
                            book,
                            widget.state,
                            widget.repository,
                          ),
                        ),
                        const SizedBox(height: 20),
                        LoadedContentItem(
                          index: 2,
                          child: DiscoverLibraryOverview(
                            books: allBooks,
                            feed: feed,
                            state: widget.state,
                            repository: widget.repository,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + 120,
                ),
                sliver: SliverToBoxAdapter(
                  child:
                      feed != null &&
                          (feed.loading || feed.error != null || feed.hasMore)
                      ? FeedFooter(feed: feed)
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      );
      if (feed != null) {
        body = FeedRefresh(feed: feed, child: body);
      }
    }
    return GlassHeaderLayout(
      showHeader: widget.showHeader,
      header: widget.buildHeader(context),
      body: body,
    );
  }

  Widget _categoryHeader(BuildContext context) {
    final selectedTagId = _selectedTagId;
    final selectedTag = selectedTagId == null
        ? null
        : _tagStore.tagById(selectedTagId);
    final count = LibraryFilter.shared.tagIds.length;
    final title = LibraryFilter.shared.untaggedOnly
        ? '未设标签'
        : selectedTag?.name ??
              (count > 1 ? '$count 个标签' : null) ??
              widget.categoryTitle ??
              '全部';
    return Row(
      children: [
        Expanded(child: sectionHeader(context, title, '')),
        if (widget.feed != null)
          GlassMenuAnchor(
            child: Builder(
              builder: (buttonContext) => GlassIconButton(
                icon: CupertinoIcons.line_horizontal_3_decrease,
                label: '标签筛选',
                onPressed: () => widget.onChooseCategory != null
                    ? widget.onChooseCategory!(buttonContext)
                    : _chooseTag(buttonContext),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _chooseTag(BuildContext context) async {
    final choice = await showGlassMenu<_TagMenuChoice>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      builder: (menuContext) => AnimatedBuilder(
        // 菜单打开期间标签发生增删改名时同步更新菜单内容。
        animation: _tagStore,
        builder: (context, _) {
          final tags = _tagStore.tags.toList(growable: false);
          final selectedTagId = _selectedTagId;
          final untaggedOnly = LibraryFilter.shared.untaggedOnly;
          final effectiveSelectedTagId =
              !untaggedOnly &&
                  selectedTagId != null &&
                  _tagStore.tagById(selectedTagId) != null
              ? selectedTagId
              : null;
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(menuContext).height * .62,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassMenuItem(
                    order: 0,
                    label: '全部',
                    selected:
                        !untaggedOnly &&
                        effectiveSelectedTagId == null &&
                        LibraryFilter.shared.tagIds.isEmpty,
                    onPressed: () => Navigator.of(
                      menuContext,
                    ).pop<_TagMenuChoice>(const _TagMenuChoice(null)),
                  ),
                  GlassMenuItem(
                    order: 1,
                    label: '未设标签',
                    selected: untaggedOnly,
                    onPressed: () => Navigator.of(menuContext)
                        .pop<_TagMenuChoice>(
                          const _TagMenuChoice(null, untagged: true),
                        ),
                  ),
                  for (var index = 0; index < tags.length; index++)
                    GlassMenuItem(
                      order: index + 2,
                      label: tags[index].name,
                      selected:
                          !untaggedOnly &&
                          effectiveSelectedTagId == tags[index].id,
                      onPressed: () => Navigator.of(
                        menuContext,
                      ).pop<_TagMenuChoice>(_TagMenuChoice(tags[index].id)),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );

    // 外层 null 是取消菜单，不清除现有选择。
    if (!mounted || choice == null) return;

    if (choice.untagged) {
      if (!LibraryFilter.shared.untaggedOnly) {
        LibraryFilter.shared.toggleUntagged();
      }
      return;
    }

    final requestedTagId = choice.tagId;
    // 标签可能在点击与菜单 Future 返回之间被删除。
    final String? nextTagId =
        requestedTagId != null && _tagStore.tagById(requestedTagId) != null
        ? requestedTagId
        : null;

    // 重复选择不触发重建。
    if (!LibraryFilter.shared.untaggedOnly &&
        _selectedTagId == nextTagId &&
        LibraryFilter.shared.tagIds.length <= 1) {
      return;
    }
    _selectedTagId = nextTagId;
  }
}

/// 发现页下方的馆藏与阅读概览卡片：展示书库书籍数量、各标签书籍数量、
/// 累计阅读小时数与已读书籍数量。
class DiscoverLibraryOverview extends StatefulWidget {
  const DiscoverLibraryOverview({
    super.key,
    required this.books,
    required this.state,
    required this.repository,
    this.feed,
  });

  final List<Novel> books;
  final LibraryState state;
  final NovelRepository repository;
  final NovelFeedController? feed;

  @override
  State<DiscoverLibraryOverview> createState() =>
      _DiscoverLibraryOverviewState();
}

class _DiscoverLibraryOverviewState extends State<DiscoverLibraryOverview> {
  late Listenable _changes;
  Widget? _cachedCard;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant DiscoverLibraryOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    _cachedCard = null;
    if (oldWidget.state != widget.state ||
        oldWidget.repository != widget.repository ||
        oldWidget.feed != widget.feed) {
      _bind();
    }
  }

  void _bind() {
    _changes = Listenable.merge([
      widget.state,
      widget.state.historyChanges,
      widget.state.readingActivity,
      TagStore.shared,
      LibraryFilter.shared,
      localLibraryOf(widget.repository),
      widget.feed,
    ]);
  }

  static String _formatReadingHours(int totalSeconds) {
    if (totalSeconds <= 0) return '0';
    final hours = totalSeconds / 3600.0;
    if (hours < 0.1) return '0.1';
    final tenths = (hours * 10).round();
    if (tenths % 10 == 0) {
      return '${tenths ~/ 10}';
    }
    return (tenths / 10).toStringAsFixed(1);
  }

  void _openStatistics() {
    unawaited(
      pushNovelPage<void>(
        context,
        ReadingStatisticsPage(
          state: widget.state,
          repository: widget.repository,
        ),
        reduceMotion: widget.state.reduceMotion,
      ),
    );
  }

  void _openTagManage() {
    unawaited(
      pushNovelPage<void>(
        context,
        TagManagePage(
          state: widget.state,
          local: localLibraryOf(widget.repository),
        ),
        reduceMotion: widget.state.reduceMotion,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _cachedCard = null;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final containerPaper = dark
        ? Color.lerp(scheme.surface, scheme.surfaceContainerHigh, .45)!
        : Color.lerp(scheme.surface, scheme.primaryContainer, .20)!;
    final tilePaper = dark
        ? Color.lerp(scheme.surfaceContainerHigh, scheme.primaryContainer, .22)!
        : scheme.surface;
    final ink = scheme.onSurface;
    final muted = scheme.onSurfaceVariant;
    final border = dark
        ? scheme.outlineVariant
        : Color.lerp(scheme.outlineVariant, scheme.primary, .16)!;
    final accent = scheme.primary;

    return ListenableBuilder(
      listenable: _changes,
      builder: (context, _) {
        final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
        if (!isCurrent && _cachedCard != null) {
          return _cachedCard!;
        }
        final local =
            localLibraryOf(widget.repository) ?? widget.state.localLibrary;
        final libraryIds = <int>{
          for (final book in widget.books) book.id,
          if (local != null) ...[
            for (final book in local.books) book.id,
            for (final id in widget.state.shelf)
              if (!isLocalNovelId(id)) id,
          ] else
            ...widget.state.shelf,
        };
        final totalBooks = math.max(
          libraryIds.length,
          widget.feed?.totalItems ?? 0,
        );

        final byId = <int, Novel>{
          for (final book in widget.books) book.id: book,
        };
        final offline = offlineRepositoryOf(widget.repository);
        Novel? knownBook(int id) =>
            byId[id] ??
            local?.novelFor(id) ??
            widget.state.cachedNovel(id) ??
            offline?.cache.book(id)?.novel;

        final readBookIds = <int>{
          ...widget.state.recordedReadingIds,
          for (final day in widget.state.readingActivity.days)
            if (day.seconds > 0) ...day.bookIds,
        };
        var finishedBooks = 0;
        for (final id in readBookIds) {
          final book = knownBook(id);
          if (book != null && widget.state.finishedReading(book)) {
            finishedBooks++;
          }
        }
        final readBooks = readBookIds.length;

        final totalSeconds = widget.state.readingActivity.totalSeconds;
        final hoursText = _formatReadingHours(totalSeconds);
        final durationCaption = totalSeconds <= 0
            ? '累计 0 分钟'
            : '累计 ${statisticsDuration(totalSeconds)}';

        final store = TagStore.shared;
        final tags = store.tags;
        var taggedBooks = 0;
        for (final id in libraryIds) {
          if (store.tagsForBook(id).isNotEmpty) {
            taggedBooks++;
          }
        }
        final untaggedBooks = math.max(0, totalBooks - taggedBooks);
        final tagCounts = <({Tag tag, int count})>[
          for (final tag in tags) (tag: tag, count: store.bookCountFor(tag.id)),
        ];
        final maxTagCount = tagCounts.fold<int>(
          0,
          (prev, item) => math.max(prev, item.count),
        );

        return _cachedCard = Container(
          key: const ValueKey('discover-library-overview'),
          width: double.infinity,
          decoration: BoxDecoration(
            color: containerPaper,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '书库与阅读',
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontSize: 21,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: ink,
                        letterSpacing: 0,
                      ),
                    ),
                    TextButton.icon(
                      key: const ValueKey('discover-open-statistics'),
                      onPressed: _openStatistics,
                      style: TextButton.styleFrom(
                        foregroundColor: accent,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        minimumSize: const Size(0, 32),
                      ),
                      icon: const ArchiveIcon(
                        CupertinoIcons.chart_bar,
                        size: 15,
                      ),
                      label: const Text('阅读统计', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '当前书库规模、标签分布与累计阅读记录。',
                  style: TextStyle(color: muted, fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final largeText =
                        MediaQuery.textScalerOf(context).scale(14) > 20;
                    final columns = constraints.maxWidth < 250 || largeText
                        ? 1
                        : (constraints.maxWidth >= 560 ? 4 : 2);
                    const spacing = 12.0;
                    final tileWidth =
                        (constraints.maxWidth - spacing * (columns - 1)) /
                        columns;
                    final tiles = <Widget>[
                      _OverviewStatTile(
                        key: const ValueKey('discover-stat-total-books'),
                        label: '书库藏书',
                        value: '$totalBooks',
                        unit: '本',
                        caption: taggedBooks > 0
                            ? '已设标签 $taggedBooks 本'
                            : '当前书库全部书籍',
                        paper: tilePaper,
                        border: border,
                        ink: ink,
                        muted: muted,
                        reduceMotion: widget.state.reduceMotion,
                      ),
                      _OverviewStatTile(
                        key: const ValueKey('discover-stat-reading-hours'),
                        label: '阅读时长',
                        value: hoursText,
                        unit: '小时',
                        caption: durationCaption,
                        paper: tilePaper,
                        border: border,
                        ink: ink,
                        muted: muted,
                        reduceMotion: widget.state.reduceMotion,
                        onTap: _openStatistics,
                      ),
                      _OverviewStatTile(
                        key: const ValueKey('discover-stat-read-books'),
                        label: '已读书籍',
                        value: '$readBooks',
                        unit: '本',
                        caption: readBooks > 0
                            ? '已读完 $finishedBooks 本'
                            : '翻开书页自动记录',
                        paper: tilePaper,
                        border: border,
                        ink: ink,
                        muted: muted,
                        reduceMotion: widget.state.reduceMotion,
                        onTap: _openStatistics,
                      ),
                      _OverviewStatTile(
                        key: const ValueKey('discover-stat-total-tags'),
                        label: '标签分类',
                        value: '${tags.length}',
                        unit: '个',
                        caption: tags.isEmpty
                            ? '暂未创建标签'
                            : '未设标签 $untaggedBooks 本',
                        paper: tilePaper,
                        border: border,
                        ink: ink,
                        muted: muted,
                        reduceMotion: widget.state.reduceMotion,
                        onTap: _openTagManage,
                      ),
                    ];
                    return Wrap(
                      spacing: spacing,
                      runSpacing: spacing,
                      children: [
                        for (final tile in tiles)
                          SizedBox(width: tileWidth, child: tile),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
                Divider(height: 1, color: border.withValues(alpha: .7)),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '各个标签',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: ink,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: dark ? .16 : .08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${tags.length} 个',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    TextButton(
                      key: const ValueKey('discover-manage-tags'),
                      onPressed: _openTagManage,
                      style: TextButton.styleFrom(
                        foregroundColor: muted,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        minimumSize: const Size(0, 30),
                      ),
                      child: const Text('管理标签', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (tagCounts.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: tilePaper,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: border.withValues(alpha: .7)),
                    ),
                    child: Text(
                      '还没有创建标签，为书籍添加标签后可在此查看各标签的藏书数量。',
                      style: TextStyle(fontSize: 13, color: muted, height: 1.5),
                    ),
                  )
                else
                  Column(
                    children: [
                      for (final item in tagCounts)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _OverviewTagRow(
                            key: ValueKey('discover-tag-stat-${item.tag.id}'),
                            name: item.tag.name,
                            count: item.count,
                            maxCount: math.max(1, maxTagCount),
                            color: tagPalette.isEmpty
                                ? accent
                                : tagPalette[item.tag.colorIndex %
                                      tagPalette.length],
                            selected: LibraryFilter.shared.tagIds.contains(
                              item.tag.id,
                            ),
                            paper: tilePaper,
                            border: border,
                            ink: ink,
                            muted: muted,
                            accent: accent,
                            dark: dark,
                            reduceMotion: widget.state.reduceMotion,
                            onTap: () =>
                                LibraryFilter.shared.toggleTag(item.tag.id),
                          ),
                        ),
                      if (untaggedBooks > 0)
                        _OverviewTagRow(
                          key: const ValueKey('discover-tag-stat-untagged'),
                          name: '未设标签',
                          count: untaggedBooks,
                          maxCount: math.max(1, totalBooks),
                          color: muted,
                          selected: LibraryFilter.shared.untaggedOnly,
                          paper: tilePaper,
                          border: border,
                          ink: ink,
                          muted: muted,
                          reduceMotion: widget.state.reduceMotion,
                          accent: accent,
                          dark: dark,
                          onTap: LibraryFilter.shared.toggleUntagged,
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _OverviewStatTile extends StatelessWidget {
  const _OverviewStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.caption,
    required this.paper,
    required this.border,
    required this.ink,
    required this.muted,
    this.reduceMotion = false,
    this.onTap,
  });

  final String label;
  final String value;
  final String unit;
  final String caption;
  final Color paper;
  final Color border;
  final Color ink;
  final Color muted;
  final bool reduceMotion;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: paper,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border.withValues(alpha: .75)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: muted,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 24,
                  height: 1.1,
                  fontWeight: FontWeight.w600,
                  color: ink,
                  letterSpacing: 0,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  unit,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: muted.withValues(alpha: .85)),
          ),
        ],
      ),
    );
    if (onTap == null) return content;
    return _OverviewPressable(
      reduceMotion: reduceMotion,
      onTap: onTap!,
      child: content,
    );
  }
}

/// Light press feedback for overview tiles: a short scale and dim on contact.
/// Reduce motion keeps only the dim so the tap still reads as acknowledged.
class _OverviewPressable extends StatefulWidget {
  const _OverviewPressable({
    required this.onTap,
    required this.child,
    this.reduceMotion = false,
  });

  final VoidCallback onTap;
  final Widget child;
  final bool reduceMotion;

  @override
  State<_OverviewPressable> createState() => _OverviewPressableState();
}

class _OverviewPressableState extends State<_OverviewPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.onTap,
        child: AnimatedOpacity(
          opacity: _pressed ? .78 : 1,
          duration: NovelMotion.contact,
          curve: NovelMotion.ease,
          child: AnimatedScale(
            scale: _pressed && !widget.reduceMotion ? .98 : 1,
            duration: widget.reduceMotion ? Duration.zero : NovelMotion.contact,
            curve: NovelMotion.ease,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _OverviewTagRow extends StatelessWidget {
  const _OverviewTagRow({
    super.key,
    required this.name,
    required this.count,
    required this.maxCount,
    required this.color,
    required this.selected,
    required this.paper,
    required this.border,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.dark,
    this.reduceMotion = false,
    this.onTap,
  });

  final String name;
  final int count;
  final int maxCount;
  final Color color;
  final bool selected;
  final Color paper;
  final Color border;
  final Color ink;
  final Color muted;
  final Color accent;
  final bool dark;
  final bool reduceMotion;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fraction = maxCount <= 0 ? 0.0 : (count / maxCount).clamp(0.0, 1.0);
    final row = AnimatedContainer(
      duration: reduceMotion ? Duration.zero : NovelMotion.contact * 2,
      curve: NovelMotion.ease,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: selected ? Color.lerp(paper, accent, dark ? .18 : .10)! : paper,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected
              ? accent.withValues(alpha: dark ? .50 : .36)
              : border.withValues(alpha: .7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? accent : ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$count 本',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? accent : muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // The bar grows from zero on first build and eases between counts.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: fraction),
            duration: reduceMotion ? Duration.zero : NovelMotion.enter,
            curve: NovelMotion.ease,
            builder: (context, value, _) => ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 3,
                color: color.withValues(alpha: .85),
                backgroundColor: border.withValues(alpha: .45),
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return _OverviewPressable(
      reduceMotion: reduceMotion,
      onTap: onTap!,
      child: row,
    );
  }
}

/// Pull-to-refresh keeps content/scroll position and announces a bounded static
/// skeleton strip. There is no native spinner hidden behind the glass header.
class FeedRefresh extends StatelessWidget {
  const FeedRefresh({super.key, required this.feed, required this.child});
  final NovelFeedController feed;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: RefreshIndicator.noSpinner(
          onRefresh: feed.refresh,
          child: child,
        ),
      ),
      if (feed.refreshing)
        Positioned(
          top: MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight,
          left: 24,
          right: 24,
          height: 64,
          child: IgnorePointer(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: const LoadingSkeleton(
                key: ValueKey('feed-refresh-skeleton'),
                layout: SkeletonLayout.actions,
                label: '正在刷新书籍',
              ),
            ),
          ),
        ),
    ],
  );
}

class FeedFooter extends StatelessWidget {
  const FeedFooter({super.key, required this.feed});
  final NovelFeedController feed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (feed.loading)
          const BookRowSkeleton(label: '正在加载更多书籍')
        else if (feed.error != null) ...[
          Text(
            feed.refreshFailed ? '刷新失败，已保留原列表' : '加载下一页失败',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          GlassTextButton(onPressed: feed.retry, child: const Text('重试')),
        ] else if (feed.hasMore)
          GlassTextButton(onPressed: feed.loadMore, child: const Text('加载更多'))
        else if (feed.items.isNotEmpty)
          Text(
            '已经到底了',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
      ],
    ),
  );
}

void openDetail(
  BuildContext context,
  Novel novel,
  LibraryState state,
  NovelRepository repository, {
  Object? coverHeroTag,
  bool fromCache = false,
}) {
  unawaited(
    pushNovelPage<void>(
      context,
      fromCache
          ? DetailPage(
              novel: novel,
              state: state,
              repository: repository,
              fromCache: true,
              coverHeroTag: coverHeroTag,
            )
          : DetailLoaderPage(
              novel: novel,
              state: state,
              repository: repository,
              coverHeroTag: coverHeroTag,
            ),
      reduceMotion: state.reduceMotion,
      paperFlight: coverHeroTag != null,
      slot: 'detail',
    ),
  );
}

void openReadingHistory(
  BuildContext context,
  LibraryState state,
  NovelRepository repository,
) => unawaited(
  pushNovelPage<void>(
    context,
    ReadingHistoryPage(
      state: state,
      repository: repository,
      onOpen: (pageContext, id, book) => openDetail(
        pageContext,
        book ??
            Novel(
              id: id,
              title: '书籍 $id',
              author: '',
              genre: '',
              summary: '',
              colors: const [Color(0xFF202020), Color(0xFF333333)],
            ),
        state,
        repository,
      ),
    ),
    reduceMotion: state.reduceMotion,
  ),
);

/// 书架行内的标签，只负责展示。
///
/// 由父级决定是否传入；为 null 时不占高度。
class _ShelfBookTags extends StatelessWidget {
  const _ShelfBookTags({required this.tags});

  final List<Tag> tags;

  static const double _maxChipWidth = 120;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 标签整体宽度最多 120；窄屏时不超过标题栏可用宽度。
        final double maxChipWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth.clamp(0.0, _maxChipWidth).toDouble()
            : _maxChipWidth;
        return Wrap(
          spacing: 4,
          runSpacing: 2,
          children: [
            for (final tag in tags)
              _buildChip(tag: tag, theme: theme, maxWidth: maxChipWidth),
          ],
        );
      },
    );
  }

  Widget _buildChip({
    required Tag tag,
    required ThemeData theme,
    required double maxWidth,
  }) {
    // 沿用详情页配色；调色板为空时回退到主题色，避免取模异常。
    final Color color = tagPalette.isEmpty
        ? theme.colorScheme.primary
        : tagPalette[tag.colorIndex % tagPalette.length];
    // 不用 Chip：其最小高度受主题约束，无法保证缩小到一半。
    // 这里用 Container 自绘：字号 9（行高约 10.8）+ 上下内边距 2 + 边框 2，
    // 总高度约 15，仅为原来 Chip（约 36~40）的三分之一多一点。
    // 文字样式沿用主题 labelLarge（原 Chip 默认），只改字号，保证颜色不变。
    return Tooltip(
      message: tag.name,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          key: ValueKey<String>(tag.id),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .18),
            border: Border.all(color: color.withValues(alpha: .5)),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            tag.name,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style:
                theme.textTheme.labelLarge?.copyWith(
                  fontSize: 9,
                  height: 1.2,
                ) ??
                const TextStyle(fontSize: 9, height: 1.2),
          ),
        ),
      ),
    );
  }
}

/// Right-edge fast scroller for large shelves. Dragging maps the thumb
/// position to the list extent and shows the label under the finger.
class _FastScroller extends StatefulWidget {
  const _FastScroller({required this.controller, required this.labels});
  final ScrollController controller;
  final List<String> labels;

  @override
  State<_FastScroller> createState() => _FastScrollerState();
}

class _FastScrollerState extends State<_FastScroller> {
  static const double _thumbHeight = 28;
  String? _label;
  double _y = 0;

  void _drag(double dy, double height) {
    final c = widget.controller;
    if (!c.hasClients || height <= 0) return;
    final t = (dy / height).clamp(0.0, 1.0);
    c.jumpTo(t * c.position.maxScrollExtent);
    final i = (t * (widget.labels.length - 1)).round();
    setState(() {
      _y = dy.clamp(0.0, height);
      _label = widget.labels.isEmpty ? null : widget.labels[i];
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dragging = _label != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 0.0;
        return GestureDetector(
          key: const ValueKey('shelf-fast-scroller'),
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) => _drag(d.localPosition.dy, height),
          onVerticalDragUpdate: (d) => _drag(d.localPosition.dy, height),
          onVerticalDragEnd: (_) => setState(() => _label = null),
          onVerticalDragCancel: () => setState(() => _label = null),
          child: SizedBox(
            width: 28,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: .65),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: widget.controller,
                  builder: (context, _) {
                    final c = widget.controller;
                    final maxExtent = c.hasClients
                        ? c.position.maxScrollExtent
                        : 0.0;
                    final fraction = c.hasClients && maxExtent > 0
                        ? (c.offset / maxExtent).clamp(0.0, 1.0)
                        : 0.0;
                    final travel = math.max(0.0, height - _thumbHeight);
                    return Positioned(
                      top: fraction * travel,
                      left: dragging ? 10 : 11,
                      right: dragging ? 10 : 11,
                      height: math.min(_thumbHeight, math.max(8.0, height)),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: dragging
                              ? scheme.primary
                              : scheme.primary.withValues(alpha: .62),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    );
                  },
                ),
                if (_label != null)
                  Positioned(
                    right: 34,
                    top: _y - 22,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _label!,
                        style: TextStyle(
                          color: scheme.onPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
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

class NovelRow extends StatelessWidget {
  const NovelRow({
    super.key,
    required this.novel,
    required this.onTap,
    this.trailing,
    this.coverHeroTag,
    this.tagRow,
    this.progress,
  });
  final Novel novel;
  final VoidCallback onTap;
  final Widget? trailing;
  final Object? coverHeroTag;

  /// Optional 0–1 reading progress, drawn as a 3px accent bar.
  final double? progress;

  /// 标题下方的可选标签区域。为 null 时不占高度。
  final Widget? tagRow;

  @override
  Widget build(BuildContext context) => JellyTapSurface(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          NovelCover(novel, width: 56, height: 76, heroTag: coverHeroTag),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ArchiveCode(ArchiveDesign.fileCode(novel.id)),
                const SizedBox(height: 4),
                Text(
                  novel.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                // 标签紧接标题；无标签时不创建间距。
                if (tagRow != null) ...[const SizedBox(height: 4), tagRow!],
                // 本地书作者可能为空，不创建空作者行及其间距。
                if (novel.author.trim().isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    novel.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (progress case final value?) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      key: ValueKey('shelf-progress-${novel.id}'),
                      value: value.clamp(0.0, 1.0),
                      minHeight: 3,
                      color: Theme.of(context).colorScheme.secondary,
                      backgroundColor: Theme.of(context).dividerColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
          trailing ?? const ArchiveIcon(CupertinoIcons.chevron_right, size: 15),
        ],
      ),
    ),
  );
}
