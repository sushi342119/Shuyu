import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'app_interactions.dart';
import 'app_typography.dart';
import 'app_ui.dart';
import 'book_documents.dart';
import 'feature_pages.dart' show confirmNovelAction;
import 'font_download.dart';
import 'library_state.dart';
import 'user_fonts.dart';

class FontSettingsPage extends StatefulWidget {
  const FontSettingsPage({
    super.key,
    required this.state,
    this.readerOnly = false,
    this.documents,
    this.bookId,
    this.onReaderTypefaceChanged,
  });
  final LibraryState state;
  final bool readerOnly;
  final BookDocuments? documents;
  final int? bookId;
  final Future<void> Function(String)? onReaderTypefaceChanged;
  @override
  State<FontSettingsPage> createState() => _FontSettingsPageState();
}

class _FontSettingsPageState extends State<FontSettingsPage> {
  late final documents = widget.documents ?? BookDocuments();
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(widget.state.loadFonts());
    unawaited(widget.state.preloadImportedFonts());
  }

  String get _readerTypeface => widget.state.readerTypefaceFor(widget.bookId);
  Future<void> _setReaderTypeface(String value) =>
      widget.onReaderTypefaceChanged?.call(value) ??
      widget.state.setReaderTypeface(value, bookId: widget.bookId);
  Future<void> _applyChoice(String value, {required bool reader}) async {
    if (downloadableFont(value) != null &&
        !widget.state.fonts.available(value)) {
      await widget.state.downloadReadingFont(value);
    }
    await (reader ? _setReaderTypeface(value) : widget.state.setAppFont(value));
  }

  Future<void> _choose({required bool reader}) async {
    final state = widget.state, fonts = widget.state.fonts;
    final selected = reader ? _readerTypeface : state.appFontChoice;
    final value = await showJellySheet<String>(
      context: context,
      reduceMotion: state.reduceMotion,
      heightFactor: .72,
      builder: (sheet) => ListView(
        cacheExtent: 0,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: [
          ArchiveSection(
            title: reader ? '阅读器字体' : 'App 字体',
            code: 'TYPE / SELECT',
          ),
          const SizedBox(height: 18),
          for (final id in [
            if (reader) followAppFont,
            AppTypeface.system.name,
            AppTypeface.sourceHanSerif.name,
            ...fonts.fonts.map((font) => font.id),
            ...downloadableFonts
                .where(
                  (font) =>
                      font.id != sourceHanFontId && fonts.available(font.id),
                )
                .map((font) => font.id),
            ...downloadableFonts
                .where(
                  (font) =>
                      font.id != sourceHanFontId && !fonts.available(font.id),
                )
                .map((font) => font.id),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _fontOption(
                id,
                reader: reader,
                selected: selected == id,
                onTap: () => Navigator.pop(sheet, id),
              ),
            ),
        ],
      ),
    );
    if (!mounted || value == null) return;
    await _perform(() => _applyChoice(value, reader: reader));
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on FontDownloadCancelled {
      // A cancelled download leaves the selected face and preferences intact.
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? e.message : '字体操作未完成，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _import() => _perform(() async {
    final selected = await documents.pickFont();
    if (selected == null) return;
    try {
      final font = await widget.state.fonts.importFile(
        selected.name,
        selected.path!,
      );
      if (mounted) {
        showNovelFeedback(context, '已导入 ${font.name}，可分别设为 App 或阅读器字体');
      }
    } finally {
      await documents.releaseBooks([selected]);
    }
  });
  Future<void> _delete(UserFont font) async {
    if (!await confirmNovelAction(
      context,
      title: '移除这款字体？',
      message: '已使用这款字体的位置会恢复默认，原始字体文件不会删除。',
      confirmLabel: '移除字体',
      reduceMotion: widget.state.reduceMotion,
    )) {
      return;
    }
    await _perform(() => widget.state.removeUserFont(font.id));
  }

  Future<void> _deleteDownloaded(DownloadableFont font) async {
    if (!await confirmNovelAction(
      context,
      title: '删除已下载的${font.name}？',
      message:
          '释放约 ${(font.bytes / 1048576).toStringAsFixed(1)} MiB 空间。使用这款字体的位置恢复默认，以后可重新下载。',
      confirmLabel: '删除字体',
      reduceMotion: widget.state.reduceMotion,
    )) {
      return;
    }
    await _perform(() => widget.state.removeUserFont(font.id));
  }

  Widget _selection({required bool reader}) {
    final state = widget.state;
    final choice = reader ? _readerTypeface : state.appFontChoice;
    return GlassTextButton(
      key: ValueKey(reader ? 'select-reader-font' : 'select-app-font'),
      onPressed: busy ? null : () => _choose(reader: reader),
      child: Row(
        children: [
          ArchiveIcon(
            reader ? CupertinoIcons.book : CupertinoIcons.textformat,
            size: 21,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reader
                      ? widget.bookId != null &&
                                state.independentReaderStyle(widget.bookId!)
                            ? '本书字体'
                            : '阅读器字体'
                      : 'App 字体',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                Text(
                  downloadableFont(choice) != null &&
                          !state.fonts.available(choice)
                      ? '${state.fontLabel(choice)} · 未下载，暂用系统字体'
                      : state.fontLabel(choice),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const ArchiveIcon(CupertinoIcons.chevron_right, size: 14),
        ],
      ),
    );
  }

  Widget _fontOption(
    String id, {
    required bool reader,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final state = widget.state;
    final download = id == sourceHanFontId ? null : downloadableFont(id);
    final family =
        (id == followAppFont ? state.appFontFamily : state.fontFamilyFor(id)) ??
        'Roboto';
    return _FontFacePreview(
      fonts: state.fonts,
      id: id == followAppFont ? state.appFontId : id,
      builder: (ready, failed) => GlassTextButton(
        key: ValueKey('${reader ? 'reader' : 'app'}-font-$id'),
        selected: selected,
        onPressed: busy ? null : onTap,
        child: Row(
          children: [
            SizedBox(
              width: 38,
              child: Text(
                'Aa',
                style: TextStyle(
                  fontFamily: ready ? family : null,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    id == followAppFont ? '跟随 App' : state.fontLabel(id),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    download != null && !state.fonts.available(id)
                        ? '下载并使用 · ${download.sizeLabel}'
                        : failed
                        ? '字体预览暂不可用'
                        : download?.previewText ?? '春日的光，落在书页上。',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: ready ? family : null,
                      fontSize: 14,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
            if (download != null && !state.fonts.available(id)) ...[
              const SizedBox(width: 10),
              const ArchiveIcon(CupertinoIcons.arrow_down_to_line, size: 16),
            ] else if (selected) ...[
              const SizedBox(width: 10),
              const ArchiveIcon(CupertinoIcons.checkmark, size: 16),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.state.settingsChanges,
      widget.state.readerSettingsChanges,
      widget.state.fonts,
    ]),
    builder: (context, _) => Scaffold(
      body: Atmosphere(
        child: GlassHeaderLayout(
          header: ArchiveHeaderBar(
            leading: GlassIconButton(
              icon: CupertinoIcons.back,
              label: '返回',
              onPressed: () => Navigator.pop(context),
            ),
            title: const ArchiveRouteTitle(
              title: '字体',
              code: 'TYPE / PERSONALIZE',
            ),
            actions: [
              GlassIconButton(
                key: const ValueKey('import-font'),
                icon: CupertinoIcons.plus,
                label: '导入字体',
                onPressed: busy ? null : _import,
              ),
            ],
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                cacheExtent: 0,
                padding: EdgeInsets.fromLTRB(
                  24,
                  MediaQuery.paddingOf(context).top +
                      FrostedHeader.toolbarHeight +
                      20,
                  24,
                  MediaQuery.paddingOf(context).bottom + 36,
                ),
                children: [
                  if (!widget.readerOnly) ...[
                    _selection(reader: false),
                    const SizedBox(height: 16),
                  ],
                  _selection(reader: true),
                  const SizedBox(height: 10),
                  Text(
                    '右上角可导入 TTF、OTF 字体，单款 32 MiB 以内。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const ArchiveSection(title: '可下载字体', code: 'TYPE / DOWNLOAD'),
                  const SizedBox(height: 14),
                  for (final font in downloadableFonts)
                    if (font.id != sourceHanFontId)
                      _DownloadableFontRow(
                        key: ValueKey('downloadable-font-${font.id}'),
                        font: font,
                        fonts: widget.state.fonts,
                        busy: busy,
                        reduceMotion: widget.state.reduceMotion,
                        onDownload: () => _perform(
                          () => widget.state.downloadReadingFont(font.id),
                        ),
                        onDelete: () => _deleteDownloaded(font),
                      ),
                  if (widget.state.fonts.fonts.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    const ArchiveSection(title: '我的字体', code: 'TTF / OTF'),
                    const SizedBox(height: 14),
                  ],
                  if ((error ?? widget.state.fontError) case final message?)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (widget.state.fontError != null)
                    GlassTextButton(
                      onPressed: busy
                          ? null
                          : () => _perform(widget.state.loadFonts),
                      child: const Text('重试读取字体'),
                    ),
                  for (final font in widget.state.fonts.fonts)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              font.name,
                              style: const TextStyle(height: 1.6),
                            ),
                          ),
                          const SizedBox(width: 12),
                          GlassIconButton(
                            icon: CupertinoIcons.trash,
                            label: '移除 ${font.name}',
                            onPressed: busy ? null : () => _delete(font),
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
    ),
  );
}

class _DownloadableFontRow extends StatelessWidget {
  const _DownloadableFontRow({
    super.key,
    required this.font,
    required this.fonts,
    required this.busy,
    required this.reduceMotion,
    required this.onDownload,
    required this.onDelete,
  });
  final DownloadableFont font;
  final UserFontStore fonts;
  final bool busy, reduceMotion;
  final VoidCallback onDownload, onDelete;

  @override
  Widget build(BuildContext context) {
    final available = fonts.available(font.id);
    final active = fonts.downloadingFontId == font.id;
    final failed = fonts.downloadError(font.id) != null;
    final scheme = Theme.of(context).colorScheme;
    Widget action(FontDownloadProgress? progress) => ArchiveTransferButton(
      key: ValueKey(
        font.id == sourceHanFontId
            ? 'manage-source-han-font'
            : 'manage-font-${font.id}',
      ),
      icon: available
          ? CupertinoIcons.trash
          : failed
          ? CupertinoIcons.arrow_clockwise
          : CupertinoIcons.arrow_down_to_line,
      label: active
          ? '取消${font.name}下载'
          : available
          ? '删除${font.name}'
          : failed
          ? '重试下载${font.name}'
          : '下载${font.name}',
      working: active,
      completed: available,
      value: progress?.validating == true ? null : progress?.fraction ?? 0,
      status: active && progress?.validating == true ? '正在校验字体' : null,
      reduceMotion: reduceMotion,
      onPressed: active
          ? fonts.cancelDownload
          : busy
          ? null
          : available
          ? onDelete
          : onDownload,
    );
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      font.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      font.description,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 5),
                    ValueListenableBuilder<FontDownloadProgress?>(
                      valueListenable: fonts.downloadChanges,
                      builder: (context, progress, child) => active
                          ? Text(
                              progress?.validating == true
                                  ? '正在校验字体…'
                                  : '${((progress?.received ?? 0) / 1048576).toStringAsFixed(1)} / ${((progress?.total ?? font.transferBytes) / 1048576).toStringAsFixed(1)} MiB',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.5,
                                color: scheme.onSurfaceVariant,
                              ),
                            )
                          : child!,
                      child: Text(
                        available
                            ? '已下载 · 可离线使用'
                            : failed
                            ? '下载未完成，点击重试'
                            : '${font.sizeLabel} · 按需下载',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (available)
                      _FontFacePreview(
                        fonts: fonts,
                        id: font.id,
                        builder: (ready, _) => Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            font.previewText,
                            style: TextStyle(
                              fontFamily: ready ? fonts.family(font.id) : null,
                              fontSize: 15,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ValueListenableBuilder<FontDownloadProgress?>(
                valueListenable: fonts.downloadChanges,
                // Progress never rebuilds the other font actions or previews.
                builder: (context, progress, child) =>
                    active ? action(progress) : child!,
                child: active ? null : action(null),
              ),
            ],
          ),
        ],
      ),
    );
    return reduceMotion
        ? content
        : AnimatedSize(
            duration: const Duration(milliseconds: 260),
            reverseDuration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: content,
          );
  }
}

// Load only mounted choices, and use the store's one-load-per-face cache. A
// library of large custom fonts must not all be decoded when opening settings.
class _FontFacePreview extends StatefulWidget {
  const _FontFacePreview({
    required this.fonts,
    required this.id,
    required this.builder,
  });
  final UserFontStore fonts;
  final String id;
  final Widget Function(bool ready, bool failed) builder;
  @override
  State<_FontFacePreview> createState() => _FontFacePreviewState();
}

class _FontFacePreviewState extends State<_FontFacePreview> {
  static Future<void> _previewQueue = Future.value();
  Future<void>? _loading;
  bool _available = false;
  Animation<double>? _routeAnimation;
  ModalRoute<dynamic>? _route;
  @override
  void initState() {
    super.initState();
    _available = widget.fonts.available(widget.id);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final animation = _route?.animation;
    if (_routeAnimation != animation) {
      _routeAnimation?.removeStatusListener(_routeChanged);
      _routeAnimation = animation;
      animation?.addStatusListener(_routeChanged);
    }
    _prepare();
  }

  void _routeChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) setState(_prepare);
  }

  void _prepare() {
    _available = widget.fonts.available(widget.id);
    if (!_available ||
        widget.fonts.isLoaded(widget.id) ||
        _loading != null ||
        _route?.isCurrent == false ||
        (_routeAnimation != null &&
            _routeAnimation!.status != AnimationStatus.completed)) {
      return;
    }
    final id = widget.id, fonts = widget.fonts;
    final work = _previewQueue.then(
      (_) => SchedulerBinding.instance.scheduleTask(
        () async {
          if (!mounted || widget.id != id || _route?.isCurrent == false) return;
          await fonts.ensureLoaded(id);
        },
        Priority.idle,
        debugLabel: 'font-face-preview',
      ),
    );
    _loading = work;
    // Font registration invalidates text metrics. Do not register several large
    // faces together, or register them while the page's glass transition draws.
    _previewQueue = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
  }

  @override
  void didUpdateWidget(_FontFacePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id ||
        oldWidget.fonts != widget.fonts ||
        _available != widget.fonts.available(widget.id)) {
      _loading = null;
      _prepare();
    }
  }

  @override
  Widget build(BuildContext context) => _loading == null
      ? widget.builder(widget.fonts.isLoaded(widget.id), false)
      : FutureBuilder<void>(
          future: _loading,
          builder: (context, snapshot) => widget.builder(
            widget.fonts.isLoaded(widget.id) && !snapshot.hasError,
            snapshot.hasError,
          ),
        );

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_routeChanged);
    super.dispose();
  }
}

/// A transfer occupies its action, never a second panel. The fine open ring
/// measures real progress; the centre remains the stop target throughout.
class ArchiveTransferButton extends StatefulWidget {
  const ArchiveTransferButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.working = false,
    this.completed = false,
    this.value,
    this.status,
    this.reduceMotion = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool working, completed, reduceMotion;
  final double? value;
  final String? status;

  @override
  State<ArchiveTransferButton> createState() => _ArchiveTransferButtonState();
}

class _ArchiveTransferButtonState extends State<ArchiveTransferButton>
    with TickerProviderStateMixin {
  late final _fill = AnimationController(vsync: this);
  late final _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  late final _finish = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 720),
  );
  late final _paint = Listenable.merge([_fill, _turn, _finish]);
  bool get _still =>
      widget.reduceMotion || MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ArchiveTransferButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.working && !widget.working && widget.completed && !_still) {
      _finish.forward(from: 0);
    } else if (widget.working || _still) {
      _finish.value = 1;
    }
    _sync();
  }

  void _sync() {
    final target = widget.value?.clamp(0.0, 1.0) ?? 0;
    if (_still || !widget.working) {
      _fill.value = target;
    } else if (_fill.value != target) {
      _fill.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
    if (widget.working && widget.value == null && !_still) {
      if (!_turn.isAnimating) _turn.repeat();
    } else {
      _turn.stop();
      _turn.value = 0;
    }
    if (_still) _finish.value = 1;
  }

  @override
  void dispose() {
    _fill.dispose();
    _turn.dispose();
    _finish.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = widget.onPressed == null
        ? theme.disabledColor
        : theme.colorScheme.onSurface;
    final value = widget.value;
    final semanticValue = [
      if (widget.working && value != null)
        '${(value.clamp(0, 1) * 100).floor()}%',
      ?widget.status,
    ].join(' · ');
    return MergeSemantics(
      child: Semantics(
        value: semanticValue.isEmpty ? null : semanticValue,
        child: GlassIconButton.custom(
          key: ValueKey((widget.working, widget.completed)),
          label: widget.label,
          onPressed: widget.onPressed,
          child: RepaintBoundary(
            child: SizedBox.square(
              dimension: 30,
              child: AnimatedBuilder(
                animation: _finish,
                builder: (context, icon) => CustomPaint(
                  key: const ValueKey('archive-transfer-ring'),
                  painter: _TransferMarkPainter(
                    fill: _fill,
                    turn: _turn,
                    finish: _finish,
                    repaint: _paint,
                    ink: ink,
                    working: widget.working,
                    indeterminate: value == null,
                    highContrast: MediaQuery.highContrastOf(context),
                  ),
                  child: Opacity(
                    opacity: widget.working
                        ? 0
                        : Curves.easeOut.transform(
                            ((_finish.value - .65) / .35).clamp(0, 1),
                          ),
                    child: icon,
                  ),
                ),
                child: ArchiveIcon(widget.icon, size: 21, color: ink),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TransferMarkPainter extends CustomPainter {
  _TransferMarkPainter({
    required this.fill,
    required this.turn,
    required this.finish,
    required Listenable repaint,
    required this.ink,
    required this.working,
    required this.indeterminate,
    required this.highContrast,
  }) : super(repaint: repaint);
  final Animation<double> fill, turn, finish;
  final Color ink;
  final bool working, indeterminate, highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final pen = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round;
    if (working) {
      final ring = Rect.fromCircle(center: centre, radius: 12.5);
      const gap = .22;
      const start = -math.pi / 2 + gap / 2;
      const sweep = 2 * math.pi - gap;
      pen.color = ink.withValues(alpha: highContrast ? .32 : .12);
      canvas.drawArc(ring, start, sweep, false, pen);
      pen.color = ink.withValues(alpha: .88);
      if (indeterminate) {
        canvas.drawArc(
          ring,
          start + turn.value * 2 * math.pi,
          sweep * .23,
          false,
          pen,
        );
      } else if (fill.value > 0) {
        canvas.drawArc(ring, start, sweep * fill.value, false, pen);
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: centre, width: 7, height: 7),
          const Radius.circular(1.2),
        ),
        Paint()..color = ink.withValues(alpha: .88),
      );
    } else if (finish.value < 1) {
      final reveal = Curves.easeOut.transform((finish.value / .3).clamp(0, 1));
      final fade = 1.0 - ((finish.value - .65) / .35).clamp(0, 1);
      final path = Path()
        ..moveTo(centre.dx - 5, centre.dy)
        ..lineTo(centre.dx - 1.2, centre.dy + 3.8)
        ..lineTo(centre.dx + 6, centre.dy - 4.5);
      final metric = path.computeMetrics().single;
      pen.color = ink.withValues(alpha: fade);
      canvas.drawPath(metric.extractPath(0, metric.length * reveal), pen);
    }
  }

  @override
  bool shouldRepaint(_TransferMarkPainter old) =>
      old.ink != ink ||
      old.working != working ||
      old.indeterminate != indeterminate ||
      old.highContrast != highContrast;
}
