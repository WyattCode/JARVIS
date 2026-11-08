import 'package:flutter/material.dart';

import '../model/fold_state.dart';

/// The colours the iOS pages draw with (Design.swift's Palette), read from the
/// app's theme where the theme already carries them and fixed where it does
/// not (the accent, and the state tones).
class PagePalette {
  PagePalette._(this.dark, this._colors);

  factory PagePalette.of(BuildContext context) {
    final theme = Theme.of(context);
    return PagePalette._(
      theme.brightness == Brightness.dark,
      theme.colorScheme,
    );
  }

  final bool dark;
  final ColorScheme _colors;

  Color get accent => dark ? const Color(0xff8fdceb) : const Color(0xff137589);
  Color get card => _colors.surfaceContainerLow;
  Color get container => _colors.surfaceContainer;
  Color get containerHigh => _colors.surfaceContainerHigh;
  Color get surface => _colors.surface;
  Color get outlineVariant => _colors.outlineVariant;
  Color get onSurface => _colors.onSurface;
  Color get onSurfaceVariant => _colors.onSurfaceVariant;
  Color get error => _colors.error;
  Color get success => dark ? const Color(0xff2d9f80) : const Color(0xff196a52);
  Color get warning => dark ? const Color(0xffc6a765) : const Color(0xff6f5612);

  /// The hairline round a card.
  Color get hairline => outlineVariant.withValues(alpha: .7);

  /// The rule between two rows of a card.
  Color get divider => outlineVariant.withValues(alpha: .6);
}

/// A card as the iOS pages draw it: the card colour, a 1pt hairline, a corner.
class PageCard extends StatelessWidget {
  const PageCard({
    super.key,
    required this.child,
    this.radius = 18,
    this.color,
    this.clip = Clip.antiAlias,
  });
  final Widget child;
  final double radius;
  final Color? color;
  final Clip clip;

  @override
  Widget build(BuildContext context) {
    final p = PagePalette.of(context);
    return Material(
      color: color ?? p.card,
      clipBehavior: clip,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: p.hairline),
      ),
      child: child,
    );
  }
}

/// Where a pushed page that covers the window puts its two halves when the
/// device is half-folded with the screens side by side: the first on the left
/// screen, the second on the right one, nothing on the crease. Everywhere else
/// (flat, upright, no fold) [PageFoldSplit.of] is null and the page uses its
/// ordinary arrangement.
class PageFoldSplit {
  const PageFoldSplit(this.leftWidth, this.gap, this.rightWidth);
  final double leftWidth;
  final double gap;
  final double rightWidth;

  /// The split for a page that fills a window of [constraints]' width, or null.
  static PageFoldSplit? of(BuildContext context, BoxConstraints constraints) {
    final size = MediaQuery.sizeOf(context);
    final fold = FoldState.fromFeatures(MediaQuery.displayFeaturesOf(context));
    if (!fold.splitsSideBySide(size)) return null;
    // Only a page that fills the window can be laid out against the crease.
    if ((constraints.maxWidth - size.width).abs() > 1) return null;
    final left = fold.bounds.left.clamp(0.0, size.width);
    final right = fold.bounds.right.clamp(0.0, size.width);
    if (left <= 0 || size.width - right <= 0) return null;
    return PageFoldSplit(left, right - left, size.width - right);
  }

  /// Both halves as a row: each in its own screen, the gap left empty. Each
  /// half takes the system's side insets only on its outer edge.
  Widget row(Widget left, Widget right, {Key? key}) => Row(
    key: key,
    children: [
      SizedBox(
        key: const Key('fold-left-screen'),
        width: leftWidth,
        child: SafeArea(top: false, right: false, child: left),
      ),
      SizedBox(width: gap),
      SizedBox(
        key: const Key('fold-right-screen'),
        width: rightWidth,
        child: SafeArea(top: false, left: false, child: right),
      ),
    ],
  );
}
