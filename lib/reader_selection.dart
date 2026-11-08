import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';

class ReaderQuoteRange {
  const ReaderQuoteRange(
    this.paragraph,
    this.start,
    this.end, {
    this.chapter,
  });
  final int paragraph;
  final int start;
  final int end;
  final int? chapter;
}

class ReaderQuoteSelection {
  const ReaderQuoteSelection({
    required this.text,
    required this.paragraph,
    required this.start,
    required this.end,
    this.ranges = const [],
  });
  final String text;
  final int paragraph;
  final int start;
  final int end;
  final List<ReaderQuoteRange> ranges;
}

class ReaderSelectionController extends ValueNotifier<bool> {
  ReaderSelectionController() : super(false);
  VoidCallback? _clear;
  final _fragments = <_ReaderSelectionFragmentState>{};

  void clear() => _clear?.call();

  ReaderQuoteSelection? get selectedQuote => _selected();

  /// Returns the paragraph index and UTF-16 character offset if [globalPosition]
  /// lands directly on a laid-out character glyph box.
  ({int paragraph, int offset})? hitOffsetAt(Offset globalPosition) {
    for (final fragment in _fragments) {
      final hit = fragment._hitOffsetAt(globalPosition);
      if (hit != null) return hit;
    }
    return null;
  }

  ReaderQuoteSelection? _selected() {
    final ranges =
        [
          for (final fragment in _fragments)
            if (fragment._selectedRange() case final selected?) selected,
        ]..sort((a, b) {
          final chapter = (a.$1.chapter ?? -1).compareTo(b.$1.chapter ?? -1);
          if (chapter != 0) return chapter;
          final paragraph = a.$1.paragraph.compareTo(b.$1.paragraph);
          return paragraph != 0 ? paragraph : a.$1.start.compareTo(b.$1.start);
        });
    if (ranges.isEmpty) return null;
    final merged = <(ReaderQuoteRange, String)>[];
    for (final current in ranges) {
      final last = merged.lastOrNull;
      if (last != null &&
          last.$1.chapter == current.$1.chapter &&
          last.$1.paragraph == current.$1.paragraph &&
          last.$1.end >= current.$1.start) {
        final extra = current.$1.end <= last.$1.end
            ? ''
            : current.$2.substring(last.$1.end - current.$1.start);
        merged[merged.length - 1] = (
          ReaderQuoteRange(
            last.$1.paragraph,
            last.$1.start,
            math.max(last.$1.end, current.$1.end),
            chapter: last.$1.chapter,
          ),
          '${last.$2}$extra',
        );
      } else {
        merged.add(current);
      }
    }
    final buffer = StringBuffer();
    for (var i = 0; i < merged.length; i++) {
      if (i > 0 &&
          (merged[i - 1].$1.chapter != merged[i].$1.chapter ||
              merged[i - 1].$1.paragraph != merged[i].$1.paragraph)) {
        buffer.write('\n');
      }
      buffer.write(merged[i].$2);
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) return null;
    final first = merged.first.$1;
    final last = merged.last.$1;
    return ReaderQuoteSelection(
      text: text,
      paragraph: first.paragraph,
      start: first.start,
      end: last.end,
      ranges: [for (final item in merged) item.$1],
    );
  }
}

class _ReaderSelectionScope extends InheritedWidget {
  const _ReaderSelectionScope({
    required this.controller,
    required super.child,
  });
  final ReaderSelectionController controller;

  static ReaderSelectionController? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_ReaderSelectionScope>()
          ?.controller;

  @override
  bool updateShouldNotify(_ReaderSelectionScope oldWidget) =>
      controller != oldWidget.controller;
}

class ReaderSelection extends StatefulWidget {
  const ReaderSelection({
    super.key,
    this.controller,
    this.onUnderline,
    this.onCopy,
    this.onAnnotate,
    this.onBookmark,
    this.onPurify,
    required this.child,
  });
  final ReaderSelectionController? controller;
  final ValueChanged<ReaderQuoteSelection>? onUnderline;
  final ValueChanged<ReaderQuoteSelection>? onCopy;
  final ValueChanged<ReaderQuoteSelection>? onAnnotate;
  final ValueChanged<ReaderQuoteSelection>? onBookmark;
  final ValueChanged<ReaderQuoteSelection>? onPurify;
  final Widget child;

