import 'package:flutter/cupertino.dart';
import 'cloud_library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_sync.dart';
import 'cloud_sources.dart';
import 'library_backup.dart';
import 'library_state.dart';
import 'local_platform.dart';
import 'webdav_sync.dart';

class LibraryBackupPage extends StatefulWidget {
  const LibraryBackupPage({super.key, required this.state});
  final LibraryState state;
  @override
  State<LibraryBackupPage> createState() => _LibraryBackupPageState();
}

class _LibraryBackupPageState extends State<LibraryBackupPage> {
  String? _busy;
  String? _error;
  LibraryBackup? _preview;
  LibraryBackupOptions _exportOptions = LibraryBackupOptions.all;
  bool _preferences = false;
  bool _importPurification = true;
  bool _importReadingStats = true;
  bool _clipboardPreview = false;
  late final CloudSourceSettings _cloudSources = CloudSourceSettings()..load();
  late final BookSync _bookSync = BookSync(
    state: widget.state,
    preferences: widget.state.preferences,
    cloudSources: _cloudSources,
  )..load();

  @override
  void dispose() {
    _bookSync.dispose();
    _cloudSources.dispose();
    super.dispose();
  }

  Future<void> _openCloudSync() => showJellySheet<void>(
    context: context,
    reduceMotion: widget.state.reduceMotion,
    builder: (_) => CloudBookSyncPanel(sync: _bookSync),
  );

