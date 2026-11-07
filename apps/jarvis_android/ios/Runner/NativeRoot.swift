import Combine
import SwiftUI
import UIKit

// The app's one screen: the window's root, the chat beside or under the conversation list (see `RootContainerViewController`).

private let appBackground = UIColor { trait in
  trait.userInterfaceStyle == .dark
    ? UIColor(red: 9 / 255, green: 9 / 255, blue: 11 / 255, alpha: 1)
    : UIColor(red: 249 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1)
}

/// Builds the app around a store.
@MainActor
enum NativeChatApp {
  static func makeRoot(store: JarvisStore) -> UIViewController {
    let root = RootContainerViewController(store: store)
    root.view.backgroundColor = appBackground
    return root
  }
}

/// The app's one screen: the chat inside a navigation controller, and the conversation list beside it (docked, in a wide
/// window) or over it (a drawer that slides in from the left, in a narrow one). It keeps the window in the app's own light or
/// dark choice ("system" is the device's). No system split view: its back button would stand in the foldable's strip.
@MainActor
final class RootContainerViewController: UIViewController, UIGestureRecognizerDelegate, UINavigationControllerDelegate {
  /// The list's slide, and how far into it the messages are made again for the new width (the picture dissolves into them there).
  private static let slideDuration = 0.42
  private static let dissolveAt = 0.5
  /// Every way up (see the root page): a page shown over it must not take the upside-down turn away again.
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
  private let store: JarvisStore
  /// The call; the store holds it weakly, so it lives here.
  let voice: VoiceSession
  private let chat: ChatViewController
  private let nav: UINavigationController
  private let sidebar: SidebarViewController
  /// The list stands in a navigation controller of its own, so that beside a vertical bar strip the system puts the list's
  /// buttons (close, search, new) in the strip, as it does for the chat's.
  private let sideNav: UINavigationController
  private let dim = UIView()
  private var bag = Set<AnyCancellable>()
  private var open = false
  /// A finger is moving the drawer: layout passes leave it where the finger put it.
  private var dragging = false
  /// The real drawer is on the move (sliding, or under a finger).
  private var moving = false

  private var sliding = false
  private var slideToken = 0
  private let drawerFraction = ChatLayout.drawer

