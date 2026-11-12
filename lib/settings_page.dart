part of 'pages.dart';

class _SettingsBentoItem {
  const _SettingsBentoItem({
    this.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailingText,
    required this.onTap,
  });
  final Key? key;
  final IconData icon;
  final String title;
  final String subtitle;
  final String? trailingText;
  final VoidCallback onTap;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.state,
    this.repository,
    this.showHeader = true,
  });
  final LibraryState state;
  final NovelRepository? repository;
  final bool showHeader;

  Widget buildHeader(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: const ArchiveMasthead(title: '设置'),
  );

  @override
  Widget build(BuildContext context) {
    final localLib = LocalPlatform.android ? localLibraryOf(repository) : null;
    final offlineRepo = switch (repository) {
      final OfflineNovelRepository o => o,
      CompositeNovelRepository(:final remote)
          when remote is OfflineNovelRepository =>
        remote,
      _ => null,
    };
    final updateScope = AppUpdatesScope.maybeOf(context);
    final versionText =
        '版本 ${updateScope?.installed?.version ?? currentAppVersion}'
        ' · 构建 ${updateScope?.installed?.build ?? currentAppBuild}'
        '${updateScope?.available == true ? ' · 有新版本' : ''}';

    return AnimatedBuilder(
      animation: Listenable.merge([
        state.settingsChanges,
        ?localLib,
        ?TagStore.maybeShared,
      ]),
      builder: (context, child) {
        final localCount = localLib?.books.length ?? 0;
        final tagCount = TagStore.maybeShared?.tags.length ?? 0;
        return GlassHeaderLayout(
          showHeader: showHeader,
          header: buildHeader(context),
          body: ListView(
            key: const PageStorageKey('settings'),
            cacheExtent: 0,
            padding: EdgeInsets.fromLTRB(
              24,
              MediaQuery.paddingOf(context).top +
                  FrostedHeader.toolbarHeight +
                  8,
              24,
              MediaQuery.paddingOf(context).bottom + 120,
            ),
            children: [
              // 01 / 书库：最常用的本地书库入口放在最前。
              sectionHeader(context, '书库', '本地文件 · 标签 · 备份'),
              const SizedBox(height: 14),
              ContentPanel(
                child: _settingsToolList(context, [
                  if (localLib != null) ...[
                    _SettingsBentoItem(
                      key: const ValueKey('settings-local-library'),
                      icon: CupertinoIcons.book,
                      title: '本地书库',
                      subtitle: '选择文件夹，扫描导入 TXT / EPUB / PDF / MOBI',
                      trailingText: localCount > 0 ? '$localCount 本' : null,
                      onTap: () => pushNovelPage<void>(
                        context,
                        LocalLibraryPage(
                          state: state,
                          local: localLib,
                          repository: repository!,
                        ),
                        reduceMotion: state.reduceMotion,
                      ),
                    ),
                    _SettingsBentoItem(
                      key: const ValueKey('settings-local-duplicates'),
                      icon: CupertinoIcons.doc_on_doc,
                      title: '重复小说清理',
                      subtitle: '按内容指纹或书名排查重复文件',
                      onTap: () => pushNovelPage<void>(
                        context,
                        LocalDuplicatesPage(local: localLib, state: state),
                        reduceMotion: state.reduceMotion,
                      ),
                    ),
                    _SettingsBentoItem(
                      key: const ValueKey('settings-tag-manage'),
                      icon: CupertinoIcons.tag,
                      title: '标签管理',
                      subtitle: '新建、重命名或删除书架标签',
                      trailingText: tagCount > 0 ? '$tagCount 个' : null,
                      onTap: () => pushNovelPage<void>(
                        context,
                        TagManagePage(state: state, local: localLib),
                        reduceMotion: state.reduceMotion,
                      ),
                    ),
                  ],
                  _SettingsBentoItem(
                    key: const ValueKey('settings-backup'),
                    icon: CupertinoIcons.archivebox,
                    title: '备份与恢复',
                    subtitle: '导出或恢复书架、进度、书签与设置',
                    onTap: () => pushNovelPage<void>(
                      context,
                      LibraryBackupPage(state: state),
                      reduceMotion: state.reduceMotion,
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 24),

              // 02 / 阅读偏好：显示设置在前，进入子页的工具在后。
              sectionHeader(context, '阅读偏好', '外观 · 排版 · 工具'),
              const SizedBox(height: 14),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _appearanceSetting(context),
                    _settingsDivider(context),
                    ReaderValueSlider(
                      sliderKey: const ValueKey('settings-font-slider'),
                      label: '阅读字号',
                      value: state.fontSize,
                      min: readerFontSizeMin,
                      max: readerFontSizeMax,
                      divisions: 16,
                      format: (value) => '${value.round()} pt',
                      onCommitted: (value) => _savePreference(
                        context,
                        () => state.setFontSize(value),
                      ),
                    ),
                    if (LocalPlatform.android) ...[
                      _settingsDivider(context),
                      Row(
                        children: [
                          _settingsIconBadge(
                            context,
                            CupertinoIcons.lightbulb,
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              '阅读时保持亮屏',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          CupertinoSwitch(
                            value: state.keepScreenOn,
                            activeTrackColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            onChanged: (value) => _savePreference(
                              context,
                              () => state.setKeepScreenOn(value),
                            ),
                          ),
                        ],
                      ),
                    ],
                    _settingsDivider(context),
                    _settingsToolList(context, [
                      // Same record as the reader's 亮度 sheet (synced both ways).
                      _SettingsBentoItem(
                        key: const ValueKey('settings-reader-paper'),
                        icon: CupertinoIcons.circle_lefthalf_fill,
                        title: '纸色与夜读',
                        subtitle: '纸色、夜读亮度与暖光',
                        trailingText: state.readerPreferences.paper.label,
                        onTap: () =>
                            showReaderAppearanceSheet(context, state: state),
                      ),
                      _SettingsBentoItem(
                        key: const ValueKey('settings-palette-page'),
                        icon: CupertinoIcons.paintbrush,
                        title: '主题调节',
                        subtitle: '界面极光与纸张色系',
                        onTap: () => pushNovelPage<void>(
                          context,
                          PaletteSettingsPage(state: state),
                          reduceMotion: state.reduceMotion,
                        ),
                      ),
                      _SettingsBentoItem(
                        key: const ValueKey('settings-font-settings-page'),
                        icon: CupertinoIcons.textformat_alt,
                        title: '字体管理',
                        subtitle: '内置与导入字库',
                        onTap: () => pushNovelPage<void>(
                          context,
                          FontSettingsPage(state: state),
                          reduceMotion: state.reduceMotion,
                        ),
                      ),
                      _SettingsBentoItem(
                        key: const ValueKey('settings-purification-rules'),
                        icon: CupertinoIcons.wand_stars,
                        title: '正文替换',
                        subtitle: '正则与文本纠错',
                        onTap: () => showReaderPurificationSheet(
                          context: context,
                          reduceMotion: state.reduceMotion,
                        ),
                      ),
                      _SettingsBentoItem(
                        key: const ValueKey('settings-reading-widget-page'),
                        icon: CupertinoIcons.rectangle_on_rectangle,
                        title: '桌面阅读小组件',
                        subtitle: '配置主屏幕阅读进度卡片',
                        onTap: () => pushNovelPage<void>(
                          context,
                          ReadingWidgetSettingsPage(state: state),
                          reduceMotion: state.reduceMotion,
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // 03 / 阅读记录：历史、统计、书签与离线缓存。
              if (repository != null) ...[
                sectionHeader(context, '阅读记录', '历史 · 统计 · 缓存'),
                const SizedBox(height: 14),
                ContentPanel(
                  child: _settingsToolList(context, [
                    if (repository case final NovelRepository source) ...[
                      _SettingsBentoItem(
                        key: const ValueKey('settings-reading-history'),
                        icon: CupertinoIcons.clock,
                        title: '阅读历史',
                        subtitle: '足迹与章节续读',
                        onTap: () => openReadingHistory(context, state, source),
                      ),
                      _SettingsBentoItem(
                        key: const ValueKey('settings-reading-statistics'),
                        icon: CupertinoIcons.chart_bar,
                        title: '阅读统计',
                        subtitle: '阅读时长与日历报告',
                        onTap: () => pushNovelPage<void>(
                          context,
                          ReadingStatisticsPage(
                            state: state,
                            repository: source,
                          ),
                          reduceMotion: state.reduceMotion,
                        ),
                      ),
                      _SettingsBentoItem(
                        key: const ValueKey('settings-bookmarks'),
                        icon: CupertinoIcons.bookmark,
                        title: '书签与划线',
                        subtitle: '汇总全部书签与批注',
                        onTap: () => pushNovelPage<void>(
                          context,
                          BookmarkLibraryPage(state: state, repository: source),
                          reduceMotion: state.reduceMotion,
                        ),
                      ),
                    ],
                    if (offlineRepo case final OfflineNovelRepository offline)
                      _SettingsBentoItem(
                        key: const ValueKey('settings-offline-cache'),
                        icon: CupertinoIcons.cloud_download,
                        title: '缓存管理',
                        subtitle: '管理已下载章节与离线缓存空间',
                        onTap: () => pushNovelPage<void>(
                          context,
                          OfflineCachePage(
                            repository: offline,
                            reduceMotion: state.reduceMotion,
                            onOpen: (pageContext, novel) => openDetail(
                              pageContext,
                              novel,
                              state,
                              offline,
                              fromCache: true,
                            ),
                          ),
                          reduceMotion: state.reduceMotion,
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 24),
              ],

              AppearancePerformancePanel(state: state),
              const SizedBox(height: 24),

              // 系统与关于：版本信息与在线更新。
              sectionHeader(context, '系统与关于', '版本 · 更新'),
              const SizedBox(height: 14),
              ContentPanel(
                child: _settingsNavRow(
                  context,
                  rowKey: const ValueKey('settings-app-update'),
                  icon: CupertinoIcons.arrow_down_circle,
                  title: '关于书屿',
                  subtitle: versionText,
                  onTap: () => pushNovelPage<void>(
                    context,
                    AppUpdatePage(updates: updateScope),
                    reduceMotion: state.reduceMotion,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _settingsIconBadge(BuildContext context, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: dark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: scheme.primary.withValues(alpha: dark ? 0.28 : 0.16),
          width: 0.8,
        ),
      ),
      alignment: Alignment.center,
      child: ArchiveIcon(icon, size: 18, color: scheme.primary),
    );
  }

  Widget _settingsDivider(BuildContext context) =>
      const Divider(height: 18, indent: 46);

  Widget _settingsToolList(
    BuildContext context,
    List<_SettingsBentoItem> items,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (index, item) in items.indexed) ...[
        if (index > 0) _settingsDivider(context),
        _settingsNavRow(
          context,
          rowKey: item.key,
          icon: item.icon,
          title: item.title,
          subtitle: item.subtitle,
          trailingText: item.trailingText,
          onTap: item.onTap,
        ),
      ],
    ],
  );

  Widget _settingsNavRow(
    BuildContext context, {
    Key? rowKey,
    required IconData icon,
    required String title,
    String? subtitle,
    String? trailingText,
    required VoidCallback onTap,
  }) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return JellyTapSurface(
      key: rowKey,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            _settingsIconBadge(context, icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ],
              ),
            ),
            if (trailingText != null) ...[
              const SizedBox(width: 8),
              Text(trailingText, style: TextStyle(fontSize: 13, color: muted)),
            ],
            const SizedBox(width: 8),
            ArchiveIcon(CupertinoIcons.chevron_forward, size: 14, color: muted),
          ],
        ),
      ),
    );
  }

  Widget _appearanceSetting(BuildContext context) {
    final label = Row(
      children: [
        _settingsIconBadge(context, CupertinoIcons.moon_stars),
        const SizedBox(width: 12),
        const Expanded(
          child: Text('外观模式', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
    final selector = GlassMenuAnchor(
      child: Builder(
        builder: (anchorContext) => LiquidGlass(
          radius: 20,
          elevated: false,
          semanticLabel: '选择外观模式',
          onTap: () => _chooseTheme(anchorContext),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(switch (state.theme) {
                ThemeMode.system => '跟随系统',
                ThemeMode.light => '浅色',
                ThemeMode.dark => '深色',
              }),
              const SizedBox(width: 7),
              const ArchiveIcon(CupertinoIcons.chevron_down, size: 14),
            ],
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (constraints.maxWidth < 160 * scale + 70) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label,
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerRight, child: selector),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: label),
            const SizedBox(width: 12),
            selector,
          ],
        );
      },
    );
  }

  Future<void> _chooseTheme(BuildContext context) async {
    final selected = await showGlassMenu<ThemeMode>(
      context: context,
      reduceMotion:
          state.reduceMotion || MediaQuery.disableAnimationsOf(context),
      builder: (menuContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (mode, label) in [
            (ThemeMode.system, '跟随系统'),
            (ThemeMode.light, '浅色'),
            (ThemeMode.dark, '深色'),
          ])
            GlassMenuItem(
              order: mode.index,
              selected: state.theme == mode,
              onPressed: () => Navigator.of(menuContext).pop(mode),
              label: label,
            ),
        ],
      ),
    );
    if (selected != null && context.mounted) {
      await _savePreference(context, () => state.setTheme(selected));
    }
  }

  Future<void> _savePreference(
    BuildContext context,
    Future<void> Function() save,
  ) async {
    try {
      await save();
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '设置保存失败，请重试');
    }
  }
}

class InlineSearchResults extends StatelessWidget {
  const InlineSearchResults({
    super.key,
    required this.state,
    required this.repository,
    required this.feed,
    required this.onOpenBook,
    this.onRecall,
  });
  final LibraryState state;
  final NovelRepository repository;
  final NovelFeedController feed;
  final VoidCallback onOpenBook;
  final ValueChanged<String>? onRecall;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: feed,
    builder: (context, _) => LoadedContentSequence(
      generation: feed.resultRevision,
      firstIndex: feed.resultStartIndex == 0 ? 0 : feed.resultStartIndex + 1,
      child: _buildResults(context),
    ),
  );

  Widget _buildResults(BuildContext context) {
    final books = feed.items;
    if (books.isEmpty &&
        feed.query.isEmpty &&
        onRecall != null &&
        state.recentSearches.isNotEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(
          24,
          MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight + 20,
          24,
          24,
        ),
        children: [
          RecentSearches(state: state, onRecall: onRecall!),
          if (feed.loading)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Column(children: [BookRowSkeleton(), BookRowSkeleton()]),
            )
          else if (feed.error != null)
            Column(
              children: [
                const Text('推荐载入失败，仍可搜索书名或作者'),
                GlassTextButton(onPressed: feed.retry, child: const Text('重试')),
              ],
            )
          else
            const Text('搜索书名或作者，开始寻找故事。'),
        ],
      );
    }
    if (books.isEmpty && feed.loading) {
      return const SearchSkeleton();
    }
    if (books.isEmpty && feed.error != null) {
      return ContentNotice(
        icon: CupertinoIcons.wifi_exclamationmark,
        title: '搜索失败，请稍后重试',
        onRetry: feed.retry,
      );
    }
    if (books.isEmpty) {
      return const ContentNotice(
        icon: CupertinoIcons.search,
        title: '没有找到相关故事',
        message: '试试更短的书名或作者名',
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            !feed.loading &&
            feed.hasMore &&
            feed.error == null &&
            notification.metrics.extentAfter < 400) {
          WidgetsBinding.instance.addPostFrameCallback((_) => feed.loadMore());
        }
        return false;
      },
      child: FeedRefresh(
        feed: feed,
        child: ListView.builder(
          key: PageStorageKey('inline-search-results-${feed.query}'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            22,
            MediaQuery.paddingOf(context).top +
                FrostedHeader.toolbarHeight +
                20,
            22,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          itemCount: books.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              return LoadedContentItem(
                index: 0,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (feed.query.isEmpty && onRecall != null)
                        RecentSearches(state: state, onRecall: onRecall!),
                      Text(
                        feed.query.isEmpty
                            ? '你可能会喜欢'
                            : '找到 ${feed.totalItems ?? books.length} 个结果',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            if (index == books.length + 1) return FeedFooter(feed: feed);
            final book = books[index - 1];
            return LoadedContentItem(
              key: ValueKey(book.id),
              index: index,
              child: NovelRow(
                novel: book,
                coverHeroTag: CoverHeroTag(context, book.id),
                onTap: () {
                  onOpenBook();
                  openDetail(
                    context,
                    book,
                    state,
                    repository,
                    coverHeroTag: CoverHeroTag(context, book.id),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
