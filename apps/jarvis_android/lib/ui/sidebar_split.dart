import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  final gripKey = GlobalKey();
  static const layoutChannel = MethodChannel('cc.odn.jarvis/layout');
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
            width: 48,
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
                    onHorizontalDragStart: (_) {
                      motion.stop();
                      setState(() => dragging = true);
                    },
                    onHorizontalDragUpdate: (event) {
                      motion.value =
                          (motion.value + event.delta.dx / widget.width).clamp(
                            0.0,
                            1.0,
                          );
                    },
                    onHorizontalDragEnd: (event) {
                      final velocity = event.primaryVelocity ?? 0;
                      finish(
                        velocity.abs() > 300
                            ? velocity > 0
                            : motion.value >= .5,
                      );
                    },
                    onHorizontalDragCancel: () {
                      setState(() => dragging = false);
                      settle(widget.visible);
                    },
                    child: SizedBox(
                      width: 48,
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
        ],
      );
    },
  );
}
