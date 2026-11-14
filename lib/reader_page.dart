part of 'pages.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.novel,
    required this.state,
    required this.repository,
    required this.initialChapter,
    this.initialBookmark,
  });
  final Novel novel;
  final LibraryState state;
  final NovelRepository repository;
  final int initialChapter;
  final ReaderBookmark? initialBookmark;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late Novel _novel = widget.novel;
  LocalLibraryStore? get _local =>
      isLocalNovelId(_novel.id) ? localLibraryOf(widget.repository) : null;
  bool _reloadingLocal = false;
  bool _localReloadPending = false;

  void _localChanged() {
    final local = _local;
    final book = local?.bookFor(_novel.id);
    if (!mounted || local == null || book == null) return;
    if (_reloadingLocal) {
      _localReloadPending = true;
      return;
    }
    if (!local.isMigrationPending(_novel.id) &&
        _novel.chapters.isNotEmpty &&
        _novel.chapters.first.revision == book.revision) {
      return;
    }
    _savePosition(notify: false);
    _idleSave?.cancel();
    _ready = false;
    _currentContent = null;
    _contentGeneration++;
    _restoreTicket++;
    _followTicket++;
    _followScroll.cancel();
    _reloadingLocal = true;
    _parsedChapters.clear();
    _resolvedChapters.clear();
    setState(() {
      _content = _reloadLocalContent();
    });
  }

  Future<({ReaderContent? content, Object? error})> _reloadLocalContent({
    bool initial = false,
  }) async {
    _reloadingLocal = true;
    try {
      final chapters = await widget.repository.chapters(_novel.id);
      if (!mounted) {
        return (content: null, error: const StaleLocalChapterException());
      }
      final saved = widget.state.positionFor(_novel.id);
      final initialMark = initial ? widget.initialBookmark : null;
      final freshSelection =
          initial &&
          _novel.chapters.isNotEmpty &&
          chapters.isNotEmpty &&
          _novel.chapters.first.revision == chapters.first.revision;
      _novel = _novel.withChapters(chapters);
      final savedIndex = saved == null
          ? null
          : widget.state.chapterForPosition(_novel, saved);
      final markIndex = initialMark == null
          ? null
          : widget.state.chapterForPosition(_novel, initialMark.position);
      final index =
          markIndex ?? (freshSelection ? widget.initialChapter : savedIndex ?? 0);
      if (index < 0 || index >= chapters.length) {
        throw const StaleLocalChapterException();
      }
      _chapter = index;
      if (initialMark != null && markIndex == index) {
        _restorePending = initialMark.position;
        _bookmarkLandingPending = true;
        if (!initialMark.isUnderline && initialMark.quote.isEmpty) {
          _activeBookmarkId = initialMark.id;
        }
      } else {
        _restorePending = savedIndex == index ? saved : null;
      }
      _restoreQueued = false;
      _restoring = false;
      _computeChapterWeights();
      return await _loadContent();
    } catch (error) {
      return (content: null, error: error);
    } finally {
      _reloadingLocal = false;
      if (_localReloadPending && mounted) {
        _localReloadPending = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _localChanged();
        });
      }
    }
  }

  late int _chapter = _novel.chapters.isEmpty
      ? 0
      : widget.initialChapter.clamp(0, _novel.chapters.length - 1);
  late Future<({ReaderContent? content, Object? error})> _content;
  ReaderContent? _currentContent;
  bool _illustrationsRefreshing = false;
  final _findMatch = ValueNotifier<ReaderMatch?>(null);
  final _bookmarkLanding = ValueNotifier<int?>(null);
  Timer? _bookmarkLandingTimer;
  bool _bookmarkLandingPending = false;
  bool _openedForBookmarkInspection = false;
  Timer? _highlightTimer;
  // Stable chapter IDs/paragraph anchors own restoration; do not also walk
  // PageStorage and persist the viewport on every interrupted fling.
  final _scroll = ScrollController(keepScrollOffset: false);
  // P3: 横排翻页 / 竖排翻页 use the existing paged engine; 上下滚动 keeps
  // every scroll path below unchanged.
  final _paged = ReaderPagedController();
  int _pagedTurn = 0;
  ReaderMode? _lastMode;
  ReadingPosition? _pagedRestoreSource, _pagedRestore, _settingsPosition;
  bool get _paginated =>
      widget.state.readerPreferences.mode.paginated &&
      _novel.chapters.isNotEmpty;
  late final _followScroll = ReaderFollowScroll(_scroll);
  final _paragraphRegistry = ReaderParagraphRegistry();
  // 阅读进度条：章节字数权重 + 章内滚动比例。
  List<int> _chapterWeights = const [];
  List<int> _chapterPrefix = const [0];
  int _totalWeight = 0;
  final _progressValue = ValueNotifier<double>(0);
  late final _progressBarVisible = ValueNotifier<bool>(_showProgressBar);
  final _bookmarkedState = ValueNotifier<bool>(false);
  final _pagedPageTick = ValueNotifier<int>(0);
  bool _progressDragging = false;
  double _dragValue = 0;
  // 拖拽 accepted 后底层指针取消可能走 onEnd 而非 onCancel，
  // 用该标记区分"取消却进了 onEnd"，避免误提交跳转。
  bool _progressPointerCancelled = false;
  ReadingPosition? _restorePending;
  bool _restoreQueued = false;
  bool _restoring = false;
  bool _ready = false;
  bool _addingBookmark = false;
  int _paragraphCount = 0;
  bool _saveQueued = false;
  Timer? _idleSave;
  final _activityOverlays = <String>{};
  bool get _catalogueOpen => _activityOverlays.contains('catalogue');
  set _catalogueOpen(bool value) => _activityOverlay('catalogue', value);
  bool get _toolsOpen => _activityOverlays.contains('tools');
  set _toolsOpen(bool value) => _activityOverlay('tools', value);
  bool get _findOpen => _activityOverlays.contains('find');
  set _findOpen(bool value) => _activityOverlay('find', value);
  bool get _listeningOpen => _activityOverlays.contains('listening');
  set _listeningOpen(bool value) => _activityOverlay('listening', value);
  late ReadingActivitySession _readingActivity;
  bool _activityAttached = false;
  bool _activityForeground = true;
  bool _activityRouteCurrent = true;
  bool _activityStartQueued = false;

  void _activityOverlay(String overlay, bool open) {
    if (_activityOverlays.contains(overlay) == open) return;
    if (open) {
      _activityOverlays.add(overlay);
    } else {
      _activityOverlays.remove(overlay);
    }
    _syncReadingActivity();
  }

  bool get _activityEligible =>
      _activityAttached &&
      _activityForeground &&
      _activityRouteCurrent &&
      _ready &&
      !_restoring &&
      _activityOverlays.isEmpty &&
      (_currentContent?.paragraphs.isNotEmpty ?? false);

  void _syncReadingActivity() {
    if (!_activityAttached) return;
    if (!_activityEligible) {
      _readingActivity.setActive(false);
    } else if (!_readingActivity.active && !_activityStartQueued) {
      _activityStartQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _activityStartQueued = false;
        if (mounted && _activityAttached) {
          _readingActivity.setActive(_activityEligible);
        }
      });
    }
  }

  ListeningController? _listening;
  (int, int, int, int)? _listeningTarget;
  String? _listeningError;
  int _followTicket = 0;
  bool _followLocallyPaused = false;
  bool _followAutomatic = false;
  int _restoreTicket = 0;
  double _layoutWidth = 0;
  String _layoutFontId = 'system';
  bool _typographyPreviewing = false;
  double _layoutTextScale = 1;
  double _readingInset = 0;
  int _contentGeneration = 0;
  // Parsed chapters keyed by "revision|id"; neighbours are warmed after each
  // open so stepping or quickly flicking chapters skips read + parse.
  final Map<String, Future<ReaderContent>> _parsedChapters = {};
  // Same entries as [_parsedChapters] once parsed, so a cached chapter can be
  // shown in the very first frame instead of flashing the skeleton.
  final Map<String, ReaderContent> _resolvedChapters = {};
  ({int generation, ReaderContent content})? _instant;
  static const _parsedChapterLimit = 8;
  Timer? _prefetchTimer;

  String _parsedKey(int index) {
    final c = _novel.chapters[index];
    return '${c.revision}|${c.id}|$index';
  }

  Future<ReaderContent> _parsedChapter(int index, {bool refresh = false}) {
    final key = _parsedKey(index);
    if (!refresh) {
      final hit = _parsedChapters.remove(key);
      if (hit != null) return _parsedChapters[key] = hit;
    }
    _resolvedChapters.remove(key);
    final future = _requestContent(
      index,
      refresh: refresh,
    ).then(ReaderContent.parse);
    _parsedChapters[key] = future;
    // Failed reads must not stick in the cache.
    future.then<void>(
      (content) {
        if (identical(_parsedChapters[key], future)) {
          _resolvedChapters[key] = content;
        }
      },
      onError: (Object _) {
        if (identical(_parsedChapters[key], future)) {
          _parsedChapters.remove(key);
        }
      },
    );
    while (_parsedChapters.length > _parsedChapterLimit) {
      _resolvedChapters.remove(_parsedChapters.keys.first);
      _parsedChapters.remove(_parsedChapters.keys.first);
    }
    return future;
  }

  void _prefetchNeighbours(int index, int generation) {
    // Only local files are free to read ahead; remote sources stay on demand.
    if (!isLocalNovelId(_novel.id)) return;
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted || generation != _contentGeneration) return;
      for (final next in [index + 1, index - 1]) {
        if (next < 0 || next >= _novel.chapters.length) continue;
        if (_parsedChapters.containsKey(_parsedKey(next))) continue;
        unawaited(_parsedChapter(next).then((_) {}, onError: (_) {}));
      }
    });
  }

  late final AnimationController _chapterReveal;
  bool _chapterRevealPending = false;
  int _chapterRevealFirst = 0;
  late final AnimationController _chrome;
  bool _chromeTarget = true;
  final _selection = ReaderSelectionController();

  late Listenable _bookmarkMerged;
  late Listenable _statusExtraMerged;
  bool _deferredProgressSync = false;
  bool _pagedTickQueued = false;

  void _rebuildMergedListenables() {
    _bookmarkMerged = Listenable.merge([
      _bookmarkedState,
      widget.state.readerSettingsChanges,
    ]);
    _statusExtraMerged = Listenable.merge([
      _pagedPageTick,
      widget.state.readerSettingsChanges,
    ]);
  }

  void _notifyPagedStatus() {
    if (!mounted || !_activityAttached) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_pagedTickQueued) return;
      _pagedTickQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pagedTickQueued = false;
        if (mounted && _activityAttached) _pagedPageTick.value++;
      });
      return;
    }
    _pagedPageTick.value++;
  }

  void _syncBookmarkedState() {
    if (!mounted || !_activityAttached) return;
    final next = _isCurrentPositionBookmarked;
    if (_bookmarkedState.value != next) {
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        _scheduleDeferredProgressSync();
        return;
      }
      _bookmarkedState.value = next;
    }
  }

  void _scheduleDeferredProgressSync() {
    if (_deferredProgressSync) return;
    _deferredProgressSync = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _deferredProgressSync = false;
      if (mounted && _activityAttached) {
        _applyProgressFromScroll();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(ReaderPurificationStore.shared.ensureLoaded());
    _rebuildMergedListenables();
    _readingActivity = ReadingActivitySession(
      store: widget.state.readingActivity,
      bookId: _novel.id,
    );
    _activityAttached = true;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _activityForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (_local case final local?) {
      widget.state.bindLocalChapters(local);
      local.addListener(_localChanged);
    }
    _computeChapterWeights();
    _scroll.addListener(_updateProgressFromScroll);
    widget.state.bookmarkChanges.addListener(_syncBookmarkedState);
    _bookmarkLanding.addListener(_syncBookmarkedState);
    _progressValue.addListener(_syncBookmarkedState);
    _chapterReveal = AnimationController(
      vsync: this,
      duration: NovelMotion.enter,
      value: 1,
    );
    _chrome = AnimationController(
      vsync: this,
      duration: NovelMotion.chromeShow,
      reverseDuration: NovelMotion.chromeHide,
      value: 1,
    );
    WidgetsBinding.instance.addObserver(this);
    final saved = widget.state.positionFor(_novel.id);
    if (widget.initialBookmark case final mark?) {
      _openedForBookmarkInspection = saved != null;
      final markChapter = _novel.chapters.isEmpty
          ? null
          : widget.state.chapterForPosition(_novel, mark.position);
      if (markChapter != null) _chapter = markChapter;
      _restorePending = mark.position;
      _bookmarkLandingPending = true;
      if (!mark.isUnderline && mark.quote.isEmpty) {
        _activeBookmarkId = mark.id;
      }
    } else if (saved != null &&
        _novel.chapters.isNotEmpty &&
        (saved.chapterId > 0
            ? saved.chapterId == _novel.chapters[_chapter].id
            : saved.chapter == _chapter)) {
      _restorePending = saved;
    }
    _syncBookmarkedState();
    _content = _local != null
        ? _reloadLocalContent(initial: true)
        : _loadContent();
  }

  @override
  void didUpdateWidget(covariant ReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.bookmarkChanges.removeListener(_syncBookmarkedState);
      widget.state.bookmarkChanges.addListener(_syncBookmarkedState);
      _rebuildMergedListenables();
      _readingActivity.dispose();
      _readingActivity = ReadingActivitySession(
        store: widget.state.readingActivity,
        bookId: _novel.id,
      );
      _syncReadingActivity();
      _syncBookmarkedState();
    }
  }

  @override
  void deactivate() {
    _readingActivity.setActive(false);
    _activityAttached = false;
    // The Scrollable child detaches its controller before this State's dispose.
    // Capture while it is still attached, also when idle-save is pending.
    _idleSave?.cancel();
    _followTicket++;
    _followScroll.cancel();
    _savePosition(notify: false, finalSave: true);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _activityAttached = true;
    _syncReadingActivity();
  }

  @override
  void dispose() {
    _readingActivity.dispose();
    _local?.removeListener(_localChanged);
    widget.state.bookmarkChanges.removeListener(_syncBookmarkedState);
    _bookmarkLanding.removeListener(_syncBookmarkedState);
    _progressValue.removeListener(_syncBookmarkedState);
    _idleSave?.cancel();
    _prefetchTimer?.cancel();
    _savePosition(notify: false, finalSave: true);
    _highlightTimer?.cancel();
    _findMatch.dispose();
    _progressValue.dispose();
    _progressBarVisible.dispose();
    _bookmarkedState.dispose();
    _pagedPageTick.dispose();
    _bookmarkLandingTimer?.cancel();
    _bookmarkLanding.dispose();
    _listening?.snapshot.removeListener(_listeningChanged);
    _followTicket++;
    _followScroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _selection.dispose();
    _scroll.dispose();
    _chapterReveal.dispose();
    _chrome.dispose();
    super.dispose();
  }

  void _updateRouteCurrent(bool routeCurrent) {
    if (_activityRouteCurrent != routeCurrent) {
      _activityRouteCurrent = routeCurrent;
      _syncReadingActivity();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final listening = ListeningScope.maybeOf(context);
    if (listening != _listening) {
      _listening?.snapshot.removeListener(_listeningChanged);
      _listening = listening;
      listening?.snapshot.addListener(_listeningChanged);
      _listeningTarget = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _listeningChanged();
      });
    } else if (listening != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _listeningChanged();
      });
    }
    if (!_ready || _restoring || _layoutWidth <= 0) return;
    final width = MediaQuery.sizeOf(context).width;
    final scale =
        MediaQuery.textScalerOf(context).scale(widget.state.fontSize) /
        widget.state.fontSize;
    if ((width - _layoutWidth).abs() >= 1 ||
        (scale - _layoutTextScale).abs() >= .01 ||
        _layoutFontId != widget.state.effectiveReaderFontId) {
      final position = _currentPosition();
      if (position != null) _prepareRestore(position);
    }
  }

  Future<void> _listen() async {
    final listening = _listening;
    if (listening == null ||
        _listeningOpen ||
        _toolsOpen ||
        _catalogueOpen ||
        _findOpen) {
      return;
    }
    _listeningOpen = true;
    _followTicket++;
    _followScroll.cancel();
    try {
      await showListeningPanel(
        context,
        controller: listening,
        novel: _novel,
        chapter: _chapter,
        paragraph: _currentPosition()?.paragraphIndex ?? 0,
        reduceMotion: widget.state.reduceMotion,
      );
    } finally {
      _listeningOpen = false;
      _listeningTarget = null;
      if (mounted) _listeningChanged();
    }
  }

  void _suspendListeningFollow({bool userDrag = false}) {
    final listening = _listening;
    _followTicket++;
    _followScroll.cancel(userDrag: userDrag);
    if (listening != null &&
        listening.snapshot.value.active &&
        listening.snapshot.value.novel?.id == _novel.id &&
        listening.snapshot.value.follow) {
      _followLocallyPaused = true;
      unawaited(listening.setFollow(false).catchError((Object _) {}));
    }
  }

  void _listeningChanged() {
    final state = _listening?.snapshot.value;
    if (state != null && state.novel?.id == _novel.id && state.playing) {
      _readingActivity.notifyInteraction();
    }
    final current = state?.current;
    if (state?.error == null) _listeningError = null;
    if (mounted &&
        state?.novel?.id == _novel.id &&
        state?.error != null &&
        state!.error != _listeningError) {
      final error = _listeningError = state.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !_listeningOpen &&
            ModalRoute.of(context)?.isCurrent != false &&
            _listening?.snapshot.value.error == error) {
          showNovelFeedback(
            context,
            error!,
            actionLabel: '听书',
            action: _listen,
          );
        }
      });
    }
    if (state == null || !state.active || !state.follow) {
      _followLocallyPaused = false;
    }
    if (state == null ||
        !state.active ||
        state.novel?.id != _novel.id ||
        !_listeningScrollSceneActive) {
      _listeningTarget = null;
      _followTicket++;
      _followScroll.cancel();
      return;
    }
    if (!state.follow || _followLocallyPaused || current == null) {
      _listeningTarget = null;
      if (_followAutomatic) {
        _followTicket++;
        _followScroll.cancel();
        _followAutomatic = false;
      }
      return;
    }
    final target = (_novel.id, state.chapter, current.paragraph, current.start);
    if (_listeningTarget == target) return;
    _listeningTarget = target;
    if (state.chapter != _chapter) _go(state.chapter, listeningFollow: true);
    _revealListeningFragment(
      state.chapter,
      current.paragraph,
      current.start,
      current.end,
      automatic: true,
    );
  }

  bool get _listeningScrollSceneActive =>
      mounted &&
      !_listeningOpen &&
      !_toolsOpen &&
      !_catalogueOpen &&
      !_findOpen &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) &&
      ModalRoute.of(context)?.isCurrent != false;

  void _revealListeningFragment(
    int chapter,
    int paragraph,
    int start,
    int end, {
    required bool automatic,
  }) {
    final ticket = ++_followTicket;
    _followAutomatic = automatic;
    _followScroll.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool allowed() =>
          _listeningScrollSceneActive &&
          ticket == _followTicket &&
          _chapter == chapter &&
          _listening?.snapshot.value.active == true &&
          _listening?.snapshot.value.novel?.id == _novel.id &&
          (!automatic ||
              (_listening?.snapshot.value.follow == true &&
                  !_followLocallyPaused));
      if (!allowed()) return;
      try {
        await _followScroll.reveal(
          allowed: allowed,
          reduceMotion:
              widget.state.reduceMotion ||
              MediaQuery.disableAnimationsOf(context),
          target: () =>
              !_ready ||
                  _restoring ||
                  _restorePending != null ||
                  !_scroll.hasClients
              ? null
              : _paragraphRegistry.speechTarget(
                  paragraph,
                  start,
                  end,
                  _readingInset,
                  viewportBottom:
                      _scroll.position.viewportDimension -
                      MediaQuery.paddingOf(context).bottom -
                      116,
                  trailingSpace: 12,
                ),
        );
      } finally {
        if (ticket == _followTicket) _followAutomatic = false;
      }
    });
    // Adding a post-frame callback alone does not request a frame. In a static
    // chapter or after resuming, explicitly wake the one requested landing.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _doubleTapListeningParagraph(int paragraph) async {
    final listening = _listening;
    if (listening == null) return;
    final state = listening.snapshot.value;
    final other =
        state.active &&
        state.novel?.id == _novel.id &&
        (state.chapter != _chapter || state.current?.paragraph != paragraph);
    final action = listening.paragraphDoubleTap(
      novelId: _novel.id,
      chapter: _chapter,
      paragraph: paragraph,
    );
    // An explicit double-tap is a one-off soft landing even after a manual
    // scroll suspended following. It never flips the user's follow preference.
    if (other &&
        (!state.follow || _followLocallyPaused) &&
        _currentContent != null) {
      final text = _currentContent!.paragraphs[paragraph];
      _revealListeningFragment(
        _chapter,
        paragraph,
        0,
        text.length.clamp(0, 240),
        automatic: false,
      );
    }
    await action;
  }

  /// 计算每章的字数权重（去空白字符数），用于全书进度。
  void _computeChapterWeights() {
    // 本地书的 NovelChapter.content 为空（正文懒加载），不能用它算字数：
    // TXT 用章节索引的 length 做权重，PDF 按页等权；在线书才用 content 长度。
    final local = localLibraryOf(widget.repository)?.bookFor(_novel.id);
    if (local != null) {
      if (local.kind == LocalBookKind.pdf) {
        _chapterWeights = List.filled(_novel.chapters.length, 1);
      } else {
        _chapterWeights = [for (final c in local.chapters) c.length];
      }
    } else {
      final chapters = _novel.chapters;
      _chapterWeights = [
        for (final c in chapters)
          c.content.replaceAll(_readerWhitespace, '').runes.length,
      ];
    }
    _totalWeight = _chapterWeights.fold(0, (a, b) => a + b);
    if (_totalWeight <= 0 && _chapterWeights.isNotEmpty) {
      _chapterWeights = List.filled(_chapterWeights.length, 1);
      _totalWeight = _chapterWeights.length;
    }
    _chapterPrefix = <int>[0];
    for (final weight in _chapterWeights) {
      _chapterPrefix.add(_chapterPrefix.last + weight);
    }
  }

  /// 章内滚动比例（0~1）。
  double get _chapterScrollRatio {
    if (_paginated) return _paged.fraction;
    if (!_scroll.hasClients) return 0;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return 0;
    return (_scroll.offset / max).clamp(0.0, 1.0);
  }

  /// 当前章节进度（0~1）。
  double _bookProgress() {
    if (_novel.chapters.isEmpty) return 0;
    return _chapterScrollRatio.clamp(0.0, 1.0);
  }

  /// 滚动时更新进度条（拖动中不跟随，避免打架）。
  void _updateProgressFromScroll() {
    if (!mounted || !_activityAttached) return;
    _readingActivity.notifyInteraction();
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _scheduleDeferredProgressSync();
      return;
    }
    _applyProgressFromScroll();
  }

  void _applyProgressFromScroll() {
    if (!mounted || !_activityAttached) return;
    _syncProgressBarVisibility();
    final nextBookmarked = _isCurrentPositionBookmarked;
    if (_bookmarkedState.value != nextBookmarked) {
      _bookmarkedState.value = nextBookmarked;
    }
    if (_progressDragging) return;
    final v = _bookProgress();
    if ((v - _progressValue.value).abs() > 0.0005) {
      _progressValue.value = v;
    }
  }

  void _syncProgressBarVisibility() {
    final visible = _showProgressBar;
    if (_progressBarVisible.value != visible) {
      _progressBarVisible.value = visible;
    }
  }

  /// 进度条是否显示：多章，或单章可滚动/多页时显示。
  bool get _showProgressBar {
    if (_novel.chapters.length > 1) return true;
    if (_paginated) return _paged.pageCount > 1;
    return _scroll.hasClients && _scroll.position.maxScrollExtent > 0;
  }

  /// 把当前章进度换算为当前章节和章内比例。
  ({int chapter, double ratio}) _progressToTarget(double progress) {
    if (_novel.chapters.isEmpty) {
      return (chapter: 0, ratio: 0);
    }
    final current = _chapter.clamp(0, _novel.chapters.length - 1);
    return (chapter: current, ratio: progress.clamp(0.0, 1.0));
  }

  /// 拖动结束：跳转到当前章节目标位置。
  Future<void> _jumpToProgress(double progress) async {
    final target = _progressToTarget(progress);
    if (!mounted) return;
    await _seekProgress(target.ratio);
    if (!mounted) return;
    _updateProgressFromScroll();
  }

  /// 拖动预览文字：第 N 章 · X%。
  String _dragPreviewText(double progress) {
    final target = _progressToTarget(progress);
    final pct = (target.ratio * 100).round();
    return '${isLocalNovelId(_novel.id) ? '目录项 ${target.chapter + 1}' : '第 ${target.chapter + 1} 章'} · $pct%';
  }

  void _go(
    int index, {
    ReadingPosition? position,
    bool highlightBookmark = false,
    bool listeningFollow = false,
  }) {
    if (index < 0 || index >= _novel.chapters.length) {
      return;
    }
    _openedForBookmarkInspection = false;
    _selection.clear();
    _pagedTurn = 0;
    if (!listeningFollow) _suspendListeningFollow();
    _clearBookmarkLanding();
    _bookmarkLandingPending = highlightBookmark;
    if (highlightBookmark) {
      _highlightTimer?.cancel();
      _findMatch.value = null;
    }
    if (index == _chapter) {
      if (position == null) return;
      _prepareRestore(position);
      setState(() {});
      return;
    }
    _idleSave?.cancel();
    _savePosition(notify: false);
    _highlightTimer?.cancel();
    _findMatch.value = null;
    _currentContent = null;
    _illustrationsRefreshing = false;
    _ready = false;
    _restorePending = position;
    _restoreQueued = false;
    _restoring = false;
    _restoreTicket++;
    setState(() {
      _chapter = index;
      _content = _loadContent();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _syncBookmarkedState();
    // 章节切换后刷新进度条（新章节从头开始）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncProgressBarVisibility();
        _progressValue.value = _bookProgress();
        _syncBookmarkedState();
      }
    });
  }

  Future<void> _catalogue() async {
    if (_catalogueOpen ||
        _listeningOpen ||
        _toolsOpen ||
        _findOpen ||
        _novel.chapters.isEmpty) {
      return;
    }
    _selection.clear();
    var catalogueRevision = _novel.chapters.first.revision;
    final canResplitTxt =
        _local != null &&
        isLocalNovelId(_novel.id) &&
        _local!.bookFor(_novel.id)?.kind == LocalBookKind.txt;
    _catalogueOpen = true;
    _followTicket++;
    _followScroll.cancel();
    try {
      final picked = await showJellySheet<Object>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        builder: (sheetContext) => ReaderMarksSheet(
          state: widget.state,
          novel: _novel,
          currentChapter: _chapter,
          cache: offlineRepositoryForBook(widget.repository, _novel.id)?.cache,
          onPickUnderline: _ready && _currentContent != null
              ? () => _pickChapterTextInMarksSheet(sheetContext: sheetContext)
              : null,
          onEditMark: (mark) =>
              _editBookmarkAnnotation(mark, sheetContext: sheetContext),
          onConfigureTocRule: canResplitTxt
              ? (customPattern, maxChapterChars) async {
                  final updated = await _local!.resplitTxtChapters(
                    _novel.id,
                    customPattern: customPattern,
                    maxChapterChars: maxChapterChars,
                  );
                  if (updated != null &&
                      mounted &&
                      updated.chapters.isNotEmpty) {
                    _parsedChapters.clear();
                    _resolvedChapters.clear();
                    setState(() {
                      _novel = updated;
                      catalogueRevision = _novel.chapters.first.revision;
                      final migratedPos = widget.state.positionFor(_novel.id);
                      final targetChapter =
                          migratedPos != null &&
                              migratedPos.revision == catalogueRevision
                          ? migratedPos.chapter
                          : _chapter;
                      _chapter = targetChapter.clamp(
                        0,
                        _novel.chapters.length - 1,
                      );
                      _computeChapterWeights();
                      _content = _loadContent();
                    });
                  }
                  return updated;
                }
              : null,
        ),
      );
      if (mounted && picked is ReaderBookmark) {
        final chapter = widget.state.chapterForPosition(
          _novel,
          picked.position,
        );
        if (chapter != null) {
          _go(chapter, position: picked.position, highlightBookmark: true);
          if (!picked.isUnderline && picked.quote.isEmpty) {
            _activeBookmarkId = picked.id;
          }
        }
        return;
      }
      final index = picked is int ? picked : null;
      if (mounted &&
          index != null &&
          _novel.chapters.first.revision == catalogueRevision &&
          !(_local?.isMigrationPending(_novel.id) ?? false)) {
        _go(index);
      }
    } finally {
      _catalogueOpen = false;
      _listeningTarget = null;
      if (mounted) _listeningChanged();
    }
  }

  Future<({ReaderContent? content, Object? error})> _loadContent({
    bool refresh = false,
  }) async {
    final index = _chapter;
    final generation = ++_contentGeneration;
    _chapterRevealPending = false;
    _chapterReveal.value = 1;
    final cached = refresh ? null : _resolvedChapters[_parsedKey(index)];
    _instant = cached == null
        ? null
        : (generation: generation, content: cached);
    if (cached != null) _currentContent = cached;
    // Picker results can arrive between frames. Carry expected request failure
    // as data, rather than an exceptional future awaiting the next UI listener.
    try {
      final content = await _parsedChapter(index, refresh: refresh);
      if (mounted && index == _chapter && generation == _contentGeneration) {
        _currentContent = content;
        _prefetchNeighbours(index, generation);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _contentGeneration) {
            _listeningTarget = null;
            _listeningChanged();
            if (content.paragraphs.any((p) => p.trim() == '[插图]') &&
                offlineRepositoryForBook(widget.repository, _novel.id) !=
                    null) {
              unawaited(_refreshIllustrations(automatic: true));
            }
          }
        });
        // Design §4: the 420ms paragraph entrance on chapter change is
        // optional and off by default (ReaderPreferences.chapterEntrance).
        final reduce =
            widget.state.reduceMotion ||
            MediaQuery.disableAnimationsOf(context) ||
            !widget.state.readerPreferences.chapterEntrance;
        if (reduce) {
          _chapterReveal.value = 1;
        } else {
          _chapterRevealPending = true;
          _chapterReveal.value = 0;
        }
      }
      return (content: content, error: null);
    } catch (error) {
      if (mounted && generation == _contentGeneration) _showChrome(true);
      return (content: null, error: error);
    }
  }

  void _showChrome(bool visible) {
    _chromeTarget = visible;
    if (widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      _chrome.value = visible ? 1 : 0;
    } else if (visible) {
      _chrome.forward();
    } else {
      _chrome.reverse();
    }
  }

  void _revealChapter() {
    if (!_chapterRevealPending || !_ready || !_scroll.hasClients) return;
    _chapterRevealPending = false;
    // Reveal the restored viewport, not offscreen paragraphs at chapter start.
    // The anchor render objects remain outside the visual transform so saving,
    // typography changes and lazy restoration keep the same coordinates.
    final first =
        _paragraphRegistry.capture(_scroll.offset + _readingInset)?.index ?? 0;
    if (_chapterRevealFirst != first) {
      setState(() => _chapterRevealFirst = first);
    }
    if (widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      _chapterReveal.value = 1;
    } else {
      _chapterReveal.forward(from: 0);
    }
  }

  void _toggleChrome() {
    if (_ready &&
        !_toolsOpen &&
        !_catalogueOpen &&
        !_findOpen &&
        !_listeningOpen) {
      _showChrome(!_chromeTarget);
    }
  }

  void _tapAt(Offset position, Size size, {Offset? globalPosition}) {
    if (_selection.value) {
      _selection.clear();
      return;
    }
    if (globalPosition != null) {
      final hit = _selection.hitOffsetAt(globalPosition);
      if (hit != null) {
        final mark = _underlineBookmarkAt(
          hit.paragraph,
          hit.offset,
          chapterId: hit.chapter,
        );
        if (mark != null) {
          unawaited(_editBookmarkAnnotation(mark));
          return;
        }
      }
    }
    final prefs = widget.state.readerPreferences;
    if (prefs.edgeDeadZone > 0 &&
        (position.dx < prefs.edgeDeadZone ||
            position.dx > size.width - prefs.edgeDeadZone)) {
      return;
    }
    final action = _chromeTarget
        ? ReaderTapAction.toggle
        : readerTapAction(position, size, prefs);
    switch (action) {
      case ReaderTapAction.toggle:
        _toggleChrome();
      case ReaderTapAction.previous:
        _pageBy(-1);
      case ReaderTapAction.next:
        _pageBy(1);
      case ReaderTapAction.previousChapter:
        _go(_chapter - 1);
      case ReaderTapAction.nextChapter:
        _go(_chapter + 1);
      case ReaderTapAction.toggleListening:
        if (_listening != null) unawaited(_listen());
      case ReaderTapAction.addBookmark:
        unawaited(_quickAddBookmark());
      case ReaderTapAction.none:
        break;
    }
  }

  void _pageBy(int direction) {
    _readingActivity.notifyInteraction();
    _selection.clear();
    if (_paginated) {
      if (_ready &&
          !_toolsOpen &&
          !_catalogueOpen &&
          !_listeningOpen &&
          !_findOpen) {
        _openedForBookmarkInspection = false;
        _suspendListeningFollow();
        _paged.pageBy(direction);
      }
      return;
    }
    if (!_ready ||
        !_scroll.hasClients ||
        _toolsOpen ||
        _catalogueOpen ||
        _listeningOpen ||
        _findOpen) {
      return;
    }
    _openedForBookmarkInspection = false;
    _suspendListeningFollow();
    final position = _scroll.position;
    final readableViewport =
        (position.viewportDimension -
                _readingInset -
                MediaQuery.paddingOf(context).bottom)
            .clamp(0.0, double.infinity);
    final distance = (readableViewport - 48).clamp(0.0, double.infinity);
    final target = (position.pixels + direction * distance).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: NovelMotion.contact,
        curve: NovelMotion.ease,
      );
    }
  }

  Future<String> _requestContent(int index, {bool refresh = false}) async {
    if (_novel.chapters.isEmpty) throw const FormatException('目录为空');
    if (offlineRepositoryForBook(widget.repository, _novel.id)
        case final offline?) {
      await offline.rememberDirectory(_novel);
      if (refresh) {
        return offline.refreshChapterContent(_novel.id, _novel.chapters[index]);
      }
    }
    return widget.repository.chapterContent(_novel.id, _novel.chapters[index]);
  }

  Future<void> _refreshIllustrations({bool automatic = false}) async {
    if (_illustrationsRefreshing) return;
    final chapter = _chapter;
    final generation = _contentGeneration;
    setState(() => _illustrationsRefreshing = true);
    try {
      final body = automatic
          ? await offlineRepositoryForBook(widget.repository, _novel.id)
                ?.repairChapterIllustrations(
                  _novel.id,
                  _novel.chapters[chapter],
                )
          : await _requestContent(chapter, refresh: true);
      if (body == null) return;
      final content = await ReaderContent.parse(body);
      if (!mounted || chapter != _chapter || generation != _contentGeneration) {
        return;
      }
      final position = _currentPosition();
      if (position != null) _prepareRestore(position);
      setState(() {
        _currentContent = content;
        _content = Future.value((content: content, error: null));
      });
    } catch (_) {
      if (!automatic && mounted && chapter == _chapter) {
        showNovelFeedback(context, '插图暂未更新成功，正文已保留，可稍后重试');
      }
    } finally {
      if (mounted && generation == _contentGeneration) {
        setState(() => _illustrationsRefreshing = false);
      }
    }
  }

  PurifiedParagraph _purifyParagraphAt(
    List<String> paragraphs,
    int chapterIndex,
    int paragraphIndex,
  ) {
    if (paragraphIndex < 0 || paragraphIndex >= paragraphs.length) {
      return const PurifiedParagraph('');
    }
    return ReaderPurificationStore.shared.purifyParagraphWithMap(
      paragraphs[paragraphIndex],
      bookId: _novel.id,
      bookTitle: _novel.title,
      chapterIndex: chapterIndex,
      paragraphIndex: paragraphIndex,
      chapterTitle: chapterIndex >= 0 && chapterIndex < _novel.chapters.length
          ? _novel.chapters[chapterIndex].title
          : null,
      isFirstParagraph: paragraphIndex == 0,
    );
  }

  ReaderRichParagraph _projectRichParagraph(
    ReaderRichParagraph format,
    PurifiedParagraph purified,
  ) {
    if (purified.isIdentity ||
        (format.emphasis.isEmpty &&
            format.ruby.isEmpty &&
            format.references.isEmpty)) {
      return format;
    }
    return ReaderRichParagraph(
      alignment: format.alignment,
      writing: format.writing,
      language: format.language,
      opacity: format.opacity,
      rule: format.rule,
      breakBefore: format.breakBefore,
      breakAfter: format.breakAfter,
      spacing: format.spacing,
      emphasis: [
        for (final r in format.emphasis)
          if (purified.purifiedRangeFor(r.start, r.end)
              case (final int s, final int e))
            ReaderEmphasis(s, e, r.mask),
      ],
      ruby: [
        for (final r in format.ruby)
          if (purified.purifiedRangeFor(r.start, r.end)
              case (final int s, final int e))
            ReaderRuby(s, e, r.text),
      ],
      references: [
        for (final r in format.references)
          if (purified.purifiedRangeFor(r.start, r.end)
              case (final int s, final int e))
            ReaderNoteReference(s, e, r.id),
      ],
    );
  }

  ReaderContent _purifyChapterContent(ReaderContent raw, int chapterIndex) {
    final store = ReaderPurificationStore.shared;
    if (!store.hasEnabledRules && !store.hasChapterEdits(_novel.id, chapterIndex)) {
      return raw;
    }
    var changed = false;
    final paragraphs = <String>[];
    final projectedFormats = <int, ReaderRichParagraph>{};
    for (var i = 0; i < raw.paragraphs.length; i++) {
      final p = _purifyParagraphAt(raw.paragraphs, chapterIndex, i);
      if (p.text != raw.paragraphs[i] || !p.isIdentity) {
        changed = true;
      }
      paragraphs.add(p.text);
      final rawFormat = raw.formats[i];
      if (rawFormat != null) {
        projectedFormats[i] = _projectRichParagraph(rawFormat, p);
      }
    }
    if (!changed) return raw;
    return ReaderContent(
      List.unmodifiable(paragraphs),
      readingOrder: raw.readingOrder,
      inlineOwners: raw.inlineOwners,
      placementIds: raw.placementIds,
      formats: projectedFormats,
      notes: raw.notes,
      revision: raw.revision,
      coordinateMap: raw.coordinateMap,
      languageFilter: raw.languageFilter,
    );
  }

  Widget _buildPagedIllustration(ReaderPageFragment fragment) {
    final url = readerIllustrationUrl(fragment.text);
    if (url != null) {
      final illustrations = _currentContent?.illustrations ?? [url];
      return ClipRRect(
        borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
        child: ReaderIllustration(
          url: url,
          fullScreen: true,
          onOpen: () => pushNovelPage<void>(
            context,
            ReaderIllustrationGallery(urls: illustrations, initialUrl: url),
            reduceMotion: widget.state.reduceMotion,
          ),
        ),
      );
    }
    if (fragment.text.trim() == '[插图]') {
      return _illustrationsRefreshing
          ? const LoadingSkeleton(
              layout: SkeletonLayout.cover,
              label: '正在补全插图',
            )
          : ContentPanel(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ArchiveIcon(CupertinoIcons.photo),
                    const SizedBox(height: 10),
                    const Text('暂未取得本章插图地址'),
                    GlassTextButton(
                      onPressed: _refreshIllustrations,
                      child: const Text('重试本章插图'),
                    ),
                  ],
                ),
              ),
            );
    }
    return const SizedBox.shrink();
  }

  Widget _paragraphContent(
    List<String> paragraphs,
    int index,
    TextStyle style,
  ) {
    final url = readerIllustrationUrl(paragraphs[index]);
    if (url != null) {
      final illustrations = _currentContent?.illustrations ?? [url];
      return ReaderIllustration(
        url: url,
        onOpen: () => pushNovelPage<void>(
          context,
          ReaderIllustrationGallery(urls: illustrations, initialUrl: url),
          reduceMotion: widget.state.reduceMotion,
        ),
      );
    }
    if (paragraphs[index].trim() == '[插图]') {
      // Match the loaded image's extent: replacing a URL-less slot must not
      // collapse/expand the article while the user keeps reading below it.
      return SizedBox(
        height: (MediaQuery.sizeOf(context).width - 52) * 4 / 3,
        child: _illustrationsRefreshing
            ? const LoadingSkeleton(
                layout: SkeletonLayout.cover,
                label: '正在补全插图',
              )
            : ContentPanel(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ArchiveIcon(CupertinoIcons.photo),
                      const SizedBox(height: 10),
                      const Text('暂未取得本章插图地址'),
                      GlassTextButton(
                        onPressed: _refreshIllustrations,
                        child: const Text('重试本章插图'),
                      ),
                    ],
                  ),
                ),
              ),
      );
    }
    final purified = _purifyParagraphAt(paragraphs, _chapter, index);
    final chapterId = _chapter >= 0 && _chapter < _novel.chapters.length
        ? _novel.chapters[_chapter].id
        : null;
    return ReaderSelectionFragment(
      paragraph: index,
      chapter: chapterId,
      text: purified.text,
      child: AnimatedBuilder(
        animation: widget.state.underlineChanges,
        builder: (context, _) {
          final rawAnnotations = chapterId == null
              ? const <ReaderAnnotationRange>[]
              : widget.state.annotationsFor(_novel.id, chapterId: chapterId);
          final annotations = rawAnnotations.isEmpty || purified.isIdentity
              ? rawAnnotations
              : ReaderPurificationStore.shared.mapAnnotationsToPurified(
                  rawAnnotations,
                  resolveParagraph: (pIdx) => pIdx == index
                      ? purified
                      : _purifyParagraphAt(paragraphs, _chapter, pIdx),
                );
          final marks = annotations.isEmpty
              ? const <ReaderTextMark>[]
              : clipReaderParagraphMarks(
                  annotations,
                  paragraph: index,
                  textLength: purified.text.length,
                );
          return ReaderHighlightText(
            text: purified.text,
            index: index,
            match: _findMatch,
            style: style,
            marks: marks,
          );
        },
      ),
    );
  }

  @override
  void didChangeMetrics() {
    if (!mounted || !_ready || _restoring) return;
    final view = View.of(context);
    final width = view.physicalSize.width / view.devicePixelRatio;
    if ((width - _layoutWidth).abs() < 1) return;
    final position = _currentPosition();
    if (position != null) _prepareRestore(position);
  }

  @override
  void didChangeTextScaleFactor() {
    if (!mounted) return;
    final position = _currentPosition();
    if (position != null) _prepareRestore(position);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _activityForeground = state == AppLifecycleState.resumed;
    _syncReadingActivity();
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _idleSave?.cancel();
      _savePosition(notify: false);
    }
    _followTicket++;
    _followScroll.cancel();
    _listeningTarget = null;
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _listeningChanged();
      });
    }
  }

  String? _activeBookmarkId;

  @override
  Widget build(BuildContext context) {
    final chapter = _novel.chapters.isEmpty
        ? const NovelChapter('目录为空', '')
        : _novel.chapters[_chapter];
    _layoutWidth = MediaQuery.sizeOf(context).width;
    _layoutFontId = widget.state.effectiveReaderFontId;
    // Keep this State subscribed to the app theme: a global typeface switch
    // must reach didChangeDependencies, which re-anchors and re-saves the
    // position with the new font (the scaffold reads Theme in a Builder).
    Theme.of(context);
    // Unified reader skeleton: paper theme, solid controls and warm light
    // apply below; sheets opened from this State keep the app theme.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _readingActivity.notifyInteraction(),
      child: ReaderPaperScope(
        state: widget.state,
        child: Builder(builder: (context) => _readerScaffold(context, chapter)),
      ),
    );
  }

  Widget _readerScaffold(BuildContext context, NovelChapter chapter) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ReaderScaffold(
      chrome: _chrome,
      novelId: _novel.id,
      title: _novel.title,
      bookmarkListenable: _bookmarkMerged,
      isBookmarked: () => _isCurrentPositionBookmarked,
      onAddBookmark: _quickAddBookmark,
      actions: _readerActions(),
      leadingStackChild: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReaderScreenBinding(state: widget.state),
          _ReaderRouteActivityBinding(onChanged: _updateRouteCurrent),
        ],
      ),
      body: NativeGlassGroup(
        enabled: false,
        inherit: false,
        child: RepaintBoundary(
          key: const ValueKey('reader-article-boundary'),
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.pageDown): () =>
                    _pageBy(1),
                const SingleActivator(LogicalKeyboardKey.space): () =>
                    _pageBy(1),
                const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                    _pageBy(-1),
                const SingleActivator(LogicalKeyboardKey.home): () =>
                    _seekProgress(0),
                const SingleActivator(LogicalKeyboardKey.end): () =>
                    _seekProgress(1),
                const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                    _findInChapter,
                const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                    _findInChapter,
              },
              child: Focus(
                autofocus: true,
                child: Semantics(
                  customSemanticsActions: {
                    const CustomSemanticsAction(label: '切换阅读控件'): _toggleChrome,
                  },
                  child: ReaderVolumePaging(
                    enabled: widget.state.readerPreferences.volumePaging,
                    onPage: _pageBy,
                    child: ReaderSelection(
                      controller: _selection,
                      onUnderline: _toggleSelectionUnderline,
                      isUnderlined: _isSelectionUnderlined,
                      onAnnotate: _annotateSelection,
                      onBookmark: _bookmarkSelection,
                      isBookmarked: _isSelectionBookmarked,
                      onPurify: _purifySelection,
                      child: GestureDetector(
                        key: const ValueKey('reader-content-tap'),
                        behavior: HitTestBehavior.translucent,
                        onTapUp: (details) => _tapAt(
                          details.localPosition,
                          context.size ?? MediaQuery.sizeOf(context),
                          globalPosition: details.globalPosition,
                        ),
                        child: _article(context, chapter, dark),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      navigation: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 阅读进度条：显示全书进度，可拖动跳转。
          ValueListenableBuilder<bool>(
            valueListenable: _progressBarVisible,
            builder: (context, showProgressBar, child) =>
                showProgressBar ? child! : const SizedBox.shrink(),
            child: Padding(
              padding: const EdgeInsets.only(left: 56, right: 56, bottom: 8),
              child: ValueListenableBuilder<double>(
                valueListenable: _progressValue,
                builder: (context, progress, _) => ReaderProgressBar(
                  value: _progressDragging ? _dragValue : progress,
                  dragging: _progressDragging,
                  previewText: _dragPreviewText(
                    _progressDragging ? _dragValue : progress,
                  ),
                  onDragStart: () => setState(() {
                    _progressDragging = true;
                    _progressPointerCancelled = false;
                    _dragValue = _progressValue.value;
                  }),
                  onDragUpdate: (v) => setState(() => _dragValue = v),
                  onDragEnd: () async {
                    // 底层指针取消可能绕开 onCancel 直接进 onEnd：
                    // 此时只重置状态，不跳转。
                    final cancelled = _progressPointerCancelled;
                    final target = _dragValue;
                    setState(() {
                      _progressDragging = false;
                      _progressPointerCancelled = false;
                    });
                    if (!cancelled) {
                      await _jumpToProgress(target);
                    }
                  },
                  onPointerCancel: () => _progressPointerCancelled = true,
                  // 取消只重置状态，不跳转。
                  onDragCancel: () => setState(() {
                    _progressDragging = false;
                    _progressPointerCancelled = false;
                  }),
                ),
              ),
            ),
          ),
          GlassDock(
            key: const ValueKey('reader-liquid-dock'),
            selectedIndex: 1,
            animateInactiveIcons: true,
            reduceMotion: widget.state.reduceMotion,
            items: [
              GlassDockItem(
                CupertinoIcons.arrow_left,
                '上一章',
                enabled: _chapter > 0,
              ),
              GlassDockItem(
                CupertinoIcons.book,
                '${_novel.chapters.isEmpty ? 0 : _chapter + 1} / ${_novel.chapters.length}',
                enabled: _novel.chapters.isNotEmpty,
                selectableOnDrag: false,
                semanticLabel:
                    '目录，当前第 ${_novel.chapters.isEmpty ? 0 : _chapter + 1} 章，共 ${_novel.chapters.length} 章',
              ),
              GlassDockItem(
                CupertinoIcons.arrow_right,
                '下一章',
                enabled: _chapter + 1 < _novel.chapters.length,
              ),
            ],
            onSelected: (index) {
              if (index == 1) {
                _catalogue();
              } else {
                _go(_chapter + (index == 0 ? -1 : 1));
              }
            },
          ),
        ],
      ),
      statusListenable: _progressValue,
      statusExtraListenable: _statusExtraMerged,
      maskTopSafeArea: () =>
          !_paginated && !widget.state.readerPreferences.hideSystemStatus,
      statusTextBuilder: (progress) {
        final pct = '${(progress * 100).round()}%';
        final displayTitle = ReaderPurificationStore.shared.purifyTitle(
          chapter.title,
          bookId: _novel.id,
          bookTitle: _novel.title,
        );
        if (_paginated && _paged.pageCount > 0) {
          final page = (_paged.page + 1).clamp(1, _paged.pageCount);
          return '$displayTitle · $page/${_paged.pageCount}页 · $pct';
        }
        return '$displayTitle · $pct';
      },
    );
  }

  /// 横排翻页 body (design decision 6). Uses the paged engine that
  /// shipped unused in v1.7.1; listening follow stays in 上下滚动.
  Widget _pagedArticle(
    BuildContext context,
    ReaderContent content,
    TextStyle style,
  ) {
    final rawPrefs = widget.state.readerPreferences;
    final prefs = rawPrefs.mode == ReaderMode.vertical
        ? rawPrefs.copyWith(mode: ReaderMode.paged)
        : rawPrefs;
    final media = MediaQuery.paddingOf(context);
    final pending = _restorePending;
    // Scroll mode stores textOffset chapter-wide; the paged engine reads it
    // as in-paragraph. Restore by paragraph index + fraction instead. Cached
    // by identity: the engine re-restores whenever `position` changes.
    if (!identical(pending, _pagedRestoreSource)) {
      _pagedRestoreSource = pending;
      _pagedRestore = pending == null
          ? null
          : ReadingPosition(
              chapter: pending.chapter,
              chapterId: pending.chapterId,
              offset: pending.offset,
              fraction: pending.fraction,
              fontSize: pending.fontSize,
              width: pending.width,
              updatedAt: pending.updatedAt,
              lineHeight: pending.lineHeight,
              paragraphIndex: pending.paragraphIndex,
              paragraphFraction: pending.paragraphFraction,
              textScale: pending.textScale,
              typeface: pending.typeface,
            );
    }
    final restore = _pagedRestore;
    final chapterIndex = _chapter;
    final chapterId = _novel.chapters[chapterIndex].id;
    final rawTitle = _novel.chapters[chapterIndex].title;
    final purifiedTitle = ReaderPurificationStore.shared.purifyTitle(
      rawTitle,
      bookId: _novel.id,
      bookTitle: _novel.title,
    );
    final purifiedContent = _purifyChapterContent(content, chapterIndex);
    final statusReserve = ReaderStatusLine.totalExtentFor(context) + 4;
    return AnimatedBuilder(
      animation: widget.state.underlineChanges,
      builder: (context, _) {
        final rawAnnotations = widget.state.annotationsFor(
          _novel.id,
          chapterId: chapterId,
        );
        final annotations =
            rawAnnotations.isEmpty || identical(purifiedContent, content)
            ? rawAnnotations
            : ReaderPurificationStore.shared.mapAnnotationsToPurified(
                rawAnnotations,
                resolveParagraph: (pIdx) =>
                    _purifyParagraphAt(content.paragraphs, chapterIndex, pIdx),
              );
        return ReaderPagedView(
          key: ValueKey(('reader-paged', prefs.mode, _novel.id)),
          content: purifiedContent,
          preferences: prefs,
          style: style,
          controller: _paged,
          title: purifiedTitle,
          bookTitle: _novel.title,
          chrome: _chrome,
          showBottomLocation: false,
          padding: EdgeInsets.fromLTRB(
            prefs.marginLeft ?? prefs.margin,
            media.top + FrostedHeader.toolbarHeight + 8,
            prefs.marginRight ?? prefs.margin,
            media.bottom + statusReserve,
          ),
          pageBuilder: (page) => readerPageBody(
            page,
            style,
            compressPunctuation: prefs.kinsokuCompression,
            justify: prefs.justify,
            formats: purifiedContent.formats,
            chapterId: chapterId,
            annotations: annotations,
            imageBuilder: _buildPagedIllustration,
          ),
          pageBuilderKey: (
            style,
            prefs.indent,
            prefs.justify,
            prefs.kinsokuCompression,
            purifiedContent.paragraphs,
            annotations,
          ),
          chapterKey: (_novel.id, chapterIndex),
          chapterTurnDirection: _pagedTurn,
          position: restore,
          reduceMotion:
              widget.state.reduceMotion ||
              MediaQuery.disableAnimationsOf(context),
          onReady: () {
            if (!mounted || chapterIndex != _chapter) return;
            _restorePending = null;
            _restoring = false;
            _notifyPagedStatus();
            _updateProgressFromScroll();
          },
          onChanged: () {
            if (!mounted || chapterIndex != _chapter) return;
            _selection.clear();
            _notifyPagedStatus();
            _updateProgressFromScroll();
            _idleSave?.cancel();
            _idleSave = Timer(const Duration(milliseconds: 160), () {
              _idleSave = null;
              if (mounted && chapterIndex == _chapter) {
                _savePosition(notify: false);
              }
            });
          },
          onUserScroll: () {
            _openedForBookmarkInspection = false;
            _selection.clear();
            _suspendListeningFollow(userDrag: true);
            _clearBookmarkLanding();
          },
          onBoundary: (direction) {
            final target = chapterIndex + direction.sign;
            if (target < 0 || target >= _novel.chapters.length) {
              showNovelFeedback(context, direction < 0 ? '已是第一章' : '已是最后一章');
              return;
            }
            _go(target);
            // _go resets the turn; a boundary turn keeps its direction so the
            // previous chapter opens on its last page.
            _pagedTurn = direction.sign;
          },
        );
      },
    );
  }

  Widget _article(
    BuildContext context,
    NovelChapter chapter,
    bool dark,
  ) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.state.readerSettingsChanges,
      ReaderPurificationStore.shared,
    ]),
    builder: (context, child) =>
        FutureBuilder<({ReaderContent? content, Object? error})>(
          future: _content,
          builder: (context, snapshot) {
            _layoutTextScale =
                MediaQuery.textScalerOf(context).scale(widget.state.fontSize) /
                widget.state.fontSize;
            _readingInset =
                MediaQuery.paddingOf(context).top +
                FrostedHeader.toolbarHeight +
                12;
            final done = snapshot.connectionState == ConnectionState.done;
            final instant = _instant;
            final useInstant =
                !done &&
                instant != null &&
                instant.generation == _contentGeneration;
            final content = useInstant
                ? instant.content
                : snapshot.data?.content;
            final ready = (done || useInstant) && content != null;
            final failed =
                snapshot.connectionState == ConnectionState.done &&
                (snapshot.hasError || snapshot.data?.error != null);
            _ready = ready;
            // Switching 阅读方式 keeps the reading line: the old view's
            // position seeds the new one (paragraph anchors, not pixels).
            // Must run before _restoreAfterLayout() below: clearing
            // _restoreQueued afterwards would skip the scroll restore in
            // this frame and leave the reader at the chapter start.
            final mode = widget.state.readerPreferences.mode;
            if (ready && _lastMode != null && _lastMode != mode) {
              final saved =
                  _settingsPosition ?? widget.state.positionFor(_novel.id);
              final sameChapterSaved =
                  saved != null &&
                      widget.state.chapterForPosition(_novel, saved) == _chapter
                  ? saved
                  : null;
              _restorePending ??= _lastMode!.paginated
                  ? (_pagedPosition() ?? sameChapterSaved)
                  : sameChapterSaved;
              _restoreQueued = false;
            }
            if (ready) _lastMode = mode;
            if (ready) {
              _restoreAfterLayout();
            } else {
              _syncReadingActivity();
            }
            final paragraphs = ready ? content.paragraphs : const <String>[];
            _paragraphCount = paragraphs.length;
            final paragraphStyle = TextStyle(
              fontSize: widget.state.fontSize,
              height: widget.state.lineHeight,
              letterSpacing: .1,
              // "跟随外观" keeps the v1.7.1 ink; other papers use their own.
              color: widget.state.readerPreferences.paper == ReaderPaper.system
                  ? (dark ? const Color(0xFFE8E8E8) : ink)
                  : Theme.of(context).colorScheme.onSurface,
            );
            if (ready && _paginated) {
              return _pagedArticle(context, content, paragraphStyle);
            }
            final displayChapterTitle = ReaderPurificationStore.shared
                .purifyTitle(
                  chapter.title,
                  bookId: _novel.id,
                  bookTitle: _novel.title,
                );
            return NotificationListener<ScrollMetricsNotification>(
              onNotification: (notification) {
                if (notification.depth == 0) {
                  _updateProgressFromScroll();
                }
                return false;
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0) {
                    if (notification is ScrollStartNotification) {
                      _idleSave?.cancel();
                      if (notification.dragDetails != null) {
                        _openedForBookmarkInspection = false;
                        _suspendListeningFollow(userDrag: true);
                        _clearBookmarkLanding();
                        _restoreTicket++;
                        _restorePending = null;
                        _restoring = false;
                        _revealChapter();
                      }
                    } else if (notification is ScrollEndNotification) {
                      // A new drag stops the old fling and emits scroll-end
                      // inside its input callback. Do no anchor/storage work in
                      // that callback; save only after genuine, stable idle.
                      _saveWhenIdle();
                    }
                  }
                  return false;
                },
                child: CustomScrollView(
                  key: const ValueKey('reader-scroll'),
                  controller: _scroll,
                  cacheExtent: (MediaQuery.sizeOf(context).height * .75).clamp(
                    250.0,
                    900.0,
                  ),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        26,
                        MediaQuery.paddingOf(context).top +
                            FrostedHeader.toolbarHeight +
                            24,
                        26,
                        28,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  isLocalNovelId(_novel.id)
                                      ? '目录项 ${_chapter + 1}'
                                      : '第 ${_chapter + 1} 章',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: ArchiveCode(
                                      'CH.${(_chapter + 1).toString().padLeft(3, '0')} / TEXT',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              displayChapterTitle,
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (failed)
                      SliverToBoxAdapter(
                        child: Column(
                          children: [
                            const Text('章节加载失败'),
                            GlassTextButton(
                              onPressed: () => setState(() {
                                _content = _loadContent();
                              }),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    else if (!ready)
                      const SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: 26),
                        sliver: SliverToBoxAdapter(child: ReaderSkeleton()),
                      )
                    else ...[
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 26),
                        sliver: SliverList.builder(
                          addAutomaticKeepAlives: false,
                          itemCount: paragraphs.length,
                          itemBuilder: (context, index) => ReaderParagraph(
                            key: ValueKey(
                              'paragraph-anchor-$_contentGeneration-$index',
                            ),
                            registry: _paragraphRegistry,
                            index: index,
                            child: LoadedContentItem(
                              key: ValueKey('reader-paragraph-reveal-$index'),
                              index: index - _chapterRevealFirst,
                              animation: _chapterReveal,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: ValueListenableBuilder<int?>(
                                  valueListenable: _bookmarkLanding,
                                  child: _listening == null
                                      ? _paragraphContent(
                                          paragraphs,
                                          index,
                                          paragraphStyle,
                                        )
                                      : ListeningParagraphHighlight(
                                          controller: _listening!,
                                          novelId: _novel.id,
                                          chapter: _chapter,
                                          paragraph: index,
                                          onDoubleTap: () =>
                                              _doubleTapListeningParagraph(
                                                index,
                                              ),
                                          interactive:
                                              readerIllustrationUrl(
                                                    paragraphs[index],
                                                  ) ==
                                                  null &&
                                              paragraphs[index].trim() !=
                                                  '[插图]' &&
                                              hasSpeechText(paragraphs[index]),
                                          child: _paragraphContent(
                                            paragraphs,
                                            index,
                                            paragraphStyle,
                                          ),
                                        ),
                                  builder: (context, selected, child) =>
                                      selected == index
                                      ? ReaderLandingHighlight(
                                          key: ValueKey(
                                            'bookmark-landing-$index',
                                          ),
                                          reduceMotion:
                                              widget.state.reduceMotion,
                                          child: child!,
                                        )
                                      : child!,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: EdgeInsets.only(
                          top: 48,
                          bottom: MediaQuery.paddingOf(context).bottom + 216,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            children: [
                              SizedBox(
                                width: 30,
                                child: Divider(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                '本章完',
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 12),
                              if (_chapter + 1 < _novel.chapters.length)
                                GlassTextButton(
                                  key: const ValueKey('reader-end-next'),
                                  onPressed: () => _go(_chapter + 1),
                                  child: const Text('继续下一章'),
                                )
                              else
                                Text(
                                  '已读至当前目录末章',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
  );

  Future<void> _settings({bool bookmarks = false}) async {
    if (_toolsOpen || _catalogueOpen || _findOpen || _listeningOpen) return;
    _toolsOpen = true;
    _followTicket++;
    _followScroll.cancel();
    final position = _currentPosition();
    _settingsPosition = position;
    final preview = ValueNotifier(false);
    try {
      final action = await showJellySheet<ReaderToolAction>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        previewing: preview,
        builder: (context) => ReaderTools(
          novel: _novel,
          state: widget.state,
          position: position,
          onAddBookmark: _addBookmark,
          onFontSize: (value) => _applyTypography(fontSize: value),
          onLineHeight: (value) => _applyTypography(lineHeight: value),
          onFontPreview: (value) =>
              _applyTypography(fontSize: value, persist: false),
          onLineHeightPreview: (value) =>
              _applyTypography(lineHeight: value, persist: false),
          onPreviewChanged: (value) {
            _typographyPreviewing = value;
            preview.value = value;
          },
          onReset: () => _applyTypography(fontSize: 19, lineHeight: 1.72),
          initialBookmarks: bookmarks,
        ),
      );
      if (!mounted) return;
      switch (action) {
        case ReaderEnterFocus():
          _showChrome(false);
        case ReaderSeekProgress(:final fraction):
          await _seekProgress(fraction);
        case ReaderOpenBookmark(:final bookmark):
          final chapter = widget.state.chapterForPosition(
            _novel,
            bookmark.position,
          );
          if (chapter != null) {
            _go(chapter, position: bookmark.position, highlightBookmark: true);
            _activeBookmarkId = bookmark.id;
          }
        case ReaderOpenFind():
          // The settings surface has fully collapsed before opening the next.
          _toolsOpen = false;
          await _findInChapter();
        case ReaderOpenPurification():
          _toolsOpen = false;
          await _openPurificationInChapter(position);
        case null:
          break;
      }
    } finally {
      _settingsPosition = null;
      _toolsOpen = false;
      _typographyPreviewing = false;
      preview.dispose();
      _savePosition(notify: false);
    }
  }

  Future<void> _openPurificationInChapter([
    ReadingPosition? position,
    String? initialPattern,
  ]) async {
    final content = _currentContent;
    final paragraphIndex =
        (position?.paragraphIndex ?? _currentPosition()?.paragraphIndex ?? 0)
            .clamp(0, (content?.paragraphs.length ?? 1) - 1);
    final chapterTitle = _chapter >= 0 && _chapter < _novel.chapters.length
        ? _novel.chapters[_chapter].title
        : null;
    await showReaderPurificationSheet(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      bookId: _novel.id,
      bookTitle: _novel.title,
      chapterIndex: _chapter,
      chapterTitle: chapterTitle,
      chapterParagraphs: content?.paragraphs,
      initialParagraphIndex: paragraphIndex,
      initialPattern: initialPattern,
    );
  }

  List<ReaderAction> _readerActions() => [
    ReaderAction(
      key: const ValueKey('reader-catalogue-entry'),
      icon: CupertinoIcons.list_bullet,
      caption: '目录',
      label: '目录',
      onPressed: _novel.chapters.isEmpty ? null : _catalogue,
      unavailable: _novel.chapters.isEmpty ? '本书没有目录' : null,
    ),
    ReaderAction(
      icon: CupertinoIcons.textformat_size,
      caption: '设置',
      label: '阅读设置',
      onPressed: _settings,
    ),
    ReaderAction(
      key: const ValueKey('reader-appearance-entry'),
      icon: CupertinoIcons.sun_max,
      caption: '亮度',
      label: '亮度与纸色',
      onPressed: () => showReaderAppearanceSheet(context, state: widget.state),
    ),
    ReaderAction(
      key: const ValueKey('reader-listening-entry'),
      icon: CupertinoIcons.headphones,
      caption: '听书',
      label: '听书',
      onPressed: _listening == null ? null : _listen,
      unavailable: _listening == null ? '当前设备不支持听书' : null,
    ),
  ];

  Future<void> _findInChapter() async {
    final content = _currentContent;
    if (!_ready ||
        content == null ||
        _findOpen ||
        _toolsOpen ||
        _listeningOpen ||
        _catalogueOpen) {
      return;
    }
    _clearBookmarkLanding();
    _suspendListeningFollow();
    _findOpen = true;
    final generation = _contentGeneration;
    final purifiedContent = _purifyChapterContent(content, _chapter);
    try {
      final match = await showJellySheet<ReaderMatch>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        builder: (_) => ReaderFindPanel(content: purifiedContent),
      );
      if (!mounted || match == null || generation != _contentGeneration) return;
      _highlightTimer?.cancel();
      _findMatch.value = match;
      // A manual drag can interrupt lazy positioning before it completes.
      // Expiration belongs to selection, not to successful restoration.
      _highlightTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) _findMatch.value = null;
      });
      if (_paginated) {
        _paged.reveal(ReaderTextAnchor(match.paragraph, match.start));
        _savePosition(notify: false);
        _showChrome(true);
        return;
      }
      final ticket = ++_restoreTicket;
      _restoring = true;
      try {
        for (var step = 0; step < 20; step++) {
          if (!mounted ||
              generation != _contentGeneration ||
              ticket != _restoreTicket ||
              !_scroll.hasClients) {
            return;
          }
          final precise = _paragraphRegistry.matchOffset(
            match.paragraph,
            match.start,
            match.end,
            _readingInset + 8,
          );
          final estimate = _paragraphRegistry.target((
            index: match.paragraph,
            fraction: 0,
          ), _readingInset + 8);
          final target = precise ?? estimate?.offset;
          if (target == null) break;
          _scroll.jumpTo(target.clamp(0.0, double.infinity));
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted ||
              generation != _contentGeneration ||
              ticket != _restoreTicket ||
              !_scroll.hasClients) {
            return;
          }
          final refined = _paragraphRegistry.matchOffset(
            match.paragraph,
            match.start,
            match.end,
            _readingInset + 8,
          );
          if (refined != null &&
              (_scroll.offset -
                          refined.clamp(0.0, _scroll.position.maxScrollExtent))
                      .abs() <
                  1) {
            break;
          }
        }
        if (!mounted ||
            generation != _contentGeneration ||
            ticket != _restoreTicket) {
          return;
        }
        _restoring = false;
        _savePosition(notify: false);
        _showChrome(true);
      } finally {
        if (ticket == _restoreTicket) _restoring = false;
      }
    } finally {
      _findOpen = false;
    }
  }
}

class _ReaderRouteActivityBinding extends StatefulWidget {
  const _ReaderRouteActivityBinding({required this.onChanged});
  final ValueChanged<bool> onChanged;

  @override
  State<_ReaderRouteActivityBinding> createState() =>
      _ReaderRouteActivityBindingState();
}

class _ReaderRouteActivityBindingState
    extends State<_ReaderRouteActivityBinding> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onChanged(ModalRoute.isCurrentOf(context) ?? true);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
