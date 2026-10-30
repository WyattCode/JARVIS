import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Width of the grip's hit area, which lies over the left edge of the content beside the docked list.
const sidebarGripWidth = 24.0;

/// A sideways drag that lets any other sideways drag under the same finger go first. When the finger has moved far
/// enough to count as a drag, every horizontal recognizer under it claims the gesture on that same move; this one holds
/// back its claim until the next move. A horizontal scroll view under the finger has claimed it by then and wins; with
/// nothing that scrolls sideways under it (the vertical message list only claims vertical moves) this one takes the
/// drag a move later.
class _YieldingDragRecognizer extends HorizontalDragGestureRecognizer {
  _YieldingDragRecognizer({super.debugOwner});

  /// The pointer whose first claim was held back.
  int? _deferred;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _deferred = null;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && _deferred == event.pointer) {
      // The move after the held-back claim: claim it now (the drag's own handling does so again; that is harmless).
      _deferred = -1;
      super.resolve(GestureDisposition.accepted);
    }
    super.handleEvent(event);
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted && _deferred == null) {
      _deferred = _pointer;
      return;
    }
    super.resolve(disposition);
  }

  int? _pointer;

  @override
  void addPointer(PointerDownEvent event) {
    _pointer = event.pointer;
    super.addPointer(event);
  }
}

class _SetSidebarIntent extends Intent {
  const _SetSidebarIntent(this.visible);
  final bool visible;
}

/// A small grip reveals the navigation pane without drawing a full divider.
/// Dragging follows the finger; release snaps to either end, like a drawer.
class SidebarSplit extends StatefulWidget {
  const SidebarSplit({
    super.key,
    required this.width,
    required this.visible,
    required this.duration,
    required this.onChanged,
    required this.child,
    required this.content,
  });
  final double width;
  final bool visible;
  final Duration duration;
  final ValueChanged<bool> onChanged;
  final Widget child, content;

  @override
  State<SidebarSplit> createState() => _SidebarSplitState();
}

