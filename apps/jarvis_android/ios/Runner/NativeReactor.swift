import UIKit

private func energy(_ mode: String) -> CGFloat {
  switch mode {
  case "listening": return 0.48
  case "thinking": return 0.72
  case "speaking": return 1
  default: return 0.18
  }
}

private func ease(_ x: CGFloat) -> CGFloat { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

final class ReactorView: UIView {
  private var mode = "idle"
  private var dark = true
  /// Reduce Motion: the ring stands still (drawn once, no display link) and does not pulse.
  private var reduced = UIAccessibility.isReduceMotionEnabled
  private var seconds: Double = 26
  private var signature: CGFloat = 0
  private var direction: CGFloat = 1
  private var phase: Double = 0
  private var started = CACurrentMediaTime()
  private var fromEnergy: CGFloat = 0.18
  private var fromExpressing: CGFloat = 0
  private var blendStart: CFTimeInterval = -10
  private var link: CADisplayLink?
  private var motionObserver: NSObjectProtocol?

  override init(frame: CGRect) {
    super.init(frame: frame)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ReactorView, _: UITraitCollection) in
      view.setNeedsDisplay()
    }
    backgroundColor = .clear
    isOpaque = false
    contentMode = .redraw
    motionObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.reduced = UIAccessibility.isReduceMotionEnabled
        self.updateLink()
        self.setNeedsDisplay()
      }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  func apply(_ a: [String: Any], animated: Bool) {
    let now = CACurrentMediaTime()
    if let newMode = a["mode"] as? String, newMode != mode {
      // From the levels shown right now.
      fromEnergy = currentEnergy(at: now)
      fromExpressing = currentExpressing(at: now)
      blendStart = animated ? now : -10
      mode = newMode
    }
    dark = a["dark"] as? Bool ?? dark
    reduced = a["reduced"] as? Bool ?? reduced
    seconds = a["seconds"] as? Double ?? seconds
    if let s = a["signature"] as? Double { signature = CGFloat(s) }
    if let d = a["direction"] as? Double { direction = CGFloat(d) }
    if let p = a["phase"] as? Double, a["phase"] != nil, window == nil { phase = p }
    setNeedsDisplay()
    updateLink()
  }

  private func blend(at now: CFTimeInterval) -> CGFloat { ease(CGFloat(min(1, max(0, (now - blendStart) / 0.45)))) }
  private func currentEnergy(at now: CFTimeInterval) -> CGFloat {
    let b = blend(at: now)
    return fromEnergy * (1 - b) + energy(mode) * b
  }
  private func currentExpressing(at now: CFTimeInterval) -> CGFloat {
    let b = blend(at: now)
    return fromExpressing * (1 - b) + (mode == "speaking" ? 1 : 0) * b
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateLink()
  }

  private func updateLink() {
    let wants = window != nil && !reduced
    if wants, link == nil {
      let l = CADisplayLink(target: self, selector: #selector(tick))
      l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
      l.add(to: .main, forMode: .common)
      link = l
    } else if !wants {
      link?.invalidate()
      link = nil
    }
  }

  @objc private func tick() { setNeedsDisplay() }

  deinit {
    link?.invalidate()
    if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) }
  }


  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext(), bounds.width > 0, bounds.height > 0 else { return }
    let size = bounds.size
    let now = CACurrentMediaTime()
    let radius = min(size.width * 0.44, size.height * 0.46)
    let cycle = (phase + (now - started) / seconds).truncatingRemainder(dividingBy: 1)
    let t: CGFloat = reduced ? 0 : CGFloat(cycle) * .pi * 2 * direction
    let e = currentEnergy(at: now)
    let expressing = currentExpressing(at: now)
    let pulse: CGFloat = reduced ? 0.5 : 0.5 + 0.5 * sin(t * 12 + signature)
    let expressionPulse: CGFloat = reduced ? 0.5 : 0.5 + 0.5 * sin(t * 36 + signature)
    let daylight: CGFloat = dark ? 0 : 1

    func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
      UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    func tone(_ night: UInt32, _ day: UInt32, nightAlpha: CGFloat = 1, dayAlpha: CGFloat = 1) -> UIColor {
      let n = rgb(night, nightAlpha), d = rgb(day, dayAlpha)
      return daylight == 0 ? n : d
    }
    let white = tone(0xe6f8ff, 0x326579)
    let cyan = tone(0x8fdceb, 0x147f9f)
    let faint = tone(0x39778e, 0x6a9dab)

    ctx.saveGState()
    ctx.translateBy(x: size.width / 2, y: size.height / 2)
    let scale = radius / 100 * (1 + (reduced ? 0 : expressing * 0.032 * expressionPulse))
    ctx.scaleBy(x: scale, y: scale)

    func polar(_ a: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: cos(a) * r, y: sin(a) * r) }
    func radial(_ r: CGFloat, _ colors: [UIColor], _ stops: [CGFloat]? = nil, center: CGPoint = .zero) {
      let space = CGColorSpaceCreateDeviceRGB()
      guard let g = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: stops) else { return }
      ctx.saveGState()
      ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
      ctx.clip()
      ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
      ctx.restoreGState()
    }
    func line(_ a: CGPoint, _ b: CGPoint, _ color: UIColor, _ width: CGFloat) {
      ctx.setStrokeColor(color.cgColor)
      ctx.setLineWidth(width)
      ctx.setLineCap(.round)
      ctx.move(to: a)
      ctx.addLine(to: b)
      ctx.strokePath()
    }
    func ring(_ r: CGFloat, _ color: UIColor, _ width: CGFloat) {
      ctx.setStrokeColor(color.cgColor)
      ctx.setLineWidth(width)
      ctx.strokeEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
    }
    func arc(_ r: CGFloat, _ start: CGFloat, _ sweep: CGFloat, _ color: UIColor, _ width: CGFloat) {
      ctx.setStrokeColor(color.cgColor)
      ctx.setLineWidth(width)
      ctx.setLineCap(.round)
      ctx.addArc(center: .zero, radius: r, startAngle: start, endAngle: start + sweep, clockwise: false)
      ctx.strokePath()
    }
    func dot(_ p: CGPoint, _ r: CGFloat, _ color: UIColor) {
      ctx.setFillColor(color.cgColor)
      ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // Halo and the dark disc.
    radial(
      100,
      [
        cyan.withAlphaComponent((0.16 + e * 0.05 + expressing * 0.12 * expressionPulse) * (1 - daylight) + 0.07 * daylight),
        cyan.withAlphaComponent(0),
      ])
    radial(
      78,
      [
        tone(0x181b1e, 0xe9f8fc), tone(0x0d0f11, 0xcde9f1, dayAlpha: 0.5),
        tone(0x111315, 0xeaf7fa, nightAlpha: 0.4, dayAlpha: 0),
      ], [0, 0.5, 1])

    ring(92, faint.withAlphaComponent(0.17), 0.6)
    for i in 0..<60 {
      let a = CGFloat(i) * .pi / 30 - t * 0.5
      let major = i % 5 == 0
      line(polar(a, major ? 86 : 89), polar(a, 91), faint.withAlphaComponent(major ? 0.55 : 0.22), major ? 0.9 : 0.5)
    }
    arc(96, t, 0.65, cyan.withAlphaComponent(0.55), 0.8)
    arc(96, t + .pi, 0.4, cyan.withAlphaComponent(0.3), 0.8)
    ring(78, white.withAlphaComponent(0.8), 1.4)
    ring(75, faint.withAlphaComponent(0.4), 0.55)

    ctx.saveGState()
    ctx.rotate(by: t * 0.1)
    for i in 0..<10 {
      let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
      let tangent = CGPoint(x: -sin(a), y: cos(a))
      for offset: CGFloat in [-2, 2] {
        let dx = tangent.x * offset, dy = tangent.y * offset
        let p0 = polar(a, 61), p1 = polar(a, 72)
        let from = CGPoint(x: p0.x + dx, y: p0.y + dy), to = CGPoint(x: p1.x + dx, y: p1.y + dy)
        line(from, to, cyan.withAlphaComponent(0.1), 6)
        line(from, to, white.withAlphaComponent(0.76), 1.7)
      }
    }
    ctx.restoreGState()

    ring(55, white.withAlphaComponent(0.75), 1.5)
    ring(52, faint.withAlphaComponent(0.36), 0.6)
    arc(58, -t * 2, 1.35, cyan.withAlphaComponent(0.14), 5)
    arc(58, -t * 2, 1.05, cyan.withAlphaComponent(0.85), 1.3)
    arc(49, t * 3 + .pi, 0.9, cyan.withAlphaComponent(0.6), 0.8)
    for i in 0..<3 {
      let a = -CGFloat.pi / 2 + CGFloat(i) * .pi * 2 / 3
      line(polar(a, 32), polar(a, 47), white.withAlphaComponent(0.65), 2.2)
      dot(polar(a, 48), 1.5, cyan)
    }
    if expressing > 0 {
      arc(83, -t * 7 + signature, 0.7 + expressionPulse * 0.6, cyan.withAlphaComponent(expressing * (0.35 + expressionPulse * 0.4)), 2.2)
    }

    // The central flux.
    radial(30 + e * pulse * 2 + expressing * expressionPulse * 5 + 12, [cyan.withAlphaComponent(0.28), cyan.withAlphaComponent(0)])
    ring(27, cyan.withAlphaComponent(0.14 + e * 0.08), 6)
    ring(27, cyan, 2.8)
    ring(22, faint.withAlphaComponent(0.35), 0.6)
    radial(
      27,
      [
        white.withAlphaComponent(0.45 + e * pulse * 0.25 + expressing * expressionPulse * 0.18), cyan.withAlphaComponent(0.12),
        cyan.withAlphaComponent(0.015),
      ], [0, 0.55, 1])
    for i in 0..<24 {
      let a = CGFloat(i) * .pi / 12
      let wave: CGFloat = reduced ? 0.5 : 0.5 + 0.5 * sin(t * 12 + CGFloat(i) * 0.7 + signature)
      let length = 1.4 + e * (2 + wave * 5) + expressing * (2 + expressionPulse * 6) * wave
      line(polar(a, 34), polar(a, 34 + length), cyan.withAlphaComponent(0.22 + e * 0.35), 1)
    }
    for i in 0..<4 {
      let a = t * (i % 2 == 0 ? 1 : -1) + CGFloat(i) * .pi / 2
      dot(polar(a, i % 2 == 0 ? 82 : 44), i % 2 == 0 ? 1.3 : 0.9, cyan.withAlphaComponent(0.75))
    }
    ctx.restoreGState()
  }
}
