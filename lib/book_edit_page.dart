import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'book_tags.dart';
import 'library_state.dart';
import 'local_library.dart';
import 'wenku_errors.dart';

/// 在图书详情页弹出「修改书名」弹窗；书名变化时同步重命名源文件（保留扩展名与标签）。
/// 保存成功时返回更新后的 [LocalBook]，取消返回 null。
Future<LocalBook?> showLocalBookTitleEditor(
  BuildContext context, {
  required LibraryState state,
  required LocalLibraryStore local,
  required int bookId,
}) async {
  final book = local.bookFor(bookId);
  if (book == null || !context.mounted) return null;
  String? feedback;
  final updated = await showDialog<LocalBook>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _BookTitleEditDialog(
      state: state,
      local: local,
      bookId: bookId,
      onFeedback: (message) => feedback = message,
    ),
  );
  if (updated != null && context.mounted) {
    showNovelFeedback(context, feedback ?? '已保存');
  }
  return updated;
}

/// 在图书详情页弹出「修改作者」弹窗。
/// 保存成功时返回更新后的 [LocalBook]，取消返回 null。
Future<LocalBook?> showLocalBookAuthorEditor(
  BuildContext context, {
  required LibraryState state,
  required LocalLibraryStore local,
  required int bookId,
}) async {
  final book = local.bookFor(bookId);
  if (book == null || !context.mounted) return null;
  String? feedback;
  final updated = await showDialog<LocalBook>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _BookAuthorEditDialog(
      state: state,
      local: local,
      bookId: bookId,
      onFeedback: (message) => feedback = message,
    ),
  );
  if (updated != null && context.mounted) {
    showNovelFeedback(context, feedback ?? '已保存');
  }
  return updated;
}

String friendlyBookEditError(Object e) {
  final message = e.toString();
  if (message.contains('书名不能为空')) return '书名不能为空';
  if (message.contains('无法用作文件名')) return '书名无法用作文件名';
  if (message.contains('同名文件已存在')) return '同名文件已存在';
  if (message.contains('书籍不存在')) return '书籍已不存在';
  return describeSafeError(e, fallback: '保存失败，请重试');
}

class _BookTitleEditDialog extends StatefulWidget {
  const _BookTitleEditDialog({
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
  State<_BookTitleEditDialog> createState() => _BookTitleEditDialogState();
}

class _BookTitleEditDialogState extends State<_BookTitleEditDialog> {
  late final TextEditingController _titleController;
  bool _saving = false;
  String? _error;

  LocalBook? get _book => widget.local.bookFor(widget.bookId);

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: _book?.displayTitle ?? '',
    )..addListener(_onChanged);
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() => _error = null);
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final book = _book;
    if (book == null) {
      setState(() => _error = '书籍已不存在');
      return;
    }
    final cleanTitle = _titleController.text.trim();
    if (cleanTitle.isEmpty) {
      setState(() => _error = '书名不能为空');
      return;
    }
    final preview = LocalLibraryStore.previewEditedFileName(
      book,
      title: cleanTitle,
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
        author: book.displayAuthor,
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
    if (widget.state.shelf.contains(widget.bookId) ||
        widget.state.cachedNovel(widget.bookId) != null) {
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

  @override
  Widget build(BuildContext context) {
    final book = _book;
    final scheme = Theme.of(context).colorScheme;
    if (book == null) {
      return AlertDialog(
        title: const Text('修改书名'),
        content: const Text('该本地书籍记录已被移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    }

    final rawTitle = _titleController.text.trim();
    final previewFileName = LocalLibraryStore.previewEditedFileName(
      book,
      title: rawTitle,
    );

    return PopScope<LocalBook>(
      canPop: !_saving,
      child: AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('修改书名')),
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
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('book-edit-title-field'),
                  controller: _titleController,
                  enabled: !_saving,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                  decoration: InputDecoration(
                    labelText: '书名',
                    floatingLabelBehavior: FloatingLabelBehavior.never,
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
                            onPressed: _saving ? null : _titleController.clear,
                          ),
                  ),
                ),
                const SizedBox(height: 14),
                FileRenamePreviewNotice(
                  currentFileName: book.fileName,
                  previewFileName: previewFileName,
                  titleEmpty: rawTitle.isEmpty,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  _EditErrorBanner(message: _error!),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('book-edit-save-button'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存'),
          ),
        ],
      ),
    );
  }
}

class _BookAuthorEditDialog extends StatefulWidget {
  const _BookAuthorEditDialog({
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
  State<_BookAuthorEditDialog> createState() => _BookAuthorEditDialogState();
}

class _BookAuthorEditDialogState extends State<_BookAuthorEditDialog> {
  late final TextEditingController _authorController;
  bool _saving = false;
  String? _error;

  LocalBook? get _book => widget.local.bookFor(widget.bookId);

  @override
  void initState() {
    super.initState();
    _authorController = TextEditingController(
      text: _book?.displayAuthor ?? '',
    )..addListener(_onChanged);
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() => _error = null);
  }

  @override
  void dispose() {
    _authorController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final book = _book;
    if (book == null) {
      setState(() => _error = '书籍已不存在');
      return;
    }
    final cleanAuthor = _authorController.text.trim();

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });

