import Combine
import UIKit

private let appBackground = UIColor { trait in
  trait.userInterfaceStyle == .dark
    ? UIColor(red: 9 / 255, green: 9 / 255, blue: 11 / 255, alpha: 1)
    : UIColor(red: 249 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1)
}

/// The app's root on the Swift core: signed in shows the chat (`NativeChatApp`), signed out shows the sign-in page, and the
/// store decides which, including when the session ends in the middle of use.
@MainActor
final class NativeAppRootViewController: UIViewController {
  private let store: JarvisStore
  private var bag = Set<AnyCancellable>()
  private var current: UIViewController?
  private var main: UIViewController?
  private var login: LoginViewController?
  private var started = false
  /// What shows while the saved session is read: the reactor alone, which then flies to its place on the next page.
  private let launch = UIView()
  private let launchReactor = ReactorView()
  /// The launch screen the system shows (LaunchReactor, in the launch storyboard) is a picture of this same reactor, in the same place and size, so that the
  /// hand-over from the system's screen to the app's is not seen, and so that what flies is one thing from the first frame to the
  /// landing: the reactor, which comes alive and goes where the page keeps its own.
  /// A light page gets a second reactor in the light colours, faded in over the dark one on the way, so that the one that lands is
  /// not a pale ring on a pale page.
  private var launchTint: ReactorView?
  private let backdrop = UIView()
  /// The flight is in progress, or over: the icon stays in the middle of the window until it starts.
  private var flightStarted = false
  private var flightDone = false
  private var flightAnimators: [UIViewPropertyAnimator] = []
  private var flightTimers: [DispatchWorkItem] = []
  /// The reactor is drawn this big and shown smaller at the start: it grows to its landing size by its transform (a bitmap drawn
  /// at the small size and then stretched up would be soft).
  private static let reactorSide: CGFloat = 264
  private static let iconSide: CGFloat = 176
  private var launching = true

  /// Every way up, the upside-down portrait too: on an iPhone the system's own answer leaves that one out (and the screen then did
  /// not turn to it, with a foldable's outer display turned all the way round).
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

