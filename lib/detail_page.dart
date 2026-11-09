part of 'pages.dart';

class DetailLoaderPage extends StatefulWidget {
  const DetailLoaderPage({
    super.key,
    required this.novel,
    required this.state,
    required this.repository,
    this.coverHeroTag,
    this.loadTimeout = const Duration(seconds: 12),
  });
  final Novel novel;
  final LibraryState state;
  final NovelRepository repository;
  final Object? coverHeroTag;
  final Duration loadTimeout;

  @override
  State<DetailLoaderPage> createState() => _DetailLoaderPageState();
}

class _DetailLoaderPageState extends State<DetailLoaderPage> {
  late Future<Novel> _loaded;
  Novel? _cached;
  LocalLibraryStore? get _local => isLocalNovelId(widget.novel.id)
      ? localLibraryOf(widget.repository)
      : null;
  String? _revision;
  bool _loadingLocal = false;
  int _loadGeneration = 0;
  final _disposed = Completer<void>();
  void _localChanged() {
    final book = _local?.bookFor(widget.novel.id);
    if (!mounted || _loadingLocal || book?.revision == _revision) {
      return;
    }
    setState(() {
      _cached = null;
      _loaded = _load();
    });
  }

  @override
  void dispose() {
    _loadGeneration++;
    _disposed.complete();
    _local?.removeListener(_localChanged);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (_local case final local?) {
      widget.state.bindLocalChapters(local);
      local.addListener(_localChanged);
    }
    _loaded = _load();
    unawaited(_seedFromCache());
  }

  Future<void> _seedFromCache() async {
    final generation = _loadGeneration;
    if (widget.repository case final OfflineNovelRepository offline) {
      try {
        final cached = await offline
            .cachedBook(widget.novel.id)
            .timeout(widget.loadTimeout);
        if (mounted &&
            generation == _loadGeneration &&
            _loadingLocal &&
            cached != null &&
            cached.chapters.isNotEmpty) {
          setState(() => _cached = cached);
        }
      } catch (_) {
        // Online loading remains available when a local snapshot is damaged.
      }
    }
  }

  Future<Novel> _load() {
    final future = _loadWithDeadline();
    // A retry can fail before the next frame subscribes its FutureBuilder.
    // Retain the error for that builder without an unhandled async error.
    future.ignore();
    return future;
  }

