import Flutter
import UIKit

/// The iPhone Duo vertical bar strip as real system UI: Liquid Glass buttons with SF Symbols, embedded in Flutter.
/// Flutter draws the rest of the app, so the system cannot move Flutter's own bars into the strip; this view is the
/// strip's content. Layout: `top` group from the top, `bottom` group from the bottom, overflow items in a system menu
/// that follows the top group.
///
/// creationParams (and later `update` calls): `dark` Bool; `top`, `bottom`, `overflow`: [{id, symbol, label, destructive?}].
/// creationParams also carry the starting `lift` (later ones come as `lift` calls).
/// The view is long-lived: when the set of controls changes (keyboard up/down) the buttons glide to their new places
/// and fade instead of the whole strip being replaced.
/// Taps are reported on `ai.jarvis.app/duo-rail/<viewId>` as `tap` with the item id.
final class DuoRailFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    DuoRailView(frame: frame, viewId: viewId, args: args as? [String: Any] ?? [:], messenger: messenger)
  }
}

private final class RailRootView: UIView {
  var onLayout: (() -> Void)?
  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }
}

final class DuoRailView: NSObject, FlutterPlatformView {
  private static let side: CGFloat = 48
  private static let gap: CGFloat = 16
  private static let overflowId = "__overflow__"

  private let root: RailRootView
  private let channel: FlutterMethodChannel

  /// Current buttons by item id (the overflow button has a reserved id).
  private var buttons: [String: UIButton] = [:]
  private var top: [String] = []
  private var bottom: [String] = []
  private var hasOverflow = false
  /// The controls that rest at the bottom (while the keyboard is up some of them stand with the top group) and how far
  /// they are from the top-group spot towards their resting place: 0 stacked, 1 at rest. The keyboard sets it, frame by frame.
  private var rest: [String] = []
  private var lift: CGFloat = 1
  /// What each button currently shows (symbol, label, style), so a changed label or symbol is applied in place.
  private var looks: [String: String] = [:]
  private var overflowLook = ""
  /// The size the buttons were last placed for.
  private var laidOut = CGSize.zero
  /// Buttons in the middle of their fade-in. The keyboard's `lift` must not cancel those animations (the
  /// button would pop to its end state); it only moves the model frame the animation is heading for. Keyed by the button
  /// itself, not its id: an id that leaves and comes back gets a new button while the old one's entrance may still finish.
  private var entering = Set<ObjectIdentifier>()
  /// Buttons that have left, kept (hidden) for when their id comes back: making a Liquid Glass button costs the main
  /// thread several milliseconds, and while a platform view is on screen Flutter's frames wait for that thread, so a
  /// page push or pop that made its buttons afresh dropped frames. Each push and pop swaps the same few buttons.
  private var spare: [String: UIButton] = [:]
  /// What each kept button shows (the pre-made back button's look is the one Flutter sends).
  private var spareLooks: [String: String] = ["back": "chevron.backward|返回|false"]

