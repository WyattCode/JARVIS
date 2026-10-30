import Flutter
import UIKit
import os

/// iPhone Duo layout facts for Dart on `ai.jarvis.app/duo` (+ `duo-events`).
/// Flutter draws its own bars, so the system's vertical-bar layout does not apply to them; Dart needs to know
/// which edge the system strip is on and which regions (fold, camera) must stay free of interactive content.
final class DuoLayoutBridge: NSObject, FlutterStreamHandler {
  private let log = Logger(subsystem: "ai.jarvis.app", category: "layout")
  private var sink: FlutterEventSink?
  private weak var probe: ProbeView?
  private var lastSent: [String: Any]?
  private var observers: [NSObjectProtocol] = []
  private var settle: DispatchWorkItem?

  func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "ai.jarvis.app/duo", binaryMessenger: messenger).setMethodCallHandler {
      [weak self] call, result in
      guard let self, call.method == "snapshot" else { return result(FlutterMethodNotImplemented) }
      self.attachIfNeeded()
      result(self.snapshot())
    }
    FlutterEventChannel(name: "ai.jarvis.app/duo-events", binaryMessenger: messenger).setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    lastSent = nil
    observe()
    attachIfNeeded()
    emit()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    settle?.cancel()
    unobserve()
    return nil
  }

  deinit { unobserve() }

  /// Only while Dart listens. Reduce Transparency is a system setting Flutter cannot read (Dart swaps frosted bars for
  /// solid ones); coming back to the foreground re-checks the regions, which can change while the app is away.
  private func observe() {
    unobserve()
    let center = NotificationCenter.default
    for name in [UIAccessibility.reduceTransparencyStatusDidChangeNotification, UIApplication.didBecomeActiveNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.emit() })
    }
  }

  private func unobserve() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
  }

  private func flutterController() -> FlutterViewController? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        if let controller = window.rootViewController as? FlutterViewController { return controller }
      }
    }
    return nil
  }

  private func flutterView() -> UIView? { flutterController()?.view }

  private var navProbe: UINavigationController?
  private var lastMetrics: (size: CGSize, values: [String: Any])?

  /// A standard, invisible UINavigationController. iOS lays its bar buttons out in the vertical strip by the official
  /// rules, so their frames tell us exactly where system controls sit; our own rail lines up with them. Attached only
  /// once the system reports a vertical bar (i.e. on a foldable), never on ordinary iPhones or iPads.
  private func attachNavProbe() {
    guard navProbe == nil, let controller = flutterController() else { return }
    let content = UIViewController()
    content.view.backgroundColor = .clear
    // A title, so the probe also shows where the system puts a navigation title on this display.
    content.title = "JARVIS"
    content.navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "gearshape"), style: .plain, target: nil, action: nil)
    content.toolbarItems = [
      UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), style: .plain, target: nil, action: nil)
    ]
    let nav = UINavigationController(rootViewController: content)
    nav.setToolbarHidden(false, animated: false)
    controller.addChild(nav)
    nav.view.frame = controller.view.bounds
    nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    nav.view.alpha = 0.001
    nav.view.isUserInteractionEnabled = false
    nav.view.accessibilityElementsHidden = true
    controller.view.addSubview(nav.view)
    nav.didMove(toParent: controller)
    navProbe = nav
  }

  /// Where the system itself puts bar buttons: horizontal center of the strip's controls and the vertical centers of
  /// the first (top) and last (bottom) one, in the Flutter view's coordinates. nil when there is no vertical bar.
  private func systemBarMetrics(host: UIView) -> [String: Any]? {
    guard let nav = navProbe else { return nil }
    // The scene or Flutter view controller was recreated: drop the stale probe so the next layout re-attaches it.
    guard nav.parent != nil, nav.view.superview != nil else {
      navProbe = nil
      return nil
    }
    nav.view.layoutIfNeeded()
    var frames: [CGRect] = []
    var titleCenter: CGFloat?
    func walk(_ view: UIView) {
      if !view.isHidden, String(describing: type(of: view)).hasSuffix("BarButton") {
        let r = view.convert(view.bounds, to: host)
        if r.width > 0, r.height > 0 { frames.append(r) }
      }
      if let label = view as? UILabel, label.text == "JARVIS", !label.isHidden {
        let r = label.convert(label.bounds, to: host)
        if r.height > 0 { titleCenter = r.midY }
      }
      view.subviews.forEach(walk)
    }
    walk(nav.view)
    // The buttons are not always laid out when a report is taken (a layout pass in progress): keep the last good
    // measurement for the same window size instead of reporting nothing, which would make the strip jump.
    guard frames.count >= 2 else { return lastMetrics?.size == host.bounds.size ? lastMetrics?.values : nil }
    let centers = frames.map { $0.midY }
    var metrics: [String: Any] = [
      "cx": frames.map { $0.midX }.reduce(0, +) / CGFloat(frames.count),
      "top": centers.min()!,
      "bottom": centers.max()!,
    ]
    if let titleCenter { metrics["titleCY"] = titleCenter }
    lastMetrics = (host.bounds.size, metrics)
    return metrics
  }

  private func attachIfNeeded() {
    guard probe == nil, let host = flutterView() else { return }
    let view = ProbeView(frame: host.bounds)
    view.onChange = { [weak self] in self?.changed() }
    host.addSubview(view)
    probe = view
  }

  /// A layout, trait or window change: report now, and once more after the transition settles. Half-folding the device
  /// flips a region's `isActive` without necessarily changing this view's size, and the system may update the regions
  /// a beat after the layout pass; the repeat is de-duplicated, so it only sends when something really changed.
  private func changed() {
    emit()
    guard sink != nil else { return }
    settle?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.emit() }
    settle = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  /// The Flutter view is created after the engine; keep trying briefly so the view is ready before Dart listens.
  func start(attempt: Int = 0) {
    attachIfNeeded()
    if probe != nil {
      emit()
    } else if attempt < 20 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.start(attempt: attempt + 1) }
    }
  }

  private func emit() {
    // Nobody is listening: do not walk the probe's view tree for a snapshot nobody receives.
    guard let sink else { return }
    let state = snapshot()
    if let lastSent, NSDictionary(dictionary: lastSent).isEqual(to: state) { return }
    lastSent = state
    log.debug("duo layout \(String(describing: state))")
    sink(state)
  }

  /// All values are in points in the Flutter view's coordinate space (= Flutter logical pixels).
  func snapshot() -> [String: Any] {
    guard let host = flutterView() else {
      return ["edge": "none", "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled]
    }
    var state: [String: Any] = [
      "edge": "none",
      "width": host.bounds.width,
      "height": host.bounds.height,
      "safe": [
        "left": host.safeAreaInsets.left, "top": host.safeAreaInsets.top,
        "right": host.safeAreaInsets.right, "bottom": host.safeAreaInsets.bottom,
      ],
      "layoutMargins": [
        "left": host.layoutMargins.left, "top": host.layoutMargins.top,
        "right": host.layoutMargins.right, "bottom": host.layoutMargins.bottom,
      ],
      "directionalMargins": [
        "leading": host.directionalLayoutMargins.leading, "trailing": host.directionalLayoutMargins.trailing,
      ],
      "regions": [[String: Any]](),
      "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
    ]
    if #available(iOS 27.1, *) {
      switch host.traitCollection.verticalBarEdge {
      case .leading: state["edge"] = host.effectiveUserInterfaceLayoutDirection == .rightToLeft ? "right" : "left"
      case .trailing: state["edge"] = host.effectiveUserInterfaceLayoutDirection == .rightToLeft ? "left" : "right"
      default: state["edge"] = "none"
      }
      var regions: [[String: Any]] = []
      for (name, kind) in [("division", UIView.ReservedRegion.Kind.division), ("occlusion", .occlusion)] {
        for region in host.reservedRegions(kind: kind, options: [.includeInactive]) {
          regions.append([
            "kind": name, "active": region.isActive,
            "x": region.frame.minX, "y": region.frame.minY,
            "w": region.frame.width, "h": region.frame.height,
            "mLeft": region.margins.left, "mTop": region.margins.top,
            "mRight": region.margins.right, "mBottom": region.margins.bottom,
          ])
        }
      }
      state["regions"] = regions
    }
    if state["edge"] as? String != "none" {
      if navProbe == nil {
        // Not inside this layout pass: adding a view controller here would re-enter layout.
        DispatchQueue.main.async { [weak self] in
          self?.attachNavProbe()
          self?.emit()
        }
      } else if let metrics = systemBarMetrics(host: host) {
        state["systemBar"] = metrics
      }
    }
    return state
  }
}

/// Transparent, touch-transparent view pinned over the Flutter view; it only exists to be told about layout changes.
private final class ProbeView: UIView {
  var onChange: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  // Deprecated from iOS 17, but the app still supports iOS 15 and the replacement is not available there.
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    onChange?()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    onChange?()
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    onChange?()
  }

  // A scene or window change (e.g. a new window geometry) without a layout pass of its own.
  override func didMoveToWindow() {
    super.didMoveToWindow()
    onChange?()
  }
}
