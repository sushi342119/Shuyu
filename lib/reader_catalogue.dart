import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'chapter_splitter.dart' show TxtTocRulePreset;
import 'library_state.dart';
import 'offline_cache.dart';
import 'regex_safety.dart';

/// A bounded, lazy chapter picker using the existing glass drawer. The current
/// chapter is the scroll origin, so locating it never lays out earlier rows.
class ReaderCatalogue extends StatefulWidget {
  const ReaderCatalogue({
    super.key,
    required this.novel,
    required this.currentChapter,
    this.cache,
    this.onConfigureTocRule,
  });
  final Novel novel;
  final int currentChapter;
  final OfflineCacheStore? cache;
  final Future<Novel?> Function(String? customPattern, int maxChapterChars)?
  onConfigureTocRule;

  @override
  State<ReaderCatalogue> createState() => _ReaderCatalogueState();
}

class _ReaderCatalogueState extends State<ReaderCatalogue> {
  final _search = TextEditingController();
  final _customRegex = TextEditingController();
  final _scroll = ScrollController();
  final _center = GlobalKey();
  late Novel _novel = widget.novel;
  late int _activeChapter = _clampChapter(
    widget.currentChapter,
    widget.novel.chapters.length,
  );
  bool _reversed = false;
  late List<int> _matches = _filter('');
  bool _configuringRule = false;
  bool _applyingRule = false;
  TxtTocRulePreset _selectedPreset = TxtTocRulePreset.auto;
  bool _subdivideOversized = false;
  String? _ruleError;
  bool _locatedFeedback = false;
  int _locatePulse = 0;

  static int _clampChapter(int chapter, int total) =>
      total <= 0 ? 0 : chapter.clamp(0, total - 1);

  List<int> _filter(String query) {
    final chapters = _novel.chapters;
    final text = query.trim().toLowerCase();
    List<int> indices;
    if (text.isEmpty) {
      indices = List.generate(chapters.length, (index) => index);
    } else {
      final number = int.tryParse(text);
      if (number != null) {
        indices = number > 0 && number <= chapters.length ? [number - 1] : [];
      } else {
        indices = [
          for (var index = 0; index < chapters.length; index++)
            if (chapters[index].title.toLowerCase().contains(text) ||
                chapters[index].volume.toLowerCase().contains(text))
              index,
        ];
      }
    }
    return _reversed ? indices.reversed.toList() : indices;
  }

