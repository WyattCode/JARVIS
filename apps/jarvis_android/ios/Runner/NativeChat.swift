import Combine
import SwiftUI
import PDFKit
import UIKit

// The chat as a native app on the Swift core: a split view (the system's sidebar on a wide window, a pushed list on a
// narrow one, moved into the strip by the system on the Duo) over `JarvisStore`. Nothing here knows of Flutter.

private let appBackground = UIColor { trait in
  trait.userInterfaceStyle == .dark
    ? UIColor(red: 9 / 255, green: 9 / 255, blue: 11 / 255, alpha: 1)
    : UIColor(red: 249 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1)
}

// MARK: Chat

@MainActor
final class ChatViewController: UIViewController {
  /// Every way up (see the root page): a page shown over it must not take the upside-down turn away again.
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
  private let store: JarvisStore
  private let voice: VoiceSession
  private let bridge = MessageBridge()
  private lazy var list = MessageListView(bridge: bridge)
  private let composer: NativeComposer
  private let welcome = UIHostingController(rootView: WelcomeView(greeting: "", starters: [], foldable: false, onPick: { _ in }))
  private let jump = UIButton(type: .system)
  private var composerHeight: NSLayoutConstraint!
  private var columnWidth: NSLayoutConstraint!
  private var composerBottom: NSLayoutConstraint!
  /// With the keyboard up the box widens to 8 pt from both sides and stands 8.5 pt above the keys (16 and the safe area at rest).
  private var keyboardUp = false
  /// Beside a docked list (the inner display) the box and the welcome page's four cards are 5% narrower.
  /// Their share of the width beside a docked list that is out (5% less, then 2% back, then 5% less again: asked for in steps).
  static let dockedScale = ChatLayout.dockedBox
  /// With the list folded away they are a fifth narrower again (that was asked for the folded state only).
  static let foldedScale = ChatLayout.foldedBox
  /// How far out the list beside the chat is, 0 (folded away) to 1 (out): the box and the cards go from one share of the width to the
  /// other with it, as the list moves, not at its ends.
  var dockedOpenness: CGFloat = 1 {
    didSet {
      guard abs(dockedOpenness - oldValue) > 0.0005 else { return }
      view.setNeedsLayout()
    }
  }
  private func dockScale(at openness: CGFloat) -> CGFloat { !dockedMode ? 1 : Self.foldedScale + (Self.dockedScale - Self.foldedScale) * openness }
  private var dockScale: CGFloat { dockScale(at: dockedOpenness) }
  /// The four starter cards of the welcome page: the chat's own, so that they move with the box (the page in SwiftUI laid them out
  /// at once for the width the slide ended at, and they jumped before the slide caught up).
  private let starterCards = StarterCards()
  private var cardsWidth: NSLayoutConstraint!
  /// The welcome page is as wide as the chat while a list is docked (its figure and greeting are laid out once, for that width, and
  /// move with the pane's centre as the box does: laid out at the pane's width they jumped to the width the slide ended at).
  private lazy var welcomeWidth = welcome.view.widthAnchor.constraint(equalToConstant: 400)
  private var cardsBottom: NSLayoutConstraint!
  private var cardsHeight: NSLayoutConstraint!
  /// The height the welcome page last had with no keyboard (whether there is room for the cards).
  private var welcomeRoom: CGFloat = 0

  /// The chat is about to change its width in a slide (the list beside it folds away or comes back). Laying the messages out again at
  /// every frame of that is heavy, and laying them out at once for the final width made them jump (the cover picture grew to its
  /// full height in the first frame, and everything under it moved): they are held as they stand, in a picture that moves with the
  /// chat, and made again for the new width when the slide has ended.
  /// The messages are held as a picture while the list beside the chat moves.
  private(set) var settling = false
  private var pictures: [(picture: UIView, live: UIView)] = []
  var hasPicture: Bool { settling }

  /// The picture is moved by how far the messages' left edge goes from where the slide began to where it is to end (see
  /// `messagesEdge`): the text then stands where the live messages will, and the dissolve does not show it twice. (It used to be moved
  /// by half of what the chat gave up, which holds only while the column keeps its width: it grows as the list goes, and the two
  /// texts stood a few points apart.)
  func slidePicture(by dx: CGFloat) {
    for held in pictures { held.picture.transform = CGAffineTransform(translationX: dx, y: 0) }
  }

  /// Where the messages' left edge stands in the chat's own page when the list is `openness` out and the page is `pane` wide.
  func messagesEdge(openness: CGFloat, pane: CGFloat) -> CGFloat {
    max(18, (pane - columns(in: pane, openness: openness).messages) / 2)
  }

  /// The messages are held as a picture during the slide (their layout is left alone until it is over); not when the page is coming back.
  private var holdingMessages = true

  func beginSettle(holdMessages: Bool = true) {
    guard !settling else { return }
    holdingMessages = holdMessages
    settling = true
    // What is held is the list as it stands now: laid out first (it may still be as it was when its page was away, a picture in it
    // smaller than it is to be).
    UIView.performWithoutAnimation {
      view.setNeedsLayout()
      view.layoutIfNeeded()
      list.layoutIfNeeded()
    }
    // Only the messages are held: the welcome page and its cards are live (the cards are laid out as the box is).
    guard holdMessages, !list.isHidden, let picture = list.snapshotView(afterScreenUpdates: false) else { return }
    picture.frame = list.frame
    picture.isUserInteractionEnabled = false
    view.insertSubview(picture, aboveSubview: list)
    list.alpha = 0
    pictures.append((picture, list))
    list.freeze(true)
  }

