import UIKit

/// The hands-free mark of the round talk button: five rounded bars that breathe while the call is listening, and rest as small
/// dots when it is not.
private final class ListeningBars: UIView {
  private let bars: [UIView] = (0..<5).map { _ in UIView() }
  private static let heights: [CGFloat] = [12, 22, 32, 22, 12]
  private(set) var active = false
  private var laidOut: CGSize = .zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    for bar in bars {
      bar.layer.cornerCurve = .continuous
      bar.transform = CGAffineTransform(scaleX: 1, y: 0.35)
      addSubview(bar)
    }
    isUserInteractionEnabled = false
    NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  override var intrinsicContentSize: CGSize { CGSize(width: 46, height: 34) }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.size != laidOut else { return }
    laidOut = bounds.size
    let width: CGFloat = 5, gap: CGFloat = 5
    let total = CGFloat(bars.count) * width + CGFloat(bars.count - 1) * gap
    var x = (bounds.width - total) / 2
    for (i, bar) in bars.enumerated() {
      let h = Self.heights[i]
      // The frame is set at identity (a frame under a transform is read back scaled), then the transform comes back.
      let transform = bar.transform
      bar.transform = .identity
      bar.frame = CGRect(x: x, y: (bounds.height - h) / 2, width: width, height: h)
      bar.transform = transform
      bar.layer.cornerRadius = width / 2
      x += width + gap
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, active { animate() }
  }

  @objc private func resume() { if active, window != nil { animate() } }

  func setColour(_ colour: UIColor) { bars.forEach { $0.backgroundColor = colour } }

  /// Breathing while listening; with `active` false the bars stand still, small.
  func setActive(_ on: Bool) {
    guard on != active else { return }
    active = on
    if on {
      UIView.animate(withDuration: 0.2) { self.bars.forEach { $0.transform = .identity } }
      animate()
    } else {
      for bar in bars { bar.layer.removeAnimation(forKey: "breathe") }
      UIView.animate(withDuration: 0.25) { self.bars.forEach { $0.transform = CGAffineTransform(scaleX: 1, y: 0.35) } }
    }
  }

  private func animate() {
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    for (i, bar) in bars.enumerated() {
      bar.layer.removeAnimation(forKey: "breathe")
      let a = CABasicAnimation(keyPath: "transform.scale.y")
      a.fromValue = 0.45
      a.toValue = 1.0
      a.duration = 0.55 + Double(i % 3) * 0.13
      a.beginTime = CACurrentMediaTime() + Double(i) * 0.09
      a.autoreverses = true
      a.repeatCount = .infinity
      a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      a.fillMode = .backwards
      bar.layer.add(a, forKey: "breathe")
    }
  }
}

