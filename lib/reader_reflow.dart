import 'dart:ui' show lerpDouble;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'archive_motion.dart';
import 'reader_pagination.dart';
import 'reader_turn_motion.dart';

/// Reflow retains source identities. Changed vertical columns are replaced in
/// reading order while unchanged glyphs stay painted in place.
class ReaderReflowScope extends InheritedWidget {
  ReaderReflowScope({
    super.key,
    required this.animation,
    required this.previous,
    this.current,
    required this.size,
    required this.previousSize,
    required this.originDelta,
    required super.child,
  });
  final Animation<double> animation;
  final ReaderLeaf previous;
  final ReaderLeaf? current;
  late final _LineReflowPlan _linePlan = _LineReflowPlan(this);
  final Size size, previousSize;
  final Offset originDelta;
  double get progress =>
      Curves.easeOutCubic.transform(animation.value.clamp(0, 1));
  double delayFor(int index, int count, {bool reverse = false}) {
    final rank = reverse ? count - 1 - index : index;
    return count < 2 ? 0 : .2 * rank.clamp(0, count - 1) / (count - 1);
  }

  double progressFor(int index, int count, {bool reverse = false}) {
    final start = delayFor(index, count, reverse: reverse);
    return Interval(
      start,
      start + .8,
      curve: Curves.easeOutCubic,
    ).transform(animation.value.clamp(0, 1));
  }

  Offset displacementFor(int index, int count, {bool reverse = false}) =>
      originDelta * (progress - progressFor(index, count, reverse: reverse));
  int lineCount({bool departing = false}) =>
      (departing ? previous : current ?? previous).fragments.fold<int>(
        0,
        (count, fragment) => count + fragment.lineCount,
      );
  int lineIndex(ReaderPageFragment fragment, {bool departing = false}) {
    var rank = 0;
    for (final part in (departing ? previous : current ?? previous).fragments) {
      if (identical(part, fragment) ||
          part.paragraph == fragment.paragraph &&
              part.start == fragment.start) {
        return rank;
      }
      rank += part.lineCount;
    }
    return rank;
  }

  static ReaderReflowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReaderReflowScope>();
  @override
  bool updateShouldNotify(ReaderReflowScope oldWidget) =>
      animation != oldWidget.animation ||
      previous != oldWidget.previous ||
      current != oldWidget.current ||
      size != oldWidget.size ||
      previousSize != oldWidget.previousSize ||
      originDelta != oldWidget.originDelta;
}

/// Horizontal reflow owns individual shaped lines, while images and rules
/// remain atomic. Text and selection still use one intact paragraph renderer.
class ReaderFragmentMotion extends StatelessWidget {
  const ReaderFragmentMotion({
    super.key,
    required this.fragment,
    required this.index,
    required this.count,
    required this.child,
    this.previousBuilder,
  });
  final ReaderPageFragment fragment;
  final int index, count;
  final Widget child;
  final Widget Function(ReaderPageFragment)? previousBuilder;
  @override
  Widget build(BuildContext context) {
    final scope = ReaderReflowScope.maybeOf(context);
    if (scope == null) {
      return ReaderTurnPart(
        index: index,
        count: count,
        bounds: fragment.rect,
        child: child,
      );
    }
    if (fragment.lineMetrics != null) {
      final old = scope.previous.fragments
          .where((before) => before.paragraph == fragment.paragraph)
          .firstOrNull;
      return _ReaderLineMotion(
        scope: scope,
        fragment: fragment,
        previous: old,
        previousChild:
            old == null ||
                previousBuilder == null ||
                old.text == fragment.text && old.rect.size == fragment.rect.size
            ? null
            : previousBuilder!(old),
        child: child,
      );
    }
    final reverse = scope.originDelta.dy < 0;
    ReaderPageFragment? previous;
    for (final before in scope.previous.fragments) {
      if (before.paragraph == fragment.paragraph &&
          before.start == fragment.start) {
        previous = before;
        break;
      }
    }
    final old = previous;
    final previousChild =
        old != null &&
            previousBuilder != null &&
            (old.text != fragment.text || old.rect.size != fragment.rect.size)
        ? previousBuilder!(old)
        : null;
    final start = scope.delayFor(index, count, reverse: reverse);
    return AnimatedBuilder(
      animation: scope.animation,
      child: old != null
          ? child
          : ArchiveReveal(
              animation: scope.animation,
              start: start,
              end: start + .8,
              travel: const Offset(-8, 10),
              child: child,
            ),
      builder: (context, child) {
        final progress = scope.progressFor(index, count, reverse: reverse);
        final correction = old == null
            ? Offset.zero
            : (old.rect.topLeft - fragment.rect.topLeft) * (1 - progress);
        final content = previousChild == null
            ? child!
            : _FragmentReplacement(
                progress: progress,
                previous: previousChild,
                previousSize: old!.rect.size,
                size: fragment.rect.size,
                child: child!,
              );
        return Transform.translate(
          offset:
              scope.displacementFor(index, count, reverse: reverse) +
              correction,
          child: content,
        );
      },
    );
  }
}