  init(store: JarvisStore) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
    store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.follow() }
    }.store(in: &bag)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  /// The writes of the store are held back a moment (and a streamed reply keeps pushing them back): leaving the app writes what is
  /// waiting at once, in the time the system gives a task that is ending, so that being ended in the background loses nothing.
  private func saveForLeaving() {
    var task = UIBackgroundTaskIdentifier.invalid
    task = UIApplication.shared.beginBackgroundTask(withName: "jarvis.save") {
      UIApplication.shared.endBackgroundTask(task)
      task = .invalid
    }
    Task { [store] in
      await store.saveIfDirty()
      if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = appBackground
    // Only when the app really goes to the background (not for the Control Center, a permission box or Face ID, which also make it
    // inactive): the save then is a whole one, and the app is not ended before it has gone to the background.
    NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.saveForLeaving() }
    }
    // Going inactive may be the end too (the app swiped away from the app switcher): what waits to be written goes now, cheaply.
    NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let store = self?.store else { return }
        Task { await store.flushPending() }
      }
    }
    // The original's launch screen is always dark (LaunchReactor), whatever the theme the app then opens in.
    // The backdrop is its own view: it fades by its alpha, and what it fades over is the page, never a colour mixed on the way.
    backdrop.backgroundColor = UIColor(red: 9 / 255, green: 9 / 255, blue: 11 / 255, alpha: 1)
    backdrop.frame = view.bounds
    backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    launch.backgroundColor = .clear
    launch.insertSubview(backdrop, at: 0)
    launch.frame = view.bounds
    launch.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // The welcome page's figure waits until the launch reactor has landed on it.
    LaunchFigure.shared.hidden = true
    prepareReactors(light: false)
    launchReactor.alpha = 1
    view.addSubview(launch)
    Task {
      await store.initialize()
      started = true
      follow()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The reactor keeps the middle of the window (a turn moves it) until the flight begins.
    if !flightStarted { launchReactor.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY) }
  }

  /// A turn in the middle of the flight: it ends where it was going (its place was worked out for the old shape).
  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    if flightStarted, !flightDone { finishFlight(immediately: true) }
  }

  /// A session that is signed in, or one that only lost the network (the saved session is kept and retried), shows the chat.
  private func followTheme() {
    // Only what was really read: before that the store holds its defaults, which are not the person's choice.
    guard store.initialized else { return }
    UserDefaults.standard.set(store.theme, forKey: "jarvis.theme")
    let style: UIUserInterfaceStyle = store.theme == "light" ? .light : store.theme == "dark" ? .dark : .unspecified
    if view.window?.overrideUserInterfaceStyle != style { view.window?.overrideUserInterfaceStyle = style }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    followTheme()
  }

  private func follow() {
    followTheme()
    guard store.initialized else { return }
    // A saved session counts as signed in from the first moment: until the connection answers, the store is neither "authenticated"
    // nor "offline", and the sign-in page must not show for that time.
    let signedIn = store.authenticated || store.offlineSession || store.api.cookie != nil
    if signedIn {
      LoginViewController.autoPrompted = true
      if main == nil { main = NativeChatApp.makeRoot(store: store) }
      show(main!)
      login = nil
    } else {
      main = nil
      if login == nil { login = LoginViewController(store: store) }
      show(login!)
    }
    if launching {
      launching = false
      land()
    }
  }

  /// The launch icon flies to where the next page keeps its reactor, and on the way turns into it: the bold icon of the launch
  /// screen fades into the living reactor while the whole moves and grows on one soft curve (quick away, long settling), the
  /// dark screen lifts off the page, and the page's own reactor comes up under the one that flew before that one is let go. The
  /// place is the sign-in page's emblem or, with the chat as the first page and no messages yet, the welcome page's figure.
  /// With Reduce Motion it is a plain dissolve.
  private func land() {
    view.bringSubviewToFront(launch)
    guard !UIAccessibility.isReduceMotionEnabled else {
      reveal()
      UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut, animations: { self.launch.alpha = 0 }) { _ in
        self.launch.removeFromSuperview()
      }
      flightStarted = true
      flightDone = true
      return
    }
    login?.setEmblem(hidden: true)
    view.layoutIfNeeded()
    // Where the page keeps its reactor, in the launch layer's own coordinates. The welcome page reports its figure after its first
    // layout pass, and may move it again in the next one: the flight starts when two looks in a row agree (never later than a third
    // of a second), so that it starts on the page's real place and, on a slow phone, not with the page still being built under it.
    // A page with a conversation open, or a window too short for the figure, has none to wait for.
    func place() -> CGRect? {
      if let login { return login.emblemFrame(in: launch) }
      guard let figure = LaunchLanding.figure else { return nil }
      return launch.convert(figure, from: nil)
    }
    let expectsFigure = login != nil || (store.current.messages.isEmpty && view.bounds.height >= 520)
    let began = CACurrentMediaTime()
    var last: CGRect?
    func start() {
      let now = place()
      if expectsFigure, CACurrentMediaTime() - began < 0.33 {
        if let now, let last, abs(now.midX - last.midX) < 0.5, abs(now.midY - last.midY) < 0.5, abs(now.width - last.width) < 0.5 {
          return fly(to: now)
        }
        last = now
        return DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { start() }
      }
      fly(to: now)
    }
    DispatchQueue.main.async { start() }
  }

  /// The page's own reactor (and the sign-in emblem) shows.
  private func reveal() {
    login?.setEmblem(hidden: false)
    LaunchFigure.shared.hidden = false
  }

  private func fly(to target: CGRect?) {
    flightStarted = true
    launch.isUserInteractionEnabled = false
    let light = view.traitCollection.userInterfaceStyle == .light
    if light { addTint() }
    let moving = target != nil
    let duration = moving ? 0.88 : 0.6
    let base = CGAffineTransform(scaleX: Self.iconSide / Self.reactorSide, y: Self.iconSide / Self.reactorSide)
    let centre = launchReactor.center
    var reactorEnd = base.scaledBy(x: 1.25, y: 1.25)
    if let target {
      // The ring's radius is what has to match the page's reactor (it is the smaller of 44% of the width and 46% of the height of
      // the box the page draws it in, which is not a square on the welcome page).
      let radius = min(target.width * 0.44, target.height * 0.46)
      let move = CGAffineTransform(translationX: target.midX - centre.x, y: target.midY - centre.y)
      reactorEnd = move.scaledBy(x: radius / (0.44 * Self.reactorSide), y: radius / (0.44 * Self.reactorSide))
    }
    let curve = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.33, y: 0), controlPoint2: CGPoint(x: 0.3, y: 1))
    let flight = UIViewPropertyAnimator(duration: duration, timingParameters: curve)
    flight.addAnimations {
      self.launchReactor.transform = reactorEnd
      self.launchTint?.transform = reactorEnd
    }
    flight.addCompletion { _ in self.finishFlight(immediately: false) }
    func run(_ length: Double, after delay: Double, _ curve: UIView.AnimationCurve = .easeInOut, _ animations: @escaping () -> Void) {
      let a = UIViewPropertyAnimator(duration: length, curve: curve, animations: animations)
      flightAnimators.append(a)
      a.startAnimation(afterDelay: delay)
    }
    flightAnimators.append(flight)
    // The dark screen lifts off the page. On a flight it waits until the reactor is well clear of the middle (where the page keeps
    // its title) and goes on until the landing: the page comes up around the reactor while it settles, so that nothing else
    // happens in the last moment, when the eye is on the landing.
    if moving {
      run(duration * 0.6, after: duration * 0.3) { self.backdrop.alpha = 0 }
      // The page comes up as it appears: a small rise into its place over the same stretch, ending exactly in place (the
      // reactor lands on the page's own spot, and the one that flew is taken away at that moment).
      if let page = current?.view {
        page.transform = CGAffineTransform(translationX: 0, y: 14)
        run(duration * 0.6, after: duration * 0.3, .easeOut) { page.transform = .identity }
      }
    }
    else { run(duration * 0.6, after: duration * 0.1) { self.backdrop.alpha = 0 } }
    if light { run(duration * 0.45, after: duration * 0.35) { self.launchTint?.alpha = 1 } }
    flight.startAnimation()
    if moving {
      // The page's reactor turns in step with the one that flies (it is not seen yet). Nothing is ever shown twice: the two are not
      // on screen together for a moment (two reactors over each other add up and the middle flashes bright), the one that flew is
      // taken away in the very turn in which the page's own is shown, when the flight ends exactly on its place.
      LaunchFigure.shared.pageReactor?.adoptClock(from: launchReactor)
      // A flight that never reports its end (the app sent to the background and brought back in the middle of it) must not leave the
      // launch layer over the page for good.
      let guardrail = DispatchWorkItem { [weak self] in self?.finishFlight(immediately: true) }
      flightTimers.append(guardrail)
      DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.7, execute: guardrail)
    } else {
      reveal()
      run(duration * 0.7, after: 0, .easeIn) {
        self.launchReactor.alpha = 0
        self.launchTint?.alpha = 0
      }
    }
  }

  /// The reactor of the launch layer, drawn big and shown at the launch picture's size (a reactor drawn at that size and then
  /// stretched up to its landing size would be soft).
  private func prepareReactors(light: Bool) {
    launchReactor.isUserInteractionEnabled = false
    launchReactor.isAccessibilityElement = false
    launchReactor.apply(["mode": "idle", "dark": true], animated: false)
    launchReactor.transform = .identity
    launchReactor.frame = CGRect(x: 0, y: 0, width: Self.reactorSide, height: Self.reactorSide)
    launchReactor.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    launchReactor.transform = CGAffineTransform(scaleX: Self.iconSide / Self.reactorSide, y: Self.iconSide / Self.reactorSide)
    if launchReactor.superview == nil { launch.addSubview(launchReactor) }
  }

  /// A light page gets a second reactor in the light colours, in the same place, faded in over the dark one on the way.
  private func addTint() {
    let tint = ReactorView()
    tint.isUserInteractionEnabled = false
    tint.isAccessibilityElement = false
    tint.apply(["mode": "idle", "dark": false], animated: false)
    tint.frame = launchReactor.bounds
    tint.center = launchReactor.center
    tint.transform = launchReactor.transform
    tint.alpha = 0
    launch.insertSubview(tint, aboveSubview: launchReactor)
    launchTint = tint
  }

  /// The flight is over (or cut short by a turn): the page's reactor shows, the rest of the launch layer goes. What is still faintly
  /// there fades in a moment; nothing is cut.
  private func finishFlight(immediately: Bool) {
    guard !flightDone else { return }
    flightDone = true
    flightTimers.forEach { $0.cancel() }
    flightTimers = []
    if immediately {
      flightAnimators.forEach { a in
        a.stopAnimation(false)
        if a.state == .stopped { a.finishAnimation(at: .end) }
      }
    }
    flightAnimators = []
    if !immediately { LaunchFigure.shared.pageReactor?.adoptClock(from: launchReactor) }
    LaunchFigure.shared.instant = true
    reveal()
    current?.view.transform = .identity
    launch.removeFromSuperview()
  }

  /// The session ended with a page over the chat (a call, the settings, a sheet) or a dialog up: they go, and the answer they were
  /// waiting for is "no", so that the sign-in page is not shown under them (nor their buttons acting on a signed-out store).
  private func clearOverlays() {
    FilesService.shared.cancelAll()
    GlassRenameDialog.dismissShowing()
    GlassConfirmDialog.dismissShowing()
    GlassNoticeDialog.dismissShowing()
    func dismiss(_ controller: UIViewController) {
      controller.children.forEach(dismiss)
      controller.presentedViewController?.dismiss(animated: false)
    }
    dismiss(self)
  }

  private func show(_ next: UIViewController) {
    guard next !== current else { return }
    if next is LoginViewController, current != nil { clearOverlays() }
    let previous = current
    current = next
    addChild(next)
    next.view.frame = view.bounds
    next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    if let previous {
      transition(from: previous, to: next, duration: 0.25, options: .transitionCrossDissolve, animations: nil) { _ in
        previous.removeFromParent()
        next.didMove(toParent: self)
      }
    } else {
      view.addSubview(next.view)
      next.didMove(toParent: self)
    }
  }
}