  /// The slide is over: the content is laid out for the width it has, and the pictures dissolve into it.
  func endSettle() {
    guard settling else { return }
    settling = false
    let held = pictures
    pictures = []
    list.freeze(false)
    view.setNeedsLayout()
    UIView.performWithoutAnimation { view.layoutIfNeeded() }
    // The content comes in as the picture goes out (shown at once, it would be seen beyond the picture's edge, which is where the
    // chat has become wider, in one frame).
    // The picture of the messages is not scaled to the new width: text would be near, but a picture in them (which stands at one size
    // whatever the column is) was shown at the wrong size until the end, and then jumped. Moved only; the new layout dissolves in.
    UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
      for item in held {
        item.live.alpha = 1
        item.live.transform = .identity
        item.picture.alpha = 0
      }
    } completion: { _ in held.forEach { $0.picture.removeFromSuperview() } }
  }
  var dockedMode = false {
    didSet {
      guard dockedMode != oldValue else { return }
      view.setNeedsLayout()
    }
  }
  /// The welcome page's floor: where the page's own floor stands with no keyboard. It does not move with the keyboard, so the
  /// figure and the greeting keep their size and place and only the cards give way (a layout that followed the keyboard
  /// shrank the figure and let it jump back).
  private lazy var welcomeBottom = welcome.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -200)
  private var bag = Set<AnyCancellable>()
  private var sentRevisions: [String: Int] = [:]
  private var sentOrder: [String] = []
  /// The conversation whose reply was being written at the last refresh, so that its end can be said to VoiceOver.
  private var wasGenerating: String?
  private var sentEnv = ""
  private var shownConversation = ""
  private var away = false, far = false
  private var scheduled = false
  private var fresh = Set<String>()
  private var barRight: [UIBarButtonItem] = []
  private var knownMessages = Set<String>()
  private var greeting = ""
  var sidebarDidSelect: (() -> Void)?
  /// The box's keyboard comes (true) or goes (false).
  var composerKeyboard: ((Bool) -> Void)?
  var toggleSidebar: (() -> Void)?
  private let heading = ChatHeadingView()

  init(store: JarvisStore, voice: VoiceSession) {
    self.store = store
    self.voice = voice
    composer = NativeComposer(frame: CGRect(x: 0, y: 0, width: 360, height: 90), args: ["draft": store.current.draft])
    super.init(nibName: nil, bundle: nil)
    greeting = timeGreeting(Date())
    composer.emit = { [weak self] name, value in self?.composerSaid(name, value) }
    bridge.act = { [weak self] a, done in self?.listSaid(a, done) }
    bridge.fetch = { [weak self] key, done in self?.picture(key, done) }
    PictureCache.shared.bridge = bridge
    // The bar's buttons are the system's own (round glass ones): on a foldable iPhone the system puts them in its vertical strip
    // by itself, at its own size, under the clock.
    let image = { (name: String) in UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)) }
    let more = UIBarButtonItem(
      image: image("ellipsis"),
      menu: UIMenu(children: [
        UIAction(title: "设置", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in self?.openSettings() },
        UIAction(title: "作品", image: UIImage(systemName: "photo.on.rectangle.angled")) { [weak self] _ in
          guard let self else { return }
          WorksSheet.present(store: self.store, from: self.navigationController ?? self)
        },
        UIAction(title: "模型状态", image: UIImage(systemName: "waveform.path.ecg")) { [weak self] _ in self?.openStatus() },
      ]))
    more.accessibilityLabel = "更多"
    let fresh = UIBarButtonItem(image: image("square.and.pencil"), primaryAction: UIAction { [weak self] _ in self?.newChat() })
    fresh.accessibilityLabel = "新建会话"
    let menu = makeListButton()
    for item in [menu, more, fresh] { item.tintColor = Palette.onSurface }
    navigationItem.leftBarButtonItem = menu
    // Separate round buttons, not one grouped capsule: a space between them splits the system's grouping.
    barRight = [more, .fixedSpace(0), fresh]
    navigationItem.rightBarButtonItems = barRight
    navigationItem.leftItemsSupplementBackButton = true
    store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.changed() }.store(in: &bag)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  private func makeListButton() -> UIBarButtonItem {
    let menu = UIBarButtonItem(image: Self.listIcon(), primaryAction: UIAction { [weak self] _ in self?.toggleSidebar?() })
    menu.accessibilityLabel = "会话列表"
    menu.tintColor = Palette.onSurface
    return menu
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // What the assistant asks to change in the service's models (load, unload, make room) waits for a yes here; without this it was
    // always answered no.
    store.confirmToolCall = { [weak self] action in
      await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        MainActor.assumeIsolated {
          // (the chat may be under another page: the app's window is asked then)
          let key = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
          guard let window = self?.view.window ?? key else { return c.resume(returning: false) }
          var answered = false
          let answer = { (yes: Bool) in
            guard !answered else { return }
            answered = true
            c.resume(returning: yes)
          }
          let shown = GlassConfirmDialog.show(
            title: "模型操作", lines: ["助手想要\(action)。", "这会改变服务上的模型状态，是否同意？"], confirm: "同意", in: window,
            dismissed: { answer(false) }, finish: answer)
          if !shown { answer(false) }
        }
      }
    }
    VideoCover.load = { [store] address, file in try await store.api.download(address, to: file) }
    VideoCover.normalize = { [store] address in (try? store.api.mediaURL(address))?.absoluteString ?? address }
    view.backgroundColor = appBackground
    navigationItem.largeTitleDisplayMode = .never
    // The bar is the page's own colour with nothing under it, as the original's header was.
    let bar = UINavigationBarAppearance()
    bar.configureWithTransparentBackground()
    bar.backgroundColor = Palette.surface
    bar.shadowColor = .clear
    navigationItem.standardAppearance = bar
    navigationItem.scrollEdgeAppearance = bar
    navigationItem.compactAppearance = bar
    let listView = list
    listView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(listView)
    addChild(welcome)
    cardsWidth = starterCards.widthAnchor.constraint(equalToConstant: 300)
    cardsBottom = starterCards.bottomAnchor.constraint(equalTo: welcome.view.bottomAnchor, constant: -20)
    cardsHeight = starterCards.heightAnchor.constraint(equalToConstant: 186)
    welcome.view.backgroundColor = .clear
    // The page does not make way for the keyboard by itself: it is laid out by what it is told, and nothing moves when it comes up.
    welcome.safeAreaRegions = []
    welcome.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(welcome.view)
    welcome.didMove(toParent: self)
    starterCards.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(starterCards)
    composer.attachments.onRemove = { [weak self] id in self?.store.removeAttachment(id) }
    composer.attachments.thumbnail = { [weak self] item, done in self?.attachmentPicture(item, done) }
    let box = composer.view()
    box.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(box)
    var config = UIButton.Configuration.plain()
    if #available(iOS 26.0, *) { config = .glass() } else { config = .tinted() }
    config.image = UIImage(systemName: "arrow.down")
    config.cornerStyle = .capsule
    jump.configuration = config
    jump.accessibilityLabel = "回到底部"
    jump.translatesAutoresizingMaskIntoConstraints = false
    jump.alpha = 0
    jump.addAction(UIAction { [weak self] _ in self?.list.toTail() }, for: .touchUpInside)
    view.addSubview(jump)
    composerHeight = box.heightAnchor.constraint(equalToConstant: 56)
    columnWidth = box.widthAnchor.constraint(equalToConstant: 340)
    composerBottom = box.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -1)
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    // A touch anywhere but the box puts the keyboard away (the touch itself still goes on to what it hit).
    let away = UITapGestureRecognizer(target: self, action: #selector(tappedAway))
    away.cancelsTouchesInView = false
    away.delegate = self
    view.addGestureRecognizer(away)
    // Any drag over the page (the list, the welcome page) puts the keyboard away, and the box comes back down with it.
    let dragAway = UIPanGestureRecognizer(target: self, action: #selector(draggedAway(_:)))
    dragAway.cancelsTouchesInView = false
    dragAway.delegate = self
    view.addGestureRecognizer(dragAway)
    #if DEBUG
    // JARVIS_FAKE_KEYBOARD=1: the simulator keeps its hardware keyboard, so the box is lifted by hand (up and down every 4 s) to look at
    // what the page does while the keyboard comes and goes.
    if ProcessInfo.processInfo.environment["JARVIS_FAKE_KEYBOARD"] == "1" {
      fakeKeyboard = 300
      Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.applyKeyboard(showing: !self.keyboardUp, duration: 0.5, curve: 7)
        }
      }
    }
    #endif
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      listView.topAnchor.constraint(equalTo: guide.topAnchor),
      listView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      listView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      // The list runs to the bottom of the page, under the box and under the keyboard (which is glass: what scrolls past shows through
      // it, and around the box, instead of a band of page colour); its last message stops above the box (`bottomInset`).
      listView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      welcome.view.topAnchor.constraint(equalTo: guide.topAnchor),
      welcome.view.centerXAnchor.constraint(equalTo: guide.centerXAnchor), welcomeWidth,
      welcomeBottom,
      starterCards.centerXAnchor.constraint(equalTo: guide.centerXAnchor), cardsWidth, cardsBottom, cardsHeight,
      box.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      columnWidth,
      composerBottom,
      composerHeight,
      jump.centerXAnchor.constraint(equalTo: guide.centerXAnchor),   // in the middle, above the box that is in the middle
      jump.bottomAnchor.constraint(equalTo: box.topAnchor, constant: -12),
      jump.widthAnchor.constraint(equalToConstant: 44), jump.heightAnchor.constraint(equalToConstant: 44),
    ])
    refresh(force: true)
    #if DEBUG
      scheduleDump()
      scheduleOpen()
    #endif
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(false, animated: animated)
    if navigationItem.rightBarButtonItems?.isEmpty != false { navigationItem.setRightBarButtonItems(barRight, animated: animated) }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    list.remeasure()
    refresh()
    warnAboutStorage()
  }

  private var warnedAboutStorage = false

  /// The saved file could not be read: nothing is saved until the person chooses to start fresh (the file is kept aside).
  private func warnAboutStorage() {
    guard !warnedAboutStorage, store.storageReadOnly, let text = store.storageError, presentedViewController == nil else { return }
    warnedAboutStorage = true
    present(
      FlatDialogController(
        title: "无法读取本机资料", paragraphs: [text],
        actions: [.init("知道了", .plain), .init("从空白开始", .destructive) { [store] in Task { await store.startFresh() } }]),
      animated: true)
  }

  /// The widths the original gave the page: on a foldable iPhone the composer (and the welcome cards) take 85% of the pane
  /// (89% with the list docked) and the messages a little less than the composer; on a phone a column of at most 720 pt with
  /// 10 pt beside the composer and 18 beside the messages.
  /// The inner display held upright: the box and the four cards are this share of their usual width.
  static let uprightScale = ChatLayout.uprightBox
  /// The window's shape and the pane the chat has, as the root works them out for the layout it is making. During a turn of the device
  /// the chat's own view is a pass or two behind (its bounds and safe area catch up one after another), and a box laid out from those
  /// took three different widths in three frames; laid out from these it stands where it will end in the first.
  var layoutSize: CGSize?
  var knownPane: CGFloat?
  private var shape: CGSize { layoutSize ?? view.bounds.size }
  private var upright: Bool { isInnerDisplayUpright(shape) }

  /// A foldable's outer display held sideways (no docked list, not the inner display upright): the box and the messages are the same
  /// share of the screen's width as held upright.
  private var outerSideways: Bool { isFoldablePhone(view) && !dockedMode && !upright && shape.width > shape.height }

  private func columns(in pane: CGFloat, openness: CGFloat? = nil) -> (composer: CGFloat, messages: CGFloat) {
    let dockScale = openness.map { dockScale(at: $0) } ?? self.dockScale
    if outerSideways {
      return OuterColumns.widths(shape: shape, pane: pane, keyboardUp: keyboardUp)
    }
    if isFoldablePhone(view) {
      // Held upright the inner display has a wide page: the box (and the cards above it) are a fifth shorter at rest.
      let composer = (pane - (keyboardUp ? 17 : 32)) * dockScale * (upright && !keyboardUp ? Self.uprightScale : 1)
      // Measured at the box's resting width: the keyboard widens the box, and messages that changed their width with it wrapped
      // again at every show and hide.
      let messages = (pane - 32) * 0.95 * ChatLayout.messagesShare
      // Beside a docked list the text is never wider than the box under it (folded, the box is the narrower of the two).
      let box = (pane - 32) * dockScale * (upright ? Self.uprightScale : 1)
      // Beside the docked list (and upright) the text is also a little narrower than the box it stands over (the box was what bound it:
      // with the list folded away the share above was past it, and asking for the text to be narrower changed nothing there).
      // Beside the docked list (out or folded away) and upright the text is the same share of the box: the box is what sets it there (the
      // looser share below set it in one state and not in the other, so that it was narrower beside the list than away from it).
      if dockedMode || upright { return (composer, min(pane - 36, box * ChatLayout.messagesInBox)) }
      return (composer, min(messages, pane - 36))

    }
    let reading = min(pane, 720)
    // Beside a docked list the box is 5% narrower here too (the chat's pane may not count as a foldable's: it is narrower).
    let box = (reading - 32) * dockScale
    return (box, min(reading - 36, dockedMode ? box : .infinity))
  }

  @objc private func tappedAway() { composer.handle("blur", nil) }

  @objc private func draggedAway(_ pan: UIPanGestureRecognizer) {
    if pan.state == .began { composer.handle("blur", nil) }
  }

  @objc private func keyboardChanged(_ note: Notification) {
    let showing = note.name == UIResponder.keyboardWillShowNotification
    // Only the box's own keyboard counts: the list's search field and the dialogs bring one up too.
    if showing ? !composer.isEditing : !keyboardUp { return }
    let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
    // The keyboard's own curve, so that the box and the keys move as one.
    let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
    applyKeyboard(showing: showing, duration: duration, curve: curve)
  }

  private var fakeKeyboard: CGFloat = 0
  /// How tall the box's text may grow (less where the room above the keyboard is short).
  private var fieldLimit = 160.0

  private func applyKeyboard(showing: Bool, duration: Double, curve: Int) {
    keyboardUp = showing
    composerKeyboard?(showing)
    if !showing {
      // A work that came ready while the person typed is shown now (once the page is back where it was).
      let front = navigationController?.topViewController === self && navigationController?.presentedViewController == nil && presentedViewController == nil
      autoWorks.flush(store: store, presenter: front ? (navigationController ?? self) : nil)
    }
    composerBottom.constant = (keyboardUp ? -8.5 : -1) - (keyboardUp ? fakeKeyboard : 0)
    welcome.rootView.keyboard = keyboardUp
    UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) { self.starterCards.alpha = self.keyboardUp ? 0 : 1 }
    starterCards.isUserInteractionEnabled = !keyboardUp
    view.setNeedsLayout()
    UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: UInt(curve) << 16), .beginFromCurrentState]) {
      self.view.layoutIfNeeded()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The last message stops above the box (the attachments are inside it; the keyboard is under it).
    let reach = max(0, view.bounds.height - composer.view().frame.minY + 4)
    if reach > 0 { list.bottomInset = reach }
    // The room between the top of the page and the keyboard (or the foot of the page): where it is short (a phone on its side, typing)
    // the attachments' tiles are small and the text grows less, so that the box never reaches past the screen's top.
    let room = view.keyboardLayoutGuide.layoutFrame.minY - view.safeAreaInsets.top
    var side = room < 400 ? ComposerAttachments.smallTile : ComposerAttachments.tile
    #if DEBUG
      // JARVIS_SMALL_TILES=1: the small tiles whatever the room (the simulator keeps its hardware keyboard, so the short room is not met).
      if ProcessInfo.processInfo.environment["JARVIS_SMALL_TILES"] == "1" { side = ComposerAttachments.smallTile }
    #endif
    if composer.attachments.side != side { composer.attachments.side = side }
    // (the row's room is taken only when there is a row)
    let rowRoom = composer.attachments.isEmpty ? 0 : side + ComposerAttachments.inset
    let limit = Double(max(54, min(160, room - rowRoom - 120)))
    if abs(limit - fieldLimit) > 0.5 {
      fieldLimit = limit
      composer.handle("update", ["maxFieldHeight": limit])
    }
    // Where the box's top stands with no keyboard (its bottom is 1 pt above the safe area), with 4 pt above it.
    let rest = -(1 + composerHeight.constant + 4)
    if abs(welcomeBottom.constant - rest) > 0.5 { welcomeBottom.constant = rest }
    let pane = knownPane ?? view.safeAreaLayoutGuide.layoutFrame.width
    let widths = columns(in: pane)
    if abs(columnWidth.constant - widths.composer) > 0.5 { columnWidth.constant = widths.composer }
    // The cards' row is as wide as the box beside a docked list; on its own it is the page less its margins, at most 620.
    let narrow = pane - 32 < 420
    let hostWidth = dockedMode ? max(shape.width, pane) : pane
    if abs(welcomeWidth.constant - hostWidth) > 0.5 { welcomeWidth.constant = hostWidth }
    let paneForPage: CGFloat? = dockedMode ? pane : nil
    if welcome.rootView.paneWidth != paneForPage { welcome.rootView.paneWidth = paneForPage }
    // The cards are as wide as the box at rest (not the keyboard's wider one: they are away then).
    let row = dockedMode || outerSideways ? widths.composer : upright ? (pane - 32) * dockScale * Self.uprightScale : min(620, max(0, pane - 32))
    if abs(cardsWidth.constant - row) > 0.5 { cardsWidth.constant = row }
    let cardsH = StarterCards.height(narrow: narrow)
    if abs(cardsHeight.constant - cardsH) > 0.5 { cardsHeight.constant = cardsH }
    starterCards.narrow = narrow
    let below = max(0, max(view.window?.safeAreaInsets.bottom ?? 34, 20) + 1 - 4)
    if abs(cardsBottom.constant + below) > 0.5 { cardsBottom.constant = -below }
    if !keyboardUp, welcome.view.bounds.height > 0 { welcomeRoom = welcome.view.bounds.height }
    starterCards.isHidden = welcome.view.isHidden || welcomeRoom < 380
    let env = "\(Int(list.bounds.width))|\(Int(widths.messages))|\(store.settings.messageFontSize + 1)"
    // Not while the list beside the chat moves: the messages are held (see `beginSettle`) and are made again at its end.
    if !(settling && holdingMessages), env != sentEnv { refresh(force: true) }
  }

  /// The list beside the chat is at `openness`: the box's and the cards' width for that is worked out before anything is laid out.
  func dockTarget(openness: CGFloat, pane: CGFloat, animated: Bool) {
    dockedOpenness = openness
    knownPane = pane
    // The box's and the cards' widths are set here, with the safe area that moves the page, so that one layout pass carries all of
    // them: set by `viewDidLayoutSubviews` after the move (as they were), the widths were a pass behind, and in a slide that is let run
    // they jumped to their end at once while the page was still on its way.
    let widths = columns(in: pane)
    if abs(columnWidth.constant - widths.composer) > 0.01 { columnWidth.constant = widths.composer }
    if abs(cardsWidth.constant - widths.composer) > 0.01 { cardsWidth.constant = widths.composer }
  }

  private func newChat() {
    _ = store.newConversation()
    sidebarDidSelect?()
  }

  /// The conversation-list mark of the Claude app's bar: two long lines and a short one.
  static func listIcon() -> UIImage {
    let size = CGSize(width: 20, height: 21)
    return UIGraphicsImageRenderer(size: size).image { context in
      let c = context.cgContext
      c.setStrokeColor(UIColor.black.cgColor)
      c.setLineWidth(2.0)
      c.setLineCap(.round)
      for (y, width) in [(3.0, 19.0), (10.5, 19.0), (18.0, 9.5)] {
        c.move(to: CGPoint(x: 1, y: y))
        c.addLine(to: CGPoint(x: width - 1, y: y))
      }
      c.strokePath()
    }.withRenderingMode(.alwaysTemplate)
  }

  /// A header button as the original drew it: the bare icon, no capsule behind it.
  private static func plainItem(image: String, label: String, menu: UIMenu? = nil, action: (() -> Void)? = nil) -> UIBarButtonItem {
    let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    let picture = UIImage(systemName: image, withConfiguration: configuration)
    let item: UIBarButtonItem
    if let menu {
      item = UIBarButtonItem(image: picture, menu: menu)
    } else {
      item = UIBarButtonItem(image: picture, primaryAction: UIAction { _ in action?() })
    }
    item.tintColor = Palette.onSurfaceVariant
    item.accessibilityLabel = label
    if #available(iOS 26.0, *) { item.hidesSharedBackground = true }
    return item
  }

  /// A failed connection is tried again by a tap on the status dot.
  private func reconnect() {
    guard store.connectionError != nil else { return }
    Task { await store.retryConnect() }
  }

  func openSettings() {
    let page = SettingsHostController(store: store) { [weak self] in self?.navigationController?.popToRootViewController(animated: true) }
    pushPage(PageContainer(title: "设置", content: page))
  }

  private func openStatus() {
    let page = StatusHostController(store: store)
    let refresh = UIButton.barIcon("arrow.clockwise", label: "刷新状态") { [weak page] in Task { await page?.refresh() } }
    pushPage(PageContainer(title: "模型状态", content: page, trailing: refresh))
  }

  /// The bar's right-hand buttons go as the page comes in: the page has fewer, and the ones with nothing to become would otherwise
  /// hang on for the length of the slide. They come back, animated, when the chat does.
  private func pushPage(_ page: UIViewController) {
    navigationItem.setRightBarButtonItems(nil, animated: false)
    navigationController?.navigationBar.layoutIfNeeded()
    DispatchQueue.main.async { [weak self] in self?.navigationController?.pushViewController(page, animated: true) }
  }

  // MARK: Following the store

  private func changed() {
    guard !scheduled else { return }
    scheduled = true
    // The store says it will change; what it changed to is there on the next turn of the run loop.
    DispatchQueue.main.async { [weak self] in
      self?.scheduled = false
      self?.refresh()
    }
  }

  /// A work that comes ready while the person chats is shown at once.
  private let autoWorks = WorksAutoPop()

  private func refresh(force: Bool = false) {
    guard isViewLoaded else { return }
    // Only from the chat when it is the page in front (not under the settings, the call or a sheet).
    let front = navigationController?.topViewController === self && navigationController?.presentedViewController == nil && presentedViewController == nil
    autoWorks.check(store: store, presenter: front ? (navigationController ?? self) : nil, typing: keyboardUp)
    // What the store refused (a regenerate with text in the box, a media task still running) is told once, not left unsaid.
    // (a lost connection is the status chip's to tell, not a notice at every retry)
    if store.authenticated, let refusal = store.error, refusal != store.connectionError {
      store.clearError()
      show(refusal)
    }
    let c = store.current
    let switched = c.id != shownConversation
    if switched {
      shownConversation = c.id
      away = false
      far = false
      list.resetScroll()
      sentRevisions = [:]
      sentOrder = []
      paced = [:]
      knownMessages = Set(c.messages.map(\.id))
      fresh = []
    } else {
      let ids = Set(c.messages.map(\.id))
      fresh = ids.subtracting(knownMessages)
      knownMessages = ids
    }
    // What the store holds is what the box shows (a sent message empties it); the box ignores what it already has.
    composer.handle("draft", c.draft)
    let generating = store.isGenerating(c.id)
    if wasGenerating == c.id, !generating, !switched, UIAccessibility.isVoiceOverRunning {
      let last = c.messages.last { $0.role == "assistant" }
      let said = last?.status == "interrupted" ? (last?.error == nil ? "已停止" : "回复中断") : "回复完成"
      UIAccessibility.post(notification: .announcement, argument: said)
    }
    wasGenerating = generating ? c.id : nil
    let rows = MessageRows.rows(c, generating: generating)
    // A different conversation is drawn at once, whatever the throttle says.
    pushRows(rows, force: force || switched)
    if welcome.view.isHidden != !c.messages.isEmpty {
      welcome.view.isHidden = !c.messages.isEmpty
      starterCards.isHidden = welcome.view.isHidden || welcomeRoom < 380
      view.setNeedsLayout()
    }
    if !c.messages.isEmpty { LaunchLanding.figure = nil }
    list.isHidden = c.messages.isEmpty
    if c.messages.isEmpty {
      welcome.rootView = WelcomeView(
        greeting: greeting, starters: store.starters, foldable: isFoldablePhone(view),
        screenHeight: view.window?.bounds.height ?? 680, onPick: { [weak self] starter in self?.pick(starter) },
        onFigure: { [weak self] in if self?.store.current.messages.isEmpty ?? false { LaunchLanding.figure = $0 } }, bottomGap: max(view.window?.safeAreaInsets.bottom ?? 34, 20) + 1, keyboard: keyboardUp,
        paneWidth: dockedMode ? view.safeAreaLayoutGuide.layoutFrame.width : nil)
      starterCards.set(store.starters, onPick: { [weak self] in self?.pick($0) })
    }
    let hasDraft = !c.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !c.pendingAttachments.isEmpty
    let loading = store.attachmentsLoading(c.id)
    composer.handle(
      "update",
      [
        "generating": generating,
        "ready": store.authenticated && !store.model.isEmpty && !loading,
        "hasAttachments": !c.pendingAttachments.isEmpty,
        "blocked": ChatStatus.sendBlockedReason(
          hasDraft: hasDraft, generating: generating, authenticated: store.authenticated, hasModel: !store.model.isEmpty,
          loading: loading) as Any,
        "effort": store.effort,
        "attachesPhotos": true,
        "compact": false,
        "foldable": false,
        "maxFieldHeight": fieldLimit,
        "loading": loading,
      ])
    composer.attachments.apply(c.pendingAttachments, loading: loading)
    updateJump()
  }

  /// While a reply is written, any step away from the tail offers the way back; at rest only a long way.
  private func updateJump() {
    let generating = store.isGenerating(store.current.id)
    let target: CGFloat = (generating ? away : far) ? 1 : 0
    jump.isAccessibilityElement = target > 0
    if jump.alpha != target { UIView.animate(withDuration: 0.18) { self.jump.alpha = target } }
  }

  // MARK: Pacing the reply

  /// How much of each streaming reply is shown, in characters. A reply is written onto the page at a steady pace that catches up
  /// with what has arrived (about a seventh of the backlog per frame, at least a character), so a fast stream reads as writing
  /// and not as jumps.
  private var paced: [String: Int] = [:]
  private var pacer: CADisplayLink?
  private var arrived: [MessageRow] = []

  private func pace(_ rows: [MessageRow]) -> [MessageRow] {
    arrived = rows
    var behind = false
    var out = rows
    for i in out.indices {
      guard case .object(var o) = out[i].json, case .string(let kind)? = o["kind"], kind == "assistant",
        case .string(let text)? = o["text"]
      else { continue }
      let id = out[i].id
      let streaming: Bool = {
        if case .string(let status)? = o["status"] { return status == "generating" }
        return false
      }()
      guard streaming || paced[id] != nil else { continue }
      let total = text.count
      var shown = min(paced[id] ?? (fresh.contains(id) ? 0 : total), total)
      if shown < total {
        let step = max(1, Int((Double(total - shown) * (total > 1500 ? 0.3 : 0.14)).rounded(.up)))
        shown = min(total, shown + (pacer == nil ? 0 : step))
      }
      if shown >= total && !streaming {
        paced[id] = nil
        continue
      }
      paced[id] = shown
      if shown < total { behind = true }
      o["text"] = .string(String(text.prefix(shown)))
      var hasher = Hasher()
      hasher.combine(out[i].revision)
      hasher.combine(shown)
      out[i] = MessageRow(id: id, revision: hasher.finalize(), json: .object(o))
    }
    if behind {
      if pacer == nil {
        let link = CADisplayLink(target: DisplayProxy(self), selector: #selector(DisplayProxy.tick(_:)))
        link.preferredFramesPerSecond = 30
        pacerSkip = 0
        link.add(to: .main, forMode: .common)
        pacer = link
      }
    } else if pacer != nil {
      pacer?.invalidate()
      pacer = nil
    }
    return out
  }

  /// Long replies are drawn less often: laying out a long text 30 times a second is more than the main thread can do.
  private var pacerSkip = 0
  private var pacerEvery = 1

  func pacerTick() {
    guard !arrived.isEmpty else { return }
    let longest = arrived.reduce(0) { max($0, $1.json.stringLength) }
    let every = longest > 4000 ? 6 : longest > 1500 ? 3 : longest > 600 ? 2 : 1
    pacerSkip += 1
    if pacerSkip < max(every, pacerEvery) { return }
    pacerSkip = 0
    // Draw no more often than the main thread can bear: after a slow draw the next ones wait in proportion to how long it took,
    // so the page stays alive however long the reply is.
    let began = CACurrentMediaTime()
    pushRows(arrived, force: false)
    let took = CACurrentMediaTime() - began
    pacerEvery = min(30, max(1, Int((took * 3 / (1.0 / 30)).rounded(.up))))
  }

  private var lastPushAt = 0.0
  private var lastPushTook = 0.0

  private func startPacer() {
    guard pacer == nil else { return }
    let link = CADisplayLink(target: DisplayProxy(self), selector: #selector(DisplayProxy.tick(_:)))
    link.preferredFramesPerSecond = 30
    link.add(to: .main, forMode: .common)
    pacer = link
  }

  private func pushRows(_ original: [MessageRow], force: Bool) {
    // Rows arrive with every piece the server sends, far more often than the page can draw them. While one is slow to draw, the
    // newest state is kept and drawn by the next tick of the pacer, not at once.
    let now = CACurrentMediaTime()
    if !force, now - lastPushAt < max(1.0 / 30, lastPushTook * 3), original.contains(where: { $0.json.stringLength > 600 }) {
      arrived = original
      startPacer()
      return
    }
    defer {
      lastPushTook = CACurrentMediaTime() - now
      lastPushAt = CACurrentMediaTime()
    }
    let rows = pace(original)
    var changedRows: [String: String] = [:]
    for row in rows {
      // A row is sent again only when its revision changed (the JSON's key order is not stable enough to compare).
      if !force, sentRevisions[row.id] == row.revision { continue }
      guard let data = try? JSONEncoder().encode(row.json), let json = String(data: data, encoding: .utf8) else { continue }
      changedRows[row.id] = json
      sentRevisions[row.id] = row.revision
    }
    let order = rows.map(\.id)
    let present = Set(order)
    sentRevisions = sentRevisions.filter { present.contains($0.key) }
    let messageColumn = columns(in: view.safeAreaLayoutGuide.layoutFrame.width).messages
    let env = "\(Int(list.bounds.width))|\(Int(messageColumn))|\(store.settings.messageFontSize + 1)"
    var state: [String: Any] = ["order": order, "changed": changedRows]
    if !fresh.isEmpty { state["fresh"] = Array(fresh) }
    if force || env != sentEnv {
      sentEnv = env
      let column = columns(in: view.safeAreaLayoutGuide.layoutFrame.width).messages
      let inset = max(18, (list.bounds.width - column) / 2)
      state["fontSize"] = Double(store.settings.messageFontSize) + 1
      state["left"] = Double(inset)
      state["right"] = Double(inset)
      state["userMax"] = Double(min(640, column * ChatLayout.userBubble))
    }
    if changedRows.isEmpty && state["fontSize"] == nil && order == sentOrder { return }
    sentOrder = order
    list.apply(state)
  }

  // MARK: What the composer says

  #if DEBUG
    /// `JARVIS_DUMP=<seconds>`: writes the list's state to the log that long after launch.
    func scheduleDump() {
      guard let delay = Double(ProcessInfo.processInfo.environment["JARVIS_DUMP"] ?? "") else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self else { return }
        try? self.list.debugDump().write(toFile: "/tmp/claude-501/dump.txt", atomically: true, encoding: .utf8)
      }
    }

    /// `JARVIS_OPEN=settings|status|call|works|play|confirm|rename`: that page or dialog comes up 1.5 s after launch (tools/smoke.sh looks at them).
    func scheduleOpen() {
      guard let what = ProcessInfo.processInfo.environment["JARVIS_OPEN"] else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        guard let self, let window = self.view.window else { return }
        switch what {
        case "settings": self.openSettings()
        case "works": WorksSheet.present(store: self.store, from: self.navigationController ?? self)
        case "play":
          // (a cut-short file is told by its name: a video kept earlier under the other one is not met)
          let cut = ProcessInfo.processInfo.environment["JARVIS_DEMO_VIDEO_BROKEN"] != nil
          MediaViewer.play(url: "http://internal.host:9000/v1/files/clip\(cut ? "-cut" : "").mp4") {}
        case "status": self.openStatus()
        case "call": NativeCall.present(from: self.navigationController ?? self, store: self.store, voice: self.voice)
        case "confirm":
          GlassConfirmDialog.show(title: "删除这个会话？", lines: ["删除后无法恢复。"], confirm: "删除", destructive: true, in: window) { _ in }
        case "rename":
          GlassRenameDialog.show(title: "重命名", text: "封面设计", in: window, room: window.bounds) { _ in }
        default: break
        }
      }
    }
  #endif

  private func composerSaid(_ name: String, _ value: Any?) {
    switch name {
    case "height":
      if let h = value as? Double, abs(composerHeight.constant - CGFloat(h)) > 0.5 {
        composerHeight.constant = CGFloat(h)
        view.layoutIfNeeded()
      }
    case "draft": store.setDraft(value as? String ?? "")
    case "send":
      composer.handle("blur", nil)
      Task {
        guard await AiNotice.ensure(store: store, from: navigationController ?? self) else { return }
        await store.send()
      }
    case "stop": store.cancel(store.current.id)
    case "effort": store.setEffort(value as? String ?? "high")
    case "attach": attach(value as? String ?? "files")
    case "voice":
      Task {
        guard await AiNotice.ensure(store: store, from: navigationController ?? self) else { return }
        NativeCall.start(from: navigationController ?? self, store: store, voice: voice)
      }
    default: break
    }
  }

  /// A starter is written into the box (after what is there), never sent.
  private func pick(_ starter: Starter) {
    let written = store.current.draft.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    let draft = written.isEmpty ? starter.prompt : "\(written)\n\(starter.prompt)"
    store.setDraft(draft)
    composer.handle("draft", draft)
    composer.handle("focus", nil)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  private func attach(_ choice: String) {
    let owner = store.current.id
    Task { [store] in
      // The copies the picker made are removed whichever way this ends (attaching may stop before it reads one: too many, too big).
      var picked: [URL] = []
      defer { picked.forEach(FilesService.discardCopy) }
      do {
        let sources: [AttachmentSource]
        switch choice {
        case "photos", "camera":
          let pictures = choice == "photos" ? try await FilesService.shared.pickPhotos() : try await FilesService.shared.takePhoto()
          sources = pictures.compactMap {
            if case .picture(let name, let bytes) = $0 { return AttachmentSource(name: name, data: bytes, isImage: true) }
            return nil
          }
          if let failed = pictures.compactMap({ p -> String? in if case .failed(let m) = p { return m } else { return nil } }).first,
            sources.isEmpty
          {
            return show(failed)
          }
        default:
          let urls = try await FilesService.shared.openFiles(types: [.data], multiple: true)
          picked = urls
          sources = urls.map { url in
            AttachmentSource(
              name: url.lastPathComponent,
              length: { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 },
              read: {
                defer { FilesService.discardCopy(url) }
                return try Data(contentsOf: url)
              })
          }
        }
        if sources.isEmpty { return }
        try await Attachments.attach(sources, to: owner, in: store, pdf: store.api as? PDFExtractor)
      } catch let e as JarvisException {
        show(e.message)
      } catch let e as FilesFailure {
        show(e.message)
      } catch {
        show("添加附件失败，请重试")
      }
    }
  }

  private func show(_ text: String) { showNotice(text) }

  // MARK: What the list says

  private func listSaid(_ a: [String: Any], _ done: @escaping ([String: Any]?) -> Void) {
    switch a["a"] as? String {
    case "tap", "drag": composer.handle("blur", nil)
    case "scroll":
      away = a["away"] as? Bool ?? false
      far = a["far"] as? Bool ?? false
      updateJump()
    case "link":
      if let s = a["url"] as? String, let url = URL(string: s), ["http", "https", "mailto", "tel"].contains(url.scheme ?? "") {
        UIApplication.shared.open(url)
      }
    case "regenerate", "retry": Task { await store.regenerate() }
    case "continue": Task { await store.continueReply() }
    case "cancelTask": if let id = a["id"] as? String { store.cancelMediaTask(store.current.id, id) }
    case "retryTask": if let id = a["id"] as? String { Task { await store.retryMedia(store.current.id, id) } }
    case "preview": preview(a)
    case "attachment": openAttachment(a)
    case "save": return save(a, done)
    default: break
    }
    done(nil)
  }

  /// Whether an address is a file of this server (it is fetched with the person's session; any other is fetched as a plain public one).
  private func isOurs(_ url: URL) -> Bool {
    // The same host and port (the scheme is not compared: the service may name its own files with another one, and they were fetched
    // with the session before pictures of other servers were let in).
    if url.path.hasPrefix("/v1/files/") || url.path.hasPrefix("/v1/videos/") { return true }
    return url.host == store.api.endpoint.host && url.port == store.api.endpoint.port
  }

  /// The bytes of a picture or video: from this server with the session, from any other server (https only) as a plain request.
  private func bytes(_ address: String) async throws -> Data {
    // An attachment of this conversation (`att:<id>`) is a file of the vault.
    if address.hasPrefix("att:") {
      guard let data = (try? store.vault.readBlob(String(address.dropFirst(4)))) ?? nil else { throw JarvisException("无法获取") }
      return data
    }
    guard let url = resolve(address) else { throw JarvisException("地址无效") }
    if isOurs(url) { return try await store.api.download(url.absoluteString) }
    guard url.scheme == "https" else { throw JarvisException("不支持的地址") }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(from: url)
    guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, data.count <= 64 * 1024 * 1024 else {
      throw JarvisException("无法获取")
    }
    return data
  }

  /// A picture in the viewer, whichever server it is on (a click on a picture in a reply used to open the browser for any that was
  /// not this server's); a video of another server opens in the browser.
  private func preview(_ a: [String: Any]) {
    guard let address = a["url"] as? String, let url = resolve(address) else { return }
    if a["kind"] as? String == "video", !isOurs(url) {
      UIApplication.shared.open(url)
      return
    }
    if a["kind"] as? String == "video" {
      MediaViewer.play(url: url.absoluteString) {}
    } else {
      MediaViewer.show(url: url.absoluteString, source: viewerSource(for: url.absoluteString, mime: "image/png"))
    }
  }

  /// The picture of a tile in the box: a picture attachment itself, a file's first page (made by Quick Look from the file's bytes).
  private func attachmentPicture(_ item: Attachment, _ done: @escaping (UIImage?) -> Void) {
    if item.kind == "image" {
      PictureCache.shared.load("att:\(item.id)", done)
      return
    }
    // A text file (a table, notes) is shown as the top of a page with its first lines on it.
    if item.mime != "application/pdf", let text = item.text, !text.isEmpty {
      done(Self.textPage(text))
      return
    }
    // A PDF's first page is drawn from its bytes in memory (nothing of a decrypted file is written out for it).
    let vault = store.vault
    Task.detached(priority: .userInitiated) {
      let picture = ((try? vault.readBlob(item.id)) ?? nil)
        .flatMap { PDFDocument(data: $0)?.page(at: 0) }
        .map { $0.thumbnail(of: CGSize(width: 240, height: 312), for: .mediaBox) }
      await MainActor.run { done(picture) }
    }
  }

  /// The top of a page with the first lines of a text on it, in small print (what a file's tile shows of it).
  private static func textPage(_ text: String) -> UIImage {
    let size = CGSize(width: 160, height: 208)
    // (only the top of the text is read: a file of 100,000 characters is not laid out for a tile; line ends of any kind end a line)
    let lines = text.prefix(4000).components(separatedBy: .newlines).prefix(24).joined(separator: "\n")
    return UIGraphicsImageRenderer(size: size).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byTruncatingTail
      (lines as NSString).draw(
        in: CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20),
        withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor(white: 0.2, alpha: 1), .paragraphStyle: style])
    }
  }

  /// A picture sent with a message, full screen (a document has nothing to open).
  private func openAttachment(_ a: [String: Any]) {
    guard let id = a["id"] as? String,
      let att = store.current.messages.lazy.flatMap(\.attachments).first(where: { $0.id == id }), att.kind == "image"
    else { return }
    MediaViewer.show(url: "att:\(id)", source: viewerSource(for: "att:\(id)", mime: att.mime))
  }

  private func resolve(_ address: String) -> URL? {
    URL(string: address, relativeTo: store.api.endpoint)?.absoluteURL
  }

  private func viewerSource(for address: String, mime: String) -> ViewerSource {
    let notes = CurrentValueSubject<SaveNote?, Never>(nil)
    return ViewerSource(
      fetch: { [weak self] _, answer in
        Task { answer(try? await self?.bytes(address)) }
      },
      save: { [weak self] in
        guard notes.value != .busy else { return }
        notes.send(.busy)
        Task {
          do {
            guard let data = try await self?.bytes(address) else { throw JarvisException("无法获取") }
            let ext = mime.hasPrefix("video") ? "mp4" : "png"
            _ = try await FilesService.shared.saveToPhotos(FileSource(name: "jarvis.\(ext)", bytes: data, path: nil), mime: mime)
            notes.send(.saved)
          } catch let e as FilesFailure {
            notes.send(e.code == "photos_denied" ? .denied : .failed)
          } catch {
            notes.send(.failed)
          }
          try? await Task.sleep(nanoseconds: 2_200_000_000)
          notes.send(nil)
        }
      },
      notes: notes.eraseToAnyPublisher())
  }

  private func save(_ a: [String: Any], _ done: @escaping ([String: Any]?) -> Void) {
    guard let id = a["id"] as? String, let task = store.current.tasks.first(where: { $0.id == id }), let first = task.urls.first,
      let url = resolve(first)
    else { return done(["result": "failed"]) }
    let video = task.kind == "video"
    Task { [store] in
      do {
        if video, let file = await VideoCover.saved(url.absoluteString) {
          _ = try await FilesService.shared.saveToPhotos(FileSource(name: "jarvis.mp4", bytes: nil, path: file.path), mime: "video/mp4")
        } else {
          let data = try await store.api.download(url.absoluteString)
          _ = try await FilesService.shared.saveToPhotos(
            FileSource(name: video ? "jarvis.mp4" : "jarvis.png", bytes: data, path: nil), mime: video ? "video/mp4" : "image/png")
        }
        done(["result": "saved"])
      } catch let e as FilesFailure {
        done(["result": e.code == "photos_denied" ? "denied" : "failed"])
      } catch {
        done(["result": "failed"])
      }
    }
  }

  /// A picture the list asks for: an attachment of this conversation or a file of this server.
  private func picture(_ key: String, _ done: @escaping (Data?) -> Void) {
    if key.hasPrefix("att:") {
      let id = String(key.dropFirst(4))
      done(((try? store.vault.readBlob(id)) ?? nil))
    } else if key.hasPrefix("url:"), resolve(String(key.dropFirst(4))) != nil {
      let address = String(key.dropFirst(4))
      Task { done(try? await self.bytes(address)) }
    } else {
      done(nil)
    }
  }
}

extension ChatViewController: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { a is UIPanGestureRecognizer }

  func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard let box = touch.view else { return true }
    return !box.isDescendant(of: composer.view())
  }
}
