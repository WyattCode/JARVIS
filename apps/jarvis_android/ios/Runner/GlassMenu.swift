import UIKit

// MARK: Glass menu

/// The long-press menu of a conversation row, as it was set: a Liquid Glass panel (a blur before iOS 26) 9 pt below the row,
/// lined up with the row's right edge, 30% wider than its items need and no wider than the row; above the row when there is no
/// room below. It springs open from the corner it hangs from. A glass highlight follows the finger over the items, with a tick
/// at each one it reaches and a tap when one is chosen, as the system's menus do; a touch anywhere else closes it.
final class GlassMenu: UIView {
  struct Item {
    let title: String
    var symbol: String?
    var destructive = false
    var checked = false
    let run: () -> Void
  }

  private var panel: UIVisualEffectView?
  private var fits = false
  private var above = false
  private var alignLeft = false
  private let highlight = UIVisualEffectView(effect: nil)
  private var rows: [UIButton] = []
  private var items: [Item] = []
  private var current: Int?
  private var shown = false
  private let tick = UISelectionFeedbackGenerator()
  private weak static var showing: GlassMenu?
  /// The window's size when the menu was built: a turn or a fold makes the row it hangs from the wrong place, and it goes.
  private var builtSize: CGSize = .zero
  /// An item has been chosen (by touch or by VoiceOver): a second choice before the menu is gone is not taken.
  private var chosen = false
  private var elements: [MenuElement] = []

