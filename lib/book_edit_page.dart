import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_tags.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_library.dart';
import 'wenku_errors.dart';

/// 打开独立的本地书籍信息编辑页（书架页与详情页共用）。
/// 保存成功时返回更新后的 [LocalBook]，取消返回 null。
Future<LocalBook?> openLocalBookEditPage(
  BuildContext context, {
  required LibraryState state,
  required LocalLibraryStore local,
  required int bookId,
}) async {
  final book = local.bookFor(bookId);
  if (book == null || !context.mounted) return null;
  String? feedback;
  final updated = await pushNovelPage<LocalBook>(
    context,
    LocalBookEditPage(
      state: state,
      local: local,
      bookId: bookId,
      onFeedback: (message) => feedback = message,
    ),
    reduceMotion: state.reduceMotion,
  );
  if (updated != null && context.mounted) {
    showNovelFeedback(context, feedback ?? '已保存');
  }
  return updated;
}

class LocalBookEditPage extends StatefulWidget {
  const LocalBookEditPage({
    super.key,
    required this.state,
    required this.local,
    required this.bookId,
    this.onFeedback,
  });

  final LibraryState state;
  final LocalLibraryStore local;
  final int bookId;
  final ValueChanged<String>? onFeedback;

  @override
  State<LocalBookEditPage> createState() => _LocalBookEditPageState();
}

class _LocalBookEditPageState extends State<LocalBookEditPage> {
  final _tagStore = TagStore.shared;
  late final TextEditingController _titleController;
  late final TextEditingController _authorController;
  final _newTagController = TextEditingController();
  late final Set<String> _selectedTagIds;
  bool _saving = false;
  bool _creatingTag = false;
  String? _error;
  String? _tagError;

  LocalBook? get _book => widget.local.bookFor(widget.bookId);

  @override
  void initState() {
    super.initState();
    final book = _book;
    _titleController = TextEditingController(text: book?.displayTitle ?? '');
    _authorController = TextEditingController(text: book?.displayAuthor ?? '');
    _selectedTagIds = _tagStore
        .tagsForBook(widget.bookId)
        .map((t) => t.id)
        .toSet();
    _titleController.addListener(_onFieldChanged);
    _authorController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    if (!mounted) return;
    setState(() => _error = null);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _authorController.dispose();
    _newTagController.dispose();
    super.dispose();
  }

  List<Tag> _selectedTags(LocalBook book) => [
    for (final tag in _tagStore.tags)
      if (_selectedTagIds.contains(tag.id)) tag,
  ];

  List<String> _selectedTagNames(LocalBook book) => [
    for (final tag in _selectedTags(book)) tag.name,
  ];

