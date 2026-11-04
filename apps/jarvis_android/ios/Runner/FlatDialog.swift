import UIKit

/// A dialog as the original drew it: a flat card on a dimmed page, a semibold title, plain paragraphs, an optional link line,
/// an optional text field, and the buttons at the foot to the right (the last one filled).
final class FlatDialogController: UIViewController {
  /// Every way up (see the root page): a page shown over it must not take the upside-down turn away again.
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
  struct Action {
    enum Style { case plain, primary, destructive }
    let title: String
    let style: Style
    let handler: (() -> Void)?
    init(_ title: String, _ style: Style = .plain, _ handler: (() -> Void)? = nil) {
      self.title = title
      self.style = style
      self.handler = handler
    }
  }

  private let heading: String
  private let paragraphs: [String]
  private let linkTitle: String?
  private let onLink: (() -> Void)?
  private let fieldText: String?
  private let actions: [Action]
  private let card = UIView()
  private let field = UITextField()
  /// What the text field held when a button was pressed.
  var onField: ((String) -> Void)?
  /// What the link line does (when it is set after the dialog was made).
  var linkAction: (() -> Void)?

  init(
    title: String, paragraphs: [String] = [], link: String? = nil, onLink: (() -> Void)? = nil, field: String? = nil, actions: [Action]
  ) {
    heading = title
    self.paragraphs = paragraphs
    linkTitle = link
    self.onLink = onLink
    fieldText = field
    self.actions = actions
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.65) : UIColor.black.withAlphaComponent(0.32) }
    card.styleSurface(Palette.containerHigh, radius: Radii.sheet)
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)

    let title = UILabel()
    title.text = heading
    title.font = .systemFont(ofSize: 20, weight: .semibold)
    title.textColor = Palette.onSurface
    title.numberOfLines = 0
    title.accessibilityTraits = .header
    var rows: [UIView] = [title]
    for text in paragraphs {
      let label = UILabel()
      label.text = text
      label.font = .systemFont(ofSize: 14)
      label.textColor = Palette.onSurface
      label.numberOfLines = 0
      rows.append(label)
    }
    if let linkTitle {
      var c = UIButton.Configuration.plain()
      c.contentInsets = .zero
      let text = NSMutableAttributedString(
        string: linkTitle,
        attributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: Palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue])
      let chevron = NSTextAttachment()
      chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
        .withTintColor(Palette.accent, renderingMode: .alwaysOriginal)
      text.append(NSAttributedString(string: " "))
      text.append(NSAttributedString(attachment: chevron))
      c.attributedTitle = AttributedString(text)
      let button = UIButton(configuration: c)
      button.contentHorizontalAlignment = .leading
      button.addAction(UIAction { [weak self] _ in (self?.linkAction ?? self?.onLink)?() }, for: .touchUpInside)
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      rows.append(button)
    }
    if let fieldText {
      field.text = fieldText
      field.font = .systemFont(ofSize: 16)
      field.textColor = Palette.onSurface
      field.tintColor = Palette.accent
      field.clearButtonMode = .whileEditing
      field.backgroundColor = Palette.surface
      field.layer.cornerRadius = Radii.medium
      field.layer.cornerCurve = .continuous
      field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
      field.leftViewMode = .always
      field.heightAnchor.constraint(equalToConstant: 52).isActive = true
      field.returnKeyType = .done
      field.addTarget(self, action: #selector(finishField), for: .editingDidEndOnExit)
      rows.append(field)
    }
    let foot = UIStackView()
    foot.axis = .horizontal
    foot.spacing = 8
    foot.alignment = .center
    foot.addArrangedSubview(UIView())
    for (i, action) in actions.enumerated() {
      var c: UIButton.Configuration = action.style == .primary ? .filled() : .plain()
      c.title = action.title
      c.cornerStyle = .capsule
      c.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20)
      switch action.style {
      case .primary:
        c.baseBackgroundColor = Palette.primary
        c.baseForegroundColor = Palette.onPrimary
      case .destructive:
        c.baseForegroundColor = Palette.error
      case .plain:
        c.baseForegroundColor = Palette.onSurface
      }
      c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
        var a = $0
        a.font = .systemFont(ofSize: 15, weight: .medium)
        return a
      }
      let button = UIButton(configuration: c)
      button.addAction(UIAction { [weak self] _ in self?.choose(i) }, for: .touchUpInside)
      foot.addArrangedSubview(button)
    }
    rows.append(foot)
    let stack = UIStackView(arrangedSubviews: rows)
    stack.axis = .vertical
    stack.spacing = 12
    stack.setCustomSpacing(8, after: title)
    if linkTitle != nil || fieldText != nil { stack.setCustomSpacing(16, after: rows[rows.count - 2]) }
    stack.setCustomSpacing(20, after: rows[rows.count - 2])
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    let width = card.widthAnchor.constraint(equalToConstant: 560)
    width.priority = .defaultHigh
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      card.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
      card.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      card.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      width,
    ])
    card.accessibilityViewIsModal = true
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if fieldText != nil {
      field.becomeFirstResponder()
      field.selectAll(nil)
    }
  }

  @objc private func finishField() {
    if let last = actions.indices.last { choose(last) }
  }

  private var chosen = false

  private func choose(_ index: Int) {
    guard !chosen else { return }
    chosen = true
    let text = field.text ?? ""
    dismiss(animated: true) { [actions, onField, fieldText] in
      if fieldText != nil { onField?(text) }
      actions[index].handler?()
    }
  }
}

