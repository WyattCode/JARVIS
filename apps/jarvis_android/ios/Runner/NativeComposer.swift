import UIKit

/// The chat's message box as real system UI: a Liquid Glass frame with a growing text view, the attach and thinking-depth
/// menus, and the mic / send / stop buttons. Flutter lays it out (where it stands, how wide, the keyboard) and keeps what
/// it is about (the draft, whether a reply is running, the attachments); this view shows that and reports what the user does.
///
/// creationParams and `update`: see [ComposerState]. Reports to `ai.jarvis.app/composer/<viewId>`:
/// `draft` (text), `send`, `stop`, `voice`, `attach` (photos | camera | files), `effort` (id), `focus` (Bool) and `height`
/// (what the view wants, whenever it changes). Flutter can send `focus`, `blur` and `draft` (replace the text).
struct ComposerState {
  var draft = ""
  var generating = false
  /// Sending is possible once there is something to send (signed in, a model, attachments done).
  var ready = false
  var hasAttachments = false
  var blocked: String?
  var effort = "high"
  var attachesPhotos = true
  var compact = false
  var foldable = false
  var maxFieldHeight: Double = 160
  var loading = false
  var model = ""

  init(_ a: [String: Any]) {
    draft = a["draft"] as? String ?? ""
    update(a)
  }

  mutating func update(_ a: [String: Any]) {
    generating = a["generating"] as? Bool ?? generating
    ready = a["ready"] as? Bool ?? ready
    hasAttachments = a["hasAttachments"] as? Bool ?? hasAttachments
    blocked = a.keys.contains("blocked") ? a["blocked"] as? String : blocked
    effort = a["effort"] as? String ?? effort
    attachesPhotos = a["attachesPhotos"] as? Bool ?? attachesPhotos
    compact = a["compact"] as? Bool ?? compact
    foldable = a["foldable"] as? Bool ?? foldable
    maxFieldHeight = a["maxFieldHeight"] as? Double ?? maxFieldHeight
    loading = a["loading"] as? Bool ?? loading
    model = a["model"] as? String ?? model
  }
}

private final class ComposerRoot: UIView {
  var onLayout: (() -> Void)?
  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }
}

private let effortNames = ["none": "关闭", "low": "低", "medium": "中", "high": "高"]
private let effortSymbols = [
  // Not a meter: each depth is a thing of its own. Off, a quick spark, an idea, a thinking head.
  "none": "nosign", "low": "bolt", "medium": "lightbulb", "high": "brain.head.profile",
]

/// The message box itself, with no Flutter in it: what it reports goes to `emit` (`draft`, `send`, `stop`, `voice`,
/// `attach`, `effort`, `focus`, `height`), what its owner tells it comes through `handle` (`update`, `draft`, `focus`,
/// `blur`). The Flutter platform view and the native chat page both own one.
final class NativeComposer: NSObject, UITextViewDelegate {
  private let root: ComposerRoot
  var emit: (String, Any?) -> Void = { _, _ in }
  private var state: ComposerState

  private let frameView: UIVisualEffectView
  private let textView = UITextView()
  private let placeholder = UILabel()
  private let hint = UILabel()
  private let plus = UIButton(type: .system)
  private let effort = UIButton(type: .system)
  private let sideMic = UIButton(type: .system)
  private let main = UIButton(type: .system)
  private let buttons = UIStackView()
  /// The attachments of the message, inside the box above its text.
  let attachments = ComposerAttachments()
  private var reported: CGFloat = 0

