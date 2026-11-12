part of 'pages.dart';

class ShelfPage extends StatefulWidget {
  const ShelfPage({
    super.key,
    required this.books,
    required this.state,
    required this.repository,
    this.showHeader = true,
  });
  final List<Novel> books;
  final LibraryState state;
  final NovelRepository repository;
  final bool showHeader;

  Widget buildHeader(BuildContext context) => Row(
    children: [
      const Expanded(
        child: ArchiveMasthead(title: '书架'),
      ),
      GlassIconButton(
        icon: CupertinoIcons.clock,
        label: '阅读历史',
        onPressed: () => openReadingHistory(context, state, repository),
      ),
    ],
  );

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

enum _ShelfSort { recentRead, recentAdded, title, progress, chapters }

class _ShelfPageState extends State<ShelfPage> {
  final Map<int, Future<Novel?>> _requests = {};
  final _query = TextEditingController();
  Timer? _queryDelay;
  Map<int, Novel?> _buildKnown = const {};
  SearchScope _scope = SearchScope.all;
  final Set<int> _selection = {};
  final _scroll = ScrollController();
  bool get _selecting => _selection.isNotEmpty;
  final _filter = LibraryFilter.shared;
  bool get _hasActiveFilters =>
      _query.text.trim().isNotEmpty ||
      state.shelfFilter != 'all' ||
      !_filter.isEmpty;

  Future<void> _clearFilters() async {
    _queryDelay?.cancel();
    _queryDelay = null;
    final hadQuery = _query.text.isNotEmpty;
    if (hadQuery) _query.clear();
    await _filter.clear(state: state);
    if (hadQuery && mounted) setState(() {});
  }

  _ShelfSort get _sort => _ShelfSort.values.firstWhere(
    (sort) => sort.name == state.shelfSort,
    orElse: () => _ShelfSort.recentRead,
  );
  LibraryState get state => widget.state;
  late final _changes = Listenable.merge([
    state,
    state.historyChanges,
    state.shelfViewChanges,
    TagStore.shared,
    LibraryFilter.shared,
    localLibraryOf(widget.repository),
  ]);