extension UIViewController {
  /// A one-button notice in the original's dialog.
  func showNotice(_ text: String, title: String? = nil) {
    present(FlatDialogController(title: title ?? text, paragraphs: title == nil ? [] : [text], actions: [.init("好", .primary)]), animated: true)
  }
}

/// A page with the original's own top bar: the back arrow at the left, the title in the middle, an optional button at the
/// right, on the page colour; the system bar is hidden for it.
final class PageContainer: UIViewController {
  /// Every way up (see the root page): a page shown over it must not take the upside-down turn away again.
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
  private let content: UIViewController
  private let heading: String
  private let trailing: UIButton?
  var onBack: (() -> Void)?
  private let back = UIButton(type: .system)
  private let titleLabel = UILabel()
  private var barTop: NSLayoutConstraint!
  private var stripTop: NSLayoutConstraint!

  init(title: String, content: UIViewController, trailing: UIButton? = nil) {
    heading = title
    self.content = content
    self.trailing = trailing
    super.init(nibName: nil, bundle: nil)
    // The bar's item is there from the start, so that the system can carry the chat's buttons over into it as the page slides
    // in (an item added after the push starts is not part of that move). Without a vertical strip the bar stays hidden.
    if let trailing {
      let item = UIBarButtonItem(image: trailing.configuration?.image, primaryAction: UIAction { [weak trailing] _ in trailing?.sendActions(for: .touchUpInside) })
      item.accessibilityLabel = trailing.accessibilityLabel
      navigationItem.rightBarButtonItem = item
    }
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.surface
    var c = UIButton.Configuration.plain()
    c.image = UIImage(systemName: "chevron.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
    c.baseForegroundColor = Palette.onSurface
    back.configuration = c
    back.accessibilityLabel = "返回"
    back.addAction(UIAction { [weak self] _ in self?.goBack() }, for: .touchUpInside)
    let title = titleLabel
    title.text = heading
    title.font = .systemFont(ofSize: 16, weight: .semibold)
    title.textColor = Palette.onSurface
    title.textAlignment = .center
    title.accessibilityTraits = .header
    for v in [back, title] as [UIView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(v)
    }
    addChild(content)
    content.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(content.view)
    content.didMove(toParent: self)
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      back.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8), back.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4),
      back.widthAnchor.constraint(equalToConstant: 48), back.heightAnchor.constraint(equalToConstant: 48),
      title.centerXAnchor.constraint(equalTo: guide.centerXAnchor), title.centerYAnchor.constraint(equalTo: back.centerYAnchor),
      content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    barTop = content.view.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 4)
    stripTop = content.view.topAnchor.constraint(equalTo: guide.topAnchor)
    if let trailing {
      trailing.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(trailing)
      NSLayoutConstraint.activate([
        trailing.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8), trailing.centerYAnchor.constraint(equalTo: back.centerYAnchor),
        trailing.widthAnchor.constraint(equalToConstant: 48), trailing.heightAnchor.constraint(equalToConstant: 48),
      ])
    }
    applyBarMode(bar: false)
  }

  /// Beside a vertical bar strip (iPhone Duo's outer display, inner landscape) the controls belong in that strip, and only
  /// the system's bar is moved there: show it, with the back button it makes and the page's trailing button as a bar item.
  /// Otherwise the page keeps its own top bar.
  /// The system's bar is shown on every screen (its buttons are the glass ones the chat has, along the vertical strip, along the top of
  /// a phone or of the inner display held upright), so that the page's buttons are the same ones, in the same place, whichever way the
  /// device is held; and the edge swipe back is the system's own.
  private var systemBar: Bool { true }
  private var barModeApplied: Bool?
  private var verticalApplied: Bool?

  private func applyBarMode(bar: Bool = true) {
    guard isViewLoaded else { return }
    let strip = systemBar
    barModeApplied = strip
    verticalApplied = hasVerticalBar(traitCollection)
    // Along the top the bar has a title of its own (a strip has no room for one).
    navigationItem.title = hasVerticalBar(traitCollection) ? nil : heading
    // The bar is only touched once the page is on its way in: while the view loads the traits are not settled, and hiding the
    // bar there and showing it again a moment later is a visible hitch as the page slides in.
    if bar && navigationController?.isNavigationBarHidden != !strip { navigationController?.setNavigationBarHidden(!strip, animated: false) }
    back.isHidden = strip
    titleLabel.isHidden = strip
    // Pushed on a stack, the system makes the back button, and it is the one that morphs out of the bar's buttons as the page
    // slides in; only a page that stands alone (settings from the drawer) needs one made.
    let pushed = (navigationController?.viewControllers.count ?? 0) > 1
    // A pushed page keeps the system's back button (hidden under the hidden bar; its edge swipe works), a lone page has none.
    navigationItem.hidesBackButton = !pushed
    if strip && !pushed {
      let item = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), primaryAction: UIAction { [weak self] _ in self?.goBack() })
      item.accessibilityLabel = "返回"
      navigationItem.leftBarButtonItem = item
    } else {
      navigationItem.leftBarButtonItem = nil
    }
    barTop.isActive = !strip
    stripTop.isActive = strip
    trailing?.isHidden = strip
  }

  /// A turn of the device between upright and sideways changes the bar without changing the traits.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The bar the page is in changed (a vertical strip came or went, or the device turned): the page's bar is set again.
    if barModeApplied != systemBar || verticalApplied != hasVerticalBar(traitCollection) { applyBarMode() }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyBarMode()
  }

  private func goBack() {
    if let onBack { return onBack() }
    if let nav = navigationController, nav.viewControllers.count > 1 {
      nav.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }
}

