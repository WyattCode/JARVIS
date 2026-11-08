import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Where an action menu's panel stands, as the iOS glass menu places it: 9
/// below the anchor (or above it, when [above]), lined up with the anchor's
/// right edge (or its left, when [alignLeft]), turned to the other side of the
/// anchor when there is no room, and kept inside the usable area (the system's
/// insets, one screen of a folded display) with 8 to spare.
class MenuLayout extends SingleChildLayoutDelegate {
  const MenuLayout({
    required this.anchor,
    required this.usable,
    this.above = false,
    this.alignLeft = false,
  });

  static const gap = 9.0;
  static const margin = 8.0;

  /// The anchor, in the overlay's coordinates.
  final Rect anchor;

  /// The area the panel may use, in the overlay's coordinates.
  final Rect usable;
  final bool above;
  final bool alignLeft;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, usable.width - 2 * margin),
        maxHeight: math.max(0, usable.height - 2 * margin),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final low = usable.left + margin;
    final high = math.max(low, usable.right - childSize.width - margin);
    final x = (alignLeft ? anchor.left : anchor.right - childSize.width).clamp(
      low,
      high,
    );
    final top = usable.top + margin;
    final bottom = usable.bottom - margin;
    var y = above ? anchor.top - gap - childSize.height : anchor.bottom + gap;
    final overflows = above ? y < top : y + childSize.height > bottom;
    if (overflows) {
      // No room on that side: the other one, or as high as it fits.
      y = above
          ? anchor.bottom + gap
          : math.max(top, anchor.top - gap - childSize.height);
    }
    y = y.clamp(top, math.max(top, bottom - childSize.height));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(MenuLayout old) =>
      old.anchor != anchor ||
      old.usable != usable ||
      old.above != above ||
      old.alignLeft != alignLeft;
}
