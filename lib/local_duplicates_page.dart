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
      if (mounted) setState(() => _report = report);
    } catch (_) {
      if (mounted) setState(() => _error = '查重失败，请重试');
    }
  }

  LocalBook _recommended(List<LocalBook> books) => recommendedDuplicateKeeper(
    books,
    hasRead: widget.state.hasRead,
    lastReadAt: widget.state.lastReadAt,
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
        child: _report == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : TextButton(onPressed: _refresh, child: Text(_error!)),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final kind in LocalDuplicateKind.values)
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
                        const SizedBox(height: 8),
                        Text(
                          _kind == LocalDuplicateKind.content
                              ? '按最近扫描的源文件或正文指纹匹配。文件有变动时，请先回本地书库扫描。'
                              : '书名相近不代表内容相同，可能是不同版本或同名作品，请逐本核对。',
                        ),
                        if (withoutFingerprint > 0)
                          Text(
                            '$withoutFingerprint 本缺少内容指纹，仅参与同名检测；旧 TXT / EPUB 可先重新扫描。',
                          ),
                        Wrap(
                          spacing: 12,
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
                          LinearProgressIndicator(value: _processed / _total),
                          Text('正在处理 $_processed / $_total，请勿关闭应用'),
                        ],
                      ],
                    ),
                  ),
                  Expanded(
                    child: groups.isEmpty
                        ? Center(
                            child: Text(
                              _kind == LocalDuplicateKind.content
                                  ? '没有找到内容相同的小说'
                                  : '没有找到疑似同名小说',
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: groups.length,
                            itemBuilder: (context, index) =>
                                _groupCard(groups[index]),
                          ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
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
    );
  }

  Widget _groupCard(LocalDuplicateGroup group) {
    final recommended = _recommended(group.books);
    final retained = group.books.where((b) => !_selected.contains(b.id)).length;
    return Card(
      child: ExpansionTile(
        key: PageStorageKey('${_kind.name}:${group.books.first.id}'),
        title: Text(group.books.first.displayTitle),
        subtitle: Text('${group.books.length} 本 · 保留 $retained 本'),
        children: [
          for (final book in group.books)
            CheckboxListTile(
              key: ValueKey('duplicate-book-${book.id}'),
              value: _selected.contains(book.id),
              controlAffinity: ListTileControlAffinity.leading,
              isThreeLine: false,
              title: Text(
                '${book.displayTitle}${book.id == recommended.id ? ' · 建议保留' : ''}',
              ),
              subtitle: Text(
                [
                  '${book.displayAuthor} · ${book.isMobiSource ? 'MOBI/AZW3' : book.kind.name.toUpperCase()} · ${formatLocalSize(book.size)}',
                  '${book.wordCount == null ? '字数未知' : formatLocalWordCount(book.wordCount!)} · ${book.chapters.length} 章',
                  _readingLabel(book.id),
                  '书签／批注 ${widget.state.bookmarksFor(book.id).length} 条',
                  book.fileName,
                  book.fileUri,
                  if (!_selected.contains(book.id) && retained == 1)
                    '此组最后一本，保留',
                ].join('\n'),
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
      ),
    );
  }

  String _readingLabel(int id) {
    if (!widget.state.hasRead(id)) return '未读';
    final position = widget.state.positionFor(id);
    return position == null ? '有阅读进度' : '有阅读进度 · 第 ${position.chapter + 1} 章';
  }
}