  void _toggleSortOrder() {
    setState(() {
      _reversed = !_reversed;
      _matches = _filter(_search.text);
      _locatedFeedback = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _filterChanged(String query) {
    setState(() {
      _matches = _filter(query);
      _locatedFeedback = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _locateCurrent() {
    final hadSearch = _search.text.trim().isNotEmpty;
    _search.clear();
    setState(() {
      _matches = _filter('');
      _locatedFeedback = true;
      _locatePulse++;
    });
    FocusScope.of(context).unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (!hadSearch && _scroll.offset.abs() > 1.0) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scroll.jumpTo(0);
      }
    });
  }

  Future<void> _applyTocRule() async {
    final callback = widget.onConfigureTocRule;
    if (callback == null || _applyingRule) return;
    final custom = _customRegex.text.trim();
    if (custom.isNotEmpty) {
      final unsafe = detectUnsafeRegexPattern(custom);
      if (unsafe != null) {
        setState(() => _ruleError = unsafe);
        return;
      }
      try {
        RegExp(custom, multiLine: true);
      } on FormatException catch (e) {
        setState(() => _ruleError = '正则表达式语法有误：${e.message}');
        return;
      }
    }
    setState(() {
      _applyingRule = true;
      _ruleError = null;
    });
    try {
      final pattern = custom.isNotEmpty ? custom : _selectedPreset.pattern;
      final oldTotal = math.max(1, _novel.chapters.length);
      final updated = await callback(
        pattern,
        _subdivideOversized ? 12000 : 0,
      );
      if (!mounted) return;
      setState(() {
        if (updated != null) {
          final ratio = _activeChapter / oldTotal;
          _novel = updated;
          _activeChapter = _clampChapter(
            (ratio * updated.chapters.length).floor(),
            updated.chapters.length,
          );
          _matches = _filter(_search.text);
        }
        _configuringRule = false;
      });
      if (updated != null) {
        showNovelFeedback(context, '已按新规则切分为 ${updated.chapters.length} 章');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _ruleError = '重新切分目录失败，请检查规则后重试');
      }
    } finally {
      if (mounted) setState(() => _applyingRule = false);
    }
  }

  @override
  void didUpdateWidget(ReaderCatalogue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.novel.chapters, widget.novel.chapters) ||
        oldWidget.currentChapter != widget.currentChapter) {
      _novel = widget.novel;
      _activeChapter = _clampChapter(
        widget.currentChapter,
        widget.novel.chapters.length,
      );
      _matches = _filter(_search.text);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _customRegex.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available = math.max(
      0.0,
      media.size.height - media.padding.vertical - media.viewInsets.bottom - 40,
    );
    final height = math.min(media.size.height * .64, available);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Small landscape/keyboard viewports can scroll the header as well;
          // the chapter list still has its own finite lazy viewport.
          if (constraints.maxHeight < 210) {
            return SingleChildScrollView(
              child: SizedBox(height: 300, child: _contents(context)),
            );
          }
          return _contents(context);
        },
      ),
    );
  }

  Widget _contents(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: ArchiveSection(title: '目录', code: 'READER / CONTENTS'),
            ),
            if (widget.onConfigureTocRule != null)
              GlassIconButton(
                key: const ValueKey('reader-catalogue-toc-rule'),
                icon: CupertinoIcons.slider_horizontal_3,
                label: 'TXT 分章规则',
                onPressed: () => setState(() {
                  _configuringRule = !_configuringRule;
                  _ruleError = null;
                }),
              ),
            GlassIconButton(
              key: const ValueKey('reader-catalogue-sort-order'),
              icon: CupertinoIcons.arrow_up_arrow_down,
              label: _reversed ? '切换正序' : '切换倒序',
              onPressed: _novel.chapters.length <= 1 ? null : _toggleSortOrder,
            ),
            GlassIconButton(
              icon: CupertinoIcons.location,
              label: '定位当前章节',
              onPressed: _locateCurrent,
            ),
            GlassIconButton(
              icon: CupertinoIcons.xmark,
              label: '关闭目录',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        if (_configuringRule && widget.onConfigureTocRule != null) ...[
          const SizedBox(height: 8),
          ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'TXT 目录切分规则',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in TxtTocRulePreset.values)
                      ChoiceChip(
                        label: Text(
                          preset.label,
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected:
                            _customRegex.text.trim().isEmpty &&
                            _selectedPreset == preset,
                        onSelected: (_) => setState(() {
                          _selectedPreset = preset;
                          _customRegex.clear();
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                TextField(
                  key: const ValueKey('reader-catalogue-custom-regex'),
                  controller: _customRegex,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '自定义章节标题正则（选填，留空使用上方预设）',
                    isDense: true,
                  ),
                ),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '超长章节自动分节（> 1.2 万字）',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    Switch.adaptive(
                      key: const ValueKey('reader-catalogue-subdivide-long'),
                      value: _subdivideOversized,
                      onChanged: (v) => setState(() => _subdivideOversized = v),
                    ),
                  ],
                ),
                if (_ruleError != null)
                  Text(
                    _ruleError!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: GlassTextButton(
                    key: const ValueKey('reader-catalogue-apply-toc-rule'),
                    onPressed: _applyingRule ? null : _applyTocRule,
                    child: Text(_applyingRule ? '正在切分…' : '重新切分目录'),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        CupertinoSearchTextField(
          key: const ValueKey('reader-chapter-search'),
          controller: _search,
          borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
          backgroundColor: Theme.of(context).colorScheme.surface,
          placeholder: '搜索章节名或输入章序',
          onChanged: _filterChanged,
          onSubmitted: (_) => FocusScope.of(context).unfocus(),
          onSuffixTap: () {
            _search.clear();
            _filterChanged('');
          },
        ),
        const SizedBox(height: 10),
        Text(
          _search.text.trim().isEmpty
              ? _locatedFeedback
                    ? '共 ${_novel.chapters.length} 章 · 已定位到第 ${_activeChapter + 1} 章'
                    : '共 ${_novel.chapters.length} 章 · 当前第 ${_activeChapter + 1} 章${_reversed ? ' · 倒序' : ''}'
              : '找到 ${_matches.length} 章',
          style: TextStyle(
            fontSize: 12,
            fontWeight: _locatedFeedback && _search.text.trim().isEmpty
                ? FontWeight.w600
                : null,
            color: _locatedFeedback && _search.text.trim().isEmpty
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _chapters(context)),
      ],
    ),
  );

  Widget _chapters(BuildContext context) {
    if (_matches.isEmpty) {
      return const Center(child: Text('没有匹配的章节'));
    }
    final current = _reversed && !_locatedFeedback
        ? -1
        : _matches.indexOf(_activeChapter);
    final origin = current < 0 || _matches.length <= 6 ? 0 : current;
    return CustomScrollView(
      key: const ValueKey('reader-catalogue-scroll'),
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      center: _center,
      anchor: origin > 0 ? .22 : 0,
      slivers: [
        SliverList.builder(
          itemCount: origin,
          itemBuilder: (context, index) =>
              _row(context, _matches[origin - index - 1]),
        ),
        SliverList.builder(
          key: _center,
          itemCount: _matches.length - origin,
          itemBuilder: (context, index) =>
              _row(context, _matches[origin + index]),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, int index) {
    final chapter = _novel.chapters[index];
    final current = index == _activeChapter;
    final scheme = Theme.of(context).colorScheme;
    final showVolume =
        chapter.volume.isNotEmpty &&
        !chapter.title.trimLeft().startsWith(chapter.volume.trim());
    return Semantics(
      selected: current,
      child: JellyTapSurface(
        key: ValueKey('reader-chapter-$index'),
        onTap: () {
          FocusScope.of(context).unfocus();
          Navigator.pop(context, index);
        },
        child: TweenAnimationBuilder<double>(
          key: ValueKey(
            current ? 'reader-chapter-pulse-$index-$_locatePulse' : index,
          ),
          tween: Tween(
            begin: current && _locatePulse > 0 ? 1.0 : 0.0,
            end: 0.0,
          ),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
          builder: (context, pulse, child) => Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            decoration: BoxDecoration(
              color: current
                  ? Color.lerp(
                      scheme.onSurface.withValues(alpha: .06),
                      scheme.primary.withValues(alpha: .18),
                      pulse,
                    )
                  : null,
              border: current && (_locatedFeedback || pulse > 0)
                  ? Border.all(
                      color: scheme.primary.withValues(
                        alpha: .28 + pulse * .42,
                      ),
                    )
                  : null,
              borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
            ),
            child: child,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 42,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showVolume)
                      Text(
                        chapter.volume,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    Text(
                      chapter.title,
                      style: const TextStyle(fontSize: 14, height: 1.45),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (current)
                    const Text('正在阅读', style: TextStyle(fontSize: 10)),
                  if (widget.cache case final OfflineCacheStore cache)
                    AnimatedBuilder(
                      animation: cache.bookChanges(widget.novel.id),
                      builder: (context, _) =>
                          cache
                                  .book(widget.novel.id)
                                  ?.chapterBytes
                                  .containsKey(chapter.id) ==
                              true
                          ? const Text('已缓存', style: TextStyle(fontSize: 10))
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Design 2026-11 §5.4: one bottom sheet with 目录 / 书签 / 划线 tabs.
/// Pops an `int` (chapter index) from the contents tab, exactly as the
/// catalogue did, or a [ReaderBookmark] from the other two tabs.
class ReaderMarksSheet extends StatefulWidget {
  const ReaderMarksSheet({
    super.key,
    required this.state,
    required this.novel,
    required this.currentChapter,
    this.cache,
    this.onConfigureTocRule,
    this.onPickUnderline,
    this.onEditMark,
  });
  final LibraryState state;
  final Novel novel;
  final int currentChapter;
  final OfflineCacheStore? cache;
  final Future<Novel?> Function(String? customPattern, int maxChapterChars)?
  onConfigureTocRule;
  final Future<void> Function()? onPickUnderline;
  final Future<void> Function(ReaderBookmark mark)? onEditMark;

  @override
  State<ReaderMarksSheet> createState() => _ReaderMarksSheetState();
}

enum _MarksTab { contents, bookmarks, underlines }

class _ReaderMarksSheetState extends State<ReaderMarksSheet> {
  _MarksTab _tab = _MarksTab.contents;

  @override
  Widget build(BuildContext context) {
    final tabs = Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      child: CupertinoSlidingSegmentedControl<_MarksTab>(
        key: const ValueKey('reader-marks-tabs'),
        groupValue: _tab,
        children: const {
          _MarksTab.contents: Text('目录'),
          _MarksTab.bookmarks: Text('书签'),
          _MarksTab.underlines: Text('划线'),
        },
        onValueChanged: (tab) {
          if (tab != null) setState(() => _tab = tab);
        },
      ),
    );
    // Small keyboard/landscape viewports: the body shrinks to what is left
    // under the tab bar instead of overflowing the sheet.
    Widget layout(Widget body) => LayoutBuilder(
      builder: (context, constraints) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          tabs,
          if (constraints.hasBoundedHeight) Flexible(child: body) else body,
        ],
      ),
    );
    if (_tab == _MarksTab.contents) {
      return layout(
        ReaderCatalogue(
          novel: widget.novel,
          currentChapter: widget.currentChapter,
          cache: widget.cache,
          onConfigureTocRule: widget.onConfigureTocRule,
        ),
      );
    }
    final height = math.min(
      MediaQuery.sizeOf(context).height * .64,
      math.max(
        200.0,
        MediaQuery.sizeOf(context).height -
            MediaQuery.paddingOf(context).vertical -
            40,
      ),
    );
    return layout(
      SizedBox(
        height: height,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            widget.state.bookmarkChanges,
            widget.state.underlineChanges,
          ]),
          builder: (context, _) => _marks(
            context,
            underlines: _tab == _MarksTab.underlines,
          ),
        ),
      ),
    );
  }

  Widget _marks(BuildContext context, {required bool underlines}) {
    final scheme = Theme.of(context).colorScheme;
    final marks = [
      for (final mark in widget.state.bookmarksFor(widget.novel.id))
        if (mark.isUnderline == underlines) mark,
    ];
    final pickButton = underlines && widget.onPickUnderline != null
        ? GlassTextButton(
            key: const ValueKey('reader-marks-pick-underline'),
            compact: true,
            onPressed: () => widget.onPickUnderline!(),
            child: const Text('选字划线 / 复制本章片段'),
          )
        : null;
    if (marks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                underlines ? '还没有划线。长按正文选字后可划线。' : '还没有书签。在排版面板里可添加书签。',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              if (pickButton != null) ...[
                const SizedBox(height: 14),
                pickButton,
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pickButton != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            child: Align(alignment: Alignment.centerRight, child: pickButton),
          ),
        Expanded(
          child: ListView.separated(
            key: ValueKey(
              underlines ? 'reader-underline-list' : 'reader-bookmark-list',
            ),
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            itemCount: marks.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final mark = marks[index];
              final quote = mark.quote.trim();
              final note = mark.note.trim();
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                minVerticalPadding: 10,
                title: Text(
                  quote.isEmpty
                      ? mark.chapterTitle
                      : quote.characters.take(60).toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '批注：$note',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        [
                          mark.chapterTitle,
                          if (mark.createdAt case final at?) _relative(at),
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (quote.isNotEmpty)
                      IconButton(
                        key: ValueKey('reader-mark-copy-${mark.id}'),
                        tooltip: '复制',
                        visualDensity: VisualDensity.compact,
                        icon: const ArchiveIcon(CupertinoIcons.doc_on_doc, size: 17),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: quote));
                          if (context.mounted) {
                            showNovelFeedback(context, '已复制选中内容');
                          }
                        },
                      ),
                    if (widget.onEditMark != null)
                      IconButton(
                        key: ValueKey('reader-mark-edit-${mark.id}'),
                        tooltip: '批注',
                        visualDensity: VisualDensity.compact,
                        icon: const ArchiveIcon(CupertinoIcons.pencil, size: 17),
                        onPressed: () => widget.onEditMark!(mark),
                      ),
                    IconButton(
                      key: ValueKey('reader-mark-delete-${mark.id}'),
                      tooltip: '删除',
                      visualDensity: VisualDensity.compact,
                      icon: const ArchiveIcon(CupertinoIcons.trash, size: 17),
                      onPressed: () async {
                        await widget.state.removeBookmark(
                          widget.novel.id,
                          mark.id,
                        );
                        if (context.mounted) {
                          showNovelFeedback(
                            context,
                            underlines ? '已删除划线' : '已删除书签',
                          );
                        }
                      },
                    ),
                  ],
                ),
                onTap: () => Navigator.pop(context, mark),
              );
            },
          ),
        ),
      ],
    );
  }

  static String _relative(DateTime at) {
    final diff = DateTime.now().difference(at.toLocal());
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    final local = at.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}
