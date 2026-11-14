part of 'pages.dart';

extension _ReaderPagePersistence on _ReaderPageState {
  ReadingPosition? _positionForParagraph(int paragraphIndex, int startOffset) {
    final content = _currentContent;
    if (content == null ||
        _novel.chapters.isEmpty ||
        paragraphIndex < 0 ||
        paragraphIndex >= content.paragraphs.length) {
      return _currentPosition(bookmark: true);
    }
    final base = _currentPosition(bookmark: true);
    final chapter = _novel.chapters[_chapter];
    final length = content.paragraphs[paragraphIndex].length;
    final fraction = length <= 0
        ? 0.0
        : (startOffset / length).clamp(0.0, 1.0);
    return ReadingPosition(
      chapter: _chapter,
      chapterId: chapter.id,
      revision: chapter.revision,
      contentRevision: content.revision,
      textOffset: paragraphTextOffset(content.paragraphs, paragraphIndex),
      offset: base?.offset ?? 0,
      fraction: base?.fraction ?? 0,
      fontSize: widget.state.fontSize,
      lineHeight: widget.state.lineHeight,
      width: base?.width ?? _layoutWidth,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      paragraphIndex: paragraphIndex,
      paragraphFraction: fraction,
      textScale: _textScale,
      typeface: _layoutFontId,
    );
  }

  List<ReaderUnderlineRange> _selectionToUnderlineRanges(
    ReaderQuoteSelection selection,
  ) {
    if (_novel.chapters.isEmpty) return const [];
    final fallbackChapterId = _novel.chapters[_chapter].id;
    final contentRevision = _currentContent?.revision ?? '';
    final byChapter = <int, List<ReaderQuoteRange>>{};
    for (final range in selection.ranges) {
      final chapterId = range.chapter ?? fallbackChapterId;
      (byChapter[chapterId] ??= []).add(range);
    }
    final out = <ReaderUnderlineRange>[];
    for (final entry in byChapter.entries) {
      final ranges = entry.value
        ..sort((a, b) => a.paragraph != b.paragraph
            ? a.paragraph.compareTo(b.paragraph)
            : a.start.compareTo(b.start));
      final first = ranges.first;
      final last = ranges.last;
      final candidate = ReaderUnderlineRange(
        chapterId: entry.key,
        startParagraph: first.paragraph,
        startOffset: first.start,
        endParagraph: last.paragraph,
        endOffset: last.end,
        contentRevision: contentRevision,
      );
      if (candidate.isValid) out.add(candidate);
    }
    return canonicalReaderUnderlineRanges(out);
  }

  ReaderBookmark? _underlineBookmarkAt(
    int paragraph,
    int offset, {
    int? chapterId,
  }) {
    if (_novel.chapters.isEmpty) return null;
    final targetChapterId = chapterId ?? _novel.chapters[_chapter].id;
    for (final mark in widget.state.bookmarksFor(_novel.id)) {
      if (!mark.isUnderline) continue;
      for (final range in mark.underlineRanges) {
        if (range.chapterId != targetChapterId) continue;
        if (paragraph < range.startParagraph ||
            paragraph > range.endParagraph) {
          continue;
        }
        if (paragraph == range.startParagraph && offset < range.startOffset) {
          continue;
        }
        if (paragraph == range.endParagraph && offset >= range.endOffset) {
          continue;
        }
        return mark;
      }
    }
    return null;
  }

  Future<ReaderAnnotationContext?> _annotationContext(
    List<ReaderUnderlineRange> ranges,
    ReadingPosition anchor,
  ) async {
    final offline = await loadOfflineReaderAnnotationContext(
      repository: widget.repository,
      state: widget.state,
      novelId: _novel.id,
      ranges: ranges,
      anchor: anchor,
      novel: _novel,
    );
    if (offline != null) return offline;
    final content = _currentContent;
    if (content == null || _novel.chapters.isEmpty) return null;
    final chapter = _novel.chapters[_chapter];
    return ReaderAnnotationContext(
      novelId: _novel.id,
      novel: _novel,
      chapters: [
        ReaderAnnotationChapterSource(
          chapterId: chapter.id,
          title: chapter.title,
          content: content,
        ),
      ],
    );
  }