private final class TalkButton: UIControl {
  let icon = UIImageView()
  private let listening = ListeningBars()
  let title = UILabel()
  private let fill = CAGradientLayer()
  private let stack = UIStackView()
  var ptt = true { didSet { if ptt != oldValue { restyle(animated: false) } } }
  /// The call is listening (hands-free and not muted): the bars breathe.
  var listeningNow = false { didSet { listening.setActive(listeningNow) } }
  /// The round, label-less button of the Duo layout.
  var circular = false {
    didSet {
      guard circular != oldValue else { return }
      title.isHidden = circular
      glassView.isHidden = !circular
      if circular, glassView.effect == nil {
        if #available(iOS 26.0, *) {
          let glass = UIGlassEffect(style: .regular)
          glass.isInteractive = true
          glassView.effect = glass
        } else {
          glassView.effect = UIBlurEffect(style: .systemThinMaterial)
        }
      }
      setNeedsLayout()
      restyle(animated: false)
    }
  }
  /// The see-through round button of the Duo layout: system glass, the hand-free / held state drawn over it.
  private let glassView = UIVisualEffectView(effect: nil)
  var held = false { didSet { if held != oldValue { restyle(animated: true) } } }
  var muted = false { didSet { if muted != oldValue { restyle(animated: true) } } }
  override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.38 } }

  private static let energy = UIColor(red: 0.561, green: 0.863, blue: 0.922, alpha: 1)
  private static let ink = UIColor(red: 0.082, green: 0.129, blue: 0.149, alpha: 1)

  override init(frame: CGRect) {
    super.init(frame: frame)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TalkButton, _: UITraitCollection) in
      view.restyle(animated: false)
    }
    layer.cornerRadius = 20
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.masksToBounds = false
    fill.cornerRadius = 20
    fill.cornerCurve = .continuous
    fill.startPoint = .zero
    fill.endPoint = CGPoint(x: 1, y: 1)
    fill.opacity = 0
    glassView.isHidden = true
    glassView.isUserInteractionEnabled = false
    glassView.clipsToBounds = true
    addSubview(glassView)
    layer.insertSublayer(fill, at: 0)
    icon.contentMode = .center
    title.font = .systemFont(ofSize: 16, weight: .semibold)
    stack.axis = .horizontal
    stack.spacing = 10
    stack.alignment = .center
    stack.isUserInteractionEnabled = false
    stack.addArrangedSubview(icon)
    stack.addArrangedSubview(listening)
    listening.isHidden = true
    stack.addArrangedSubview(title)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
    ])
    isAccessibilityElement = true
    accessibilityTraits = .button
    restyle(animated: false)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    fill.frame = bounds
    glassView.frame = bounds
    glassView.layer.cornerRadius = min(bounds.width, bounds.height) / 2
    let radius = circular ? min(bounds.width, bounds.height) / 2 : 20
    layer.cornerRadius = radius
    fill.cornerRadius = radius
  }


  func restyle(animated: Bool) {
    let colour: UIColor = held ? TalkButton.ink : muted ? Palette.error : Palette.onSurface
    let apply = {
      self.backgroundColor = self.circular ? .clear : Palette.containerHigh
      self.fill.colors = [
        UIColor.white.withAlphaComponent(0.2).blended(with: TalkButton.energy).cgColor, TalkButton.energy.cgColor,
        UIColor(red: 0.25, green: 0.56, blue: 0.67, alpha: 1).blended(with: TalkButton.energy, 0.88).cgColor,
      ]
      self.fill.opacity = self.held ? 1 : 0
      self.layer.borderColor = (self.held ? TalkButton.energy.withAlphaComponent(0.5) : self.muted ? Palette.error : Palette.outlineVariant).resolvedColor(with: self.traitCollection).cgColor
      self.layer.borderWidth = self.circular && !self.held && !self.muted ? 0 : (self.muted && !self.held ? 2 : 1)
      self.layer.shadowColor = TalkButton.energy.cgColor
      self.layer.shadowOpacity = self.held ? 0.34 : 0
      self.layer.shadowRadius = 11
      self.layer.shadowOffset = .zero
      self.transform = self.held ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
      self.title.textColor = colour
      self.icon.tintColor = colour
      self.listening.setColour(colour)
    }
    // Hold-to-talk keeps the microphone; hands-free (the round button) is drawn as sound bars, not a second microphone.
    let bars = circular && !ptt
    if icon.isHidden != bars || listening.isHidden == bars {
      // The two marks trade places with a dissolve, not a cut.
      UIView.transition(with: stack, duration: animated || window != nil ? 0.22 : 0, options: [.transitionCrossDissolve, .allowUserInteraction]) {
        self.icon.isHidden = bars
        self.listening.isHidden = !bars
      }
    }
    let name = circular ? "mic.fill" : (muted ? "mic.slash" : held ? "mic.fill" : "mic")
    icon.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: circular ? 30 : 20, weight: .regular))
    if animated && !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: held ? 0.08 : 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: apply)
    } else {
      apply()
    }
  }
}

private extension UIColor {
  func blended(with other: UIColor, _ amount: CGFloat = 0.5) -> UIColor {
    var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), b = a
    getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
    other.getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
    return UIColor(red: a.0 + (b.0 - a.0) * amount, green: a.1 + (b.1 - a.1) * amount, blue: a.2 + (b.2 - a.2) * amount, alpha: 1)
  }
}

/// The controls themselves, with no Flutter in it: what they report goes to `emit` (`down`, `up`, `cancel`, `mute`,
/// `mode`), the owner's state comes through `apply`.
final class NativeCallControls: NSObject {
  private let root = UIView()
  var emit: (String, Any?) -> Void = { _, _ in }
  private let selector = UIView()
  private let talk = TalkButton()
  private var buttons: [String: UIButton] = [:]
  private var short = false
  private var circular = false
  private var ptt = true
  private var ready = true
  private var constraintsSet: [NSLayoutConstraint] = []

  init(frame: CGRect, args: [String: Any]) {
    super.init()
    root.frame = frame
    root.backgroundColor = .clear
    build()
    apply(args)
  }

  func view() -> UIView { root }

