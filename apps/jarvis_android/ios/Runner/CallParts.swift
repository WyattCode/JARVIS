import Combine
import SwiftUI
import UIKit

/// The light behind the call's lower half: a soft cloud that rises from the bottom edge and swells with the sound. JARVIS's own
/// (the reactor's cyan) while it speaks, a pale silver one while you do.
final class CallGlowView: UIView {
  private let cloud = CAGradientLayer()

  /// `fromTop`: the light comes down from the top edge (JARVIS's voice); otherwise it rises from the bottom edge (yours).
  init(fromTop: Bool) {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    cloud.type = .radial
    cloud.startPoint = CGPoint(x: 0.5, y: fromTop ? 0.0 : 1.0)
    cloud.endPoint = CGPoint(x: 1.2, y: fromTop ? 1.0 : 0.0)
    cloud.locations = [0, 0.45, 1]
    layer.addSublayer(cloud)
    show(UIColor.white, 0)
  }

  override init(frame: CGRect) { fatalError() }
  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    cloud.frame = bounds
    CATransaction.commit()
  }

  func show(_ colour: UIColor, _ alpha: CGFloat) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.35)
    cloud.colors = [colour.withAlphaComponent(alpha).cgColor, colour.withAlphaComponent(alpha * 0.4).cgColor, colour.withAlphaComponent(0).cgColor]
    CATransaction.commit()
  }
}

/// The level bars of the call: tapered dots at rest, rising and falling with the sound that is being played or heard.
final class WaveformView: UIView {
  var levels = AudioLevels() { didSet { target = min(1, levels.playing ? levels.output * 9 : levels.input * 14) } }
  private var target = 0.0
  private var level = 0.0
  private var link: CADisplayLink?
  private let started = CACurrentMediaTime()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) { fatalError() }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    link?.invalidate()
    link = nil
    guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return setNeedsDisplay() }
    let l = CADisplayLink(target: self, selector: #selector(tick))
    l.preferredFramesPerSecond = 30
    l.add(to: .main, forMode: .common)
    link = l
  }

  @objc private func tick() {
    let before = level
    level += (target - level) * 0.22
    if level < 0.001 { level = 0 }
    if level != 0 || before != 0 { setNeedsDisplay() }
  }

  override func draw(_ rect: CGRect) {
    guard let c = UIGraphicsGetCurrentContext() else { return }
    let count = 64
    let step = bounds.width / CGFloat(count)
    let time = CACurrentMediaTime() - started
    let ink = Palette.onSurfaceVariant.resolvedColor(with: traitCollection)
    for i in 0..<count {
      let x = (CGFloat(i) + 0.5) * step
      let t = CGFloat(i) / CGFloat(count - 1)
      // Tapered at both ends; a travelling ripple while there is sound.
      let envelope = sin(t * .pi)
      let ripple = 0.5 + 0.5 * sin(Double(i) * 0.55 + time * 6)
      let height = max(2, bounds.height * envelope * CGFloat(level * (0.35 + 0.65 * ripple)))
      c.setFillColor(ink.withAlphaComponent(level > 0 ? 0.9 : 0.45).cgColor)
      let w = max(1.5, step * 0.5)
      c.addPath(UIBezierPath(roundedRect: CGRect(x: x - w / 2, y: bounds.midY - height / 2, width: w, height: height), cornerRadius: w / 2).cgPath)
      c.fillPath()
    }
  }

  deinit { link?.invalidate() }
}

/// Starts a call from a chat and shows its page.
@MainActor
enum NativeCall {
  static func start(from presenter: UIViewController, store: JarvisStore, voice: VoiceSession) {
    let owner = store.current.id
    present(from: presenter, store: store, voice: voice)
    Task { await voice.start(owner) }
  }

