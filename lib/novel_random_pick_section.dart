import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'archive_icons.dart';
import 'archive_random_pick_card.dart';
import 'book_tags.dart';
import 'catalog.dart';
import 'library_filter.dart';
import 'library_state.dart';
import 'ui_preferences.dart';

/// 首页随机抽阅的标签筛选包装组件。
/// 管理标签筛选，以及按书籍 ID 持久化的次数和上次抽取结果。
class NovelRandomPickSection extends StatefulWidget {
  const NovelRandomPickSection({
    super.key,
    required this.books,
    required this.onOpenDetail,
    this.state,
    this.matchMode = TagMatchMode.any,
    this.pace = RandomPickPace.quick,
    this.carouselBuilder,
  });

  final List<Novel> books;
  final ValueChanged<Novel> onOpenDetail;
  final LibraryState? state;

  /// Shared with the shelf; OR stays the default like the old random pick.
  final TagMatchMode matchMode;

  /// 快速 900ms by default; 仪式 2400ms is optional.
  final RandomPickPace pace;

  /// Places the history action beside the discovery carousel's pager while
  /// keeping draw-count loading, writes and empty filters in this state.
  final Widget Function(Widget resetButton)? carouselBuilder;

  @override
  State<NovelRandomPickSection> createState() => _NovelRandomPickSectionState();
}

class _NovelRandomPickSectionState extends State<NovelRandomPickSection> {
  static const _drawCountsKey = 'random_pick_draw_counts_v1';
  static const _lastPickedKey = 'random_pick_last_id_v1';

  ColorScheme get _scheme => Theme.of(context).colorScheme;
  bool get _dark => Theme.of(context).brightness == Brightness.dark;
  Color get _muted => _scheme.onSurfaceVariant;
  Color get _border => _dark
      ? _scheme.outlineVariant
      : Color.lerp(_scheme.outlineVariant, _scheme.primary, .14)!;
  Color get _accent => _scheme.primary;