  private func build() {
    // The original's mode chooser: a rounded track with the hairline, the chosen segment raised inside it.
    let box = UIVisualEffectView(effect: nil)
    box.styleSurface(Palette.card, radius: Radii.large, border: Palette.outlineVariant)
    box.clipsToBounds = true
    box.translatesAutoresizingMaskIntoConstraints = false
    selector.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(box)
    root.addSubview(selector)
    let row = UIStackView()
    row.axis = .horizontal
    row.distribution = .fillEqually
    row.spacing = 4
    row.translatesAutoresizingMaskIntoConstraints = false
    for (id, label, symbol) in [("ptt", "按住说话", "hand.tap"), ("vad", "免按对话", "ear")] {
      var c = UIButton.Configuration.plain()
      c.title = label
      c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
      c.imagePadding = 6
      c.cornerStyle = .fixed
      c.background.cornerRadius = Radii.medium
      c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
        var a = $0
        a.font = .systemFont(ofSize: 14, weight: .semibold)
        return a
      }
      let b = UIButton(configuration: c)
      b.addAction(UIAction { [weak self] _ in
        if self?.ptt != (id == "ptt") { UISelectionFeedbackGenerator().selectionChanged() }
        self?.emit("mode", id)
      }, for: .touchUpInside)
      buttons[id] = b
      row.addArrangedSubview(b)
    }
    box.contentView.addSubview(row)
    box.contentView.layoutMargins = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
    selector.addSubview(box)
    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: box.contentView.layoutMarginsGuide.topAnchor),
      row.bottomAnchor.constraint(equalTo: box.contentView.layoutMarginsGuide.bottomAnchor),
      row.leadingAnchor.constraint(equalTo: box.contentView.layoutMarginsGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: box.contentView.layoutMarginsGuide.trailingAnchor),
    ])
    box.removeFromSuperview()
    selector.addSubview(box)
    NSLayoutConstraint.activate([
      box.topAnchor.constraint(equalTo: selector.topAnchor), box.bottomAnchor.constraint(equalTo: selector.bottomAnchor),
      box.leadingAnchor.constraint(equalTo: selector.leadingAnchor), box.trailingAnchor.constraint(equalTo: selector.trailingAnchor),
    ])
    talk.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(talk)
    talk.addTarget(self, action: #selector(down), for: .touchDown)
    talk.addTarget(self, action: #selector(up), for: [.touchUpInside, .touchUpOutside])
    talk.addTarget(self, action: #selector(cancel), for: .touchCancel)
    talk.addTarget(self, action: #selector(tapped), for: .touchUpInside)
  }

  private var placedFor: String?

  private func place() {
    let key = "\(short)|\(circular)"
    guard key != placedFor else { return }
    placedFor = key
    NSLayoutConstraint.deactivate(constraintsSet)
    let gap: CGFloat = short ? 6 : 10
    let h: CGFloat = short ? 54 : 56
    selector.isHidden = circular
    talk.circular = circular
    if circular {
      // Duo: one round button, centred, the size of the one the other apps' voice pages have.
      constraintsSet = [
        talk.topAnchor.constraint(equalTo: root.topAnchor), talk.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        talk.widthAnchor.constraint(equalToConstant: 80), talk.heightAnchor.constraint(equalToConstant: 80),
      ]
      NSLayoutConstraint.activate(constraintsSet)
      return
    }
    constraintsSet = [
      selector.topAnchor.constraint(equalTo: root.topAnchor), selector.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      selector.trailingAnchor.constraint(equalTo: root.trailingAnchor), selector.heightAnchor.constraint(equalToConstant: h),
      talk.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: gap), talk.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      talk.trailingAnchor.constraint(equalTo: root.trailingAnchor), talk.heightAnchor.constraint(equalToConstant: h),
    ]
    NSLayoutConstraint.activate(constraintsSet)
  }

  func apply(_ a: [String: Any]) {
    short = a["short"] as? Bool ?? short
    circular = a["circular"] as? Bool ?? circular
    ptt = a["ptt"] as? Bool ?? ptt
    ready = a["ready"] as? Bool ?? ready
    place()
    talk.ptt = ptt
    talk.isEnabled = ready
    talk.listeningNow = circular && !ptt && ready && !(a["muted"] as? Bool ?? talk.muted)
    talk.muted = a["muted"] as? Bool ?? talk.muted
    talk.held = a["held"] as? Bool ?? talk.held
    let label = a["label"] as? String ?? ""
    talk.title.text = label
    talk.accessibilityLabel = !ptt && ready ? (talk.muted ? "取消静音" : "静音") : label
    talk.accessibilityValue = !ptt && ready ? label : nil
    talk.accessibilityHint = ptt ? "长按说话，松开发送" : nil
    for (id, b) in buttons {
      let on = (id == "ptt") == ptt
      var c = b.configuration
      c?.baseForegroundColor = on ? Palette.onSurface : Palette.onSurfaceVariant
      c?.background.backgroundColor = on ? Palette.containerHigh : .clear
      c?.background.strokeColor = on ? Palette.outlineVariant : .clear
      c?.background.strokeWidth = on ? 1 : 0
      c?.image = UIImage(
        systemName: on ? "checkmark.circle" : (id == "ptt" ? "hand.tap" : "ear"),
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
      b.configuration = c
      b.accessibilityTraits = on ? [.button, .selected] : .button
    }
  }

  @objc private func down() { if ptt { emit("down", nil) } }
  @objc private func up() { if ptt { emit("up", nil) } }
  @objc private func cancel() { if ptt { emit("cancel", nil) } }
  @objc private func tapped() { if !ptt { emit("mute", nil) } }
}