  init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
    root = RailRootView(frame: frame)
    channel = FlutterMethodChannel(name: "ai.jarvis.app/duo-rail/\(viewId)", binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .clear
    root.onLayout = { [weak self] in
      // Only a change of size needs the buttons put back; every other layout pass would reset the alpha and transform of
      // buttons that are in the middle of their entrance animation.
      guard let self, self.root.bounds.size != self.laidOut else { return }
      self.laidOut = self.root.bounds.size
      self.place(animated: false)
    }
    // A strip made while the keyboard is up starts lifted, not at rest and then jumping.
    lift = min(1, max(0, CGFloat((args["lift"] as? Double) ?? 1)))
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "update" {
        self?.apply(call.arguments as? [String: Any] ?? [:], animated: true)
      } else if call.method == "lift" {
        self?.setLift(CGFloat((call.arguments as? Double) ?? 1))
      }
      result(nil)
    }
    apply(args, animated: false)
    // Every pushed page puts a back button here: have it made before the first push needs it.
    let back: [String: Any] = ["id": "back", "symbol": "chevron.backward", "label": "返回"]
    if buttons["back"] == nil {
      let made = button(back)
      made.isHidden = true
      made.alpha = 0
      root.addSubview(made)
      spare["back"] = made
    }
  }

  deinit { channel.setMethodCallHandler(nil) }

  func view() -> UIView { root }

  // MARK: Model

  private func items(_ raw: Any?) -> [[String: Any]] { raw as? [[String: Any]] ?? [] }

  private func apply(_ args: [String: Any], animated: Bool) {
    // Only when it changes: setting it sends a trait change through every glass button, which redraws them all.
    let style: UIUserInterfaceStyle = (args["dark"] as? Bool ?? true) ? .dark : .light
    if root.overrideUserInterfaceStyle != style { root.overrideUserInterfaceStyle = style }
    let newTop = items(args["top"]), newBottom = items(args["bottom"]), overflow = items(args["overflow"])
    let wanted = Set((newTop + newBottom).compactMap { $0["id"] as? String })

    // Buttons that are no longer shown glide to the overflow button's slot (or just fade) and go away.
    let leaving = buttons.filter { $0.key != Self.overflowId && !wanted.contains($0.key) }
    for (id, button) in leaving {
      buttons[id] = nil
      spare[id] = button
    }

    top = newTop.compactMap { $0["id"] as? String }
    bottom = newBottom.compactMap { $0["id"] as? String }
    hasOverflow = !overflow.isEmpty
    rest = (args["rest"] as? [String]) ?? []

    var fresh: [String] = []
    for item in newTop + newBottom {
      let id = item["id"] as? String ?? ""
      if buttons[id] == nil {
        // One kept from an earlier page comes back (restyled if it changed); otherwise one is made.
        let created: UIButton
        if let kept = spare.removeValue(forKey: id) {
          created = kept
          kept.layer.removeAllAnimations()
          entering.remove(ObjectIdentifier(kept))
          if kept.accessibilityLabel != item["label"] as? String || kept.toolTip == nil
            || spareLooks[id] != look(item)
          {
            restyle(kept, item)
          }
          kept.isHidden = false
          kept.transform = .identity
        } else {
          created = button(item)
          root.addSubview(created)
        }
        spareLooks[id] = nil
        created.alpha = animated ? 0 : 1
        if let start = target(id) { created.frame = start }
        if animated {
          fresh.append(id)
        }
        buttons[id] = created
        looks[id] = look(item)
      } else if looks[id] != look(item), let existing = buttons[id] {
        restyle(existing, item)
        looks[id] = look(item)
      }
    }
    for id in looks.keys where !wanted.contains(id) {
      spareLooks[id] = looks[id]
      looks[id] = nil
    }

    var menuButton = buttons[Self.overflowId]
    if overflow.isEmpty {
      if let old = menuButton {
        buttons[Self.overflowId] = nil
        fadeOut(old, to: nil, animated: animated)
        menuButton = nil
      }
    } else if let existing = menuButton {
      // Reassigning an open menu would dismiss it, so only touch it when its items changed.
      let signature = overflow.map { "\($0["id"] ?? "")|\($0["label"] ?? "")|\($0["symbol"] ?? "")" }.joined(separator: ";")
      if signature != overflowLook {
        existing.menu = menu(overflow)
        overflowLook = signature
      }
    } else {
      let created = overflowButton(overflow)
      created.alpha = animated ? 0 : 1
      if animated {
        fresh.append(Self.overflowId)
      }
      overflowLook = overflow.map { "\($0["id"] ?? "")|\($0["label"] ?? "")|\($0["symbol"] ?? "")" }.joined(separator: ";")
      if let start = target(Self.overflowId) { created.frame = start }
      root.addSubview(created)
      buttons[Self.overflowId] = created
    }

    // Where leaving buttons end up: the overflow slot they are folded into.
    let slot = frame(forOverflow: true)
    place(animated: animated, leaving: leaving.map { $0.value }, leavingTo: hasOverflow ? slot : nil, fresh: fresh)
  }

  // MARK: Layout

  private func x() -> CGFloat { (root.bounds.width - Self.side) / 2 }

  private func frame(forOverflow _: Bool) -> CGRect {
    CGRect(x: x(), y: CGFloat(top.count) * (Self.side + Self.gap), width: Self.side, height: Self.side)
  }

  private func target(_ id: String) -> CGRect? {
    if let i = top.firstIndex(of: id) {
      var y = CGFloat(i) * (Self.side + Self.gap)
      // A bottom control standing with the top group: it comes back down as the keyboard goes.
      if lift < 1, let r = rest.firstIndex(of: id) {
        let home = root.bounds.height - Self.side - CGFloat(rest.count - 1 - r) * (Self.side + Self.gap)
        y += (home - y) * lift
      }
      return CGRect(x: x(), y: y, width: Self.side, height: Self.side)
    }
    if let i = bottom.firstIndex(of: id) {
      let fromBottom = CGFloat(bottom.count - 1 - i)
      let y = root.bounds.height - Self.side - fromBottom * (Self.side + Self.gap)
      return CGRect(x: x(), y: y, width: Self.side, height: Self.side)
    }
    if id == Self.overflowId, hasOverflow { return frame(forOverflow: true) }
    return nil
  }

  /// The keyboard moved: put the bottom controls that stand with the top group where it says, at once.
  private func setLift(_ value: CGFloat) {
    lift = min(1, max(0, value))
    guard root.bounds.width > 0 else { return }
    UIView.performWithoutAnimation {
      for id in rest {
        guard top.contains(id), let button = buttons[id], let frame = target(id) else { continue }
        if !entering.contains(ObjectIdentifier(button)) { button.layer.removeAllAnimations() }
        button.frame = frame
      }
    }
  }

  /// A leaving button is hidden once it has faded, not removed: it is kept in [spare] for when it comes back. Unless it
  /// came back while fading (it is shown again then) or is not kept (the overflow button), which goes away.
  private func settle(_ button: UIButton) {
    if spare.values.contains(where: { $0 === button }) {
      button.isHidden = true
    } else if !buttons.values.contains(where: { $0 === button }) {
      button.removeFromSuperview()
    }
  }

  /// Fades a layer's opacity from where it shows now.
  private func fade(_ layer: CALayer, to value: Float) {
    let from = layer.presentation()?.opacity ?? layer.opacity
    layer.removeAnimation(forKey: "fade")
    layer.opacity = value
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = from
    animation.toValue = value
    animation.duration = 0.25
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(animation, forKey: "fade")
  }

  private func fadeOut(_ button: UIButton, to frame: CGRect?, animated: Bool) {
    guard animated else { return settle(button) }
    // Reduce Motion: no glide to the overflow slot and no shrink, just a quick fade.
    if UIAccessibility.isReduceMotionEnabled {
      UIView.animate(
        withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState],
        animations: { button.alpha = 0 },
        completion: { [weak self] finished in if finished { self?.settle(button) } })
      return
    }
    UIView.animate(
      withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState],
      animations: {
        if let frame { button.frame = frame }
        button.alpha = 0
        button.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
      },
      completion: { [weak self] finished in if finished { self?.settle(button) } })
  }

  private func place(animated: Bool, leaving: [UIButton] = [], leavingTo: CGRect? = nil, fresh: [String] = []) {
    // Before the first layout (zero width) there is nothing to animate; leaving buttons must still go away.
    guard root.bounds.width > 0 else {
      for button in leaving { settle(button) }
      return
    }
    let incoming = Set(fresh)
    let moves = {
      for (id, button) in self.buttons where !incoming.contains(id) {
        guard let frame = self.target(id) else { continue }
        button.transform = .identity
        button.frame = frame
        button.alpha = 1
      }
    }
    if animated, UIAccessibility.isReduceMotionEnabled {
      // Reduce Motion: buttons jump to their places and new ones fade in; nothing springs or slides.
      for button in leaving { fadeOut(button, to: leavingTo, animated: true) }
      UIView.performWithoutAnimation { moves() }
      for id in fresh {
        guard let button = buttons[id], let frame = target(id) else { continue }
        UIView.performWithoutAnimation {
          button.transform = .identity
          button.frame = frame
        }
        entering.insert(ObjectIdentifier(button))
        UIView.animate(
          withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
          animations: { button.alpha = 1 },
          completion: { [weak self] _ in
            self?.entering.remove(ObjectIdentifier(button))
          })
      }
    } else if animated {
      // New buttons stand in their places at once and fade in while the leaving ones fade out: a cross-fade, as the
      // system's own bars swap their buttons. Done on the layers' opacity: the same change through UIView animations
      // (alpha, frame, scale) costs the main thread 10 to 20 ms on Liquid Glass buttons, measured on device, and
      // Flutter's frames wait for that thread; this costs about one.
      UIView.performWithoutAnimation {
        for id in fresh {
          guard let button = buttons[id], let frame = target(id) else { continue }
          button.transform = .identity
          button.frame = frame
        }
      }
      // Buttons that stay but change places (the keyboard moved some) glide there.
      let moving = buttons.contains { id, button in
        !incoming.contains(id) && target(id).map { $0 != button.frame || button.alpha != 1 } ?? false
      }
      if moving {
        UIView.animate(
          withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
          options: [.beginFromCurrentState, .allowUserInteraction], animations: moves)
      }
      let arriving = fresh.compactMap { buttons[$0] }
      for button in arriving { entering.insert(ObjectIdentifier(button)) }
      CATransaction.begin()
      CATransaction.setCompletionBlock { [weak self] in
        guard let self else { return }
        for button in leaving where button.layer.opacity == 0 { self.settle(button) }
        for button in arriving { self.entering.remove(ObjectIdentifier(button)) }
      }
      for button in leaving { fade(button.layer, to: 0) }
      for button in arriving { fade(button.layer, to: 1) }
      CATransaction.commit()
    } else {
      for button in leaving { settle(button) }
      moves()
    }
  }

  // MARK: Buttons

  private func symbol(_ name: String?) -> UIImage? {
    guard let name else { return nil }
    return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
  }

  private func baseConfiguration(destructive: Bool) -> UIButton.Configuration {
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      configuration = destructive ? .prominentGlass() : .glass()
    } else {
      configuration = destructive ? .filled() : .tinted()
    }
    configuration.cornerStyle = .capsule
    if destructive {
      configuration.baseBackgroundColor = .systemRed
      configuration.baseForegroundColor = .white
    }
    return configuration
  }

  private func finish(_ button: UIButton, label: String?) -> UIButton {
    button.accessibilityLabel = label
    button.toolTip = label
    button.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
    return button
  }

  private func look(_ item: [String: Any]) -> String {
    "\(item["symbol"] ?? "")|\(item["label"] ?? "")|\(item["destructive"] as? Bool ?? false)"
  }

  private func restyle(_ button: UIButton, _ item: [String: Any]) {
    var configuration = baseConfiguration(destructive: item["destructive"] as? Bool ?? false)
    configuration.image = symbol(item["symbol"] as? String)
    button.configuration = configuration
    button.accessibilityLabel = item["label"] as? String
    button.toolTip = item["label"] as? String
  }

  private func button(_ item: [String: Any]) -> UIButton {
    let id = item["id"] as? String ?? ""
    var configuration = baseConfiguration(destructive: item["destructive"] as? Bool ?? false)
    configuration.image = symbol(item["symbol"] as? String)
    let destructive = item["destructive"] as? Bool ?? false
    let button = UIButton(configuration: configuration, primaryAction: nil)
    // A tick under the finger when the button is released: medium for the destructive one (hang up), light otherwise.
    let feedback = UIImpactFeedbackGenerator(style: destructive ? .medium : .light)
    button.addAction(UIAction { _ in feedback.prepare() }, for: .touchDown)
    button.addAction(
      UIAction { [weak self] _ in
        feedback.impactOccurred()
        self?.channel.invokeMethod("tap", arguments: id)
      }, for: .touchUpInside)
    return finish(button, label: item["label"] as? String)
  }

  private func menu(_ items: [[String: Any]]) -> UIMenu {
    UIMenu(
      children: items.map { item in
        let id = item["id"] as? String ?? ""
        return UIAction(title: item["label"] as? String ?? "", image: symbol(item["symbol"] as? String)) {
          [weak self] _ in self?.channel.invokeMethod("tap", arguments: id)
        }
      })
  }

  private func overflowButton(_ items: [[String: Any]]) -> UIButton {
    var configuration = baseConfiguration(destructive: false)
    configuration.image = symbol("ellipsis")
    let button = UIButton(configuration: configuration, primaryAction: nil)
    button.menu = menu(items)
    button.showsMenuAsPrimaryAction = true
    return finish(button, label: "更多操作")
  }
}
