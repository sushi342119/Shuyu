import 'dart:async';
import 'ui_preferences.dart' show readerFontSizeMin, readerFontSizeMax;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'glass_dock.dart';
import 'library_state.dart';
import 'local_epub.dart';
import 'reader_purification.dart';
import 'reading_activity.dart';
import 'local_library.dart';
import 'reader_annotation_editor.dart';
import 'reader_catalogue.dart';
import 'reader_chrome.dart';
import 'reader_selection.dart';
import 'reader_skeleton.dart';
import 'reader_tools.dart';
import 'reader_underline.dart';

class LocalEpubReaderPage extends StatefulWidget {
  const LocalEpubReaderPage({
    super.key,
    required this.novel,
    required this.state,
    required this.local,
    required this.initialChapter,
  });

  final Novel novel;
  final LibraryState state;
  final LocalLibraryStore local;
  final int initialChapter;

  @override
  State<LocalEpubReaderPage> createState() => _LocalEpubReaderPageState();
}

class _LocalEpubReaderPageState extends State<LocalEpubReaderPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late Novel _novel;
  late final AnimationController _chrome;
  late ReadingActivitySession _readingActivity;
  bool _activityAttached = false;
  bool _activityForeground = true;
  bool _chapterReady = false;
  late int _chapter;
  int _chapterVisit = 0;
  bool _chromeTarget = true;
  bool _sheetOpen = false;
  bool _addingBookmark = false;
  Future<({List<EpubBlock> blocks, Map<String, Uint8List> images})>? _future;
  int? _futureChapter;

  void _syncReadingActivity() {
    final active =
        _activityAttached &&
        _activityForeground &&
        _chapterReady &&
        !_sheetOpen &&
        _total > 0;
    _readingActivity.setActive(active);
  }

  // keepScrollOffset: false —— 每章换新 ListView，不能让 PageStorage 把上一章偏移带过来。
  final ScrollController _scroll = ScrollController(keepScrollOffset: false);
  final ReaderSelectionController _selection = ReaderSelectionController();
  final ValueNotifier<double> _progressValue = ValueNotifier(0);
  bool _progressDragging = false;
  bool _progressPointerCancelled = false;
  double _dragValue = 0;
  bool _singleScrollable = false;
  // 恢复旧章内位置完成前不保存滚动，避免 offset 0 覆盖旧位置。
  bool _tracking = false;
  int _jumpTicket = 0;
  Timer? _idleSave;
  double _width = 0;
  double _lastOffset = 0;
  double _lastMax = 0;

  int get _total => _novel.chapters.length;

  bool get _hasLayout =>
      _scroll.positions.length == 1 && _scroll.position.hasContentDimensions;

  /// 章内滚动比例（0~1），不可滚动时为 0。
  double get _chapterRatio {
    if (!_hasLayout) return 0;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return 0;
    return (_scroll.offset / max).clamp(0.0, 1.0);
  }

  /// 当前章节进度（0~1）。
  double _bookProgress() {
    if (_total <= 0) return 0;
    return _chapterRatio.clamp(0.0, 1.0);
  }

  double _chapterStart(int chapter) => 0.0;

  /// 把当前章进度换算为当前章节和章内比例。
  ({int chapter, double ratio}) _progressToTarget(double progress) {
    if (_total <= 0) return (chapter: 0, ratio: 0);
    return (chapter: _chapter, ratio: progress.clamp(0.0, 1.0));
  }

  /// 进度条是否显示：多章，或单章可滚动时显示。
  bool get _showProgressBar => _total > 1 || (_total == 1 && _singleScrollable);

  String _dragPreviewText(double progress) =>
      '第 ${_chapter + 1} 章 · ${(progress.clamp(0.0, 1.0) * 100).round()}%';

  void _updateProgress() {
    if (_progressDragging || !mounted) return;
    final v = _bookProgress();
    if ((v - _progressValue.value).abs() > 0.0005) _progressValue.value = v;
  }

  void _onScroll() {
    if (_hasLayout) {
      _lastOffset = _scroll.offset;
      _lastMax = _scroll.position.maxScrollExtent;
    }
    _updateProgress();
    if (!_tracking) return;
    _idleSave?.cancel();
    _idleSave = Timer(const Duration(milliseconds: 600), () {
      if (mounted) unawaited(_savePosition());
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(ReaderPurificationStore.shared.ensureLoaded());
    final book = widget.local.bookFor(widget.novel.id);
    _novel = book == null
        ? widget.novel
        : widget.novel.withChapters([
            for (var index = 0; index < book.chapters.length; index++)
              NovelChapter(
                book.chapters[index].title,
                '',
                id: index,
                revision: book.revision,
                volume: book.chapters[index].volume,
              ),
          ]);
    _readingActivity = ReadingActivitySession(
      store: widget.state.readingActivity,
      bookId: _novel.id,
    );
    _activityAttached = true;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _activityForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _chrome = AnimationController(
      vsync: this,
      duration: NovelMotion.chromeShow,
      reverseDuration: NovelMotion.chromeHide,
      value: 1,
    );
    if (_total <= 0) {
      _chapter = 0;
    } else if (widget.initialChapter >= 0 && widget.initialChapter < _total) {
      _chapter = widget.initialChapter;
    } else {
      _chapter = widget.state.chapterForNovel(_novel).clamp(0, _total - 1);
    }
    _scroll.addListener(_onScroll);
    _progressValue.value = _total == 0 ? 0 : _chapterStart(_chapter);
    // 先读旧的章内位置；必须在恢复滚动之后才开始保存，否则旧位置被 0 覆盖。
    double? restoreRatio;
    final saved = widget.state.positionFor(_novel.id);
    if (_total > 0 &&
        saved != null &&
        widget.state.chapterForPosition(_novel, saved) == _chapter &&
        saved.fraction > 0) {
      restoreRatio = saved.fraction.clamp(0.0, 1.0);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _total <= 0) return;
      if (restoreRatio != null) {
        unawaited(_restore(restoreRatio));
      } else {
        _tracking = true;
        unawaited(_saveChapter(_chapter));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _width = MediaQuery.sizeOf(context).width;
  }

  /// 等当前章（[chapter]）加载并布局完成；postFrame 回调链 + 2 秒 watchdog，
  /// 超时、卸载或被新跳转取代时也结束等待。返回 false 表示已被取代/卸载。
  Future<bool> _waitForChapterLayout(int ticket, int chapter) async {
    try {
      await _load();
    } catch (_) {
      return mounted && ticket == _jumpTicket && chapter == _chapter;
    }
    bool stale() => !mounted || ticket != _jumpTicket || chapter != _chapter;
    if (stale()) return false;
    final done = Completer<void>();
    final stopwatch = Stopwatch()..start();
    final watchdog = Timer(const Duration(seconds: 2), () {
      if (!done.isCompleted) done.complete();
    });
    void waitForLayout() {
      if (done.isCompleted) return;
      if (stale() ||
          stopwatch.elapsed >= const Duration(seconds: 2) ||
          _hasLayout) {
        done.complete();
        return;
      }
      SchedulerBinding.instance.scheduleFrame();
      WidgetsBinding.instance.addPostFrameCallback((_) => waitForLayout());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => waitForLayout());
    SchedulerBinding.instance.scheduleFrame();
    try {
      await done.future;
    } finally {
      watchdog.cancel();
      stopwatch.stop();
    }
    return !stale();
  }

  /// 按比例滚动；懒加载列表的 maxScrollExtent 是估算值，跳转后再校正几帧。
  Future<void> _scrollToRatio(int ticket, double ratio) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!mounted || ticket != _jumpTicket || !_hasLayout) return;
      final max = _scroll.position.maxScrollExtent;
      if (max <= 0) return;
      final target = (ratio * max).clamp(0.0, max);
      if ((_scroll.offset - target).abs() < 1) return;
      _scroll.jumpTo(target);
      final frame = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) => frame.complete());
      SchedulerBinding.instance.scheduleFrame();
      await frame.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    }
  }

  Future<void> _restore(double ratio) async {
    final ticket = ++_jumpTicket;
    final chapter = _chapter;
    var current = false;
    try {
      current = await _waitForChapterLayout(ticket, chapter);
      if (current) await _scrollToRatio(ticket, ratio);
    } finally {
      // 被跳章取代时由 _goTo 或 _jumpToProgress 负责保存；否则恢复结束（含超时）后开始跟踪并保存真实位置。
      if (mounted && ticket == _jumpTicket) {
        _tracking = true;
        _updateProgress();
        if (_hasLayout && _scroll.offset > 0) {
          unawaited(_savePosition());
        }
      }
    }
  }

  void _syncNovelFromStore() {
    final book = widget.local.bookFor(widget.novel.id);
    if (book == null || book.chapters.length == _novel.chapters.length) return;
    final nextNovel = widget.novel.withChapters([
      for (var index = 0; index < book.chapters.length; index++)
        NovelChapter(
          book.chapters[index].title,
          '',
          id: index,
          revision: book.revision,
          volume: book.chapters[index].volume,
        ),
    ]);
    if (mounted) {
      setState(() {
        _novel = nextNovel;
        if (_total > 0 && _chapter >= _total) {
          _chapter = _total - 1;
        }
      });
    } else {
      _novel = nextNovel;
    }
  }

  Future<({List<EpubBlock> blocks, Map<String, Uint8List> images})> _load() {
    if (_future == null || _futureChapter != _chapter) {
      _futureChapter = _chapter;
      _future = widget.local
          .epubChapter(widget.novel.id, _chapter)
          .then((result) {
            _syncNovelFromStore();
            return result;
          });
    }
    return _future!;
  }

  /// 切章时保存：章序号 + 章首位置（新章从头开始）。
  Future<void> _saveChapter(int chapter) async {
    final width = _width;
    try {
      await widget.state.setChapter(_novel.id, chapter);
    } catch (_) {
      if (mounted) showNovelFeedback(context, '阅读进度保存失败，请重试');
      return;
    }
    try {
      await widget.state.savePosition(
        novel: _novel,
        chapter: chapter,
        offset: 0,
        maximum: 0,
        width: width,
      );
    } catch (_) {}
  }

  /// 保存当前章真实的滚动 offset/maximum（章内进度）。
  Future<void> _savePosition({bool notify = true}) async {
    _idleSave?.cancel();
    _idleSave = null;
    if (!_tracking || _total <= 0 || !_hasLayout) return;
    try {
      await widget.state.savePosition(
        novel: _novel,
        chapter: _chapter,
        offset: _scroll.offset,
        maximum: _scroll.position.maxScrollExtent,
        width: _width,
        notify: notify,
      );
    } catch (_) {}
  }

  void _goTo(int chapter, {bool restart = false}) {
    if (chapter < 0 || chapter >= _total) return;
    if (chapter == _chapter && !restart) return;
    _selection.clear();
    _jumpTicket++;
    _idleSave?.cancel();
    _idleSave = null;
    _tracking = true;
    unawaited(_saveChapter(chapter));
    setState(() {
      if (_chapter != chapter) {
        _future = null;
        _futureChapter = null;
      }
      _chapter = chapter;
      _chapterVisit++;
    });
    if (!_progressDragging) _progressValue.value = _chapterStart(_chapter);
    _showChrome(true);
  }

  /// 拖动结束：在当前章节内按比例滚动跳转。
  Future<void> _jumpToProgress(double progress) async {
    final target = _progressToTarget(progress);
    final ticket = ++_jumpTicket;
    // 恢复进行中被进度条打断时，恢复的 finally 不会再设 tracking；
    // 此次跳转接管保存，否则之后滚动将一直不保存。
    _tracking = true;
    final chapter = _chapter;
    if (!await _waitForChapterLayout(ticket, chapter)) return;
    await _scrollToRatio(ticket, target.ratio);
    _updateProgress();
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

  void _toggleChrome() {
    if (_selection.value) {
      _selection.clear();
      return;
    }
    if (_total > 0 && !_sheetOpen) _showChrome(!_chromeTarget);
  }

  void _tapContent(TapUpDetails details) {
    if (_selection.value) {
      _selection.clear();
      return;
    }
    final hit = _selection.hitOffsetAt(details.globalPosition);
    if (hit != null && _total > 0) {
      final targetChapterId = hit.chapter ?? _novel.chapters[_chapter].id;
      for (final mark in widget.state.bookmarksFor(_novel.id)) {
        if (!mark.isUnderline) continue;
        for (final range in mark.underlineRanges) {
          if (range.chapterId != targetChapterId) continue;
          if (hit.paragraph < range.startParagraph ||
              hit.paragraph > range.endParagraph) {
            continue;
          }
          if (hit.paragraph == range.startParagraph &&
              hit.offset < range.startOffset) {
            continue;
          }
          if (hit.paragraph == range.endParagraph &&
              hit.offset >= range.endOffset) {
            continue;
          }
          unawaited(_editMark(mark));
          return;
        }
      }
    }
    _toggleChrome();
  }

  ReadingPosition _positionForBlock(int paragraphIndex) {
    final chapter = _novel.chapters[_chapter];
    return ReadingPosition(
      chapter: _chapter,
      chapterId: chapter.id,
      revision: chapter.revision,
      offset: _hasLayout ? _scroll.offset : 0,
      fraction: _chapterRatio,
      fontSize: widget.state.fontSize,
      lineHeight: widget.state.lineHeight,
      width: MediaQuery.sizeOf(context).width,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      paragraphIndex: paragraphIndex,
    );
  }

  List<ReaderUnderlineRange> _selectionToUnderlineRanges(
    ReaderQuoteSelection selection,
  ) {
    if (_total == 0) return const [];
    final chapterId = _novel.chapters[_chapter].id;
    final ranges = List.of(selection.ranges)
      ..sort((a, b) => a.paragraph != b.paragraph
          ? a.paragraph.compareTo(b.paragraph)
          : a.start.compareTo(b.start));
    if (ranges.isEmpty) return const [];
    final first = ranges.first;
    final last = ranges.last;
    final candidate = ReaderUnderlineRange(
      chapterId: chapterId,
      startParagraph: first.paragraph,
      startOffset: first.start,
      endParagraph: last.paragraph,
      endOffset: last.end,
    );
    return candidate.isValid
        ? canonicalReaderUnderlineRanges([candidate])
        : const [];
  }

  Future<void> _toggleSelectionUnderline(ReaderQuoteSelection selection) async {
    final ranges = _selectionToUnderlineRanges(selection);
    if (ranges.isEmpty) return;
    try {
      final added = await widget.state.toggleUnderline(
        novel: _novel,
        position: _positionForBlock(selection.ranges.first.paragraph),
        ranges: ranges,
        quote: selection.quote,
      );
      if (mounted) {
        showNovelFeedback(context, added ? '已添加划线' : '已取消划线');
      }
    } catch (_) {
      if (mounted) showNovelFeedback(context, '划线未保存，请重试');
    }
  }

  Future<void> _annotateSelection(ReaderQuoteSelection selection) async {
    final ranges = _selectionToUnderlineRanges(selection);
    if (ranges.isEmpty) return;
    final mark = await showReaderAnnotationEditor(
      context,
      state: widget.state,
      novelId: _novel.id,
      novel: _novel,
      position: _positionForBlock(selection.ranges.first.paragraph),
      ranges: ranges,
      quote: selection.quote,
      initialStyle: ReaderMarkStyle.underline,
    );
    if (mounted && mark != null) {
      showNovelFeedback(context, '已保存标记与批注');
    }
  }

  bool _isSelectionUnderlined(ReaderQuoteSelection selection) {
    final ranges = _selectionToUnderlineRanges(selection);
    if (ranges.isEmpty) return false;
    return widget.state.bookmarksFor(_novel.id).any(
      (mark) =>
          mark.isUnderline &&
          readerUnderlineRangesOverlap(mark.underlineRanges, ranges),
    );
  }

  ReaderBookmark? _selectionBookmarkMatch(ReaderQuoteSelection selection) {
    final first = selection.ranges.firstOrNull;
    if (first == null) return null;
    final excerpt = selection.quote.trim();
    for (final mark in widget.state.bookmarksFor(_novel.id)) {
      if (mark.isUnderline ||
          widget.state.chapterForPosition(_novel, mark.position) != _chapter) {
        continue;
      }
      if (excerpt.isNotEmpty && mark.quote == excerpt) {
        return mark;
      }
      if (mark.position.paragraphIndex == first.paragraph &&
          (mark.quote.isEmpty || mark.quote == excerpt)) {
        return mark;
      }
    }
    return null;
  }

  bool _isSelectionBookmarked(ReaderQuoteSelection selection) =>
      _selectionBookmarkMatch(selection) != null;

  Future<void> _bookmarkSelection(ReaderQuoteSelection selection) async {
    final existing = _selectionBookmarkMatch(selection);
    if (existing != null) {
      try {
        await widget.state.removeBookmark(_novel.id, existing.id);
        if (mounted) showNovelFeedback(context, '已取消书签');
      } catch (_) {
        if (mounted) showNovelFeedback(context, '书签删除失败，请重试');
      }
      return;
    }
    try {
      final mark = await widget.state.addBookmark(
        novel: _novel,
        position: _positionForBlock(selection.ranges.first.paragraph),
        quote: selection.quote,
      );
      if (mounted && mark != null) {
        showNovelFeedback(context, '已添加摘录书签');
      }
    } catch (_) {
      if (mounted) showNovelFeedback(context, '书签保存失败，请重试');
    }
  }

  Future<void> _editMark(
    ReaderBookmark mark, {
    BuildContext? sheetContext,
  }) async {
    final hostContext =
        sheetContext != null && sheetContext.mounted ? sheetContext : context;
    final updated = await showReaderAnnotationEditor(
      hostContext,
      state: widget.state,
      novelId: _novel.id,
      novel: _novel,
      bookmark: mark,
    );
    if (mounted && updated != null) {
      showNovelFeedback(context, '已更新标记与批注');
    }
  }

  Future<void> _catalogue() async {
    if (_sheetOpen || _total == 0) return;
    _selection.clear();
    _sheetOpen = true;
    _syncReadingActivity();
    try {
      final picked = await showJellySheet<Object>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        builder: (sheetContext) => ReaderMarksSheet(
          state: widget.state,
          novel: _novel,
          currentChapter: _chapter,
          cache: null,
          onEditMark: (mark) => _editMark(mark, sheetContext: sheetContext),
        ),
      );
      if (!mounted) return;
      if (picked is ReaderBookmark) {
        final chapter = widget.state.chapterForPosition(_novel, picked.position);
        if (chapter != null) _goTo(chapter, restart: true);
      } else if (picked is int) {
        _goTo(picked, restart: true);
      }
    } finally {
      _sheetOpen = false;
      _syncReadingActivity();
    }
  }

  Future<ReaderBookmark?> _addBookmark() async {
    if (_total == 0) return null;
    final chapter = _novel.chapters[_chapter];
    return widget.state.addBookmark(
      novel: _novel,
      position: ReadingPosition(
        chapter: _chapter,
        chapterId: chapter.id,
        revision: chapter.revision,
        offset: 0,
        fraction: 0,
        fontSize: widget.state.fontSize,
        lineHeight: widget.state.lineHeight,
        width: MediaQuery.sizeOf(context).width,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  List<ReaderBookmark> _chapterBookmarks() {
    if (_total == 0) return const [];
    return [
      for (final mark in widget.state.bookmarksFor(_novel.id))
        if (!mark.isUnderline &&
            mark.quote.isEmpty &&
            widget.state.chapterForPosition(_novel, mark.position) == _chapter)
          mark,
    ];
  }

  Future<void> _quickAddBookmark() async {
    if (_addingBookmark || _total == 0) return;
    _addingBookmark = true;
    final matched = _chapterBookmarks();
    if (matched.isNotEmpty) {
      try {
        for (final mark in matched) {
          await widget.state.removeBookmark(_novel.id, mark.id);
        }
        if (mounted) showNovelFeedback(context, '已取消书签');
      } catch (_) {
        if (mounted) showNovelFeedback(context, '书签删除失败，请重试');
      } finally {
        _addingBookmark = false;
      }
      return;
    }
    try {
      final mark = await _addBookmark();
      if (!mounted) return;
      if (mark == null) {
        showNovelFeedback(context, '书签保存失败，请重试');
      } else {
        showNovelFeedback(context, '已添加书签（目前仅支持跳转到章首）');
      }
    } catch (_) {
      if (mounted) showNovelFeedback(context, '书签保存失败，请重试');
    } finally {
      _addingBookmark = false;
    }
  }

  Future<void> _settings({bool bookmarks = false}) async {
    if (_sheetOpen || _total == 0) return;
    _selection.clear();
    _sheetOpen = true;
    _syncReadingActivity();
    try {
      final action = await showJellySheet<ReaderToolAction>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        builder: (context) => LocalEpubReaderTools(
          novel: _novel,
          state: widget.state,
          chapter: _chapter,
          chapterProgress: _chapterRatio,
          onAddBookmark: _addBookmark,
          initialBookmarks: bookmarks,
        ),
      );
      if (!mounted) return;
      if (action is ReaderEnterFocus) {
        _showChrome(false);
      } else if (action is ReaderOpenBookmark) {
        final chapter = widget.state.chapterForPosition(
          _novel,
          action.bookmark.position,
        );
        if (chapter != null) _goTo(chapter, restart: true);
      }
    } finally {
      _sheetOpen = false;
      _syncReadingActivity();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _activityForeground = state == AppLifecycleState.resumed;
    _syncReadingActivity();
  }

  @override
  void deactivate() {
    _readingActivity.setActive(false);
    _activityAttached = false;
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
    WidgetsBinding.instance.removeObserver(this);
    _readingActivity.dispose();
    // 页面不持有 EpubPackage；epubChapter() 完成时会在 finally 中关闭包。
    // 清引用不会取消尚未完成的加载；ImageCache 可能继续持有图片字节，
    // 因此 dispose 不保证立即释放全部图片内存。
    _future = null;
    _futureChapter = null;
    _jumpTicket++;
    // 有未落盘的滚动时补存一次（与 TXT 退出时 finalSave 一致，不通知监听者）。
    // dispose 时列表可能已先卸载，用滚动监听里缓存的 offset/maximum。
    if (_idleSave != null && _tracking && _total > 0 && _lastMax > 0) {
      unawaited(
        widget.state
            .savePosition(
              novel: _novel,
              chapter: _chapter,
              offset: _lastOffset,
              maximum: _lastMax,
              width: _width,
              notify: false,
            )
            .catchError((_) {}),
      );
    }
    _idleSave?.cancel();
    _selection.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _progressValue.dispose();
    _chrome.dispose();
    super.dispose();
  }

  void _retry() {
    _tracking = true;
    setState(() {
      _future = null;
      _futureChapter = null;
    });
  }

  String _chapterTitle() => _total == 0 ? '' : _novel.chapters[_chapter].title;

  @override
  Widget build(BuildContext context) => ReaderPaperScope(
    state: widget.state,
    child: Builder(builder: _readerScaffold),
  );

  List<ReaderAction> _readerActions() => [
    ReaderAction(
      key: const ValueKey('reader-catalogue-entry'),
      icon: CupertinoIcons.list_bullet,
      caption: '目录',
      label: '目录',
      onPressed: _total == 0 ? null : _catalogue,
      unavailable: _total == 0 ? '本书没有目录' : null,
    ),
    // Zero chapters: truly disabled (onPressed null), as in v1.7.1.
    ReaderAction(
      icon: CupertinoIcons.textformat_size,
      caption: '设置',
      label: '阅读设置',
      onPressed: _total == 0 ? null : _settings,
    ),
    ReaderAction(
      key: const ValueKey('reader-appearance-entry'),
      icon: CupertinoIcons.sun_max,
      caption: '亮度',
      label: '亮度与纸色',
      onPressed: () =>
          showReaderAppearanceSheet(context, state: widget.state),
    ),
    // No 听书 entry: EPUB listening is not wired, so it is not offered.
  ];

  Widget _readerScaffold(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Atmosphere(
        shareGlass: true,
        archiveBackdrop: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: ReaderSelection(
                controller: _selection,
                onUnderline: _toggleSelectionUnderline,
                isUnderlined: _isSelectionUnderlined,
                onAnnotate: _annotateSelection,
                onBookmark: _bookmarkSelection,
                isBookmarked: _isSelectionBookmarked,
                child: GestureDetector(
                  key: const ValueKey('reader-content-tap'),
                  behavior: HitTestBehavior.translucent,
                  onTapUp: _tapContent,
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surface,
                    child: _total == 0
                        ? _message('暂无章节')
                        : AnimatedBuilder(
                            animation: Listenable.merge([
                              widget.state.readerSettingsChanges,
                              ReaderPurificationStore.shared,
                            ]),
                            builder: (context, _) => _content(context),
                          ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: ReaderEdgeBlur(animation: _chrome),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ReaderTopBar(
                chrome: _chrome,
                novelId: _novel.id,
                title: _novel.title,
                bookmarkListenable: widget.state.bookmarkChanges,
                isBookmarked: () => _chapterBookmarks().isNotEmpty,
                onAddBookmark: _total == 0 ? null : _quickAddBookmark,
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  22 + MediaQuery.paddingOf(context).left,
                  0,
                  22 + MediaQuery.paddingOf(context).right,
                  MediaQuery.paddingOf(context).bottom + 12,
                ),
                child: ReaderChromeLayer(
                  key: const ValueKey('reader-chrome-dock'),
                  animation: _chrome,
                  slide: const Offset(0, 8),
                  fadeOffset: const Offset(0, 12),
                  child: ReaderBottomPanel(
                    actions: _readerActions(),
                    navigation: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 全书进度条：与 Dock 一起随控件显隐，可拖动跳转。
                      if (_showProgressBar)
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 56,
                            right: 56,
                            bottom: 8,
                          ),
                          child: ValueListenableBuilder<double>(
                            valueListenable: _progressValue,
                            builder: (context, progress, _) => ReaderProgressBar(
                              key: const ValueKey('epub-book-progress'),
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
                              onDragUpdate: (v) =>
                                  setState(() => _dragValue = v),
                              onDragEnd: () async {
                                // 底层指针取消可能绕开 onCancel 直接进 onEnd：
                                // 此时只重置状态，不跳转。
                                final cancelled = _progressPointerCancelled;
                                final target = _dragValue;
                                setState(() {
                                  _progressDragging = false;
                                  _progressPointerCancelled = false;
                                });
                                if (!cancelled) await _jumpToProgress(target);
                              },
                              onPointerCancel: () =>
                                  _progressPointerCancelled = true,
                              // 取消只重置状态，不跳转。
                              onDragCancel: () => setState(() {
                                _progressDragging = false;
                                _progressPointerCancelled = false;
                              }),
                            ),
                          ),
                        ),
                      GlassDock(
                        key: const ValueKey('reader-liquid-dock'),
                        selectedIndex: 1,
                        reduceMotion: widget.state.reduceMotion,
                        items: [
                          GlassDockItem(
                            CupertinoIcons.arrow_left,
                            '上一章',
                            enabled: _total > 0 && _chapter > 0,
                          ),
                          GlassDockItem(
                            CupertinoIcons.book,
                            '${_total == 0 ? 0 : _chapter + 1} / $_total',
                            enabled: _total > 0,
                            selectableOnDrag: false,
                            semanticLabel:
                                '目录，当前第 ${_total == 0 ? 0 : _chapter + 1} 章，共 $_total 章',
                          ),
                          GlassDockItem(
                            CupertinoIcons.arrow_right,
                            '下一章',
                            enabled: _chapter + 1 < _total,
                          ),
                        ],
                        onSelected: (index) {
                          if (index == 1) {
                            _catalogue();
                          } else {
                            _goTo(_chapter + (index == 0 ? -1 : 1));
                          }
                        },
                      ),
                    ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: MediaQuery.paddingOf(context).bottom + 6,
              child: ValueListenableBuilder<double>(
                valueListenable: _progressValue,
                builder: (context, progress, _) => ReaderStatusLine(
                  chrome: _chrome,
                  text: '${_chapterTitle()} · ${(progress * 100).round()}%',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _message(String text) => Center(child: Text(text));

  Widget _content(BuildContext context) {
    final media = MediaQuery.of(context);
    final cacheWidth = (media.size.width * media.devicePixelRatio)
        .clamp(800, 2400)
        .round();
    return FutureBuilder<
      ({List<EpubBlock> blocks, Map<String, Uint8List> images})
    >(
      future: _load(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          _chapterReady = false;
          _syncReadingActivity();
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          _chapterReady = false;
          _syncReadingActivity();
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('章节加载失败'),
                const SizedBox(height: 12),
                TextButton(onPressed: _retry, child: const Text('重试')),
              ],
            ),
          );
        }
        final data = snapshot.data!;
        _chapterReady = data.blocks.isNotEmpty;
        _syncReadingActivity();
        // 懒加载：只构建可见块，不是一次性把整章所有块（含图片 widget）
        // 全部建出来；每次只加载一章图片。切换章节时 connectionState != done，
        // 上方分支返回加载指示，不会把旧章正文当成新章显示；旧 snapshot
        // 是否保留取决于 FutureBuilder 内部，不作为保证。
        return NotificationListener<ScrollMetricsNotification>(
          onNotification: (notification) {
            // 内容尺寸变化（图片解码、字号）后刷新进度与单章可滚动状态。
            if (_hasLayout) {
              _lastOffset = _scroll.offset;
              _lastMax = _scroll.position.maxScrollExtent;
            }
            _updateProgress();
            if (_total == 1) {
              final scrollable = notification.metrics.maxScrollExtent > 0;
              if (scrollable != _singleScrollable) {
                setState(() => _singleScrollable = scrollable);
              }
            }
            return false;
          },
          child: ListView.builder(
            key: ValueKey('epub-chapter-$_chapter-$_chapterVisit'),
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              20 + media.padding.left,
              media.padding.top + FrostedHeader.toolbarHeight + 16,
              20 + media.padding.right,
              media.padding.bottom + 108,
            ),
            itemCount: data.blocks.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Text(
                    _chapterTitle(),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              }
              return _block(
                index - 1,
                data.blocks[index - 1],
                data.images,
                cacheWidth,
              );
            },
          ),
        );
      },
    );
  }

  Widget _block(
    int blockIndex,
    EpubBlock block,
    Map<String, Uint8List> images,
    int cacheWidth,
  ) {
    if (block.kind == EpubBlockKind.image) {
      final bytes = images[block.entryPath];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: bytes == null
            ? _brokenImage()
            : Image.memory(
                bytes,
                fit: BoxFit.fitWidth,
                width: double.infinity,
                cacheWidth: cacheWidth,
                errorBuilder: (_, _, _) => _brokenImage(),
              ),
      );
    }
    final purified = ReaderPurificationStore.shared.purifyParagraph(
      block.text ?? '',
      bookId: _novel.id,
      chapterIndex: _chapter,
    );
    final chapterId = _total > 0 ? _novel.chapters[_chapter].id : null;
    final style = TextStyle(
      fontSize: widget.state.fontSize,
      height: widget.state.lineHeight,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .87),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: ReaderSelectionFragment(
        paragraph: blockIndex,
        chapter: chapterId,
        text: purified,
        child: AnimatedBuilder(
          animation: widget.state.underlineChanges,
          builder: (context, _) {
            final annotations = chapterId == null
                ? const <ReaderAnnotationRange>[]
                : widget.state.annotationsFor(_novel.id, chapterId: chapterId);
            final marks = annotations.isEmpty
                ? const <ReaderTextMark>[]
                : clipReaderParagraphMarks(
                    annotations,
                    paragraph: blockIndex,
                    textLength: purified.length,
                  );
            if (marks.isEmpty) {
              return Text(purified, style: style);
            }
            final dark = Theme.of(context).brightness == Brightness.dark;
            final baseColor =
                style.color ?? Theme.of(context).colorScheme.onSurface;
            final spans = buildReaderMarkedSpans(
              text: purified,
              marks: marks,
              baseTextColor: baseColor,
              dark: dark,
            );
            Widget child = Text.rich(TextSpan(children: spans), style: style);
            if (marks.any((m) => m.style == ReaderMarkStyle.outline)) {
              child = ReaderAnnotationOutlines(
                marks: marks,
                baseTextColor: baseColor,
                dark: dark,
                child: child,
              );
            }
            return child;
          },
        ),
      ),
    );
  }

  Widget _brokenImage() {
    return const Center(child: Icon(Icons.broken_image, size: 48));
  }
}

class LocalEpubReaderTools extends StatefulWidget {
  const LocalEpubReaderTools({
    super.key,
    required this.novel,
    required this.state,
    required this.chapter,
    required this.onAddBookmark,
    this.initialBookmarks = false,
    this.chapterProgress = 0,
  });

  final Novel novel;
  final LibraryState state;
  final int chapter;
  final Future<ReaderBookmark?> Function() onAddBookmark;
  final bool initialBookmarks;

  /// 打开面板时当前章的滚动比例（0~1）。
  final double chapterProgress;

  @override
  State<LocalEpubReaderTools> createState() => _LocalEpubReaderToolsState();
}

class _LocalEpubReaderToolsState extends State<LocalEpubReaderTools> {
  late String _tab = widget.initialBookmarks ? 'bookmarks' : 'layout';
  bool _adding = false;
  String? _addedId;
  String? _error;

  Future<void> _typography({
    double? fontSize,
    double? lineHeight,
    bool persist = true,
  }) async {
    try {
      await widget.state.setTypography(
        fontSize: fontSize,
        lineHeight: lineHeight,
        persist: persist,
      );
    } catch (_) {
      if (mounted) setState(() => _error = '排版设置保存失败，请重试');
    }
  }

  Future<void> _add() async {
    if (_adding) return;
    final existingId = _addedId;
    if (existingId != null &&
        widget.state
            .bookmarksFor(widget.novel.id)
            .any((mark) => mark.id == existingId)) {
      setState(() {
        _adding = true;
        _error = null;
      });
      try {
        await widget.state.removeBookmark(widget.novel.id, existingId);
        if (mounted) setState(() => _addedId = null);
      } catch (_) {
        if (mounted) setState(() => _error = '书签删除失败，请重试');
      } finally {
        if (mounted) setState(() => _adding = false);
      }
      return;
    }
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final mark = await widget.onAddBookmark();
      if (mounted) {
        setState(() {
          _addedId = mark?.id;
          if (mark == null) _error = '书签保存失败，请重试';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '书签保存失败，请重试');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _remove(ReaderBookmark mark) async {
    setState(() => _error = null);
    try {
      await widget.state.removeBookmark(widget.novel.id, mark.id);
      if (mounted && mark.id == _addedId) setState(() => _addedId = null);
    } catch (_) {
      if (mounted) setState(() => _error = '书签删除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.state.readerSettingsChanges,
      widget.state.bookmarkChanges,
    ]),
    builder: (context, _) => ListView(
      key: const ValueKey('epub-settings-scroll'),
      shrinkWrap: true,
      primary: false,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Row(
          children: [
            const Expanded(
              child: ArchiveSection(
                title: '阅读设置',
                code: 'READER / CONTROL PANEL',
              ),
            ),
            GlassIconButton(
              icon: CupertinoIcons.xmark,
              label: '关闭阅读设置',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 12),
        CupertinoSlidingSegmentedControl<String>(
          groupValue: _tab,
          children: const {'layout': Text('排版与进度'), 'bookmarks': Text('书签')},
          onValueChanged: (tab) {
            if (tab != null) setState(() => _tab = tab);
          },
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_tab == 'layout') ..._layout() else ..._bookmarks(),
      ],
    ),
  );

  List<Widget> _layout() => [
    ReaderValueSlider(
      sliderKey: const ValueKey('reader-font-slider'),
      label: '字体大小',
      value: widget.state.fontSize,
      min: readerFontSizeMin,
      max: readerFontSizeMax,
      divisions: 16,
      format: (value) => '${value.round()} pt',
      onPreview: (value) => _typography(fontSize: value, persist: false),
      onCommitted: (value) => _typography(fontSize: value),
    ),
    const SizedBox(height: 8),
    ReaderValueSlider(
      sliderKey: const ValueKey('reader-line-height-slider'),
      label: '行距',
      value: widget.state.lineHeight,
      min: 1.3,
      max: 2.2,
      format: (value) => '${value.toStringAsFixed(2)} 倍',
      onPreview: (value) => _typography(lineHeight: value, persist: false),
      onCommitted: (value) => _typography(lineHeight: value),
    ),
    Align(
      alignment: Alignment.centerRight,
      child: GlassTextButton(
        onPressed: () => _typography(fontSize: 19, lineHeight: 1.72),
        child: const Text('恢复默认排版'),
      ),
    ),
    const Divider(height: 24),
    Text('第 ${widget.chapter + 1} 章 / 共 ${widget.novel.chapters.length} 章'),
    const SizedBox(height: 8),
    Text(
      '本章已读 ${(widget.chapterProgress.clamp(0.0, 1.0) * 100).round()}%',
      key: const ValueKey('epub-chapter-progress'),
    ),
    const SizedBox(height: 8),
    GlassTextButton(
      key: const ValueKey('epub-open-purification'),
      onPressed: () => Navigator.pop(context, const ReaderOpenPurification()),
      child: const Text('正文净化与纠错'),
    ),
    const SizedBox(height: 8),
    GlassTextButton(
      onPressed: () => Navigator.pop(context, const ReaderEnterFocus()),
      child: const Text('专注阅读 · 隐藏控件'),
    ),
    const Text('点按正文即可显示或隐藏控件'),
  ];

  List<Widget> _bookmarks() {
    final marks = widget.state.bookmarksFor(widget.novel.id);
    return [
      GlassTextButton(
        key: const ValueKey('reader-add-bookmark'),
        onPressed: _adding ? null : _add,
        child: Text(
          _adding
              ? '正在保存…'
              : _addedId != null
              ? '已添加书签'
              : '添加当前章节书签',
        ),
      ),
      const SizedBox(height: 8),
      const Text('EPUB 书签目前仅支持跳转到章首，暂不支持章内精确定位。'),
      const SizedBox(height: 8),
      Text('本书 ${marks.length} 个书签'),
      if (marks.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text('将喜欢的章节存成书签，下次直接回到这里。'),
        ),
      for (final mark in marks) _bookmark(mark),
    ];
  }

  Widget _bookmark(ReaderBookmark mark) {
    final chapter = widget.state.chapterForPosition(
      widget.novel,
      mark.position,
    );
    return Row(
      children: [
        Expanded(
          child: JellyTapSurface(
            key: ValueKey('reader-bookmark-${mark.id}'),
            onTap: chapter == null
                ? null
                : () => Navigator.pop(context, ReaderOpenBookmark(mark)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mark.chapterTitle),
                  Text(
                    chapter == null ? '章节已从目录移除' : '第 ${chapter + 1} 章 · 章首',
                  ),
                ],
              ),
            ),
          ),
        ),
        GlassIconButton(
          icon: CupertinoIcons.trash,
          label: '删除书签 ${mark.id}',
          onPressed: () => _remove(mark),
        ),
      ],
    );
  }
}
