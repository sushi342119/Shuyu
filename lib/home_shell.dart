part of 'pages.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state, required this.repository});
  final LibraryState state;
  final NovelRepository repository;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with TickerProviderStateMixin {
  /// 冷启动自动扫描本地书库：已绑定文件夹时静默扫描，有变化才提示。
  Future<void> _autoScanLocal(LocalLibraryStore local) async {
    // 等首帧后再跑，避免阻塞启动。
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    if (local.tagMigrationFailures.isNotEmpty) {
      showNovelFeedback(
        context,
        local.tagMigrationFailures.entries
            .map((entry) => '${entry.key}：${entry.value}')
            .join('\n'),
      );
    }
    if (local.folderUri == null && local.mangaFolderUri == null) return;
    try {
      final result = await local.scan(verifyUnchangedFingerprints: false);
      // 章节迁移按队列顺序执行，完成后一次提交确认和失败状态。
      final followUp = await applyLocalScanFollowUp<LocalChapterRemap>(
        remaps: result.chapterRemaps,
        cleanupAssociations: () async {},
        migrate: (remap) => widget.state.migrateLocalChapterTask(remap),
        confirm: (_) async {},
        recordFailure: (_, _) async {},
        bookIdOf: (remap) => remap.bookId,
        commitMigrationOutcomes: (confirmed, failures) =>
            local.commitChapterRemapResults(
              confirmed: [
                for (final remap in confirmed)
                  (bookId: remap.bookId, migrationId: remap.migrationId),
              ],
              failures: failures,
            ),
      );
      if (followUp.failedMigrations > 0 && mounted) {
        showNovelFeedback(
          context,
          '${followUp.failedMigrations} 本书的阅读进度迁移失败，已保存待重试任务',
        );
      }
      if (!followUp.handled && mounted) {
        showNovelFeedback(context, '进度已迁移，但确认尚未保存，已保留待重试任务');
      }
      if (!mounted) return;
      if (result.failures.isNotEmpty) {
        showNovelFeedback(context, '部分本地文件扫描失败，请打开本地书库查看详情');
      }
      // 文件夹切换：清理旧来源书籍的书架/标签/阅读进度。
      // peek→逐个幂等清理→confirm：中断后未确认的 ID 下次重试。
      // 这里不接删除步骤，清理失败只中断本轮、静默失败后用户可
      // 手动扫描重试；重授权路径的同名清理见 _applyLocalScanAfterReauth，
      // 那里异常必须向上传，不能吞掉。
      final state = widget.state;
      try {
        final cleanupIds = await local.peekAssociatedCleanupIds();
        final cleanupDone = <int>[];
        for (final id in cleanupIds) {
          try {
            await state.setShelfMembership(id, false);
            await TagStore.shared.setTagsForBook(id, const {});
            await state.clearBookProgress(id);
            cleanupDone.add(id);
          } catch (_) {
            if (mounted) showNovelFeedback(context, '部分关联记录未清理，已保留待重试任务');
          }
        }
        await local.confirmAssociatedCleanupIds(cleanupDone);
      } catch (_) {
        if (mounted) showNovelFeedback(context, '关联清理未完成，已保留待重试任务');
      }
      final changed = result.added + result.refreshed + result.removed;
      final shelfAdditions = [
        for (final book in local.books)
          if (!state.contains(book.id)) local.toNovel(book),
      ];
      await state.addShelfBooks(shelfAdditions);
      // 字数静默补算或本地书库增删改后刷新首页 feed，确保本地书库页和详情页即时显示最新数据。
      if (result.backfilled > 0 ||
          changed > 0 ||
          result.switchedRemovedIds.isNotEmpty) {
        if (!mounted) return;
        try {
          await _catalog.refresh();
        } catch (_) {
          if (mounted) showNovelFeedback(context, '书库已扫描，首页刷新失败，请重试');
        }
        if (!mounted) return;
      }
      if (!mounted) return;
      if (changed == 0 && result.switchedRemovedIds.isEmpty) return;
      final parts = <String>[];
      if (result.added > 0) parts.add('新增 ${result.added} 本');
      if (result.refreshed > 0) parts.add('更新 ${result.refreshed} 本');
      if (result.removed > 0) parts.add('移除 ${result.removed} 本');
      if (result.switchedRemovedIds.isNotEmpty) {
        parts.add('旧文件夹移除 ${result.switchedRemovedIds.length} 本');
      }
      showNovelFeedback(context, '本地书库自动扫描：${parts.join('，')}');
    } catch (_) {
      // 静默失败：用户可在本地书库页手动扫描。
    }
  }

  late NovelFeedController _catalog;
  late NovelFeedController _searchFeed;
  LocalLibraryStore? _boundLocal;
  int _lastSyncedRevision = 0;
  int _lastSyncedScanAdded = 0;
  bool _syncingLocalCatalog = false;
  bool _pendingLocalCatalogSync = false;
  List<Widget> _pageWidgets = const [];
  List<WidgetBuilder> _headers = const [];
  int _tab = 0;
  double _tabDirection = 1;
  int? _outgoingTab;
  bool _searchOpen = false;
  bool _searchMounted = false;
  bool _searchCovered = false;
  final _searchText = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'inline-search');
  bool _searchStarted = false;
  String _lastRecordedSearch = '';
  late final AnimationController _searchExpansion =
      AnimationController(
        vsync: this,
        duration: NovelMotion.enter,
        reverseDuration: NovelMotion.exit,
      )..addStatusListener((status) {
        if (!mounted) return;
        if (status == AnimationStatus.dismissed && !_searchOpen) {
          setState(() => _searchMounted = false);
        } else if (status == AnimationStatus.completed && _searchOpen) {
          setState(() => _searchCovered = true);
          _searchFocus.requestFocus();
        }
      });
  late final AnimationController _pageTransition =
      AnimationController(vsync: this, duration: NovelMotion.enter, value: 1)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => _outgoingTab = null);
          }
        });

  void _onLocalProgressChanged() {
    final local = _boundLocal;
    if (!mounted || local == null) return;
    final progress = localScanProgressFor(local).value;
    if (progress.scanning) {
      if (progress.added < _lastSyncedScanAdded) {
        _lastSyncedScanAdded = 0;
      }
      if (progress.added - _lastSyncedScanAdded >= 15) {
        _lastSyncedScanAdded = progress.added;
        _scheduleLocalCatalogSync(local);
      }
      return;
    }
    _lastSyncedScanAdded = 0;
    if (progress.revision != _lastSyncedRevision) {
      _lastSyncedRevision = progress.revision;
      _scheduleLocalCatalogSync(local);
    }
  }

  void _scheduleLocalCatalogSync(LocalLibraryStore local) {
    if (_syncingLocalCatalog) {
      _pendingLocalCatalogSync = true;
      return;
    }
    _syncingLocalCatalog = true;
    unawaited(() async {
      try {
        do {
          _pendingLocalCatalogSync = false;
          if (!mounted) return;
          if (!localScanProgressFor(local).value.scanning) {
            final books = local.books;
            final additions = [
              for (final book in books)
                if (!widget.state.contains(book.id)) local.toNovel(book),
            ];
            if (additions.isNotEmpty) {
              await widget.state.addShelfBooks(additions);
            }
          }
          if (!mounted) return;
          await _catalog.refresh();
        } while (_pendingLocalCatalogSync && mounted);
      } catch (_) {
        // 渐进同步失败不打断当前浏览。
      } finally {
        _syncingLocalCatalog = false;
      }
    }());
  }

  @override
  void initState() {
    super.initState();
    // 首页改用本地书库数据源（纯本地阅读）。
    final NovelRepository homeRepository;
    final repo = widget.repository;
    if (repo is CompositeNovelRepository) {
      widget.state.bindLocalChapters(repo.local);
      homeRepository = repo.local;
      _boundLocal = repo.local;
    } else {
      homeRepository = repo;
      if (repo is LocalLibraryStore) _boundLocal = repo;
    }
    if (_boundLocal != null) {
      _lastSyncedRevision = localScanProgressFor(_boundLocal!).value.revision;
      localScanProgressFor(_boundLocal!).addListener(_onLocalProgressChanged);
    }
    _catalog = NovelFeedController(
      homeRepository,
      // 本地书库首页加载全部书籍，用于 3D 轮播全量循环和随机抽选。
      loadAll: true,
      loadAllItems: homeRepository is LocalLibraryStore
          ? homeRepository.list
          : null,
    );
    _searchFeed = NovelFeedController(homeRepository, search: true);
    _searchText.addListener(_searchEdited);
    _searchFeed.addListener(_searchSucceeded);
    final repository = widget.repository;
    final OfflineNovelRepository? offline =
        repository is CompositeNovelRepository
        ? (repository.remote is OfflineNovelRepository
              ? repository.remote as OfflineNovelRepository
              : null)
        : (repository is OfflineNovelRepository ? repository : null);
    if (offline != null) {
      unawaited(offline.loadCache().catchError((Object _) {}));
    }
    // 启动自动扫描本地书库（静默，有变化才提示）。
    if (repository is CompositeNovelRepository) {
      _autoScanLocal(repository.local);
    }
    final discover = DiscoverPage(
      books: const [],
      feed: _catalog,
      state: widget.state,
      repository: widget.repository,
      showHeader: false,
      onSearch: _openSearch,
      categoryTitle: '本地书库',
    );
    final shelf = ShelfPage(
      books: const [],
      state: widget.state,
      repository: widget.repository,
      showHeader: false,
    );
    final settings = SettingsPage(
      state: widget.state,
      repository: widget.repository,
      showHeader: false,
    );
    _headers = [discover.buildHeader, shelf.buildHeader, settings.buildHeader];
    _pageWidgets = [discover, shelf, settings]
        .map((page) => RepaintBoundary(child: Atmosphere(child: page)))
        .toList(growable: false);
    _catalog.loadInitial();
  }

  @override
  void dispose() {
    if (_boundLocal != null) {
      localScanProgressFor(
        _boundLocal!,
      ).removeListener(_onLocalProgressChanged);
    }
    _pageTransition.dispose();
    _searchExpansion.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    _catalog.dispose();
    _searchFeed.dispose();
    super.dispose();
  }

  bool get _reduceMotion =>
      widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context);

  void _openSearch() {
    if (!_searchStarted || (_searchFeed.page == 0 && !_searchFeed.loading)) {
      _searchStarted = true;
      _searchFeed.loadInitial();
    }
    setState(() {
      _searchOpen = true;
      _searchMounted = true;
    });
    if (_reduceMotion) {
      _searchExpansion.value = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchOpen) _searchFocus.requestFocus();
      });
    } else {
      _searchExpansion.forward();
    }
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _searchFeed.cancelScheduledSearch();
    setState(() {
      _searchOpen = false;
      _searchCovered = false;
    });
    if (_reduceMotion) {
      _searchExpansion.value = 0;
    } else {
      _searchExpansion.reverse();
    }
  }

  void _searchEdited() {
    if (!_searchOpen) return;
    if (!_searchText.value.composing.isCollapsed) {
      _searchFeed.cancelScheduledSearch();
      return;
    }
    _searchFeed.scheduleSearch(_searchText.text);
  }

  void _searchSucceeded() {
    if (_searchFeed.loading ||
        _searchFeed.error != null ||
        _searchFeed.page < 1) {
      return;
    }
    final query = _searchFeed.query.trim();
    if (query == _lastRecordedSearch) return;
    _lastRecordedSearch = query;
    unawaited(
      widget.state.recordSearch(query).catchError((Object _) {
        if (_lastRecordedSearch == query) _lastRecordedSearch = '';
        if (mounted) showNovelFeedback(context, '最近搜索保存失败');
      }),
    );
  }

  void _recallSearch(String query) {
    _searchText.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _searchFeed.searchFor(query);
    _searchFocus.unfocus();
  }

  void _selectTab(int index) {
    if (index == _tab) return;
    final reduceMotion =
        widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context);
    if (index != _tab) HapticFeedback.selectionClick();
    setState(() {
      if (index != _tab) {
        _tabDirection = index > _tab ? 1 : -1;
        _outgoingTab = reduceMotion ? null : _tab;
        if (reduceMotion) {
          _pageTransition.value = 1;
        } else {
          _pageTransition.forward(from: 0);
        }
      }
      _tab = index;
    });
  }

  Widget _tabPlane(int index) {
    final active = index == _tab;
    final outgoing = index == _outgoingTab;
    final animation = (active || outgoing) && !_reduceMotion
        ? _pageTransition
        : const AlwaysStoppedAnimation<double>(1);
    return Offstage(
      key: ValueKey('home-tab-$index'),
      offstage: _searchCovered || (!active && !outgoing),
      child: TickerMode(
        enabled: active && !_searchCovered,
        child: HeroMode(
          enabled: active && !_searchMounted,
          child: IgnorePointer(
            ignoring: !active || _searchMounted,
            child: ExcludeSemantics(
              excluding: !active || _searchMounted,
              child: ArchivePlaneTransition(
                key: ValueKey('home-archive-plane-$index'),
                animation: animation,
                kind: outgoing
                    ? ArchivePlaneKind.outgoing
                    : ArchivePlaneKind.incoming,
                direction: _tabDirection,
                child: ArchiveMotionScope(
                  animation: animation,
                  enabled: active && !_reduceMotion,
                  child: _pageWidgets[index],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_searchMounted,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _searchMounted) _closeSearch();
    },
    child: Scaffold(
      body: Atmosphere(
        // Each tab/search paints its own archive diagram; the shell only
        // supplies the fallback canvas during a transition.
        archiveBackdrop: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        for (var i = 0; i < _pageWidgets.length; i++)
                          if (i != _tab && i != _outgoingTab) _tabPlane(i),
                        if (_outgoingTab case final outgoing?)
                          _tabPlane(outgoing),
                        _tabPlane(_tab),
                      ],
                    ),
                  ),
                  if (_searchMounted)
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: !_searchOpen,
                        child: ArchivePlaneTransition(
                          key: const ValueKey('search-archive-plane'),
                          animation: _searchExpansion,
                          child: Atmosphere(
                            child: InlineSearchResults(
                              feed: _searchFeed,
                              state: widget.state,
                              repository: widget.repository,
                              onOpenBook: _searchFocus.unfocus,
                              onRecall: _recallSearch,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    key: const ValueKey('home-pinned-header'),
                    top: 0,
                    left: 0,
                    right: 0,
                    child: FrostedHeader(
                      child: _searchMounted
                          ? _expandedSearchHeader(context)
                          : ArchiveMotionScope(
                              animation: _pageTransition,
                              enabled: !_reduceMotion,
                              child: Row(
                                children: [
                                  Expanded(child: _headers[_tab](context)),
                                  if (ListeningScope.maybeOf(context)
                                      case final listening?)
                                    ValueListenableBuilder<ListeningSnapshot>(
                                      valueListenable: listening.snapshot,
                                      builder: (context, session, _) =>
                                          session.novel == null ||
                                              !session.active
                                          ? const SizedBox.shrink()
                                          : Padding(
                                              padding: const EdgeInsets.only(
                                                left: 4,
                                              ),
                                              child: GlassIconButton(
                                                key: const ValueKey(
                                                  'home-listening-entry',
                                                ),
                                                icon: CupertinoIcons.headphones,
                                                label:
                                                    '正在听书 · ${session.novel!.title}',
                                                onPressed: () =>
                                                    showListeningPanel(
                                                      context,
                                                      controller: listening,
                                                      novel: session.novel!,
                                                      chapter: session.chapter,
                                                      paragraph:
                                                          session
                                                              .current
                                                              ?.paragraph ??
                                                          0,
                                                      reduceMotion: widget
                                                          .state
                                                          .reduceMotion,
                                                    ),
                                              ),
                                            ),
                                    ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
            const Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: DockUnderlay(),
            ),
            AnimatedBuilder(
              animation: _searchExpansion,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    22 + MediaQuery.paddingOf(context).left,
                    0,
                    22 + MediaQuery.paddingOf(context).right,
                    12 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: GlassDock(
                    key: const ValueKey('liquid-dock'),
                    selectedIndex: _tab,
                    reduceMotion: widget.state.reduceMotion,
                    onSelected: _selectTab,
                  ),
                ),
              ),
              builder: (context, child) => IgnorePointer(
                ignoring: _searchMounted,
                child: ExcludeSemantics(
                  excluding: _searchMounted,
                  child: Opacity(
                    opacity: 1 - _searchExpansion.value,
                    child: child,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _expandedSearchHeader(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => AnimatedBuilder(
      animation: _searchExpansion,
      child: _searchField(context),
      builder: (context, child) {
        final t = _searchExpansion.value;
        final expansion = NovelMotion.ease.transform(t);
        final wobble = _reduceMotion ? 0.0 : NovelMotion.jelly(t);
        final width = 46 + (constraints.maxWidth - 46) * expansion;
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            ExcludeSemantics(
              child: Opacity(
                opacity: 1 - expansion,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: const ArchiveMasthead(
                    title: '书屿',
                    brand: true,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Transform(
                key: const ValueKey('search-jelly-transform'),
                alignment: Alignment.centerRight,
                transform: Matrix4.diagonal3Values(
                  1 + .026 * wobble,
                  1 - .042 * wobble,
                  1,
                ),
                child: IgnorePointer(
                  ignoring: !_searchOpen || t < .4,
                  child: LiquidGlass(
                    key: const ValueKey('expanded-search-bar'),
                    radius: 24 - expansion,
                    elevated: false,
                    activation: wobble.abs() * .35,
                    touchPosition: .94,
                    child: SizedBox(
                      width: width,
                      height: 46,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24 - expansion),
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          minWidth: constraints.maxWidth,
                          maxWidth: constraints.maxWidth,
                          minHeight: 46,
                          maxHeight: 46,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  Widget _searchField(BuildContext context) => Row(
    children: [
      const SizedBox(width: 46, child: ArchiveIcon(CupertinoIcons.search, size: 21)),
      Expanded(
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchText,
          builder: (context, value, _) => TextField(
            key: const ValueKey('expanded-search-input'),
            controller: _searchText,
            focusNode: _searchFocus,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 14),
            onSubmitted: (query) {
              _searchFeed.searchFor(query);
              _searchFocus.unfocus();
            },
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: '书名、作者',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      icon: const ArchiveIcon(CupertinoIcons.xmark_circle_fill,
                        size: 17,
                      ),
                      onPressed: _searchText.clear,
                    ),
            ),
          ),
        ),
      ),
      SizedBox(
        width: 46,
        height: 46,
        child: IconButton(
          key: const ValueKey('inline-search-close'),
          tooltip: '收起搜索',
          onPressed: _closeSearch,
          icon: const ArchiveIcon(CupertinoIcons.xmark, size: 17),
        ),
      ),
    ],
  );
}