  @override
  void dispose() {
    _queryDelay?.cancel();
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  bool _matches(int id) {
    if (!_filter.matchesTags(id, state.tagMatchMode)) return false;
    if (!_filter.matchesFormat(id, localLibraryOf(widget.repository))) {
      return false;
    }
    final book = _known(id);
    if (!matchesSearch(book, id, _query.text, _scope)) return false;
    final read = state.hasRead(id);
    final finished = book != null && state.finishedReading(book);
    return switch (state.shelfFilter) {
      'unread' => !read,
      'reading' => read && !finished,
      'finished' => finished,
      'untagged' => TagStore.shared.tagsForBook(id).isEmpty,
      _ => true,
    };
  }

  Novel? _knownFromSources(int id, [Map<int, Novel>? feedById]) {
    final local = localLibraryOf(widget.repository);
    final source = local?.bookFor(id);
    if (source != null) return local!.toNovel(source);
    final cached = state.cachedNovel(id);
    if (cached != null) return cached;
    if (feedById != null) return feedById[id];
    for (final book in widget.books) {
      if (book.id == id) return book;
    }
    return null;
  }

  Novel? _known(int id) =>
      _buildKnown.containsKey(id) ? _buildKnown[id] : _knownFromSources(id);

  Future<Novel?> _resolve(int id) async {
    final book = await widget.repository.find(id);
    if (book != null) await state.rememberNovel(book);
    return book;
  }

  int _chapterTotalFor(int id) {
    final book = _known(id);
    if (book == null) return 0;
    return book.chapters.isNotEmpty ? book.chapters.length : book.chapterCount;
  }

  double _sortProgressFor(int id) {
    final book = _known(id);
    if (book == null || !state.hasRead(id)) return -1;
    return _progressOf(book) ?? 0;
  }

  int _compare(int a, int b) {
    final result = switch (_sort) {
      _ShelfSort.recentRead =>
        state.lastReadAt(b).compareTo(state.lastReadAt(a)),
      _ShelfSort.recentAdded => state.addedAt(b).compareTo(state.addedAt(a)),
      _ShelfSort.title => (_known(a)?.title ?? '$a').compareTo(
        _known(b)?.title ?? '$b',
      ),
      _ShelfSort.progress =>
        _sortProgressFor(b).compareTo(_sortProgressFor(a)),
      _ShelfSort.chapters =>
        _chapterTotalFor(b).compareTo(_chapterTotalFor(a)),
    };
    if (result != 0) return result;
    final added = state.addedAt(b).compareTo(state.addedAt(a));
    return added != 0 ? added : a.compareTo(b);
  }

  @override
  Widget build(BuildContext context) => ActiveListenableBuilder(
    listenable: _changes,
    builder: (context) {
      // One id->book map per build keeps lookups O(1) for large shelves.
      final feedById = {for (final book in widget.books) book.id: book};
      _buildKnown = {
        for (final id in state.shelf) id: _knownFromSources(id, feedById),
      };
      _filter.prune(TagStore.shared);
      final saved = state.shelf.where(_matches).toList()..sort(_compare);
      _selection.removeWhere((id) => !state.contains(id));
      final grid = state.shelfLayout == ShelfLayout.grid;
      return GlassHeaderLayout(
        showHeader: widget.showHeader,
        header: widget.buildHeader(context),
        body: Stack(
          children: [
            Positioned.fill(
              child: ListView.builder(
          key: const PageStorageKey('shelf'),
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(
            24,
            MediaQuery.paddingOf(context).top +
                FrostedHeader.toolbarHeight +
                8,
            24,
            MediaQuery.paddingOf(context).bottom + 120,
          ),
          itemCount: saved.isEmpty
              ? 2
              : (grid ? (saved.length / 3).ceil() : saved.length) + 1,
          itemBuilder: (context, index) {
            if (grid && index > 0 && saved.isNotEmpty) {
              return _gridRow(context, saved, index - 1);
            }
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CupertinoSearchTextField(
                      key: const ValueKey('shelf-search'),
                      controller: _query,
                      borderRadius: BorderRadius.circular(
                        ArchiveDesign.panelRadius,
                      ),
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      placeholder: switch (_scope) {
                        SearchScope.tags => '在书架中查找标签',
                        SearchScope.titleAuthor => '查找书名、作者',
                        SearchScope.all => '查找书名、作者、编号或标签',
                      },
                      onChanged: (_) {
                        _queryDelay?.cancel();
                        _queryDelay = Timer(
                          const Duration(milliseconds: 180),
                          () {
                            if (mounted) setState(() {});
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            saved.length == state.shelf.length
                                ? '${saved.length} 本书'
                                : '${saved.length} / ${state.shelf.length} 本书',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        GlassMenuAnchor(
                          child: Builder(
                            builder: (buttonContext) => GlassTextButton(
                              key: const ValueKey('shelf-filter'),
                              onPressed: () => _chooseFilter(buttonContext),
                              child: Text(switch (state.shelfFilter) {
                                'unread' => '未读',
                                'reading' => '阅读中',
                                'finished' => '已读完',
                                'untagged' => '未写标签',
                                _ => '全部',
                              }),
                            ),
                          ),
                        ),
                        GlassMenuAnchor(
                          child: Builder(
                            builder: (buttonContext) => GlassIconButton(
                              icon: CupertinoIcons.line_horizontal_3_decrease,
                              label: '书架排序',
                              onPressed: () => _chooseSort(buttonContext),
                            ),
                          ),
                        ),
                        GlassIconButton(
                          key: const ValueKey('shelf-layout-toggle'),
                          icon: state.shelfLayout == ShelfLayout.grid
                              ? CupertinoIcons.list_bullet
                              : CupertinoIcons.square_grid_2x2,
                          label: state.shelfLayout == ShelfLayout.grid
                              ? '切换为列表'
                              : '切换为网格',
                          onPressed: () => state.setShelfLayout(
                            state.shelfLayout == ShelfLayout.grid
                                ? ShelfLayout.list
                                : ShelfLayout.grid,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 34,
                      child: ListView(
                        key: const ValueKey('shelf-scope-chips'),
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final scope in SearchScope.values)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                key: ValueKey('shelf-scope-${scope.name}'),
                                label: Text(scope.label),
                                selected: _scope == scope,
                                onSelected: (_) =>
                                    setState(() => _scope = scope),
                              ),
                            ),
                          for (final format in BookFormatFilter.values)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: FilterChip(
                                key: ValueKey('shelf-format-${format.name}'),
                                label: Text(format.label),
                                selected: _filter.formats.contains(format),
                                onSelected: (_) => _filter.toggleFormat(format),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (TagStore.shared.tags.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 34,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ActionChip(
                                key: const ValueKey('shelf-tag-match-mode'),
                                label: Text(state.tagMatchMode.label),
                                onPressed: () => state.setTagMatchMode(
                                  state.tagMatchMode == TagMatchMode.any
                                      ? TagMatchMode.all
                                      : TagMatchMode.any,
                                ),
                              ),
                            ),
                            _tagChip(context, null, '全部'),
                            for (final tag in TagStore.shared.tags)
                              _tagChip(context, tag.id, tag.name),
                          ],
                        ),
                      ),
                    ],
                    if (_hasActiveFilters) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        key: const ValueKey('shelf-active-filters'),
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (_query.text.trim().isNotEmpty)
                            InputChip(
                              label: Text('关键词：${_query.text.trim()}'),
                              onDeleted: () {
                                _queryDelay?.cancel();
                                _queryDelay = null;
                                setState(_query.clear);
                              },
                            ),
                          if (state.shelfFilter != 'all')
                            InputChip(
                              label: Text(switch (state.shelfFilter) {
                                'unread' => '阅读状态：未读',
                                'reading' => '阅读状态：阅读中',
                                'finished' => '阅读状态：已读完',
                                'untagged' => '标签：未写标签',
                                _ => '阅读状态：全部',
                              }),
                              onDeleted: () =>
                                  state.setShelfView(filter: 'all'),
                            ),
                          for (final id in _filter.tagIds)
                            if (TagStore.shared.tagById(id) case final tag?)
                              InputChip(
                                label: Text('标签：${tag.name}'),
                                onDeleted: () => _filter.toggleTag(id),
                              ),
                          for (final format in _filter.formats)
                            InputChip(
                              label: Text('格式：${format.label}'),
                              onDeleted: () => _filter.toggleFormat(format),
                            ),
                          ActionChip(
                            label: const Text('清除全部'),
                            onPressed: _clearFilters,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            }
            if (saved.isEmpty) {
              final local = localLibraryOf(widget.repository);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 90),
                child: Column(
                  children: [
                    ArchiveIcon(CupertinoIcons.book,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 34,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      state.shelf.isEmpty ? '书架还空着' : '没有符合条件的书',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      state.shelf.isEmpty
                          ? '导入本地书籍，或在发现页收藏喜欢的书'
                          : '试试其他关键词或清除筛选',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (state.shelf.isEmpty && local != null) ...[
                      const SizedBox(height: 16),
                      GlassTextButton(
                        key: const ValueKey('shelf-import-local'),
                        onPressed: () => pushNovelPage<void>(
                          context,
                          LocalLibraryPage(
                            state: state,
                            local: local,
                            repository: widget.repository,
                            pickFolderOnOpen: true,
                          ),
                          reduceMotion: state.reduceMotion,
                        ),
                        child: const Text('导入本地书籍（TXT / EPUB / PDF）'),
                      ),
                    ] else if (state.shelf.isNotEmpty && _hasActiveFilters) ...[
                      const SizedBox(height: 16),
                      GlassTextButton(
                        key: const ValueKey('shelf-empty-clear-filters'),
                        onPressed: _clearFilters,
                        child: const Text('清除全部筛选'),
                      ),
                    ],
                  ],
                ),
              );
            }
            final id = saved[index - 1];
            final book = _known(id);
            return FutureBuilder<Novel?>(
              key: ValueKey('shelf-resolve-$id'),
              initialData: book,
              future: book == null
                  ? _requests.putIfAbsent(id, () => _resolve(id))
                  : _requests[id],
              builder: (context, snapshot) {
                final resolved = book ?? snapshot.data;
                final pending =
                    snapshot.connectionState != ConnectionState.done;
                return LoadedContentSequence(
                  generation: resolved?.id,
                  child: resolved != null
                      ? LoadedContentItem(
                          index: index - 1,
                          child: _row(context, resolved),
                        )
                      : pending
                      ? BookRowSkeleton(label: '正在载入书籍 $id')
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Row(
                            children: [
                              const ArchiveIcon(CupertinoIcons.book, size: 26),
                              const SizedBox(width: 15),
                              Expanded(child: Text('书籍 $id 暂未载入')),
                              GlassTextButton(
                                onPressed: () => setState(() {
                                  _requests[id] = _resolve(id);
                                }),
                                child: const Text('重试'),
                              ),
                              GlassMenuAnchor(
                                child: Builder(
                                  builder: (buttonContext) => GlassIconButton(
                                    icon: CupertinoIcons.ellipsis,
                                    label: '书籍 $id 书架操作',
                                    onPressed: () =>
                                        _bookMenu(buttonContext, id),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                );
              },
            );
          },
        ),
            ),
            if (saved.length >= 40)
              Positioned(
                top: MediaQuery.paddingOf(context).top +
                    FrostedHeader.toolbarHeight + 20,
                bottom: MediaQuery.paddingOf(context).bottom + 120,
                right: 0,
                child: _FastScroller(
                  controller: _scroll,
                  labels: [for (final id in saved) _indexLabel(id)],
                ),
              ),
            if (_selecting)
              Positioned(
                left: 16,
                right: 16,
                bottom: MediaQuery.paddingOf(context).bottom + 96,
                child: _selectionBar(context, saved),
              ),
          ],
        ),
      );
    },
  );

  /// 快速滚动条标签：按书名排序时用书名首字（无拼音库，汉字显示原字），
  /// 按进度/章节排序时显示百分比或章节数，按时间排序时用年月。
  String _indexLabel(int id) {
    return switch (_sort) {
      _ShelfSort.title => () {
        final title = _known(id)?.title.trim() ?? '';
        return title.isEmpty ? '#' : title.characters.first.toUpperCase();
      }(),
      _ShelfSort.progress => () {
        final book = _known(id);
        if (book == null || !state.hasRead(id)) return '未读';
        return '${((_progressOf(book) ?? 0) * 100).round()}%';
      }(),
      _ShelfSort.chapters => '${_chapterTotalFor(id)}章',
      _ShelfSort.recentAdded || _ShelfSort.recentRead => () {
        final at = _sort == _ShelfSort.recentAdded
            ? state.addedAt(id)
            : state.lastReadAt(id);
        if (at <= 0) return '—';
        final date = DateTime.fromMillisecondsSinceEpoch(at);
        return '${date.year % 100}.${date.month}';
      }(),
    };
  }

  Widget _selectionBar(BuildContext context, List<int> visible) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey('shelf-selection-bar'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ArchiveDesign.sheetRadius),
        boxShadow: const [
          BoxShadow(color: Color(0x1F101828), blurRadius: 32, offset: Offset(0, 12)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text('已选 ${_selection.length} 本')),
            TextButton(
              key: const ValueKey('shelf-batch-tag'),
              onPressed: TagStore.shared.tags.isEmpty
                  ? () => showNovelFeedback(context, '还没有标签，请先在“标签管理”中新建')
                  : () => _batchTag(context),
              child: const Text('加标签'),
            ),
            TextButton(
              key: const ValueKey('shelf-batch-remove'),
              onPressed: () => _batchRemove(context),
              child: const Text('移出'),
            ),
            TextButton(
              key: const ValueKey('shelf-batch-finish'),
              onPressed: () => _batchFinish(context),
              child: const Text('标为已读'),
            ),
            IconButton(
              tooltip: '退出多选',
              icon: const ArchiveIcon(CupertinoIcons.xmark),
              onPressed: () => setState(_selection.clear),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _batchTag(BuildContext context) async {
    final tagId = await showGlassMenu<String>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, tag) in TagStore.shared.tags.indexed)
            GlassMenuItem(
              order: i,
              label: tag.name,
              onPressed: () => Navigator.of(menu).pop(tag.id),
            ),
        ],
      ),
    );
    if (tagId == null || !context.mounted) return;
    final ids = _selection.toList();
    final localCount = ids.where(isLocalNovelId).length;
    if (localCount > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('批量加标签'),
          content: Text(
            '将为 ${ids.length} 本书加标签，其中 $localCount 本本地书会逐个修改源文件名。'
            '改名失败的书保持原样，并在完成后列出。',
            style: TextStyle(color: Theme.of(dialog).colorScheme.error),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('继续')),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    final result = await addTagToBooks(
      books: [for (final id in ids) (id: id, title: _known(id)?.title ?? '书籍 $id')],
      tagId: tagId,
      local: localLibraryOf(widget.repository),
    );
    if (!context.mounted) return;
    setState(_selection.clear);
    if (result.failed.isEmpty) {
      showNovelFeedback(context, '已为 ${result.succeeded.length} 本书加标签');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const ValueKey('shelf-batch-failures'),
        title: Text('${result.failed.length} 本未能加标签'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('成功 ${result.succeeded.length} 本；以下书籍保持原样：'),
              const SizedBox(height: 8),
              for (final item in result.failed)
                Text('· ${item.title}：${item.reason}'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('知道了')),
        ],
      ),
    );
  }

  Future<void> _batchRemove(BuildContext context) async {
    final ids = _selection.toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('将 ${ids.length} 本书移出书架。阅读进度与书签保留，文件不会删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('移出')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    var failed = 0;
    for (final id in ids) {
      try {
        await state.setShelfMembership(id, false);
      } catch (_) {
        failed++;
      }
    }
    if (!context.mounted) return;
    setState(_selection.clear);
    showNovelFeedback(
      context,
      failed == 0 ? '已移出 ${ids.length} 本' : '已移出 ${ids.length - failed} 本，$failed 本失败',
    );
  }

  Future<void> _batchFinish(BuildContext context) async {
    final ids = _selection.toList();
    if (ids.isEmpty) return;
    var succeeded = 0;
    for (final id in ids) {
      try {
        final resolved = _known(id) ?? await _resolve(id);
        if (resolved == null) continue;
        Novel book = resolved;
        if (book.chapters.isEmpty) {
          try {
            book = await widget.repository.detail(book);
          } catch (_) {}
        }
        if (book.chapters.isEmpty) {
          final count = math.max(1, book.chapterCount);
          book = book.withChapters([
            for (var i = 0; i < count; i++)
              NovelChapter('第 ${i + 1} 章', '', id: book.id * 1000 + i + 1),
          ]);
        }
        await state.savePosition(
          novel: book,
          chapter: book.chapters.length - 1,
          offset: 1,
          maximum: 1,
          width: 390,
        );
        if (state.finishedReading(book)) {
          succeeded++;
        }
      } catch (_) {}
    }
    if (!context.mounted) return;
    setState(_selection.clear);
    final failed = ids.length - succeeded;
    showNovelFeedback(
      context,
      failed == 0
          ? '已将 $succeeded 本标为已读'
          : '已将 $succeeded 本标为已读，$failed 本未能更新',
    );
  }

  /// 该书的标签行；无标签时返回 null，不占高度。
  /// 书架已监听 TagStore，标签变化会自动重建行。
  Widget? _tagRowForBook(int bookId) {
    final List<Tag> tags = TagStore.shared.tagsForBook(bookId);
    if (tags.isEmpty) {
      return null;
    }
    return _ShelfBookTags(tags: tags);
  }

  /// Grid row: 3 covers of 104×148, gap 12, lazily built like list rows.
  Widget _gridRow(BuildContext context, List<int> ids, int row) {
    final start = row * 3;
    return Padding(
      key: ValueKey('shelf-grid-row-$row'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = start; i < start + 3; i++) ...[
            if (i > start) const SizedBox(width: 12),
            Expanded(
              child: i < ids.length
                  ? _gridCell(context, ids[i])
                  : const SizedBox.shrink(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _gridCell(BuildContext context, int id) {
    final book = _known(id);
    if (book == null) {
      return FutureBuilder<Novel?>(
        future: _requests.putIfAbsent(id, () => _resolve(id)),
        builder: (context, snapshot) => snapshot.data == null
            ? AspectRatio(
                aspectRatio: 104 / 148,
                child: Center(child: Text('$id')),
              )
            : _gridCell(context, id),
      );
    }
    final progress = _progressOf(book);
    return _selectable(
      book,
      JellyTapSurface(
        key: ValueKey('shelf-book-${book.id}'),
        onTap: () => _openOrSelect(context, book),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth.clamp(0.0, 104.0);
                return NovelCover(
                  book,
                  width: width,
                  height: width * 148 / 104,
                  heroTag: CoverHeroTag(this, book.id),
                );
              },
            ),
            const SizedBox(height: 6),
            Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            if (progress != null) ...[
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                color: Theme.of(context).colorScheme.secondary,
                backgroundColor: Theme.of(context).dividerColor,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Display-only whole-book progress; stored fields are only read.
  double? _progressOf(Novel book) {
    if (!state.hasRead(book.id)) return null;
    final count = book.chapters.isNotEmpty
        ? book.chapters.length
        : book.chapterCount;
    if (count <= 0) return null;
    final chapter = state.chapterForNovel(book);
    final fraction = state.positionFor(book.id)?.fraction ?? 0;
    return ((chapter + fraction) / count).clamp(0.0, 1.0);
  }

  void _toggleSelect(int id) => setState(() {
    if (!_selection.remove(id)) _selection.add(id);
  });

  void _openOrSelect(BuildContext context, Novel book) {
    if (_selecting) {
      _toggleSelect(book.id);
      return;
    }
    openDetail(
      context,
      book,
      state,
      widget.repository,
      coverHeroTag: CoverHeroTag(this, book.id),
    );
  }

  Widget _selectable(Novel book, Widget child) => GestureDetector(
    key: ValueKey('shelf-select-${book.id}'),
    behavior: HitTestBehavior.translucent,
    onLongPress: () {
      AppHaptics.play(context, HapticCue.action);
      _toggleSelect(book.id);
    },
    child: Stack(
      children: [
        child,
        if (_selecting)
          Positioned(
            top: 8,
            left: 0,
            child: IgnorePointer(
              child: ArchiveIcon(
                _selection.contains(book.id)
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                size: 22,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _row(BuildContext context, Novel book) => _selectable(book, NovelRow(
    key: ValueKey('shelf-book-${book.id}'),
    novel: book,
    coverHeroTag: CoverHeroTag(this, book.id),
    tagRow: _tagRowForBook(book.id),
    progress: _progressOf(book),
    onTap: () => _openOrSelect(context, book),
    trailing: SizedBox(
      width: 74,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassMenuAnchor(
            child: Builder(
              builder: (buttonContext) => GlassIconButton(
                icon: CupertinoIcons.ellipsis,
                label: '${book.title}书架操作',
                onPressed: () => _bookMenu(buttonContext, book.id, book: book),
              ),
            ),
          ),
          Text(
            !state.hasRead(book.id)
                ? '未读'
                : state.finishedReading(book)
                ? '已读完'
                : (book.chapters.isNotEmpty || book.chapterCount > 0)
                ? '${state.chapterForNovel(book) + 1}/${book.chapters.isNotEmpty ? book.chapters.length : book.chapterCount}'
                : '第 ${state.chapterFor(book.id) + 1} 章',
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    ),
  ));

  Future<void> _chooseSort(BuildContext context) async {
    final sort = await showGlassMenu<_ShelfSort>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (menuContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, label) in [
            (_ShelfSort.recentRead, '最近阅读'),
            (_ShelfSort.recentAdded, '最近加入'),
            (_ShelfSort.title, '书名'),
            (_ShelfSort.progress, '阅读进度'),
            (_ShelfSort.chapters, '章节数'),
          ])
            GlassMenuItem(
              order: value.index,
              label: label,
              selected: value == _sort,
              onPressed: () => Navigator.of(menuContext).pop(value),
            ),
        ],
      ),
    );
    if (!mounted || sort == null) return;
    try {
      await state.setShelfView(sort: sort.name);
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '书架排序保存失败，请重试');
    }
  }

  Future<void> _chooseFilter(BuildContext context) async {
    final filter = await showGlassMenu<String>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, (value, label)) in [
            ('all', '全部'),
            ('unread', '未读'),
            ('reading', '阅读中'),
            ('finished', '已读完'),
            ('untagged', '未写标签'),
          ].indexed)
            GlassMenuItem(
              order: index,
              label: label,
              selected: state.shelfFilter == value,
              onPressed: () => Navigator.pop(menu, value),
            ),
        ],
      ),
    );
    if (!mounted || filter == null) return;
    try {
      await state.setShelfView(filter: filter);
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '书架筛选保存失败，请重试');
    }
  }

  /// 标签筛选小方片：null 表示全部（清空）；其余可多选，按 AND / OR 匹配。
  Widget _tagChip(BuildContext context, String? tagId, String label) {
    final selected = tagId == null
        ? !_filter.hasTags
        : _filter.tagIds.contains(tagId);
    final tag = tagId == null ? null : TagStore.shared.tagById(tagId);
    final color = tag == null
        ? Theme.of(context).colorScheme.primary
        : tagPalette[tag.colorIndex % tagPalette.length];
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => tagId == null
            ? _filter.setSingleTag(null)
            : _filter.toggleTag(tagId),
        selectedColor: color.withValues(alpha: .22),
        side: BorderSide(
          color: selected ? color : Theme.of(context).dividerColor,
        ),
      ),
    );
  }

  Future<void> _bookMenu(BuildContext context, int id, {Novel? book}) async {
    final repository = widget.repository;
    final local = repository is CompositeNovelRepository
        ? repository.local
        : null;
    final localBook = local?.bookFor(id);
    final action = await showGlassMenu<_ShelfBookAction>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (menuContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassMenuItem(
            label: '移出书架',
            onPressed: () =>
                Navigator.of(menuContext).pop(_ShelfBookAction.removeFromShelf),
          ),
          if (localBook != null)
            GlassMenuItem(
              label: '删除文件',
              onPressed: () =>
                  Navigator.of(menuContext).pop(_ShelfBookAction.deleteFile),
            ),
        ],
      ),
    );
    if (!mounted || !context.mounted || action == null) return;
    switch (action) {
      case _ShelfBookAction.removeFromShelf:
        await _removeFromShelf(context, id, book: book);
      case _ShelfBookAction.deleteFile:
        if (local != null) await _deleteShelfBookFile(context, local, id);
    }
  }

  Future<void> _removeFromShelf(
    BuildContext context,
    int id, {
    Novel? book,
  }) async {
    if (!state.contains(id)) return;
    final snapshot = state.cachedNovel(id) ?? book;
    final addedAt = state.addedAt(id);
    try {
      await state.setShelfMembership(id, false);
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '书架操作保存失败，请重试');
      return;
    }
    final revision = state.shelfRevision(id);
    if (!mounted) return;
    showNovelFeedback(
      this.context,
      '已移出书架',
      actionLabel: '撤销',
      action: () async {
        if (!state.contains(id) && state.shelfRevision(id) == revision) {
          await state.setShelfMembership(
            id,
            true,
            novel: snapshot,
            restoredAddedAt: addedAt,
          );
        }
      },
    );
  }

  /// 二次确认后彻底删除本地书籍的源文件，并清理书架/标签/阅读进度。
  Future<void> _deleteShelfBookFile(
    BuildContext context,
    LocalLibraryStore local,
    int id,
  ) async {
    final (successText, cleanupOk) = await _confirmAndDeleteLocalBook(
      context,
      local: local,
      state: state,
      id: id,
    );
    if (successText == null || !mounted || !context.mounted) return;
    showNovelFeedback(
      context,
      cleanupOk ? successText : '书籍已移除，但部分关联数据未清干净，可重启后重试',
    );
  }
}

Future<(String?, bool)> _confirmAndDeleteLocalBook(
  BuildContext context, {
  required LocalLibraryStore local,
  required LibraryState state,
  required int id,
}) async {
  final book = local.bookFor(id);
  if (book == null || !context.mounted) return (null, false);
  final title = book.displayTitle;
  final first = await confirmNovelAction(
    context,
    title: '彻底删除文件？',
    message: '「$title」将从手机存储中彻底删除，书架、标签和阅读进度一并清除。此操作无法撤销。',
    confirmLabel: '继续',
    reduceMotion: state.reduceMotion,
  );
  if (!first || !context.mounted) return (null, false);
  final second = await confirmNovelAction(
    context,
    title: '再次确认删除',
    message: '这是最后一次确认。文件删除后无法恢复，确定要删除「$title」吗？',
    confirmLabel: '确认删除',
    reduceMotion: state.reduceMotion,
  );
  if (!second || !context.mounted) return (null, false);
  final deleteResult = await _deleteLocalBookWithFallback(
    context,
    local,
    id,
    reduceMotion: state.reduceMotion,
    state: state,
  );
  if (deleteResult == _DeleteFileResult.failed) return (null, false);
  final successText = switch (deleteResult) {
    _DeleteFileResult.recordOnly => '已移出书库「$title」，源文件已保留',
    _DeleteFileResult.recordOnlySourceGone => '已移出书库「$title」',
    _ => '已删除「$title」',
  };
  var cleanupOk = true;
  for (final step in <Future<void> Function()>[
    () => state.setShelfMembership(id, false),
    () => TagStore.shared.setTagsForBook(id, const {}),
    () => state.clearBookProgress(id),
  ]) {
    try {
      await step();
    } catch (_) {
      cleanupOk = false;
    }
  }
  return (successText, cleanupOk);
}

/// 删除源文件的结果：已彻底删除 / 仅移出书库（源文件保留）/
/// 仅移出书库（源文件已不存在）/ 失败（记录保留）。
enum _DeleteFileResult { deleted, recordOnly, recordOnlySourceGone, failed }

/// 重授权后的统一扫描后处理：关联清理 + 章节迁移任务。
/// 与首页自动扫描、本地书库页走同一套顺序，扫描结果不丢弃。
Future<LocalScanFollowUp> _applyLocalScanAfterReauth(
  LocalLibraryStore local,
  LibraryState? state,
) async {
  state?.bindLocalChapters(local);
  final scanResult = await local.scan();
  return applyLocalScanFollowUp<LocalChapterRemap>(
    remaps: scanResult.chapterRemaps,
    cleanupAssociations: () async {
      if (state == null) {
        throw StateError('LibraryState is not available');
      }
      final cleanupIds = await local.peekAssociatedCleanupIds();
      final cleanupDone = <int>[];
      // 异常不能吞掉：已完整处理的 ID 在 finally 里确认，未处理的
      // ID 留待下次重试，异常向上传给 applyLocalScanFollowUp，
      // 使 followUp.handled 为 false、调用方不再继续删除源文件。
      // 单个清理动作本身幂等（移出书架、清空标签、清进度），
      // 已完成的部分不需要回滚。
      try {
        for (final id in cleanupIds) {
          await state.setShelfMembership(id, false);
          await TagStore.shared.setTagsForBook(id, const {});
          await state.clearBookProgress(id);
          cleanupDone.add(id);
        }
      } finally {
        if (cleanupDone.isNotEmpty) {
          await local.confirmAssociatedCleanupIds(cleanupDone);
        }
      }
    },
    migrate: (remap) async {
      if (state == null) {
        throw StateError('LibraryState is not available');
      }
      await state.migrateLocalChapterTask(remap);
    },
    confirm: (remap) =>
        local.confirmChapterRemap(remap.migrationId, bookId: remap.bookId),
    recordFailure: (remap, error) => local.markChapterRemapFailed(remap, error),
    commitMigrationOutcomes: (confirmed, failures) =>
        local.commitChapterRemapResults(
          confirmed: [
            for (final remap in confirmed)
              (bookId: remap.bookId, migrationId: remap.migrationId),
          ],
          failures: failures,
        ),
    bookIdOf: (remap) => remap.bookId,
  );
}

enum _UnconfirmedDeleteAction { retry, removeRecordOnly }

Future<_UnconfirmedDeleteAction?> _showUnconfirmedDeleteDialog(
  BuildContext context,
) {
  return showDialog<_UnconfirmedDeleteAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('无法确认删除结果'),
      content: const Text(
        '文件提供方未能确认源文件是否已删除。'
        '文件可能暂时离线，或提供方当前无法解析该文件。\n\n'
        '本地记录已保留。请恢复连接、挂载存储或解锁提供方后重试；'
        '也可以仅移出书库，此操作不会删除源文件。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            dialogContext,
            _UnconfirmedDeleteAction.removeRecordOnly,
          ),
          child: const Text('仅移出书库'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _UnconfirmedDeleteAction.retry),
          child: const Text('重试'),
        ),
      ],
    ),
  );
}

