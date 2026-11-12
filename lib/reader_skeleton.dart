import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_palette.dart';
import 'app_ui.dart';
import 'glass_palette.dart';
import 'library_state.dart';
import 'performance_preferences.dart';
import 'reader_chrome.dart';
import 'reader_preferences.dart';

/// Shared reading skeleton for TXT / EPUB / PDF (design 2026-11 §5.3).
///
/// * [ReaderPaperScope] applies the reader paper and warm light to one
///   reader subtree; the rest of the app keeps its own theme.
/// * Reader controls are solid panels: [ReaderSolidScope] turns glass
///   refraction and backdrop blur off for everything inside the reader.
/// * [ReaderActionBar] gives every format the same four buttons
///   (目录 / 排版 / 亮度 / 听书). Unsupported ones stay visible, greyed, and
///   explain why when tapped.

ThemeData readerPaperTheme(
  ThemeData base,
  ReaderPreferences prefs, {
  bool overrideFont = false,
  String? fontFamily,
  List<String>? fontFamilyFallback,
}) {
  final appDark = base.brightness == Brightness.dark;
  if (prefs.paper == ReaderPaper.system && !overrideFont) return base;
  final baseText = overrideFont
      ? ThemeData(brightness: base.brightness).textTheme.apply(
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          bodyColor: base.colorScheme.onSurface,
          displayColor: base.colorScheme.onSurface,
        )
      : base.textTheme;
  if (prefs.paper == ReaderPaper.system) {
    return base.copyWith(textTheme: baseText);
  }
  final dark = prefs.darkPaper(appDark);
  final background = prefs.background(appDark);
  final ink = prefs.foreground(appDark);
  final control = prefs.controlForeground(appDark);
  final panel = prefs.panel(appDark);
  final muted = Color.lerp(background, control, dark ? .62 : .66)!;
  final scheme = base.colorScheme.copyWith(
    brightness: dark ? Brightness.dark : Brightness.light,
    surface: background,
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceContainerLowest: background,
    surfaceContainerLow: panel,
    surfaceContainer: panel,
    surfaceContainerHigh: Color.lerp(panel, control, .05),
    surfaceContainerHighest: Color.lerp(panel, control, .09),
    outlineVariant: Color.lerp(panel, control, .14),
    primary: dark && !appDark ? base.colorScheme.inversePrimary : null,
  );
  final tonal = base.extension<AppTonalColors>();
  return base.copyWith(
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    dividerColor: scheme.outlineVariant,
    textTheme: baseText.apply(bodyColor: ink, displayColor: ink),
    iconTheme: base.iconTheme.copyWith(color: control),
    extensions: [
      for (final extension in base.extensions.values)
        if (extension is! GlassPalette &&
            extension is! AppTonalColors &&
            extension is! PageWash)
          extension,
      // Translucent reader controls take the paper's control-panel colour.
      GlassPalette(tint: panel, thumb: dark ? control : Colors.white),
      if (tonal != null)
        tonal.copyWith(
          milk: panel,
          darkMilk: dark ? control : panel,
          glassSurface: panel,
          thumb: dark ? control : Colors.white,
          action: control,
        ),
    ],
  );
}

/// Glass refraction and backdrop blur are off for the reader chrome so
/// controls paint in one pass with their foreground under [ReaderChromeLayer]'s
/// opacity transition; translucency is preserved by `NativeBackdrop`.
class ReaderSolidScope extends StatelessWidget {
  const ReaderSolidScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final parent = PerformanceScope.of(context);
    final effects = {
      for (final effect in PerformanceEffect.values)
        if (effect != PerformanceEffect.glass &&
            effect != PerformanceEffect.blur &&
            parent.allows(effect))
          effect,
    };
    return PerformanceScope(
      preferences: PerformancePreferences(enabled: true, effects: effects),
      explicitReduceMotion: PerformanceScope.reduceMotionOf(context),
      child: child,
    );
  }
}

/// Paper theme + warm-light overlay for one reader.
class ReaderPaperScope extends StatefulWidget {
  const ReaderPaperScope({super.key, required this.state, required this.child});
  final LibraryState state;
  final Widget child;