  Future<void> _editBookmarkAnnotation(
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
      rangeContextResolver: _annotationContext,
    );
    if (mounted && updated != null) {
      showNovelFeedback(context, '已更新标记与批注');
    }
  }

  Future<void> _pickChapterTextInMarksSheet({
    BuildContext? sheetContext,
  }) async {
    final content = _currentContent;
    if (content == null ||
        content.paragraphs.isEmpty ||
        _novel.chapters.isEmpty) {
      return;
    }
    final currentPos = _currentPosition(bookmark: true);
    var paragraphIndex = (currentPos?.paragraphIndex ?? 0).clamp(
      0,
      content.paragraphs.length - 1,
    );
    for (var i = 0; i < content.paragraphs.length; i++) {
      final candidate = (paragraphIndex + i) % content.paragraphs.length;
      final text = content.paragraphs[candidate];
      if (text.trim().isNotEmpty && readerIllustrationUrl(text) == null) {
        paragraphIndex = candidate;
        break;
      }
    }
    final anchor = _positionForParagraph(paragraphIndex, 0);
    if (anchor == null) return;
    try {
      final ctx = await _annotationContext(const [], anchor);
      if (!mounted || ctx == null) return;
      final seedChange = ctx.paragraphAt(anchor);
      final projection = ctx.project(
        ranges: seedChange.ranges,
        anchor: anchor,
      );
      if (sheetContext != null && !sheetContext.mounted) return;
      final picked = await showReaderTextRangePicker(
        context: sheetContext ?? context,
        text: projection.text,
        initialRange: projection.initialRange,
        title: '选字划线 / 复制片段',
        scopeLabel: projection.scopeLabel,
        confirmLabel: '添加划线',
        reduceMotion: widget.state.reduceMotion,
        maxSelectionCodeUnits: 12000,
      );
      if (!mounted || picked == null) return;
      final change = projection.apply(picked);
      final first = change.ranges.first;
      final pos = _positionForParagraph(
        first.startParagraph,
        first.startOffset,
      );
      if (pos == null) return;
      await widget.state.addUnderline(
        novel: _novel,
        position: pos,
        ranges: change.ranges,
        quote: change.quote,
      );
      if (mounted) showNovelFeedback(context, '已添加划线');
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          error is FormatException ? error.message : '划线未保存，请重试',
        );
      }
    }
  }

  Future<void> _toggleSelectionUnderline(ReaderQuoteSelection selection) async {
    final ranges = _selectionToUnderlineRanges(selection);
    if (ranges.isEmpty) return;
    final first = selection.ranges.first;
    final position = _positionForParagraph(first.paragraph, first.start);
    if (position == null) return;
    try {
      final added = await widget.state.toggleUnderline(
        novel: _novel,
        position: position,
        ranges: ranges,
        quote: selection.quote,
      );
      if (!mounted) return;
      showNovelFeedback(context, added ? '已添加划线' : '已取消划线');
    } catch (_) {
      if (mounted) showNovelFeedback(context, '划线未保存，请重试');
    }
  }

  Future<void> _annotateSelection(ReaderQuoteSelection selection) async {
    final ranges = _selectionToUnderlineRanges(selection);
    if (ranges.isEmpty) return;
    final first = selection.ranges.first;
    final position = _positionForParagraph(first.paragraph, first.start);
    if (position == null) return;
    final mark = await showReaderAnnotationEditor(
      context,
      state: widget.state,
      novelId: _novel.id,
      novel: _novel,
      position: position,
      ranges: ranges,
      quote: selection.quote,
      initialStyle: ReaderMarkStyle.underline,
      rangeContextResolver: _annotationContext,
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
        if (_activeBookmarkId == existing.id) _clearBookmarkLanding();
        if (mounted) showNovelFeedback(context, '已取消书签');
      } catch (_) {
        if (mounted) showNovelFeedback(context, '书签删除失败，请重试');
      }
      return;
    }
    final first = selection.ranges.first;
    final position = _positionForParagraph(first.paragraph, first.start);
    if (position == null) return;
    try {
      final mark = await widget.state.addBookmark(
        novel: _novel,
        position: position,
        quote: selection.quote,
      );
      if (!mounted) return;
      if (mark != null) {
        _activeBookmarkId = mark.id;
        showNovelFeedback(context, '已添加摘录书签');
      }
    } catch (_) {
      if (mounted) showNovelFeedback(context, '书签保存失败，请重试');
    }
  }

  Future<void> _purifySelection(ReaderQuoteSelection selection) async {
    final first = selection.ranges.first;
    final position = _positionForParagraph(first.paragraph, first.start);
    await _openPurificationInChapter(position, selection.quote);
  }

  void _saveWhenIdle() {
    _idleSave?.cancel();
    if (_restoring) return;
    final generation = _contentGeneration;
    _idleSave = Timer(const Duration(milliseconds: 160), () {
      _idleSave = null;
      if (mounted &&
          generation == _contentGeneration &&
          _scroll.hasClients &&
          !_scroll.position.isScrollingNotifier.value) {
        _savePosition(notify: false);
      }
    });
  }

  void _savePosition({bool notify = true, bool finalSave = false}) {
    // Explicit save/restore/exit supersedes any delayed copy of that position.
    _idleSave?.cancel();
    _idleSave = null;
    if (_openedForBookmarkInspection) return;
    if (_local != null &&
        (_novel.chapters.isEmpty ||
            !_local!.acceptsChapter(_novel.id, _novel.chapters[_chapter]))) {
      return;
    }
    if (_paginated) {
      _savePagedPosition(notify: notify);
      return;
    }
    if (!_ready ||
        _restoring ||
        !_scroll.hasClients ||
        (_typographyPreviewing && !finalSave)) {
      return;
    }
    // Lazy slivers can emit a scroll-end while correcting their estimated
    // extent during layout. Persist after that frame, not from inside layout.
    final duringLayout =
        WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks;
    if (duringLayout && !finalSave) {
      if (!_saveQueued) {
        _saveQueued = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _saveQueued = false;
          if (mounted) _savePosition(notify: notify);
        });
      }
      return;
    }
    final position = _currentPosition(includeParagraph: !duringLayout);
    unawaited(
      widget.state
          .savePosition(
            novel: _novel,
            chapter: _chapter,
            offset: position?.offset ?? _scroll.offset,
            maximum: _scroll.position.maxScrollExtent,
            width: _layoutWidth,
            notify: notify,
            textOffset: position?.textOffset,
            paragraphIndex: position?.paragraphIndex,
            paragraphFraction: position?.paragraphFraction ?? 0,
            textScale: _textScale,
            typeface: position?.typeface ?? _layoutFontId,
          )
          .catchError((Object _) {}),
    );
  }

  double get _textScale => _layoutTextScale;

  /// Paged records hold a fraction, not pixels. Width 0 never matches a laid
  /// out reader (and is what v1.7.1 records without a width already read
  /// back as), so scroll mode always restores them by paragraph anchor.
  static const double _pagedRecordWidth = 0;

  /// Paged/vertical position: the paragraph anchor carries it across modes
  /// (scroll mode restores by paragraph when geometry differs). The raw
  /// offset/maximum pair stores the in-chapter fraction, never pixels.
  /// Same record shape as scroll mode, for bookmarks and the progress sheet.
  /// `width` is stored as [_pagedRecordWidth] so scroll mode's `sameLayout`
  /// check can never treat the 0–1 fraction in `offset` as pixels.
  ReadingPosition? _pagedPosition() {
    final anchor = _paged.anchor;
    final content = _currentContent;
    if (!_ready ||
        !_paged.ready ||
        anchor == null ||
        content == null ||
        _novel.chapters.isEmpty) {
      return null;
    }
    final paragraphs = content.paragraphs;
    if (anchor.paragraph < 0 || anchor.paragraph >= paragraphs.length) {
      return null;
    }
    final length = paragraphs[anchor.paragraph].length;
    return ReadingPosition(
      chapter: _chapter,
      chapterId: _novel.chapters[_chapter].id,
      revision: _novel.chapters[_chapter].revision,
      textOffset: paragraphTextOffset(paragraphs, anchor.paragraph),
      offset: _paged.fraction,
      fraction: _paged.fraction,
      fontSize: widget.state.fontSize,
      lineHeight: widget.state.lineHeight,
      width: _pagedRecordWidth,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      paragraphIndex: anchor.paragraph,
      paragraphFraction: length <= 0
          ? 0
          : (anchor.offset / length).clamp(0.0, 1.0),
      textScale: _textScale,
      typeface: _layoutFontId,
    );
  }

  void _savePagedPosition({bool notify = true}) {
    final position = _pagedPosition();
    if (position == null) return;
    unawaited(
      widget.state
          .savePosition(
            novel: _novel,
            chapter: _chapter,
            offset: position.fraction,
            maximum: 1,
            width: _pagedRecordWidth,
            notify: notify,
            textOffset: position.textOffset,
            paragraphIndex: position.paragraphIndex,
            paragraphFraction: position.paragraphFraction,
            textScale: _textScale,
            typeface: _layoutFontId,
          )
          .catchError((Object _) {}),
    );
  }

  ReadingPosition? _currentPosition({
    bool includeParagraph = true,
    bool bookmark = false,
  }) {
    if (_paginated) return _pagedPosition();
    if (!_ready ||
        _restoring ||
        !_scroll.hasClients ||
        _novel.chapters.isEmpty) {
      return null;
    }
    final maximum = _scroll.position.maxScrollExtent;
    final offset = _scroll.offset.clamp(
      0.0,
      maximum.clamp(0.0, double.infinity),
    );
    var paragraph = includeParagraph
        ? _paragraphRegistry.capture(offset + _readingInset, clampToLast: true)
        : null;
    if (!includeParagraph) {
      // A route can be disposed inside layout, where reading RenderBox sizes
      // is invalid. Retain an already measured anchor only for the exact same
      // chapter, offset and geometry; otherwise keep the raw-offset fallback.
      final previous = widget.state.positionFor(_novel.id);
      if (previous != null &&
          previous.paragraphIndex != null &&
          previous.chapter == _chapter &&
          previous.chapterId == _novel.chapters[_chapter].id &&
          (previous.offset - offset).abs() < .5 &&
          previous.fontSize == widget.state.fontSize &&
          previous.lineHeight == widget.state.lineHeight &&
          previous.typeface == _layoutFontId &&
          (previous.width - _layoutWidth).abs() < .5 &&
          (previous.textScale - _textScale).abs() < .01) {
        paragraph = (
          index: previous.paragraphIndex!,
          fraction: previous.paragraphFraction,
        );
      }
    }
    return ReadingPosition(
      chapter: _chapter,
      chapterId: _novel.chapters[_chapter].id,
      revision: _novel.chapters[_chapter].revision,
      textOffset: _currentContent == null
          ? null
          : paragraphTextOffset(
              _currentContent!.paragraphs,
              paragraph?.index ?? 0,
            ),
      offset: offset,
      fraction: maximum > 0 ? (offset / maximum).clamp(0, 1) : 0,
      fontSize: widget.state.fontSize,
      lineHeight: widget.state.lineHeight,
      width: _layoutWidth,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      paragraphIndex: paragraph?.index,
      paragraphFraction: paragraph?.fraction ?? 0,
      textScale: _textScale,
      typeface: _layoutFontId,
    );
  }

  void _prepareRestore(ReadingPosition position) {
    _restorePending = position;
    _restoreQueued = false;
    _restoring = true;
    _restoreTicket++;
  }

  List<ReaderBookmark> _currentPositionBookmarks() {
    final marks = widget.state.bookmarksFor(_novel.id);
    if (marks.isEmpty) return const [];
    final matched = <ReaderBookmark>[];
    for (final mark in marks) {
      if (mark.isUnderline ||
          widget.state.chapterForPosition(_novel, mark.position) != _chapter) {
        continue;
      }
      if (mark.id == _activeBookmarkId) {
        matched.add(mark);
        continue;
      }
      if (mark.quote.isNotEmpty) {
        continue;
      }
      if (_paginated) {
        final anchor =
            _paged.anchor?.paragraph ?? _restorePending?.paragraphIndex;
        if (anchor != null && mark.position.paragraphIndex == anchor) {
          matched.add(mark);
        }
      } else if (_scroll.hasClients) {
        if ((mark.position.offset - _scroll.offset).abs() < 24 &&
            (mark.position.fontSize - widget.state.fontSize).abs() < .01 &&
            (mark.position.lineHeight - widget.state.lineHeight).abs() < .01) {
          matched.add(mark);
        }
      }
    }
    return matched;
  }

  bool get _isCurrentPositionBookmarked =>
      _currentPositionBookmarks().isNotEmpty;

  void _clearBookmarkLanding() {
    _activeBookmarkId = null;
    _bookmarkLandingTimer?.cancel();
    _bookmarkLandingPending = false;
    _bookmarkLanding.value = null;
  }

  void _landBookmark(ReadingPosition? saved, {int? paragraphIndex}) {
    if (!_bookmarkLandingPending || !_scroll.hasClients) return;
    _bookmarkLandingPending = false;
    final savedIndex = paragraphIndex ?? saved?.paragraphIndex;
    final index =
        savedIndex != null && savedIndex >= 0 && savedIndex < _paragraphCount
        ? savedIndex
        : _paragraphRegistry.capture(_scroll.offset + _readingInset)?.index ??
              0;
    if (index >= _paragraphCount) return;
    _bookmarkLanding.value = index;
    _bookmarkLandingTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) _bookmarkLanding.value = null;
    });
  }

  void _applyTypography({
    double? fontSize,
    double? lineHeight,
    bool persist = true,
  }) {
    final font = fontSize ?? widget.state.fontSize;
    final spacing = lineHeight ?? widget.state.lineHeight;
    if (font == widget.state.fontSize && spacing == widget.state.lineHeight) {
      if (persist) {
        unawaited(
          widget.state
              .setTypography(fontSize: fontSize, lineHeight: lineHeight)
              .catchError((Object _) {
                if (mounted) showNovelFeedback(context, '排版设置保存失败，请重试');
              }),
        );
      }
      return;
    }
    final position = _currentPosition();
    if (position != null) _prepareRestore(position);
    unawaited(
      widget.state
          .setTypography(
            fontSize: fontSize,
            lineHeight: lineHeight,
            persist: persist,
          )
          .catchError((Object _) {
            if (mounted) showNovelFeedback(context, '排版设置保存失败，请重试');
          }),
    );
  }

  Future<ReaderBookmark?> _addBookmark() async {
    _openedForBookmarkInspection = false;
    final position = _currentPosition(bookmark: true);
    if (position == null) return null;
    _savePosition(notify: false);
    final mark = await widget.state.addBookmark(
      novel: _novel,
      position: position,
    );
    if (mark != null) _activeBookmarkId = mark.id;
    return mark;
  }

  Future<void> _quickAddBookmark() async {
    if (_addingBookmark) return;
    _addingBookmark = true;
    final matched = _currentPositionBookmarks();
    if (matched.isNotEmpty) {
      try {
        for (final mark in matched) {
          await widget.state.removeBookmark(_novel.id, mark.id);
        }
        _clearBookmarkLanding();
        if (mounted) showNovelFeedback(context, '已取消书签');
      } catch (_) {
        if (mounted) showNovelFeedback(context, '书签删除失败，请重试');
      } finally {
        _addingBookmark = false;
      }
      return;
    }
    final existing = widget.state
        .bookmarksFor(_novel.id)
        .map((mark) => mark.id)
        .toSet();
    try {
      final mark = await _addBookmark();
      if (!mounted) return;
      if (mark == null) {
        showNovelFeedback(context, '书签保存失败，请重试');
      } else if (existing.contains(mark.id)) {
        await widget.state.removeBookmark(_novel.id, mark.id);
        _clearBookmarkLanding();
        if (mounted) showNovelFeedback(context, '已取消书签');
      } else {
        showNovelFeedback(context, '已添加书签');
      }
    } catch (_) {
      if (mounted) showNovelFeedback(context, '书签保存失败，请重试');
    } finally {
      _addingBookmark = false;
    }
  }

  Future<void> _seekProgress(double fraction) async {
    _openedForBookmarkInspection = false;
    _suspendListeningFollow();
    if (_paginated) {
      if (_ready) _paged.seek(fraction.clamp(0.0, 1.0));
      return;
    }
    if (!_ready || !_scroll.hasClients) return;
    _clearBookmarkLanding();
    final value = fraction.clamp(0.0, 1.0);
    final generation = _contentGeneration;
    final ticket = ++_restoreTicket;
    _restoring = true;
    // A lazy sliver refines its estimate after a large jump. Follow that new
    // extent for a bounded number of frames, including an exact chapter end.
    try {
      for (var step = 0; step < 4; step++) {
        if (!mounted ||
            generation != _contentGeneration ||
            ticket != _restoreTicket ||
            !_scroll.hasClients) {
          return;
        }
        final maximum = _scroll.position.maxScrollExtent;
        _scroll.jumpTo(value * maximum);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted ||
            generation != _contentGeneration ||
            ticket != _restoreTicket ||
            !_scroll.hasClients) {
          return;
        }
        if ((_scroll.position.maxScrollExtent - maximum).abs() < .5) break;
      }
    } finally {
      if (ticket == _restoreTicket) _restoring = false;
    }
    _savePosition(notify: false);
  }

  void _restoreAfterLayout() {
    // The paged engine restores from its `position` argument itself.
    if (_paginated) {
      _restoring = false;
      return;
    }
    if (_restoreQueued) return;
    _restoreQueued = true;
    final generation = _contentGeneration;
    final ticket = ++_restoreTicket;
    _restoring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      var completed = false;
      try {
        if (!mounted ||
            generation != _contentGeneration ||
            ticket != _restoreTicket ||
            !_scroll.hasClients ||
            !_ready) {
          return;
        }
        final saved = _restorePending;
        _restorePending = null;
        int? landingParagraph;
        if (saved != null) {
          final centreBookmark = _bookmarkLandingPending;
          final viewportBottom = centreBookmark
              ? (_scroll.position.viewportDimension -
                        MediaQuery.paddingOf(context).bottom -
                        96)
                    .clamp(_readingInset + 1, double.infinity)
              : null;
          final sameLayout =
              (saved.fontSize - widget.state.fontSize).abs() < .01 &&
              (saved.lineHeight - widget.state.lineHeight).abs() < .01 &&
              (saved.width - _layoutWidth).abs() < 1 &&
              (saved.textScale - _textScale).abs() < .01 &&
              saved.typeface == widget.state.effectiveReaderFontId;
          var anchor =
              saved.paragraphIndex != null &&
                  saved.paragraphIndex! >= 0 &&
                  saved.paragraphIndex! < _paragraphCount
              ? (
                  index: saved.paragraphIndex!,
                  fraction: saved.paragraphFraction,
                )
              : null;
          for (var step = 0; step < 10; step++) {
            if (!mounted ||
                generation != _contentGeneration ||
                ticket != _restoreTicket ||
                !_scroll.hasClients) {
              return;
            }
            final maximum = _scroll.position.maxScrollExtent;
            final paragraph = anchor == null
                ? null
                : _paragraphRegistry.target(
                    anchor,
                    _readingInset,
                    viewportBottom: viewportBottom,
                    trailingSpace: centreBookmark ? 12 : 0,
                  );
            final target = sameLayout && step == 0 && !centreBookmark
                ? saved.offset
                : paragraph?.offset ??
                      (sameLayout && saved.fraction < .999
                          ? saved.offset
                          : saved.fraction * maximum);
            _scroll.jumpTo(
              target.clamp(
                0.0,
                centreBookmark && paragraph?.exact == true
                    ? maximum.clamp(0.0, double.infinity)
                    : double.infinity,
              ),
            );
            await WidgetsBinding.instance.endOfFrame;
            if (!mounted ||
                generation != _contentGeneration ||
                ticket != _restoreTicket ||
                !_scroll.hasClients) {
              return;
            }
            // Older bookmarks stored only pixels. Resolve that position once,
            // then use the same paragraph-centred refinement as newer bookmarks.
            if (centreBookmark && anchor == null) {
              anchor = _paragraphRegistry.capture(
                _scroll.offset + _readingInset,
                clampToLast: true,
              );
            }
            final refined = anchor == null
                ? null
                : _paragraphRegistry.target(
                    anchor,
                    _readingInset,
                    viewportBottom: viewportBottom,
                    trailingSpace: centreBookmark ? 12 : 0,
                  );
            if (refined?.exact == true &&
                (_scroll.offset -
                            refined!.offset.clamp(
                              0.0,
                              centreBookmark
                                  ? _scroll.position.maxScrollExtent.clamp(
                                      0.0,
                                      double.infinity,
                                    )
                                  : double.infinity,
                            ))
                        .abs() <
                    .5) {
              break;
            }
            if (anchor == null &&
                (_scroll.position.maxScrollExtent - maximum).abs() < .5) {
              break;
            }
          }
          landingParagraph = anchor?.index;
        }
        if (!mounted ||
            generation != _contentGeneration ||
            ticket != _restoreTicket) {
          return;
        }
        _restoring = false;
        _revealChapter();
        _landBookmark(saved, paragraphIndex: landingParagraph);
        _savePosition();
        completed = true;
      } finally {
        if (ticket == _restoreTicket) {
          _restoring = false;
          if (!completed) _restoreQueued = false;
          _updateProgressFromScroll();
          _syncReadingActivity();
        }
      }
    });
  }
}