  init(store: JarvisStore) {
    self.store = store
    voice = VoiceSession(store: store, audio: EngineAudioDevice())
    voice.traceSink = { SpeechTraceFile.shared.write($0) }
    store.voice = voice
    chat = ChatViewController(store: store, voice: voice)
    nav = UINavigationController(rootViewController: chat)
    sidebar = SidebarViewController(store: store)
    sideNav = UINavigationController(rootViewController: sidebar)
    super.init(nibName: nil, bundle: nil)
    chat.sidebarDidSelect = { [weak self] in self?.close() }
    // The box's keyboard is the chat's: the list beside it (a page of SwiftUI, which gives way to a keyboard by itself) stays as it is, so
    // that its rows and its foot do not jump behind the keys. Its own search field still gets the keyboard's room.
    chat.composerKeyboard = { [weak self] up in self?.sidebar.safeAreaRegions = up ? .container : .all }
    sidebar.onChoose = { [weak self] in self?.close() }
    sidebar.onClose = { [weak self] in self?.toggle() }
    sidebar.onSettings = { [weak self] in
      self?.close()
      self?.chat.openSettings()
    }
    chat.toggleSidebar = { [weak self] in self?.toggle() }
    store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.followTheme() }
    }.store(in: &bag)
    // While a call is on (held to talk or hands-free), the screen does not dim or lock: it is let go when the call ends.
    voice.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        let on = self.voice.active
        if UIApplication.shared.isIdleTimerDisabled != on { UIApplication.shared.isIdleTimerDisabled = on }
      }
    }.store(in: &bag)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  /// The list stands beside the chat only on an inner display: the shorter side is at least 600 pt, the window is wider than it is
  /// tall, and 760 pt are left beside the system's strip (the original's rule). The outer display of a foldable never has it, in
  /// either landscape: there the chat is the whole page and the list is the drawer (it used to be docked there, a screen 678 pt wide).
  private var wide: Bool {
    let w = view.bounds.width, h = view.bounds.height
    #if DEBUG
      // JARVIS_FORCE_WIDE=1: the old rule (wide enough and wider than tall), to look at the docked list on a smaller screen.
      if ProcessInfo.processInfo.environment["JARVIS_FORCE_WIDE"] == "1" { return w > h && w >= 600 }
    #endif
    return min(w, h) >= 600 && w > h && w - view.safeAreaInsets.left - view.safeAreaInsets.right >= 760
  }

  // MARK: Half-folded (the hinge between the two halves of the inner display is bent)

  /// The hinge is partly open: the inner display stands as two screens, one each side of the crease.
  private var hingePartlyOpen = false
  /// What the last layout was made for (the fold changes with the hinge, and with a page that comes up or goes).
  private var foldApplied = false
  private var hingeInteraction: AnyObject?

  /// Half-folded, sideways, and no page over the chat: the list has the left screen and the chat the right one, half each, with the
  /// crease between (nothing of either is put on it).
  private var folded: Bool {
    #if DEBUG
      // JARVIS_FOLD=1: the half-folded arrangement, on a flat display (the simulator cannot bend its hinge).
      if ProcessInfo.processInfo.environment["JARVIS_FOLD"] == "1" { return wide && !pageActive }
    #endif
    return wide && hingePartlyOpen && !pageActive
  }

  /// The crease, in this view's coordinates (its centre line when the system names none).
  private var foldGap: CGRect {
    if #available(iOS 27.1, *), let region = view.reservedRegions(kind: .division, options: [.includeInactive]).first {
      return region.frame
    }
    return CGRect(x: view.bounds.midX - 20, y: 0, width: 40, height: view.bounds.height)
  }

  private func watchHinge() {
    guard #available(iOS 27.1, *) else { return }
    let interaction = UIHingeInteraction { [weak self] _, update in
      MainActor.assumeIsolated {
        let open = update.hinge?.status == .partiallyOpen
        guard let self, self.hingePartlyOpen != open else { return }
        self.hingePartlyOpen = open
        self.syncFold()
      }
    }
    view.addInteraction(interaction)
    hingeInteraction = interaction
  }

  /// The fold has changed (the hinge, or a page): the list and the chat go to their halves, or back, on one spring. The messages are held
  /// as a picture that moves with the chat's edge while it goes (see `beginSettle`).
  private func syncFold() {
    guard isViewLoaded, wide else { foldApplied = false; return }
    let now = folded
    guard now != foldApplied else { return }
    finishDockMotion()
    dockToken += 1
    let token = dockToken
    // The start is measured with the width the screen is laid out with now (`folded` has already changed, and with it `dockedWidth`).
    let from = messagesLeft(dockProgress, width: laidWidth)
    foldApplied = now
    // A drag of the grip that the hinge cut short is over.
    grip.dragging = false
    grip.isHidden = !wide || now || pageActive
    chat.navigationItem.leftBarButtonItem?.isHidden = now
    let target: CGFloat = now ? 1 : (dockedOpen ? 1 : 0)
    guard !UIAccessibility.isReduceMotionEnabled else {
      dockProgress = target
      layoutDocked()
      return
    }
    chat.beginSettle(holdMessages: !returningFromPage)
    dockBusy = true
    UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
      self.dockProgress = target
      self.dockBusy = false
      self.layoutDocked()
      self.dockBusy = true
      self.chat.slidePicture(by: self.messagesLeft(target) - from)
      self.view.layoutIfNeeded()
    } completion: { [weak self] _ in
      // A newer slide, or a turn to another arrangement, has taken over (it ends what it began): this one leaves it alone.
      guard let self, token == self.dockToken, self.wide else { return }
      self.dockBusy = false
      self.layoutDocked()
      self.chat.endSettle()
    }
  }

  /// The docked width the screen was last laid out with.
  private var laidWidth: CGFloat = 0

  /// The docked list's width: 31.9% of what the strip leaves, between 251 and 308 pt, less a tenth. Half-folded it is the left screen,
  /// up to the far edge of the crease.
  private var dockedWidth: CGFloat {
    if folded { return foldGap.maxX }
    let usable = view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
    let base = min(308, max(251, usable * 0.319))
    // What is seen (the column less the strip's place at its left, where the strip is on that side) is a tenth wider than the
    // original's (it was tried at 90%, 94.5% and 100%); the rows and the search box are as wide as that.
    let strip = view.safeAreaInsets.left
    return strip + (base - strip) * ChatLayout.dockedListStretch
  }
  /// The docked list is shown (the button and the grip fold it away and bring it back); how far out it is, 0...1, while it moves.
  private var dockedOpen = true
  private var dockProgress: CGFloat = 1
  private var wasWide = false
  /// What the list was across a turn away from the sideways arrangement and across the pages that fold it (see `DockMemory`).
  private var memory = DockMemory()
  private let grip = DockGripView()
  private var gripStart: CGFloat = 1
  private var dockPan: UIPanGestureRecognizer?
  /// A hard swipe to the left over the list or the chat folds the list.
  private var dockSwipe: UIPanGestureRecognizer?

  // MARK: Pages that do not need the list

  /// Set while such a page is up: whether the list was out when it came, to be brought back with the chat.
  private var restoreDock: Bool?

  /// A page that has no use for the list (the settings, the model status, a call, the works, the privacy page...) comes up: the list
  /// beside the chat folds away, to come back when the chat does.
  private func pageUp(animated: Bool) {
    guard wide else { return }
    if restoreDock == nil { restoreDock = dockedOpen }
    if foldApplied {
      // A page leaves the half-folded arrangement: the list goes from its screen to away, on the fold's own slide (not a slide made
      // for the width it has not any more).
      dockedOpen = false
      syncFold()
      grip.isHidden = true
      return
    }
    if dockedOpen || dockProgress > 0.001 { setDockedOpen(false, animated: animated) }
    grip.isHidden = true
  }

  private var returningFromPage = false

  private func pageDown() {
    guard let wasOut = restoreDock else { return }
    restoreDock = nil
    returningFromPage = true
    grip.isHidden = !wide || folded
    // Come back to a wide arrangement later (the device was turned while the page was up): the list is as it was before the page.
    memory.pageLeft(wasOut: wasOut, sideways: wide)
    if folded {
      // Half-folded again with the page gone: the list and the chat go back to their screens.
      syncFold()
    } else if wide, wasOut {
      setDockedOpen(true, animated: true)
    } else if wide {
      grip.wake()
    }
    // (it is for the slide just begun; one that never began must not leave it set for the next)
    returningFromPage = false
  }

  /// A page with no use for the list is up: the list is folded away and cannot be pulled out (no grip, no swipe, no button).
  private var pageActive: Bool { restoreDock != nil }

  func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
    guard viewController === chat else {
      // A page with no use for the list: the list folds as the page comes.
      pageUp(animated: animated)
      return
    }
    // The way back is one motion: the list comes out as the page goes. A swipe back that is still under the finger brings nothing
    // out (it used to put the list and its grip over the page that was still there); the moment it is let go for good, they come.
    if let coordinator = navigationController.transitionCoordinator, coordinator.isInteractive {
      coordinator.notifyWhenInteractionChanges { [weak self] context in
        if !context.isCancelled { self?.pageDown() }
      }
    } else {
      pageDown()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // A full-screen page over everything (the settings from the list, a call, the works): not seen, so not animated.
    if presentedViewController != nil || nav.presentedViewController != nil { pageUp(animated: false) }
  }

  private func comingBack() {
    if presentedViewController == nil, nav.presentedViewController == nil, nav.topViewController === chat { pageDown() }
  }
  private var touchWatcher: UILongPressGestureRecognizer?

  @objc private func listTouched(_ gesture: UILongPressGestureRecognizer) {
    if gesture.state == .began { grip.wake(hold: dockBusy) }
  }
  /// Beside a vertical bar strip the drawer covers the whole window (its own strip buttons replace the chat's); otherwise it
  /// takes 88% of the screen.
  /// How dark the page behind the drawer gets. Not at all when the drawer is as wide as the window (a foldable's strip): there
  /// the page is never seen beside it, only darkened for a moment on its way under it, which on a light page was a grey flash,
  /// and the strip's column, the last the drawer reaches, stayed grey until it jumped to the drawer's colour.
  private var dimOpen: CGFloat { sidebarWidth >= view.bounds.width - 1 ? 0 : 1 }


  /// What kind of phone this is and how it is held, worked out once per layout pass (the drawer's width is asked for at every touch
  /// of a drag, and the answer needs the system's fold regions).
  private var straightPhone = false
  private var straightPortrait = false
  private func refreshShape(_ size: CGSize) {
    straightPhone = isStraightPhone(view)
    straightPortrait = straightPhone && size.height > size.width
  }

  private var sidebarWidth: CGFloat {
    if wide { return dockedWidth }
    if hasVerticalBar(traitCollection) || isInnerDisplayUpright(view.bounds.size) || straightPortrait { return view.bounds.width }
    // A phone on its side: the drawer is a column of a usual width, not 88% of a very wide window.
    return min(view.bounds.width * (straightPhone ? ChatLayout.drawerStraight : drawerFraction), ChatLayout.drawerMost)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = appBackground
    nav.navigationBar.prefersLargeTitles = false
    nav.delegate = self
    // The page under the chat hides the system's bar when it has its own (a phone), and with it goes the swipe from the edge back: it is
    // let through here.
    nav.interactivePopGestureRecognizer?.delegate = self
    addChild(nav)
    view.addSubview(nav.view)
    nav.didMove(toParent: self)
    dim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    dim.alpha = 0
    dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))
    view.addSubview(dim)
    addChild(sideNav)
    view.addSubview(sideNav.view)
    sideNav.view.backgroundColor = Palette.card
    sideNav.didMove(toParent: self)
    let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    pan.delegate = self
    view.addGestureRecognizer(pan)
    let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgePanned(_:)))
    edge.edges = .left
    edge.delegate = self
    view.addGestureRecognizer(edge)
    let dock = UIPanGestureRecognizer(target: self, action: #selector(dockPanned(_:)))
    dock.delegate = self
    view.addGestureRecognizer(dock)
    dockPan = dock
    let swipe = UIPanGestureRecognizer(target: self, action: #selector(dockSwiped(_:)))
    swipe.delegate = self
    swipe.cancelsTouchesInView = false
    view.addGestureRecognizer(swipe)
    dockSwipe = swipe
    // A touch on the list (it takes nothing from it) shows the grip, as a touch at the grip's own place does.
    let watcher = UILongPressGestureRecognizer(target: self, action: #selector(listTouched(_:)))
    watcher.minimumPressDuration = 0
    watcher.allowableMovement = .greatestFiniteMagnitude
    watcher.cancelsTouchesInView = false
    watcher.delaysTouchesBegan = false
    watcher.delegate = self
    view.addGestureRecognizer(watcher)
    touchWatcher = watcher
    grip.onTap = { [weak self] in
      guard let self else { return }
      UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
      self.setDockedOpen(!self.dockedOpen, animated: true)
    }
    view.addSubview(grip)
    watchHinge()
    layoutPanes(animated: false)
    foldApplied = folded
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    followTheme()
    comingBack()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if !dragging { layoutPanes(animated: false) }
  }

  /// A turn: a finger still on the drawer lets go where it is (its range was for the old shape), and the list decides its bar for the
  /// new shape now, inside the turn, not in its first layout afterwards.
  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    refreshShape(size)
    if dragging { release(velocity: 0) }
    sidebar.prepareBar(windowSize: size)
  }

  // A turn between upright and sideways is the system's own (no snapshot, no fade): a page that lays itself out for the new shape in
  // `viewDidLayoutSubviews` is turned into place by the system the way every other app on the device is.

  /// Wide: the list is a column of its own and the chat takes the rest. Narrow: the chat has the whole window; the list is a
  /// drawer, in or out. The drawer's own view always has its open size and place; it moves by its transform, which leaves its
  /// layout (and the strip's safe-area inset) alone. (Moving a picture of it instead put a still image of its glass and text
  /// in its place, and the swap back to the real thing at the end of the slide showed as a change of colour.)
  private func layoutPanes(animated: Bool) {
    defer { memory.started(view.window != nil && view.bounds.width > 100) }
    refreshShape(view.bounds.size)
    let bounds = view.bounds
    let width = sidebarWidth
    let docked = wide
    // The chat's box and starter cards are 5% narrower beside a docked list (the inner display).
    chat.dockedMode = docked
    chat.layoutSize = bounds.size
    chat.knownPane = docked ? dockedPane(dockProgress) : bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
    sidebar.docked = docked
    if !docked { chat.dockedOpenness = 1 }
    if !docked {
      // Left the docked arrangement (a turn to the outer display, a fold): a slide that was under way ends where it was going.
      foldApplied = false
      chat.navigationItem.leftBarButtonItem?.isHidden = false
      if wasWide {
        wasWide = false
        // What the list was when the device was turned away from the wide arrangement comes back with it (see below). Held upright
        // the conversation page is the list at the whole window's width: out when the list was out, folded away when it was.
        // (with a page up the list is folded for it: what it was before the page is what is kept)
        memory.leftSideways(listOut: restoreDock ?? dockedOpen)
        // Turned upright with the list out beside the chat: the list goes at once and the chat is shown (the list page is there
        // from the button, not in the way). Back to sideways it comes out again unless the person opened or closed it meanwhile.
        open = false
        finishDockMotion()
        dockBusy = false
        nav.view.transform = .identity
        nav.additionalSafeAreaInsets = .zero
        stripContainer(in: sideNav.view)?.transform = .identity
      }
      nav.view.frame = bounds
    }
    dim.frame = bounds
    dim.isUserInteractionEnabled = !docked && open
    grip.isHidden = !docked || pageActive || folded
    if docked {
      // Coming to a docked arrangement (the inner display, or a turn of the device to it): the list is out at the very first, and
      // afterwards as it was left (or as the drawer was when the device was upright): a list that was closed is not put out by a turn.
      if !wasWide {
        wasWide = true
        // A pull of the drawer that was under the finger as the device turned is over.
        dragging = false
        let out = memory.enteredSideways(pageOpen: open)
        if nav.topViewController !== chat || nav.presentedViewController != nil || presentedViewController != nil {
          // A page was opened upright and is still up: the list stays folded for it and comes back with the chat, as if the page had
          // come up in this arrangement (it was put out beside the page).
          restoreDock = restoreDock ?? out
          dockedOpen = false
        } else {
          dockedOpen = out
        }
        dockProgress = dockedOpen ? 1 : 0
        grip.wake()
      }
      // The list is on the move (a finger on the grip, or the slide after it): the layout pass of its frames leaves it alone.
      if dockBusy { return }
      endPull()
      moving = false
      picture?.removeFromSuperview()
      picture = nil
      pendingHand?.cancel()
      pendingHand = nil
      sliding = false
      open = false
      sideNav.view.isHidden = false
      sideNav.view.layer.shadowOpacity = 0
      sideNav.view.accessibilityViewIsModal = false
      nav.view.accessibilityElementsHidden = false
      sideNav.view.alpha = 1
      sideNav.view.layer.mask = nil
      view.insertSubview(sideNav.view, aboveSubview: nav.view)
      layoutDocked()
      view.bringSubviewToFront(grip)
      dim.alpha = 0
      return
    }
    if dragging { return }
    if animated && !UIAccessibility.isReduceMotionEnabled {
      slide(to: open, width: width)
      return
    }
    // A slide is under way: the layout pass of its frames leaves it alone. A drawer left off its place with no slide (Reduce
    // Motion, a drag that was let go) is put back here.
    if sliding { return }
    endPull()
    moving = false
    picture?.removeFromSuperview()
    picture = nil
    placeDrawer(width: width)
    restDrawer(open: open)
    dim.alpha = open ? dimOpen : 0
  }

  // MARK: Docked list: folding it away and bringing it back

  /// The list is on the move (a finger on the grip, or the slide that follows it).
  private var dockBusy = false
  private var dockAnimator: UIViewPropertyAnimator?
  /// Tells a slide from the one before it (the end of an old one must not touch the state of a new one).
  private var dockToken = 0

  /// The system's strip of buttons is at the left edge (where the docked list reaches it: its buttons are the list's) or at the right
  /// (where the chat reaches it: its buttons are the chat's, whether the list is out or not).
  private var stripOnLeft: Bool {
    if #available(iOS 27.1, *) { return traitCollection.verticalBarEdge != .trailing }
    return true
  }

  /// How visible the list's strip buttons and the chat's are with the list as far out as `progress`.
  private func stripAlphas(_ progress: CGFloat) -> (list: CGFloat, chat: CGFloat) {
    stripOnLeft ? (progress, 1 - progress) : (0, 1)
  }

  /// What the chat gives up on its left for the list, beyond what the system already keeps clear there (the strip, where it is on
  /// that side). The chat's view is always the whole window; this is how much of it is the list's. (The chat used to be resized
  /// with the list: the system sets its strip of buttons down again whenever its page changes its size, and in the slide the
  /// buttons vanished and came back, shifting sideways, at every fold and unfold.)
  private func dockedInset(_ progress: CGFloat, width: CGFloat? = nil) -> CGFloat {
    max(0, (width ?? dockedWidth) * progress - view.safeAreaInsets.left)
  }

  /// Where the messages' left edge stands (in the window) with the list at `progress`: what the chat gives up on its left, and the
  /// column's place in what is left.
  private func messagesLeft(_ progress: CGFloat, width: CGFloat? = nil) -> CGFloat {
    dockedInset(progress, width: width) + chat.messagesEdge(openness: progress, pane: dockedPane(progress, width: width))
  }

  /// How wide the chat's pane is (its safe area) with the list at `progress`.
  private func dockedPane(_ progress: CGFloat, width: CGFloat? = nil) -> CGFloat {
    view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right - dockedInset(progress, width: width)
  }

  private func applyDockedChat(_ progress: CGFloat, animated: Bool = false) {
    chat.dockTarget(openness: progress, pane: dockedPane(progress), animated: animated)
    nav.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: dockedInset(progress), bottom: 0, right: 0)
  }

  /// Where the slide began (the list's progress then): the messages' picture is moved from there.
  private var dockOrigin: CGFloat = 1

  /// The list stands where `progress` says by its transform alone (its own layout, and the strip's inset, stay as they are).
  private func dockedListShift(_ progress: CGFloat) -> CGAffineTransform {
    CGAffineTransform(translationX: -(dockedWidth * (1 - progress)), y: 0)
  }

  /// The strip's buttons of the list stay where they are while the list moves (they would ride with it): the opposite shift.
  private func holdListStrip(_ progress: CGFloat) {
    stripContainer(in: sideNav.view)?.transform = CGAffineTransform(translationX: dockedWidth * (1 - progress), y: 0)
  }

  /// The docked arrangement at rest, the list as far out as `dockProgress` says: the chat takes what the list leaves. Nothing is
  /// laid out while the list is on the move (see `settleDocked`).
  private func layoutDocked() {
    guard !dockBusy else { return }
    // Half-folded the list is always out (it has its screen); the room beside the crease is kept clear of its rows.
    if folded { dockProgress = 1 }
    sideNav.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: folded ? foldGap.width : 0)
    nav.view.transform = .identity
    nav.view.frame = view.bounds
    applyDockedChat(dockProgress)
    placeDrawer(width: dockedWidth)
    sideNav.view.transform = dockedListShift(dockProgress)
    let away = dockProgress <= 0.001
    // Folded away it takes no touch and says nothing to VoiceOver; docked it is a column of its own.
    sideNav.view.isUserInteractionEnabled = !away
    sideNav.view.accessibilityElementsHidden = away
    // The strip's buttons: the list's when it is out, the chat's when it is not.
    stripContainer(in: sideNav.view)?.transform = .identity
    let alphas = stripAlphas(away ? 0 : 1)
    stripContainer(in: sideNav.view)?.alpha = alphas.list
    stripContainer(in: nav.view)?.alpha = alphas.chat
    grip.place(x: gripEdge, height: view.bounds.height)
    grip.isOpen = dockedOpen
    laidWidth = dockedWidth
    foldApplied = folded
    grip.isHidden = pageActive || folded
    chat.navigationItem.leftBarButtonItem?.isHidden = folded
  }

  /// Where the grip stands: at the chat's left edge, which with the list folded away is clear of the system's strip (when the strip
  /// is on that side), not under it.
  private var gripEdge: CGFloat { max(dockedWidth * dockProgress, view.safeAreaInsets.left) }

  /// The button: the list folds away or comes back.
  private func setDockedOpen(_ open: Bool, animated: Bool) {
    // (half-folded the list has its screen: nothing folds it away until the hinge is open again)
    guard !folded else { return }
    dockedOpen = open
    finishDockMotion()
    let target: CGFloat = open ? 1 : 0
    guard animated, !UIAccessibility.isReduceMotionEnabled, abs(dockProgress - target) > 0.001 else {
      dockProgress = target
      layoutDocked()
      return
    }
    dockBusy = true
    settleDocked(to: target, velocity: 0)
  }

  /// Ends a slide that is under way where it was going (a new one is wanted, or the window changed).
  private func finishDockMotion() {
    dockToken += 1
    if let a = dockAnimator {
      dockAnimator = nil
      a.stopAnimation(false)
      a.finishAnimation(at: .end)
    }
    if dockBusy {
      dockBusy = false
      layoutDocked()
    }
    chat.endSettle()
  }

  /// Slides the list and resizes the chat to `target` (0 folded away, 1 out), together, on one spring.
  ///
  /// The chat is the real view the whole way: it is laid out once, inside the animation, and every part of it (the header, the box,
  /// the cards, the messages) goes from where it stood to where it will stand by the animation's own interpolation, with no layout
  /// at the frames between. What would once make that stutter was the message list laying out all its rows again as its width
  /// changed: the rows are made at their new size without animation (see `MessageListView.layoutSubviews`), so they do not fly in.
  private func settleDocked(to target: CGFloat, velocity: CGFloat) {
    dockToken += 1
    let token = dockToken
    let fromProgress = dockProgress
    // The messages' picture moves from where the slide began (a drag has begun it already).
    if !chat.hasPicture { dockOrigin = fromProgress }
    let origin = dockOrigin
    // Coming back from a page: the chat is still arriving (its view has not its place yet, and a picture of it taken now is of a stale
    // layout, smaller than the real one), so nothing is held and the messages are laid out as they slide.
    chat.beginSettle(holdMessages: !returningFromPage)
    returningFromPage = false
    holdListStrip(fromProgress)
    view.bringSubviewToFront(grip)
    let distance = abs(target - fromProgress) * dockedWidth
    let initial = distance > 1 ? CGVector(dx: min(8, max(-8, velocity / distance)), dy: 0) : .zero
    let animator = UIViewPropertyAnimator(duration: Self.slideDuration, timingParameters: UISpringTimingParameters(dampingRatio: 1, initialVelocity: initial))
    animator.addAnimations {
      self.dockProgress = target
      self.applyDockedChat(target, animated: true)
      self.nav.view.layoutIfNeeded()
      self.chat.slidePicture(by: self.messagesLeft(target) - self.messagesLeft(origin))
      self.sideNav.view.transform = self.dockedListShift(target)
      self.holdListStrip(target)
      let alphas = self.stripAlphas(target)
      self.stripContainer(in: self.sideNav.view)?.alpha = alphas.list
      self.stripContainer(in: self.nav.view)?.alpha = alphas.chat
      self.grip.place(x: self.gripEdge, height: self.view.bounds.height)
    }
    animator.addCompletion { [weak self] _ in
      guard let self, token == self.dockToken else { return }
      self.dockAnimator = nil
      self.dockBusy = false
      self.layoutDocked()
      self.chat.endSettle()
    }
    dockAnimator = animator
    animator.startAnimation()
    grip.wake()
    // The messages are made again for the new width, and the picture dissolves into them, as the slide comes to rest (not after it:
    // the slide used to stand still for a few frames before that).
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideDuration * Self.dissolveAt) { [weak self] in
      guard let self, token == self.dockToken else { return }
      self.chat.endSettle()
    }
  }

  /// A swipe to the left that is quick and mostly sideways (a scroll, or a slow drag, is not it): the list folds away.
  @objc private func dockSwiped(_ pan: UIPanGestureRecognizer) {
    guard pan.state == .ended, wide, !folded, dockedOpen, !pageActive, !dockBusy else { return }
    let v = pan.velocity(in: view), t = pan.translation(in: view)
    if v.x < -800, t.x < -50, abs(v.x) > abs(v.y) * 2 { setDockedOpen(false, animated: true) }
  }

  /// A drag on the grip: the list follows the finger and the chat moves with it as it is (it is not laid out at every move); when
  /// it is let go the slide above settles it at the nearer end, or the way a flick goes.
  @objc private func dockPanned(_ pan: UIPanGestureRecognizer) {
    guard wide else { return }
    let width = max(dockedWidth, 1)
    switch pan.state {
    case .began:
      finishDockMotion()
      dockBusy = true
      gripStart = dockProgress
      dockOrigin = dockProgress
      grip.dragging = true
      chat.beginSettle()
    case .changed:
      guard dockBusy else { return }
      let p = min(1, max(0, gripStart + pan.translation(in: view).x / width))
      dockProgress = p
      // The chat is resized under the finger, not moved: its edge by the window's stays where it is (moved, the system's strip of
      // buttons left the window's edge and became a row of buttons at the top, flying with the page). Its messages are a picture
      // (see `beginSettle`), so only the header, the box and the cards are laid out at each move.
      applyDockedChat(p)
      nav.view.layoutIfNeeded()
      chat.slidePicture(by: messagesLeft(p) - messagesLeft(dockOrigin))
      sideNav.view.transform = dockedListShift(p)
      holdListStrip(p)
      let alphas = stripAlphas(p)
      stripContainer(in: sideNav.view)?.alpha = alphas.list
      stripContainer(in: nav.view)?.alpha = alphas.chat
      grip.place(x: gripEdge, height: view.bounds.height)
    case .ended, .cancelled, .failed:
      guard dockBusy, dockAnimator == nil else { return }
      grip.dragging = false
      let velocity = pan.velocity(in: view).x
      // A flick says which way; otherwise the half-way mark does.
      let open = abs(velocity) > 300 ? velocity > 0 : dockProgress >= 0.5
      dockedOpen = open
      settleDocked(to: open ? 1 : 0, velocity: velocity)
    default: break
    }
  }

  /// The drawer at rest. Open: above the page. Closed: still drawn, but behind the page (so that it is not hidden and shown again
  /// each time it is pulled out).
  private func restDrawer(open: Bool) {
    sideNav.view.isHidden = false
    sideNav.view.alpha = 1
    sideNav.view.layer.mask = nil
    stripContainer(in: sideNav.view)?.alpha = 1
    stripContainer(in: sideNav.view)?.transform = .identity
    stripContainer(in: nav.view)?.alpha = open ? 0 : 1
    sideNav.view.layer.shadowOpacity = open ? 0.35 : 0
    sideNav.view.layer.shadowRadius = 18
    sideNav.view.layer.shadowPath = UIBezierPath(rect: sideNav.view.bounds).cgPath
    sideNav.view.isUserInteractionEnabled = open
    sideNav.view.accessibilityElementsHidden = !open
    sideNav.view.accessibilityViewIsModal = open
    nav.view.accessibilityElementsHidden = open
    // Moved only when it is not already where it belongs: moving a view cancels the touch its buttons are tracking.
    let order = view.subviews
    if let side = order.firstIndex(of: sideNav.view) {
      if open {
        if let d = order.firstIndex(of: dim), side < d { view.insertSubview(sideNav.view, aboveSubview: dim) }
      } else if let n = order.firstIndex(of: nav.view), side > n {
        view.insertSubview(sideNav.view, belowSubview: nav.view)
      }
    }
  }

  private func placeDrawer(width: CGFloat) {
    sideNav.view.transform = .identity
    sideNav.view.bounds = CGRect(x: 0, y: 0, width: width, height: view.bounds.height)
    sideNav.view.center = CGPoint(x: width / 2, y: view.bounds.height / 2)
  }

  /// The system's strip of round buttons lives inside the page's own view, in a container of its own. It is found by its class
  /// name (nothing of it is called); if a system version names it otherwise, nil is returned and the strip is treated like any
  /// other part of the page.
  private func stripContainer(in page: UIView) -> UIView? {
    page.subviews.first { String(describing: type(of: $0)).contains("FloatingBarContainer") }
  }

  /// The drawer is put on the move. Opening: the real drawer itself slides out (a picture of it, swapped for the real one at the
  /// end, showed as a change of colour as the drawer stopped). Closing: a picture of it slides away, with the strip's buttons
  /// left out of it; the real drawer goes behind the page so that the page's own buttons are in view for the whole of the slide
  /// (with the real drawer above the page they stayed out of sight until it was put away, and then all three appeared at once).
  private func beginMove(opening: Bool) {
    guard !moving else { return }
    moving = true
    // The keyboard of the page (or of the list's search) would stay over the list.
    view.endEditing(true)
    // A pull (a finger on the drawer) takes the drawer's strip buttons along with it, as the rest of the drawer goes; a tap on
    // the list button leaves them where they are and changes them over in place.
    riding = !buttonTap
    placeDrawer(width: sidebarWidth)
    sideNav.view.isHidden = false
    sideNav.view.alpha = 1
    sideNav.view.layer.mask = nil
    sideNav.view.layer.shadowRadius = 18
    sideNav.view.layer.shadowPath = UIBezierPath(rect: sideNav.view.bounds).cgPath
    sideNav.view.isUserInteractionEnabled = false
    sideNav.view.accessibilityElementsHidden = false
    if opening {
      sideNav.view.transform = CGAffineTransform(translationX: closedShift, y: 0)
      sideNav.view.layer.shadowOpacity = 0.35
      stripContainer(in: sideNav.view)?.alpha = riding ? 1 : 0
      holdStrip(shift: closedShift)
      view.insertSubview(sideNav.view, aboveSubview: dim)
      shiftNow = closedShift
      if riding && dragging {
        let a = UIViewPropertyAnimator(duration: 1, curve: .linear) { self.sideNav.view.transform = .identity }
        a.pausesOnCompletion = true
        a.pauseAnimation()
        pullAnimator = a
      }
    } else if riding {
      // The buttons are in the picture and go away with it; the real drawer is behind the page, whose own buttons are live
      // underneath and come into view as the picture leaves them.
      sideNav.view.layer.shadowOpacity = 0
      if let pic = sideNav.view.snapshotView(afterScreenUpdates: false) {
        pic.frame = sideNav.view.frame
        pic.isUserInteractionEnabled = false
        pic.layer.shadowColor = UIColor.black.cgColor
        pic.layer.shadowOpacity = 0.35
        pic.layer.shadowRadius = 18
        pic.layer.shadowOffset = .zero
        view.insertSubview(pic, aboveSubview: dim)
        picture = pic
        view.insertSubview(sideNav.view, belowSubview: nav.view)
        stripContainer(in: nav.view)?.alpha = 1
      } else {
        view.insertSubview(sideNav.view, aboveSubview: dim)
      }
    } else {
      sideNav.view.layer.shadowOpacity = 0
      let strip = stripContainer(in: sideNav.view)
      stripWindow = strip.map { stripButtonRects(in: $0, of: sideNav.view) }.map { rects in
        let path = UIBezierPath()
        for r in rects { path.append(UIBezierPath(roundedRect: r, cornerRadius: r.height / 2)) }
        return path.cgPath
      }
      strip?.alpha = 0
      let taken = sideNav.view.snapshotView(afterScreenUpdates: strip != nil)   // true: so that the strip being out is in it
      strip?.alpha = 1
      if let pic = taken {
        pic.frame = sideNav.view.frame
        pic.isUserInteractionEnabled = false
        pic.layer.shadowColor = UIColor.black.cgColor
        pic.layer.shadowOpacity = 0.35
        pic.layer.shadowRadius = 18
        pic.layer.shadowOffset = .zero
        view.insertSubview(pic, aboveSubview: dim)
        picture = pic
        // Until the buttons change hands the drawer's own stay in view, drawn through a window in the real drawer above the picture.
        sideNav.view.layer.mask = stripMask()
        view.insertSubview(sideNav.view, aboveSubview: pic)
      } else {
        view.insertSubview(sideNav.view, aboveSubview: dim)   // no picture: the real drawer slides away
      }
    }
    // Both pages' buttons stand in the same places: only one set may show. A tap on the list button lets its press settle first
    // (the buttons change hands 0.15s into the slide, which starts at once); a pull has no press and changes at once.
    if riding {
      buttonTap = false
    } else if buttonTap {
      stripContainer(in: sideNav.view)?.alpha = opening ? 0 : 1
      stripContainer(in: nav.view)?.alpha = opening ? 1 : 0
      buttonTap = false
      let work = DispatchWorkItem { [weak self] in self?.handStrip(opening: opening) }
      pendingHand = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    } else {
      handStrip(opening: opening)
    }
  }

  /// The picture of the drawer that slides away when it closes.
  private var picture: UIView?
  /// The drawer's strip buttons move with it (a pull) instead of standing still (a tap on the list button).
  private var riding = false
  private var stripWindow: CGPath?
  private var pendingHand: DispatchWorkItem?
  /// Set by `toggle()`: the next slide begins with a tap on the list button.
  private var buttonTap = false

  /// What moves: the picture while there is one, otherwise the real drawer.
  private var mover: UIView { picture ?? sideNav.view }

  /// The drawer's strip buttons stay where the system puts them while the real drawer moves: it places them from the drawer's
  /// transform as it stands, so under a finger (the transform following it at every move) they rode in with the drawer. A
  /// transform of the opposite sign on their container cancels that out.
  private func holdStrip(shift: CGFloat) {
    guard picture == nil, !riding else { return }
    stripContainer(in: sideNav.view)?.transform = CGAffineTransform(translationX: -shift, y: 0)
  }

  private func stripMask() -> CAShapeLayer {
    let mask = CAShapeLayer()
    mask.path = stripWindow
    return mask
  }

  /// Where each of the strip's buttons is inside `page`.
  private func stripButtonRects(in container: UIView, of page: UIView) -> [CGRect] {
    var found: [CGRect] = []
    func walk(_ v: UIView) {
      if String(describing: type(of: v)).contains("GlassInteractionView") {
        found.append(v.convert(v.bounds, to: page).insetBy(dx: -1, dy: -1))
      } else {
        v.subviews.forEach(walk)
      }
    }
    walk(container)
    return found
  }

  /// The system's strip of round buttons lives inside each page's own view, in a container of its own (found by its class name;
  /// nothing of it is called). Opening: the drawer's buttons are in, the page's out. Closing: the other way round.
  private func handStrip(opening: Bool) {
    pendingHand?.cancel()
    pendingHand = nil
    guard moving, !riding else { return }
    if opening, picture == nil {
      // The buttons stay where they are and change into the drawer's: the page's fade out as the drawer's fade in.
      let own = stripContainer(in: sideNav.view), page = stripContainer(in: nav.view)
      UIView.animate(withDuration: 0.22, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
        page?.alpha = 0
        own?.alpha = 1
      }
    } else if opening, let pic = picture {   // turned round while closing: the real drawer is wanted above the picture again
      stripContainer(in: sideNav.view)?.alpha = 1
      stripContainer(in: nav.view)?.alpha = 0
      sideNav.view.layer.mask = stripMask()
      view.insertSubview(sideNav.view, aboveSubview: pic)
    } else if let pic = picture {
      sideNav.view.layer.mask = CAShapeLayer()
      view.insertSubview(sideNav.view, belowSubview: nav.view)
      stripContainer(in: nav.view)?.alpha = 1
      view.bringSubviewToFront(pic)
    } else {
      // Turned round while opening by a tap: the drawer's buttons (held in place) change back into the page's.
      let own = stripContainer(in: sideNav.view), page = stripContainer(in: nav.view)
      UIView.animate(withDuration: 0.18, delay: 0, options: [.curveLinear, .allowUserInteraction, .beginFromCurrentState]) {
        own?.alpha = 0
        page?.alpha = 1
      }
    }
  }

  private var closedShift: CGFloat { -(sidebarWidth + 24) }

  /// Slides the drawer in or out from wherever it is, quickly and with no overshoot.
  private func slide(to opening: Bool, width: CGFloat) {
    sliding = true
    slideToken += 1
    let token = slideToken
    if moving {
      handStrip(opening: opening)   // turned round mid-slide
    } else {
      beginMove(opening: opening)
      dim.alpha = opening ? 0 : dimOpen
    }
    // A pull brings the drawer's buttons in with the drawer: the page's own fade out as they come in over them.
    if riding && picture == nil {
      // Let go: the page's buttons are out by the time the drawer's land (opening), or back at once if it goes back in.
      UIView.animate(withDuration: opening ? 0.25 : 0.2, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
        self.stripContainer(in: self.nav.view)?.alpha = opening ? 0 : 1
      }
    }
    let spring = UISpringTimingParameters(mass: 1, stiffness: 420, damping: 2 * 420.0.squareRoot() * 0.98, initialVelocity: .zero)
    let animator = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
    animator.addAnimations {
      self.mover.transform = opening ? .identity : CGAffineTransform(translationX: self.closedShift, y: 0)
      self.holdStrip(shift: opening ? 0 : self.closedShift)
      self.dim.alpha = opening ? self.dimOpen : 0
    }
    animator.addCompletion { [weak self] _ in
      // Only the latest slide settles things (an earlier one, ending in the middle of a later one, must not snap it to rest), and
      // at the width of now (a turn may have changed it on the way).
      guard let self, self.open == opening, token == self.slideToken else { return }
      self.sliding = false
      self.moving = false
      self.pendingHand?.cancel()
      self.pendingHand = nil
      self.picture?.removeFromSuperview()
      self.picture = nil
      self.placeDrawer(width: self.sidebarWidth)
      self.restDrawer(open: opening)
    }
    animator.startAnimation()
  }

  /// The list button on either page: the drawer starts to move at once; only the strip's buttons wait (see `beginMove`).
  func toggle() {
    if wide {
      // (half-folded the list has its screen and stays: the button does nothing)
      guard !pageActive, !folded else { return }
      UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
      setDockedOpen(!dockedOpen, animated: true)
      return
    }
    buttonTap = true
    open ? close() : openDrawer()
    buttonTap = false
  }

  func openDrawer() {
    guard !wide, !open else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    memory.movedList(open: true)
    open = true
    layoutPanes(animated: true)
  }

  func close() {
    view.endEditing(true)
    guard open else { return }
    memory.movedList(open: false)
    open = false
    layoutPanes(animated: true)
  }

  @objc private func dimTapped() { close() }

  /// How much of the drawer shows, 0...1, for its shift.
  private var shown: CGFloat {
    let width = max(sidebarWidth, 1)
    let shift = moving ? shiftNow : 0
    return min(1, max(0, 1 + shift / (width + 24)))
  }

  /// Where the drawer is under the finger (its transform is the animator's while a pull is being scrubbed).
  private var shiftNow: CGFloat = 0
  /// A pull of the real drawer is a paused animation that the finger scrubs: the system makes the drawer's strip buttons when
  /// the drawer is animated, and with a bare transform they were not there until the finger let go.
  private var pullAnimator: UIViewPropertyAnimator?

  private func follow(_ shift: CGFloat) {
    guard moving else { return }
    let clamped = min(0, max(closedShift, shift))
    shiftNow = clamped
    if let a = pullAnimator {
      a.fractionComplete = min(1, max(0, (clamped - closedShift) / -closedShift))
    } else {
      mover.transform = CGAffineTransform(translationX: clamped, y: 0)
    }
    holdStrip(shift: clamped)
    dim.alpha = shown * dimOpen
    if riding, picture == nil {
      // The drawer's buttons come in from the left and the page's, which stand where they land, give way as they get near.
      let near = min(1, max(0, (shown - 0.55) / 0.4))
      stripContainer(in: nav.view)?.alpha = 1 - near
    }
  }

  /// Ends the scrubbed animation where it stands, so that what follows starts from there.
  private func endPull() {
    guard let a = pullAnimator else { return }
    a.stopAnimation(false)
    a.finishAnimation(at: .current)
    pullAnimator = nil
  }

  /// Settles where the finger left it: past half the drawer is out, before half it goes back.
  private func release(velocity: CGFloat) {
    guard dragging else { return }
    dragging = false
    endPull()
    // A hard flick says what is meant, wherever the finger stopped; otherwise it is the half-way mark.
    open = velocity > 350 ? true : velocity < -350 ? false : shown > 0.5
    // What a pull settles on is the person's doing, remembered as the buttons' is (a turn to the wide arrangement keeps it).
    memory.movedList(open: open)
    layoutPanes(animated: true)
  }

  /// A pull from the left edge draws the drawer out, as far as the finger goes.
  @objc private func edgePanned(_ pan: UIScreenEdgePanGestureRecognizer) {
    guard !wide else { dragging = false; return }
    let dx = pan.translation(in: view).x
    switch pan.state {
    case .began:
      guard !open else { return }
      dragging = true
      beginMove(opening: true)
      follow(closedShift)
    case .changed:
      guard dragging else { return }
      follow(closedShift + dx)
    case .ended, .cancelled, .failed:
      release(velocity: pan.velocity(in: view).x)
    default: break
    }
  }

  /// A push to the left on the open drawer takes it back in, as far as the finger goes.
  @objc private func panned(_ pan: UIPanGestureRecognizer) {
    guard !wide else { dragging = false; return }
    let dx = pan.translation(in: view).x
    switch pan.state {
    case .began:
      guard open else { return }
      dragging = true
      beginMove(opening: false)
      follow(0)
    case .changed:
      guard dragging else { return }
      follow(dx)
    case .ended, .cancelled, .failed:
      release(velocity: pan.velocity(in: view).x)
    default: break
    }
  }

  /// The grip's drag takes a touch that begins on the divider (the 24 pt of the grip and 20 beyond it), nowhere else.
  func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if recognizer === touchWatcher { return wide && !pageActive && !folded && touch.location(in: view).x < gripEdge }
    if recognizer === dockSwipe {
      // A hard swipe to the left folds the list: from anywhere but the grip (its own drag takes that).
      let x = touch.location(in: view).x, edge = gripEdge
      return wide && !pageActive && !folded && dockedOpen && !dockBusy && !(x >= edge - 8 && x <= edge + DockGripView.width + 20)
    }
    guard recognizer === dockPan else { return true }
    guard wide, !pageActive, !folded else { return false }
    let x = touch.location(in: view).x, edge = gripEdge
    let inside = x >= edge - 8 && x <= edge + DockGripView.width + 20
    // A touch at its place (and only there) shows it again.
    if inside { grip.wake(hold: dockBusy) }
    return inside
  }

  /// The drawer's list scrolls under the same finger: both see the touch.
  func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
    if a === touchWatcher || b === touchWatcher { return true }
    return a is UIPanGestureRecognizer && !(a is UIScreenEdgePanGestureRecognizer)
  }

  /// The closing push begins only on the open drawer, and mostly sideways: a vertical scroll of the list, or a finger that
  /// wobbles on a button of the strip, is not it. The edge pull begins only over the chat itself (on a pushed page the edge
  /// swipe is the way back).
  func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    // (not while a page is still coming or going: a swipe back then would start a second transition on top of the first)
    if recognizer === nav.interactivePopGestureRecognizer { return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil }
    if recognizer === touchWatcher { return wide && !pageActive }
    if recognizer === dockSwipe {
      guard wide, let pan = recognizer as? UIPanGestureRecognizer else { return false }
      let v = pan.velocity(in: view)
      return abs(v.x) > abs(v.y)
    }
    if recognizer === dockPan {
      guard wide, !pageActive, let pan = recognizer as? UIPanGestureRecognizer else { return false }
      let v = pan.velocity(in: view)
      return abs(v.x) > abs(v.y)
    }
    guard !wide, !sliding else { return false }
    if recognizer is UIScreenEdgePanGestureRecognizer {
      return !open && nav.topViewController === chat && nav.presentedViewController == nil && presentedViewController == nil
    }
    guard let pan = recognizer as? UIPanGestureRecognizer, open else { return false }
    let v = pan.velocity(in: view)
    return abs(v.x) > abs(v.y) * 1.2 && v.x < 0
  }

  private func followTheme() {
    let style: UIUserInterfaceStyle = store.theme == "light" ? .light : store.theme == "dark" ? .dark : .unspecified
    if view.window?.overrideUserInterfaceStyle != style { view.window?.overrideUserInterfaceStyle = style }
  }
}