  static func present(from presenter: UIViewController, store: JarvisStore, voice: VoiceSession) {
    guard presenter.presentedViewController == nil else { return }
    let page = CallViewController(store: store, voice: voice)
    // In a navigation controller of its own, so that beside a vertical strip the system carries the page's buttons in it.
    let nav = UINavigationController(rootViewController: page)
    nav.isNavigationBarHidden = true
    nav.isToolbarHidden = true
    nav.modalPresentationStyle = .fullScreen
    let bar = UINavigationBarAppearance()
    bar.configureWithTransparentBackground()
    page.navigationItem.standardAppearance = bar
    page.navigationItem.scrollEdgeAppearance = bar
    presenter.present(nav, animated: true)
  }
}

/// The talking-way switch of the call's side strip: a glass capsule with two stacked places and a raised pill that moves to the one
/// that is on. A finger pointing: hold to talk. Sound bars: hands-free.
final class ModeToggle: UIView {
  private let glass: UIVisualEffectView
  private let pill = UIView()
  /// Each icon is drawn twice, light (on the glass) and dark (on the pill), and they trade places by alpha.
  private let holdLight = UIImageView(), holdDark = UIImageView(), freeLight = UIImageView(), freeDark = UIImageView()
  private var ptt: Bool
  private var moving = false
  private let choose: (String) -> Void
  /// Along the side strip the two places are stacked; in a bar along the top they stand side by side.
  private let horizontal: Bool
  var isHorizontal: Bool { horizontal }
  private var size: CGSize { horizontal ? CGSize(width: 100, height: 48) : CGSize(width: 48, height: 100) }
  /// The pill is a little smaller than the place it stands in.
  private static let inset: CGFloat = 5
  private static let rim: CGFloat = 2

