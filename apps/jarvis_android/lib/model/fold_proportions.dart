import 'dart:math' as math;

/// Shared logical proportions. Window shape is read before the IME consumes
/// height; every child uses the same content pane rather than physical pixels.
class FoldProportions {
  static bool isFold(double w, double h) =>
      math.min(w, h) >= 600 || math.max(w, h) / math.min(w, h) < 1.9;
  static bool inner(double w, double h) => math.min(w, h) >= 600;
  static bool compactInput(double windowHeight, double keyboardInset) =>
      keyboardInset > 0 && windowHeight - keyboardInset < 220;
  static const uprightBox = .76;
  static const dockedBox = .97 * .95;
  static const foldedBox = .97 * .8 * .9;
  static const messagesInBox = .98;
  static const userBubble = .88;

  static FoldColumns columns({
    required double windowWidth,
    required double windowHeight,
    required double paneWidth,
    required bool dockedMode,
    required bool sidebarOpen,
    double? sidebarProgress,
  }) {
    final p = math.max(0.0, paneWidth);
    final base = math.max(0.0, p - 32);
    double box, messages;
    if (dockedMode) {
      final progress = (sidebarProgress ?? (sidebarOpen ? 1.0 : 0.0)).clamp(
        0.0,
        1.0,
      );
      box = base * (foldedBox + (dockedBox - foldedBox) * progress);
      messages = box * messagesInBox;
    } else if (inner(windowWidth, windowHeight)) {
      box = base * uprightBox;
      messages = box * messagesInBox;
    } else if (windowWidth > windowHeight) {
      final strip = math.max(0.0, windowWidth - p);
      final upright = math.max(0.0, windowHeight - strip - 32);
      box = math.min(base, upright * windowWidth / windowHeight * .9);
      messages = box * .94;
    } else {
      box = base;
      messages = math.min(math.max(0, p - 36), base * .95 * .95 * .98);
    }
    return FoldColumns(p, box, messages);
  }

  /// A shared identity/transcript column; controls stay within it too.
  static double voiceWidth(
    double width,
    double height, {
    required double paneWidth,
  }) => columns(
    windowWidth: width,
    windowHeight: height,
    paneWidth: paneWidth,
    dockedMode: inner(width, height) && width > height,
    sidebarOpen: false,
  ).composer;
  static double voiceActionWidth(double column) => math.min(380, column);
  static const callIdleFigure = 220.0;
  static const callCompactFigure = 84.0;
  static const callIdleGap = 26.0;
  static const callLabelGap = 14.0;
  static const callStatus = 17.0;
  static const callHint = 12.0;
  static const welcomeTitle = 24.0;
  static const welcomeHint = 15.0;
}

class FoldColumns {
  const FoldColumns(this.pane, this.composer, this.messages);
  final double pane, composer, messages;
  double get composerInset => (pane - composer) / 2;
  double get messageInset => (pane - messages) / 2;
}
