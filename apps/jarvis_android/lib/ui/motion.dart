import 'package:flutter/widgets.dart';

/// Length of a UI transition; zero when the system asks to reduce motion.
Duration motion(BuildContext context, [int milliseconds = 200]) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

/// Fade plus a slight grow: how small controls appear and disappear.
Widget popTransition(Widget child, Animation<double> animation) =>
    FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: .85, end: 1).animate(animation),
        child: child,
      ),
    );

/// [AnimatedSize] that steps aside when motion is reduced: with a zero duration it would resize inside its own layout
/// pass, which Flutter rejects.
class SmoothSize extends StatelessWidget {
  const SmoothSize({
    super.key,
    this.milliseconds = 200,
    this.alignment = Alignment.center,
    required this.child,
  });
  final int milliseconds;
  final AlignmentGeometry alignment;
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
            child: child,
          );
  }
}
