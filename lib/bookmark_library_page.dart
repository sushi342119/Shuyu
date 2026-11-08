import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'library_reflow.dart';
import 'local_library.dart';
import 'local_platform.dart';
import 'offline_repository.dart';
import 'pages.dart' show readerPageFor;
import 'quote_card.dart';
import 'reader_annotation_editor.dart';
import 'reader_content.dart';
import 'reader_underline.dart';
import 'setting_menu.dart';
import 'user_fonts.dart';

Future<void> organizeBookmark(
  BuildContext context,
  LibraryState state,
  int novelId,
  ReaderBookmark mark,
) async {
  final text = TextEditingController(text: mark.category);
  try {
    final names =
        state.bookmarkEntries
            .map((e) => e.bookmark.category)
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final category = await showJellySheet<String>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (sheet) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '书签分类', code: 'EXCERPTS / CATEGORY'),
            const SizedBox(height: 18),
            CupertinoTextField(
              key: const ValueKey('bookmark-category-name'),
              onTap: () => AppHaptics.play(sheet, HapticCue.selection),
              onSubmitted: (_) => AppHaptics.play(sheet, HapticCue.action),
              controller: text,
              maxLength: 30,
              placeholder: '新建或选择分类',
              padding: const EdgeInsets.all(14),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                GlassTextButton(
                  onPressed: () => Navigator.pop(sheet, ''),
                  child: const Text('未分类'),
                ),
                for (final name in names)
                  GlassTextButton(
                    onPressed: () => Navigator.pop(sheet, name),
                    child: Text(name),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            GlassPillButton(
              icon: CupertinoIcons.checkmark,
              label: '保存分类',
              onPressed: () => Navigator.pop(sheet, text.text.trim()),
            ),
          ],
        ),
      ),
    );
    if (category != null) {
      await state.categorizeBookmark(novelId, mark.id, category);
    }
  } catch (_) {
    if (context.mounted) showNovelFeedback(context, '书签分类未保存，请重试');
  } finally {
    text.dispose();
  }
}

/// Reads only an already-imported original, an offline body or source-owned
/// inline text. This action never calls remote find/chapters/chapterContent.
Future<ReaderAnnotationContext?> loadOfflineReaderAnnotationContext({
  required LibraryState state,
  required NovelRepository repository,
  required int novelId,
  required List<ReaderUnderlineRange> ranges,
  required ReadingPosition anchor,
  Novel? novel,
}) async {
  final offline = repository is OfflineNovelRepository ? repository : null;
  if (offline != null) await offline.cache.load();
  final localStore = state.localLibrary;
  final localBook = localStore?.bookFor(novelId);
  novel =
      novel ??
      (localBook == null ? null : localStore!.toNovel(localBook)) ??
      offline?.cache.book(novelId)?.novel ??
      state.cachedNovel(novelId);
  if (localBook != null && novel != null && novel.chapters.isEmpty) {
    novel = novel.withChapters(await localStore!.chapters(novelId));
  }
  if (novel == null || novel.id != novelId || novel.chapters.isEmpty) {
    return null;
  }
  if (isLocalNovelId(novelId) && localBook == null) {
    return null;
  }
  final requiredIds = ranges.isEmpty
      ? <int>{
          if (anchor.chapterId >= 0 &&
              novel.chapters.any((c) => c.id == anchor.chapterId))
            anchor.chapterId
          else if (anchor.chapter >= 0 &&
              anchor.chapter < novel.chapters.length)
            novel.chapters[anchor.chapter].id,
        }
      : ranges.map((range) => range.chapterId).toSet();
  if (requiredIds.isEmpty ||
      requiredIds.any((id) => !novel!.chapters.any((c) => c.id == id))) {
    return null;
  }
  final candidates = <int>{...requiredIds};
  for (final id in requiredIds) {
    final index = novel.chapters.indexWhere((c) => c.id == id);
    if (index > 0) candidates.add(novel.chapters[index - 1].id);
    if (index + 1 < novel.chapters.length) {
      candidates.add(novel.chapters[index + 1].id);
    }
  }
  final sources = <ReaderAnnotationChapterSource>[];
  for (final chapter in novel.chapters.where(
    (c) => candidates.contains(c.id),
  )) {
    String? body;
    if (localStore != null && isLocalNovelId(novelId)) {
      body = await localStore.chapterContent(novelId, chapter);
    } else if (offline != null) {
      body = await offline.cache.readChapter(novelId, chapter.id);
    } else if (chapter.content.trim().isNotEmpty) {
      body = chapter.content;
    }
    if (body == null || body.trim().isEmpty) {
      if (requiredIds.contains(chapter.id)) return null;
      continue;
    }
    final source = await ReaderContent.parse(body);
    sources.add(
      ReaderAnnotationChapterSource(
        chapterId: chapter.id,
        title: chapter.title,
        content: source,
      ),
    );
  }
  return ReaderAnnotationContext(
    novelId: novelId,
    novel: novel,
    chapters: sources,
  );
}

