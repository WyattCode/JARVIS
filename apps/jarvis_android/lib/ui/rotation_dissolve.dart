import 'package:flutter/material.dart';

/// Turning the phone swaps the whole layout at once (the rail changes sides, the composer reflows). The system turns
/// a picture of the old layout while that happens, so the new one would pop in at the end; here it dissolves in
/// instead. Only a change of orientation counts: the keyboard, a text size change or a fold do not.
class RotationDissolve extends StatefulWidget {
  const RotationDissolve({super.key, required this.child});
  final Widget child;

  /// How long the new layout takes to appear.
  static const duration = Duration(milliseconds: 260);

  /// Whether going from [before] to [after] is a turn between portrait and landscape.
  static bool turned(Size before, Size after) =>
      (before.width > before.height) != (after.width > after.height);

  @override
  State<RotationDissolve> createState() => _RotationDissolveState();
}

class _RotationDissolveState extends State<RotationDissolve>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: RotationDissolve.duration,
    value: 1,
  );
  Size? last;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    final before = last;
    last = size;
    if (before != null &&
        RotationDissolve.turned(before, size) &&
        !MediaQuery.disableAnimationsOf(context)) {
      controller.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: widget.child,
    builder: (context, child) => controller.isCompleted
        ? child!
        // The new layout rises out of the app's own background, so nothing else shows through while it is not there yet.
        : ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Opacity(
              opacity: Curves.easeOut.transform(controller.value),
              child: child,
            ),
          ),
  );
}