class _SidebarSplitState extends State<SidebarSplit>
    with SingleTickerProviderStateMixin {
  late final motion = AnimationController(
    vsync: this,
    value: widget.visible ? 1 : 0,
    duration: widget.duration,
  );
  bool dragging = false;
  bool focused = false;

  /// The grip's transparent hit area lies over the messages when the pane is open, so it is kept narrow: wider would
  /// swallow taps and text selection at the left edge of the chat.
  static const gripWidth = sidebarGripWidth;

  /// Extra drag-only reach beside the grip, so its touch area is [gripWidth] + this = 44 pt.
  static const gripReach = 20.0;
  final gripKey = GlobalKey();
  static const layoutChannel = MethodChannel('ai.jarvis.app/layout');
  bool exclusionScheduled = false;
  List<int>? lastExclusion;

  Future<void> sendExclusion(List<int> rect) async {
    try {
      await layoutChannel.invokeMethod<void>('gripExclusion', rect);
    } on MissingPluginException {
      // Other platforms and widget tests have no Android window.
    } on PlatformException {
      // The menu remains available if the platform cannot set an exclusion.
    }
  }

  void syncExclusion() {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        exclusionScheduled) {
      return;
    }
    exclusionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      exclusionScheduled = false;
      if (!mounted) return;
      final box = gripKey.currentContext?.findRenderObject() as RenderBox?;
      final enabled =
          motion.value == 0 &&
          TickerMode.valuesOf(context).enabled &&
          ModalRoute.of(context)?.isCurrent != false &&
          box != null &&
          box.hasSize;
      final scale = MediaQuery.devicePixelRatioOf(context);
      final origin = enabled ? box.localToGlobal(Offset.zero) : Offset.zero;
      final rect = enabled
          ? <int>[
              (origin.dx * scale).round(),
              (origin.dy * scale).round(),
              ((origin.dx + box.size.width) * scale).round(),
              ((origin.dy + box.size.height) * scale).round(),
            ]
          : <int>[];
      if (!listEquals(lastExclusion, rect)) {
        lastExclusion = rect;
        unawaited(sendExclusion(rect));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to route/ticker changes so other pages retain normal Back.
    ModalRoute.of(context);
    TickerMode.valuesOf(context).enabled;
    syncExclusion();
  }

  void settle(bool visible) {
    if (widget.duration == Duration.zero) {
      motion.value = visible ? 1 : 0;
    } else {
      motion.animateTo(visible ? 1 : 0, curve: Curves.easeOutCubic);
    }
  }

  @override
  void didUpdateWidget(SidebarSplit oldWidget) {
    super.didUpdateWidget(oldWidget);
    motion.duration = widget.duration;
    if (oldWidget.visible != widget.visible ||
        oldWidget.width != widget.width ||
        oldWidget.duration != widget.duration) {
      dragging = false;
      settle(widget.visible);
    }
  }

  void finish(bool visible) {
    setState(() => dragging = false);
    settle(visible);
    widget.onChanged(visible);
  }

  void dragStart(DragStartDetails _) {
    motion.stop();
    setState(() => dragging = true);
  }

  void dragUpdate(DragUpdateDetails event) {
    motion.value = (motion.value + event.delta.dx / widget.width).clamp(
      0.0,
      1.0,
    );
  }

  void dragEnd(DragEndDetails event) {
    final velocity = event.primaryVelocity ?? 0;
    finish(velocity.abs() > 300 ? velocity > 0 : motion.value >= .5);
  }

  void dragCancel() {
    setState(() => dragging = false);
    settle(widget.visible);
  }

  @override
  void dispose() {
    unawaited(sendExclusion([]));
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: motion,
    builder: (context, _) {
      syncExclusion();
      return Stack(
        fit: StackFit.expand,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeFocus(
                excluding: !widget.visible || dragging || motion.value < 1,
                child: ExcludeSemantics(
                  excluding: !widget.visible || dragging || motion.value < 1,
                  child: IgnorePointer(
                    ignoring: !widget.visible || dragging || motion.value < 1,
                    child: ClipRect(
                      child: SizedBox(
                        key: const Key('docked-sidebar'),
                        width: widget.width * motion.value,
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          minWidth: widget.width,
                          maxWidth: widget.width,
                          child: Material(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerLow
                                : Theme.of(context).colorScheme.surface,
                            child: widget.child,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: SizedBox(
                  key: const Key('split-content'),
                  child: widget.content,
                ),
              ),
            ],
          ),
          Positioned(
            left: widget.width * motion.value,
            top: 0,
            bottom: 0,
            width: gripWidth,
            child: Center(
              child: FocusableActionDetector(
                key: gripKey,
                mouseCursor: SystemMouseCursors.resizeLeftRight,
                onShowFocusHighlight: (value) =>
                    setState(() => focused = value),
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.arrowLeft):
                      _SetSidebarIntent(false),
                  SingleActivator(LogicalKeyboardKey.arrowRight):
                      _SetSidebarIntent(true),
                },
                actions: {
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      finish(!widget.visible);
                      return null;
                    },
                  ),
                  _SetSidebarIntent: CallbackAction<_SetSidebarIntent>(
                    onInvoke: (intent) {
                      finish(intent.visible);
                      return null;
                    },
                  ),
                },
                child: Semantics(
                  button: true,
                  label: widget.visible ? '收起会话侧栏' : '展开会话侧栏',
                  hint: '也可左右拖动',
                  onTap: () => finish(!widget.visible),
                  child: GestureDetector(
                    key: const Key('pane-grip'),
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTap: () => finish(!widget.visible),
                    onHorizontalDragStart: dragStart,
                    onHorizontalDragUpdate: dragUpdate,
                    onHorizontalDragEnd: dragEnd,
                    onHorizontalDragCancel: dragCancel,
                    child: SizedBox(
                      width: gripWidth,
                      height: 80,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: Container(
                            key: const Key('pane-grip-thumb'),
                            width: 4,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant
                                  .withValues(
                                    alpha: dragging || focused ? .8 : .4,
                                  ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // A finger needs 44 pt: the grip's touch area goes on 20 pt past its visible 24 pt, for dragging only. It is
          // translucent and has no tap, so a tap beside the grip still reaches the messages under it. It lies over the
          // messages, so it gives way to anything under it that scrolls sideways (a code block, a wide table): see
          // [_YieldingDragRecognizer].
          Positioned(
            left: widget.width * motion.value + gripWidth,
            top: 0,
            bottom: 0,
            width: gripReach,
            child: Center(
              child: RawGestureDetector(
                key: const Key('pane-grip-reach'),
                behavior: HitTestBehavior.translucent,
                excludeFromSemantics: true,
                gestures: {
                  _YieldingDragRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        _YieldingDragRecognizer
                      >(
                        () => _YieldingDragRecognizer(debugOwner: this),
                        // The same touch slop as the scroll views it gives way to, so both see the drag begin on
                        // the same move.
                        (r) => r
                          ..gestureSettings = MediaQuery.maybeGestureSettingsOf(
                            context,
                          )
                          ..onStart = dragStart
                          ..onUpdate = dragUpdate
                          ..onEnd = dragEnd
                          ..onCancel = dragCancel,
                      ),
                },
                child: const SizedBox(width: gripReach, height: 80),
              ),
            ),
          ),
        ],
      );
    },
  );
}
