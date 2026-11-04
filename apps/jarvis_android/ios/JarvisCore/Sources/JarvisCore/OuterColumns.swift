import CoreGraphics

/// The widths of the box and the messages on a foldable's outer display held sideways: the share of the screen's width the box has
/// upright (not the same margins, which made it a larger share of the screen the wider it got), a tenth less, and the messages a
/// little narrower than the box.
public enum OuterColumns {
  /// A tenth narrower than the upright share (asked for).
  static let narrower: CGFloat = 0.9
  /// The messages are this share of the box's width (asked for: 2% narrower, then 4% more).
  static let messagesInBox: CGFloat = 0.94

  /// - Parameters:
  ///   - shape: the window's size (wider than tall).
  ///   - pane: what the system's strip leaves of the width.
  ///   - keyboardUp: the box is wider with the keyboard up (its margins are 17, not 32).
  /// - Returns: the widths, never past what the pane has.
  public static func widths(shape: CGSize, pane: CGFloat, keyboardUp: Bool) -> (composer: CGFloat, messages: CGFloat) {
    let strip = max(0, shape.width - pane)
    // The page this display has upright: its short side, with the strip beside it as here.
    let uprightPane = max(0, shape.height - strip)
    let scale = shape.width / max(shape.height, 1)
    let margin: CGFloat = keyboardUp ? 17 : 32
    let box = min((uprightPane - margin) * scale * narrower, pane - margin)
    return (box, box * messagesInBox)
  }
}