  Future<void> _createTag() async {
    final raw = _newTagController.text;
    if (_saving || _creatingTag || raw.isEmpty) return;
    setState(() {
      _creatingTag = true;
      _tagError = null;
    });
    try {
      final id = await _tagStore.createTag(raw);
      if (!mounted) return;
      _newTagController.clear();
      setState(() => _selectedTagIds.add(id));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _tagError = describeSafeError(error, fallback: '新建标签失败');
      });
    } finally {
      if (mounted) setState(() => _creatingTag = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final book = _book;
    if (book == null) {
      setState(() => _error = '书籍已不存在');
      return;
    }
    final cleanTitle = _titleController.text.trim();
    final cleanAuthor = _authorController.text.trim();
    if (cleanTitle.isEmpty) {
      setState(() => _error = '书名不能为空');
      return;
    }
    final preview = LocalLibraryStore.previewEditedFileName(
      book,
      title: cleanTitle,
      tagNames: _selectedTagNames(book),
    );
    if (preview == null) {
      setState(() => _error = '书名无法用作文件名');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });

    LocalBook updated;
    try {
      updated = await widget.local.editBookFile(
        widget.bookId,
        title: cleanTitle,
        author: cleanAuthor,
        tagIds: _selectedTagIds,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = friendlyBookEditError(error);
      });
      return;
    }

    var feedback = '已保存';
    if (widget.state.shelf.contains(widget.bookId)) {
      try {
        await widget.state.rememberNovel(widget.local.toNovel(updated));
      } catch (_) {
        feedback = '文件已改名，书架信息保存失败，请重试';
      }
    }
    if (!mounted) return;
    widget.onFeedback?.call(feedback);
    setState(() => _saving = false);
    Navigator.of(context).pop(updated);
  }

  static String friendlyBookEditError(Object e) {
    final message = e.toString();
    if (message.contains('书名不能为空')) return '书名不能为空';
    if (message.contains('无法用作文件名')) return '书名无法用作文件名';
    if (message.contains('同名文件已存在')) return '同名文件已存在';
    if (message.contains('书籍不存在')) return '书籍已不存在';
    return describeSafeError(e, fallback: '保存失败，请重试');
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    final code = ArchiveDesign.fileCode(widget.bookId);
    if (book == null) {
      return ArchiveFeaturePage(
        title: '编辑书籍信息',
        code: code,
        child: const ContentNotice(
          icon: CupertinoIcons.exclamationmark_circle,
          title: '书籍已不存在',
          message: '该本地书籍记录已被移除，请返回上一页。',
        ),
      );
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rawTitle = _titleController.text.trim();
    final previewTitle = rawTitle.isEmpty ? book.title : rawTitle;
    final previewAuthor = _authorController.text.trim();
    final baseNovel = widget.local.toNovel(book);
    final previewNovel = Novel(
      id: baseNovel.id,
      title: previewTitle,
      author: previewAuthor,
      genre: baseNovel.genre,
      summary: baseNovel.summary,
      colors: baseNovel.colors,
      isComplete: baseNovel.isComplete,
      chapterCount: baseNovel.chapterCount,
      coverUrl: baseNovel.coverUrl,
    );

    return PopScope<LocalBook>(
      canPop: !_saving,
      child: ArchiveFeaturePage(
        title: '编辑书籍信息',
        code: code,
        canPop: !_saving,
        actions: [
          GlassIconButton(
            key: const ValueKey('book-edit-header-save'),
            icon: CupertinoIcons.checkmark,
            label: '保存',
            onPressed: _saving ? null : _save,
          ),
        ],
        child: ListenableBuilder(
          listenable: _tagStore,
          builder: (context, _) {
            // Keep selected tag IDs pruned to existing definitions.
            final validTagIds = {for (final t in _tagStore.tags) t.id};
            _selectedTagIds.retainAll(validTagIds);
            final selectedTags = _selectedTags(book);
            final previewFileName = LocalLibraryStore.previewEditedFileName(
              book,
              title: rawTitle,
              tagNames: [for (final t in selectedTags) t.name],
            );

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 700),
                child: SingleChildScrollView(
                  key: const ValueKey('book-edit-scroll'),
                  padding: featurePadding(context),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _BookPreviewCard(
                      book: book,
                      previewNovel: previewNovel,
                      previewTitle: previewTitle,
                      previewAuthor: previewAuthor,
                      selectedTags: selectedTags,
                    ),
                    const SizedBox(height: 28),
                    ArchiveSection(
                      title: '基本信息',
                      code: code,
                      subtitle: '修改书名将同步重命名源文件（保留原扩展名与标签）',
                    ),
                    const SizedBox(height: 14),
                    ContentPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Text(
                                '书名',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              if (rawTitle != book.title)
                                GestureDetector(
                                  key: const ValueKey('book-edit-reset-title'),
                                  onTap: _saving
                                      ? null
                                      : () => _titleController.text = book.title,
                                  child: Text(
                                    '恢复原解析书名',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: scheme.primary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const ValueKey('book-edit-title-field'),
                            controller: _titleController,
                            enabled: !_saving,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              labelText: '书名',
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.never,
                              hintText: '输入书名（必填）',
                              isDense: true,
                              suffixIcon: _titleController.text.isEmpty
                                  ? null
                                  : IconButton(
                                      icon: const Icon(
                                        CupertinoIcons.clear_circled_solid,
                                        size: 18,
                                      ),
                                      tooltip: '清空书名',
                                      onPressed: _saving
                                          ? null
                                          : _titleController.clear,
                                    ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              const Text(
                                '作者',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              if (book.author.isNotEmpty &&
                                  previewAuthor != book.author)
                                GestureDetector(
                                  key: const ValueKey('book-edit-reset-author'),
                                  onTap: _saving
                                      ? null
                                      : () =>
                                            _authorController.text = book.author,
                                  child: Text(
                                    '恢复原解析作者',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: scheme.primary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const ValueKey('book-edit-author-field'),
                            controller: _authorController,
                            enabled: !_saving,
                            textInputAction: TextInputAction.done,
                            decoration: InputDecoration(
                              labelText: '作者',
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.never,
                              hintText: '输入作者（选填，留空则不显示）',
                              isDense: true,
                              suffixIcon: _authorController.text.isEmpty
                                  ? null
                                  : IconButton(
                                      icon: const Icon(
                                        CupertinoIcons.clear_circled_solid,
                                        size: 18,
                                      ),
                                      tooltip: '清空作者',
                                      onPressed: _saving
                                          ? null
                                          : _authorController.clear,
                                    ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _FileRenamePreviewNotice(
                            currentFileName: book.fileName,
                            previewFileName: previewFileName,
                            titleEmpty: rawTitle.isEmpty,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Expanded(
                          child: ArchiveSection(
                            title: '书籍标签',
                            subtitle: '点选标签或直接新建，保存时一次性同步至文件名',
                          ),
                        ),
                        if (_selectedTagIds.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 12, bottom: 2),
                            child: GestureDetector(
                              key: const ValueKey('book-edit-clear-tags'),
                              onTap: _saving
                                  ? null
                                  : () => setState(_selectedTagIds.clear),
                              child: Text(
                                '清空已选 (${_selectedTagIds.length})',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ContentPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_tagStore.tags.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                '还没有标签，在下方新建一个吧',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 10,
                              children: [
                                for (final tag in _tagStore.tags)
                                  _SelectableTagChip(
                                    key: ValueKey('book-edit-tag-${tag.name}'),
                                    tag: tag,
                                    selected: _selectedTagIds.contains(tag.id),
                                    enabled: !_saving,
                                    onTap: () => setState(() {
                                      if (_selectedTagIds.contains(tag.id)) {
                                        _selectedTagIds.remove(tag.id);
                                      } else {
                                        _selectedTagIds.add(tag.id);
                                      }
                                    }),
                                  ),
                              ],
                            ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const ValueKey(
                                    'book-edit-new-tag-field',
                                  ),
                                  controller: _newTagController,
                                  enabled: !_saving && !_creatingTag,
                                  textInputAction: TextInputAction.done,
                                  onChanged: (_) {
                                    if (_tagError != null) {
                                      setState(() => _tagError = null);
                                    }
                                  },
                                  onSubmitted: (_) => _createTag(),
                                  decoration: const InputDecoration(
                                    hintText: '新建标签（不能含空格或 ✦）',
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              GlassTextButton(
                                key: const ValueKey('book-edit-add-tag-button'),
                                compact: true,
                                onPressed: _saving || _creatingTag
                                    ? null
                                    : _createTag,
                                child: Text(_creatingTag ? '添加中…' : '新建并勾选'),
                              ),
                            ],
                          ),
                          if (_tagError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                _tagError!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        key: const ValueKey('book-edit-error-banner'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.error.withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(
                            ArchiveDesign.panelRadius,
                          ),
                          border: Border.all(
                            color: scheme.error.withValues(alpha: .4),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              CupertinoIcons.exclamationmark_circle,
                              size: 18,
                              color: scheme.error,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.error,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Center(
                      child: GlassPillButton(
                        key: const ValueKey('book-edit-save-button'),
                        icon: CupertinoIcons.checkmark,
                        label: _saving ? '正在保存…' : '保存',
                        onPressed: _saving ? null : _save,
                      ),
                    ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BookPreviewCard extends StatelessWidget {
  const _BookPreviewCard({
    required this.book,
    required this.previewNovel,
    required this.previewTitle,
    required this.previewAuthor,
    required this.selectedTags,
  });

  final LocalBook book;
  final Novel previewNovel;
  final String previewTitle;
  final String previewAuthor;
  final List<Tag> selectedTags;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kindLabel = switch (book.kind) {
      LocalBookKind.pdf => 'PDF',
      LocalBookKind.epub => 'EPUB',
      LocalBookKind.txt => 'TXT',
    };
    final countLabel = book.kind == LocalBookKind.pdf
        ? '${book.pageCount} 页'
        : '${book.chapters.length} 章';
    final wordCountLabel =
        book.kind == LocalBookKind.txt && book.wordCount != null
        ? formatLocalWordCount(book.wordCount!)
        : null;
    final sizeLabel = formatLocalSize(book.size);

    return ContentPanel(
      key: const ValueKey('book-edit-preview-card'),
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NovelCover(previewNovel, width: 92, height: 130),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ArchiveCode(
                      ArchiveDesign.fileCode(book.id),
                      inverse: true,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '实时封面预览',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  previewTitle,
                  key: const ValueKey('book-edit-preview-title'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  previewAuthor.isEmpty ? '未署名作者' : previewAuthor,
                  key: const ValueKey('book-edit-preview-author'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: previewAuthor.isEmpty
                        ? scheme.onSurfaceVariant.withValues(alpha: .65)
                        : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _MetaBadge(label: kindLabel, highlight: true),
                    _MetaBadge(label: countLabel),
                    if (wordCountLabel != null)
                      _MetaBadge(label: wordCountLabel),
                    _MetaBadge(label: sizeLabel),
                  ],
                ),
                if (selectedTags.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in selectedTags)
                        _PreviewTagPill(tag: tag),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaBadge extends StatelessWidget {
  const _MetaBadge({required this.label, this.highlight = false});
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: highlight
            ? scheme.primary.withValues(alpha: .12)
            : scheme.onSurface.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
          color: highlight ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _PreviewTagPill extends StatelessWidget {
  const _PreviewTagPill({required this.tag});
  final Tag tag;

  @override
  Widget build(BuildContext context) {
    final color = tagPalette[tag.colorIndex % tagPalette.length];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .45), width: .8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            tag.name,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _SelectableTagChip extends StatelessWidget {
  const _SelectableTagChip({
    super.key,
    required this.tag,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final Tag tag;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = tagPalette[tag.colorIndex % tagPalette.length];
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: tag.name,
      child: JellyTapSurface(
        onTap: enabled ? onTap : null,
        haptic: HapticCue.selection,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: .18)
                : scheme.onSurface.withValues(alpha: .045),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: .7)
                  : scheme.outlineVariant.withValues(alpha: .55),
              width: selected ? 1.2 : .8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                tag.name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 6),
                Icon(
                  CupertinoIcons.checkmark_alt,
                  size: 14,
                  color: scheme.onSurface,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FileRenamePreviewNotice extends StatelessWidget {
  const _FileRenamePreviewNotice({
    required this.currentFileName,
    required this.previewFileName,
    required this.titleEmpty,
  });

  final String currentFileName;
  final String? previewFileName;
  final bool titleEmpty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (titleEmpty || previewFileName == null) {
      return Container(
        key: const ValueKey('book-edit-filename-invalid'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.error.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.error.withValues(alpha: .35)),
        ),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 16,
              color: scheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                titleEmpty ? '书名不能为空' : '当前书名无法用作合法文件名',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          ],
        ),
      );
    }

    final willRename = previewFileName != currentFileName;
    if (!willRename) {
      return Container(
        key: const ValueKey('book-edit-filename-unchanged'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: .04),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              CupertinoIcons.doc_text,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '源文件：$currentFileName',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '修改书名或标签会同步重命名源文件（保留原扩展名）。',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      key: const ValueKey('book-edit-rename-preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.primary.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.arrow_right_arrow_left_circle,
                size: 16,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '保存后将重命名源文件',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '改名前：$currentFileName',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(
            '改名后：$previewFileName',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
