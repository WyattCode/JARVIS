import 'package:flutter/material.dart';

/// A quiet edge cue, removed as soon as the remaining content is reached.
class ScrollAffordance extends StatefulWidget {
  const ScrollAffordance({
    super.key,
    required this.enabled,
    required this.child,
  });
  final bool enabled;
  final Widget child;
  @override
  State<ScrollAffordance> createState() => _ScrollAffordanceState();
}

class _ScrollAffordanceState extends State<ScrollAffordance> {
  bool more = true, scheduled = false, next = true;
  void sync(ScrollMetrics metrics) {
    next = metrics.extentAfter > 2;
    if (scheduled || next == more) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (mounted && next != more) setState(() => more = next);
    });
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) {
          if (n.depth == 0) sync(n.metrics);
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.depth == 0) sync(n.metrics);
            return false;
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (widget.enabled && more)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 24,
                  child: ExcludeSemantics(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        key: const Key('welcome-more-cue'),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Theme.of(context).colorScheme.surface
                                  .withValues(alpha: 0),
                              Theme.of(context).colorScheme.surface
                                  .withValues(alpha: .94),
                            ],
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            size: 16,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}