/// Old and new ink occupy complementary clips on the same moving paragraph.
/// Publishing a taller fragment must not expose its extra lines immediately;
/// shrinking one must retain its old tail until that tail actually leaves.
class _FragmentReplacement extends StatelessWidget {
  const _FragmentReplacement({
    required this.progress,
    required this.previous,
    required this.previousSize,
    required this.size,
    required this.child,
  });
  final double progress;
  final Widget previous, child;
  final Size previousSize, size;
  @override
  Widget build(BuildContext context) {
    final height = previousSize.height > size.height
        ? previousSize.height
        : size.height;
    final seam = height * progress;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: size.width,
          height: size.height,
          child: ClipRect(
            clipper: _ViewportClip(Rect.fromLTRB(0, 0, size.width, seam)),
            child: child,
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          width: previousSize.width,
          height: previousSize.height,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: SelectionContainer.disabled(
                child: ClipRect(
                  clipper: _ViewportClip(
                    Rect.fromLTRB(
                      0,
                      seam.clamp(0, previousSize.height),
                      previousSize.width,
                      previousSize.height,
                    ),
                  ),
                  child: previous,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Paint-only viewport interpolation. Pagination always sees the final size,
/// so opening controls never shapes a chapter on every animation tick.
class ReaderIncrementalViewport extends StatelessWidget {
  const ReaderIncrementalViewport({
    super.key,
    required this.animation,
    required this.fromSize,
    required this.toSize,
    required this.originDelta,
    required this.child,
    this.horizontalOverflow = 0,
  });
  final Animation<double> animation;
  final Size fromSize, toSize;
  final Offset originDelta;
  final Widget child;
  final double horizontalOverflow;
  Rect viewportAt(double value) {
    final t = Curves.easeOutCubic.transform(value.clamp(0, 1));
    return Offset.lerp(originDelta, Offset.zero, t)! &
        Size(
          lerpDouble(fromSize.width, toSize.width, t)!,
          lerpDouble(fromSize.height, toSize.height, t)!,
        );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final viewport = viewportAt(animation.value);
      return ClipRect(
        clipper: _ViewportClip(
          Rect.fromLTRB(
            (viewport.left > 0 ? 0 : viewport.left) - horizontalOverflow,
            viewport.top > 0 ? 0 : viewport.top,
            viewport.right + horizontalOverflow,
            viewport.bottom,
          ),
        ),
        child: Transform.translate(offset: viewport.topLeft, child: child),
      );
    },
  );
}

class _ViewportClip extends CustomClipper<Rect> {
  const _ViewportClip(this.rect);
  final Rect rect;
  @override
  Rect getClip(Size size) => rect;
  @override
  bool shouldReclip(_ViewportClip oldClipper) => oldClipper.rect != rect;
}

/// Entering and departing rows inherit the nearest retained row's trajectory.
/// Newly exposed text therefore comes from outside the old reading window,
/// instead of appearing underneath lines that have not moved out of its way.
class _LineReflowPlan {
  _LineReflowPlan(ReaderReflowScope scope) {
    List<({(int, int, int) key, Offset at})> flatten(ReaderLeaf page) => [
      for (final fragment in page.fragments)
        for (final line in fragment.lines)
          (
            key: (fragment.paragraph, line.start, line.end),
            at: fragment.rect.topLeft + Offset(0, line.top),
          ),
    ];
    final before = flatten(scope.previous),
        after = flatten(scope.current ?? scope.previous);
    final oldByKey = {for (final row in before) row.key: row.at};
    final newByKey = {for (final row in after) row.key: row.at};
    incoming = _nearest([
      for (final row in after)
        oldByKey.containsKey(row.key)
            ? scope.originDelta + oldByKey[row.key]! - row.at
            : null,
    ]);
    outgoing = _nearest([
      for (final row in before)
        newByKey.containsKey(row.key)
            ? scope.originDelta + row.at - newByKey[row.key]!
            : null,
    ]);
  }
  late final List<Offset> incoming, outgoing;
  static List<Offset> _nearest(List<Offset?> rows) {
    final next = List<int>.filled(rows.length, -1);
    var nearest = -1;
    for (var i = rows.length - 1; i >= 0; i--) {
      if (rows[i] != null) nearest = i;
      next[i] = nearest;
    }
    var previous = -1;
    return [
      for (var i = 0; i < rows.length; i++)
        (() {
          if (rows[i] != null) {
            previous = i;
            return rows[i]!;
          }
          final following = next[i];
          final at =
              previous >= 0 && (following < 0 || i - previous <= following - i)
              ? previous
              : following;
          return at < 0 ? Offset.zero : rows[at]!;
        })(),
    ];
  }
}

class _ReaderLineMotion extends MultiChildRenderObjectWidget {
  _ReaderLineMotion({
    required this.scope,
    required this.fragment,
    required Widget child,
    this.previous,
    Widget? previousChild,
  }) : super(
         children: [
           child,
           if (previousChild != null)
             IgnorePointer(
               child: ExcludeSemantics(
                 child: SelectionContainer.disabled(child: previousChild),
               ),
             ),
         ],
       );
  final ReaderReflowScope scope;
  final ReaderPageFragment fragment;
  final ReaderPageFragment? previous;

  @override
  RenderReaderLineMotion createRenderObject(BuildContext context) =>
      RenderReaderLineMotion._(this);
  @override
  void updateRenderObject(
    BuildContext context,
    RenderReaderLineMotion object,
  ) => object._update(this);
}

/// Shapes each paragraph once, then moves its existing ink in line-sized bands.
/// Reflow neither splits Text into one widget per line nor relayouts on ticks:
/// justification, rich spans, selection offsets and ruby keep their native text.
class RenderReaderLineMotion extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  RenderReaderLineMotion._(_ReaderLineMotion config) : _config = config {
    _prepare();
  }
  _ReaderLineMotion _config;
  late List<ReaderPageLine> _lines, _oldLines;
  late Map<(int, int), int> _oldBySource;
  late List<int> _departingOld;
  late int _rank, _count, _oldRank, _oldCount;
  ReaderReflowScope get _scope => _config.scope;
  // Start at the leading edge of travel. Rows moving down settle bottom-first;
  // rows moving up settle top-first, so their ink never overtakes the next row.
  bool get _reverse => (_scope._linePlan.incoming.firstOrNull?.dy ?? 0) < 0;

  @visibleForTesting
  double debugLineProgress(int index) =>
      _scope.progressFor(_rank + index, _count, reverse: _reverse);
  @visibleForTesting
  Offset debugLineDisplacement(int index) {
    final p = debugLineProgress(index);
    return _scope._linePlan.incoming[_rank + index] * (1 - p);
  }

  void _prepare() {
    _lines = _config.fragment.lines.toList(growable: false);
    _oldLines = _config.previous?.lines.toList(growable: false) ?? const [];
    _oldBySource = {
      for (var i = 0; i < _oldLines.length; i++)
        (_oldLines[i].start, _oldLines[i].end): i,
    };
    final current = {for (final line in _lines) (line.start, line.end)};
    _departingOld = [
      for (var i = 0; i < _oldLines.length; i++)
        if (!current.contains((_oldLines[i].start, _oldLines[i].end))) i,
    ];
    _rank = _scope.lineIndex(_config.fragment);
    _count = _scope.lineCount();
    _oldRank = _config.previous == null
        ? 0
        : _scope.lineIndex(_config.previous!, departing: true);
    _oldCount = _scope.lineCount(departing: true);
  }

  void _update(_ReaderLineMotion value) {
    final clock = _scope.animation;
    if (attached && clock != value.scope.animation) {
      clock.removeListener(markNeedsPaint);
      value.scope.animation.addListener(markNeedsPaint);
    }
    _config = value;
    _prepare();
    markNeedsLayout();
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scope.animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _scope.animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _LineParentData();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_config.fragment.rect.size);
  @override
  void performLayout() {
    size = computeDryLayout(constraints);
    firstChild!.layout(BoxConstraints.tight(size));
    if (childCount > 1) {
      lastChild!.layout(BoxConstraints.tight(_config.previous!.rect.size));
    }
  }

  @override
  Rect get paintBounds {
    var bounds = Offset.zero & size;
    if (_config.previous case final old?) {
      bounds = bounds.expandToInclude(
        (_scope.originDelta +
                old.rect.topLeft -
                _config.fragment.rect.topLeft) &
            old.rect.size,
      );
    }
    return bounds.inflate(24);
  }

  Rect _band(List<ReaderPageLine> lines, int i, double width) => Rect.fromLTRB(
    -8,
    i == 0 ? -24 : lines[i].top,
    width + 8,
    lines[i].top + lines[i].height + (i == lines.length - 1 ? 4 : 0),
  );
  void _paintBand(
    PaintingContext context,
    RenderBox child,
    Offset offset,
    Rect clip, {
    double opacity = 1,
  }) {
    if (clip.isEmpty || opacity <= 0) return;
    context.pushClipRect(needsCompositing, offset, clip, (context, at) {
      if (opacity >= 1) {
        context.paintChild(child, at);
      } else {
        context.pushOpacity(at, (255 * opacity).round(), (context, at) {
          context.paintChild(child, at);
        });
      }
    });
  }

  void _depart(
    PaintingContext context,
    RenderBox child,
    Offset origin,
    List<ReaderPageLine> lines,
    int i,
    int rank,
    int count,
  ) {
    final p = _scope.progressFor(rank + i, count, reverse: _reverse);
    if (p >= 1) return;
    final box = _band(lines, i, child.size.width);
    _paintBand(
      context,
      child,
      origin - _scope._linePlan.outgoing[rank + i] * p,
      box,
      opacity: 1 - p,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = firstChild!;
    if (_scope.animation.value >= 1) {
      context.paintChild(child, offset);
      return;
    }
    final oldChild = childCount > 1 ? lastChild : null;
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i], p = debugLineProgress(i);
      final band = _band(_lines, i, size.width);
      final oldIndex = _oldBySource[(line.start, line.end)];
      final origin = offset + debugLineDisplacement(i);
      if (oldIndex == null) {
        _paintBand(context, child, origin, band, opacity: p);
        continue;
      }
      if (oldChild == null) {
        _paintBand(context, child, origin, band);
        continue;
      }
      final before = _oldLines[oldIndex];
      final delta = line.top - before.top;
      final oldBand = _band(_oldLines, oldIndex, oldChild.size.width);
      final owned = band.expandToInclude(oldBand.shift(Offset(0, delta)));
      final seam = lerpDouble(owned.top, owned.bottom, p)!;
      _paintBand(
        context,
        child,
        origin,
        band.intersect(Rect.fromLTRB(owned.left, owned.top, owned.right, seam)),
      );
      _paintBand(
        context,
        oldChild,
        origin + Offset(0, delta),
        oldBand.intersect(
          Rect.fromLTRB(
            owned.left,
            seam - delta,
            owned.right,
            owned.bottom - delta,
          ),
        ),
      );
    }
    if (oldChild != null) {
      final origin =
          offset +
          _scope.originDelta +
          _config.previous!.rect.topLeft -
          _config.fragment.rect.topLeft;
      for (final i in _departingOld) {
        _depart(context, oldChild, origin, _oldLines, i, _oldRank, _oldCount);
      }
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (var i = 0; i < _lines.length; i++) {
      final shift = debugLineDisplacement(i);
      if (!_band(_lines, i, size.width).shift(shift).contains(position)) {
        continue;
      }
      if (result.addWithPaintOffset(
        offset: shift,
        position: position,
        hitTest: (result, point) =>
            firstChild!.hitTest(result, position: point),
      )) {
        return true;
      }
    }
    return false;
  }
}

class _LineParentData extends ContainerBoxParentData<RenderBox> {}