extension UIButton {
  /// A bare icon button for a page's top bar.
  static func barIcon(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
    let b = UIButton(type: .system)
    var c = UIButton.Configuration.plain()
    c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
    c.baseForegroundColor = Palette.onSurfaceVariant
    b.configuration = c
    b.accessibilityLabel = label
    b.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return b
  }
}

/// The original's popup menu: a rounded card in the raised colour with an icon and a word on every row, hanging from the
/// button that opened it (below it, or above when there is no room); a touch anywhere else closes it.
final class FlatMenuController: UIViewController {
  /// Every way up (see the root page): a page shown over it must not take the upside-down turn away again.
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
  struct Item {
    let title: String
    let symbol: String?
    var checked = false
    var destructive = false
    let action: () -> Void
  }

  private let items: [Item]
  private let anchor: CGRect
  private let preferAbove: Bool
  private let card = UIView()

  init(items: [Item], anchor: CGRect, preferAbove: Bool = false) {
    self.items = items
    self.anchor = anchor
    self.preferAbove = preferAbove
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  /// Shows a menu hanging from `view`.
  @MainActor
  static func show(_ items: [Item], from view: UIView, above: Bool = false) {
    guard let window = view.window, let top = window.rootViewController?.topmost else { return }
    let rect = view.convert(view.bounds, to: window)
    top.present(FlatMenuController(items: items, anchor: rect, preferAbove: above), animated: true)
  }

  /// A symbol centred in a box of one size, so the words line up whatever the symbol's width.
  private static func slot(_ name: String) -> UIImage? {
    guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .light))?
      .withTintColor(Palette.onSurfaceVariant, renderingMode: .alwaysOriginal)
    else { return nil }
    let size = CGSize(width: 24, height: 22)
    return UIGraphicsImageRenderer(size: size).image { _ in
      symbol.draw(in: CGRect(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    let tap = UITapGestureRecognizer(target: self, action: #selector(close))
    tap.cancelsTouchesInView = false
    view.addGestureRecognizer(tap)
    card.styleSurface(Palette.containerHigh, radius: Radii.medium, border: Palette.outlineVariant)
    card.layer.shadowColor = UIColor.black.cgColor
    card.layer.shadowOpacity = 0.35
    card.layer.shadowRadius = 16
    card.layer.shadowOffset = CGSize(width: 0, height: 6)
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)
    let stack = UIStackView()
    stack.axis = .vertical
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    for (i, item) in items.enumerated() {
      var c = UIButton.Configuration.plain()
      c.title = item.title
      c.image = item.symbol.flatMap { Self.slot($0) }
      c.imagePadding = 14
      c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 18)
      c.baseForegroundColor = item.destructive ? Palette.error : Palette.onSurface
      c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
        var a = $0
        a.font = .systemFont(ofSize: 15)
        return a
      }
      let button = UIButton(configuration: c)
      button.contentHorizontalAlignment = .leading
      button.heightAnchor.constraint(equalToConstant: 50).isActive = true
      button.addAction(UIAction { [weak self] _ in
        self?.dismiss(animated: true) { item.action() }
      }, for: .touchUpInside)
      if item.checked {
        let mark = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)))
        mark.tintColor = Palette.accent
        mark.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(mark)
        NSLayoutConstraint.activate([mark.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14), mark.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
      }
      stack.addArrangedSubview(button)
      _ = i
    }
    let rect = anchor
    let height = CGFloat(items.count) * 50
    let below = rect.maxY + 6 + height <= view.bounds.maxY - 12 && !preferAbove
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 4), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      card.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
    ])
    // Hung from the button's own side: the right edge to a button in the right half, the left edge to one in the left.
    if rect.midX > view.bounds.midX {
      card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10).isActive = true
    } else {
      card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: max(8, rect.minX)).isActive = true
    }
    if below {
      card.topAnchor.constraint(equalTo: view.topAnchor, constant: rect.maxY + 6).isActive = true
    } else {
      card.bottomAnchor.constraint(equalTo: view.topAnchor, constant: rect.minY - 6).isActive = true
    }
  }

  @objc private func close(_ tap: UITapGestureRecognizer) {
    if !card.frame.contains(tap.location(in: view)) { dismiss(animated: true) }
  }
}

extension UIViewController {
  var topmost: UIViewController {
    var top = self
    while let next = top.presentedViewController { top = next }
    return top
  }
}