/// Reuse an installed face. Reports neither download fonts nor require one.
Future<String?> registeredReadingReportSerif(UserFontStore store) async {
  await store.load();
  for (final id in const ['sourceHanSerif', 'sourceHanSerifTW']) {
    if (!store.available(id)) continue;
    await store.ensureLoaded(id);
    if (store.isLoaded(id)) return store.family(id);
  }
  return null;
}

/// A merged volume keeps its original recovery records. Show the equivalent
/// bookmark in the active series once, without deleting those recovery copies.
List<({int novelId, ReaderBookmark bookmark})> libraryBookmarks(
  LibraryState state, {
  LocalLibraryStore? books,
}) => state.bookmarkEntries;

class BookmarkLibraryPage extends StatefulWidget {
  const BookmarkLibraryPage({
    super.key,
    required this.state,
    required this.repository,
  });
  final LibraryState state;
  final NovelRepository repository;
  @override
  State<BookmarkLibraryPage> createState() => _BookmarkLibraryPageState();
}

typedef _BookmarkEntry = ({int novelId, ReaderBookmark bookmark});

class _BookmarkMarkRow {
  const _BookmarkMarkRow(this.entry, this.order);
  final _BookmarkEntry entry;
  final int order;
}

class _BookmarkLibraryPageState extends State<BookmarkLibraryPage>
    with TickerProviderStateMixin {
  String _query = '';
  String _category = '_book';
  final _search = TextEditingController();
  final _expandedBooks = <int>{};
  bool _searchOpen = false;
  String? _opening;
  final _bookClocks = <int, AnimationController>{};
  final _reflow = LibraryReflowController();
  bool _settlingMotion = false;
  late final _reorder =
      AnimationController(
        vsync: this,
        duration: NovelMotion.enter,
        value: 1,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && _reflow.active && mounted) {
          setState(_reflow.finish);
        }
      });

  bool get _reduced =>
      widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    widget.state.appearanceChanges.addListener(_appearanceChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduced) _settleMotion();
  }

  @override
  void didUpdateWidget(BookmarkLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.appearanceChanges.removeListener(_appearanceChanged);
      widget.state.appearanceChanges.addListener(_appearanceChanged);
    }
  }

  void _appearanceChanged() {
    if (!mounted) return;
    if (_reduced) _settleMotion();
    setState(() {});
  }

  void _settleMotion() {
    _settlingMotion = true;
    _reflow.finish();
    _reorder.stop();
    for (final entry in _bookClocks.entries) {
      entry.value.value = _expandedBooks.contains(entry.key) ? 1 : 0;
    }
    _settlingMotion = false;
  }

  AnimationController _clockFor(int id) => _bookClocks.putIfAbsent(id, () {
    final clock = AnimationController(
      vsync: this,
      duration: NovelMotion.enter,
      reverseDuration: NovelMotion.exit,
    );
    clock.addStatusListener((status) {
      if (status == AnimationStatus.dismissed &&
          !_settlingMotion &&
          !_expandedBooks.contains(id) &&
          mounted) {
        _layoutChange(() {}, duration: NovelMotion.contact);
      }
    });
    return clock;
  });

  void _layoutChange(
    VoidCallback change, {
    Duration? duration,
  }) {
    _reorder.duration = duration ?? NovelMotion.enter;
    if (!_reduced) _reflow.begin(_reorder);
    setState(change);
    if (!_reduced) _reorder.forward(from: 0);
  }

  void _toggleBook(int id) {
    final clock = _clockFor(id);
    final opening = !_expandedBooks.contains(id);
    if (_reduced || _query.trim().isNotEmpty) {
      _settlingMotion = true;
      setState(() {
        opening ? _expandedBooks.add(id) : _expandedBooks.remove(id);
        clock.value = opening ? 1 : 0;
      });
      _settlingMotion = false;
    } else if (opening) {
      _layoutChange(() => _expandedBooks.add(id));
      clock.forward();
    } else {
      setState(() => _expandedBooks.remove(id));
      clock.reverse();
    }
  }

  bool _keepsBookRows(int id) =>
      _expandedBooks.contains(id) ||
      _query.trim().isNotEmpty ||
      (_bookClocks[id]?.value ?? 0) > 0;

  Key _rowKey(Object row) {
    if (row is int) return ValueKey(('bookmark-book-row', row));
    final mark = row as _BookmarkMarkRow;
    return ValueKey((
      'bookmark-entry-row',
      mark.entry.novelId,
      mark.entry.bookmark.id,
    ));
  }

  @override
  void dispose() {
    widget.state.appearanceChanges.removeListener(_appearanceChanged);
    _reflow.dispose();
    _reorder.dispose();
    for (final clock in _bookClocks.values) {
      clock.dispose();
    }
    _search.dispose();
    super.dispose();
  }

  Novel? _known(int id) =>
      widget.state.localLibrary?.novelFor(id) ??
      (widget.repository is OfflineNovelRepository
          ? (widget.repository as OfflineNovelRepository).cache
                    .book(id)
                    ?.novel ??
                widget.state.cachedNovel(id)
          : widget.state.cachedNovel(id));

  Future<void> _open(int id, ReaderBookmark mark) async {
    if (_opening != null) return;
    setState(() => _opening = mark.id);
    try {
      final repository = widget.repository;
      if (isLocalBook(id) &&
          widget.state.localLibrary != null &&
          widget.state.localLibrary?.novelFor(id) == null) {
        throw const FormatException('本地原书已移除，摘录仍可查看和分享');
      }
      var novel = _known(id) ?? await repository.find(id);
      if (novel == null) throw const FormatException('暂时无法读取原书，请检查本机文件或网络');
      if (novel.chapters.isEmpty) {
        novel = novel.withChapters(await repository.chapters(novel.id));
      }
      final chapter = widget.state.chapterForPosition(novel, mark.position);
      if (chapter == null) throw const FormatException('原章节已变动，摘录仍保留');
      if (!mounted) return;
      await pushNovelPage<void>(
        context,
        // Was always ReaderPage (TXT) regardless of format.
        readerPageFor(
          novel: novel,
          state: widget.state,
          repository: repository,
          chapter: chapter,
          bookmark: mark,
        ),
        reduceMotion: widget.state.reduceMotion,
      );
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          error is FormatException ? error.message : '暂时无法打开原文，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _edit(int id, ReaderBookmark mark) => showReaderAnnotationEditor(
    context,
    state: widget.state,
    novelId: id,
    bookmark: mark,
    rangeContextResolver: (ranges, anchor) =>
        loadOfflineReaderAnnotationContext(
          state: widget.state,
          repository: widget.repository,
          novelId: id,
          ranges: ranges,
          anchor: anchor,
          novel: _known(id),
        ),
  );

  String _buildMarkdownExport() {
    final local = widget.state.localLibrary;
    final entries = libraryBookmarks(widget.state, books: local);
    if (entries.isEmpty) return '';
    final groups = <int, List<({int novelId, ReaderBookmark bookmark})>>{};
    for (final entry in entries) {
      groups.putIfAbsent(entry.novelId, () => []).add(entry);
    }
    final buffer = StringBuffer()
      ..writeln('# 书屿读书笔记与书签摘录')
      ..writeln()
      ..writeln(
        '> 导出时间：${DateTime.now().toIso8601String().replaceFirst("T", " ").split(".").first} · 共 ${entries.length} 条记录 / ${groups.length} 本书',
      )
      ..writeln();
    for (final group in groups.entries) {
      final book = _known(group.key);
      final title = book?.title ?? '书籍 ${group.key}';
      final author = book?.author ?? '';
      buffer.writeln(
        '## 《$title》${author.isEmpty ? "" : " · $author"}',
      );
      buffer.writeln();
      for (final item in group.value) {
        final mark = item.bookmark;
        final chapter = mark.chapterTitle.isEmpty
            ? '第 ${mark.position.chapter + 1} 章'
            : mark.chapterTitle;
        final meta = <String>[
          mark.kindLabel,
          if (mark.category.isNotEmpty) '分类：${mark.category}',
        ].join(' · ');
        buffer.writeln('### $chapter（$meta）');
        buffer.writeln();
        if (mark.quote.isNotEmpty) {
          for (final line in mark.quote.split('\n')) {
            buffer.writeln('> $line');
          }
          buffer.writeln();
        }
        if (mark.note.isNotEmpty) {
          buffer.writeln('- **批注**：${mark.note}');
          buffer.writeln();
        }
      }
    }
    return buffer.toString().trimRight();
  }

  Future<void> _exportMarkdown(BuildContext anchorContext) async {
    final markdown = _buildMarkdownExport();
    if (markdown.isEmpty) {
      showNovelFeedback(context, '暂无可导出的书签或摘录');
      return;
    }
    final action = await showGlassMenu<String>(
      context: anchorContext,
      reduceMotion: _reduced,
      builder: (menuContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassMenuItem(
            order: 0,
            label: '导出为 Markdown 文件 (.md)',
            onPressed: () => Navigator.of(menuContext).pop('file'),
          ),
          GlassMenuItem(
            order: 1,
            label: '复制 Markdown 到剪贴板',
            onPressed: () => Navigator.of(menuContext).pop('copy'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: markdown));
      if (mounted) showNovelFeedback(context, '已复制 Markdown 读书笔记到剪贴板');
      return;
    }
    final date = DateTime.now().toIso8601String().split('T').first;
    try {
      final saved = await LocalPlatform.exportBackup(
        markdown,
        '书屿读书笔记_$date.md',
      );
      if (mounted && saved) {
        showNovelFeedback(context, '已导出 Markdown 读书笔记');
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: markdown));
      if (mounted) {
        showNovelFeedback(context, '当前环境不支持直接保存文件，已复制到剪贴板');
      }
    }
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '书签',
    code: 'PERSONAL / EXCERPTS',
    actions: [
      GlassMenuAnchor(
        child: Builder(
          builder: (anchorContext) => GlassIconButton(
            key: const ValueKey('bookmark-export-markdown'),
            icon: CupertinoIcons.doc_text,
            label: '导出 Markdown 笔记',
            onPressed: () => _exportMarkdown(anchorContext),
          ),
        ),
      ),
      const SizedBox(width: 8),
      GlassIconButton(
        key: const ValueKey('bookmark-search-toggle'),
        icon: _searchOpen ? CupertinoIcons.xmark : CupertinoIcons.search,
        label: _searchOpen ? '收起搜索' : '搜索书签',
        onPressed: () {
          if (_searchOpen) {
            FocusScope.of(context).unfocus();
            _search.clear();
          }
          setState(() {
            _searchOpen = !_searchOpen;
            if (!_searchOpen) _query = '';
          });
        },
      ),
    ],
    child: AnimatedBuilder(
      animation: widget.state.bookmarkChanges,
      builder: (context, _) {
        final query = _query.trim().toLowerCase();
        final local = widget.state.localLibrary;
        final entries = libraryBookmarks(widget.state, books: local).where((
          entry,
        ) {
          final book = _known(entry.novelId);
          return (_category == '_all' ||
                  _category == '_book' ||
                  'category:${entry.bookmark.category}' == _category) &&
              (query.isEmpty ||
                  entry.bookmark.quote.toLowerCase().contains(query) ||
                  entry.bookmark.chapterTitle.toLowerCase().contains(query) ||
                  (book?.title.toLowerCase().contains(query) ?? false) ||
                  (book?.author.toLowerCase().contains(query) ?? false) ||
                  entry.bookmark.note.toLowerCase().contains(query));
        }).toList();
        final groups = <int, List<({int novelId, ReaderBookmark bookmark})>>{};
        for (final entry in entries) {
          groups.putIfAbsent(entry.novelId, () => []).add(entry);
        }
        final rows = <Object>[];
        if (_category == '_book') {
          for (final group in groups.entries) {
            rows.add(group.key);
            if (_keepsBookRows(group.key)) {
              rows.addAll([
                for (final (order, entry) in group.value.indexed)
                  _BookmarkMarkRow(entry, order),
              ]);
            }
          }
        } else {
          rows.addAll([
            for (final (order, entry) in entries.indexed)
              _BookmarkMarkRow(entry, order),
          ]);
        }
        final rowIndices = {
          for (final (index, row) in rows.indexed) _rowKey(row): index + 1,
        };
        final contentPadding = featurePadding(context);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: EdgeInsets.only(top: contentPadding.top),
              child: LibraryReflowScope(
                controller: _reflow,
                enabled: !_reduced,
                generation: _reflow.generation,
                active: _reflow.active,
                child: LibraryReflowClip(
                  controller: _reflow,
                  child: ListView.builder(
                    clipBehavior: _reflow.active ? Clip.none : Clip.hardEdge,
                    padding: contentPadding.copyWith(top: 0),
                    itemCount: rows.length + 1,
                    findChildIndexCallback: (key) => rowIndices[key],
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AnimatedOptionSection(
                              expanded: _searchOpen,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 18),
                                child: AppSearchField(
                                  inputKey: const ValueKey('bookmark-search'),
                                  controller: _search,
                                  autofocus: true,
                                  hint: '搜索摘录、书名或作者',
                                  onChanged: (value) =>
                                      setState(() => _query = value),
                                ),
                              ),
                            ),
                            GlassSettingMenu<String>(
                              icon: CupertinoIcons.folder,
                              label: '书签分类',
                              value: _category,
                              options: {
                                '_book': '按书分类',
                                '_all': '全部书签',
                                'category:': '未分类',
                                for (final e in widget.state.bookmarkEntries)
                                  if (e.bookmark.category.isNotEmpty)
                                    'category:${e.bookmark.category}':
                                        e.bookmark.category,
                              },
                              onChanged: (value) =>
                                  setState(() => _category = value),
                              reduceMotion: widget.state.reduceMotion,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '${entries.length} 条记录 · ${groups.length} 本书',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (entries.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 36,
                                ),
                                child: Text(
                                  query.isEmpty
                                      ? '长按正文选择喜欢的句子，点「书签」即可收藏。\n已有的位置书签也会显示在这里。'
                                      : widget.state.bookmarkEntries.any(
                                          (entry) => entry.bookmark.isUnderline,
                                        )
                                      ? '没有找到匹配的记录'
                                      : '没有找到匹配的书签',
                                  style: const TextStyle(height: 1.8),
                                ),
                              ),
                          ],
                        );
                      }
                      final row = rows[index - 1];
                      if (row is int) {
                        final book = _known(row), marks = groups[row]!;
                        final expanded =
                            _expandedBooks.contains(row) || query.isNotEmpty;
                        return KeyedSubtree(
                          key: _rowKey(row),
                          child: LibraryReflowPart(
                            id: ('bookmark-book', row),
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: ContentPanel(
                                key: ValueKey('bookmark-book-$row'),
                                onTap: () => _toggleBook(row),
                                child: ArchivePart(
                                  start: .18,
                                  end: .84,
                                  travel: const Offset(0, 6),
                                  child: Row(
                                    children: [
                                      const ArchiveIcon(
                                        CupertinoIcons.book,
                                        size: 22,
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              book?.title ?? '书籍 $row',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              '${marks.length} 条书签与标记',
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      AnimatedRotation(
                                        turns: expanded ? .25 : 0,
                                        duration: widget.state.reduceMotion
                                            ? Duration.zero
                                            : NovelMotion.contact,
                                        child: const ArchiveIcon(
                                          CupertinoIcons.chevron_right,
                                          size: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }
                      final markRow = row as _BookmarkMarkRow;
                      final entry = markRow.entry;
                      final mark = entry.bookmark;
                      final novel = _known(entry.novelId);
                      final content = Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: ContentPanel(
                          key: ValueKey('my-bookmark-${mark.id}'),
                          onTap: () => _open(entry.novelId, mark),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (mark.quote.isNotEmpty ||
                                  mark.note.isNotEmpty) ...[
                                ReaderBookmarkExcerpt(mark: mark),
                                const SizedBox(height: 20),
                              ],
                              if (mark.quote.isEmpty && mark.note.isEmpty) ...[
                                Text(
                                  mark.kindLabel,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 10),
                              ],
                              if (_category != '_book') ...[
                                Text(
                                  novel?.title ?? '书籍 ${entry.novelId}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                              ],
                              Text(
                                mark.chapterTitle,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.6,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (mark.category.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  '分类 · ${mark.category}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: GlassTextButton(
                                      key: ValueKey('bookmark-read-${mark.id}'),
                                      onPressed: _opening == null
                                          ? () => _open(entry.novelId, mark)
                                          : null,
                                      child: Text(
                                        _opening == mark.id ? '正在打开…' : '回到原文',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (mark.quote.isNotEmpty)
                                    GlassIconButton(
                                      key: ValueKey(
                                        'bookmark-share-${mark.id}',
                                      ),
                                      icon: CupertinoIcons.square_arrow_up,
                                      label: '分享摘录图片 ${mark.id}',
                                      onPressed: () async {
                                        String? serifFamily;
                                        try {
                                          serifFamily =
                                              await registeredReadingReportSerif(
                                                widget.state.fonts,
                                              );
                                        } catch (_) {
                                          // Optional installed typography never blocks sharing.
                                        }
                                        if (!context.mounted) return;
                                        await pushNovelPage<void>(
                                          context,
                                          QuoteCardPage(
                                            serifFamily: serifFamily,
                                            data: QuoteCardData(
                                              text: mark.quote,
                                              book: novel?.title ?? '',
                                              author: novel?.author ?? '',
                                              chapter: mark.chapterTitle,
                                              recordedAt:
                                                  mark.createdAt == null ||
                                                      mark.createdOffsetMinutes ==
                                                          null
                                                  ? null
                                                  : mark.createdAt!.toUtc().add(
                                                      Duration(
                                                        minutes: mark
                                                            .createdOffsetMinutes!,
                                                      ),
                                                    ),
                                            ),
                                          ),
                                          reduceMotion:
                                              widget.state.reduceMotion,
                                        );
                                      },
                                    ),
                                  GlassIconButton(
                                    icon: CupertinoIcons.folder,
                                    label:
                                        '${mark.isUnderline ? '分类划线' : '分类书签'} ${mark.id}',
                                    onPressed: () => organizeBookmark(
                                      context,
                                      widget.state,
                                      entry.novelId,
                                      mark,
                                    ),
                                  ),
                                  GlassIconButton(
                                    icon: CupertinoIcons.square_pencil,
                                    label: '查看与编辑批注 ${mark.id}',
                                    onPressed: () => _edit(entry.novelId, mark),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                      final grouped = _category == '_book' && query.isEmpty;
                      final clock = grouped
                          ? _bookClocks[entry.novelId] ??
                                const AlwaysStoppedAnimation<double>(1)
                          : const AlwaysStoppedAnimation<double>(1);
                      final interactive =
                          !grouped || _expandedBooks.contains(entry.novelId);
                      return KeyedSubtree(
                        key: _rowKey(row),
                        child: LibraryReflowPart(
                          id: ('bookmark-mark', entry.novelId, mark.id),
                          child: IgnorePointer(
                            key: ValueKey((
                              'bookmark-entry-input',
                              entry.novelId,
                              mark.id,
                            )),
                            ignoring: !interactive,
                            child: ExcludeSemantics(
                              excluding: !interactive,
                              child: LoadedContentItem(
                                key: ValueKey((
                                  'bookmark-entry-motion',
                                  entry.novelId,
                                  mark.id,
                                )),
                                animation: _reduced
                                    ? const AlwaysStoppedAnimation<double>(1)
                                    : clock,
                                index: markRow.order,
                                placeholder: null,
                                child: content,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// One borderless input inside the shared glass plate. Embedded header searches
/// keep their animated outer plate, rather than nesting a filled Material field.
class AppSearchField extends StatefulWidget {
  const AppSearchField({
    super.key,
    this.inputKey,
    this.controller,
    this.focusNode,
    required this.hint,
    this.onChanged,
    this.onSubmitted,
    this.embedded = false,
    this.showLeading = true,
    this.trailing,
    this.autofocus = false,
  });
  final Key? inputKey;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String>? onChanged, onSubmitted;
  final bool embedded, showLeading, autofocus;
  final Widget? trailing;
  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  TextEditingController? _owned;
  TextEditingController get _text =>
      widget.controller ?? (_owned ??= TextEditingController());
  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 46),
      child: Row(
        children: [
          if (widget.showLeading)
            SizedBox(
              width: 44,
              child: ArchiveIcon(
                CupertinoIcons.search,
                size: 19,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          Expanded(
            child: TextField(
              key: widget.inputKey,
              controller: _text,
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14, height: 1.25),
              onTap: () => AppHaptics.play(context, HapticCue.selection),
              onTapAlwaysCalled: true,
              onChanged: widget.onChanged,
              onSubmitted: (value) {
                AppHaptics.play(context, HapticCue.action);
                widget.onSubmitted?.call(value);
              },
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: TextStyle(
                  fontSize: 14,
                  height: 1.25,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _text,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox(width: 12)
                : SizedBox(
                    width: 40,
                    height: 46,
                    child: ArchiveIconButton(
                      tooltip: '清空搜索',
                      onPressed: () {
                        _text.clear();
                        widget.onChanged?.call('');
                      },
                      icon: const ArchiveIcon(
                        CupertinoIcons.xmark_circle_fill,
                        size: 16,
                      ),
                    ),
                  ),
          ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
    return widget.embedded
        ? child
        : LiquidGlass(radius: 24, elevated: false, child: child);
  }
}

/// Shared quote/thought hierarchy for reader and library bookmark rows.
/// The surrounding page keeps ownership of its panel, metadata and actions.
class ReaderBookmarkExcerpt extends StatelessWidget {
  const ReaderBookmarkExcerpt({
    super.key,
    required this.mark,
    this.quoteMaxLines = 5,
    this.noteMaxLines = 3,
    this.compact = false,
  });

  final ReaderBookmark mark;
  final int quoteMaxLines, noteMaxLines;
  final bool compact;

  Widget _quote(BuildContext context) {
    final theme = Theme.of(context);
    final ink = readerMarkInk(
      mark.annotation.color,
      theme.colorScheme.onSurface,
      dark: theme.brightness == Brightness.dark,
    );
    return DecoratedBox(
      key: ValueKey('bookmark-quote-${mark.id}'),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: ink.withValues(alpha: .64), width: 2),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(left: compact ? 10 : 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    compact ? '摘录' : '原文摘录',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      mark.kindLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: ink),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 4 : 8),
            Text(
              mark.quote,
              maxLines: quoteMaxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 15 : 16,
                height: compact ? 1.5 : 1.8,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thought(BuildContext context) => compact
      ? Padding(
          key: ValueKey('bookmark-note-${mark.id}'),
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '批注',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.8,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  mark.note,
                  maxLines: noteMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ),
            ],
          ),
        )
      : Padding(
          key: ValueKey('bookmark-note-${mark.id}'),
          padding: const EdgeInsets.only(left: 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '个人批注',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                mark.note,
                maxLines: noteMaxLines,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, height: 1.75),
              ),
            ],
          ),
        );

  @override
  Widget build(BuildContext context) => mark.quote.isEmpty && mark.note.isEmpty
      ? const SizedBox.shrink()
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (mark.quote.isNotEmpty) _quote(context),
            if (mark.quote.isNotEmpty && mark.note.isNotEmpty)
              SizedBox(height: compact ? 8 : 20),
            if (mark.note.isNotEmpty) _thought(context),
          ],
        );
}