  @override
  State<ReaderSelection> createState() => _ReaderSelectionState();
}

class _ReaderSelectionState extends State<ReaderSelection> {
  final _area = GlobalKey<SelectionAreaState>();
  final _focus = FocusNode(debugLabel: 'reader selection');
  final _controls = _ReaderHandleControls();
  ReaderSelectionController? _owned;
  SelectedContent? _content;
  ReaderSelectionController get _controller => widget.controller ?? _owned!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _owned = ReaderSelectionController();
    _bind(_controller);
  }

  @override
  void didUpdateWidget(ReaderSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._clear = null;
      _owned?.dispose();
      _owned = widget.controller == null ? ReaderSelectionController() : null;
      _bind(_controller);
    }
  }

  void _bind(ReaderSelectionController controller) {
    controller._clear = _clear;
    controller.value = (_content?.plainText.trim().isNotEmpty ?? false);
  }

  void _clear() {
    _area.currentState?.selectableRegion.clearSelection();
    _area.currentState?.selectableRegion.hideToolbar();
    if ((_content?.plainText.isNotEmpty ?? false) && mounted) {
      setState(() => _content = null);
    }
    _controller.value = false;
  }

  @override
  void dispose() {
    _controller._clear = null;
    _owned?.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _ReaderSelectionScope(
      controller: _controller,
      child: DefaultSelectionStyle(
        selectionColor: scheme.onSurface.withValues(alpha: dark ? .20 : .13),
        cursorColor: scheme.onSurface.withValues(alpha: dark ? .78 : .68),
        child: SelectionArea(
          key: _area,
          focusNode: _focus,
          selectionControls: _controls,
          onSelectionChanged: (content) {
            _content = content;
            _controller.value = (content?.plainText.trim().isNotEmpty ?? false);
          },
          contextMenuBuilder: (context, state) {
            final quote = _controller._selected();
            if (quote == null) return const SizedBox.shrink();
            return CustomSingleChildLayout(
              delegate: _ToolbarPosition(
                anchor:
                    state.contextMenuAnchors.secondaryAnchor ??
                    state.contextMenuAnchors.primaryAnchor,
                padding: MediaQuery.paddingOf(context),
              ),
              child: _ReaderSelectionBar(
                onUnderline: widget.onUnderline == null
                    ? null
                    : () {
                        final selected = _controller._selected() ?? quote;
                        _clear();
                        widget.onUnderline!(selected);
                      },
                onCopy: () {
                  final selected = _controller._selected() ?? quote;
                  unawaited(Clipboard.setData(ClipboardData(text: selected.text)));
                  _clear();
                  if (widget.onCopy != null) {
                    widget.onCopy!(selected);
                  } else {
                    showNovelFeedback(context, '已复制选中内容');
                  }
                },
                onAnnotate: widget.onAnnotate == null
                    ? null
                    : () {
                        final selected = _controller._selected() ?? quote;
                        _clear();
                        widget.onAnnotate!(selected);
                      },
                onBookmark: widget.onBookmark == null
                    ? null
                    : () {
                        final selected = _controller._selected() ?? quote;
                        _clear();
                        widget.onBookmark!(selected);
                      },
                onPurify: widget.onPurify == null
                    ? null
                    : () {
                        final selected = _controller._selected() ?? quote;
                        _clear();
                        widget.onPurify!(selected);
                      },
              ),
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

class _ReaderSelectionBar extends StatelessWidget {
  const _ReaderSelectionBar({
    this.onUnderline,
    required this.onCopy,
    this.onAnnotate,
    this.onBookmark,
    this.onPurify,
  });
  final VoidCallback? onUnderline;
  final VoidCallback onCopy;
  final VoidCallback? onAnnotate;
  final VoidCallback? onBookmark;
  final VoidCallback? onPurify;

  @override
  Widget build(BuildContext context) {
    final actions = <(Key, String, VoidCallback)>[
      if (onUnderline != null)
        (const ValueKey('reader-selection-underline'), '划线', onUnderline!),
      (const ValueKey('reader-selection-copy'), '复制', onCopy),
      if (onAnnotate != null)
        (const ValueKey('reader-selection-annotate'), '批注', onAnnotate!),
      if (onBookmark != null)
        (const ValueKey('reader-selection-bookmark'), '书签', onBookmark!),
      if (onPurify != null)
        (const ValueKey('reader-selection-purify'), '净化', onPurify!),
    ];
    return Material(
      type: MaterialType.transparency,
      child: GlassPane(
        key: const ValueKey('reader-selection-toolbar'),
        borderRadius: BorderRadius.circular(18),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        blur: 16,
        opacity: .88,
        lift: 10,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) _divider(context),
              _item(
                context,
                key: actions[i].$1,
                label: actions[i].$2,
                onTap: actions[i].$3,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _divider(BuildContext context) => Container(
    width: 1,
    height: 16,
    color: Theme.of(context).dividerColor.withValues(alpha: .55),
  );

  Widget _item(
    BuildContext context, {
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) => JellyTapSurface(
    key: key,
    borderRadius: BorderRadius.circular(12),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class _ToolbarPosition extends SingleChildLayoutDelegate {
  const _ToolbarPosition({required this.anchor, required this.padding});
  final Offset anchor;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = (anchor.dx - childSize.width / 2).clamp(
      14.0 + padding.left,
      math.max(14.0 + padding.left, size.width - childSize.width - 14.0),
    );
    final above = anchor.dy - childSize.height - 16;
    final top = above >= padding.top + 64
        ? above
        : (anchor.dy + 22).clamp(
            padding.top + 12,
            math.max(
              padding.top + 12,
              size.height - childSize.height - padding.bottom - 16,
            ),
          );
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_ToolbarPosition oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}

class _ReaderHandleControls extends TextSelectionControls {
  static const _radius = 5.5;
  static const _stem = 16.0;

  @override
  Size getHandleSize(double textLineHeight) =>
      const Size(_radius * 2 + 8, _stem + _radius * 2 + 6);

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) =>
      switch (type) {
        TextSelectionHandleType.left => const Offset(
          _radius + 4,
          _radius * 2 + _stem,
        ),
        TextSelectionHandleType.right => const Offset(_radius + 4, 2),
        TextSelectionHandleType.collapsed => const Offset(_radius + 4, 2),
      };

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) {
    if (type == TextSelectionHandleType.collapsed) {
      return const SizedBox.shrink();
    }
    final color = Theme.of(context).colorScheme.onSurface;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTap,
      child: SizedBox.fromSize(
        size: getHandleSize(textLineHeight),
        child: CustomPaint(painter: _HandlePainter(color: color, type: type)),
      ),
    );
  }

  @override
  Widget buildToolbar(
    BuildContext context,
    Rect globalEditableRegion,
    double textLineHeight,
    Offset selectionMidpoint,
    List<TextSelectionPoint> endpoints,
    TextSelectionDelegate delegate,
    ValueListenable<ClipboardStatus>? clipboardStatus,
    Offset? lastSecondaryTapDownPosition,
  ) => const SizedBox.shrink();
}

class _HandlePainter extends CustomPainter {
  const _HandlePainter({required this.color, required this.type});
  final Color color;
  final TextSelectionHandleType type;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: .78)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final x = size.width / 2;
    if (type == TextSelectionHandleType.left) {
      canvas.drawCircle(const Offset(9.5, 6.5), 4.5, paint);
      canvas.drawLine(
        const Offset(9.5, 10),
        Offset(x, size.height - 4),
        paint,
      );
    } else {
      canvas.drawLine(
        const Offset(9.5, 2),
        Offset(x, size.height - 11),
        paint,
      );
      canvas.drawCircle(Offset(x, size.height - 6.5), 4.5, paint);
    }
  }

  @override
  bool shouldRepaint(_HandlePainter oldDelegate) =>
      color != oldDelegate.color || type != oldDelegate.type;
}

class ReaderSelectionFragment extends StatefulWidget {
  const ReaderSelectionFragment({
    super.key,
    this.controller,
    this.paragraph = 0,
    this.chapter,
    this.baseOffset = 0,
    this.leadingPlaceholders = 0,
    required this.text,
    this.anchorForOffset,
    required this.child,
  });
  final ReaderSelectionController? controller;
  final int paragraph;
  final int? chapter;
  final int baseOffset;
  final int leadingPlaceholders;
  final String text;
  final ({int paragraph, int offset})? Function(int offset)? anchorForOffset;
  final Widget child;

  @override
  State<ReaderSelectionFragment> createState() =>
      _ReaderSelectionFragmentState();
}

class _ReaderSelectionFragmentState extends State<ReaderSelectionFragment> {
  _SentenceSelectable? _selectable;
  ReaderSelectionController? _registeredController;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = widget.controller ?? _ReaderSelectionScope.maybeOf(context);
    if (_registeredController != next) {
      _registeredController?._fragments.remove(this);
      _registeredController = next;
      _registeredController?._fragments.add(this);
    }
  }

  @override
  void didUpdateWidget(ReaderSelectionFragment oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.controller ?? _ReaderSelectionScope.maybeOf(context);
    if (_registeredController != next) {
      _registeredController?._fragments.remove(this);
      _registeredController = next;
      _registeredController?._fragments.add(this);
    }
    _selectable?._update(widget.text, widget.leadingPlaceholders);
  }

  @override
  void dispose() {
    _registeredController?._fragments.remove(this);
    _registeredController = null;
    _selectable?.dispose();
    super.dispose();
  }

  RenderParagraph? _findRenderParagraph(RenderObject? root) {
    if (root is RenderParagraph) return root;
    RenderParagraph? found;
    root?.visitChildren((child) {
      found ??= _findRenderParagraph(child);
    });
    return found;
  }

  ({int paragraph, int offset})? _hitOffsetAt(Offset globalPosition) {
    if (!mounted || widget.text.isEmpty) return null;
    final renderParagraph = _findRenderParagraph(context.findRenderObject());
    if (renderParagraph == null ||
        !renderParagraph.attached ||
        !renderParagraph.hasSize) {
      return null;
    }
    final local = renderParagraph.globalToLocal(globalPosition);
    if (!(Offset.zero & renderParagraph.size).inflate(4).contains(local)) {
      return null;
    }
    final pos = renderParagraph.getPositionForOffset(local);
    final rawOffset = pos.offset - widget.leadingPlaceholders;
    for (final candidate in {rawOffset, rawOffset - 1}) {
      if (candidate < 0 || candidate >= widget.text.length) continue;
      final boxes = renderParagraph.getBoxesForSelection(
        TextSelection(
          baseOffset: candidate + widget.leadingPlaceholders,
          extentOffset: candidate + 1 + widget.leadingPlaceholders,
        ),
      );
      if (boxes.any((box) => box.toRect().inflate(6).contains(local))) {
        if (widget.anchorForOffset case final resolve?) {
          return resolve(candidate);
        }
        return (
          paragraph: widget.paragraph,
          offset: widget.baseOffset + candidate,
        );
      }
    }
    return null;
  }

  (ReaderQuoteRange, String)? _selectedRange() {
    final selectable = _selectable;
    if (selectable == null) return null;
    final selection = selectable.getSelection();
    final content = selectable.getSelectedContent();
    if (selection == null || content == null || content.plainText.isEmpty) {
      return null;
    }
    final start =
        (math.min(selection.startOffset, selection.endOffset) -
                widget.leadingPlaceholders)
            .clamp(0, widget.text.length);
    final end =
        (math.max(selection.startOffset, selection.endOffset) -
                widget.leadingPlaceholders)
            .clamp(0, widget.text.length);
    if (start >= end) return null;
    final text = widget.text.substring(start, end);
    if (widget.anchorForOffset case final resolve?) {
      final first = resolve(start);
      final last = resolve(end - 1);
      if (first == null || last == null) return null;
      return (
        ReaderQuoteRange(
          first.paragraph,
          first.offset,
          last.offset + 1,
          chapter: widget.chapter,
        ),
        text,
      );
    }
    return (
      ReaderQuoteRange(
        widget.paragraph,
        widget.baseOffset + start,
        widget.baseOffset + end,
        chapter: widget.chapter,
      ),
      text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final registrar = SelectionContainer.maybeOf(context);
    if (registrar == null) return widget.child;
    return SelectionRegistrarScope(
      registrar: _SentenceRegistrar(
        parent: registrar,
        text: widget.text,
        leadingPlaceholders: widget.leadingPlaceholders,
        onChanged: (selectable) => _selectable = selectable,
      ),
      child: widget.child,
    );
  }
}

class _SentenceRegistrar extends SelectionRegistrar {
  _SentenceRegistrar({
    required this.parent,
    required this.text,
    required this.leadingPlaceholders,
    required this.onChanged,
  });
  final SelectionRegistrar parent;
  final String text;
  final int leadingPlaceholders;
  final ValueChanged<_SentenceSelectable?> onChanged;
  final _wrappers = <Selectable, _SentenceSelectable>{};

  @override
  void add(Selectable selectable) {
    final wrapper = _SentenceSelectable(
      selectable,
      text,
      leadingPlaceholders,
    );
    _wrappers[selectable] = wrapper;
    onChanged(wrapper);
    parent.add(wrapper);
  }

  @override
  void remove(Selectable selectable) {
    final wrapper = _wrappers.remove(selectable);
    if (wrapper != null) {
      onChanged(null);
      parent.remove(wrapper);
      wrapper.dispose();
    }
  }
}

class _SentenceSelectable with Selectable {
  _SentenceSelectable(this._delegate, this._text, this._leadingPlaceholders);
  final Selectable _delegate;
  String _text;
  int _leadingPlaceholders;
  bool _expandingSentence = false;

  void _update(String text, int leadingPlaceholders) {
    _text = text;
    _leadingPlaceholders = leadingPlaceholders;
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final result = _delegate.dispatchSelectionEvent(event);
    if (!_expandingSentence && event is SelectWordSelectionEvent) {
      final range = _delegate.getSelection();
      if (range != null && _text.isNotEmpty) {
        final localOffset =
            (range.startOffset - _leadingPlaceholders).clamp(0, _text.length - 1);
        final sentence = readerSentenceRange(_text, localOffset);
        return _selectRange(
          sentence.$1 + _leadingPlaceholders,
          sentence.$2 + _leadingPlaceholders,
        );
      }
    }
    return result;
  }

  SelectionResult _selectRange(int start, int end) {
    final first = _boxAt(start);
    final last = _boxAt(math.max(start, end - 1));
    if (first == null || last == null) return SelectionResult.end;
    _expandingSentence = true;
    try {
      _delegate.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forStart(
          globalPosition: localToGlobal(
            Offset(first.left + .5, first.center.dy),
          ),
        ),
      );
      return _delegate.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forEnd(
          globalPosition: localToGlobal(Offset(last.right - .5, last.center.dy)),
        ),
      );
    } finally {
      _expandingSentence = false;
    }
  }

  Rect? _boxAt(int offset) {
    final delegate = _delegate;
    if (delegate is RenderParagraph) {
      final boxes = delegate.getBoxesForSelection(
        TextSelection(baseOffset: offset, extentOffset: offset + 1),
      );
      if (boxes.isNotEmpty) return boxes.first.toRect();
    }
    return null;
  }

  @override
  void addListener(VoidCallback listener) => _delegate.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _delegate.removeListener(listener);

  @override
  SelectedContent? getSelectedContent() => _delegate.getSelectedContent();

  @override
  SelectedContentRange? getSelection() => _delegate.getSelection();

  @override
  SelectionGeometry get value => _delegate.value;

  @override
  int get contentLength => _delegate.contentLength;

  @override
  Size get size => _delegate.size;

  @override
  Rect get boundingBoxes => _delegate.boundingBoxes;

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) =>
      _delegate.getTransformTo(ancestor);

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) =>
      _delegate.pushHandleLayers(startHandle, endHandle);

  @override
  void dispose() {
    _delegate.pushHandleLayers(null, null);
  }
}

final _sentenceBreak = RegExp(r'[。！？!?；;\n]');
final _closingPunctuation = RegExp(r'''[”’」』）》】\]\)]''');

(int, int) readerSentenceRange(String text, int offset) {
  if (text.isEmpty) return (0, 0);
  final index = offset.clamp(0, text.length - 1);
  var start = 0;
  for (var i = index; i > 0; i--) {
    if (_sentenceBreak.hasMatch(text[i - 1])) {
      start = i;
      break;
    }
  }
  while (start < index && text[start].trim().isEmpty) {
    start++;
  }
  var end = text.length;
  for (var i = index; i < text.length; i++) {
    if (_sentenceBreak.hasMatch(text[i])) {
      end = i + 1;
      while (end < text.length && _closingPunctuation.hasMatch(text[end])) {
        end++;
      }
      break;
    }
  }
  return start < end ? (start, end) : (0, text.length);
}