    LocalBook updated;
    try {
      updated = await widget.local.editBookFile(
        widget.bookId,
        title: book.displayTitle,
        author: cleanAuthor,
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
    if (widget.state.shelf.contains(widget.bookId) ||
        widget.state.cachedNovel(widget.bookId) != null) {
      try {
        await widget.state.rememberNovel(widget.local.toNovel(updated));
      } catch (_) {
        feedback = '作者已更新，书架信息保存失败，请重试';
      }
    }
    if (!mounted) return;
    widget.onFeedback?.call(feedback);
    setState(() => _saving = false);
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    final scheme = Theme.of(context).colorScheme;
    if (book == null) {
      return AlertDialog(
        title: const Text('修改作者'),
        content: const Text('该本地书籍记录已被移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    }

    final previewAuthor = _authorController.text.trim();

    return PopScope<LocalBook>(
      canPop: !_saving,
      child: AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('修改作者')),
            if (book.author.isNotEmpty && previewAuthor != book.author)
              GestureDetector(
                key: const ValueKey('book-edit-reset-author'),
                onTap: _saving
                    ? null
                    : () => _authorController.text = book.author,
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
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('book-edit-author-field'),
                  controller: _authorController,
                  enabled: !_saving,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                  decoration: InputDecoration(
                    labelText: '作者',
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    hintText: '输入作者（选填，留空则显示未署名作者）',
                    isDense: true,
                    suffixIcon: _authorController.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(
                              CupertinoIcons.clear_circled_solid,
                              size: 18,
                            ),
                            tooltip: '清空作者',
                            onPressed: _saving ? null : _authorController.clear,
                          ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  _EditErrorBanner(message: _error!),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('book-edit-save-button'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存'),
          ),
        ],
      ),
    );
  }
}

class _EditErrorBanner extends StatelessWidget {
  const _EditErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('book-edit-error-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.error.withValues(alpha: .4)),
      ),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.exclamationmark_circle,
            size: 16,
            color: scheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: scheme.error,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情页展示单个已有标签的胶囊组件。
class BookTagPill extends StatelessWidget {
  const BookTagPill({
    super.key,
    required this.tag,
    this.onTap,
  });

  final Tag tag;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = tagPalette[tag.colorIndex % tagPalette.length];
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .55), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            tag.name,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return pill;
    return JellyTapSurface(
      onTap: onTap,
      haptic: HapticCue.selection,
      child: pill,
    );
  }
}

/// 详情页「添加标签 / 编辑」操作胶囊按钮。
class BookTagActionChip extends StatelessWidget {
  const BookTagActionChip({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = CupertinoIcons.tag,
  });

  final String label;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: JellyTapSurface(
        onTap: onTap,
        haptic: HapticCue.selection,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: .045),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: .55),
              width: .9,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 标签编辑面板中的可点选标签胶囊。
class SelectableTagChip extends StatelessWidget {
  const SelectableTagChip({
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

class FileRenamePreviewNotice extends StatelessWidget {
  const FileRenamePreviewNotice({
    super.key,
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
