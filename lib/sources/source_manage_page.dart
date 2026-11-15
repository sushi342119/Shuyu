import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_interactions.dart';
import '../app_ui.dart';
import '../catalog.dart';
import '../feature_pages.dart';
import '../library_state.dart';
import 'book_source.dart';
import 'book_source_store.dart';
import 'online_book_origins.dart';
import 'source_repository.dart';

enum _SourceFilterTab {
  all('全部'),
  novel('小说'),
  manga('漫画'),
  compatible('可用'),
  unsupported('需脚本');

  const _SourceFilterTab(this.label);
  final String label;
}

class BookSourceManagePage extends StatefulWidget {
  const BookSourceManagePage({
    super.key,
    required this.state,
    this.repository,
    this.store,
  });

  final LibraryState state;
  final NovelRepository? repository;
  final BookSourceStore? store;

  @override
  State<BookSourceManagePage> createState() => _BookSourceManagePageState();
}

class _BookSourceManagePageState extends State<BookSourceManagePage> {
  BookSourceStore get _store => widget.store ?? BookSourceStore.shared;

  _SourceFilterTab _filterTab = _SourceFilterTab.all;
  final TextEditingController _queryController = TextEditingController();
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    _queryController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _queryController.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  SourceNovelRepository _resolveSourceRepo() =>
      sourceRepositoryOf(widget.repository) ??
      SourceNovelRepository(sourceStore: _store);

  List<BookSource> _filteredSources() {
    final q = _queryController.text.trim().toLowerCase();
    return _store.sources.where((src) {
      final tabMatch = switch (_filterTab) {
        _SourceFilterTab.all => true,
        _SourceFilterTab.novel => src.contentType == SourceContentType.text,
        _SourceFilterTab.manga => src.contentType == SourceContentType.manga,
        _SourceFilterTab.compatible => src.compatibility.canEnable,
        _SourceFilterTab.unsupported => !src.compatibility.canEnable,
      };
      if (!tabMatch) return false;
      if (q.isEmpty) return true;
      return src.name.toLowerCase().contains(q) ||
          src.baseUrl.toLowerCase().contains(q) ||
          src.group.toLowerCase().contains(q);
    }).toList(growable: false);
  }

