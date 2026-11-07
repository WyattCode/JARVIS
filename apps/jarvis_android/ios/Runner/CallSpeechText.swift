import UIKit

/// JARVIS's words on the call page, lit as they are said: what the voice has said is bright, what is still to come is dim, and
/// at the front of the bright part is a soft edge that moves on a character at a time and leaves a faint cyan glow that dies
/// away behind it. Nothing is boxed or underlined.
///
/// Where the voice is comes from `VoiceSession.speechProgress` (an estimate, see `SpokenText`); this view only draws it, so
/// the edge is soft on purpose: it never claims to be exact. Without progress (a reply said to the end, or one not being said
/// yet) the text is plain.
@MainActor
final class SpokenTextView: UITextView {
  private var spoken = SpokenText("")
  private var raw = ""
  private var size: CGFloat = 0
  /// How many characters have been said, with the part of the one being said (nil: the text is plain).
  private var edge: Double?
  /// The characters (by number) that are coloured one by one; the ones before are all bright, the ones after all dim.
  private var painted: Range<Int>?
  private var lastLine: CGRect?
  private var lastWidth: CGFloat = 0
  /// Keeps the edge from leaping to an estimate that jumped (see `ReadingEdge`).
  private var limiter = ReadingEdge()
  /// What the estimate said at the last look, and where the edge is drawn (for the call's trace).
  private(set) var estimated: Double?
  var shown: Double? { edge }
  var characterCount: Int { spoken.clusters.count }
  /// Called when the line the edge is on has a new place (it moved to the next line, or the lines were re-flowed).
  var onLine: ((CGRect) -> Void)?

  /// Characters behind the edge over which the glow dies away, and over which a character comes up from dim to bright.
  private static let trail = 16
  private static let rise = 3.0

