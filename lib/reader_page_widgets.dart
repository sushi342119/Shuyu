part of 'pages.dart';

class RecentSearches extends StatelessWidget {
  const RecentSearches({
    super.key,
    required this.state,
    required this.onRecall,
  });
  final LibraryState state;
  final ValueChanged<String> onRecall;

  Future<void> _clear(BuildContext context) async {
    FocusScope.of(context).unfocus();
    final confirmed = await showJellySheet<bool>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (sheet) => SingleChildScrollView(
        primary: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '清空最近搜索？',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text('只清除本机关键词，不影响书架、阅读进度或书签。'),
              const SizedBox(height: 16),
              GlassTextButton(
                onPressed: () => Navigator.pop(sheet, true),
                child: const Text('清空搜索记录'),
              ),
              GlassTextButton(
                onPressed: () => Navigator.pop(sheet, false),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await state.clearRecentSearches();
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '搜索记录清除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.searchChanges,
    builder: (context, _) {
      final recent = state.recentSearches;
      if (recent.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '最近搜索',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                GlassIconButton(
                  icon: CupertinoIcons.trash,
                  label: '清空最近搜索',
                  onPressed: () => _clear(context),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final query in recent)
                  JellyTapSurface(
                    key: ValueKey('recent-search-$query'),
                    onTap: () => onRecall(query),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: .055),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        query,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

/// Owns only explicitly requested reader motion. Uses Scrollable's native
/// driven activity, not a per-frame setState, position listener or text relayout.
class ReaderFollowScroll {
  ReaderFollowScroll(this.controller);
  final ScrollController controller;
  static const curve = Curves.easeInOutCubic;
  int _ticket = 0;
  bool _disposed = false, _driving = false;
  ScrollPosition? _position;

  static Duration durationFor(double distance, double viewport) {
    if (distance.abs() < 12) return const Duration(milliseconds: 180);
    final screens = distance.abs() / viewport.clamp(1.0, double.infinity);
    return Duration(
      milliseconds: (380 + screens * 140).round().clamp(380, 660),
    );
  }

  void cancel({bool userDrag = false}) {
    _ticket++;
    final position = _position;
    final driving = _driving;
    _driving = false;
    _position = null;
    // A user drag has already replaced our activity. Never hold/cancel that
    // new drag or its inertia when the reader suspends automatic following.
    if (!userDrag &&
        driving &&
        position != null &&
        controller.positions.contains(position)) {
      position.hold(() {}).cancel();
    }
  }

  Future<void> reveal({
    required ParagraphTarget? Function() target,
    required bool Function() allowed,
    required bool reduceMotion,
  }) async {
    cancel();
    final ticket = _ticket;
    bool valid() => !_disposed && ticket == _ticket && allowed();
    // Lazy rows are approached with an animated estimate and then refined
    // after layout. Offscreen text is never eagerly laid out to find a target.
    for (var pass = 0; pass < 12 && valid(); pass++) {
      final anchor = controller.hasClients ? target() : null;
      if (anchor == null || !anchor.offset.isFinite) {
        await _nextLayout();
        continue;
      }
      if (!valid() || !controller.hasClients) return;
      final position = controller.position;
      final offset = anchor.offset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      final distance = offset - position.pixels;
      if (distance.abs() < 1) {
        if (anchor.exact) return;
        await _nextLayout();
        continue;
      }
      if (reduceMotion) {
        position.jumpTo(offset);
      } else {
        _driving = true;
        _position = position;
        try {
          await position.animateTo(
            offset,
            duration: durationFor(distance, position.viewportDimension),
            curve: curve,
          );
          // animateTo also completes when a touch/hold interrupts it. Do not
          // restart a refinement underneath that finger. A changed lazy extent
          // is different: the next pass still needs to refine its estimate.
          if (valid() && (position.pixels - offset).abs() > 2) {
            final clippedByNewExtent =
                (offset > position.maxScrollExtent &&
                    position.pixels >= position.maxScrollExtent - 1) ||
                (offset < position.minScrollExtent &&
                    position.pixels <= position.minScrollExtent + 1);
            if (!clippedByNewExtent) return;
          }
        } finally {
          if (ticket == _ticket) {
            _driving = false;
            _position = null;
          }
        }
      }
      if (!valid()) return;
      await _nextLayout();
    }
  }

  void dispose() {
    cancel();
    _disposed = true;
  }

  Future<void> _nextLayout() {
    final frame = WidgetsBinding.instance.endOfFrame;
    // endOfFrame called from a post-frame callback also needs a fresh frame.
    // This is bounded to this reveal, never a persistent render loop.
    WidgetsBinding.instance.ensureVisualUpdate();
    return frame;
  }
}

/// A temporary archive registration plane, never a text glow or blur layer.
class ReaderLandingHighlight extends StatefulWidget {
  const ReaderLandingHighlight({
    super.key,
    required this.child,
    this.reduceMotion = false,
  });
  final Widget child;
  final bool reduceMotion;

  @override
  State<ReaderLandingHighlight> createState() => _ReaderLandingHighlightState();
}

class _ReaderLandingHighlightState extends State<ReaderLandingHighlight>
    with SingleTickerProviderStateMixin {
  AnimationController? _clock;
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncClock();
  }

  @override
  void didUpdateWidget(ReaderLandingHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
  }

  void _syncClock() {
    _reduced = widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
    if (_reduced) {
      _clock?.stop();
    } else {
      _clock ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2000),
      );
      if (_clock!.value < 1 && !_clock!.isAnimating) _clock!.forward();
    }
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _LandingPlane(
      clock: _reduced ? null : _clock,
      dark: Theme.of(context).brightness == Brightness.dark,
    ),
    child: widget.child,
  );

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }
}

class _LandingPlane extends CustomPainter {
  _LandingPlane({required this.clock, required this.dark})
    : super(repaint: clock);
  final Animation<double>? clock;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock?.value;
    final strength = t == null
        ? 1.0
        : t < .14
        ? Curves.easeOut.transform(t / .14)
        : t < .7
        ? 1.0
        : 1 - Curves.easeInOut.transform(((t - .7) / .3).clamp(0.0, 1.0));
    if (strength <= 0) return;
    final rect = readerRegistrationBounds(Offset.zero & size);
    paintReaderRegistrationFrame(
      canvas,
      rect,
      fill:
          (dark
                  ? ArchiveDesign.milk
                  : Color.lerp(
                      ArchiveDesign.milk,
                      ArchiveDesign.darkSurface,
                      .065,
                    )!)
              .withValues(alpha: strength * (dark ? .13 : .92)),
      ink: (dark ? ArchiveDesign.milk : ArchiveDesign.darkSurface).withValues(
        alpha: strength * (dark ? .65 : .42),
      ),
    );
  }

  @override
  bool shouldRepaint(_LandingPlane oldDelegate) =>
      clock != oldDelegate.clock || dark != oldDelegate.dark;
}

/// The four visible controls own appearance and tactile feedback; retired
/// overrides are migrated by LibraryState before settings are loaded or restored.
class AppearancePerformancePanel extends StatefulWidget {
  const AppearancePerformancePanel({super.key, required this.state});
  final LibraryState state;

