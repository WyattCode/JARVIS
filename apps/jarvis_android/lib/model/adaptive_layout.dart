import 'dart:math' as math;

/// Uses the current full window, never physical pixels or rotation constants.
/// IME changes must not turn a portrait window into an expanded landscape pane.
class AdaptiveLayout {
  const AdaptiveLayout({
    required this.docked,
    required this.sidebarWidth,
    required this.compactHeight,
  });
  final bool docked;
  final double sidebarWidth;
  final bool compactHeight;

  /// Shared outer spacing for the tall-phone composer and welcome cards.
  static double tallComposerGap(double bottomInset) =>
      math.max(10.0, bottomInset * .8);

  factory AdaptiveLayout.forWindow(
    double width,
    double height, {
    double horizontalInsets = 0,
    double verticalInsets = 0,
  }) {
    final usableWidth = math.max(0.0, width - horizontalInsets);
    final expanded = math.min(width, height) >= 600;
    final tallPhone = !expanded && height >= width * 1.9;
    final docked = expanded && width > height && usableWidth >= 760;
    return AdaptiveLayout(
      docked: docked,
      sidebarWidth: docked
          ? (usableWidth * .319).clamp(251, 308).toDouble() * 1.1
          : math.min(usableWidth * (tallPhone ? .715 : .65), 320),
      compactHeight: height - verticalInsets < 520,
    );
  }
}
