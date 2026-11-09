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
  /// JARVIS is saying a reply and the button is not held: the microphone turns into a stop key (a square) with a ring that fills
  /// as the voice goes through the words. A tap stops the reply; a hold still talks over it.
  var stopMode = false {
    didSet {
      guard stopMode != oldValue else { return }
      restyle(animated: true)
      updateRing()
    }
  }
  /// How far through the words the voice is, 0...1: the ring.
  var progress: Double = 0 {
    didSet {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      ringArc.strokeEnd = CGFloat(min(max(progress, 0), 1))
      CATransaction.commit()
    }
  }
  /// The progress, a thin arc along the glass edge (no second ring under it: the glass already is the circle).
  private let ringArc = CAShapeLayer()
  override var isHighlighted: Bool {
    didSet {
      guard stopMode, !held, isHighlighted != oldValue else { return }
      UIView.animate(withDuration: 0.1, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
      }
    }
  }
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
    ringArc.fillColor = UIColor.clear.cgColor
    ringArc.lineWidth = 2.5
    ringArc.lineCap = .round
    ringArc.opacity = 0
    ringArc.strokeColor = TalkButton.energy.cgColor
    ringArc.strokeEnd = 0
    layer.addSublayer(ringArc)
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
    layoutRing()
  }

  /// The ring runs round the round button just inside its edge, from the top, clockwise; on the long button it is a line along
  /// the bottom.
  private func layoutRing() {
    let path = UIBezierPath()
    if circular {
      let r = min(bounds.width, bounds.height) / 2 - 1.5
      path.addArc(withCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: r, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true)
    } else {
      path.move(to: CGPoint(x: 28, y: bounds.height - 7))
      path.addLine(to: CGPoint(x: max(28, bounds.width - 28), y: bounds.height - 7))
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ringArc.frame = bounds
    ringArc.path = path.cgPath
    CATransaction.commit()
  }

  private func updateRing() {
    let visible: Float = stopMode ? 1 : 0
    guard ringArc.opacity != visible else { return }
    if UIAccessibility.isReduceMotionEnabled || window == nil {
      ringArc.opacity = visible
    } else {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = ringArc.presentation()?.opacity ?? ringArc.opacity
      fade.toValue = visible
      fade.duration = 0.25
      ringArc.opacity = visible
      ringArc.add(fade, forKey: "fade")
    }
  }


  func restyle(animated: Bool) {
    let mutedLook = muted && !stopMode
    let colour: UIColor = held ? TalkButton.ink : mutedLook ? Palette.error : Palette.onSurface
    let apply = {
      self.backgroundColor = self.circular ? .clear : Palette.containerHigh
      self.fill.colors = [
        UIColor.white.withAlphaComponent(0.2).blended(with: TalkButton.energy).cgColor, TalkButton.energy.cgColor,
        UIColor(red: 0.25, green: 0.56, blue: 0.67, alpha: 1).blended(with: TalkButton.energy, 0.88).cgColor,
      ]
      self.fill.opacity = self.held ? 1 : 0
      self.layer.borderColor = (self.held ? TalkButton.energy.withAlphaComponent(0.5) : mutedLook ? Palette.error : Palette.outlineVariant).resolvedColor(with: self.traitCollection).cgColor
      self.layer.borderWidth = self.circular && !self.held && !mutedLook ? 0 : (mutedLook && !self.held ? 2 : 1)
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
    let bars = circular && !ptt && !stopMode
    if icon.isHidden != bars || listening.isHidden == bars {
      // The two marks trade places with a dissolve, not a cut.
      UIView.transition(with: stack, duration: animated || window != nil ? 0.22 : 0, options: [.transitionCrossDissolve, .allowUserInteraction]) {
        self.icon.isHidden = bars
        self.listening.isHidden = !bars
      }
    }
    let name = stopMode ? "stop.fill" : circular ? "mic.fill" : (muted ? "mic.slash" : held ? "mic.fill" : "mic")
    let size: CGFloat = stopMode ? (circular ? 18 : 15) : (circular ? 30 : 20)
    if let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular)) {
      if animated, window != nil, !icon.isHidden, icon.image != nil, !UIAccessibility.isReduceMotionEnabled {
        // The microphone and the stop square trade places in one move (the symbols' own replace), not a cut.
        icon.setSymbolImage(image, contentTransition: .replace)
      } else {
        icon.image = image
      }
    }
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
  /// While the reply is being said a touch on the button is a tap (stop it) or the start of a hold (talk over it): which, is
  /// known when it has lasted this long or ended.
  static let holdDelay: TimeInterval = 0.25
  private var pendingHold: DispatchWorkItem?
  private var holdStarted = false

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
    talk.addTarget(self, action: #selector(upInside), for: .touchUpInside)
    talk.addTarget(self, action: #selector(upOutside), for: .touchUpOutside)
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
    let held = a["held"] as? Bool ?? talk.held
    talk.stopMode = (a["stoppable"] as? Bool ?? talk.stopMode) && ready && !held
    talk.listeningNow = circular && !ptt && ready && !talk.stopMode && !(a["muted"] as? Bool ?? talk.muted)
    talk.muted = a["muted"] as? Bool ?? talk.muted
    talk.held = held
    let label = a["label"] as? String ?? ""
    talk.title.text = label
    if talk.stopMode {
      talk.accessibilityLabel = "停止朗读"
      talk.accessibilityValue = nil
      talk.accessibilityHint = ptt ? "点按停止，长按说话" : nil
    } else {
      talk.accessibilityLabel = !ptt && ready ? (talk.muted ? "取消静音" : "静音") : label
      talk.accessibilityValue = !ptt && ready ? label : nil
      talk.accessibilityHint = ptt ? "长按说话，松开发送" : nil
    }
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

  /// How far through the words the voice is (the ring of the stop key).
  func setProgress(_ fraction: Double) { talk.progress = fraction }

  @objc private func down() {
    guard ptt else { return }
    if talk.stopMode {
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.pendingHold = nil
        self.holdStarted = true
        self.emit("down", nil)
      }
      pendingHold = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    } else {
      holdStarted = true
      emit("down", nil)
    }
  }

  @objc private func upInside() {
    guard ptt else { return }
    if let work = pendingHold {
      // A tap: stop the reply (if it is still being said).
      work.cancel()
      pendingHold = nil
      if talk.stopMode { emit("stop", nil) }
    } else if holdStarted {
      holdStarted = false
      emit("up", nil)
    } else if talk.stopMode {
      // An activation without a touch down (VoiceOver's double tap): it is the tap of the stop key.
      emit("stop", nil)
    }
  }

  @objc private func upOutside() {
    guard ptt else { return }
    if let work = pendingHold {
      work.cancel()
      pendingHold = nil
    } else if holdStarted {
      holdStarted = false
      emit("up", nil)
    }
  }

  @objc private func cancel() {
    guard ptt else { return }
    if let work = pendingHold {
      work.cancel()
      pendingHold = nil
    } else if holdStarted {
      holdStarted = false
      emit("cancel", nil)
    }
  }

  @objc private func tapped() { if !ptt { emit(talk.stopMode ? "stop" : "mute", nil) } }
}