/// 删除源文件；失败时按原生错误码区分处理，不再统一一句「删除失败，请重试」：
/// 无写权限可重新授权文件夹后重试；provider 拒绝/不支持/地址失效时，
/// 可兜底「仅移出书库」；其余错误如实提示。关联数据清理由调用方负责。
Future<_DeleteFileResult> _deleteLocalBookWithFallback(
  BuildContext context,
  LocalLibraryStore local,
  int id, {
  required bool reduceMotion,
  bool canReauth = true,
  LibraryState? state,
}) async {
  try {
    await local.deleteBookFile(id);
    return _DeleteFileResult.deleted;
  } on BookCleanupFailed {
    // 源文件已删、记录保存失败已恢复，可重试（重试时文件不存在视为已删）。
    if (context.mounted) {
      showNovelFeedback(context, '文件已删除，但书籍记录未清干净，请重试');
    }
    return _DeleteFileResult.failed;
  } on LocalDeleteException catch (e) {
    if (!context.mounted) return _DeleteFileResult.failed;
    switch (e.code) {
      case 'permission':
        final choice = await showNovelChoiceSheet(
          context,
          title: '没有删除权限',
          message: canReauth
              ? 'App 当前没有该文件夹的删除（写）权限，无法删除或改名源文件。'
                    '重新授权一次文件夹（仍选原来的文件夹），并在系统授权时确认授予写权限；'
                    '也可以先把这本书移出书库，源文件保留在手机里。'
              : '重新授权后仍无法删除这本书的源文件。'
                    '可以先把这本书移出书库，源文件保留在手机里。',
          choices: [
            if (canReauth) (value: 'reauth', label: '重新授权文件夹'),
            (value: 'recordOnly', label: '仅移出书库（源文件保留）'),
          ],
          reduceMotion: reduceMotion,
        );
        if (choice == 'reauth') {
          if (!context.mounted) return _DeleteFileResult.failed;
          final sourceId = local.bookFor(id)?.sourceId;
          final previousFolder = sourceId != null && sourceId.startsWith('saf:')
              ? sourceId.substring(4)
              : local.folderUri;
          if (previousFolder == null) {
            showNovelFeedback(context, '无法确认原文件夹，请先在本地书库中重新授权');
            return _DeleteFileResult.failed;
          }
          String? picked;
          try {
            picked = await local.pickFolder(requiredFolder: previousFolder);
          } catch (_) {
            // pickFolder 的异常发生在本 catch 块内，外层 catch 捕获不到，
            // 必须就地处理，不能逸出成未捕获异步错误。
            if (context.mounted) {
              showNovelFeedback(context, '重新授权失败，请重试');
            }
            return _DeleteFileResult.failed;
          }
          if (picked == null || !context.mounted) {
            return _DeleteFileResult.failed;
          }
          // 原目录、换目录都走同一套扫描后处理：关联清理 + 迁移任务，
          // 扫描结果不再丢弃，失败不再静默吞掉。
          LocalScanFollowUp followUp;
          try {
            followUp = await _applyLocalScanAfterReauth(local, state);
          } catch (_) {
            if (context.mounted) {
              showNovelFeedback(context, '重新授权未完成，请重试');
            }
            return _DeleteFileResult.failed;
          }
          if (!context.mounted) return _DeleteFileResult.failed;
          if (!followUp.handled) {
            // 关联清理或失败记录本身未完成，不能误报“切换完成”就重试删除。
            showNovelFeedback(context, '目录选择已返回，但扫描或后续整理未完成；本次未删除源文件，请重新扫描');
            return _DeleteFileResult.failed;
          }
          // 权限以实际查询为准，不凭“重授权成功”就断定写权限已拿到。
          // 查询本身抛异常时也按保守失败处理，不让异常逸出删除流程。
          LocalTreePermission permission;
          try {
            permission = await LocalPlatform.queryTreePermission(picked);
          } catch (error, _) {
            debugPrint(
              'failed to query tree permission: '
              '${describeSafeError(error, fallback: '权限查询失败')}',
            );
            if (context.mounted) {
              showNovelFeedback(context, '无法确认文件夹写权限；为避免误删，本次不会重试删除，请检查授权后重试');
            }
            return _DeleteFileResult.failed;
          }
          if (!context.mounted) return _DeleteFileResult.failed;
          final migrationNotice = followUp.failedMigrations == 0
              ? ''
              : '；${followUp.failedMigrations} 本书的阅读进度迁移失败，已记录待重试状态';
          if (picked != previousFolder) {
            // 用户选了别的目录：已完成新文件夹扫描和关联整理，
            // 不再拿旧书 id 盲目重试删除，避免误判与误报。
            showNovelFeedback(
              context,
              '已完成新文件夹扫描和关联整理，原文件未删除$migrationNotice'
              '${permission.persistedWrite ? '' : '；当前只有持久化读取权限，App 暂不能凭此授权删除源文件'}',
            );
            return _DeleteFileResult.failed;
          }
          if (!permission.persistedWrite) {
            showNovelFeedback(
              context,
              '${permission.deletionHint}$migrationNotice',
            );
            return _DeleteFileResult.failed;
          }
          if (followUp.failedMigrations != 0) {
            showNovelFeedback(
              context,
              '${followUp.failedMigrations} 本书的阅读进度迁移失败，已记录待重试状态',
            );
          }
          if (local.bookFor(id) == null) {
            showNovelFeedback(context, '这本书已不在书库中');
            return _DeleteFileResult.failed;
          }
          // 每次用户触发删除，重授权后最多自动重试一次。
          // 若仍失败，显示实际错误，不能再次自动进入重授权循环。
          return _deleteLocalBookWithFallback(
            context,
            local,
            id,
            reduceMotion: reduceMotion,
            canReauth: false,
            state: state,
          );
        }
        if (choice == 'recordOnly') {
          if (!context.mounted) return _DeleteFileResult.failed;
          return _removeBookRecordOnly(context, local, id);
        }
        return _DeleteFileResult.failed;
      case 'unsupported':
      case 'delete_rejected':
        final choice = await showNovelChoiceSheet(
          context,
          title: '这个存储位置不让 App 删除',
          message:
              '源文件所在的存储不允许 App 删除文件，需要用文件管理器手动删除。'
              '可以先把这本书移出书库，源文件保留在手机里。',
          choices: [(value: 'recordOnly', label: '仅移出书库（源文件保留）')],
          reduceMotion: reduceMotion,
        );
        if (choice == 'recordOnly') {
          if (!context.mounted) return _DeleteFileResult.failed;
          return _removeBookRecordOnly(context, local, id);
        }
        return _DeleteFileResult.failed;
      case 'invalid_uri':
        final choice = await showNovelChoiceSheet(
          context,
          title: '源文件已找不到',
          message:
              '这本书的源文件可能已被移动或删除，无法再彻底删除。'
              '可以把它的书库记录移出。',
          choices: [(value: 'recordOnly', label: '移出书库记录')],
          reduceMotion: reduceMotion,
        );
        if (choice == 'recordOnly') {
          if (!context.mounted) return _DeleteFileResult.failed;
          // 源文件已不存在，成功文案不写「源文件已保留」。
          return _removeBookRecordOnly(
            context,
            local,
            id,
            successResult: _DeleteFileResult.recordOnlySourceGone,
          );
        }
        return _DeleteFileResult.failed;
      case 'io_error':
        // 无法确认删除结果：保留书籍记录及内部副本，不误报已删。
        // 重试只再次发起原删除操作，由用户每次点击触发，不自动循环。
        final action = await _showUnconfirmedDeleteDialog(context);
        if (action == _UnconfirmedDeleteAction.retry) {
          if (!context.mounted) return _DeleteFileResult.failed;
          return _deleteLocalBookWithFallback(
            context,
            local,
            id,
            reduceMotion: reduceMotion,
            canReauth: canReauth,
            state: state,
          );
        }
        if (action == _UnconfirmedDeleteAction.removeRecordOnly) {
          if (!context.mounted) return _DeleteFileResult.failed;
          return _removeBookRecordOnly(context, local, id);
        }
        return _DeleteFileResult.failed;
      default:
        showNovelFeedback(context, '删除失败，请重试');
        return _DeleteFileResult.failed;
    }
  } catch (_) {
    if (context.mounted) showNovelFeedback(context, '删除失败，请重试');
    return _DeleteFileResult.failed;
  }
}

/// 兜底：仅移出书库（加入忽略名单防再次扫描导入）。
/// [successResult] 区分成功文案：默认源文件保留；源文件已不存在时传
/// [_DeleteFileResult.recordOnlySourceGone]。
Future<_DeleteFileResult> _removeBookRecordOnly(
  BuildContext context,
  LocalLibraryStore local,
  int id, {
  _DeleteFileResult successResult = _DeleteFileResult.recordOnly,
}) async {
  try {
    await local.removeBookRecordOnly(id);
    return successResult;
  } on RecordRemovalPending {
    if (context.mounted) {
      showNovelFeedback(context, '移除状态尚未收尾，请重新扫描或重启以恢复处理');
    }
    return _DeleteFileResult.failed;
  } catch (_) {
    if (context.mounted) showNovelFeedback(context, '移出书库失败，请重试');
    return _DeleteFileResult.failed;
  }
}

enum _ShelfBookAction { removeFromShelf, deleteFile }