  Future<void> _importByUrlDialog() async {
    if (_importing) return;
    final ctrl = TextEditingController();
    final url = await showDialogWithControllers<String>(
      context: context,
      controllers: [ctrl],
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('网址导入书源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '支持直链 JSON、酷安/知乎跳转链接，以及 legado:// 订阅链接：',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('source-import-url-input'),
                controller: ctrl,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: 'https://...json',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: '粘贴剪贴板',
                    icon: const Icon(CupertinoIcons.doc_on_clipboard, size: 18),
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        ctrl.text = data!.text!.trim();
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('source-import-url-confirm'),
              onPressed: () => Navigator.pop(dialogContext, ctrl.text.trim()),
              child: const Text('导入'),
            ),
          ],
        );
      },
    );
    if (url == null || url.isEmpty || !mounted) return;
    await _runImport(() => _store.importFromUrl(url));
  }

  Future<void> _importByJsonDialog() async {
    if (_importing) return;
    final ctrl = TextEditingController();
    final raw = await showDialogWithControllers<String>(
      context: context,
      controllers: [ctrl],
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('粘贴 JSON 导入'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '支持单条或数组形式的阅读 3.0（Legado）小说与漫画书源 JSON：',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('source-import-json-input'),
                  controller: ctrl,
                  maxLines: 8,
                  minLines: 4,
                  decoration: const InputDecoration(
                    hintText: '[{"bookSourceName": "...", "bookSourceUrl": "..."}]',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        ctrl.text = data!.text!;
                      }
                    },
                    icon: const Icon(CupertinoIcons.doc_on_clipboard, size: 16),
                    label: const Text('从剪贴板粘贴'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('source-import-json-confirm'),
              onPressed: () => Navigator.pop(dialogContext, ctrl.text.trim()),
              child: const Text('解析并导入'),
            ),
          ],
        );
      },
    );
    if (raw == null || raw.isEmpty || !mounted) return;
    if (raw.startsWith('http://') ||
        raw.startsWith('https://') ||
        raw.startsWith('legado://') ||
        raw.startsWith('yuedu://')) {
      await _runImport(() => _store.importFromUrl(raw));
    } else {
      await _runImport(() => _store.importFromJsonText(raw));
    }
  }

  Future<void> _importFromClipboardQuick() async {
    if (_importing) return;
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) showNovelFeedback(context, '剪贴板为空');
      return;
    }
    if (text.startsWith('[') || text.startsWith('{')) {
      await _runImport(() => _store.importFromJsonText(text));
    } else {
      await _runImport(() => _store.importFromUrl(text));
    }
  }

  Future<void> _runImport(Future<SourceImportSummary> Function() task) async {
    setState(() => _importing = true);
    try {
      final summary = await task();
      if (!mounted) return;
      showNovelFeedback(context, summary.describe());
    } catch (error) {
      if (!mounted) return;
      final message = switch (error) {
        final FormatException e => e.message,
        _ => '导入失败：$error',
      };
      showNovelFeedback(context, message);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _exportSources() async {
    if (_store.sources.isEmpty) {
      showNovelFeedback(context, '当前暂无可导出的书源');
      return;
    }
    final jsonText = _store.exportSanitizedJson();
    await Clipboard.setData(ClipboardData(text: jsonText));
    if (mounted) {
      showNovelFeedback(
        context,
        '已复制 ${_store.sources.length} 条书源 JSON 到剪贴板（已自动剥离私有 Cookie）',
      );
    }
  }

  Future<void> _editSourceHeaders(BookSource source) async {
    final secrets = _store.secretHeadersFor(source.id);
    final currentUa =
        source.headers['User-Agent'] ?? source.headers['user-agent'] ?? '';
    final currentReferer =
        source.headers['Referer'] ?? source.headers['referer'] ?? '';
    final currentCookie = secrets['Cookie'] ?? secrets['cookie'] ?? '';
    final cookieCtrl = TextEditingController(text: currentCookie);
    final uaCtrl = TextEditingController(text: currentUa);
    final refererCtrl = TextEditingController(text: currentReferer);

    final saved = await showDialogWithControllers<
      ({String ua, String referer, String cookie})
    >(
      context: context,
      controllers: [cookieCtrl, uaCtrl, refererCtrl],
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('请求头配置 · ${source.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Cookie 仅保存在本机独立加密隔离存储中，导出书源或普通备份时不会外泄。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: cookieCtrl,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    labelText: 'Cookie（可选）',
                    hintText: 'session=...; cf_clearance=...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: uaCtrl,
                  decoration: const InputDecoration(
                    labelText: 'User-Agent（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: refererCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Referer（防盗链可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                (
                  cookie: cookieCtrl.text,
                  ua: uaCtrl.text,
                  referer: refererCtrl.text,
                ),
              ),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (saved == null || !mounted) return;
    await _store.updateCustomHeaders(
      source.id,
      cookie: saved.cookie,
      userAgent: saved.ua,
      referer: saved.referer,
    );
    if (mounted) showNovelFeedback(context, '已更新「${source.name}」请求头');
  }

  Future<void> _openDebugSheet(BookSource source) async {
    await showJellySheet<void>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      builder: (sheetContext) => _SourceDebugSheet(
        source: source,
        repository: _resolveSourceRepo(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filtered = _filteredSources();
    final unsupportedCount = _store.sources
        .where((s) => !s.compatibility.canEnable)
        .length;

    return ArchiveFeaturePage(
      title: '在线书源',
      actions: [
        GlassIconButton(
          key: const ValueKey('source-export-button'),
          icon: CupertinoIcons.share,
          label: '导出书源',
          onPressed: _store.sources.isEmpty ? null : _exportSources,
        ),
      ],
      child: ListView(
        key: const ValueKey('source-manage-list'),
        padding: EdgeInsets.fromLTRB(
          20,
          MediaQuery.paddingOf(context).top +
              FrostedHeader.toolbarHeight +
              12,
          20,
          MediaQuery.paddingOf(context).bottom + 40,
        ),
        children: [
          ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '启用在线书源阅读',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            '开启且至少启用 1 条书源后，发现页可一键切换「本地馆藏 / 在线书源」',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    CupertinoSwitch(
                      key: const ValueKey('source-master-switch'),
                      value: _store.onlineSourcesEnabled,
                      activeTrackColor: scheme.primary,
                      onChanged: (v) => _store.setOnlineSourcesEnabled(v),
                    ),
                  ],
                ),
                const Divider(height: 22),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('source-import-url-btn'),
                      onPressed: _importing ? null : _importByUrlDialog,
                      icon: _importing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(CupertinoIcons.link, size: 16),
                      label: const Text('网址导入'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('source-import-json-btn'),
                      onPressed: _importing ? null : _importByJsonDialog,
                      icon: const Icon(CupertinoIcons.chevron_left_slash_chevron_right, size: 16),
                      label: const Text('粘贴 JSON'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('source-import-clipboard-btn'),
                      onPressed: _importing ? null : _importFromClipboardQuick,
                      icon: const Icon(CupertinoIcons.doc_on_clipboard, size: 16),
                      label: const Text('剪贴板导入'),
                    ),
                  ],
                ),
                if (_store.sources.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '共 ${_store.totalCount} 条 · 已启用 ${_store.enabledCount} 条',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () =>
                                _store.setAllCompatibleEnabled(true),
                            child: const Text('全选可用'),
                          ),
                          TextButton(
                            onPressed: () =>
                                _store.setAllCompatibleEnabled(false),
                            child: const Text('全部停用'),
                          ),
                          if (unsupportedCount > 0)
                            TextButton(
                              onPressed: () async {
                                final n = await _store
                                    .removeUnsupportedSources();
                                if (context.mounted) {
                                  showNovelFeedback(
                                    context,
                                    '已清理 $n 条暂不支持的脚本书源',
                                  );
                                }
                              },
                              child: Text('清理不兼容($unsupportedCount)'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (_store.sources.isNotEmpty) ...[
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final tab in _SourceFilterTab.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(tab.label),
                        selected: _filterTab == tab,
                        onSelected: (_) => setState(() => _filterTab = tab),
                      ),
                    ),
                ],
              ),
            ),
            if (_store.sources.length > 5) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _queryController,
                decoration: InputDecoration(
                  hintText: '筛选书源名称、域名或分组…',
                  prefixIcon: const Icon(CupertinoIcons.search, size: 18),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  suffixIcon: _queryController.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(
                            CupertinoIcons.xmark_circle_fill,
                            size: 16,
                          ),
                          onPressed: _queryController.clear,
                        ),
                ),
              ),
            ],
            const SizedBox(height: 12),
          ],
          if (_store.sources.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 32),
              child: ContentNotice(
                icon: CupertinoIcons.globe,
                title: '尚未导入在线书源',
                message:
                    '书屿默认保持纯净本地阅读，不内置任何第三方站点。\n你可以通过「网址导入」或「粘贴 JSON」导入阅读 3.0 格式的小说与漫画书源。',
              ),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: Text(
                  '当前筛选条件下没有匹配的书源',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          else
            for (final source in filtered) ...[
              _buildSourceCard(context, source),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  Widget _buildSourceCard(BuildContext context, BookSource source) {
    final scheme = Theme.of(context).colorScheme;
    final canEnable = source.compatibility.canEnable;
    final compatColor = switch (source.compatibility) {
      SourceCompatibility.full => const Color(0xFF2E7D32),
      SourceCompatibility.partial => const Color(0xFFB26A00),
      SourceCompatibility.requiresJs ||
      SourceCompatibility.unsupportedType => scheme.error,
    };

    return ContentPanel(
      key: ValueKey('book-source-card-${source.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          source.name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        _tagPill(
                          source.contentType.label,
                          source.isManga
                              ? scheme.tertiary
                              : scheme.primary,
                        ),
                        _tagPill(source.compatibility.label, compatColor),
                        if (source.isHttpCleartext)
                          _tagPill('HTTP 明文', scheme.outline),
                        if (source.group.isNotEmpty)
                          _tagPill(source.group, scheme.secondary),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      source.baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              CupertinoSwitch(
                value: source.enabled && canEnable,
                activeTrackColor: scheme.primary,
                onChanged: canEnable
                    ? (val) => _store.setSourceEnabled(source.id, val)
                    : null,
              ),
            ],
          ),
          if (source.compatibilityNotes.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              source.compatibilityNotes.join('；'),
              style: TextStyle(
                fontSize: 11.5,
                color: canEnable ? scheme.onSurfaceVariant : scheme.error,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                key: ValueKey('source-test-btn-${source.id}'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _openDebugSheet(source),
                icon: const Icon(CupertinoIcons.play_circle, size: 16),
                label: const Text('测试诊断'),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _editSourceHeaders(source),
                icon: const Icon(CupertinoIcons.lock_shield, size: 16),
                label: Text(
                  _store.secretHeadersFor(source.id).isNotEmpty
                      ? 'Cookie (已配)'
                      : 'Cookie / 请求头',
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.error,
                ),
                onPressed: () => _store.removeSource(source.id),
                icon: const Icon(CupertinoIcons.trash, size: 16),
                label: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tagPill(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.45), width: 0.8),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    ),
  );
}

class _SourceDebugSheet extends StatefulWidget {
  const _SourceDebugSheet({
    required this.source,
    required this.repository,
  });

  final BookSource source;
  final SourceNovelRepository repository;

  @override
  State<_SourceDebugSheet> createState() => _SourceDebugSheetState();
}

class _SourceDebugSheetState extends State<_SourceDebugSheet> {
  final TextEditingController _keywordCtrl = TextEditingController(text: '我的');
  bool _running = false;
  List<SourceDebugStep>? _steps;

  @override
  void initState() {
    super.initState();
    unawaited(_runTest());
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    super.dispose();
  }

  Future<void> _runTest() async {
    if (_running) return;
    setState(() {
      _running = true;
      _steps = null;
    });
    try {
      final result = await widget.repository.debugSourcePipeline(
        widget.source,
        keyword: _keywordCtrl.text.trim().isEmpty
            ? '我的'
            : _keywordCtrl.text.trim(),
      );
      if (mounted) {
        setState(() {
          _steps = result;
          _running = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _steps = [
            SourceDebugStep(
              stage: '执行异常',
              success: false,
              elapsedMs: 0,
              summary: '$error',
            ),
          ];
          _running = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '书源测试 · ${widget.source.name}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '逐步验证「搜索/分类 → 详情 → 目录 → 正文/漫画页」规则链路',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _keywordCtrl,
                  decoration: const InputDecoration(
                    labelText: '测试搜索词',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runTest(),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _running ? null : _runTest,
                child: Text(_running ? '测试中…' : '重新测试'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_running)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_steps != null)
            for (final step in _steps!)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (step.success ? Colors.green : scheme.error)
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: (step.success ? Colors.green : scheme.error)
                        .withValues(alpha: 0.35),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          step.success
                              ? CupertinoIcons.check_mark_circled_solid
                              : CupertinoIcons.xmark_circle_fill,
                          size: 17,
                          color: step.success ? Colors.green : scheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            step.stage,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                        Text(
                          '${step.elapsedMs} ms',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(step.summary, style: const TextStyle(fontSize: 13)),
                    if (step.detail.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        step.detail,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
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
}

/// Opens a bottom sheet that searches alternative enabled book sources for
/// [bookId] and switches its origin while preserving reading progress.
Future<({Novel novel, List<NovelChapter> chapters, int alignedIndex})?>
showSwitchBookSourceSheet({
  required BuildContext context,
  required int bookId,
  required LibraryState state,
  required NovelRepository repository,
  String? currentChapterTitle,
  int currentChapterIndex = 0,
}) {
  final sourceRepo = sourceRepositoryOf(repository);
  if (sourceRepo == null) return Future.value(null);
  return showJellySheet<
    ({Novel novel, List<NovelChapter> chapters, int alignedIndex})
  >(
    context: context,
    reduceMotion: state.reduceMotion,
    builder: (sheetContext) => _SwitchSourceSheet(
      bookId: bookId,
      sourceRepo: sourceRepo,
      currentChapterTitle: currentChapterTitle,
      currentChapterIndex: currentChapterIndex,
    ),
  );
}

class _SwitchSourceSheet extends StatefulWidget {
  const _SwitchSourceSheet({
    required this.bookId,
    required this.sourceRepo,
    this.currentChapterTitle,
    this.currentChapterIndex = 0,
  });

  final int bookId;
  final SourceNovelRepository sourceRepo;
  final String? currentChapterTitle;
  final int currentChapterIndex;

  @override
  State<_SwitchSourceSheet> createState() => _SwitchSourceSheetState();
}

class _SwitchSourceSheetState extends State<_SwitchSourceSheet> {
  bool _searching = true;
  bool _switching = false;
  List<SourceSwitchCandidate> _candidates = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCandidates());
  }

  Future<void> _loadCandidates() async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final found = await widget.sourceRepo.findAlternativeSources(
        widget.bookId,
      );
      if (mounted) {
        setState(() {
          _candidates = found;
          _searching = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _searching = false;
        });
      }
    }
  }

  Future<void> _pick(SourceSwitchCandidate candidate) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      final switched = await widget.sourceRepo.switchSourceForBook(
        widget.bookId,
        candidate,
        previousChapterTitle: widget.currentChapterTitle,
        previousChapterIndex: widget.currentChapterIndex,
      );
      if (mounted) {
        Navigator.pop(context, switched);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _switching = false);
        showNovelFeedback(context, '换源失败：$error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final origin = OnlineBookOriginStore.shared.byBookId(widget.bookId);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '切换书源${origin == null ? "" : " · 《${origin.title}》"}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          if (origin != null) ...[
            const SizedBox(height: 4),
            Text(
              '当前来源：${origin.sourceName}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 14),
          if (_searching || _switching)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 10),
                  Text(
                    _switching ? '正在同步目标书源目录并对齐章节…' : '正在检索其他可用书源…',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(
                '检索失败：$_error',
                style: TextStyle(color: scheme.error),
              ),
            )
          else if (_candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                '未在其他已启用的同类型书源中检索到同名作品。可在「设置 → 在线书源」中导入更多书源后再试。',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _candidates.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final c = _candidates[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      c.source.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      [
                        if (c.item.author.isNotEmpty) c.item.author,
                        if (c.item.latestChapter.isNotEmpty)
                          '最新：${c.item.latestChapter}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: const Icon(
                      CupertinoIcons.arrow_right_circle,
                      size: 18,
                    ),
                    onTap: () => _pick(c),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