  init(frame: CGRect, args: [String: Any]) {
    root = ComposerRoot(frame: frame)
    state = ComposerState(args)
    let effect: UIVisualEffect
    if #available(iOS 26.0, *) {
      effect = UIGlassEffect(style: .regular)
    } else {
      effect = UIBlurEffect(style: .systemThinMaterial)
    }
    frameView = UIVisualEffectView(effect: effect)
    super.init()
    root.backgroundColor = .clear
    build()
    textView.text = state.draft
    root.onLayout = { [weak self] in
      self?.fitText()
      self?.report()
    }
    refresh()
  }

  func view() -> UIView { root }

  /// The box's own text field has the keyboard.
  var isEditing: Bool { textView.isFirstResponder }

  /// What the owner tells the box; false when it is something this does not know.
  @discardableResult
  func handle(_ method: String, _ arguments: Any?) -> Bool {
    switch method {
    case "update":
      state.update(arguments as? [String: Any] ?? [:])
      refresh()
    case "draft":
      let text = (arguments as? String) ?? ""
      if textView.text != text {
        textView.text = text
        state.draft = text
        textChanged()
      }
    case "focus": textView.becomeFirstResponder()
    case "blur": textView.resignFirstResponder()
    default: return false
    }
    return true
  }

  // MARK: Building

  /// The composer's microphone, drawn here: a full, round capsule, a soft cradle under it and a short stem with a rounded foot, all
  /// the same rounded stroke weight, so it sits in the round button as one soft shape (the system's is boxier).
  static func softMic(size: CGFloat) -> UIImage {
    let unit = size / 24
    let canvas = CGSize(width: size, height: size)
    return UIGraphicsImageRenderer(size: canvas).image { context in
      let c = context.cgContext
      c.scaleBy(x: unit, y: unit)
      c.setFillColor(UIColor.black.cgColor)
      c.setStrokeColor(UIColor.black.cgColor)
      c.setLineCap(.round)
      c.setLineJoin(.round)
      c.setLineWidth(2)
      // The capsule: 8 wide, 13 tall, fully round.
      c.addPath(UIBezierPath(roundedRect: CGRect(x: 8, y: 1.5, width: 8, height: 13), cornerRadius: 4).cgPath)
      c.fillPath()
      // The cradle: a half circle round the foot of the capsule.
      let cradle = UIBezierPath(arcCenter: CGPoint(x: 12, y: 10.5), radius: 6.6, startAngle: 0, endAngle: .pi, clockwise: true)
      c.addPath(cradle.cgPath)
      c.strokePath()
      // The stem and the foot.
      c.move(to: CGPoint(x: 12, y: 17.2))
      c.addLine(to: CGPoint(x: 12, y: 21))
      c.move(to: CGPoint(x: 8.8, y: 21.2))
      c.addLine(to: CGPoint(x: 15.2, y: 21.2))
      c.strokePath()
    }.withRenderingMode(.alwaysTemplate)
  }

  private func circle(_ button: UIButton, symbol: String, label: String) {
    var configuration = UIButton.Configuration.plain()
    configuration.image = UIImage(
      systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
    configuration.cornerStyle = .capsule
    button.configuration = configuration
    button.accessibilityLabel = label
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 36), button.heightAnchor.constraint(equalToConstant: 36),
    ])
  }

  private func build() {
    // Liquid Glass: the box is clear glass over the page, so that what scrolls past (and the keyboard's own glass under it) shows through,
    // blurred, as on the system's own pages; a light tint of the card colour keeps the text readable, and a hairline draws the edge.
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      // More of the card colour on light (dark text behind a light glass is harder to look past than light text behind a dark one).
      glass.tintColor = UIColor { trait in
        Palette.composer.resolvedColor(with: trait).withAlphaComponent(trait.userInterfaceStyle == .dark ? 0.3 : 0.6)
      }
      glass.isInteractive = false
      frameView.effect = glass
      frameView.styleSurface(.clear, radius: 28, border: Palette.composerEdge.withAlphaComponent(0.5))
    } else {
      frameView.effect = UIBlurEffect(style: .systemThinMaterial)
      frameView.styleSurface(Palette.composer.withAlphaComponent(0.6), radius: 28, border: Palette.composerEdge)
    }
    frameView.clipsToBounds = true
    frameView.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(frameView)
    NSLayoutConstraint.activate([
      frameView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      frameView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      frameView.topAnchor.constraint(equalTo: root.topAnchor),
    ])

    attachments.translatesAutoresizingMaskIntoConstraints = false
    frameView.contentView.addSubview(attachments)
    NSLayoutConstraint.activate([
      attachments.leadingAnchor.constraint(equalTo: frameView.contentView.leadingAnchor),
      attachments.trailingAnchor.constraint(equalTo: frameView.contentView.trailingAnchor),
      attachments.topAnchor.constraint(equalTo: frameView.contentView.topAnchor),
    ])
    // The box grows with the row (and gives the room back when the last one is taken off).
    attachments.onHeight = { [weak self] in
      guard let self else { return }
      self.root.setNeedsLayout()
      self.report()
    }

    textView.backgroundColor = .clear
    textView.font = .systemFont(ofSize: 17)
    textView.textColor = Palette.onSurface
    textView.tintColor = Palette.accent
    textView.delegate = self
    textView.isScrollEnabled = false
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 4, bottom: 8, right: 4)
    textView.textContainer.lineFragmentPadding = 10
    textView.returnKeyType = .default
    textView.accessibilityLabel = "发送消息"
    textView.translatesAutoresizingMaskIntoConstraints = false

    placeholder.text = "发送消息…"
    placeholder.font = .systemFont(ofSize: 17)
    placeholder.textColor = Palette.onSurfaceVariant.withAlphaComponent(0.7)
    placeholder.isUserInteractionEnabled = false
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    textView.addSubview(placeholder)
    NSLayoutConstraint.activate([
      placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 14),
      placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 16),
    ])

    hint.font = .systemFont(ofSize: 13)
    hint.textColor = Palette.onSurfaceVariant
    hint.numberOfLines = 0
    hint.isHidden = true

    circle(plus, symbol: "plus", label: "添加附件")
    plus.tintColor = Palette.onSurface
    var plusConfiguration = plus.configuration ?? UIButton.Configuration.plain()
    plusConfiguration = UIButton.Configuration.filled()
    plusConfiguration.cornerStyle = .capsule
    plusConfiguration.baseBackgroundColor = Palette.composerControl
    plusConfiguration.baseForegroundColor = Palette.onSurface
    plusConfiguration.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .light))
    plus.configuration = plusConfiguration

    var effortConfiguration = UIButton.Configuration.plain()
    effortConfiguration.image = UIImage(
      systemName: "lightbulb", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    effortConfiguration.imagePadding = 6
    effortConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
    effortConfiguration.baseForegroundColor = Palette.onSurface
    effort.configuration = effortConfiguration
    effort.tintColor = Palette.onSurfaceVariant
    effort.setContentHuggingPriority(.required, for: .horizontal)

    circle(sideMic, symbol: "mic", label: "语音对话")
    sideMic.addTarget(self, action: #selector(voiceTapped), for: .touchUpInside)
    circle(main, symbol: "mic", label: "语音对话")
    main.addTarget(self, action: #selector(mainTapped), for: .touchUpInside)

    buttons.axis = .horizontal
    buttons.alignment = .center
    buttons.spacing = 8
  }

  // MARK: Layout

  /// Rebuilds the arrangement the state asks for: the field above a row of buttons, or one row (a short window).
  private func arrange() {
    fieldHeight?.isActive = false
    fieldHeight = nil
    textView.removeFromSuperview()
    hint.removeFromSuperview()
    buttons.removeFromSuperview()
    buttons.arrangedSubviews.forEach { buttons.removeArrangedSubview($0); $0.removeFromSuperview() }
    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let content = frameView.contentView
    buttons.translatesAutoresizingMaskIntoConstraints = false
    textView.translatesAutoresizingMaskIntoConstraints = false
    hint.translatesAutoresizingMaskIntoConstraints = false
    if state.compact {
      buttons.addArrangedSubview(plus)
      buttons.addArrangedSubview(effort)
      buttons.addArrangedSubview(textView)
      buttons.addArrangedSubview(sideMic)
      buttons.addArrangedSubview(main)
      buttons.alignment = .bottom
      content.addSubview(buttons)
      NSLayoutConstraint.activate([
        buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
        buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
        buttons.topAnchor.constraint(equalTo: attachments.bottomAnchor, constant: 4),
        buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
      ])
    } else {
      buttons.alignment = .center
      buttons.addArrangedSubview(plus)
      buttons.addArrangedSubview(effort)
      buttons.addArrangedSubview(spacer)
      buttons.addArrangedSubview(sideMic)
      buttons.addArrangedSubview(main)
      content.addSubview(textView)
      content.addSubview(hint)
      content.addSubview(buttons)
      NSLayoutConstraint.activate([
        textView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 0),
        textView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 0),
        textView.topAnchor.constraint(equalTo: attachments.bottomAnchor, constant: 0),
        hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
        hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
        hint.topAnchor.constraint(equalTo: textView.bottomAnchor),
        buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
        buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
        buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 0),
        buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
      ])
    }
    bottomAnchor?.isActive = false
    let bottom = root.bottomAnchor.constraint(equalTo: frameView.bottomAnchor)
    bottom.isActive = true
    bottomAnchor = bottom
  }

  private var bottomAnchor: NSLayoutConstraint?
  private var arranged: Bool?

  private var fieldHeight: NSLayoutConstraint?

  /// The text view grows with its text up to the most Flutter allows, then scrolls inside itself.
  private func fitText() {
    // Laid out for the width it really has; before it has one, for the width the frame will give it.
    let width = textView.bounds.width > 1 ? textView.bounds.width : max(1, root.bounds.width - 16)
    let fit = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    let minimum: CGFloat = state.compact ? 36 : 54
    let wanted = min(max(fit, minimum), CGFloat(state.maxFieldHeight))
    textView.isScrollEnabled = fit > wanted + 0.5
    if let fieldHeight {
      if abs(fieldHeight.constant - wanted) > 0.5 { fieldHeight.constant = wanted }
    } else {
      let height = textView.heightAnchor.constraint(equalToConstant: wanted)
      height.priority = .required
      height.isActive = true
      fieldHeight = height
    }
  }

  private func refresh() {
    updateMenus()
    if arranged != state.compact {
      arranged = state.compact
      arrange()
    }
    let hasDraft =
      !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.hasAttachments
    let showSend = hasDraft || state.generating
    let canSend = state.ready && hasDraft
    placeholder.isHidden = !textView.text.isEmpty
    // The side mic comes in beside the send button once there is something to send.
    sideMic.isHidden = !showSend
    var mainSymbol = "mic.fill"
    var mainLabel = "语音对话"
    if showSend {
      mainSymbol = state.generating ? "stop.fill" : "arrow.up"
      mainLabel = state.generating ? "停止当前回复" : "发送"
    }
    // A 40 pt round button: a soft circle with the mic when there is nothing to send; the primary colour with an arrow (or the
    // stop square) when there is. Not sendable yet, it is the same circle with its icon dimmed.
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.image = showSend
      ? UIImage(systemName: mainSymbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
      : Self.softMic(size: 21)
    // The bright round button of the Claude app's composer: voice at rest, send (or stop) once there is something to send.
    configuration.baseBackgroundColor = Palette.onSurface.withAlphaComponent(showSend && !(state.generating || canSend) ? 0.38 : 1)
    configuration.baseForegroundColor = Palette.surface
    main.configuration = configuration
    main.configurationUpdateHandler = nil
    main.accessibilityLabel = mainLabel
    main.isUserInteractionEnabled = !showSend || state.generating || canSend
    var sideConfiguration = UIButton.Configuration.filled()
    sideConfiguration.cornerStyle = .capsule
    sideConfiguration.baseBackgroundColor = Palette.composerControl
    sideConfiguration.baseForegroundColor = Palette.onSurface
    sideConfiguration.image = Self.softMic(size: 19)
    sideMic.configuration = sideConfiguration

    // The pill beside the plus: the word in the text colour, the level after it in the quieter one ("Sonnet 5.5 中等").
    var effortConfiguration = UIButton.Configuration.filled()
    effortConfiguration.cornerStyle = .capsule
    effortConfiguration.baseBackgroundColor = Palette.composerControl
    effortConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    let label = NSMutableAttributedString(
      string: "思考 ", attributes: [.font: UIFont.systemFont(ofSize: 15.5), .foregroundColor: Palette.onSurface])
    label.append(
      NSAttributedString(
        string: effortNames[state.effort] ?? state.effort, attributes: [.font: UIFont.systemFont(ofSize: 15.5), .foregroundColor: Palette.onSurfaceVariant]))
    effortConfiguration.attributedTitle = AttributedString(label)
    effort.configuration = effortConfiguration
    effort.heightAnchor.constraint(equalToConstant: 36).isActive = effort.constraints.isEmpty
    effort.accessibilityLabel = "思考深度，当前\(effortNames[state.effort] ?? state.effort)"
    plus.isHidden = false

    hint.text = hasDraft ? state.blocked : nil
    hint.isHidden = hint.text == nil || state.compact
    fitText()
    root.setNeedsLayout()
  }

  private func report() {
    root.layoutIfNeeded()
    let fit = frameView.systemLayoutSizeFitting(
      CGSize(width: root.bounds.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
    ).height
    guard abs(fit - reported) > 0.5 else { return }
    reported = fit
    emit("height", Double(fit))
  }

  // MARK: Text

  func textViewDidChange(_ textView: UITextView) { textChanged() }

  private func textChanged() {
    state.draft = textView.text
    emit("draft", textView.text)
    refresh()
  }

  func textViewDidBeginEditing(_ textView: UITextView) { emit("focus", true) }
  func textViewDidEndEditing(_ textView: UITextView) { emit("focus", false) }

  // MARK: Actions

  private var hostView: UIView? {
    var view: UIView? = root
    while let next = view?.superview { view = next }
    return view
  }

  /// The attach and thinking-depth menus are the system's own (a button that shows its menu when pressed); the choice is
  /// reported as `attach` or `effort`.
  private var menusBound = false

  private func updateMenus() {
    guard !menusBound else { return }
    menusBound = true
    plus.menu = nil
    effort.menu = nil
    plus.showsMenuAsPrimaryAction = false
    effort.showsMenuAsPrimaryAction = false
    plus.removeTarget(nil, action: nil, for: .touchUpInside)
    effort.removeTarget(nil, action: nil, for: .touchUpInside)
    plus.addAction(UIAction { [weak self] _ in self?.plusPressed() }, for: .touchUpInside)
    effort.addAction(UIAction { [weak self] _ in self?.effortPressed() }, for: .touchUpInside)
  }

  /// The attach menu: photos, camera, files (or the files picker at once when photos cannot be attached).
  private func plusPressed() {
    guard state.attachesPhotos else { return emit("attach", "files") }
    showMenu(from: plus, alignLeft: true, [
      .init(title: "照片", symbol: "photo.on.rectangle") { [weak self] in self?.emit("attach", "photos") },
      .init(title: "拍照", symbol: "camera") { [weak self] in self?.emit("attach", "camera") },
      .init(title: "文件", symbol: "folder") { [weak self] in self?.emit("attach", "files") },
    ])
  }

  /// The thinking-depth menu, the chosen level ticked.
  private func effortPressed() {
    showMenu(from: effort, alignLeft: true, ["none", "low", "medium", "high"].map { id in
      .init(title: effortNames[id] ?? id, symbol: effortSymbols[id], checked: id == state.effort) { [weak self] in self?.emit("effort", id) }
    })
  }

  /// A Liquid Glass menu hanging above one of the box's buttons, where the button stands: it is a view over the window, not a page
  /// of its own, so the keyboard stays up and the box does not move. Both buttons use it.
  private func showMenu(from button: UIView, alignLeft: Bool, _ items: [GlassMenu.Item]) {
    guard let window = button.window else { return }
    GlassMenu.show(items: items, row: button.convert(button.bounds, to: window), in: window, fit: true, above: true, alignLeft: alignLeft)
  }

  @objc private func voiceTapped() { emit("voice", nil) }

  @objc private func mainTapped() {
    let hasDraft =
      !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.hasAttachments
    if state.generating {
      emit("stop", nil)
    } else if hasDraft {
      if state.ready { emit("send", nil) }
    } else {
      emit("voice", nil)
    }
  }
}