  @override
  State<AppearancePerformancePanel> createState() =>
      _AppearancePerformancePanelState();
}

class _AppearancePerformancePanelState
    extends State<AppearancePerformancePanel> {
  bool _expanded = false;
  LibraryState get state => widget.state;

  Future<void> _save(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) showNovelFeedback(context, '设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.settingsChanges,
    builder: (context, _) => _buildPanel(context),
  );

  Widget _buildPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glass = state.resolvedGlass;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return ContentPanel(
      key: const ValueKey('settings-appearance-performance'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            child: InkWell(
              key: const ValueKey('appearance-performance-toggle'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(
                          alpha:
                              Theme.of(context).brightness == Brightness.dark
                              ? 0.16
                              : 0.10,
                        ),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: scheme.primary.withValues(
                            alpha:
                                Theme.of(context).brightness == Brightness.dark
                                ? 0.28
                                : 0.16,
                          ),
                          width: 0.8,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: ArchiveIcon(
                        CupertinoIcons.slider_horizontal_3,
                        size: 18,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '外观与性能',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '玻璃：${glass.automatic ? '自动·' : ''}${glass.tier.label}'
                            ' · 动效：${state.motionLevel.label}'
                            ' · 选书：${state.randomPickPace.label}'
                            ' · 振动：${state.haptics.level.label}',
                            key: const ValueKey(
                              'appearance-performance-summary',
                            ),
                            style: muted,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ArchiveIcon(
                      _expanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 20),
            const Text('玻璃效果', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            AppControls.segments<GlassTier>(
              context,
              key: const ValueKey('glass-tier-picker'),
              groupValue: glass.tier,
              children: {
                for (final tier in GlassTier.values) tier: Text(tier.label),
              },
              onValueChanged: (tier) {
                if (tier != null) _save(() => state.setGlassTier(tier));
              },
            ),
            if (!glass.automatic)
              Align(
                alignment: Alignment.centerLeft,
                child: GlassTextButton(
                  key: const ValueKey('glass-tier-auto'),
                  compact: true,
                  onPressed: () => _save(() => state.setGlassTier(null)),
                  child: const Text('恢复自动选择'),
                ),
              ),
            const SizedBox(height: 12),
            const Text('动效', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            AppControls.segments<MotionLevel>(
              context,
              key: const ValueKey('motion-level-picker'),
              groupValue: state.motionLevel,
              children: {
                for (final level in MotionLevel.values)
                  level: Text(level.label),
              },
              onValueChanged: (level) {
                if (level != null) _save(() => state.setMotionLevel(level));
              },
            ),
            const SizedBox(height: 12),
            const Text('随机选书', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            AppControls.segments<RandomPickPace>(
              context,
              key: const ValueKey('random-pick-pace-picker'),
              groupValue: state.randomPickPace,
              children: {
                for (final pace in RandomPickPace.values)
                  pace: Text(pace.label),
              },
              onValueChanged: (pace) {
                if (pace != null) _save(() => state.setRandomPickPace(pace));
              },
            ),
            const SizedBox(height: 12),
            const Text('振动反馈', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            AppControls.segments<HapticLevel>(
              context,
              key: const ValueKey('haptic-level-picker'),
              haptics: false,
              groupValue: state.haptics.level,
              children: {
                for (final level in HapticLevel.values)
                  level: Text(level.label),
              },
              onValueChanged: (level) {
                if (level == null) return;
                final next = state.haptics.withLevel(level);
                _save(() async {
                  await state.setHaptics(next);
                  if (context.mounted && level != HapticLevel.off) {
                    AppHaptics.preview(
                      context,
                      HapticCue.selection,
                      preferences: next,
                    );
                  }
                });
              },
            ),
          ],
        ],
      ),
    );
  }
}