  init() {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    storage.addLayoutManager(manager)
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    super.init(frame: .zero, textContainer: container)
    isEditable = false
    isSelectable = false
    isScrollEnabled = false
    backgroundColor = .clear
    textContainerInset = .zero
    // The colours are drawn for the style the page is in: a change of style draws them again.
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SpokenTextView, _: UITraitCollection) in
      if let edge = view.edge {
        view.painted = nil
        view.paint(edge)
      }
    }
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    // A turn of the phone re-flows the lines.
    if edge != nil, bounds.width != lastWidth {
      lastWidth = bounds.width
      lastLine = nil
      locate()
    }
  }

  /// Shows `text` lit as far as `progress` says the voice has got (plain when it is not being followed).
  func show(_ text: String, size: CGFloat, progress: SpeechProgress?) {
    let rebuilt = text != raw || size != self.size
    if rebuilt {
      raw = text
      self.size = size
      spoken = SpokenText(text)
    }
    let raw = progress?.position(in: spoken)
    estimated = raw
    var target: Double?
    if let raw, let progress {
      let limit = Double(spoken.clusters.count)
      target = min(progress.cut ? limiter.freeze(at: raw) : limiter.advance(to: raw, now: CACurrentMediaTime()), limit)
    } else {
      limiter.reset()
    }
    if !rebuilt, target == edge { return }
    let change = { [self] in
      if rebuilt {
        textStorage.setAttributedString(base())
        painted = nil
      } else if target == nil {
        plain()
      }
      if let target { paint(target) }
      edge = target
    }
    // Plain to lit and back dissolves; the edge moving on is the motion itself and does not.
    if !rebuilt, (edge == nil) != (target == nil), window != nil, !UIAccessibility.isReduceMotionEnabled {
      UIView.transition(
        with: self, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState], animations: change)
    } else {
      change()
    }
    locate()
  }

  private func base() -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    let text = NSMutableAttributedString(
      string: spoken.plain,
      attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: Palette.onSurface, .paragraphStyle: style])
    let heavy = UIFont.systemFont(ofSize: size, weight: .semibold)
    for run in spoken.bold where run.upperBound <= text.length {
      text.addAttribute(.font, value: heavy, range: NSRange(location: run.lowerBound, length: run.count))
    }
    return text
  }

  // MARK: Colours

  private struct Color {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ c: UIColor, _ trait: UITraitCollection) {
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      c.resolvedColor(with: trait).getRed(&r, green: &g, blue: &b, alpha: &a)
      (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }
    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
    func mixed(with o: Color, _ t: CGFloat) -> Color {
      let t = min(max(t, 0), 1)
      return Color(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t, a: a + (o.a - a) * t)
    }
    var ui: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    func alpha(_ v: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: v) }
  }

  private func range(_ clusters: Range<Int>) -> NSRange {
    let from = spoken.clusters[clusters.lowerBound].lowerBound
    let to = spoken.clusters[clusters.upperBound - 1].upperBound
    return NSRange(location: from, length: to - from)
  }

  private func set(_ color: UIColor, _ clusters: Range<Int>) {
    guard !clusters.isEmpty else { return }
    let r = range(clusters)
    textStorage.addAttribute(.foregroundColor, value: color, range: r)
    textStorage.removeAttribute(.shadow, range: r)
  }

  /// All the text bright and without a glow.
  private func plain() {
    painted = nil
    guard !spoken.clusters.isEmpty else { return }
    set(Palette.onSurface, 0..<spoken.clusters.count)
  }

  /// Colours the characters around the edge one by one and the rest in two blocks. `p` is the number of characters said.
  private func paint(_ p: Double) {
    let n = spoken.clusters.count
    guard n > 0, p.isFinite else { return }
    let lit = Color(Palette.onSurface, traitCollection)
    let dim = Color(Palette.onSurface.withAlphaComponent(0.5), traitCollection)
    let glow = Color(Palette.accent, traitCollection)
    let lo = min(max(0, Int(p.rounded(.down)) - Self.trail), n)
    let hi = min(max(lo, Int(p.rounded(.up)) + 1), n)
    textStorage.beginEditing()
    defer { textStorage.endEditing() }
    if let old = painted {
      let from = min(lo, old.lowerBound)
      let to = max(hi, old.upperBound)
      if from < lo { set(lit.ui, from..<lo) }
      if hi < to { set(dim.ui, hi..<min(to, n)) }
    } else {
      if lo > 0 { set(lit.ui, 0..<lo) }
      if hi < n { set(dim.ui, hi..<n) }
    }
    for k in lo..<hi {
      // How far behind the edge this character is (a character is half said when the edge is at its middle).
      let d = p - Double(k) - 0.5
      let t = min(max(d / Self.rise, 0), 1)
      let up = t * t * (3 - 2 * t)
      let flash = d > 0 ? min(1, (d / 2) * exp(1 - d / 2)) : 0
      var color = dim.mixed(with: lit, CGFloat(up))
      color = color.mixed(with: glow, CGFloat(flash) * 0.6)
      let r = range(k..<(k + 1))
      textStorage.addAttribute(.foregroundColor, value: color.ui, range: r)
      if flash > 0.05 {
        let shadow = NSShadow()
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = 8
        shadow.shadowColor = glow.alpha(CGFloat(flash) * 0.85)
        textStorage.addAttribute(.shadow, value: shadow, range: r)
      } else {
        textStorage.removeAttribute(.shadow, range: r)
      }
    }
    painted = lo..<hi
  }

  /// Tells the page which line the edge is on, when that changed.
  private func locate() {
    guard let p = edge, bounds.width > 0, !spoken.clusters.isEmpty else { return }
    let k = min(max(Int(p), 0), spoken.clusters.count - 1)
    layoutManager.ensureLayout(for: textContainer)
    let glyph = layoutManager.glyphIndexForCharacter(at: spoken.clusters[k].lowerBound)
    let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    if line != lastLine {
      lastLine = line
      onLine?(line)
    }
  }
}
