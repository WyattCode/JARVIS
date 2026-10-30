import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Length of a UI transition; zero when the system asks to reduce motion.
Duration motion(BuildContext context, [int milliseconds = 200]) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

/// The tick under a deliberate tap (send, new conversation, microphone); [strong] for a stop or a delete.
void tapFeedback({bool strong = false}) => unawaited(
  strong ? HapticFeedback.lightImpact() : HapticFeedback.selectionClick(),
);

/// Fade plus a slight grow: how small controls appear and disappear.
Widget popTransition(Widget child, Animation<double> animation) =>
    FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: .85, end: 1).animate(animation),
        child: child,
      ),
    );

/// [AnimatedSwitcher.layoutBuilder] for a switcher inside a [SmoothSize]: only the incoming child gives the stack its
/// size, the outgoing ones fade out on top of it without taking any room. With the default layout the stack stays as
/// large as the outgoing child until its fade ends, so the [SmoothSize] around it would wait that long before shrinking.
/// Both are anchored at [alignment] (a point of the stack, and the same point of each outgoing child).
///
/// Every child sits in the same keyed wrapper whether it is current or leaving, so the tree keeps its shape when one
/// turns into the other: the leaving child keeps its State (and its semantics node) instead of being rebuilt for its
/// fade. A leaving child takes no touches and is hidden from VoiceOver, so a live region is not read again as it goes.
Widget Function(Widget?, List<Widget>) overlayOutgoing([
  AlignmentGeometry alignment = Alignment.topCenter,
]) => (current, previous) {
  // AnimatedSwitcher can briefly hold two entries with one key (A, B, A again during A's fade): only the first keeps it.
  final keys = <Key?>{};
  Widget layer(Widget child, {required bool leaving}) => Align(
    key: keys.add(child.key) ? child.key : null,
    alignment: alignment,
    widthFactor: leaving ? 0 : 1,
    heightFactor: leaving ? 0 : 1,
    child: IgnorePointer(
      ignoring: leaving,
      child: ExcludeSemantics(excluding: leaving, child: child),
    ),
  );
  return Stack(
    alignment: alignment,
    clipBehavior: Clip.none,
    children: [
      for (final child in previous) layer(child, leaving: true),
      if (current != null) layer(current, leaving: false),
    ],
  );
};

/// [AnimatedSize] that steps aside when motion is reduced: with a zero duration it would resize inside its own layout
/// pass, which Flutter rejects.
class SmoothSize extends StatelessWidget {
  const SmoothSize({
    super.key,
    this.milliseconds = 200,
    this.alignment = Alignment.center,
    this.clipBehavior = Clip.hardEdge,
    required this.child,
  });
  final int milliseconds;
  final AlignmentGeometry alignment;

  /// [Clip.none] lets a child that is fading out (see [overlayOutgoing]) show whole while the box shrinks past it.
  final Clip clipBehavior;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final duration = motion(context, milliseconds);
    return duration == Duration.zero
        ? child
        : AnimatedSize(
            duration: duration,
            curve: Curves.easeOutCubic,
            alignment: alignment,
            clipBehavior: clipBehavior,
            child: child,
          );
  }
}