  init(ptt: Bool, horizontal: Bool = false, choose: @escaping (String) -> Void) {
    self.ptt = ptt
    self.horizontal = horizontal
    self.choose = choose
    let effect: UIVisualEffect
    if #available(iOS 26.0, *) { effect = UIGlassEffect(style: .regular) } else { effect = UIBlurEffect(style: .systemThinMaterial) }
    glass = UIVisualEffectView(effect: effect)
    super.init(frame: CGRect(origin: .zero, size: horizontal ? CGSize(width: 100, height: 48) : CGSize(width: 48, height: 100)))
    glass.frame = bounds
    glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    glass.layer.cornerCurve = .continuous
    glass.clipsToBounds = true
    addSubview(glass)
    pill.backgroundColor = Palette.onSurface
    glass.contentView.addSubview(pill)
    let look = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
    let press = UIImage(systemName: "hand.point.up.left.fill", withConfiguration: look) ?? UIImage(systemName: "hand.tap.fill", withConfiguration: look)
    let bars = UIImage(systemName: "waveform", withConfiguration: look)
    pressImage = press
    barsImage = bars
    retint()
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (toggle: ModeToggle, _: UITraitCollection) in toggle.retint() }
    for view in [holdLight, holdDark, freeLight, freeDark] {
      view.contentMode = .center
      view.isUserInteractionEnabled = false
      glass.contentView.addSubview(view)
    }
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    isAccessibilityElement = true
    accessibilityLabel = "对话方式"
    accessibilityTraits = [.button, .adjustable]
    accessibilityValue = ptt ? "按住说话" : "免按说话"
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size.width), heightAnchor.constraint(equalToConstant: size.height)])
    settle()
  }

  required init?(coder: NSCoder) { fatalError() }

  private var pressImage: UIImage?, barsImage: UIImage?

  /// The icons are drawn in the colours of the theme the switch is in now (it is made before it has a window, and a theme may change
  /// in the middle of a call).
  private func retint() {
    let light = Palette.onSurface.resolvedColor(with: traitCollection), dark = Palette.surface.resolvedColor(with: traitCollection)
    for (view, image, colour) in [(holdLight, pressImage, light), (holdDark, pressImage, dark), (freeLight, barsImage, light), (freeDark, barsImage, dark)] {
      view.image = image?.withTintColor(colour, renderingMode: .alwaysOriginal)
    }
  }

  override var intrinsicContentSize: CGSize { size }

  override func layoutSubviews() {
    super.layoutSubviews()
    glass.layer.cornerRadius = min(bounds.width, bounds.height) / 2
    for (view, top) in [(holdLight, true), (holdDark, true), (freeLight, false), (freeDark, false)] { view.frame = placeFrame(top) }
    if !moving { settle() }
  }

  /// Where an icon stands (the whole place, a button's size).
  private func placeFrame(_ top: Bool) -> CGRect {
    if horizontal {
      let side = bounds.height - 2 * Self.rim
      return CGRect(x: top ? Self.rim : bounds.width - Self.rim - side, y: Self.rim, width: side, height: side)
    }
    let side = bounds.width - 2 * Self.rim
    return CGRect(x: Self.rim, y: top ? Self.rim : bounds.height - Self.rim - side, width: side, height: side)
  }

  /// The pill in a place: smaller than the place, centred in it.
  private func pillFrame(_ top: Bool) -> CGRect { placeFrame(top).insetBy(dx: Self.inset - Self.rim, dy: Self.inset - Self.rim) }

  /// Everything where it belongs for the way that is on, with no movement.
  private func settle() {
    pill.frame = pillFrame(ptt)
    pill.layer.cornerRadius = pill.bounds.width / 2
    holdDark.alpha = ptt ? 1 : 0
    holdLight.alpha = ptt ? 0 : 1
    freeDark.alpha = ptt ? 0 : 1
    freeLight.alpha = ptt ? 1 : 0
  }

  private func move() {
    guard !UIAccessibility.isReduceMotionEnabled else { return settle() }
    moving = true
    let from = pill.frame, to = pillFrame(ptt)
    // The pill stretches towards the other place and then draws in behind itself, as one drop of liquid does; the icons trade
    // colours while it passes.
    UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      self.holdDark.alpha = self.ptt ? 1 : 0
      self.holdLight.alpha = self.ptt ? 0 : 1
      self.freeDark.alpha = self.ptt ? 0 : 1
      self.freeLight.alpha = self.ptt ? 1 : 0
    }
    UIView.animate(withDuration: 0.17, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
      // It reaches most of the way to the other place before the rest of it follows.
      var reach = from
      if self.horizontal {
        let travel = to.midX - from.midX
        reach.size.width += abs(travel) * 0.7
        if travel < 0 { reach.origin.x -= abs(travel) * 0.7 }
      } else {
        let travel = to.midY - from.midY
        reach.size.height += abs(travel) * 0.7
        if travel < 0 { reach.origin.y -= abs(travel) * 0.7 }
      }
      self.pill.frame = reach
      self.pill.layer.cornerRadius = from.width / 2
    } completion: { _ in
      UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.1, options: [.beginFromCurrentState]) {
        self.pill.frame = to
        self.pill.layer.cornerRadius = to.width / 2
      } completion: { _ in
        self.moving = false
      }
    }
  }

  /// The way of talking changed from elsewhere (the settings): follow it, moving as a tap would.
  func sync(ptt now: Bool) {
    guard now != ptt else { return }
    ptt = now
    accessibilityValue = ptt ? "按住说话" : "免按说话"
    move()
  }

  private func set(_ wantsHold: Bool) {
    guard wantsHold != ptt else { return }
    ptt = wantsHold
    accessibilityValue = ptt ? "按住说话" : "免按说话"
    move()
    choose(ptt ? "ptt" : "vad")
  }

  @objc private func tapped(_ tap: UITapGestureRecognizer) {
    let at = tap.location(in: self)
    set(horizontal ? at.x < bounds.width / 2 : at.y < bounds.height / 2)
  }

  // VoiceOver: a double tap switches to the other way; swiping up or down chooses one.
  override func accessibilityActivate() -> Bool { set(!ptt); return true }
  override func accessibilityIncrement() { set(true) }
  override func accessibilityDecrement() { set(false) }
}
