import Combine
import SwiftUI
import UIKit

/// The call page on `VoiceSession`, laid out as the original's: the reactor with the status and the level bars above, the last
/// turn's words under them; below, one row with minimize, the voice and hang-up, the mode chooser, the talk button and the
/// row of generated works.
@MainActor
final class CallViewController: UIViewController, UIGestureRecognizerDelegate, UIScrollViewDelegate {
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
  /// JARVIS's words, with the sentence being said marked (see `SpokenTextView`).
  private let botView = SpokenTextView()
  /// The words are brought to the sentence being said; for a few seconds after a hand has moved them they are left alone.
  private var handMovedTranscript = Date.distantPast
  private let transcriptFade = CAGradientLayer()
  private var transcriptLead: NSLayoutConstraint!
  private var transcriptTrail: NSLayoutConstraint!
  private var bottomCenter: NSLayoutConstraint!
  /// The voice is saying the reply, or stopped in it: the words are brought to the line it is on.
  private var followsVoice = false
  /// Moves the lit edge 30 times a second while the voice goes (the player reports every 50 ms, and not at all while it plays
  /// silence).
  private var readingTimer: Timer?
  private var fadeSignature = ""
  #if DEBUG
    /// JARVIS_CALL_DEMO=1: a short reply; =read: a long one (twice over) read out over 80 s (the edge moves and the words
    /// follow it); =cut: the same reply cut off 52 s in (the lit part stays where the voice stopped).
    private static let demoMode: String = {
      let mode = ProcessInfo.processInfo.environment["JARVIS_CALL_DEMO"] ?? ""
      return ["1", "read", "cut"].contains(mode) ? mode : ""
    }()
    private let demoStarted = Date()
    private static let demoReply =
      "这个问题挺有意思的，得分两层看。第一层是**可观测宇宙**，也就是光从大爆炸到现在来得及传给我们那部分。它的直径大约是930亿光年。这个数字看着矛盾——宇宙才138亿岁，怎么能有930亿光年？因为空间本身在膨胀，远处的光走过的路被空间拉伸得比138亿年还长。第二层是**整个宇宙**，这个就没人知道了。它可能是可观测范围之外还有一大块，也可能是完全无限大。目前的观测数据只能告诉我们：在我们能看到的范围内，空间几乎是平直的，而平直的空间往往意味着要么无限大，要么大到我们根本测不出它的弯曲。所以老实说，930亿光年这个数我们比较确定，但宇宙真正的边界在哪，到现在还是个没解开的谜。你是对哪部分更感兴趣，膨胀的速度，还是它到底有没有边？"
  #endif
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
  private var tallLayout: [NSLayoutConstraint] = []
  private var shortLayout: [NSLayoutConstraint] = []
  private var shortWindow = false
  private var rebuildPending = false
  private var closing = false
  private var modeItem: UIBarButtonItem?
  /// A work that comes ready while the call goes on is shown at once.
  private let autoWorks = WorksAutoPop()
  /// Duo: before anyone has said anything the reactor stands large in the middle with the level bars under it; once there are
  /// words it moves up to the corner, as it was.
  private var conversing = false
  private let worksLabel = UILabel()
  private var bag = Set<AnyCancellable>()
  private var lastYou = ""
  private var holding = false
  /// Where the talk button stands on the foldable's inner display on its side: -1 the middle of the left half, 0 the middle of
  /// the window (as the page opens), 1 the middle of the right half. It goes to the side the thumb comes down on.
  private var anchor = 0
  private var summon: UILongPressGestureRecognizer!
  /// A held touch on the page (not on the button) is what holds the talk button now.
  private var summonActive = false
  private var summonStart = CGPoint.zero
  /// While JARVIS speaks the touch has to stay a little longer before it talks over it: this is that wait.
  private var summonTalks: DispatchWorkItem?
  /// The finger went up far enough: letting go now throws the words away.
  private var cancelArmed = false
  private let halo = TouchHalo()
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
    transcript.delegate = self
    botView.onLine = { [weak self] rect in
      // Not now: this comes from inside a layout pass, which the follow would start again.
      DispatchQueue.main.async { [weak self] in
        guard let self, self.followsVoice else { return }
        self.follow(rect)
      }
    }
    // The text fades out at an edge it continues past (and not at one it ends at). The mask is a little wider than the page
    // so that the glow of the lit characters is not cut at its sides.
    transcript.clipsToBounds = false
    transcriptFade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
    transcriptFade.startPoint = CGPoint(x: 0.5, y: 0)
    transcriptFade.endPoint = CGPoint(x: 0.5, y: 1)
    transcript.layer.mask = transcriptFade
    transcript.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(transcript)
    youLabel.numberOfLines = 0
    youLabel.translatesAutoresizingMaskIntoConstraints = false
    youPill.backgroundColor = Palette.containerHigh
    youPill.layer.cornerRadius = 22
    youPill.layer.cornerCurve = .continuous
    youPill.layer.borderWidth = 0.5
    youPill.layer.borderColor = Palette.outlineVariant.resolvedColor(with: traitCollection).cgColor
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (page: CallViewController, _: UITraitCollection) in
      page.youPill.layer.borderColor = Palette.outlineVariant.resolvedColor(with: page.traitCollection).cgColor
    }
    youPill.translatesAutoresizingMaskIntoConstraints = false
    youPill.addSubview(youLabel)
    let youRow = UIView()
    youRow.addSubview(youPill)
    botView.translatesAutoresizingMaskIntoConstraints = false
    turns.axis = .vertical
    turns.spacing = 20
    turns.alignment = .fill
    turns.translatesAutoresizingMaskIntoConstraints = false
    turns.addArrangedSubview(youRow)
    turns.addArrangedSubview(botView)
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
      recover.centerXAnchor.constraint(equalTo: guide.centerXAnchor), recover.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 8),
      bottom.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -10),
      minimizeButton.widthAnchor.constraint(equalToConstant: 44), minimizeButton.heightAnchor.constraint(equalToConstant: 44),
      hangupButton.widthAnchor.constraint(equalToConstant: 44), hangupButton.heightAnchor.constraint(equalToConstant: 44),
      rule.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 22), rule.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -22),
      rule.heightAnchor.constraint(equalToConstant: 0.7), rule.bottomAnchor.constraint(equalTo: works.topAnchor),
      works.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28), works.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28),
      works.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
    ])
    // Upright: the talk button is centred under the words. On its side (a short window) the words need the room, so the button
    // stands at the left, low, and the words take the rest of the width beside it.
    transcriptLead = transcript.leadingAnchor.constraint(equalTo: stage.leadingAnchor)
    transcriptTrail = transcript.trailingAnchor.constraint(equalTo: stage.trailingAnchor)
    transcriptTrail.isActive = true
    bottomCenter = bottom.centerXAnchor.constraint(equalTo: guide.centerXAnchor)
    tallLayout = [
      transcriptLead,
      transcript.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
      // As wide as the window less the margins, at most 380 pt (on a 440 pt phone both margins and the cap cannot hold at once, so the
      // margins are the minimum and the width the wish).
      bottom.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 22),
      bottom.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -22),
      bottom.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
      {
        let c = bottom.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -44)
        c.priority = .defaultHigh
        return c
      }(),
      bottomCenter,
    ]
    shortLayout = [
      bottom.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
      bottom.widthAnchor.constraint(equalToConstant: 96),
      transcript.leadingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: 20),
      transcript.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -10),
    ]
    NSLayoutConstraint.activate(tallLayout)
    // A touch anywhere (but on a button) holds JARVIS's voice while it speaks, and the next one lets it go on.
    let tapPause = UITapGestureRecognizer(target: self, action: #selector(tappedPause(_:)))
    tapPause.cancelsTouchesInView = false
    tapPause.delegate = self
    view.addGestureRecognizer(tapPause)
    // A held touch in the lower half brings the talk button to that side, and counts as holding it.
    summon = UILongPressGestureRecognizer(target: self, action: #selector(summoned(_:)))
    summon.minimumPressDuration = 0.2
    summon.cancelsTouchesInView = false
    summon.delegate = self
    view.addGestureRecognizer(summon)
    halo.isUserInteractionEnabled = false
    halo.frame = view.bounds
    halo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(halo)
    tapPause.require(toFail: summon)
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
  /// A straight phone (the Pro Max sizes) has the same page as the foldable's (the round talk button, the large reactor that moves up
  /// once someone speaks, the buttons in a bar), with the bar drawn by the navigation controller along the top. The foldable's own
  /// pages are as they were.
  private var usesBar: Bool {
    hasVerticalBar(traitCollection) || isInnerDisplayUpright(view.window?.bounds.size ?? view.bounds.size) || isStraightPhone(view)
  }
  private var barKind = 0

  /// The foldable's inner display on its side: two halves beside each other, the right one under the right thumb.
  private var twoHalves: Bool {
    let size = view.bounds.size
    return hasVerticalBar(traitCollection) && !isStraightPhone(view) && size.width > size.height && min(size.width, size.height) >= 600
  }

  /// How far from the window's middle the talk button stands for an anchor.
  private func offset(for anchor: Int) -> CGFloat {
    let guide = view.safeAreaLayoutGuide.layoutFrame
    guard twoHalves else { return 0 }
    switch anchor {
    case -1: return (guide.minX + view.bounds.midX) / 2 - guide.midX
    case 1: return (view.bounds.midX + guide.maxX) / 2 - guide.midX
    default: return 0
    }
  }

  /// The talk button is at its anchor, and the words keep a tenth of the width free there, half on each side (the lines were
  /// too long to read).
  private func placeForHalves() {
    let guide = view.safeAreaLayoutGuide.layoutFrame
    // Back in the middle whenever the two halves are gone (upright, folded, the outer display).
    if !twoHalves, !summonActive { anchor = 0 }
    let centre = offset(for: anchor)
    let inset = twoHalves ? (guide.width * 0.05).rounded() : 0
    if abs(bottomCenter.constant - centre) > 0.5 { bottomCenter.constant = centre }
    if abs(transcriptLead.constant - inset) > 0.5 {
      transcriptLead.constant = inset
      transcriptTrail.constant = -inset
    }
  }

  @objc private func summoned(_ press: UILongPressGestureRecognizer) {
    let at = press.location(in: view)
    switch press.state {
    case .began:
      summonActive = true
      summonStart = at
      cancelArmed = false
      // The nearest of the three places to where the thumb is.
      let x = at.x - view.safeAreaLayoutGuide.layoutFrame.midX
      let next = [-1, 0, 1].min { abs(offset(for: $0) - x) < abs(offset(for: $1) - x) } ?? 0
      if next != anchor {
        anchor = next
        bottomCenter.constant = offset(for: next)
        if UIAccessibility.isReduceMotionEnabled {
          view.layoutIfNeeded()
        } else {
          UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.view.layoutIfNeeded()
          }
        }
      } else {
        controls.nudge()
      }
      // The words do not move under the thumb while it holds.
      transcript.isScrollEnabled = false
      guard ptt, voice.ready, !voice.previewing else {
        // Hands-free, or no call to talk to yet: the button only comes.
        UISelectionFeedbackGenerator().selectionChanged()
        return
      }
      if voice.canStopSpeech || voice.playbackPaused {
        // JARVIS is speaking: a thumb that only rests here must not cut it off. The button comes first; the touch talks over
        // the reply once it has stayed twice as long.
        UISelectionFeedbackGenerator().selectionChanged()
        let work = DispatchWorkItem { [weak self] in
          guard let self, self.summonActive else { return }
          self.summonTalks = nil
          self.startSummonHold()
        }
        summonTalks = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
      } else {
        startSummonHold()
      }
    case .changed:
      guard holding else { return }
      halo.finger = at
      // Up by a good way from where it came down (a thumb that only rolls does not count).
      let armed = summonStart.y - at.y > 80
      if armed != cancelArmed {
        cancelArmed = armed
        if armed { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() } else { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        halo.cancelling = armed
        refresh()
      }
    case .ended, .cancelled, .failed:
      guard summonActive else { return }
      summonActive = false
      summonTalks?.cancel()
      summonTalks = nil
      transcript.isScrollEnabled = true
      let thrown = cancelArmed || press.state != .ended
      cancelArmed = false
      if holding {
        halo.hide(into: thrown ? nil : controls.talkCentre(in: view))
        endHold(send: !thrown)
        refresh()
      }
    default: break
    }
  }

  /// The held touch starts to talk: the light under the finger, tied to the button.
  private func startSummonHold() {
    beginHold()
    guard holding else { return }
    view.layoutIfNeeded()
    halo.frame = view.bounds
    halo.cancelling = false
    halo.show(finger: summon.location(in: view), button: controls.talkCentre(in: view))
  }

  private func beginHold() {
    guard voice.ready, !holding else { return }
    voice.hold()
    // (Not while a voice is being tried out: then nothing is held.)
    guard voice.held else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    holding = true
  }

  private func endHold(send: Bool) {
    guard holding else { return }
    holding = false
    if send {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      voice.release()
    } else {
      voice.cancelHold()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    placeForHalves()
    updateFade()
    // A turn between upright and sideways changes the bar without changing the traits.
    let kind = hasVerticalBar(traitCollection) ? 1 : 2
    let short = view.bounds.height < 520 && strip && isStraightPhone(view)
    if short != shortWindow {
      shortWindow = short
      if short { NSLayoutConstraint.deactivate(tallLayout); NSLayoutConstraint.activate(shortLayout) }
      else { NSLayoutConstraint.deactivate(shortLayout); NSLayoutConstraint.activate(tallLayout) }
      view.setNeedsLayout()
    }
    if isViewLoaded, usesBar != strip || (strip && kind != barKind), !rebuildPending {
      // Not in this layout pass: the strip's rebuild lays out again (the stage) and changes the page's state.
      rebuildPending = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.rebuildPending = false
        self.applyStrip()
        self.stripSignature = ""
        self.refresh()
      }
    }
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
    // The switch follows the setting at every refresh, whether or not the bar is rebuilt: it is the same view all through the call,
    // and it moves its own pill.
    modeToggle?.sync(ptt: ptt)
    let denied = voice.permissionDenied
    let signature = "\(voiceName())|\(tasks)|\(voice.needsRecovery)|\(denied)"
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
    // One switch, and one bar item holding it, for the whole call: a new one would take the view out of its place in the middle of its
    // own movement.
    let horizontal = barKind == 2
    if modeToggle?.isHorizontal != horizontal { modeToggle = nil; modeItem = nil }
    let toggle = modeToggle ?? ModeToggle(ptt: ptt, horizontal: horizontal) { [weak self] mode in self?.chooseMode(mode) }
    modeToggle = toggle
    toggle.sync(ptt: ptt)
    let modeItem: UIBarButtonItem
    if let kept = self.modeItem {
      modeItem = kept
    } else {
      modeItem = UIBarButtonItem(customView: toggle)
      modeItem.accessibilityLabel = "对话方式"
      if #available(iOS 27.1, *), !horizontal { modeItem.axisBehavior = .verticalPreferred }
      // The switch is its own glass: the bar's capsule around a custom view would be a second one.
      if #available(iOS 26.0, *) { modeItem.hidesSharedBackground = true }
      self.modeItem = modeItem
    }
    let voiceItem = item("speaker.wave.2", "音色：\(voiceName().isEmpty ? "未选择" : voiceName())", size: 17) { [weak self] in self?.pickVoice() }
    var right: [UIBarButtonItem] = []
    if voice.needsRecovery {
      // A refused microphone is not given back by trying again: the button says it takes the person to the settings.
      right.append(item(denied ? "gearshape" : "arrow.clockwise", denied ? "打开设置" : "恢复语音") { [weak self] in self?.recoverCall() })
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
    let changed = conversing != now
    conversing = now
    let animate = animated && changed && !UIAccessibility.isReduceMotionEnabled
    // The status and the level bars change their arrangement, their sizes and their type: none of that can be tweened, so they are
    // not seen while it happens and come back in the new arrangement as the reactor settles in its new place.
    if animate { info.layer.removeAllAnimations(); info.alpha = 0 }
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
    }
    if animate {
      apply()
      UIView.animate(withDuration: 0.65, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
        self.view.layoutIfNeeded()
      }
      UIView.animate(withDuration: 0.3, delay: 0.3, options: [.curveEaseOut, .allowUserInteraction]) { self.info.alpha = 1 }
    } else {
      apply()
      info.alpha = 1
      view.layoutIfNeeded()
    }
  }

  /// Not on the controls: the talk button, the mode choice and the buttons keep their own touches.
  func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    // The button is brought only on the inner display on its side, by a touch in the lower half.
    // One finger at a time (not while the button itself is held), and not under VoiceOver, where a held touch means something else.
    if recognizer === summon,
      !twoHalves || holding || summonActive || UIAccessibility.isVoiceOverRunning || touch.location(in: view).y < view.bounds.midY
    {
      return false
    }
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
    let hintText = holding && cancelArmed ? "松开取消" : voice.playbackPaused ? "再点一下继续" : voice.error ?? (staleMute || (voice.ready && idle && !vad) ? "" : voice.hint)
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
    #if DEBUG
      if Self.demoMode != "" {
        youLabel.attributedText = NSAttributedString(
          string: "你好你好你好", attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: Palette.onSurface])
        youPill.superview?.isHidden = false
        if strip, !conversing { setStage(conversing: true, animated: false) }
      }
    #endif
    updateReading()
    updateFade()
    if voice.lastYou != lastYou {
      lastYou = voice.lastYou
      transcript.setContentOffset(.zero, animated: false)
    }

    autoWorks.check(store: store, presenter: self)
    let count = store.current.tasks.filter { !$0.removed }.count
    worksLabel.text = "作品 · \(count)"
    works.accessibilityLabel = "作品，\(count) 个"

    // (Held by a tap, the reply is still there to be stopped or let go on.)
    var stoppable = voice.canStopSpeech || (voice.playbackPaused && voice.ready && !voice.held)
    if holding { halo.level = CGFloat(voice.levels.input) }
    var callReady = voice.ready
    #if DEBUG
      if Self.demoMode == "read" { stoppable = true; callReady = true }
    #endif
    let talk = callReady ? (stoppable ? (voice.playbackPaused ? "点按继续" : ptt ? "点按停止 · 按住插话" : "点按停止") : ptt ? (voice.held ? (cancelArmed ? "松开取消" : "松开发送") : "按住说话") : (muted ? "已静音" : "正在聆听")) : (voice.error == nil ? "等待连接" : "等待恢复")
    controls.apply(["ptt": ptt, "ready": callReady, "held": voice.held, "muted": muted, "label": talk, "stoppable": stoppable, "paused": voice.playbackPaused, "thinking": callReady && voice.thinking && !voice.expressing,
      "cancelling": holding && cancelArmed, "short": view.bounds.height < 520, "circular": strip])
    works.isHidden = count == 0 || strip
    updateStripItems(tasks: count)
    if strip, !conversing, !voice.lastYou.isEmpty || !voice.lastBot.isEmpty { setStage(conversing: true, animated: true) }
    if voice.open || voice.active || voice.starting { sawCall = true }
    // The call ended (hung up, or the session closed): the page goes with it.
    if sawCall && !voice.open && !voice.active && !voice.starting && !voice.needsRecovery { closePage() }
  }

  /// JARVIS's words, lit as far as the voice has got (see `SpokenTextView`).
  private func updateReading() {
    var text = voice.lastBot
    var size = store.settings.messageFontSize
    var progress = voice.speechProgress
    #if DEBUG
      if Self.demoMode != "" {
        text = "你好！我在这里，随时可以帮你。今天想聊点什么？可以问我问题，也可以让我帮你整理想法。"
        size += 1
        progress = nil
        if Self.demoMode == "read" || Self.demoMode == "cut" {
          text = Self.demoReply + "\n\n" + Self.demoReply
          size = store.settings.messageFontSize * 1.8
          let played = Self.demoMode == "cut" ? 52 : min(Date().timeIntervalSince(demoStarted), 80)
          progress = SpeechProgress(played: played, total: 80, pace: 0.2, live: Self.demoMode == "read" && played < 80, cut: Self.demoMode == "cut")
        }
      }
    #endif
    botView.isHidden = text.isEmpty
    followsVoice = progress?.live == true || progress?.cut == true
    botView.show(text, size: size, progress: progress)
    if progress != nil { voice.traceReading(raw: botView.estimated, shown: botView.shown, characters: botView.characterCount) }
    // The ring of the stop key fills as the lit edge goes through the words.
    if let shown = botView.shown, botView.characterCount > 0 { controls.setProgress(shown / Double(botView.characterCount)) }
    if progress?.live == true { startReading() } else { stopReading() }
  }

  private func startReading() {
    guard readingTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      self.updateReading()
    }
    RunLoop.main.add(timer, forMode: .common)
    readingTimer = timer
  }

  private func stopReading() {
    readingTimer?.invalidate()
    readingTimer = nil
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopReading()
    halo.hide(into: nil)
  }

  /// Brings the line the voice is on to about a quarter of the way down the words, a line at a time, unless a hand has just
  /// moved them (then the words are left to be read where they are, and the next line after a pause takes them back).
  private func follow(_ mark: CGRect) {
    guard Date().timeIntervalSince(handMovedTranscript) > 3, !transcript.isTracking, !transcript.isDragging, !transcript.isDecelerating
    else { return }
    transcript.layoutIfNeeded()
    let area = transcript.convert(mark, from: botView)
    let height = transcript.bounds.height
    let farthest = max(0, transcript.contentSize.height - height)
    let target = min(max(area.minY - height * 0.25, 0), farthest)
    if abs(target - transcript.contentOffset.y) > 2 { transcript.setContentOffset(CGPoint(x: 0, y: target), animated: true) }
  }

  /// The words fade where they go on past the edge of the area: at the top once they are scrolled, at the bottom while there is
  /// more below.
  private func updateFade() {
    let height = transcript.bounds.height
    guard height > 0 else { return }
    let offset = transcript.contentOffset.y
    let farthest = max(0, transcript.contentSize.height - height)
    let top = min(28, max(0, offset))
    let bottom = min(28, max(0, farthest - offset))
    let signature = "\(Int(offset.rounded()))/\(Int(height))/\(Int(top))/\(Int(bottom))/\(Int(transcript.bounds.width))"
    if signature == fadeSignature { return }
    fadeSignature = signature
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    transcriptFade.frame = CGRect(x: -8, y: offset, width: transcript.bounds.width + 16, height: height)
    transcriptFade.locations = [0, NSNumber(value: top / height), NSNumber(value: 1 - bottom / height), 1]
    CATransaction.commit()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) { if scrollView === transcript { updateFade() } }
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { handMovedTranscript = Date() }
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { handMovedTranscript = Date() }
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { handMovedTranscript = Date() }

  private func voiceName() -> String {
    let id = voice.voice
    return voice.speech?.voices.first { $0.id == id }?.name ?? id
  }

  private func controlsSaid(_ name: String, _ value: Any?) {
    switch name {
    // (While a touch on the page holds, the button's own reports are not a second hold.)
    case "down": if !summonActive { beginHold() }
    case "up": if !summonActive { endHold(send: true) }
    case "cancel": if !summonActive { endHold(send: false) }
    case "resume":
      if voice.playbackPaused, voice.togglePlaybackPause() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    case "stop":
      // The talk button, as a stop key while the reply is being said: the voice stops where it is and the words stay, lit as far
      // as it got.
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      Task { await voice.interrupt() }
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
    // The call's state keeps changing while the page goes: it is asked to go once.
    guard !closing else { return }
    closing = true
    (navigationController?.presentingViewController ?? presentingViewController)?.dismiss(animated: true)
  }

  private func minimize() {
    voice.minimize()
    closePage()
  }

  private func hangUp() {
    guard !closing else { return }
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


/// The light under a thumb that holds the page to talk: a pale ring that swells with the voice, and a thin line from it to the
/// talk button, so that it is plain the touch is the button. Grey when letting go would throw the words away.
final class TouchHalo: UIView {
  private let ring = CAShapeLayer()
  private let soft = CAShapeLayer()
  private let line = CAShapeLayer()
  private var button = CGPoint.zero
  private static let radius: CGFloat = 58

  var finger = CGPoint.zero { didSet { place() } }
  /// The voice's level, 0...1.
  var level: CGFloat = 0 {
    didSet {
      let scale = 1 + min(0.35, max(0, level) * 5)
      soft.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    }
  }
  var cancelling = false { didSet { if cancelling != oldValue { colour() } } }

  override init(frame: CGRect) {
    super.init(frame: frame)
    alpha = 0
    let circle = UIBezierPath(ovalIn: CGRect(x: -Self.radius, y: -Self.radius, width: Self.radius * 2, height: Self.radius * 2)).cgPath
    for layer in [soft, ring] {
      layer.path = circle
      layer.fillColor = UIColor.clear.cgColor
      self.layer.addSublayer(layer)
    }
    ring.lineWidth = 1.5
    soft.lineWidth = 10
    line.lineWidth = 1
    line.fillColor = UIColor.clear.cgColor
    line.lineDashPattern = [2, 5]
    line.lineCap = .round
    layer.addSublayer(line)
    colour()
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TouchHalo, _: UITraitCollection) in view.colour() }
  }

  required init?(coder: NSCoder) { fatalError() }

  private func colour() {
    // Pale on the dark page, dark on the light one.
    let tone = (cancelling ? Palette.onSurfaceVariant : Palette.onSurface).resolvedColor(with: traitCollection)
    ring.strokeColor = tone.withAlphaComponent(cancelling ? 0.6 : 0.85).cgColor
    soft.strokeColor = tone.withAlphaComponent(cancelling ? 0.1 : 0.2).cgColor
    line.strokeColor = tone.withAlphaComponent(cancelling ? 0.25 : 0.5).cgColor
  }

  private func place() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.position = finger
    soft.position = finger
    // From the ring's edge to the button, not through the ring.
    let dx = button.x - finger.x, dy = button.y - finger.y
    let length = max(1, hypot(dx, dy))
    let path = UIBezierPath()
    if length > Self.radius + 44 {
      path.move(to: CGPoint(x: finger.x + dx / length * (Self.radius + 6), y: finger.y + dy / length * (Self.radius + 6)))
      path.addLine(to: CGPoint(x: button.x - dx / length * 44, y: button.y - dy / length * 44))
    }
    line.path = path.cgPath
    CATransaction.commit()
  }

  func show(finger: CGPoint, button: CGPoint) {
    layer.removeAllAnimations()
    ring.removeAllAnimations()
    soft.removeAllAnimations()
    self.button = button
    self.finger = finger
    level = 0
    UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) { self.alpha = 1 }
  }

  /// Gone: drawn into the button when the words were sent, simply faded when they were not.
  func hide(into point: CGPoint?) {
    guard alpha > 0 else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    line.path = nil
    CATransaction.commit()
    if let point, !UIAccessibility.isReduceMotionEnabled {
      let move = CABasicAnimation(keyPath: "position")
      move.toValue = point
      let shrink = CABasicAnimation(keyPath: "transform.scale")
      shrink.toValue = 0.3
      for layer in [ring, soft] {
        for a in [move, shrink] {
          a.duration = 0.2
          a.timingFunction = CAMediaTimingFunction(name: .easeIn)
          a.fillMode = .forwards
          a.isRemovedOnCompletion = false
          layer.add(a.copy() as! CABasicAnimation, forKey: a.keyPath)
        }
      }
    }
    UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
      self.alpha = 0
    } completion: { _ in
      self.ring.removeAllAnimations()
      self.soft.removeAllAnimations()
    }
  }
}
