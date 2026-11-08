import 'dart:math' as math;
import 'dart:ui' show Size;

import 'device_kind.dart';
import 'fold_state.dart';

/// Uses the current full window, never physical pixels or rotation constants.
/// IME changes must not turn a portrait window into an expanded landscape pane.
class AdaptiveLayout {
  const AdaptiveLayout({
    required this.docked,
    required this.sidebarWidth,
    required this.compactHeight,
    this.split = false,
    this.foldGap = 0,
    this.fullPageList = false,
  });
  final bool docked;
  final double sidebarWidth;
  final bool compactHeight;

  /// Half-folded with the screens side by side: the list has the left screen,
  /// the chat the right one, and nothing is put on the crease between them.
  /// Always a docked arrangement; [sidebarWidth] then reaches the crease's far
  /// edge and [foldGap] is the crease's width.
  final bool split;
  final double foldGap;

  /// The inner display held upright: the conversation list covers the whole
  /// window (a page of its own), as it does on the iOS version.
  final bool fullPageList;

  /// Shared outer spacing for the tall-phone composer and welcome cards.
  static double tallComposerGap(double bottomInset) =>
      math.max(10.0, bottomInset * .8);

  factory AdaptiveLayout.forWindow(
    double width,
    double height, {
    double horizontalInsets = 0,
    double verticalInsets = 0,
    FoldState fold = FoldState.none,
    double leftInset = 0,
    bool? foldable,
  }) {
    // Whether the phone folds, as the system says; null where that is not
    // known (the window's shape is then what is guessed from).
    final kind = foldable ?? DeviceKind.foldable;
    final usableWidth = math.max(0.0, width - horizontalInsets);
    final expanded = math.min(width, height) >= 600;
    final tallPhone = !expanded && height >= width * 1.9;
    final docked = expanded && width > height && usableWidth >= 760;
    final split = docked && fold.splitsSideBySide(Size(width, height));
    final portrait = height > width;
    // When the list is a page of its own, covering the window (iOS: the inner
    // display held upright, a foldable's outer display held sideways, a
    // straight phone held upright).
    final fullPageList = kind == null
        ? expanded && portrait
        : expanded
        ? portrait
        : kind
        ? !portrait
        : portrait;
    final double sidebarWidth;
    if (split) {
      // The pane starts at the system's left inset; the crease is measured
      // from the window's edge.
      sidebarWidth = (fold.bounds.right - leftInset).clamp(0.0, usableWidth);
    } else if (docked) {
      sidebarWidth = (usableWidth * .319).clamp(251, 308).toDouble() * 1.1;
    } else if (fullPageList) {
      sidebarWidth = usableWidth;
    } else if (kind == null) {
      sidebarWidth = math.min(usableWidth * (tallPhone ? .715 : .65), 320);
    } else {
      // A drawer: 88% of the window on a foldable, 80% on a straight phone held
      // sideways, and never wider than a usual column.
      sidebarWidth = math.min(width * (kind ? .88 : .80), 420);
    }
    return AdaptiveLayout(
      docked: docked,
      sidebarWidth: sidebarWidth,
      compactHeight: height - verticalInsets < 520,
      split: split,
      foldGap: split ? fold.bounds.width : 0,
      fullPageList: fullPageList && !docked,
    );
  }
}
