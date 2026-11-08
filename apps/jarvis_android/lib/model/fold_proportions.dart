import 'dart:math' as math;

import 'device_kind.dart';

/// Shared logical proportions. Window shape is read before the IME consumes
/// height; every child uses the same content pane rather than physical pixels.
class FoldProportions {
  /// A window that gets the foldable treatment. On a phone the system says
  /// whether it folds (a folding phone: every window of it, outer display
  /// included; a straight one: only a large window). Where that is not known
  /// (tests) the window's own shape is guessed from.
  static bool isFold(double w, double h) {
    final foldable = DeviceKind.foldable;
    if (foldable != null) return foldable || math.min(w, h) >= 600;
    return math.min(w, h) >= 600 || math.max(w, h) / math.min(w, h) < 1.9;
  }

  /// The chat is laid out from [columns] (a straight phone has its own
  /// rules there, as on iOS) whenever the kind of phone is known.
  static bool usesColumns(double w, double h) =>
      DeviceKind.foldable != null || isFold(w, h);
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

    /// The keyboard is up. A foldable's box is then wider (17 from each side,
    /// not 32, and without the upright inner display's narrowing); the
    /// messages stay as wide as they were at rest, so they do not wrap again
    /// at every show and hide. A straight phone's box does not change.
    bool keyboardUp = false,
  }) {
    final p = math.max(0.0, paneWidth);
    final base = math.max(0.0, p - 32);
    final wide = math.max(0.0, p - 17);
    if (DeviceKind.foldable == false && !inner(windowWidth, windowHeight)) {
      // A straight phone: a reading column of at most 720, the box 16 in from
      // each side of it, the messages a little less wide than the column.
      final reading = math.min(p, 720.0);
      return FoldColumns(p, reading - 32, reading - 36);
    }
    double box, messages, composer;
    if (dockedMode) {
      final progress = (sidebarProgress ?? (sidebarOpen ? 1.0 : 0.0)).clamp(
        0.0,
        1.0,
      );
      final share = foldedBox + (dockedBox - foldedBox) * progress;
      box = base * share;
      messages = box * messagesInBox;
      composer = keyboardUp ? wide * share : box;
    } else if (inner(windowWidth, windowHeight)) {
      box = base * uprightBox;
      messages = box * messagesInBox;
      composer = keyboardUp ? wide : box;
    } else if (windowWidth > windowHeight) {
      final strip = math.max(0.0, windowWidth - p);
      double sideways(double margin) {
        final upright = math.max(0.0, windowHeight - strip - margin);
        return math.min(p - margin, upright * windowWidth / windowHeight * .9);
      }

      box = math.min(base, sideways(32));
      messages = box * .94;
      composer = keyboardUp ? sideways(17) : box;
    } else {
      box = base;
      messages = math.min(math.max(0, p - 36), base * .95 * .95 * .98);
      composer = keyboardUp ? wide : box;
    }
    return FoldColumns(p, composer, messages);
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
