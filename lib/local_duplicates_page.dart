import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'book_tags.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_duplicates.dart';
import 'local_library.dart';
import 'local_platform.dart';

class LocalDuplicatesPage extends StatefulWidget {
  const LocalDuplicatesPage({
    super.key,
    required this.local,
    required this.state,
  });

  final LocalLibraryStore local;
  final LibraryState state;

  @override
  State<LocalDuplicatesPage> createState() => _LocalDuplicatesPageState();
}

class _LocalDuplicatesPageState extends State<LocalDuplicatesPage> {
  LocalDuplicateReport? _report;
  LocalDuplicateKind _kind = LocalDuplicateKind.content;
  final _selected = <int>{};
  bool _busy = false;
  String? _error;
  int _processed = 0;
  int _total = 0;

  List<LocalDuplicateGroup> get _groups => _kind == LocalDuplicateKind.content
      ? _report?.content ?? []
      : _report?.title ?? [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _report = null;
      _error = null;
      _selected.clear();
    });
    try {
      final report = await compute(findLocalDuplicates, widget.local.books);
      if (mounted) {
        setState(() {
          _report = report;
          if (report.content.isEmpty && report.title.isNotEmpty) {
            _kind = LocalDuplicateKind.title;
          } else if (report.title.isEmpty && report.content.isNotEmpty) {
            _kind = LocalDuplicateKind.content;
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '查重失败，请重试');
    }
  }

  LocalBook _recommended(List<LocalBook> books) => recommendedDuplicateKeeper(
    books,
    hasRead: widget.state.hasRead,
    lastReadAt: widget.state.lastReadAt,
    annotationCount: (id) => widget.state.bookmarksFor(id).length,
  );

  void _selectCopies() {
    setState(() {
      _selected.clear();
      for (final group in _groups) {
        final keeper = _recommended(group.books);
        _selected.addAll(
          group.books.where((b) => b.id != keeper.id).map((b) => b.id),
        );
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_busy || _selected.isEmpty) return;
    final plan = <({LocalBook book, LocalBook keeper})>[];
    for (final group in _groups) {
      final retained = group.books
          .where((b) => !_selected.contains(b.id))
          .toList();
      if (retained.isEmpty) return;
      final keeper = _recommended(retained);
      for (final book in group.books.where((b) => _selected.contains(b.id))) {
        plan.add((book: book, keeper: keeper));
      }
    }
    // Lock the page through both confirmation sheets and the entire batch.
    setState(() => _busy = true);
    try {
      final confirmed = await confirmNovelAction(
        context,
        title: '删除 ${plan.length} 本重复小说？',
        message:
            '每组至少保留一本。选中的源文件、书架记录、标签和阅读进度将被删除，无法撤销。'
            '${_kind == LocalDuplicateKind.title ? '\n当前仅按书名匹配，可能包含不同版本，请逐本核对。' : ''}'
            '\n保留副本不会自动合并其他副本的进度、书签或标签。',
        confirmLabel: '继续',
        reduceMotion: widget.state.reduceMotion,
      );
      if (!confirmed || !mounted) return;
      final finalConfirmed = await confirmNovelAction(
        context,
        title: '确认永久删除',
        message: '即将永久删除 ${plan.length} 个文件。请确认已核对勾选项及保留副本。',
        confirmLabel: '永久删除 ${plan.length} 本',
        reduceMotion: widget.state.reduceMotion,
      );
      if (!finalConfirmed || !mounted) return;
      setState(() {
        _total = plan.length;
        _processed = 0;
      });
      var deleted = 0;
      var cleanupPending = 0;
      final failures = <String>[];
      for (final entry in plan) {
        var removed = false;
        try {
          await widget.local.deleteDuplicateBookFile(
            entry.book,
            keeper: entry.keeper,
          );
          removed = true;
        } catch (error) {
          // The source and index may have committed before cache cleanup failed.
          removed =
              error is BookCleanupFailed &&
              widget.local.bookFor(entry.book.id) == null;
          if (!removed) {
            final reason = switch (error) {
              StateError() => error.message,
              LocalDeleteException() => '没有删除权限或存储拒绝删除，请重新授权文件夹后重试',
              BookCleanupFailed() => error.message,
              _ => '无法确认文件状态或删除结果，请重新扫描后重试',
            };
            failures.add(
              '${entry.book.displayTitle}（${entry.book.fileName}）：$reason',
            );
          }
        }
        if (removed) {
          deleted++;
          var cleaned = true;
          for (final step in <Future<void> Function()>[
            () => widget.state.setShelfMembership(entry.book.id, false),
            () => TagStore.shared.setTagsForBook(entry.book.id, const {}),
            () => widget.state.clearBookProgress(entry.book.id),
          ]) {
            try {
              await step();
            } catch (_) {
              cleaned = false;
            }
          }
          if (cleaned) {
            try {
              await widget.local.confirmAssociatedCleanupIds([entry.book.id]);
            } catch (_) {
              cleaned = false;
            }
          }
          if (!cleaned) cleanupPending++;
        }
        if (mounted) setState(() => _processed++);
      }
      await _refresh();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('清理结果'),
          content: SingleChildScrollView(
            child: Text(
              [
                '已删除 $deleted 本，未完成 ${failures.length} 本。',
                if (cleanupPending > 0)
                  '$cleanupPending 本的关联记录待清理，将在下次启动或扫描时重试。',
                ...failures,
              ].join('\n\n'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _total = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final withoutFingerprint = widget.local.books
        .where(
          (book) =>
              book.sourceFingerprint.isEmpty && book.textFingerprint.isEmpty,
        )
        .length;
    final selectedBytes = groups
        .expand((g) => g.books)
        .where((b) => _selected.contains(b.id))
        .fold<int>(0, (sum, b) => sum + b.size);
    return PopScope(
      canPop: !_busy,
      child: ArchiveFeaturePage(
        title: '重复小说清理',
        canPop: !_busy,
        actions: [
          GlassIconButton(
            icon: CupertinoIcons.refresh,
            label: '重新查重',
            onPressed: _busy || _report == null && _error == null
                ? null
                : _refresh,
          ),
        ],
        child: Padding(
          key: const ValueKey('duplicate-page-content'),
          padding: EdgeInsets.only(
            top:
                MediaQuery.paddingOf(context).top +
                FrostedHeader.toolbarHeight +
                12,
          ),
          child: _report == null
              ? Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : TextButton(onPressed: _refresh, child: Text(_error!)),
                )
              : Column(
                  children: [
                    Expanded(
                      child: CustomScrollView(
                        key: const ValueKey('duplicate-results-scroll'),
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                              child: ContentPanel(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        ArchiveIcon(
                                          CupertinoIcons.doc_on_doc,
                                          size: 18,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            '已检查 ${widget.local.books.length} 本小说',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Wrap(
                                      key: const ValueKey('duplicate-filters'),
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        for (final kind
                                            in LocalDuplicateKind.values)
                                          ChoiceChip(
                                            label: Text(
                                              kind == LocalDuplicateKind.content
                                                  ? '内容相同（${_report!.content.length} 组）'
                                                  : '疑似同名（${_report!.title.length} 组）',
                                            ),
                                            selected: _kind == kind,
                                            onSelected: _busy
                                                ? null
                                                : (_) => setState(() {
                                                    _kind = kind;
                                                    _selected.clear();
                                                  }),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      _kind == LocalDuplicateKind.content
                                          ? '按最近扫描的源文件或正文指纹匹配。文件有变动时，请先回本地书库扫描。'
                                          : '按书名、作者后缀和末尾编号查找疑似重复；可能包含不同版本，请逐本核对。',
                                      style: TextStyle(
                                        fontSize: 12,
                                        height: 1.45,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    if (withoutFingerprint > 0) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        '$withoutFingerprint 本缺少内容指纹，仅参与同名检测；旧 TXT / EPUB 可先重新扫描。',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 12,
                                      runSpacing: 4,
                                      children: [
                                        if (_kind == LocalDuplicateKind.content)
                                          TextButton(
                                            onPressed: _busy || groups.isEmpty
                                                ? null
                                                : _selectCopies,
                                            child: const Text('每组保留一本，选择其余副本'),
                                          ),
                                        TextButton(
                                          onPressed: _busy || _selected.isEmpty
                                              ? null
                                              : () => setState(_selected.clear),
                                          child: const Text('取消选择'),
                                        ),
                                      ],
                                    ),
                                    if (_busy && _total > 0) ...[
                                      const SizedBox(height: 8),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(3),
                                        child: LinearProgressIndicator(
                                          value: _processed / _total,
                                          minHeight: 4,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        '正在处理 $_processed / $_total，请勿关闭应用',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (groups.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: ContentPanel(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ArchiveIcon(
                                          CupertinoIcons.checkmark_circle,
                                          size: 26,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          _kind == LocalDuplicateKind.content
                                              ? '没有找到内容完全相同的小说'
                                              : '没有找到疑似同名小说',
                                          textAlign: TextAlign.center,
                                        ),
                                        if (_kind ==
                                                LocalDuplicateKind.content &&
                                            _report!.title.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          TextButton(
                                            onPressed: _busy
                                                ? null
                                                : () => setState(() {
                                                    _kind =
                                                        LocalDuplicateKind.title;
                                                    _selected.clear();
                                                  }),
                                            child: Text(
                                              '查看 ${_report!.title.length} 组疑似重复',
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              sliver: SliverList.builder(
                                itemCount: groups.length,
                                itemBuilder: (context, index) =>
                                    _groupCard(groups[index]),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _busy || _selected.isEmpty
                                ? null
                                : _deleteSelected,
                            child: Text(
                              '删除选中 ${_selected.length} 本 · 文件共 ${formatLocalSize(selectedBytes)}',
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

  Widget _groupCard(LocalDuplicateGroup group) {
    final scheme = Theme.of(context).colorScheme;
    final recommended = _recommended(group.books);
    final retained = group.books.where((b) => !_selected.contains(b.id)).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ContentPanel(
        padding: EdgeInsets.zero,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey('${_kind.name}:${group.books.first.id}'),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            title: Text(
              group.books.first.displayTitle,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${group.books.length} 本 · 保留 $retained 本',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            children: [
              Divider(height: 1, color: Theme.of(context).dividerColor),
              for (final (index, book) in group.books.indexed) ...[
                if (index > 0)
                  Divider(
                    height: 1,
                    indent: 52,
                    color: Theme.of(context).dividerColor,
                  ),
                CheckboxListTile(
                  key: ValueKey('duplicate-book-${book.id}'),
                  value: _selected.contains(book.id),
                  controlAffinity: ListTileControlAffinity.leading,
                  isThreeLine: false,
                  title: Text(
                    '${book.displayTitle}${book.id == recommended.id ? ' · 建议保留' : ''}',
                    style: TextStyle(
                      fontWeight: book.id == recommended.id
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      [
                        '${book.displayAuthor} · ${book.isMobiSource ? 'MOBI/AZW3' : book.kind.name.toUpperCase()} · ${formatLocalSize(book.size)}',
                        '${book.wordCount == null ? '字数未知' : formatLocalWordCount(book.wordCount!)} · ${book.kind == LocalBookKind.pdf ? '${book.pageCount} 页' : '${book.chapters.length} 章'}',
                        '${_readingLabel(book.id)} · 书签／批注 ${widget.state.bookmarksFor(book.id).length} 条',
                        book.fileName,
                        book.fileUri,
                        if (!_selected.contains(book.id) && retained == 1)
                          '此组最后一本，保留',
                      ].join('\n'),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  onChanged:
                      _busy || (!_selected.contains(book.id) && retained <= 1)
                      ? null
                      : (selected) => setState(() {
                          if (selected == true) {
                            _selected.add(book.id);
                          } else {
                            _selected.remove(book.id);
                          }
                        }),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _readingLabel(int id) {
    if (!widget.state.hasRead(id)) return '未读';
    final position = widget.state.positionFor(id);
    return position == null ? '有阅读进度' : '有阅读进度 · 第 ${position.chapter + 1} 章';
  }
}