  Future<Novel> _loadWithDeadline() async {
    final generation = ++_loadGeneration;
    _revision = _local?.bookFor(widget.novel.id)?.revision;
    var expired = false;
    _loadingLocal = true;
    void checkActive() {
      if (expired || !mounted || generation != _loadGeneration) {
        throw StateError('详情加载已取消');
      }
    }

    Future<Novel> loadBody() async {
      while (true) {
        checkActive();
        if (_local case final local?) {
          widget.state.bindLocalChapters(local);
          await local.ensureReady(widget.novel.id);
          checkActive();
        }
        final revision = _local?.bookFor(widget.novel.id)?.revision;
        final detail = await widget.repository.detail(widget.novel);
        checkActive();
        final chapters = await widget.repository.chapters(widget.novel.id);
        checkActive();
        if (_local?.bookFor(widget.novel.id)?.revision != revision) continue;
        final loaded = detail.withChapters(chapters);
        unawaited(
          widget.state
              .rememberNovel(
                loaded,
                accepts: () =>
                    !expired &&
                    mounted &&
                    generation == _loadGeneration &&
                    _local?.bookFor(widget.novel.id)?.revision == revision,
              )
              .catchError((Object error) {
                if (mounted) showNovelFeedback(context, '书籍详情保存失败，请重试');
              }),
        );
        checkActive();
        if (_local?.bookFor(widget.novel.id)?.revision != revision) continue;
        _revision = revision;
        return loaded;
      }
    }

    try {
      final loaded =
          await Future.any<Novel>([
            loadBody(),
            _disposed.future.then<Novel>((_) => throw StateError('详情页已关闭')),
          ]).timeout(
            widget.loadTimeout,
            onTimeout: () {
              expired = true;
              throw const LocalOperationTimeoutException('详情加载');
            },
          );
      checkActive();
      return loaded;
    } finally {
      if (generation == _loadGeneration) {
        _loadingLocal = false;
        if (mounted &&
            !expired &&
            _local?.bookFor(widget.novel.id)?.revision != _revision) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _localChanged());
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Novel>(
    future: _loaded,
    // Keep the destination cover's element and layout alive from the first
    // route frame through loading, errors and completion of its Hero flight.
    builder: (context, snapshot) => DetailPage(
      novel: snapshot.data ?? _cached ?? widget.novel,
      transitionNovel: widget.novel,
      coverHeroTag: widget.coverHeroTag,
      state: widget.state,
      repository: widget.repository,
      isLoading:
          !snapshot.hasData &&
          _cached == null &&
          snapshot.connectionState != ConnectionState.done,
      loadError: _cached == null ? snapshot.error : null,
      fromCache:
          (_cached != null && !snapshot.hasData) ||
          (widget.repository is OfflineNovelRepository &&
              (widget.repository as OfflineNovelRepository).isDirectoryOffline(
                widget.novel.id,
              )),
      onRetry: () => setState(() {
        _loaded = _load();
      }),
    ),
  );
}

class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.novel,
    required this.state,
    required this.repository,
    this.coverHeroTag,
    this.transitionNovel,
    this.isLoading = false,
    this.loadError,
    this.onRetry,
    this.fromCache = false,
  });
  final Novel novel;
  final LibraryState state;
  final NovelRepository repository;
  final Object? coverHeroTag;
  final Novel? transitionNovel;
  final bool isLoading;
  final Object? loadError;
  final VoidCallback? onRetry;
  final bool fromCache;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: NovelMotion.reveal,
  );
  late final AnimationController _contentIntro = AnimationController(
    vsync: this,
    duration: NovelMotion.reveal,
  );
  Animation<double>? _routeAnimation;
  bool _introStarted = false;
  bool _contentStarted = false;
  bool _readerOpening = false;
  bool _shelfChanging = false;
  int? _resumeChapter;

  /// 当前显示的书籍（编辑后更新，刷新详情页）。
  Novel? _novelOverride;

  Novel get novel => _novelOverride ?? widget.novel;
  LibraryState get state => widget.state;
  NovelRepository get repository => widget.repository;
  Object? get coverHeroTag => widget.coverHeroTag;
  Novel? get transitionNovel => widget.transitionNovel;
  bool get _titleUpdated =>
      transitionNovel != null && transitionNovel!.title != novel.title;
  bool get _authorUpdated =>
      transitionNovel != null && transitionNovel!.author != novel.author;
  bool get isLoading => widget.isLoading;
  Object? get loadError => widget.loadError;
  VoidCallback? get onRetry => widget.onRetry;
  bool get _reduceMotion =>
      state.reduceMotion || MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (_routeAnimation != animation) {
      _routeAnimation?.removeStatusListener(_routeChanged);
      _routeAnimation = animation;
      animation?.addStatusListener(_routeChanged);
    }
    if (_reduceMotion) {
      _intro.stop();
      _contentIntro.stop();
      _intro.value = 1;
      _contentIntro.value = 1;
      _introStarted = true;
      _contentStarted = !isLoading;
    } else if (animation == null ||
        animation.status == AnimationStatus.completed) {
      // A newly installed route's proxy can briefly report completed before
      // Navigator attaches the push animation at the end of its first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startIntro();
      });
    }
  }

  void _routeChanged(AnimationStatus status) {
    if (mounted && status == AnimationStatus.completed) _startIntro();
  }

  void _startIntro() {
    if (_routeAnimation != null &&
        _routeAnimation!.status != AnimationStatus.completed) {
      return;
    }
    if (!_introStarted) {
      _introStarted = true;
      _intro.forward();
    }
    if (!isLoading && !_contentStarted) {
      _contentStarted = true;
      _contentIntro.forward();
    }
  }

  @override
  void didUpdateWidget(DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_novelOverride != null && widget.novel.chapters.isNotEmpty) {
      _novelOverride = _novelOverride!.withChapters(widget.novel.chapters);
    }
    if (isLoading && !oldWidget.isLoading) {
      _contentStarted = false;
      _contentIntro.value = 0;
    } else if (!isLoading && oldWidget.isLoading) {
      if (_reduceMotion) {
        _contentIntro.value = 1;
        _contentStarted = true;
      } else if (_introStarted) {
        _startIntro();
      }
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_routeChanged);
    _intro.dispose();
    _contentIntro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Resolve a stable chapter ID once for the lazily built directory, not once
    // per visible row or once per animation/scroll frame.
    _resumeChapter = state.hasRead(novel.id) && novel.chapters.isNotEmpty
        ? state.chapterForNovel(novel)
        : null;
    final local = localLibraryOf(repository);
    final localBook = local?.bookFor(novel.id);
    final scheme = Theme.of(context).colorScheme;
    final authorEmpty = novel.author.trim().isEmpty;
    return Scaffold(
      body: Atmosphere(
        child: GlassHeaderLayout(
          header: _header(context),
          body: Stack(
            children: [
              Positioned.fill(
                child: CustomScrollView(
                  key: PageStorageKey('detail-scroll-${novel.id}'),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        MediaQuery.paddingOf(context).top +
                            FrostedHeader.toolbarHeight +
                            12,
                        24,
                        0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: RepaintBoundary(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  NovelCover(
                                    _novelOverride ?? transitionNovel ?? novel,
                                    width: 118,
                                    height: 166,
                                    heroTag: coverHeroTag,
                                    isDetailCover: true,
                                  ),
                                  const SizedBox(width: 22),
                                  Expanded(
                                    child: Padding(
                                      // Keep the title at its existing landing
                                      // position; the inverse ID plaque belongs
                                      // below the fixed header's blur feather.
                                      padding: const EdgeInsets.only(top: 32),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          RevealFromTop(
                                            key: const ValueKey(
                                              'detail-title-reveal',
                                            ),
                                            axis: ArchiveRevealAxis.horizontal,
                                            animation: _titleUpdated
                                                ? _contentIntro
                                                : _intro,
                                            end: .46,
                                            child: localBook == null
                                                ? Text(
                                                    novel.title,
                                                    maxLines: 4,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 23,
                                                      height: 1.3,
                                                    ),
                                                  )
                                                : Semantics(
                                                    button: true,
                                                    label: '修改书名',
                                                    child: JellyTapSurface(
                                                      key: const ValueKey(
                                                        'detail-edit-title',
                                                      ),
                                                      haptic:
                                                          HapticCue.selection,
                                                      onTap: () =>
                                                          _editDetailBookTitle(
                                                            context,
                                                            local!,
                                                            novel.id,
                                                          ),
                                                      child: Text(
                                                        novel.title,
                                                        maxLines: 4,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          fontSize: 23,
                                                          height: 1.3,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                          ),
                                          const SizedBox(height: 10),
                                          RevealFromTop(
                                            key: const ValueKey(
                                              'detail-author-reveal',
                                            ),
                                            axis: ArchiveRevealAxis.horizontal,
                                            animation: _authorUpdated
                                                ? _contentIntro
                                                : _intro,
                                            start: .09,
                                            end: .56,
                                            child: isLoading && authorEmpty
                                                ? const InlineSkeleton(
                                                    key: ValueKey(
                                                      'detail-author-skeleton',
                                                    ),
                                                    height: 20,
                                                    label: '正在加载作者信息',
                                                  )
                                                : localBook == null
                                                ? Text(
                                                    novel.author,
                                                    style: TextStyle(
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                      fontSize: 14,
                                                    ),
                                                  )
                                                : Semantics(
                                                    button: true,
                                                    label: '修改作者',
                                                    child: JellyTapSurface(
                                                      key: const ValueKey(
                                                        'detail-edit-author',
                                                      ),
                                                      haptic:
                                                          HapticCue.selection,
                                                      onTap: () =>
                                                          _editDetailBookAuthor(
                                                            context,
                                                            local!,
                                                            novel.id,
                                                          ),
                                                      child: Text(
                                                        authorEmpty
                                                            ? '未署名作者'
                                                            : novel.author,
                                                        style: TextStyle(
                                                          color: authorEmpty
                                                              ? scheme
                                                                    .onSurfaceVariant
                                                                    .withValues(
                                                                      alpha:
                                                                          .65,
                                                                    )
                                                              : scheme
                                                                    .onSurfaceVariant,
                                                          fontSize: 14,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                          ),
                                          const SizedBox(height: 20),
                                          RevealFromTop(
                                            key: const ValueKey(
                                              'detail-meta-reveal',
                                            ),
                                            axis: ArchiveRevealAxis.horizontal,
                                            animation: isLoading
                                                ? _intro
                                                : _contentIntro,
                                            start: .18,
                                            end: .64,
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                if (isLoading)
                                                  const InlineSkeleton(
                                                    key: ValueKey(
                                                      'detail-meta-skeleton',
                                                    ),
                                                    label: '正在加载章节信息',
                                                  )
                                                else
                                                  Text(
                                                    loadError != null
                                                        ? '目录暂未载入'
                                                        : '${novel.isComplete ? '已完结' : '连载中'}  ·  ${novel.chapters.length} 章',
                                                    style: TextStyle(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                const SizedBox(height: 8),
                                                ArchiveCode(
                                                  ArchiveDesign.fileCode(
                                                    novel.id,
                                                  ),
                                                  inverse: true,
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (repository
                                              case final OfflineNovelRepository
                                                  offline) ...[
                                            const SizedBox(height: 8),
                                            if (isLoading)
                                              const InlineSkeleton(
                                                key: ValueKey(
                                                  'detail-cache-skeleton',
                                                ),
                                                label: '正在加载缓存信息',
                                              )
                                            else if (loadError == null)
                                              RevealFromTop(
                                                key: const ValueKey(
                                                  'detail-cache-reveal',
                                                ),
                                                axis: ArchiveRevealAxis
                                                    .horizontal,
                                                animation: _contentIntro,
                                                start: .24,
                                                end: .72,
                                                child: OfflineBookStatus(
                                                  repository: offline,
                                                  novel: novel,
                                                  localDirectory:
                                                      widget.fromCache,
                                                ),
                                              )
                                            else
                                              const SizedBox(height: 18),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 35),
                              if (isLoading) ...[
                                const DetailSkeleton(),
                              ] else if (loadError != null) ...[
                                const Center(child: Text('书籍详情加载失败')),
                                Center(
                                  child: GlassTextButton(
                                    onPressed: onRetry,
                                    child: const Text('重试'),
                                  ),
                                ),
                              ] else ...[
                                RevealFromTop(
                                  key: const ValueKey('detail-summary-reveal'),
                                  animation: _contentIntro,
                                  start: .27,
                                  end: .76,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      sectionHeader(context, '简介', ''),
                                      const SizedBox(height: 13),
                                      Text(
                                        novel.summary,
                                        style: TextStyle(
                                          fontSize: 14,
                                          height: 1.75,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 32),
                                RevealFromTop(
                                  key: const ValueKey('detail-tags-reveal'),
                                  animation: _contentIntro,
                                  start: .35,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      sectionHeader(context, '标签', ''),
                                      const SizedBox(height: 13),
                                      ListenableBuilder(
                                        listenable: TagStore.shared,
                                        builder: (context, _) {
                                          final tags = TagStore.shared
                                              .tagsForBook(novel.id);
                                          void openTags() => showTagEditor(
                                            context,
                                            widget.state,
                                            novel.id,
                                            local: localLibraryOf(repository),
                                          );
                                          return Wrap(
                                            spacing: 8,
                                            runSpacing: 10,
                                            children: [
                                              for (final tag in tags)
                                                BookTagPill(
                                                  key: ValueKey(
                                                    'detail-tag-${tag.name}',
                                                  ),
                                                  tag: tag,
                                                  onTap: openTags,
                                                ),
                                              BookTagActionChip(
                                                key: const ValueKey(
                                                  'detail-edit-tags-button',
                                                ),
                                                label: tags.isEmpty
                                                    ? '添加标签'
                                                    : '编辑',
                                                icon: tags.isEmpty
                                                    ? CupertinoIcons.plus
                                                    : CupertinoIcons.tag,
                                                onTap: openTags,
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 32),
                                RevealFromTop(
                                  key: const ValueKey(
                                    'detail-directory-reveal',
                                  ),
                                  animation: _contentIntro,
                                  start: .43,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      sectionHeader(context, '目录', ''),
                                      const SizedBox(height: 7),
                                      if (novel.chapters.isEmpty)
                                        const Text('暂无章节'),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!isLoading && loadError == null)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        // Keep the directory out of a single tall Column: only
                        // visible/cache-nearby rows build, lay out and paint.
                        sliver: SliverList.builder(
                          itemCount: novel.chapters.length,
                          itemBuilder: (context, index) => RevealFromTop(
                            key: ValueKey('detail-chapter-$index'),
                            animation: _contentIntro,
                            start: .48 + index.clamp(0, 8) * .025,
                            end: .78 + index.clamp(0, 8) * .025,
                            child: _chapterRow(context, index),
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: MediaQuery.paddingOf(context).bottom + 96,
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
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    22,
                    0,
                    22,
                    MediaQuery.paddingOf(context).bottom + 12,
                  ),
                  child: RevealFromTop(
                    key: const ValueKey('detail-footer-reveal'),
                    animation: _intro,
                    start: .52,
                    child: ArchiveMotionScope(
                      animation: _contentIntro,
                      enabled: !_reduceMotion && loadError == null,
                      child: AnimatedBuilder(
                        animation: state,
                        builder: (context, _) => GlassPillButton(
                          key: const ValueKey('detail-read-button'),
                          icon: CupertinoIcons.book,
                          loading: isLoading,
                          label: _readLabel,
                          onPressed: isLoading
                              ? null
                              : loadError != null
                              ? onRetry
                              : novel.chapters.isEmpty
                              ? null
                              : () => _openReader(
                                  context,
                                  state.chapterForNovel(novel),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _readLabel {
    if (isLoading) return '正在加载目录';
    if (loadError != null) return '重试加载目录';
    if (novel.chapters.isEmpty) return '暂无可读章节';
    final action = state.hasRead(novel.id) ? '继续阅读' : '开始阅读';
    final unit =
        localLibraryOf(repository)?.kindFor(novel.id) == LocalBookKind.pdf
        ? '页'
        : '章';
    return '$action · 第${state.chapterForNovel(novel) + 1}$unit';
  }

  Widget _chapterRow(BuildContext context, int index) => JellyTapSurface(
    onTap: () => _openReader(context, index),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 17),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(
              (index + 1).toString().padLeft(2, '0'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (novel.chapters[index].volume.isNotEmpty)
                  Text(
                    novel.chapters[index].volume,
                    style: const TextStyle(fontSize: 11),
                  ),
                Text(
                  novel.chapters[index].title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          if (index == _resumeChapter) ...[
            const SizedBox(width: 8),
            Text(
              '上次阅读',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
          ],
          const ArchiveIcon(CupertinoIcons.chevron_right, size: 14),
        ],
      ),
    ),
  );

  Widget _header(BuildContext context) => Row(
    children: [
      GlassIconButton(
        icon: CupertinoIcons.back,
        label: '返回',
        onPressed: () => Navigator.pop(context),
      ),
      if (repository is OfflineNovelRepository) const SizedBox(width: 46),
      Expanded(
        child: ArchiveRouteTitle(
          title: '图书详情',
          code: ArchiveDesign.fileCode(novel.id),
        ),
      ),
      if (repository case final OfflineNovelRepository offline)
        if (isLoading || loadError != null || novel.chapters.isEmpty)
          const GlassIconButton(
            icon: CupertinoIcons.cloud_download,
            label: '下载与缓存',
            onPressed: null,
          )
        else
          OfflineBookMenu(
            repository: offline,
            novel: novel,
            startChapter: state.chapterForNovel(novel),
            reduceMotion: state.reduceMotion,
          ),
      AnimatedBuilder(
        animation: state,
        builder: (context, child) => GlassIconButton(
          icon: state.contains(novel.id)
              ? CupertinoIcons.bookmark_fill
              : CupertinoIcons.bookmark,
          label: state.contains(novel.id) ? '移出书架' : '加入书架',
          onPressed: () async {
            if (_shelfChanging) return;
            _shelfChanging = true;
            try {
              await state.toggleShelf(novel.id, novel: novel);
            } catch (_) {
              if (context.mounted) showNovelFeedback(context, '书架操作保存失败，请重试');
            } finally {
              _shelfChanging = false;
            }
          },
        ),
      ),
      // 本地书：更多操作（删除文件）。
      if (localLibraryOf(repository)?.bookFor(novel.id) != null)
        GlassIconButton(
          icon: CupertinoIcons.ellipsis,
          label: '更多操作',
          onPressed: () => _detailMenu(context),
        ),
    ],
  );

  /// 详情页的本地书操作菜单：删除文件。
  Future<void> _detailMenu(BuildContext context) async {
    final local = localLibraryOf(repository);
    if (local == null || local.bookFor(novel.id) == null) return;
    final action = await showGlassMenu<String>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (menuContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassMenuItem(
            label: '删除文件',
            onPressed: () => Navigator.of(menuContext).pop('delete'),
          ),
        ],
      ),
    );
    if (!mounted || !context.mounted || action == null) return;
    if (action == 'delete') {
      await _deleteDetailBookFile(context, local, novel.id);
    }
  }

  /// 点击详情页书名：弹出修改书名弹窗，保存成功后刷新详情页显示。
  Future<void> _editDetailBookTitle(
    BuildContext context,
    LocalLibraryStore local,
    int id,
  ) async {
    final updated = await showLocalBookTitleEditor(
      context,
      state: state,
      local: local,
      bookId: id,
    );
    if (updated != null && mounted) {
      setState(
        () => _novelOverride =
            local.toNovel(updated).withChapters(novel.chapters),
      );
    }
  }

  /// 点击详情页作者名：弹出修改作者弹窗，保存成功后刷新详情页显示。
  Future<void> _editDetailBookAuthor(
    BuildContext context,
    LocalLibraryStore local,
    int id,
  ) async {
    final updated = await showLocalBookAuthorEditor(
      context,
      state: state,
      local: local,
      bookId: id,
    );
    if (updated != null && mounted) {
      setState(
        () => _novelOverride =
            local.toNovel(updated).withChapters(novel.chapters),
      );
    }
  }

  /// 删除文件（详情页版）：双确认，成功后返回上一页。
  Future<void> _deleteDetailBookFile(
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
    if (successText == null || !mounted) return;
    // 文件已删，详情页无意义，返回上一页。
    // pop 前先取到 ScaffoldMessenger：pop 后再用 context 找 messenger，
    // 可能拿到正在退场路由的，反馈挂上去用户看不到；
    // 也不依赖"pop 后 context 仍 mounted"这一时序。
    final messenger = context.mounted
        ? ScaffoldMessenger.maybeOf(context)
        : null;
    if (context.mounted) Navigator.of(context).pop();
    messenger
      ?..hideCurrentSnackBar()
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(cleanupOk ? successText : '书籍已移除，但部分关联数据未清干净')),
      );
  }

  Future<void> _openReader(BuildContext context, int chapter) async {
    if (_readerOpening || !mounted || !context.mounted) return;
    _readerOpening = true;
    try {
      final Widget page = readerPageFor(
        novel: novel,
        state: state,
        repository: repository,
        chapter: chapter,
      );
      await pushNovelPage<void>(
        context,
        page,
        reduceMotion: state.reduceMotion,
      );
    } finally {
      _readerOpening = false;
      // Reader exit persists its final anchor without broadcasting scroll
      // changes. Refresh the label and directory marker once, without replay.
      if (mounted) setState(() {});
    }
  }
}

/// One place decides which reader opens a book, so every entry point (detail
/// page, bookmark library, …) gets the same TXT / EPUB / PDF reader.
Widget readerPageFor({
  required Novel novel,
  required LibraryState state,
  required NovelRepository repository,
  required int chapter,
  ReaderBookmark? bookmark,
}) {
  final local = localLibraryOf(repository);
  final kind = local?.kindFor(novel.id);
  if (local != null && kind == LocalBookKind.pdf) {
    return LocalPdfReaderPage(
      novel: novel,
      state: state,
      local: local,
      // PDF page bookmarks store the page in `chapter`.
      initialPage: bookmark == null ? null : chapter,
    );
  }
  if (local != null && kind == LocalBookKind.epub) {
    // EPUB bookmarks land on their chapter; the EPUB reader has no
    // paragraph-level landing yet, so the stored offset is not replayed.
    return LocalEpubReaderPage(
      novel: novel,
      state: state,
      local: local,
      initialChapter: chapter,
    );
  }
  return ReaderPage(
    novel: novel,
    state: state,
    repository: repository,
    initialChapter: chapter,
    initialBookmark: bookmark,
  );
}