  Future<void> _openWebDav() => showWebDavBackupSheet(
    context: context,
    reduceMotion: widget.state.reduceMotion,
    preferences: widget.state.preferences,
    initialOptions: _exportOptions,
    onOptionsChanged: (options) {
      if (mounted) setState(() => _exportOptions = options);
    },
    createBackupJson: () async {
      final backup = await widget.state.createBackup(options: _exportOptions);
      return backup.encode();
    },
    createScopedBackupJson: (options) async {
      if (mounted) setState(() => _exportOptions = options);
      final backup = await widget.state.createBackup(options: options);
      return backup.encode();
    },
    onRestoreBackupJson: (jsonText) => _run('正在解析云端备份…', () async {
      final backup = await LibraryBackup.parse(jsonText);
      if (mounted) {
        setState(() {
          _preview = backup;
          _preferences = false;
          _importPurification = backup.hasPurification;
          _importReadingStats = backup.hasReadingStats;
          _clipboardPreview = false;
        });
      }
    }),
  );

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() {
      _busy = label;
      _error = null;
    });
    // Present the progress state before serializing/merging an explicit backup.
    await WidgetsBinding.instance.endOfFrame;
    try {
      await action();
    } on LibraryBackupUnavailable catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FormatException {
      if (mounted) setState(() => _error = '备份格式无效、内容不受支持或超过大小限制');
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请检查文件或本地存储后重试');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _export({bool clipboard = false, bool beforeRestore = false}) =>
      _run('正在生成备份…', () async {
        final backup = beforeRestore
            ? null
            : await widget.state.createBackup(options: _exportOptions);
        final text = beforeRestore
            ? widget.state.preRestoreBackup
            : await backup!.encode();
        final omitted = backup?.omittedCoverKeys.length ?? 0;
        final coverNotice = omitted == 0 ? '' : '；已省略 $omitted 个不支持的封面，阅读记录已保留';
        if (text == null) throw const FormatException('尚无恢复前备份');
        if (clipboard) {
          if (text.length > 256 * 1024) {
            throw const FormatException('备份较大，请使用文件导出');
          }
          if (LocalPlatform.android) {
            await LocalPlatform.setSensitiveClipboard(text);
          } else {
            await Clipboard.setData(ClipboardData(text: text));
          }
          if (mounted) showNovelFeedback(context, '备份已复制$coverNotice');
        } else {
          final date = DateTime.now().toIso8601String().substring(0, 10);
          final saved = await LocalPlatform.exportBackup(
            text,
            'wenku8-backup-${beforeRestore ? 'before-restore-' : ''}$date.json',
          );
          if (mounted && saved) showNovelFeedback(context, '备份文件已保存$coverNotice');
        }
      });

  Future<void> _import({bool clipboard = false}) => _run('正在读取备份…', () async {
    final text = clipboard
        ? (await Clipboard.getData(Clipboard.kTextPlain))?.text
        : await LocalPlatform.importBackup();
    if (text == null) {
      if (clipboard) throw const FormatException('剪贴板中没有备份文本');
      return; // System picker cancellation is not an error.
    }
    final backup = await LibraryBackup.parse(text);
    if (mounted) {
      setState(() {
        _preview = backup;
        _preferences = false;
        _importPurification = backup.hasPurification;
        _importReadingStats = backup.hasReadingStats;
        _clipboardPreview = clipboard;
      });
    }
  });

  Future<void> _restore() => _run('正在合并本地记录…', () async {
    final backup = _preview;
    if (backup == null) return;
    await widget.state.restoreBackup(
      backup,
      importPreferences: _preferences && backup.hasPreferences,
      importPurification: _importPurification && backup.hasPurification,
      importReadingStats: _importReadingStats && backup.hasReadingStats,
    );
    if (mounted) {
      final fromClipboard = _clipboardPreview;
      setState(() {
        _preview = null;
        _clipboardPreview = false;
      });
      showNovelFeedback(
        context,
        fromClipboard
            ? '备份已合并，较新的阅读进度已保留；如不再使用，请清空剪贴板'
            : '备份已合并，较新的阅读进度已保留',
      );
    }
  });

  Widget _scopeToggle({
    required Key switchKey,
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(title)),
        CupertinoSwitch(
          key: switchKey,
          value: value,
          activeTrackColor: Theme.of(context).colorScheme.primary,
          onChanged: onChanged,
        ),
      ],
    ),
  );

  String _optionalPackSummary(LibraryBackup backup) {
    final items = <String>[
      if (backup.hasPreferences) '外观与阅读偏好',
      if (backup.hasPurification) '正文净化与段落纠错',
      if (backup.hasReadingStats) '阅读统计与时刻',
    ];
    return items.isEmpty ? '仅包含核心书架、进度、书签与标签' : '包含附加项：${items.join(' · ')}';
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _busy == null,
    child: Scaffold(
      body: Atmosphere(
        child: GlassHeaderLayout(
          header: Row(
            children: [
              GlassIconButton(
                icon: CupertinoIcons.back,
                label: '返回设置',
                onPressed: _busy == null ? () => Navigator.pop(context) : null,
              ),
              const Expanded(
                child: ArchiveRouteTitle(
                  title: '备份与恢复',
                  code: 'SYSTEM / DATA TRANSFER',
                ),
              ),
              const SizedBox(width: 44),
            ],
          ),
          body: LoadedContentSequence(
            generation: _preview,
            child: ListView(
              key: const ValueKey('backup-scroll'),
              padding: EdgeInsets.fromLTRB(
                24,
                MediaQuery.paddingOf(context).top +
                    FrostedHeader.toolbarHeight +
                    20,
                24,
                MediaQuery.paddingOf(context).bottom + 32,
              ),
              children: [
                if (widget.state.shelfLoadFailed) ...[
                  const Text('书架读取失败，备份与恢复已暂停。修复会保留可读书目，并将原始记录存入本机隔离记录。'),
                  GlassTextButton(
                    key: const ValueKey('backup-repair-shelf'),
                    onPressed: _busy == null
                        ? () => _run('正在修复书架…', widget.state.repairShelf)
                        : null,
                    child: const Text('修复书架（保留可读条目）'),
                  ),
                ],
                const Text(
                  '带走你的阅读记录',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text(
                  '备份书架、阅读进度、书签与标签，并可按需选择打包外观偏好、正文净化规则与阅读统计。离线正文与账号信息不包含在备份中。',
                ),
                if (!LocalPlatform.android)
                  const Text('此平台仅支持剪贴板导入和导出，单次导出上限为 256 Ki 字符。恢复前请先导出当前记录。'),
                const SizedBox(height: 24),
                ContentPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '打包附加内容',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '书架、阅读进度、书签划线与标签始终包含。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _scopeToggle(
                        switchKey: const ValueKey('backup-option-preferences'),
                        title: '包含外观与阅读偏好',
                        value: _exportOptions.includePreferences,
                        onChanged: _busy == null
                            ? (v) => setState(
                                () => _exportOptions = _exportOptions.copyWith(
                                  includePreferences: v,
                                ),
                              )
                            : null,
                      ),
                      _scopeToggle(
                        switchKey: const ValueKey('backup-option-purification'),
                        title: '包含正文净化与纠错规则',
                        value: _exportOptions.includePurification,
                        onChanged: _busy == null
                            ? (v) => setState(
                                () => _exportOptions = _exportOptions.copyWith(
                                  includePurification: v,
                                ),
                              )
                            : null,
                      ),
                      _scopeToggle(
                        switchKey: const ValueKey('backup-option-stats'),
                        title: '包含阅读统计与时刻',
                        value: _exportOptions.includeReadingStats,
                        onChanged: _busy == null
                            ? (v) => setState(
                                () => _exportOptions = _exportOptions.copyWith(
                                  includeReadingStats: v,
                                ),
                              )
                            : null,
                      ),
                      const Divider(height: 24),
                      if (widget.state.preRestoreBackup != null)
                        GlassTextButton(
                          onPressed: _busy == null
                              ? () => _export(
                                  beforeRestore: true,
                                  clipboard: !LocalPlatform.android,
                                )
                              : null,
                          child: Text(
                            LocalPlatform.android ? '导出恢复前备份' : '复制恢复前备份',
                          ),
                        ),
                      if (LocalPlatform.android) ...[
                        GlassTextButton(
                          key: const ValueKey('backup-export-file'),
                          onPressed: _busy == null ? _export : null,
                          child: const Text('导出备份文件'),
                        ),
                        GlassTextButton(
                          key: const ValueKey('backup-import-file'),
                          onPressed: _busy == null ? _import : null,
                          child: const Text('选择备份文件'),
                        ),
                        const Divider(height: 24),
                      ],
                      GlassTextButton(
                        key: const ValueKey('backup-copy'),
                        onPressed: _busy == null
                            ? () => _export(clipboard: true)
                            : null,
                        child: const Text('复制备份文本'),
                      ),
                      const Text(
                        '复制备份会把书架、阅读历史和最近搜索放入系统剪贴板；内容可能被其他应用读取，使用后请清空。',
                      ),
                      GlassTextButton(
                        key: const ValueKey('backup-paste'),
                        onPressed: _busy == null
                            ? () => _import(clipboard: true)
                            : null,
                        child: const Text('从剪贴板读取备份'),
                      ),
                    ],
                  ),
                ),
                if (_busy != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Row(
                      children: [
                        Expanded(child: Text(_busy!)),
                        const SizedBox(width: 12),
                        const SizedBox(
                          width: 120,
                          height: 64,
                          child: LoadingSkeleton(
                            layout: SkeletonLayout.actions,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        key: const ValueKey('backup-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                if (_preview case final backup?) ...[
                  const SizedBox(height: 24),
                  LoadedContentItem(
                    index: 0,
                    child: sectionHeader(context, '恢复预览', ''),
                  ),
                  const SizedBox(height: 14),
                  LoadedContentItem(
                    index: 1,
                    child: ContentPanel(
                      key: const ValueKey('backup-preview'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('备份时间 ${_date(backup.createdAt)}'),
                          const SizedBox(height: 12),
                          Text(
                            '${backup.shelfCount} 本书架收藏 · ${backup.positionCount} 条阅读进度\n${backup.bookmarkCount} 个书签 · ${backup.historyCount} 本阅读记录 · ${backup.tagCount} 本书有标签',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _optionalPackSummary(backup),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text('恢复将合并到本机，不清空已有书架和书签；同一本书保留更新时间较新的进度。'),
                          const Divider(height: 24),
                          if (backup.hasPreferences)
                            _scopeToggle(
                              switchKey: const ValueKey(
                                'backup-import-preferences',
                              ),
                              title: '同时恢复外观与阅读偏好',
                              value: _preferences,
                              onChanged: _busy == null
                                  ? (value) =>
                                        setState(() => _preferences = value)
                                  : null,
                            ),
                          if (backup.hasPurification)
                            _scopeToggle(
                              switchKey: const ValueKey(
                                'backup-import-purification',
                              ),
                              title: '合并正文净化与纠错规则',
                              value: _importPurification,
                              onChanged: _busy == null
                                  ? (value) => setState(
                                      () => _importPurification = value,
                                    )
                                  : null,
                            ),
                          if (backup.hasReadingStats)
                            _scopeToggle(
                              switchKey: const ValueKey('backup-import-stats'),
                              title: '合并阅读统计与时刻',
                              value: _importReadingStats,
                              onChanged: _busy == null
                                  ? (value) => setState(
                                      () => _importReadingStats = value,
                                    )
                                  : null,
                            ),
                          const SizedBox(height: 12),
                          GlassTextButton(
                            key: const ValueKey('backup-confirm'),
                            onPressed: _busy == null ? _restore : null,
                            child: const Text('确认合并恢复'),
                          ),
                          GlassTextButton(
                            onPressed: _busy == null
                                ? () => setState(() => _preview = null)
                                : null,
                            child: const Text('取消恢复'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                ContentPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GlassTextButton(
                        key: const ValueKey('backup-webdav-entry'),
                        onPressed: _busy == null ? _openWebDav : null,
                        child: const Text('WebDAV 云端备份与恢复（坚果云 / Nextcloud）'),
                      ),
                      GlassTextButton(
                        key: const ValueKey('backup-cloud-sync'),
                        onPressed: _busy == null ? _openCloudSync : null,
                        child: const Text('云端书库同步（S3 / 系统文档）'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  String _date(int timestamp) {
    try {
      return DateTime.fromMillisecondsSinceEpoch(
        timestamp,
      ).toLocal().toString().substring(0, 16);
    } catch (_) {
      return '未记录';
    }
  }
}

class CloudBookSyncPanel extends StatelessWidget {
  const CloudBookSyncPanel({super.key, required this.sync});
  final BookSync sync;
  Future<void> _configure(
    BuildContext context,
    Future<void> Function() save,
  ) async {
    try {
      await save();
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '同步设置保存失败，请重试');
    }
  }

  Future<void> _configureS3(BuildContext context) async {
    final settings = sync.cloudSources;
    if (settings == null || sync.busy) return;
    await pushNovelPage<CloudSourceConfig>(
      context,
      CloudConnectionPage(
        settings: settings,
        kind: CloudSourceKind.s3,
        syncConnection: true,
      ),
      reduceMotion: sync.state.reduceMotion,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: sync,
    builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: ArchiveSection(title: '云端同步', code: 'LIBRARY / SYNC'),
              ),
              GlassIconButton(
                icon: CupertinoIcons.xmark,
                label: '关闭同步设置',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Text('连接位置', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final provider in ['S3', 'OneDrive', 'Google Drive', '其他位置'])
                Semantics(
                  selected: sync.preferredProvider == provider,
                  child: GlassTextButton(
                    key: ValueKey('sync-provider-$provider'),
                    compact: true,
                    selected: sync.preferredProvider == provider,
                    onPressed: sync.busy
                        ? null
                        : () => _configure(
                            context,
                            () => sync.configure(provider: provider),
                          ),
                    child: Text(
                      provider,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          AnimatedOptionSection(
            expanded: sync.usingS3,
            child: _s3Location(context),
          ),
          AnimatedOptionSection(
            expanded: !sync.usingS3,
            child: _documentLocation(),
          ),
          const Divider(height: 28),
          const Text('同步内容', style: TextStyle(fontWeight: FontWeight.w600)),
          _option(
            context,
            '本地原书',
            'TXT、EPUB 与书内插图',
            sync.syncOriginals,
            'sync-originals',
            (v) => sync.configure(originals: v),
          ),
          _option(
            context,
            '阅读进度与书签',
            '按更新时间合并，不覆盖较新的进度',
            sync.syncReading,
            'sync-reading',
            (v) => sync.configure(reading: v),
          ),
          _option(
            context,
            '本地分类',
            '分类名称与书籍归属',
            sync.syncCategories,
            'sync-categories',
            (v) => sync.configure(categories: v),
          ),
          const SizedBox(height: 14),
          if (sync.lastSync case final time?)
            Text(
              '上次同步 ${DateTime.fromMillisecondsSinceEpoch(time).toLocal().toString().substring(0, 16)}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 12),
          GlassPillButton(
            key: const ValueKey('sync-now'),
            icon: CupertinoIcons.arrow_2_circlepath,
            label: sync.busy ? '正在同步' : '立即同步',
            onPressed:
                sync.busy ||
                    !sync.connected ||
                    !(sync.syncOriginals ||
                        sync.syncReading ||
                        sync.syncCategories)
                ? null
                : sync.sync,
          ),
          if (sync.connected)
            GlassTextButton(
              onPressed: sync.busy ? null : sync.disconnect,
              child: const Text('断开连接'),
            ),
          if (sync.status != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(sync.status!),
            ),
          AnimatedOptionSection(
            expanded: sync.error != null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Text(
                  sync.error ?? '',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                GlassTextButton(
                  onPressed: sync.busy ? null : () => sync.recover('next'),
                  child: const Text('从上次完整同步副本恢复到本机'),
                ),
                GlassTextButton(
                  onPressed: sync.busy ? null : () => sync.recover('before'),
                  child: const Text('从写入前的云端副本恢复到本机'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            sync.usingS3
                ? '每次手动合并后写回同一同步文件；移除本机书籍不会删除云端原书。'
                : '文件选择器未显示网盘时，请先安装并登录对应网盘应用。只有获得读写授权的同步文件可以连接；移除本机书籍不会删除云端原书。',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _s3Location(BuildContext context) {
    final connection = sync.s3Connection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (connection == null)
          const Text(
            '连接 S3 或兼容存储，在不同设备间合并原书、阅读进度与分类。',
            style: TextStyle(height: 1.65),
          )
        else
          ContentPanel(
            key: const ValueKey('sync-s3-location'),
            child: ArchivePart(
              start: .24,
              end: .88,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const ArchiveIcon(CupertinoIcons.cloud, size: 18),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          connection.config.bucket,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    connection.config.endpoint.host,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    connection.objectKey,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: GlassTextButton(
            key: const ValueKey('sync-configure-s3'),
            onPressed: sync.busy || sync.cloudSources == null
                ? null
                : () => _configureS3(context),
            child: Text(connection == null ? '配置 S3 同步' : '修改 S3 连接'),
          ),
        ),
      ],
    );
  }

  Widget _documentLocation() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        sync.connection == null
            ? '在系统文件选择器侧栏选择 ${sync.preferredProvider}。首次新建同步文件，其他设备选择同一个文件。'
            : '已连接 ${sync.providerLabel}\n${sync.connection!['name']}',
        style: const TextStyle(height: 1.65),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        children: [
          GlassTextButton(
            key: const ValueKey('sync-create-document'),
            onPressed: sync.busy ? null : () => sync.connect(create: true),
            child: const Text('新建同步文件'),
          ),
          GlassTextButton(
            key: const ValueKey('sync-select-document'),
            onPressed: sync.busy ? null : () => sync.connect(create: false),
            child: const Text('选择已有文件'),
          ),
        ],
      ),
    ],
  );

  Widget _option(
    BuildContext context,
    String title,
    String detail,
    bool value,
    String key,
    Future<void> Function(bool) changed,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: ArchivePart(
      start: .24,
      end: .88,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AppControls.toggle(
            context,
            key: ValueKey(key),
            value: value,
            onChanged: sync.busy
                ? null
                : (v) => _configure(context, () => changed(v)),
          ),
        ],
      ),
    ),
  );
}
