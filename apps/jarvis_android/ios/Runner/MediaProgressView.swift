import UIKit

/// The running part of a picture or video card: what the service is doing, a percentage that keeps moving, the time spent and the
/// time still to go. The numbers come from `MediaProgress` (the service's real reports plus how long earlier runs took); this view
/// only draws them, easing the bar towards where it should be and never taking it back.
final class MediaProgressView: UIView {
  /// How far each card's bar has been drawn (kept apart from the view: the card is rebuilt on every report).
  private static var drawn: [String: (start: Double, value: Double)] = [:]

  private let stage = UILabel()
  private let percent = UILabel()
  private let spent = UILabel()
  private let left = UILabel()
  private let bar = Bar()
  private var task: RowData.Task?
  private var link: CADisplayLink?
  private var lastDraw = 0.0

  override init(frame: CGRect) {
    super.init(frame: frame)
    stage.font = .systemFont(ofSize: 14, weight: .medium)
    stage.textColor = Palette.onSurface
    percent.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    percent.textColor = Palette.accent
    percent.textAlignment = .right
    percent.setContentHuggingPriority(.required, for: .horizontal)
    percent.setContentCompressionResistancePriority(.required, for: .horizontal)
    for l in [spent, left] {
      l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      l.textColor = Palette.onSurfaceVariant
    }
    spent.numberOfLines = 0
    left.textAlignment = .right
    left.numberOfLines = 0
    left.setContentHuggingPriority(.required, for: .horizontal)
    left.setContentCompressionResistancePriority(.required, for: .horizontal)
    let top = UIStackView(arrangedSubviews: [stage, percent])
    top.spacing = 8
    let meta = UIStackView(arrangedSubviews: [spent, left])
    meta.spacing = 8
    let column = UIStackView(arrangedSubviews: [top, bar, meta])
    column.axis = .vertical
    column.spacing = 6
    column.setCustomSpacing(8, after: top)
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
      column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
      bar.heightAnchor.constraint(equalToConstant: 6),
    ])
    isAccessibilityElement = true
    accessibilityTraits = .updatesFrequently
  }

  required init?(coder: NSCoder) { fatalError() }

  func update(_ task: RowData.Task) {
    self.task = task
    syncLink()
    redraw(now: Date().timeIntervalSince1970, dt: 1)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    link?.invalidate()
    link = nil
    syncLink()
  }

  /// The display link runs only while the job does and the view is on screen (a view that is reused may change from one to the other).
  private func syncLink() {
    guard window != nil, task?.pending == true else {
      link?.invalidate()
      link = nil
      return
    }
    guard link == nil else { return }
    let ticker = Ticker(self)
    let l = CADisplayLink(target: ticker, selector: #selector(Ticker.fire(_:)))
    l.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
    l.add(to: .main, forMode: .common)
    link = l
  }

  fileprivate func tick(_ l: CADisplayLink) {
    redraw(now: Date().timeIntervalSince1970, dt: l.targetTimestamp - l.timestamp)
  }

  /// A card whose run has ended without a picture: the bar and the clock stand still, and it says why and how far it got.
  private func drawStopped(_ task: RowData.Task) {
    let cancelled = task.error == MediaCopy.cancelled
    stage.text = cancelled ? MediaCopy.cancelledTitle(task.kind) : MediaCopy.failedTitle(task.kind)
    stage.textColor = cancelled ? Palette.onSurfaceVariant : Palette.error
    // The bar is where it was drawn when the run ended (it is time-weighted, not the raw number); the percent says the same.
    let fraction = min(max(Self.drawn[task.id]?.value ?? task.progress / 100, 0), 0.99)
    let shown = Int(fraction * 100)
    percent.text = shown > 0 ? "停在 \(shown)%" : ""
    percent.textColor = Palette.onSurfaceVariant
    bar.muted = true
    bar.fraction = fraction
    spent.text = cancelled ? "" : (MediaCopy.shown(task.error, kind: task.kind) ?? "")
    spent.textColor = Palette.onSurfaceVariant
    spent.font = .systemFont(ofSize: 12)
    if let track = task.track {
      left.text = "用时 " + MediaProgress.clock((track.lastAt ?? track.startedAt) - track.startedAt)
    } else {
      left.text = ""
    }
    left.textColor = Palette.onSurfaceVariant
    accessibilityLabel = stage.text
    accessibilityValue = [percent.text, MediaCopy.shown(task.error, kind: task.kind)].compactMap { $0 }.joined(separator: "，")
  }

  private func redraw(now: Double, dt: Double) {
    guard let task else { return }
    if !task.pending { return drawStopped(task) }
    bar.muted = false
    stage.textColor = Palette.onSurface
    percent.textColor = Palette.accent
    spent.textColor = Palette.onSurfaceVariant
    spent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let plan = task.plan ?? MediaTimings.prior.plan(kind: task.kind, args: [:])
    let snap = MediaProgress.snapshot(track: task.track, plan: plan, now: now)
    let start = task.track?.startedAt ?? 0
    var state = Self.drawn[task.id]
    if state == nil || state!.start != start { state = (start, 0) }
    var value = state!.value
    if snap.fraction > value {
      value = UIAccessibility.isReduceMotionEnabled ? snap.fraction : value + (snap.fraction - value) * min(1, max(dt, 0.02) / 0.45)
      if snap.fraction - value < 0.0005 { value = snap.fraction }
    }
    Self.drawn[task.id] = (start, value)
    bar.fraction = value
    let shown = min(Int(value * 100), 99)
    percent.text = "\(shown)%"
    let name = MediaProgress.label(snap.stage, kind: task.kind)
    stage.text = name
    spent.text = "已用 " + MediaProgress.clock(snap.elapsed)
    if snap.stalled {
      left.text = "这可能需要几分钟。"
      left.textColor = Palette.warning
    } else if snap.late || snap.remaining == nil {
      left.text = snap.stage == .waiting ? "" : "这可能需要几分钟。"
      left.textColor = Palette.onSurfaceVariant
    } else {
      let span = MediaProgress.span(snap.remaining ?? 0)
      left.text = snap.stage == .waiting ? "开始后预计\(span)" : "还需\(span)"
      left.textColor = Palette.onSurfaceVariant
    }
    let label = (task.kind == "video" ? "视频" : "图片") + name
    if accessibilityLabel != label { accessibilityLabel = label }
    // Said only when it has moved by a tenth: a voice reading every second would talk over everything else.
    let value10 = "\(shown / 10 * 10)%，\(left.text ?? "")"
    if accessibilityValue != value10 { accessibilityValue = value10 }
  }

  /// Drawn without a layer animation: the display link already moves it every frame.
  private final class Bar: UIView {
    private let fill = UIView()
    var fraction: Double = 0 {
      didSet { if fraction != oldValue { setNeedsLayout() } }
    }
    /// A run that has ended: the fill is grey, not the accent.
    var muted = false {
      didSet { if muted != oldValue { fill.backgroundColor = muted ? Palette.onSurfaceVariant.withAlphaComponent(0.45) : Palette.accent } }
    }
    init() {
      super.init(frame: .zero)
      backgroundColor = Palette.outlineVariant
      fill.backgroundColor = Palette.accent
      addSubview(fill)
      layer.cornerRadius = 3
      clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
      super.layoutSubviews()
      fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(min(max(fraction, 0), 1)), height: bounds.height)
    }
  }

  /// The link holds its target; this keeps the view from being held by it.
  private final class Ticker: NSObject {
    weak var view: MediaProgressView?
    init(_ view: MediaProgressView) { self.view = view }
    @objc func fire(_ l: CADisplayLink) {
      guard let view, view.window != nil else { return l.invalidate() }
      view.tick(l)
    }
  }
}