/// Where the welcome page keeps its figure, in window coordinates: the launch reactor lands there.
@MainActor
enum LaunchLanding { static var figure: CGRect? }

/// The sign-in page: the emblem, the form (autofill, keyboard) and the store's error and connecting state.
///
/// It does not scroll. The form stands on the keyboard (the keyboard layout guide), the emblem gives way to it as the keyboard
/// comes up (it shrinks, then fades out when there is no room for it), and a window too short for the form's heading drops the
/// heading. A tap on the page puts the keyboard away. Wide windows (a foldable's outer display on its side, a tablet) put the
/// emblem beside the form.
@MainActor
final class LoginViewController: UIViewController, UIGestureRecognizerDelegate {
  private let store: JarvisStore
  private let form: NativeLoginForm
  private let emblem = ReactorView()
  /// The emblem's room: it is sized by the layout (it gives way to the keyboard); the emblem fills it.
  private let emblemRoom = UIView()
  private var bag = Set<AnyCancellable>()
  private let background = CAGradientLayer()
  private let brandRow = UIStackView()
  private let column = UIView()
  private var columnTop: NSLayoutConstraint!
  private var keyboardUp = false
  private var brandAxis: NSLayoutConstraint!
  private var axisProbe: UINavigationController?
  private var axis: CGFloat = 0
  private var columnBottom: NSLayoutConstraint!
  private var stacked: [NSLayoutConstraint] = []
  private var beside: [NSLayoutConstraint] = []
  private var besideMode: Bool?

