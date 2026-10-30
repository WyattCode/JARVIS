import 'package:flutter/material.dart';

import 'duo_layout.dart';
import 'motion.dart';

/// Keeps a page's content to the roomier side of the fold while the device is half-folded in landscape, so no text or
/// control sits on the crease. Opening or closing the fold fades the content through the change (re-wrapping it frame
/// by frame would make the text churn); flat, it is a plain pass-through. The chat page does the same for its column.
///
/// The pane is taken to span the safe area's width: place it inside the page's `SafeArea`.
class HalfFoldPane extends StatefulWidget {
  const HalfFoldPane({super.key, required this.child});
  final Widget child;

  /// The narrowest side that still counts as a usable column.
  static const minimumRoom = 240.0;

  @override
  State<HalfFoldPane> createState() => _HalfFoldPaneState();
}

class _HalfFoldPaneState extends State<HalfFoldPane>
    with SingleTickerProviderStateMixin {
  /// 0 flat .. 1 half-folded; the content fades out, switches layout at the midpoint and fades back in.
  late final anim = AnimationController(vsync: this);
  bool? target;
  bool seeded = false;
  Size? lastSize;

  /// The last crease geometry, kept so the content can still fade out of it once the fold has opened.
  EdgeInsets side = EdgeInsets.zero;

  @override
  void dispose() {
    anim.dispose();
    super.dispose();
  }

  /// The padding that puts the pane on its roomier side, or null when there is no usable fold.
  EdgeInsets? columnInset(DuoLayout duo, Size size) {
    final fold = duo.verticalFold;
    if (fold == null) return null;
    final left = duo.safe.left, right = size.width - duo.safe.right;
    final leftRoom = fold.left - left, rightRoom = right - fold.right;
    if (fold.right <= left || fold.left >= right) return null;
    // The right side whenever it is roomy enough (it holds still when the session list opens), else the left.
    if (rightRoom >= HalfFoldPane.minimumRoom) {
      return EdgeInsets.only(left: fold.right - left);
    }
    if (leftRoom >= HalfFoldPane.minimumRoom) {
      return EdgeInsets.only(right: right - fold.left);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final duo = DuoLayoutScope.of(context);
    final size = MediaQuery.sizeOf(context);
    final inset = columnInset(duo, size);
    final folded = inset != null;
    if (inset != null) side = inset;
    final resized = lastSize != null && lastSize != size;
    lastSize = size;
    if (target == null) {
      target = folded;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        anim.value = target! ? 1 : 0;
        seeded = true;
      });
    } else if (resized) {
      // A rotation or resize: the old geometry no longer applies, so go straight to the new state.
      target = folded;
      anim.stop();
      anim.value = folded ? 1 : 0;
      seeded = true;
    } else if (target != folded) {
      target = folded;
      final duration = motion(context, 320);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || target != folded) return;
        if (duration == Duration.zero) {
          anim.value = folded ? 1 : 0;
        } else {
          anim.animateTo(
            folded ? 1 : 0,
            duration: duration,
            curve: Curves.easeInOutCubic,
          );
        }
      });
    }
    return AnimatedBuilder(
      animation: anim,
      child: widget.child,
      builder: (context, child) {
        final value = seeded ? anim.value : (folded ? 1.0 : 0.0);
        final onSide = value >= .5;
        final fade = seeded ? (2 * value - 1).abs() : 1.0;
        return IgnorePointer(
          ignoring: fade < 1,
          child: Opacity(
            key: const Key('half-fold-fade'),
            opacity: fade,
            child: Padding(
              padding: onSide ? side : EdgeInsets.zero,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
