import Combine
import SwiftUI
import UIKit

/// The call page on `VoiceSession`, laid out as the original's: the reactor with the status and the level bars above, the last
/// turn's words under them; below, one row with minimize, the voice and hang-up, the mode chooser, the talk button and the
/// row of generated works.
@MainActor
final class CallViewController: UIViewController, UIGestureRecognizerDelegate {
  /// Every way up (see the root page): a page shown over it must not take the upside-down turn away again.
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
  private let store: JarvisStore
  private let voice: VoiceSession
  private let reactor = ReactorView()
  private let status = UILabel()
  private let hint = UILabel()
  private let waves = WaveformView()
  /// Your voice rises from below; JARVIS's comes down from above.
  private let glow = CallGlowView(fromTop: false)
  private let glowTop = CallGlowView(fromTop: true)
  private let transcript = UIScrollView()
  private let turns = UIStackView()
  private let youPill = UIView()
  private let youLabel = UILabel()
  private let botLabel = UILabel()
  private let recover = UIButton(type: .system)
  private let controls: NativeCallControls
  private let minimizeButton = UIButton(type: .system)
  private let voiceButton = UIButton(type: .system)
  private let hangupButton = UIButton(type: .system)
  private let works = UIButton(type: .system)
  private let railRow = UIView()
  private let railVoice = UIButton(type: .system)
  private let railMode = UIButton(type: .system)
  private var header = UIStackView()
  private var rule = UIView()
  private var controlsHeight: NSLayoutConstraint!
  private var strip = false
  private var modeToggle: ModeToggle?
  /// Your voice's light: pale silver on dark, a soft slate on light (silver would not show on the light page).
  private static let userLight = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.88, alpha: 1) : UIColor(red: 0.35, green: 0.42, blue: 0.5, alpha: 1) }
  private let stage = UIStackView()
  private let line = UIStackView()
  private let info = UIStackView()
  private var stageTop: NSLayoutConstraint!
  private var stageCenter: NSLayoutConstraint!
  private var reactorSize: NSLayoutConstraint!
  private var worksHeight: NSLayoutConstraint!
  private var stripSignature = ""
  /// A work that comes ready while the call goes on is shown at once.
  private let autoWorks = WorksAutoPop()
  /// Duo: before anyone has said anything the reactor stands large in the middle with the level bars under it; once there are
  /// words it moves up to the corner, as it was.
  private var conversing = false
  private let worksLabel = UILabel()
  private var bag = Set<AnyCancellable>()
  private var lastYou = ""
  private var holding = false
  /// The call has been seen going: only then does its ending close the page (it is presented before it starts).
  private var sawCall = false

  init(store: JarvisStore, voice: VoiceSession) {
    self.store = store
    self.voice = voice
    controls = NativeCallControls(frame: CGRect(x: 0, y: 0, width: 360, height: 130), args: [:])
    super.init(nibName: nil, bundle: nil)
    controls.emit = { [weak self] name, value in self?.controlsSaid(name, value) }
    voice.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.refresh() }
    }.store(in: &bag)
    store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.refresh() }
    }.store(in: &bag)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override var prefersStatusBarHidden: Bool { false }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.surface
    glow.translatesAutoresizingMaskIntoConstraints = false
    glowTop.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(glowTop)
    view.addSubview(glow)
    NSLayoutConstraint.activate([
      glowTop.leadingAnchor.constraint(equalTo: view.leadingAnchor), glowTop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      glowTop.topAnchor.constraint(equalTo: view.topAnchor), glowTop.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.62),
      glow.leadingAnchor.constraint(equalTo: view.leadingAnchor), glow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      glow.bottomAnchor.constraint(equalTo: view.bottomAnchor), glow.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.62),
    ])

    reactor.translatesAutoresizingMaskIntoConstraints = false
    reactor.isUserInteractionEnabled = false
    reactor.isAccessibilityElement = false
    status.font = .systemFont(ofSize: 17, weight: .semibold)
    status.textColor = Palette.onSurface
    status.adjustsFontForContentSizeCategory = true
    status.setContentHuggingPriority(.required, for: .horizontal)
    hint.font = .systemFont(ofSize: 12)
    hint.numberOfLines = 2
    hint.adjustsFontForContentSizeCategory = true
    for v in [status, hint] { line.addArrangedSubview(v) }
    line.axis = .horizontal
    line.alignment = .firstBaseline
    line.spacing = 14
    waves.translatesAutoresizingMaskIntoConstraints = false
    info.addArrangedSubview(line)
    info.addArrangedSubview(waves)
    info.axis = .vertical
    info.spacing = 10
    info.alignment = .fill
    stage.addArrangedSubview(reactor)
    stage.addArrangedSubview(info)
    stage.axis = .horizontal
    stage.alignment = .center
    stage.spacing = 14
    stage.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stage)

    // The words of the last turn, as the other apps' voice pages set them: what you said in a bubble on the right, the reply
    // plain on the left.
    transcript.alwaysBounceVertical = false
    transcript.showsVerticalScrollIndicator = false
    transcript.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(transcript)
    youLabel.numberOfLines = 0
    youLabel.translatesAutoresizingMaskIntoConstraints = false
    youPill.backgroundColor = Palette.containerHigh
    youPill.layer.cornerRadius = 22
    youPill.layer.cornerCurve = .continuous
    youPill.layer.borderWidth = 0.5
    youPill.layer.borderColor = Palette.outlineVariant.cgColor
    youPill.translatesAutoresizingMaskIntoConstraints = false
    youPill.addSubview(youLabel)
    let youRow = UIView()
    youRow.addSubview(youPill)
    botLabel.numberOfLines = 0
    turns.axis = .vertical
    turns.spacing = 20
    turns.alignment = .fill
    turns.translatesAutoresizingMaskIntoConstraints = false
    turns.addArrangedSubview(youRow)
    turns.addArrangedSubview(botLabel)
    transcript.addSubview(turns)
    NSLayoutConstraint.activate([
      youLabel.topAnchor.constraint(equalTo: youPill.topAnchor, constant: 14), youLabel.bottomAnchor.constraint(equalTo: youPill.bottomAnchor, constant: -14),
      youLabel.leadingAnchor.constraint(equalTo: youPill.leadingAnchor, constant: 22), youLabel.trailingAnchor.constraint(equalTo: youPill.trailingAnchor, constant: -22),
      youPill.topAnchor.constraint(equalTo: youRow.topAnchor), youPill.bottomAnchor.constraint(equalTo: youRow.bottomAnchor),
      youPill.trailingAnchor.constraint(equalTo: youRow.trailingAnchor), youPill.leadingAnchor.constraint(greaterThanOrEqualTo: youRow.leadingAnchor, constant: 48),
      turns.topAnchor.constraint(equalTo: transcript.contentLayoutGuide.topAnchor), turns.bottomAnchor.constraint(equalTo: transcript.contentLayoutGuide.bottomAnchor),
      turns.leadingAnchor.constraint(equalTo: transcript.contentLayoutGuide.leadingAnchor), turns.trailingAnchor.constraint(equalTo: transcript.contentLayoutGuide.trailingAnchor),
      turns.widthAnchor.constraint(equalTo: transcript.frameLayoutGuide.widthAnchor),
    ])

    var recoverConfig: UIButton.Configuration = .filled()
    recoverConfig.title = "恢复语音"
    recoverConfig.image = UIImage(systemName: "arrow.clockwise")
    recoverConfig.imagePadding = 8
    recoverConfig.cornerStyle = .capsule
    recoverConfig.baseBackgroundColor = Palette.containerHigh
    recoverConfig.baseForegroundColor = Palette.onSurface
    recover.configuration = recoverConfig
    recover.addAction(UIAction { [weak self] _ in self?.recoverCall() }, for: .touchUpInside)
    recover.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(recover)

    // The row: minimize, the voice, hang up.
    var minimize = UIButton.Configuration.plain()
    minimize.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
    minimize.baseForegroundColor = Palette.onSurfaceVariant
    minimizeButton.configuration = minimize
    minimizeButton.accessibilityLabel = "收起通话界面"
    minimizeButton.addAction(UIAction { [weak self] _ in self?.minimize() }, for: .touchUpInside)
    voiceButton.addAction(UIAction { [weak self] _ in self?.pickVoice() }, for: .touchUpInside)
    var hangup = UIButton.Configuration.filled()
    hangup.image = UIImage(systemName: "phone.down.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
    hangup.cornerStyle = .capsule
    hangup.baseBackgroundColor = Palette.danger
    hangup.baseForegroundColor = .white
    hangupButton.configuration = hangup
    hangupButton.accessibilityLabel = "结束语音通话"
    hangupButton.addAction(UIAction { [weak self] _ in self?.hangUp() }, for: .touchUpInside)
    let spacerLeft = UIView(), spacerRight = UIView()
    header = UIStackView(arrangedSubviews: [minimizeButton, spacerLeft, voiceButton, spacerRight, hangupButton])
    header.axis = .horizontal
    header.alignment = .center
    header.translatesAutoresizingMaskIntoConstraints = false
    spacerLeft.widthAnchor.constraint(equalTo: spacerRight.widthAnchor).isActive = true

    let controlsView = controls.view()
    controlsView.translatesAutoresizingMaskIntoConstraints = false

    worksLabel.font = .systemFont(ofSize: 14)
    worksLabel.textColor = Palette.onSurface
    let worksChevron = UIImageView(
      image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)))
    worksChevron.tintColor = Palette.onSurfaceVariant
    let worksRow = UIStackView(arrangedSubviews: [worksLabel, UIView(), worksChevron])
    worksRow.isUserInteractionEnabled = false
    worksRow.translatesAutoresizingMaskIntoConstraints = false
    works.addSubview(worksRow)
    NSLayoutConstraint.activate([
      worksRow.leadingAnchor.constraint(equalTo: works.leadingAnchor), worksRow.trailingAnchor.constraint(equalTo: works.trailingAnchor),
      worksRow.centerYAnchor.constraint(equalTo: works.centerYAnchor),
    ])
    works.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      WorksSheet.present(store: self.store, from: self)
    }, for: .touchUpInside)
    works.translatesAutoresizingMaskIntoConstraints = false
    rule.backgroundColor = Palette.outlineVariant.withAlphaComponent(0.6)
    rule.translatesAutoresizingMaskIntoConstraints = false

    // Duo: the voice and the mode sit in one row under the round talk button, as the other apps' voice pages have their pickers;
    // hang up, the generated works and minimize are in the system's strip.
    railRow.translatesAutoresizingMaskIntoConstraints = false
    for b in [railVoice, railMode] { b.translatesAutoresizingMaskIntoConstraints = false; railRow.addSubview(b) }
    railVoice.addAction(UIAction { [weak self] _ in self?.pickVoice() }, for: .touchUpInside)
    NSLayoutConstraint.activate([
      railVoice.leadingAnchor.constraint(equalTo: railRow.leadingAnchor), railVoice.centerYAnchor.constraint(equalTo: railRow.centerYAnchor),
      railMode.trailingAnchor.constraint(equalTo: railRow.trailingAnchor), railMode.centerYAnchor.constraint(equalTo: railRow.centerYAnchor),
      railMode.widthAnchor.constraint(equalToConstant: 52), railMode.heightAnchor.constraint(equalToConstant: 52),
      railRow.heightAnchor.constraint(equalToConstant: 56),
    ])
    let bottom = UIStackView(arrangedSubviews: [header, controlsView, railRow])
    bottom.axis = .vertical
    bottom.spacing = 10
    bottom.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(bottom)
    view.addSubview(rule)
    view.addSubview(works)

    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      stage.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
      stage.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28),
      reactor.heightAnchor.constraint(equalTo: reactor.widthAnchor),
      waves.heightAnchor.constraint(equalToConstant: 16),
      {
        let c = waves.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        c.priority = .defaultHigh
        return c
      }(),
      transcript.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 16),
      transcript.leadingAnchor.constraint(equalTo: stage.leadingAnchor), transcript.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
      transcript.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
      recover.centerXAnchor.constraint(equalTo: guide.centerXAnchor), recover.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 8),
      bottom.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 22),
      bottom.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -22),
      bottom.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
      bottom.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      bottom.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -10),
      minimizeButton.widthAnchor.constraint(equalToConstant: 44), minimizeButton.heightAnchor.constraint(equalToConstant: 44),
      hangupButton.widthAnchor.constraint(equalToConstant: 44), hangupButton.heightAnchor.constraint(equalToConstant: 44),
      rule.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 22), rule.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -22),
      rule.heightAnchor.constraint(equalToConstant: 0.7), rule.bottomAnchor.constraint(equalTo: works.topAnchor),
      works.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28), works.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28),
      works.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
    ])
    // A touch anywhere (but on a button) holds JARVIS's voice while it speaks, and the next one lets it go on.
    let tapPause = UITapGestureRecognizer(target: self, action: #selector(tappedPause(_:)))
    tapPause.cancelsTouchesInView = false
    tapPause.delegate = self
    view.addGestureRecognizer(tapPause)
    controlsHeight = controlsView.heightAnchor.constraint(equalToConstant: 122)
    controlsHeight.isActive = true
    stageTop = stage.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12)
    stageCenter = stage.topAnchor.constraint(equalTo: guide.topAnchor, constant: 48)
    reactorSize = reactor.widthAnchor.constraint(equalToConstant: 84)
    worksHeight = works.heightAnchor.constraint(equalToConstant: 52)
    for c in [stageTop!, reactorSize!, worksHeight!] { c.isActive = true }
    refresh()
  }

  @objc private func tappedPause(_ tap: UITapGestureRecognizer) {
    guard voice.togglePlaybackPause() else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  // MARK: Duo strip

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyStrip()
    refresh()
  }

  /// The system's bar carries the call's buttons: along the side (a vertical strip) or, held upright on the inner display, along the top.
  private var usesBar: Bool { hasVerticalBar(traitCollection) || isInnerDisplayUpright(view.window?.bounds.size ?? view.bounds.size) }
  private var barKind = 0

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // A turn between upright and sideways changes the bar without changing the traits.
    let kind = hasVerticalBar(traitCollection) ? 1 : 2
    if isViewLoaded, usesBar != strip || (strip && kind != barKind) { applyStrip(); stripSignature = ""; refresh() }
  }

  /// Beside a vertical strip the system's bar carries the page's buttons (minimize, works and recover at the top, hang up at the
  /// bottom); otherwise the page draws its own header and works row.
  private func applyStrip() {
    guard isViewLoaded else { return }
    strip = usesBar
    barKind = hasVerticalBar(traitCollection) ? 1 : 2
    if navigationController?.isNavigationBarHidden != !strip { navigationController?.setNavigationBarHidden(!strip, animated: false) }
    if navigationController?.isToolbarHidden != !strip { navigationController?.setToolbarHidden(!strip, animated: false) }
    header.isHidden = strip
    rule.isHidden = strip
    railRow.isHidden = true
    if !strip {
      stage.axis = .horizontal; line.axis = .horizontal; info.alignment = .fill; stage.spacing = 14
      reactorSize.constant = 84; stageTop.isActive = true; stageCenter.isActive = false
      line.alignment = .firstBaseline; hint.textAlignment = .natural
      status.font = .systemFont(ofSize: 17, weight: .semibold)
      hint.font = .systemFont(ofSize: 12)
    } else {
      setStage(conversing: conversing, animated: false)
    }
    controlsHeight.constant = strip ? 84 : 122
    worksHeight.constant = strip ? 24 : 52
    if strip {
      let down = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), primaryAction: UIAction { [weak self] _ in self?.minimize() })
      down.accessibilityLabel = "收起通话界面"
      down.tintColor = Palette.onSurface.withAlphaComponent(0.88)
      navigationItem.leftBarButtonItem = down
      navigationItem.hidesBackButton = true
      // Close: it ends the call and the page, and is a plain cross, not a telephone.
      let hang = UIBarButtonItem(image: UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)), primaryAction: UIAction { [weak self] _ in self?.hangUp() })
      hang.accessibilityLabel = "关闭，结束语音通话"
      hang.tintColor = Palette.onSurface
      if #available(iOS 26.0, *) { hang.style = .prominent }
      // Along the side the strip's own bottom is where it stands; held upright it stands at the bottom corner, on the same side as the
      // strip would be (the system centres a lone item in a toolbar).
      toolbarItems = barKind == 2 ? [.flexibleSpace(), hang] : [hang]
    } else {
      navigationItem.leftBarButtonItem = nil
      toolbarItems = nil
    }
  }

  /// The strip's buttons for the call, top to bottom: the way of talking as one linked pair (hold to talk, hands-free), the voice,
  /// then the generated works and recovering a lost voice when there are any. The system stacks a right-hand array from its last
  /// item to its first, and joins neighbours with no space between them into one capsule.
  private func updateStripItems(tasks: Int) {
    guard strip else { return }
    let signature = "\(ptt)|\(voiceName())|\(tasks)|\(voice.needsRecovery)"
    guard signature != stripSignature else { return }
    stripSignature = signature
    // Every picture the same visual size: the wide or filled ones are drawn smaller so none looks bigger than the others.
    func symbol(_ name: String, _ size: CGFloat) -> UIImage? { UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .medium)) }
    func item(_ name: String, _ label: String, size: CGFloat = 19, _ run: @escaping () -> Void) -> UIBarButtonItem {
      let i = UIBarButtonItem(image: symbol(name, size), primaryAction: UIAction { _ in run() })
      i.accessibilityLabel = label
      i.tintColor = Palette.onSurface
      return i
    }
    // The way of talking is one switch, not two buttons: a capsule with the two ways stacked in it and a raised pill that slides
    // to the one that is on (a microphone: hold to talk; sound bars: hands-free).
    // One switch for the whole call: a new one at every change would cut the movement of the old one short.
    let horizontal = barKind == 2
    if modeToggle?.isHorizontal != horizontal { modeToggle = nil }
    let toggle = modeToggle ?? ModeToggle(ptt: ptt, horizontal: horizontal) { [weak self] mode in self?.chooseMode(mode) }
    modeToggle = toggle
    toggle.sync(ptt: ptt)
    let modeItem = UIBarButtonItem(customView: toggle)
    modeItem.accessibilityLabel = "对话方式"
    if #available(iOS 27.1, *), !horizontal { modeItem.axisBehavior = .verticalPreferred }
    // The switch is its own glass: the bar's capsule around a custom view would be a second one.
    if #available(iOS 26.0, *) { modeItem.hidesSharedBackground = true }
    let voiceItem = item("speaker.wave.2", "音色：\(voiceName().isEmpty ? "未选择" : voiceName())", size: 17) { [weak self] in self?.pickVoice() }
    var right: [UIBarButtonItem] = []
    if voice.needsRecovery {
      right.append(item("arrow.clockwise", "恢复语音") { [weak self] in self?.recoverCall() })
      right.append(.fixedSpace(0))
    }
    if tasks > 0 {
      right.append(item("photo", "作品 · \(tasks)", size: 17) { [weak self] in
        guard let self else { return }
        WorksSheet.present(store: self.store, from: self)
      })
      right.append(.fixedSpace(0))
    }
    right += [voiceItem, .fixedSpace(0), modeItem]
    navigationItem.rightBarButtonItems = right
  }

  private func chooseMode(_ mode: String) {
    guard (mode == "ptt") != ptt else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    controlsSaid("mode", mode)
  }

  // MARK: Stage

  /// Lays the stage out for the first or the second part of the call, animating from one to the other.
  private func setStage(conversing now: Bool, animated: Bool) {
    guard strip else { return }
    conversing = now
    let apply = {
      self.stage.axis = now ? .horizontal : .vertical
      self.stage.alignment = .center
      self.stage.spacing = now ? 14 : 26
      self.line.axis = now ? .horizontal : .vertical
      self.line.alignment = now ? .firstBaseline : .center
      self.info.alignment = now ? .fill : .center
      self.reactorSize.constant = now ? 84 : 220
      self.stageTop.isActive = now
      self.stageCenter.isActive = !now
      self.status.font = .systemFont(ofSize: now ? 17 : 20, weight: .semibold)
      self.hint.font = .systemFont(ofSize: now ? 12 : 14)
      self.hint.textAlignment = now ? .natural : .center
      self.view.layoutIfNeeded()
    }
    if animated && !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.65, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: apply)
    } else {
      apply()
    }
  }

  /// Not on the controls: the talk button, the mode choice and the buttons keep their own touches.
  func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var hit: UIView? = touch.view
    while let v = hit {
      if v is UIControl || v is ModeToggle || v === controls.view() { return false }
      hit = v.superview
    }
    return true
  }

  // MARK: What the call says

  private var ptt: Bool { store.settings.voiceMode == "ptt" }

  private func refresh() {
    guard isViewLoaded else { return }
    let vad = !ptt
    let muted = voice.mutedInVad
    let staleMute = !vad && voice.muted && voice.status == "已静音"
    // "已就绪" alone says nothing to someone who has not spoken yet: hands-free it is listening, push-to-talk it asks for the button.
    let idle = voice.status == "已就绪"
    let nextStatus =
      voice.needsRecovery
      ? "需要恢复语音" : voice.ready && idle ? (vad ? "正在聆听" : "按住按钮说话") : staleMute ? "按住按钮说话" : voice.status
    let shownStatus = voice.playbackPaused ? "已暂停" : nextStatus
    let hintText = voice.playbackPaused ? "再点一下继续" : voice.error ?? (staleMute || (voice.ready && idle && !vad) ? "" : voice.hint)
    // Words change with a dissolve, and only when they really changed: the page keeps still while its state ticks over.
    if status.text != shownStatus {
      UIView.transition(with: status, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.status.text = shownStatus }
    }
    if hint.text != hintText {
      UIView.transition(with: hint, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.hint.text = hintText }
    }
    hint.textColor = voice.error != nil ? Palette.error : Palette.onSurfaceVariant
    hint.isHidden = hintText.isEmpty
    recover.isHidden = !voice.needsRecovery || strip
    let denied = voice.permissionDenied
    if recover.configuration?.title != (denied ? "打开设置" : "恢复语音") {
      recover.configuration?.title = denied ? "打开设置" : "恢复语音"
      recover.configuration?.image = UIImage(systemName: denied ? "gearshape" : "arrow.clockwise")
    }
    let mode =
      voice.expressing ? "speaking" : voice.thinking ? "thinking" : voice.ready && !muted && (voice.held || vad) ? "listening" : "idle"
    reactor.apply(["mode": mode, "dark": traitCollection.userInterfaceStyle != .light], animated: true)
    waves.levels = voice.levels
    // The light, in two directions: JARVIS's cyan comes down from the top edge and swells with its voice; yours rises from the
    // bottom edge, pale silver, and swells with yours; at rest only a faint cyan at the foot.
    let jarvis = Palette.accent.resolvedColor(with: traitCollection)
    if voice.expressing || voice.levels.playing {
      glowTop.show(jarvis, CGFloat(min(0.62, 0.26 + voice.levels.output * 6)))
      glow.show(UIColor(white: 0.88, alpha: 1), 0)
    } else if voice.held || (vad && voice.ready && !muted && voice.levels.input > 0.02) {
      glow.show(Self.userLight.resolvedColor(with: traitCollection), CGFloat(min(0.5, 0.2 + voice.levels.input * 8)))
      glowTop.show(jarvis, 0)
    } else {
      glowTop.show(jarvis, 0)
      glow.show(jarvis, 0.1)
    }
    #if DEBUG
      if ProcessInfo.processInfo.environment["JARVIS_GLOW_DEMO"] == "jarvis" { glowTop.show(jarvis, 0.5); glow.show(jarvis, 0) }
      if ProcessInfo.processInfo.environment["JARVIS_GLOW_DEMO"] == "user" { glow.show(UIColor(white: 0.88, alpha: 1), 0.4); glowTop.show(jarvis, 0) }
    #endif

    // The voice, named on a pill with the level mark before it.
    var pill = UIButton.Configuration.filled()
    pill.title = voiceName().isEmpty ? "选择音色" : voiceName()
    pill.image = UIImage(systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
    pill.imagePadding = 8
    pill.cornerStyle = .capsule
    pill.baseBackgroundColor = Palette.containerHigh
    pill.baseForegroundColor = Palette.onSurface
    pill.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
    let chevron = NSTextAttachment()
    chevron.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))?
      .withTintColor(Palette.onSurfaceVariant, renderingMode: .alwaysOriginal)
    let name = NSMutableAttributedString(
      string: pill.title! + " ", attributes: [.font: UIFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: Palette.onSurface])
    name.append(NSAttributedString(attachment: chevron))
    pill.attributedTitle = AttributedString(name)
    voiceButton.configuration = pill
    voiceButton.accessibilityLabel = "音色：\(voiceName().isEmpty ? "未选择" : voiceName())"
    voiceButton.accessibilityHint = "选择音色"

    let size = store.settings.messageFontSize
    youLabel.attributedText = NSAttributedString(
      string: voice.lastYou, attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: Palette.onSurface])
    youPill.superview?.isHidden = voice.lastYou.isEmpty
    botLabel.attributedText = NSAttributedString(
      string: voice.lastBot, attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: Palette.onSurface, .paragraphStyle: { () -> NSMutableParagraphStyle in
        let p = NSMutableParagraphStyle(); p.lineSpacing = 4; return p }()])
    botLabel.isHidden = voice.lastBot.isEmpty
    #if DEBUG
      if ProcessInfo.processInfo.environment["JARVIS_CALL_DEMO"] == "1" {
        youLabel.attributedText = NSAttributedString(
          string: "你好你好你好", attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: Palette.onSurface])
        youPill.superview?.isHidden = false
        botLabel.attributedText = NSAttributedString(
          string: "你好！我在这里，随时可以帮你。今天想聊点什么？可以问我问题，也可以让我帮你整理想法。",
          attributes: [.font: UIFont.systemFont(ofSize: size + 1), .foregroundColor: Palette.onSurface])
        botLabel.isHidden = false
        if strip, !conversing { setStage(conversing: true, animated: false) }
      }
    #endif
    if voice.lastYou != lastYou {
      lastYou = voice.lastYou
      transcript.setContentOffset(.zero, animated: false)
    }

    autoWorks.check(store: store, presenter: self)
    let count = store.current.tasks.count
    worksLabel.text = "作品 · \(count)"
    works.accessibilityLabel = "作品，\(count) 个"

    let talk = voice.ready ? (ptt ? (voice.held ? "松开发送" : "按住说话") : (muted ? "已静音" : "正在聆听")) : (voice.error == nil ? "等待连接" : "等待恢复")
    controls.apply(["ptt": ptt, "ready": voice.ready, "held": voice.held, "muted": muted, "label": talk, "short": view.bounds.height < 520, "circular": strip])
    works.isHidden = count == 0 || strip
    updateStripItems(tasks: count)
    if strip, !conversing, !voice.lastYou.isEmpty || !voice.lastBot.isEmpty { setStage(conversing: true, animated: true) }
    if voice.open || voice.active || voice.starting { sawCall = true }
    // The call ended (hung up, or the session closed): the page goes with it.
    if sawCall && !voice.open && !voice.active && !voice.starting && !voice.needsRecovery { closePage() }
  }

  private func voiceName() -> String {
    let id = voice.voice
    return voice.speech?.voices.first { $0.id == id }?.name ?? id
  }

  private func controlsSaid(_ name: String, _ value: Any?) {
    switch name {
    case "down":
      if voice.ready {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        voice.hold()
        holding = true
      }
    case "up":
      if holding {
        holding = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        voice.release()
      }
    case "cancel": if holding { holding = false; voice.cancelHold() }
    case "mute":
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      voice.toggleMute()
    case "mode":
      guard let mode = value as? String else { return }
      voice.cancelHold()
      store.changeSettings { $0.voiceMode = mode }
    default: break
    }
  }

  private func pickVoice() {
    present(NativeChatSettings.voicePicker(store: store) { [weak self] in self?.dismiss(animated: true) }, animated: true)
  }

  /// Closes the whole page, even when a picker or the works sheet stands on it.
  private func closePage() {
    (navigationController?.presentingViewController ?? presentingViewController)?.dismiss(animated: true)
  }

  private func minimize() {
    voice.minimize()
    closePage()
  }

  private func hangUp() {
    Task { await voice.stop() }
    closePage()
  }

  private func recoverCall() {
    // A refused microphone is not given back by trying again: the button takes the person to where it is allowed.
    if voice.permissionDenied {
      FilesService.shared.openAppSettings { _ in }
      return
    }
    Task { _ = await voice.recover() }
  }
}