  /// An item for VoiceOver: the rows themselves take no touches (the panel's press does that), so each is described and
  /// activated from here.
  private final class MenuElement: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool {
      activate?()
      return true
    }
  }

  /// `row` is the row's frame in the window.
  /// `fit`: as wide as its items need (a button's menu); `above`: hangs above the anchor (a button at the foot of the page);
  /// `alignLeft`: lined up with the anchor's left edge instead of its right.
  static func show(items: [Item], row: CGRect, in window: UIWindow, fit: Bool = false, above: Bool = false, alignLeft: Bool = false) {
    showing?.removeFromSuperview()
    let menu = GlassMenu(frame: window.bounds)
    menu.fits = fit
    menu.above = above
    menu.alignLeft = alignLeft
    menu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    menu.accessibilityViewIsModal = true
    window.addSubview(menu)
    showing = menu
    menu.items = items
    menu.build(row: row, in: window)
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  private func build(row: CGRect, in host: UIWindow) {
    let effect: UIVisualEffect
    if #available(iOS 26.0, *) { effect = UIGlassEffect(style: .regular) } else { effect = UIBlurEffect(style: .systemThickMaterial) }
    let panel = UIVisualEffectView(effect: effect)
    let radius: CGFloat = fits ? 34 : 26
    if #available(iOS 26.0, *) {
      panel.cornerConfiguration = .corners(radius: .fixed(radius))
    } else {
      panel.layer.cornerRadius = radius
      panel.layer.cornerCurve = .continuous
      panel.clipsToBounds = true
    }
    // The pill that follows the finger sits under the rows.
    if #available(iOS 26.0, *) {
      highlight.effect = UIGlassEffect(style: .clear)
      highlight.cornerConfiguration = .corners(radius: .fixed(18))
    } else {
      highlight.backgroundColor = UIColor.label.withAlphaComponent(0.14)
      highlight.layer.cornerRadius = 18
      highlight.layer.cornerCurve = .continuous
    }
    highlight.alpha = 0
    panel.contentView.addSubview(highlight)
    let room = host.bounds.height - host.safeAreaInsets.top - host.safeAreaInsets.bottom - 16
    rows = items.map { button($0, dense: false) }
    var stack = UIStackView(arrangedSubviews: rows)
    stack.axis = .vertical
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    stack.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
    ])
    addSubview(panel)
    self.panel = panel
    var fit = stack.systemLayoutSizeFitting(
      CGSize(width: row.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .fittingSizeLevel, verticalFittingPriority: .fittingSizeLevel)
    if fit.height > room {
      // Too tall for what is left of the screen (a landscape page with the keyboard up): the rows close up.
      stack.removeFromSuperview()
      rows = items.map { button($0, dense: true) }
      stack = UIStackView(arrangedSubviews: rows)
      stack.axis = .vertical
      stack.isLayoutMarginsRelativeArrangement = true
      stack.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
      stack.translatesAutoresizingMaskIntoConstraints = false
      panel.contentView.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
        stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
        stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
      ])
      fit = stack.systemLayoutSizeFitting(
        CGSize(width: row.width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .fittingSizeLevel, verticalFittingPriority: .fittingSizeLevel)
    }
    let width = fits ? min(max(fit.width, 190), host.bounds.width - 16) : min(row.width, max(fit.width, 190) * 1.3)
    let height = fit.height
    var y = above ? row.minY - 9 - height : row.maxY + 9
    var below = !above
    if above ? y < host.safeAreaInsets.top + 8 : y + height > host.bounds.height - host.safeAreaInsets.bottom - 8 {
      y = above ? row.maxY + 9 : max(host.safeAreaInsets.top + 8, row.minY - 9 - height)
      below = above
    }
    // Inside the safe areas (the strip beside a foldable's page is not to be covered).
    let safe = host.safeAreaInsets
    let low = safe.left + 8, high = host.bounds.width - safe.right - width - 8
    let x = min(max(low, alignLeft ? row.minX : row.maxX - width), max(low, high))
    y = min(max(y, safe.top + 8), max(safe.top + 8, host.bounds.height - safe.bottom - 8 - height))
    panel.frame = CGRect(x: x, y: y, width: width, height: height)
    panel.layoutIfNeeded()
    let press = UILongPressGestureRecognizer(target: self, action: #selector(touched(_:)))
    press.minimumPressDuration = 0
    panel.addGestureRecognizer(press)
    // It opens from the corner it hangs from: a spring that grows out of the row's right edge.
    let reduce = UIAccessibility.isReduceMotionEnabled
    let corner = CGPoint(x: width / 2, y: below ? -height / 2 : height / 2)
    panel.alpha = 0
    panel.transform = reduce ? .identity : CGAffineTransform(translationX: corner.x, y: corner.y).scaledBy(x: 0.72, y: 0.72).translatedBy(x: -corner.x, y: -corner.y)
    UIView.animate(withDuration: reduce ? 0.01 : 0.5, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.6, options: [.allowUserInteraction]) {
      panel.transform = .identity
    }
    UIView.animate(withDuration: reduce ? 0.01 : 0.18, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) { panel.alpha = 1 }
    tick.prepare()
    shown = true
    builtSize = host.bounds.size
    describeRows()
  }

  /// Each row as VoiceOver meets it: a button with its name, the chosen one marked, and the whole menu closes on the scrub.
  private func describeRows() {
    guard let panel else { return }
    elements = rows.enumerated().map { i, row in
      let element = MenuElement(accessibilityContainer: panel)
      element.accessibilityLabel = items[i].title
      element.accessibilityTraits = items[i].checked ? [.button, .selected] : .button
      element.accessibilityFrameInContainerSpace = row.convert(row.bounds, to: panel)
      element.activate = { [weak self] in self?.choose(i) }
      return element
    }
    panel.isAccessibilityElement = false
    panel.accessibilityElements = elements
    UIAccessibility.post(notification: .screenChanged, argument: elements.first)
  }

  override func accessibilityPerformEscape() -> Bool {
    close()
    return true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if builtSize != .zero, shown, bounds.size != builtSize { removeFromSuperview() }
  }

  /// An item chosen: a short press on it, then it runs and the menu goes.
  private func choose(_ i: Int) {
    guard !chosen, shown, items.indices.contains(i) else { return }
    chosen = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let item = items[i]
    UIView.animate(withDuration: 0.1, animations: { self.highlight.transform = CGAffineTransform(scaleX: 0.97, y: 0.97) }) { _ in
      item.run()
      self.close()
    }
  }

  /// A symbol centred in a round chip of translucent light.
  /// Drawn with the menu's own traits: the colours are fixed into the picture, and the app's theme may not be the system's.
  private func chip(_ symbol: UIImage, destructive: Bool, side: CGFloat) -> UIImage {
    let size = CGSize(width: side, height: side)
    var image = UIImage()
    traitCollection.performAsCurrent {
      image = UIGraphicsImageRenderer(size: size).image { _ in
        UIColor.label.withAlphaComponent(0.1).setFill()
        UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        let tinted = symbol.withTintColor(destructive ? .systemRed : .label, renderingMode: .alwaysOriginal)
        tinted.draw(in: CGRect(x: (size.width - tinted.size.width) / 2, y: (size.height - tinted.size.height) / 2, width: tinted.size.width, height: tinted.size.height))
      }
    }
    return image.withRenderingMode(.alwaysOriginal)
  }

  private func button(_ item: Item, dense: Bool) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.title = item.title
    // "name:0.5" is a symbol drawn to that fraction (the signal bars for low, medium and high).
    let plain = item.symbol.flatMap { symbol -> UIImage? in
      let look = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
      let parts = symbol.split(separator: ":")
      if parts.count == 2, let value = Double(parts[1]) { return UIImage(systemName: String(parts[0]), variableValue: value, configuration: look) }
      return UIImage(systemName: symbol, withConfiguration: look)
    }
    // A button's menu (the box's plus and thinking level) puts each symbol in a soft round chip, and the chosen row stands on a
    // pill of its own.
    configuration.image = fits ? plain.map { chip($0, destructive: item.destructive, side: dense ? 34 : 40) } : plain
    configuration.imagePadding = fits ? 16 : 12
    configuration.contentInsets = fits
      ? NSDirectionalEdgeInsets(top: dense ? 4 : 8, leading: 8, bottom: dense ? 4 : 8, trailing: item.checked ? 56 : 26)
      : NSDirectionalEdgeInsets(top: dense ? 8 : 12, leading: 16, bottom: dense ? 8 : 12, trailing: item.checked ? 46 : 22)
    if fits && item.checked {
      configuration.background.backgroundColor = UIColor.label.withAlphaComponent(0.12)
      configuration.background.cornerRadius = 30
    }
    configuration.baseForegroundColor = item.destructive ? .systemRed : .label
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .regular))
      return attributes
    }
    let button = UIButton(configuration: configuration)
    button.contentHorizontalAlignment = .leading
    button.isUserInteractionEnabled = false
    if item.checked {
      let mark = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
      mark.tintColor = Palette.accent
      mark.translatesAutoresizingMaskIntoConstraints = false
      button.addSubview(mark)
      NSLayoutConstraint.activate([mark.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16), mark.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
    }
    return button
  }

  private func index(at point: CGPoint) -> Int? {
    guard let panel else { return nil }
    for (i, row) in rows.enumerated() {
      let frame = row.convert(row.bounds, to: panel)
      if frame.insetBy(dx: -8, dy: 0).contains(point) { return i }
    }
    return nil
  }

  @objc private func touched(_ press: UILongPressGestureRecognizer) {
    guard let panel else { return }
    let point = press.location(in: panel)
    switch press.state {
    case .began, .changed:
      let next = index(at: point)
      if next != current {
        current = next
        if next != nil { tick.selectionChanged(); tick.prepare() }
        moveHighlight(to: next)
      }
    case .ended:
      if let i = index(at: point) {
        choose(i)
      } else {
        moveHighlight(to: nil)
        current = nil
      }
    default:
      moveHighlight(to: nil)
      current = nil
    }
  }

  private func moveHighlight(to i: Int?) {
    guard let panel else { return }
    guard let i else {
      UIView.animate(withDuration: 0.18) { self.highlight.alpha = 0 }
      return
    }
    let target = rows[i].convert(rows[i].bounds, to: panel.contentView)
    if highlight.alpha == 0 {
      highlight.transform = .identity
      highlight.frame = target
      highlight.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
    }
    UIView.animate(withDuration: 0.36, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.highlight.alpha = 1
      self.highlight.transform = .identity
      self.highlight.frame = target
    }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if let panel, panel.frame.contains(point) { return super.hitTest(point, with: event) }
    return self
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    // A touch on the panel itself comes up the responder chain to here as well; only one outside it closes the menu.
    guard let touch = touches.first, let panel, !panel.frame.contains(touch.location(in: self)) else { return }
    close()
  }

  private func close() {
    guard let panel, shown else { return removeFromSuperview() }
    shown = false
    UIView.animate(withDuration: 0.16, delay: 0, options: .curveEaseIn, animations: {
      panel.alpha = 0
      panel.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
    }) { _ in self.removeFromSuperview() }
  }
}