  @override
  State<ReaderPaperScope> createState() => _ReaderPaperScopeState();
}

class _ReaderPaperScopeState extends State<ReaderPaperScope> {
  ThemeData? _base;
  ReaderPreferences? _prefs;
  String? _readerFontId;
  bool? _overrideFont;
  ThemeData? _theme;

  ThemeData _resolve(ThemeData base, ReaderPreferences prefs) {
    final readerFontId = widget.state.effectiveReaderFontId;
    final overrideFont = readerFontId != widget.state.appFontId;
    final cached = _theme;
    if (cached != null &&
        identical(base, _base) &&
        _prefs?.paper == prefs.paper &&
        _prefs?.nightTextBrightness == prefs.nightTextBrightness &&
        _readerFontId == readerFontId &&
        _overrideFont == overrideFont) {
      return cached;
    }
    _base = base;
    _prefs = prefs;
    _readerFontId = readerFontId;
    _overrideFont = overrideFont;
    return _theme = readerPaperTheme(
      base,
      prefs,
      overrideFont: overrideFont,
      fontFamily: widget.state.readerFontFamily,
      fontFamilyFallback: widget.state.readerFontFamilyFallback,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state.readerSettingsChanges,
    child: widget.child,
    builder: (context, child) {
      final prefs = widget.state.readerPreferences;
      final base = Theme.of(context);
      final theme = _resolve(base, prefs);
      final warm = prefs.warmth > 0;
      Widget content = ReaderSolidScope(child: child!);
      if (!identical(theme, base)) {
        content = Theme(data: theme, child: content);
      }
      if (!warm) return content;
      return Stack(
        fit: StackFit.passthrough,
        children: [
          content,
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                key: const ValueKey('reader-warm-light'),
                color: readerWarmthOverlay(prefs.warmth),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// One bottom-bar button. A null [onPressed] with an [unavailable] reason
/// keeps the button visible but grey; tapping it explains the reason.
class ReaderAction {
  const ReaderAction({
    required this.icon,
    required this.caption,
    required this.label,
    this.onPressed,
    this.unavailable,
    this.key,
  });
  final IconData icon;
  final String caption, label;
  final VoidCallback? onPressed;
  final String? unavailable;
  final Key? key;
}

class ReaderActionBar extends StatelessWidget {
  const ReaderActionBar({super.key, required this.actions});
  final List<ReaderAction> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      key: const ValueKey('reader-action-bar'),
      children: [
        for (final action in actions)
          Expanded(
            child: Opacity(
              opacity: action.unavailable == null ? 1 : .42,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassIconButton(
                    key: action.key,
                    icon: action.icon,
                    label: action.label,
                    transparent: true,
                    onPressed: action.unavailable != null
                        ? () => showNovelFeedback(context, action.unavailable!)
                        : action.onPressed,
                  ),
                  Text(
                    action.caption,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Transparent bottom panel: progress, optional navigation, actions.
class ReaderBottomPanel extends StatelessWidget {
  const ReaderBottomPanel({
    super.key,
    required this.actions,
    this.progress,
    this.navigation,
  });
  final Widget? progress;
  final Widget? navigation;
  final List<ReaderAction> actions;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('reader-bottom-panel'),
    decoration: const BoxDecoration(color: Colors.transparent),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?progress,
          ?navigation,
          ReaderActionBar(actions: actions),
        ],
      ),
    ),
  );
}

/// 11sp status line shown while the controls are hidden.
class ReaderStatusLine extends StatefulWidget {
  const ReaderStatusLine({
    super.key,
    required this.chrome,
    required this.text,
  });
  final Animation<double> chrome;
  final String text;

  @override
  State<ReaderStatusLine> createState() => _ReaderStatusLineState();
}

class _ReaderStatusLineState extends State<ReaderStatusLine> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = TimeOfDay.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: widget.chrome,
        builder: (context, _) {
          final hidden = 1 - widget.chrome.value;
          if (hidden == 0) return const SizedBox.shrink();
          return Opacity(
            opacity: .55 * hidden,
            child: Text(
              '${widget.text} · $time',
              key: const ValueKey('reader-status-line'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Unified outer reader scaffold combining [ReaderTopBar], [ReaderEdgeBlur],
/// [ReaderChromeLayer], [ReaderBottomPanel], and [ReaderStatusLine] for
/// TXT, EPUB, and PDF readers.
class ReaderScaffold extends StatelessWidget {
  const ReaderScaffold({
    super.key,
    required this.chrome,
    required this.novelId,
    required this.title,
    required this.bookmarkListenable,
    required this.isBookmarked,
    required this.onAddBookmark,
    required this.actions,
    required this.body,
    this.statusText = '',
    this.statusListenable,
    this.statusTextBuilder,
    this.progress,
    this.navigation,
    this.leadingStackChild,
    this.useAtmosphere = true,
    this.blurBottom = true,
    this.bottomMaxWidth,
    this.backgroundColor,
  });

  final Animation<double> chrome;
  final int novelId;
  final String title;
  final Listenable bookmarkListenable;
  final bool Function() isBookmarked;
  final VoidCallback? onAddBookmark;
  final List<ReaderAction> actions;
  final Widget body;
  final String statusText;
  final ValueListenable<double>? statusListenable;
  final String Function(double progress)? statusTextBuilder;
  final Widget? progress;
  final Widget? navigation;
  final Widget? leadingStackChild;
  final bool useAtmosphere;
  final bool blurBottom;
  final double? bottomMaxWidth;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.paddingOf(context);
    Widget bottomPanel = ReaderBottomPanel(
      actions: actions,
      progress: progress,
      navigation: navigation,
    );
    if (bottomMaxWidth != null) {
      bottomPanel = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: bottomMaxWidth!),
        child: bottomPanel,
      );
    }
    final statusWidget = statusListenable != null && statusTextBuilder != null
        ? ValueListenableBuilder<double>(
            valueListenable: statusListenable!,
            builder: (context, value, _) => ReaderStatusLine(
              chrome: chrome,
              text: statusTextBuilder!(value),
            ),
          )
        : ReaderStatusLine(chrome: chrome, text: statusText);
    final stack = Stack(
      children: [
        ?leadingStackChild,
        Positioned.fill(child: body),
        Positioned.fill(
          child: ReaderEdgeBlur(animation: chrome, blurBottom: blurBottom),
        ),
        // Paper scrim so body text never reads through the bottom controls.
        // A plain gradient (no backdrop sampling) keeps scrolling cheap.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: media.bottom + 190,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: chrome,
              builder: (context, _) {
                final t = Curves.easeOut.transform(chrome.value);
                if (t == 0) return const SizedBox.shrink();
                final paper = Theme.of(context).colorScheme.surface;
                return DecoratedBox(
                  key: const ValueKey('reader-bottom-scrim'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0, .28, 1],
                      colors: [
                        paper.withValues(alpha: 0),
                        paper.withValues(alpha: .95 * t),
                        paper.withValues(alpha: .98 * t),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ReaderTopBar(
            chrome: chrome,
            novelId: novelId,
            title: title,
            bookmarkListenable: bookmarkListenable,
            isBookmarked: isBookmarked,
            onAddBookmark: onAddBookmark,
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              22 + media.left,
              0,
              22 + media.right,
              media.bottom + 12,
            ),
            child: ReaderChromeLayer(
              key: const ValueKey('reader-chrome-dock'),
              animation: chrome,
              slide: const Offset(0, 8),
              fadeOffset: const Offset(0, 12),
              child: bottomPanel,
            ),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: media.bottom + 6,
          child: statusWidget,
        ),
      ],
    );
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: backgroundColor,
      body: useAtmosphere
          ? Atmosphere(
              shareGlass: true,
              archiveBackdrop: false,
              child: stack,
            )
          : stack,
    );
  }
}

/// 亮度 sheet: paper, night text brightness, warm light and PDF inversion.
/// The settings page opens the same panel, so both edit one record.
Future<void> showReaderAppearanceSheet(
  BuildContext context, {
  required LibraryState state,
  bool pdf = false,
}) => showJellySheet<void>(
  context: context,
  reduceMotion: state.reduceMotion || MediaQuery.disableAnimationsOf(context),
  builder: (context) => ReaderAppearancePanel(state: state, pdf: pdf),
);

class ReaderAppearancePanel extends StatefulWidget {
  const ReaderAppearancePanel({super.key, required this.state, this.pdf = false});
  final LibraryState state;
  final bool pdf;

  @override
  State<ReaderAppearancePanel> createState() => _ReaderAppearancePanelState();
}

class _ReaderAppearancePanelState extends State<ReaderAppearancePanel> {
  double? _brightness, _warmth;
  LibraryState get state => widget.state;

  Future<void> _save(ReaderPreferences next) async {
    try {
      await state.setReaderPreferences(next);
    } catch (_) {
      if (mounted) showNovelFeedback(context, '阅读设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.readerSettingsChanges,
    builder: (context, _) {
      final prefs = state.readerPreferences;
      final appDark = Theme.of(context).brightness == Brightness.dark;
      final scheme = Theme.of(context).colorScheme;
      final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
      final darkPaper = prefs.darkPaper(appDark);
      return SingleChildScrollView(
        key: const ValueKey('reader-appearance-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '亮度与纸色'),
            const SizedBox(height: 4),
            Text('与“设置 → 阅读偏好”是同一份设置，任一处修改都会同步。', style: muted),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final paper in ReaderPaper.choices)
                  _swatch(context, prefs, paper, appDark),
              ],
            ),
            const Divider(height: 28),
            _sliderLabel('夜读正文亮度', '${((_brightness ?? prefs.nightTextBrightness) * 100).round()}%'),
            CupertinoSlider(
              key: const ValueKey('reader-night-brightness'),
              value: _brightness ?? prefs.nightTextBrightness,
              min: .35,
              max: 1,
              onChanged: darkPaper
                  ? (value) => setState(() => _brightness = value)
                  : null,
              onChangeEnd: (value) async {
                await _save(prefs.copyWith(nightTextBrightness: value));
                if (mounted) setState(() => _brightness = null);
              },
            ),
            if (!darkPaper) Text('仅在深色纸色（夜读、纯黑或深色外观）下生效。', style: muted),
            const SizedBox(height: 12),
            _sliderLabel('暖光', '${((_warmth ?? prefs.warmth) * 100).round()}%'),
            CupertinoSlider(
              key: const ValueKey('reader-warmth'),
              value: _warmth ?? prefs.warmth,
              min: 0,
              max: readerWarmthMax,
              onChanged: (value) => setState(() => _warmth = value),
              onChangeEnd: (value) async {
                await _save(prefs.copyWith(warmth: value));
                if (mounted) setState(() => _warmth = null);
              },
            ),
            const Divider(height: 28),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('夜读时反色 PDF', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        widget.pdf ? '深色纸色下将 PDF 页面反相显示' : '仅影响 PDF：深色纸色下反相页面',
                        style: muted,
                      ),
                    ],
                  ),
                ),
                CupertinoSwitch(
                  key: const ValueKey('reader-pdf-invert'),
                  value: state.pdfNightInvert,
                  activeTrackColor: scheme.primary,
                  onChanged: (value) async {
                    try {
                      await state.setPdfNightInvert(value);
                    } catch (_) {
                      if (context.mounted) showNovelFeedback(context, '设置保存失败，请重试');
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      );
    },
  );

  Widget _sliderLabel(String title, String value) => Row(
    children: [
      Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
      Text(value, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ],
  );

  Widget _swatch(
    BuildContext context,
    ReaderPreferences prefs,
    ReaderPaper paper,
    bool appDark,
  ) {
    final sample = prefs.copyWith(paper: paper);
    final selected = prefs.paper == paper;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '纸色 ${paper.label}',
      child: GestureDetector(
        key: ValueKey('reader-paper-${paper.name}'),
        onTap: () => _save(prefs.copyWith(paper: paper)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sample.background(appDark),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: Text(
                '文',
                style: TextStyle(color: sample.foreground(appDark), fontSize: 16),
              ),
            ),
            const SizedBox(height: 4),
            Text(paper.label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