  init(store: JarvisStore) {
    self.store = store
    form = NativeLoginForm(frame: CGRect(x: 0, y: 0, width: 360, height: 300), args: [:])
    super.init(nibName: nil, bundle: nil)
    form.emit = { [weak self] name, value in
      switch name {
      case "submit":
        guard let a = value as? [String: String] else { return }
        self?.signIn(username: a["username"] ?? "", password: a["password"] ?? "")
      case "biometric": self?.signInWithBiometrics()
      case "edited":
        self?.notice = nil
        self?.store.clearSignInMessages()
      default: break
      }
    }
    store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.refresh() }
    }.store(in: &bag)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: LoginViewController, _: UITraitCollection) in
      view.emblem.apply(["dark": view.traitCollection.userInterfaceStyle != .light], animated: false)
      view.paintBackground()
    }
    view.backgroundColor = appBackground
    // The original's diagonal wash behind the sign-in page.
    background.startPoint = CGPoint(x: 0, y: 0)
    background.endPoint = CGPoint(x: 1, y: 1)
    background.locations = [0, 0.58, 1]
    view.layer.addSublayer(background)
    paintBackground()
    // A tap on the page (not on a field or a button) puts the keyboard away.
    let away = UITapGestureRecognizer(target: self, action: #selector(tappedAway))
    away.cancelsTouchesInView = false
    away.delegate = self
    view.addGestureRecognizer(away)
    // The brand at the top left, as the original's sign-in page had it.
    let mark = JarvisMarkView()
    mark.translatesAutoresizingMaskIntoConstraints = false
    let brand = UILabel()
    brand.text = "JARVIS"
    brand.font = .systemFont(ofSize: 20, weight: .semibold)
    brand.textColor = Palette.onSurface
    brandRow.addArrangedSubview(mark)
    brandRow.addArrangedSubview(brand)
    brandRow.spacing = 10
    brandRow.alignment = .center
    brandRow.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(brandRow)
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      mark.widthAnchor.constraint(equalToConstant: 30), mark.heightAnchor.constraint(equalToConstant: 30),
      brandRow.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
    ])
    // Where the brand row stands: its middle on the line where the system puts a navigation title on this display (the chat's
    // header and the list's brand row are on it), 27 pt below the top where there is no such bar. See `placeBrand`.
    brandAxis = brandRow.centerYAnchor.constraint(equalTo: view.topAnchor, constant: 27)
    brandAxis.isActive = true

    emblem.translatesAutoresizingMaskIntoConstraints = false
    emblem.isAccessibilityElement = false
    emblem.apply(["mode": "idle", "dark": traitCollection.userInterfaceStyle != .light], animated: false)
    emblemRoom.translatesAutoresizingMaskIntoConstraints = false
    emblemRoom.isAccessibilityElement = false
    emblemRoom.addSubview(emblem)
    let box = form.view()
    box.translatesAutoresizingMaskIntoConstraints = false
    column.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(column)
    column.addSubview(emblemRoom)
    column.addSubview(box)
    NSLayoutConstraint.activate([
      emblem.leadingAnchor.constraint(equalTo: emblemRoom.leadingAnchor), emblem.trailingAnchor.constraint(equalTo: emblemRoom.trailingAnchor),
      emblem.topAnchor.constraint(equalTo: emblemRoom.topAnchor), emblem.bottomAnchor.constraint(equalTo: emblemRoom.bottomAnchor),
    ])

    // The column is everything between the brand row and the keyboard (or the bottom of the safe area, with no keyboard).
    columnTop = column.topAnchor.constraint(equalTo: guide.topAnchor, constant: 56)
    // The column stands on the window's bottom, lifted by what `keyboardFrameChanged` works out (not on the system's keyboard guide:
    // see there).
    columnBottom = column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -50)
    NSLayoutConstraint.activate([columnTop, columnBottom, column.centerXAnchor.constraint(equalTo: guide.centerXAnchor)])
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)

    // Stacked: the emblem above the form. The form keeps its height and stands on the keyboard; the emblem takes what is left
    // (at most 260 pt, a square), between two gaps that share any extra room (the lower one the larger).
    let above = UILayoutGuide(), between = UILayoutGuide()
    column.addLayoutGuide(above)
    column.addLayoutGuide(between)
    let width = column.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
    let fill = column.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -48)
    fill.priority = .defaultHigh
    let preferred = emblemRoom.heightAnchor.constraint(equalToConstant: 260)
    preferred.priority = UILayoutPriority(500)
    let share = above.heightAnchor.constraint(equalTo: between.heightAnchor, multiplier: 0.6)
    share.priority = UILayoutPriority(400)
    stacked = [
      width, fill,
      above.topAnchor.constraint(equalTo: column.topAnchor), above.heightAnchor.constraint(greaterThanOrEqualToConstant: 4), share,
      emblemRoom.topAnchor.constraint(equalTo: above.bottomAnchor),
      emblemRoom.centerXAnchor.constraint(equalTo: column.centerXAnchor),
      emblemRoom.widthAnchor.constraint(equalTo: emblemRoom.heightAnchor),
      emblemRoom.heightAnchor.constraint(lessThanOrEqualToConstant: 260),
      emblemRoom.heightAnchor.constraint(greaterThanOrEqualToConstant: 0), preferred,
      between.topAnchor.constraint(equalTo: emblemRoom.bottomAnchor), between.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
      box.topAnchor.constraint(equalTo: between.bottomAnchor),
      box.leadingAnchor.constraint(equalTo: column.leadingAnchor), box.trailingAnchor.constraint(equalTo: column.trailingAnchor),
      box.bottomAnchor.constraint(equalTo: column.bottomAnchor),
    ]

    // Beside: the emblem on the left, the form on the right, both in the middle of the column's height.
    let wideColumn = column.widthAnchor.constraint(lessThanOrEqualToConstant: 760)
    let wideFill = column.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -64)
    wideFill.priority = .defaultHigh
    let side = emblemRoom.widthAnchor.constraint(equalTo: column.widthAnchor, multiplier: 0.4)
    side.priority = UILayoutPriority(600)
    beside = [
      wideColumn, wideFill,
      emblemRoom.leadingAnchor.constraint(equalTo: column.leadingAnchor), emblemRoom.centerYAnchor.constraint(equalTo: column.centerYAnchor),
      emblemRoom.widthAnchor.constraint(equalTo: emblemRoom.heightAnchor), side,
      emblemRoom.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
      emblemRoom.heightAnchor.constraint(lessThanOrEqualTo: column.heightAnchor),
      box.trailingAnchor.constraint(equalTo: column.trailingAnchor), box.centerYAnchor.constraint(equalTo: column.centerYAnchor),
      box.widthAnchor.constraint(equalTo: column.widthAnchor, multiplier: 0.5),
      box.topAnchor.constraint(greaterThanOrEqualTo: column.topAnchor), box.bottomAnchor.constraint(lessThanOrEqualTo: column.bottomAnchor),
    ]
    arrange()
    refresh()
  }

  private var pendingHide: DispatchWorkItem?
  /// How far up from the bottom of the window the keyboard reaches: the most it has reached since it came up (`liftHeld`, what the
  /// page stands on) and the latest. The two fields' keyboards differ in height (the password suggestions above the keys), and
  /// following each exactly moved the whole page at every change of field; this way it moves only when the keyboard grows.
  private var liftHeld: CGFloat = 0
  private var liftSize: CGSize = .zero

  @objc private func keyboardFrameChanged(_ note: Notification) {
    guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
      let space = view.window?.screen.coordinateSpace
    else { return }
    let lift = max(0, view.bounds.maxY - view.convert(end, from: space).minY)
    // Gone (or only a hardware keyboard's bar): the same as a hide.
    guard lift > 80 else { return scheduleHide(note) }
    pendingHide?.cancel()
    pendingHide = nil
    // A turn of the device is a new session: the keyboard has another height.
    if !keyboardUp || view.bounds.size != liftSize { liftHeld = lift } else { liftHeld = max(liftHeld, lift) }
    liftSize = view.bounds.size
    apply(up: true, note: note)
  }

  @objc private func keyboardWillHide(_ note: Notification) { scheduleHide(note) }

  /// Going from one field to the other the system may say the keyboard is going and then that it is coming: the page would go
  /// through the keyboard-down layout and back (the emblem and the heading flashing). A hide is therefore held back a moment, and
  /// dropped if the keyboard comes again in that time.
  private func scheduleHide(_ note: Notification) {
    guard keyboardUp else { return }
    pendingHide?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingHide = nil
      self.liftHeld = 0
      self.apply(up: false, note: note)
    }
    pendingHide = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
  }

  private var wantedBottom: CGFloat { -(max(keyboardUp ? liftHeld : 0, view.safeAreaInsets.bottom) + 16) }

  /// The keyboard is up or down, and as high as it is held: the form's gaps close up and the emblem takes what room is left.
  private func apply(up: Bool, note: Notification) {
    let bottom: CGFloat = -(max(up ? liftHeld : 0, view.safeAreaInsets.bottom) + 16)
    guard up != keyboardUp || bottom != columnBottom.constant else { return }
    keyboardUp = up
    form.setKeyboard(up)
    columnBottom.constant = bottom
    view.setNeedsLayout()
    // The keyboard's own duration and curve, so that the page and the keys move as one.
    let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7
    let options: UIView.AnimationOptions = [UIView.AnimationOptions(rawValue: UInt(curve) << 16), .beginFromCurrentState]
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration, delay: 0, options: options) {
      self.view.layoutIfNeeded()
    }
    // The notice can come while a layout pass is under way (a field gives up the focus inside one), and then the call above does
    // nothing: one more pass is asked for after it, so that the page always ends in the state the keyboard is in.
    DispatchQueue.main.async { [weak self] in
      self?.view.setNeedsLayout()
      self?.view.layoutIfNeeded()
    }
  }

  /// Wide and not tall: side by side (a foldable's outer display on its side, a tablet). Returns whether the arrangement changed.
  @discardableResult
  private func arrange() -> Bool {
    let size = view.bounds.size
    let sideways = size.width >= 520 && size.width > size.height * 1.2
    guard sideways != besideMode else { return false }
    besideMode = sideways
    NSLayoutConstraint.deactivate(sideways ? stacked : beside)
    NSLayoutConstraint.activate(sideways ? beside : stacked)
    return true
  }


  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    background.frame = view.bounds
    // The column's floor follows the safe area (a turn of the device changes it) when no keyboard holds it up.
    if columnBottom.constant != wantedBottom { columnBottom.constant = wantedBottom }
    // What is decided here changes the layout (the arrangement, the form's heading), and a pass that is under way does not
    // always come round again (it did not inside the keyboard's own animation: the emblem stayed at the size it had with the
    // keyboard up): so it is laid out again at once, before the emblem's fade is worked out from the size it has.
    var again = arrange()
    let width = min(column.bounds.width, besideMode == true ? column.bounds.width * 0.5 : 420)
    let need = form.fullHeight(width: max(width, 1)) + (besideMode == true ? 0 : 20)
    // With the keyboard up the emblem stays, as large as the room left by the form allows. The form's heading gives way to it when
    // it would leave the emblem too small to be worth it (a short window); with no keyboard the heading goes only when the form
    // does not fit at all.
    let stackedMode = besideMode != true
    let smallest: CGFloat = 110
    // With a little slack the other way once it is down (the two fields' keyboards differ in height by a few points, and a limit
    // with none made the heading come and go as the focus moved between them).
    let slack: CGFloat = form.isTight ? 40 : 0
    let short = column.bounds.height > 0
      && (keyboardUp && stackedMode ? column.bounds.height - need < smallest + slack : column.bounds.height < need + slack / 2)
    if form.setTight(short) { again = true }
    if again {
      view.setNeedsLayout()
      view.layoutIfNeeded()
    }
    placeBrand()
    // The emblem fades out as its room gets small. Worked out from the column (which is laid out by now) and the form, not read
    // from the emblem's own frame: that is not laid out yet when this runs, and the stale size once left it hidden.
    let room = stackedMode ? column.bounds.height - form.currentHeight(width: max(width, 1)) - 20 : column.bounds.height
    emblemRoom.alpha = min(1, max(0, (min(room, 260) - 60) / 50))
  }

  private func paintBackground() {
    let dark = traitCollection.userInterfaceStyle != .light
    let hex: [UInt32] = dark ? [0x09090B, 0x111113, 0x0B0B0D] : [0xE8F4F7, 0xF6F9F7, 0xF4EFE5]
    background.colors = hex.map { UIColor(red: CGFloat($0 >> 16 & 255) / 255, green: CGFloat($0 >> 8 & 255) / 255, blue: CGFloat($0 & 255) / 255, alpha: 1).cgColor }
  }

  /// A standard, invisible navigation controller with a title: iOS lays its bar out by its own rules for this display (beside a
  /// vertical strip the title is a good way down from the top), so the title's middle is where the page's header line is.
  private func attachAxisProbe() {
    guard hasVerticalBar(traitCollection) else { return }
    let content = UIViewController()
    content.view.backgroundColor = .clear
    content.title = "JARVIS"
    let nav = UINavigationController(rootViewController: content)
    addChild(nav)
    nav.view.frame = view.bounds
    nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    nav.view.alpha = 0.001
    nav.view.isUserInteractionEnabled = false
    nav.view.accessibilityElementsHidden = true
    view.insertSubview(nav.view, at: 0)
    nav.didMove(toParent: self)
    axisProbe = nav
  }

  private func placeBrand() {
    // Without a vertical strip: on a phone the status bar runs along the top (the time at the left, where the brand is), so the brand
    // row stands below it; on the inner display held upright the system's cluster is at the right and the row stays near the top.
    if !hasVerticalBar(traitCollection) {
      let top = view.safeAreaInsets.top
      let want: CGFloat = top > 24 && !isInnerDisplayUpright(view.window?.bounds.size ?? view.bounds.size) ? top + 16 : 27
      if abs(want - axis) > 0.5 {
        axis = want
        brandAxis.constant = want
        view.layoutIfNeeded()
      }
      return
    }
    // The display's traits are known only once the page is in a window.
    if axisProbe == nil, view.window != nil { attachAxisProbe() }
    guard let nav = axisProbe else { return }
    nav.view.layoutIfNeeded()
    var found: CGFloat?
    func walk(_ v: UIView) {
      if let label = v as? UILabel, label.text == "JARVIS", !label.isHidden, label.bounds.height > 0 {
        found = label.convert(label.bounds, to: view).midY
      }
      v.subviews.forEach(walk)
    }
    walk(nav.view)
    guard let found, abs(found - axis) > 0.5 else { return }
    axis = found
    brandAxis.constant = found
    columnTop.constant = max(56, found + 15 + 10)
    view.layoutIfNeeded()
  }

  @objc private func tappedAway() {
    form.handle("dismiss", nil)
  }

  func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    // Not on a field or a button (or anything inside one): those take the touch themselves.
    var hit = touch.view
    while let v = hit {
      if v is UIControl || v is UITextField { return false }
      hit = v.superview
    }
    return true
  }

  // MARK: Passwords and biometrics

  /// Said in the form's line under the title when a Face ID / Touch ID sign-in cannot go on (until the next try).
  private var notice: String?

  /// What is kept for Face ID or Touch ID after a sign-in with the typed password. Judged by whether the server took the password,
  /// not by what `login` returns: that says whether the models were fetched too, and a slow connection could spoil that after a
  /// good sign-in, and then nothing was kept and nothing was asked (what a phone showed).
  private func signIn(username: String, password: String) {
    let window = view.window
    notice = nil
    Task { [store] in
      // Whether the server took the password, not whether the connection held after it.
      let outcome = await store.signIn(username, password)
      guard outcome == .connected || outcome == .accepted, BiometricLogin.available else { return }
      let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
      let kind = BiometricLogin.name
      @MainActor func failed(_ window: UIWindow) {
        GlassConfirmDialog.show(
          title: "未能启用 \(kind)", lines: ["钥匙串没有保存成功（错误 \(BiometricLogin.lastStatus)）。请确认这台设备已设置锁屏密码并登记了\(kind)。"],
          cancel: "好", confirm: "重试", in: window
        ) { again in
          if again, !BiometricLogin.save(name, password) { failed(window) }
        }
      }
      // Kept already (the password may have changed), or turned on in the settings and waiting for this: kept now, with no question.
      if BiometricLogin.savedUsername != nil || BiometricLogin.wanted {
        if !BiometricLogin.save(name, password), let window {
          try? await Task.sleep(nanoseconds: 700_000_000)
          failed(window)
        }
        return
      }
      guard !BiometricLogin.declined, let window else { return }
      // The page is changing to the chat as this comes up: the offer waits for it.
      try? await Task.sleep(nanoseconds: 700_000_000)
      GlassConfirmDialog.show(
        title: "使用 \(kind) 登录？", lines: ["下次打开 JARVIS，可以用 \(kind) 直接登录。", "密码只保存在本机钥匙串里，必须通过 \(kind) 才能读取。"],
        cancel: "暂不", confirm: "启用", in: window,
        // A touch beside the card, or the VoiceOver escape, is "not now": only the button "暂不" is a no that is remembered.
        dismissed: {}
      ) { confirmed in
        guard confirmed else { return BiometricLogin.declined = true }
        if !BiometricLogin.save(name, password) { failed(window) }
      }
    }
  }

  private var biometricBusy = false

  /// The system's Face ID or Touch ID prompt, then the kept password signs in. One at a time (the prompt that comes up as the page
  /// opens and the button could each start one); what went wrong is said; a password the server refuses is forgotten.
  private func signInWithBiometrics() {
    guard !store.connecting, !biometricBusy else { return }
    biometricBusy = true
    notice = nil
    Task { [store, weak self] in
      let kind = BiometricLogin.name
      let kept = await BiometricLogin.load(reason: "登录 JARVIS")
      switch kept {
      case .found(let username, let password):
        let outcome = await store.signIn(username, password)
        // Forgotten only when the server refused it: a server that is down, or a slow connection, says nothing about the password.
        if outcome == .rejected {
          BiometricLogin.remove()
          self?.notice = "保存的密码已不能登录，请输入密码登录一次，再重新启用 \(kind)。"
        }
      case .cancelled: break
      case .invalidated:
        // Forgotten here, on the main thread (the page asks again at once). Turned on before, so the next sign-in with the password
        // keeps it again without a question.
        BiometricLogin.remove()
        BiometricLogin.wanted = true
        self?.notice = "\(kind) 的录入有变化，保存的密码已失效。请输入密码登录一次，会自动重新启用。"
      case .failed:
        self?.notice = "\(kind) 验证没有通过。可以再试一次，或输入密码登录。"
      }
      self?.biometricBusy = false
      self?.refresh()
    }
  }

  /// Face ID is asked for once as the app opens, and only if the app opens on the sign-in page: `NativeAppRootViewController` sets this when it
  /// opens on the chat, so that signing out by hand does not bring the prompt up (and sign straight back in).
  static var autoPrompted = false

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !Self.autoPrompted else { return }
    Self.autoPrompted = true
    guard BiometricLogin.available, BiometricLogin.savedUsername != nil else { return }
    autoPrompt(attempt: 0)
  }

  /// Asked for once the page is settled: the app is the one in front, the page is on the screen, and nothing has been typed. If it is
  /// not so yet, it is looked at again a little later (a few times), where a prompt fired blindly could come up under a launch
  /// animation or over a password half typed, fail, and never be tried again.
  private func autoPrompt(attempt: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.9 : 0.8)) { [weak self] in
      guard let self, self.view.window != nil else { return }
      if UIApplication.shared.applicationState != .active || self.form.isEditing {
        if attempt < 4 { self.autoPrompt(attempt: attempt + 1) }
        return
      }
      self.signInWithBiometrics()
    }
  }

  /// Where the emblem stands, in another view's coordinates (the launch reactor flies there).
  func emblemFrame(in other: UIView) -> CGRect? {
    guard isViewLoaded else { return nil }
    view.layoutIfNeeded()
    return emblemRoom.superview?.convert(emblemRoom.frame, to: other)
  }

  func setEmblem(hidden: Bool) { emblem.alpha = hidden ? 0 : 1 }

  private func refresh() {
    guard isViewLoaded else { return }
    var state: [String: Any] = ["connecting": store.connecting, "compact": view.bounds.height < 520]
    // What this page has to say about Face ID comes first: a refused sign-in has just set the store's own error, and a session that
    // ran out leaves a connection message, and either would hide it.
    state["error"] = notice ?? store.error ?? store.connectionError
    state["biometric"] = BiometricLogin.available && BiometricLogin.savedUsername != nil ? BiometricLogin.name : NSNull()
    form.handle("update", state)
  }
}

/// The release entry: the real service and the encrypted vault.
@MainActor
enum NativeApp {
  static let server = URL(string: "https://jarvis.example.com")!
  static func makeStore() throws -> JarvisStore {
    let root = (try? FileVault.applicationSupport()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("Jarvis")
    return JarvisStore(api: try JarvisAPI(base: server), vault: FileVault(root: root))
  }

  static func makeRoot() -> UIViewController? {
    guard let store = try? makeStore() else { return nil }
    return NativeAppRootViewController(store: store)
  }
}
