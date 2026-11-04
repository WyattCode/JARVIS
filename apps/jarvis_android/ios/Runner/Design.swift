import SwiftUI
import UIKit

/// The app's design values, taken from the original app (its Material colour scheme, radii and margins): every screen draws
/// from these, so a colour or a corner is written once. Dark and light are the two halves of each colour.
enum Palette {
  private static func pick(_ dark: UInt32, _ light: UInt32) -> UIColor {
    UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) }
  }

  /// The page.
  static let surface = pick(0x09090B, 0xF9FAF9)
  /// Cards, the composer, grouped lists.
  static let card = pick(0x121214, 0xFFFFFF)
  static let container = pick(0x18181B, 0xF1F3F2)
  /// Bubbles, tiles, fields.
  static let containerHigh = pick(0x1C1C20, 0xEDF0EF)
  static let containerHighest = pick(0x242429, 0xE8EDEB)
  static let onSurface = pick(0xEDEDF1, 0x171C1E)
  static let onSurfaceVariant = pick(0xA1A1AA, 0x3F484B)
  /// The one hairline around inputs, cards and selected rows.
  static let outline = pick(0x36363D, 0x70797B)
  static let outlineVariant = pick(0x303036, 0xDCE3E1)
  static let primary = pick(0xD5D5DF, 0x28596A)
  static let onPrimary = pick(0x161619, 0xFFFFFF)
  static let error = pick(0xFF9B8C, 0xBA1A1A)
  static let errorContainer = pick(0x382C30, 0xFFDAD6)
  /// Text-like uses of the cyan.
  static let accent = pick(0x8FDCEB, 0x137589)
  static let success = pick(0x2D9F80, 0x196A52)
  static let warning = pick(0xC6A765, 0x6F5612)
  /// The hang-up button's red.
  static let danger = UIColor(rgb: 0xAF3543)
  /// The message box of the home page: lifted off the page, with the controls in it one step lighter again.
  static let composer = pick(0x222226, 0xFFFFFF)
  static let composerEdge = pick(0x3A3A40, 0xDCE3E1)
  static let composerControl = pick(0x38383E, 0xEDF0EF)
  /// The pale cyan of a held button (dark ink on it, in both themes).
  static let energy = UIColor(rgb: 0x8FDCEB)
}

enum Radii {
  /// Blocks inside a card, menu rows, small tiles.
  static let small: CGFloat = 12
  /// Cards, grouped lists, menus, buttons.
  static let medium: CGFloat = 16
  /// Large controls and message bubbles.
  static let large: CGFloat = 20
  /// Sheets and dialogs.
  static let sheet: CGFloat = 24
}

enum Metrics {
  /// Side margin of a settings-like page and of a sheet's content.
  static let pageMargin: CGFloat = 20
  /// Side margin of the settings cards: a little less than the other pages', so the cards are wider.
  static let cardMargin: CGFloat = 14
  static let disabledOpacity: CGFloat = 0.38
}

extension UIColor {
  convenience init(rgb: UInt32, alpha: CGFloat = 1) {
    self.init(
      red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
  }
}

extension Color {
  init(_ ui: UIColor) { self.init(uiColor: ui) }
}

extension UIView {
  /// A flat surface in the original's style: a fill, a corner and (optionally) the hairline.
  func styleSurface(_ fill: UIColor, radius: CGFloat, border: UIColor? = nil) {
    backgroundColor = fill
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous
    if let border {
      layer.borderWidth = 1
      layer.borderColor = border.resolvedColor(with: traitCollection).cgColor
      // A layer's colour is not dynamic: it is resolved again when the theme changes.
      registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
        view.layer.borderColor = border.resolvedColor(with: view.traitCollection).cgColor
      }
    }
  }
}

/// Whether the system put its bars in a vertical strip beside the content (iPhone Duo's outer display, inner landscape).
func hasVerticalBar(_ traits: UITraitCollection) -> Bool {
  if #available(iOS 27.1, *) { return traits.verticalBarEdge != .unspecified }
  return false
}

/// The inner display held upright (at least 600 pt on its short side, taller than wide): the system's buttons are a bar along the top,
/// and the conversation list covers the whole window beside them (it is a page of its own there, as on a vertical strip).
func isInnerDisplayUpright(_ size: CGSize) -> Bool { min(size.width, size.height) >= 600 && size.height > size.width }

/// A foldable iPhone: the system reports a vertical bar or a fold. The original showed the web client's welcome page and
/// roomier layouts there.
@MainActor
func isFoldablePhone(_ view: UIView) -> Bool {
  if #available(iOS 27.1, *) {
    switch view.traitCollection.verticalBarEdge {
    case .leading, .trailing: return true
    default: break
    }
    return !view.reservedRegions(kind: .division, options: [.includeInactive]).isEmpty
  }
  return false
}


/// The brand mark: a ring with an inner ring, a centre ring and three spokes, in line art (the original's JarvisMark).
final class JarvisMarkView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: JarvisMarkView, _: UITraitCollection) in
      view.setNeedsDisplay()
    }
    backgroundColor = .clear
    isOpaque = false
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ rect: CGRect) {
    guard let c = UIGraphicsGetCurrentContext() else { return }
    let size = min(bounds.width, bounds.height)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let line = max(1, size / 16)
    c.setLineWidth(line)
    c.setLineCap(.round)
    let ink = Palette.accent.resolvedColor(with: traitCollection)
    c.setStrokeColor(ink.cgColor)
    func ring(_ r: CGFloat) { c.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)) }
    ring(size * 0.46)
    ring(size * 0.30)
    ring(size * 0.11)
    for k in 0..<3 {
      let angle = CGFloat(k) * 2 * .pi / 3 - .pi / 2
      c.move(to: CGPoint(x: center.x + cos(angle) * size * 0.14, y: center.y + sin(angle) * size * 0.14))
      c.addLine(to: CGPoint(x: center.x + cos(angle) * size * 0.30, y: center.y + sin(angle) * size * 0.30))
    }
    c.strokePath()
  }

}


/// The widths the chat page is laid out at, in one place (each was asked for in steps, and the figures were scattered through the
/// layout code). All of them are shares of the width the chat has.
enum ChatLayout {
  /// Beside the docked list when it is out (the inner display held sideways): the box and the four cards.
  static let dockedBox: CGFloat = 0.97 * 0.95
  /// Beside the docked list when it is folded away.
  static let foldedBox: CGFloat = 0.97 * 0.8 * 0.9
  /// The inner display held upright.
  static let uprightBox: CGFloat = 0.76
  /// The docked list shows a tenth more than the original's column.
  static let dockedListStretch: CGFloat = 1.1
  /// The messages' column is this share of what it was (asked for: 5% narrower).
  static let messagesShare: CGFloat = 0.95 * 0.98
  /// Beside the docked list (and upright) the messages are this share of the box's width (2% narrower, asked for with the list folded).
  static let messagesInBox: CGFloat = 0.98
  /// A message of yours: at most this share of the column (and 640 pt).
  static let userBubble: CGFloat = 0.88
  /// A picture in a reply: this wide (less where there is no room), whatever the column is. It must not follow the column: the picture of
  /// the messages that stands in for them while the list beside the chat slides would then be another size than the real one.
  static let picture: CGFloat = 480
  /// A phone's drawer: this share of the window (at most 420 pt on a wide one).
  static let drawer: CGFloat = 0.88
  static let drawerMost: CGFloat = 420
}