  /// Same selection as the shelf and the carousel (LibraryFilter.shared).
  Set<String> get _selectedTagIds => LibraryFilter.shared.tagIds;
  bool get _untaggedOnly => LibraryFilter.shared.untaggedOnly;
  final TagStore _tagStore = TagStore.shared;
  final Map<int, int> _drawCounts = {};
  SharedPreferences? _preferences;
  bool _countsLoaded = false;
  bool _countsWritable = true;
  bool _lastIdWritable = true;
  bool _unreadOnly = false;
  int? _lastPickedId;
  Future<void> _pendingWrite = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _tagStore.addListener(_onTagsChanged);
    LibraryFilter.shared.addListener(_onFilterChanged);
    widget.state?.addListener(_onFilterChanged);
    unawaited(_loadDrawCounts());
  }

  @override
  void didUpdateWidget(covariant NovelRandomPickSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state?.removeListener(_onFilterChanged);
      widget.state?.addListener(_onFilterChanged);
    }
  }

  @override
  void dispose() {
    _tagStore.removeListener(_onTagsChanged);
    LibraryFilter.shared.removeListener(_onFilterChanged);
    widget.state?.removeListener(_onFilterChanged);
    super.dispose();
  }

  void _onFilterChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDrawCounts() async {
    final counts = <int, int>{};
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      final last = preferences.get(_lastPickedKey);
      if (last == null || last is int) {
        _lastPickedId = last as int?;
      } else {
        // 上次 ID 损坏不影响恢复次数，也不静默覆盖原始值。
        _lastIdWritable = false;
      }
      final raw = preferences.get(_drawCountsKey);
      final decoded = raw is String ? jsonDecode(raw) : null;
      if (raw != null && decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid draw counts');
      }
      if (decoded is Map<String, dynamic>) {
        for (final entry in decoded.entries) {
          final id = int.tryParse(entry.key);
          final count = entry.value;
          if (id != null && count is int && count > 0) {
            counts[id] = count;
          } else {
            _countsWritable = false;
          }
        }
      }
    } catch (_) {
      _countsWritable = false;
    }
    if (!mounted) return;
    setState(() {
      // 当前列表可能只是分页或筛选结果，不以其缺失项判断书籍已删除。
      _drawCounts.addAll(counts);
      _countsLoaded = true;
    });
  }

  Future<bool> _persistDrawCounts() {
    if (!_countsWritable) return Future.value(false);
    // 保存快照并串行写入，防止较早的抽取覆盖后来的重置。
    final encoded = jsonEncode(
      _drawCounts.map((id, count) => MapEntry('$id', count)),
    );
    final lastPickedId = _lastPickedId;
    final write = _pendingWrite.then((_) async {
      try {
        final preferences = _preferences ??=
            await SharedPreferences.getInstance();
        if (!await preferences.setString(_drawCountsKey, encoded)) return false;
        if (!_lastIdWritable) return false;
        // 两个键按同一快照串行保存；部分失败不丢弃已保存的次数。
        return lastPickedId == null
            ? await preferences.remove(_lastPickedKey)
            : await preferences.setInt(_lastPickedKey, lastPickedId);
      } catch (_) {
        return false;
      }
    });
    _pendingWrite = write.then((_) {});
    return write;
  }

  void _recordPick(Novel book) {
    setState(() {
      _drawCounts[book.id] = (_drawCounts[book.id] ?? 0) + 1;
      _lastPickedId = book.id;
    });
    unawaited(_persistDrawCounts());
  }

  Future<void> _resetDrawCounts() async {
    setState(() {
      _drawCounts.clear();
      _lastPickedId = null;
    });
    final saved = await _persistDrawCounts();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved ? '已重置抽取记录' : '已重置抽取记录，但保存失败')),
    );
  }

  void _onTagsChanged() {
    LibraryFilter.shared.prune(_tagStore);
    if (mounted) setState(() {});
  }

  void _toggleTag(String tagId, bool selected) {
    if (_selectedTagIds.contains(tagId) != selected) {
      LibraryFilter.shared.toggleTag(tagId);
    }
  }

  void _clearFilter() {
    LibraryFilter.shared.setSingleTag(null);
    if (_unreadOnly && mounted) {
      setState(() => _unreadOnly = false);
    }
  }

  List<Novel> _filterBooks() {
    final seen = <int>{};
    final hasTagFilter = LibraryFilter.shared.hasTags;
    return widget.books
        .where((book) {
          if (!seen.add(book.id)) return false;
          if (hasTagFilter &&
              !LibraryFilter.shared.matchesTags(
                book.id,
                widget.matchMode,
                store: _tagStore,
              )) {
            return false;
          }
          if (_unreadOnly &&
              widget.state != null &&
              widget.state!.hasRead(book.id)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  String _filterSummaryLabel(int candidateCount) {
    if (_selectedTagIds.isNotEmpty && !_unreadOnly) {
      return widget.matchMode == TagMatchMode.all
          ? '符合全部所选标签 · 共 $candidateCount 本'
          : '符合任一所选标签 · 共 $candidateCount 本';
    }
    if (_untaggedOnly && !_unreadOnly) {
      return '未设标签 · 共 $candidateCount 本';
    }
    if (_unreadOnly && !LibraryFilter.shared.hasTags) {
      return '仅未读书籍 · 共 $candidateCount 本';
    }
    return '当前筛选 · 共 $candidateCount 本';
  }

  Widget _styledFilterChip({
    Key? key,
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return FilterChip(
      key: key,
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
      backgroundColor: _dark
          ? Color.lerp(_scheme.surface, _scheme.surfaceContainerHigh, .65)!
          : _scheme.surface,
      selectedColor: Color.lerp(_scheme.surface, _accent, _dark ? .24 : .12)!,
      checkmarkColor: _accent,
      surfaceTintColor: Colors.transparent,
      labelStyle: TextStyle(
        color: selected ? _accent : _muted,
        fontSize: 13,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
      side: BorderSide(
        color: selected
            ? _accent.withValues(alpha: _dark ? .50 : .34)
            : _border,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    );
  }

  Widget _buildFilterHeader(int candidateCount) {
    final tags = _tagStore.tags;
    final hasAnyFilter = LibraryFilter.shared.hasTags || _unreadOnly;
    final showChipRow =
        tags.isNotEmpty || widget.state != null || _untaggedOnly;
    final resetButton = TextButton(
      onPressed: _countsLoaded ? _resetDrawCounts : null,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        minimumSize: const Size(0, 32),
      ),
      child: const Text('重置抽取记录', style: TextStyle(fontSize: 12)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.carouselBuilder case final builder?)
          builder(resetButton)
        else
          Align(alignment: Alignment.centerRight, child: resetButton),
        if (showChipRow) ...[
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (tags.isNotEmpty) ...[
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: !hasAnyFilter,
                    onSelected: (_) => _clearFilter(),
                    backgroundColor: _dark
                        ? Color.lerp(
                            _scheme.surface,
                            _scheme.surfaceContainerHigh,
                            .65,
                          )!
                        : _scheme.surface,
                    selectedColor: Color.lerp(
                      _scheme.surface,
                      _accent,
                      _dark ? .24 : .12,
                    )!,
                    checkmarkColor: _accent,
                    surfaceTintColor: Colors.transparent,
                    labelStyle: TextStyle(
                      color: !hasAnyFilter ? _accent : _muted,
                      fontSize: 13,
                      fontWeight: !hasAnyFilter
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                    side: BorderSide(
                      color: !hasAnyFilter
                          ? _accent.withValues(alpha: _dark ? .50 : .34)
                          : _border,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (widget.state != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _styledFilterChip(
                      key: const ValueKey('random-pick-unread-only'),
                      label: '仅未读',
                      selected: _unreadOnly,
                      onSelected: (selected) =>
                          setState(() => _unreadOnly = selected),
                    ),
                  ),
                if (_untaggedOnly)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _styledFilterChip(
                      key: const ValueKey('random-pick-untagged-only'),
                      label: '未设标签',
                      selected: true,
                      onSelected: (_) => LibraryFilter.shared.toggleUntagged(),
                    ),
                  ),
                for (final tag in tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _styledFilterChip(
                      label: tag.name,
                      selected: _selectedTagIds.contains(tag.id),
                      onSelected: (selected) => _toggleTag(tag.id, selected),
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (hasAnyFilter) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _filterSummaryLabel(candidateCount),
                  style: TextStyle(fontSize: 12, color: _muted),
                ),
              ),
              TextButton(
                onPressed: _clearFilter,
                style: TextButton.styleFrom(
                  foregroundColor: _accent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                child: const Text('清除筛选', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildEmptyState() {
    final message = _unreadOnly && !LibraryFilter.shared.hasTags
        ? '没有未读的候选书籍'
        : '没有符合所选标签的书籍';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Text(message, style: TextStyle(fontSize: 15, color: _muted)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _clearFilter,
            style: TextButton.styleFrom(foregroundColor: _accent),
            child: const Text('清除筛选'),
          ),
        ],
      ),
    );
  }

  String? _formatBadgeFor(Novel book) {
    final upper = book.summary.toUpperCase();
    for (final format in const ['EPUB', 'PDF', 'MOBI', 'TXT']) {
      if (upper.contains(format)) return format;
    }
    return null;
  }

  String? _pickedMetaFor(Novel book) {
    final count = book.chapters.isNotEmpty
        ? book.chapters.length
        : book.chapterCount;
    final parts = <String>[];
    if (book.genre == '本地' || (book.id >= 0x40000000 && book.id <= 0x7fffffff)) {
      for (final raw in book.summary.split(' · ')) {
        final part = raw.trim();
        if (part.isNotEmpty && part != '本地书籍' && part.length <= 14) {
          parts.add(part);
        }
        if (parts.length >= 2) break;
      }
    }
    if (parts.isEmpty && count > 0) {
      parts.add('$count 章');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _buildPickedBookplate(Novel book) {
    final start = book.colors.isNotEmpty ? book.colors.first : _accent;
    final end = book.colors.length > 1
        ? book.colors[1]
        : Color.lerp(start, Colors.black, .28)!;
    final badge = _formatBadgeFor(book);
    return Container(
      width: 50,
      height: 70,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [start, end],
        ),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: .16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _dark ? .28 : .14),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            left: 5,
            top: 0,
            bottom: 0,
            child: Container(
              width: 1,
              color: Colors.white.withValues(alpha: .22),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ArchiveIcon(
                  CupertinoIcons.book,
                  size: 16,
                  color: Colors.white.withValues(alpha: .88),
                ),
                if (badge != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    badge,
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .6,
                      color: Colors.white.withValues(alpha: .86),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _filterBooks();
    final weights = buildRandomPickWeights(
      candidates.map((book) => book.id).toList(growable: false),
      _drawCounts,
      lastPickedId: _lastPickedId,
    );
    final hasFilter = LibraryFilter.shared.hasTags || _unreadOnly;

    Widget? emptyState;
    if (hasFilter && candidates.isEmpty) {
      emptyState = _buildEmptyState();
    } else if (widget.books.isEmpty) {
      // 书库为空时显示明确提示
      emptyState = Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text('书库暂无书籍', style: TextStyle(fontSize: 15, color: _muted)),
      );
    }

    // 等待恢复完成再接收点击，确保重启后的第一次抽取也使用历史权重。
    return AbsorbPointer(
      absorbing: !_countsLoaded,
      child: ArchiveRandomPickCard<Novel>(
        books: candidates,
        titleOf: (book) => book.title,
        authorOf: (book) => book.author,
        identityOf: (book) => book.id,
        weightOf: (book) => weights[book.id] ?? 0,
        resultLabelOf: (book) =>
            (_drawCounts[book.id] ?? 0) == 0 ? '第一次抽到' : '又遇见这本书',
        leadingOf: _buildPickedBookplate,
        metaOf: _pickedMetaFor,
        onPicked: _recordPick,
        onOpenDetail: widget.onOpenDetail,
        totalDuration: widget.pace.duration,
        filterHeader: _buildFilterHeader(candidates.length),
        emptyState: emptyState,
      ),
    );
  }
}

/// 本轮有效权重：多本候选避开上一本，并奖励从未抽中过的书籍。
/// 先减去可参与候选的最小次数，避免大次数使所有权重一起下溢。
Map<int, double> buildRandomPickWeights(
  List<int> candidateIds,
  Map<int, int> drawCounts, {
  int? lastPickedId,
}) {
  final ids = candidateIds.toSet();
  final eligible = ids.where((id) => ids.length == 1 || id != lastPickedId);
  if (ids.isEmpty) return {};
  final minimum = eligible.map((id) => drawCounts[id] ?? 0).reduce(math.min);
  return {
    for (final id in ids)
      id: ids.length > 1 && id == lastPickedId
          ? 0.0
          : math.max(
              // 等价于给首次抽取 2 倍奖励；最大权重不超过 1。
              ((drawCounts[id] ?? 0) == 0 ? 1.0 : 0.5) *
                  math.pow(0.25, (drawCounts[id] ?? 0) - minimum).toDouble(),
              double.minPositive,
            ),
  };
}
