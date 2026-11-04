import UIKit

// MARK: Glass rename dialog

final class GlassRenameDialog: UIView, UITextFieldDelegate {
  private let card: UIVisualEffectView
  private let field = UITextField()
  private let counter = UILabel()
  private var free: CGRect
  private let inset: CGFloat
  private weak static var showing: GlassRenameDialog?
  /// Closes the one on screen as a "no" (the session ended under it, say).
  static func dismissShowing() { showing?.close(save: false) }
  private let maxLength: Int
  private var finish: ((String?) -> Void)?
  private var keyboardTop: CGFloat?
  private var closing = false

  init(
    frame: CGRect, title: String, text: String, maxLength: Int, cancel: String, save: String, free: CGRect,
    inset: CGFloat, finish: @escaping (String?) -> Void
  ) {
    self.maxLength = maxLength
    self.inset = inset
    self.free = free
    self.finish = finish
    card = UIVisualEffectView(effect: GlassRenameDialog.glass(clear: false))
    super.init(frame: frame)
    backgroundColor = UIColor.black.withAlphaComponent(0)
    accessibilityViewIsModal = true

    if #available(iOS 26.0, *) {
      card.cornerConfiguration = .corners(radius: .fixed(34))
    } else {
      card.layer.cornerRadius = 34
      card.layer.cornerCurve = .continuous
      card.clipsToBounds = true
    }

    let titleLabel = UILabel()
    titleLabel.text = title
    titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 22, weight: .semibold))
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.numberOfLines = 0
    titleLabel.textColor = .label
    titleLabel.accessibilityTraits = .header

    let box = UIVisualEffectView(effect: GlassRenameDialog.glass(clear: true))
    if #available(iOS 26.0, *) {
      box.cornerConfiguration = .corners(radius: .fixed(22))
    } else {
      box.layer.cornerRadius = 22
      box.layer.cornerCurve = .continuous
      box.clipsToBounds = true
    }
    // An imported title longer than the limit is cut to it here; nothing is saved unless the person saves.
    field.text = String(text.prefix(maxLength))
    field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 18))
    field.adjustsFontForContentSizeCategory = true
    field.textColor = .label
    field.clearButtonMode = .whileEditing
    field.returnKeyType = .done
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
    field.addTarget(self, action: #selector(changed), for: .editingChanged)
    box.contentView.addSubview(field)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: box.contentView.leadingAnchor, constant: 18),
      field.trailingAnchor.constraint(equalTo: box.contentView.trailingAnchor, constant: -14),
      field.topAnchor.constraint(equalTo: box.contentView.topAnchor),
      field.bottomAnchor.constraint(equalTo: box.contentView.bottomAnchor),
      box.heightAnchor.constraint(greaterThanOrEqualToConstant: 66),
    ])

    counter.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    counter.textColor = .secondaryLabel
    counter.textAlignment = .right
    changed()

    let cancelButton = button(cancel, prominent: false) { [weak self] in self?.close(save: false) }
    let saveButton = button(save, prominent: true) { [weak self] in self?.close(save: true) }
    let buttons = UIStackView(arrangedSubviews: [cancelButton, saveButton])
    buttons.axis = .horizontal
    buttons.spacing = 12
    buttons.distribution = .fillEqually

    let stack = UIStackView(arrangedSubviews: [titleLabel, box, counter, buttons])
    stack.axis = .vertical
    stack.spacing = 18
    stack.setCustomSpacing(8, after: box)
    stack.setCustomSpacing(24, after: counter)
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 34, left: 24, bottom: 30, right: 24)
    stack.insetsLayoutMarginsFromSafeArea = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
    ])
    addSubview(card)

    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  override func accessibilityPerformEscape() -> Bool {
    close(save: false)
    return true
  }

  /// A turn or a fold changes the room: the card is set in the new one.
  override func layoutSubviews() {
    super.layoutSubviews()
    guard window != nil, !closing else { return }
    free = CGRect(
      x: safeAreaInsets.left, y: safeAreaInsets.top, width: bounds.width - safeAreaInsets.left - safeAreaInsets.right,
      height: bounds.height - safeAreaInsets.top - safeAreaInsets.bottom)
    layoutCard()
  }

  fileprivate static func glass(clear: Bool) -> UIVisualEffect {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: clear ? .clear : .regular)
      // In the light theme the card took the colour of what was behind it (a cyan picture made the red "删除" hard to read): it is
      // whitened there. The dark theme is left as it was.
      if !clear { effect.tintColor = UIColor { $0.userInterfaceStyle == .light ? UIColor.white.withAlphaComponent(0.72) : UIColor.black.withAlphaComponent(0) } }
      return effect
    }
    return UIBlurEffect(style: clear ? .systemUltraThinMaterial : .systemThickMaterial)
  }

  private func button(_ title: String, prominent: Bool, action: @escaping () -> Void) -> UIButton {
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      configuration = prominent ? .prominentGlass() : .glass()
    } else {
      configuration = prominent ? .filled() : .tinted()
    }
    configuration.cornerStyle = .capsule
    configuration.title = title
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: prominent ? .semibold : .regular))
      return attributes
    }
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 17, leading: 20, bottom: 17, trailing: 20)
    let button = UIButton(configuration: configuration)
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  // MARK: Showing

  func present() {
    layoutCard()
    card.alpha = 0
    card.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
    let reduce = UIAccessibility.isReduceMotionEnabled
    if reduce { card.transform = .identity }
    UIView.animate(
      withDuration: reduce ? 0.2 : 0.32, delay: 0, usingSpringWithDamping: reduce ? 1 : 0.86, initialSpringVelocity: 0,
      options: [.allowUserInteraction]
    ) {
      self.card.alpha = 1
      self.card.transform = .identity
      self.backgroundColor = UIColor.black.withAlphaComponent(0.4)
    }
    UIAccessibility.post(notification: .screenChanged, argument: field)
    field.becomeFirstResponder()
    DispatchQueue.main.async { self.field.selectAll(nil) }
  }

  private func layoutCard() {
    let width = min(560, max(280, free.width - 2 * inset))
    let fit = card.contentView.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    let bottom = min(free.maxY, (keyboardTop ?? .greatestFiniteMagnitude) - 8)
    let area = CGRect(x: free.minX, y: free.minY, width: free.width, height: max(0, bottom - free.minY))
    let y = max(free.minY + 8, area.minY + (area.height - fit.height) / 2)
    card.bounds = CGRect(x: 0, y: 0, width: width, height: fit.height)
    card.center = CGPoint(x: area.midX, y: y + fit.height / 2)
  }

  @objc private func keyboardChanged(_ note: Notification) {
    guard !closing, let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
      let window = window
    else { return }
    let top = convert(end, from: window.screen.coordinateSpace).minY
    keyboardTop = top >= bounds.height - 1 ? nil : top
    let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7
    UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: UInt(curve) << 16), .beginFromCurrentState]) {
      self.layoutCard()
    }
  }

  // MARK: Text

  /// The length limit is kept here and not by refusing keystrokes: refusing them broke the spelling a Chinese or Japanese keyboard
  /// holds in the field (marked text) and made a title over the limit impossible to cut down. The text is trimmed to the limit
  /// once nothing is being spelt.
  @objc private func changed() {
    if field.markedTextRange == nil, let text = field.text, text.count > maxLength {
      field.text = String(text.prefix(maxLength))
    }
    counter.text = "\((field.text ?? "").count)/\(maxLength)"
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    close(save: true)
    return false
  }

  // MARK: Closing

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first, !card.frame.contains(touch.location(in: self)) else { return }
    close(save: false)
  }

  private func close(save: Bool) {
    guard !closing else { return }
    closing = true
    let text = save ? field.text ?? "" : nil
    field.resignFirstResponder()
    UIView.animate(
      withDuration: UIAccessibility.isReduceMotionEnabled ? 0.01 : 0.18, delay: 0, options: [.curveEaseIn],
      animations: {
        self.card.alpha = 0
        self.card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        self.backgroundColor = UIColor.black.withAlphaComponent(0)
      }
    ) { _ in
      self.removeFromSuperview()
      self.finish?(text)
      self.finish = nil
    }
  }
}



extension GlassRenameDialog {
  /// The rename dialog over the window: it stands in the room the page has (the screen less the strip, the crease and the safe
  /// areas) and above the keyboard.
  static func show(title: String, text: String, in window: UIWindow, room: CGRect, finish: @escaping (String?) -> Void) {
    // One at a time: a second touch on the menu's item, before the first dialog is up, makes no second one.
    if showing?.superview != nil { return }
    let dialog = GlassRenameDialog(
      frame: window.bounds, title: title, text: text, maxLength: 80, cancel: "取消", save: "保存", free: room, inset: 16, finish: finish)
    dialog.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(dialog)
    showing = dialog
    dialog.present()
  }
}

// MARK: Glass confirm dialog

/// A question with two answers, in a card of Liquid Glass: a bold title, a quieter line or two, and two round buttons of equal
/// width side by side (the second one may be in the red of a delete). It stands in the middle of the room the page has, over a
/// dimmed page, and comes in with a small spring.
final class GlassConfirmDialog: UIView {
  private let card: UIVisualEffectView
  private var free: CGRect
  private let inset: CGFloat
  private var finish: ((Bool) -> Void)?
  /// A touch outside the card or the VoiceOver escape: when set, this is what happens (not `finish(false)`), so that "not now" by
  /// the button and "never mind" by a stray touch can be told apart.
  var onDismiss: (() -> Void)?
  private var closing = false
  private var presented = false
  private var titleElement: UILabel?
  private weak static var showing: GlassConfirmDialog?
  static func dismissShowing() { showing?.close(confirmed: false) }

  init(
    frame: CGRect, title: String, lines: [String], cancel: String, confirm: String, destructive: Bool, free: CGRect, inset: CGFloat,
    finish: @escaping (Bool) -> Void
  ) {
    self.free = free
    self.inset = inset
    self.finish = finish
    card = UIVisualEffectView(effect: GlassRenameDialog.glass(clear: false))
    super.init(frame: frame)
    backgroundColor = UIColor.black.withAlphaComponent(0)
    accessibilityViewIsModal = true

    if #available(iOS 26.0, *) {
      card.cornerConfiguration = .corners(radius: .fixed(30))
    } else {
      card.layer.cornerRadius = 30
      card.layer.cornerCurve = .continuous
      card.clipsToBounds = true
    }

    let titleLabel = UILabel()
    titleLabel.text = title
    titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 19, weight: .semibold))
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 0
    titleLabel.accessibilityTraits = .header
    titleElement = titleLabel

    let messages = lines.map { line -> UILabel in
      let label = UILabel()
      label.text = line
      label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15))
      label.adjustsFontForContentSizeCategory = true
      label.textColor = .secondaryLabel
      // A long name does not stretch the card: three lines at most, the middle left out.
      label.numberOfLines = 3
      label.lineBreakMode = .byTruncatingMiddle
      return label
    }
    let text = UIStackView(arrangedSubviews: [titleLabel] + messages)
    text.axis = .vertical
    text.spacing = 4
    text.setCustomSpacing(8, after: titleLabel)

    let cancelButton = button(cancel, red: false) { [weak self] in self?.close(confirmed: false) }
    let confirmButton = button(confirm, red: destructive) { [weak self] in self?.close(confirmed: true) }
    let buttons = UIStackView(arrangedSubviews: [cancelButton, confirmButton])
    buttons.axis = .horizontal
    buttons.spacing = 8
    buttons.distribution = .fillEqually

    let stack = UIStackView(arrangedSubviews: [text, buttons])
    stack.axis = .vertical
    stack.spacing = 22
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 26, left: 22, bottom: 20, right: 22)
    stack.insetsLayoutMarginsFromSafeArea = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
    ])
    addSubview(card)
  }

  required init?(coder: NSCoder) { fatalError() }

  private func button(_ title: String, red: Bool, action: @escaping () -> Void) -> UIButton {
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) { configuration = .glass() } else { configuration = .tinted() }
    configuration.cornerStyle = .capsule
    configuration.title = title
    configuration.baseForegroundColor = red ? Palette.error : .label
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 16, weight: .medium))
      return attributes
    }
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
    let button = UIButton(configuration: configuration)
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  private func layoutCard() {
    let width = min(360, max(260, free.width - 2 * inset))
    let fit = card.contentView.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    card.bounds = CGRect(x: 0, y: 0, width: width, height: fit.height)
    card.center = CGPoint(x: free.midX, y: free.midY)
  }

  /// A turn or a fold changes the room: the card is set in the new one.
  override func layoutSubviews() {
    super.layoutSubviews()
    guard presented, !closing else { return }
    free = CGRect(
      x: safeAreaInsets.left, y: safeAreaInsets.top, width: bounds.width - safeAreaInsets.left - safeAreaInsets.right,
      height: bounds.height - safeAreaInsets.top - safeAreaInsets.bottom)
    layoutCard()
  }

  override func accessibilityPerformEscape() -> Bool {
    dismissWithoutAnswer()
    return true
  }

  private func dismissWithoutAnswer() {
    if let onDismiss {
      guard !closing else { return }
      closing = true
      animateOut { [weak self] in
        onDismiss()
        self?.finish = nil
      }
    } else {
      close(confirmed: false)
    }
  }

  private func animateOut(_ done: @escaping () -> Void) {
    UIView.animate(
      withDuration: UIAccessibility.isReduceMotionEnabled ? 0.01 : 0.18, delay: 0, options: [.curveEaseIn],
      animations: {
        self.card.alpha = 0
        self.card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        self.backgroundColor = UIColor.black.withAlphaComponent(0)
      }
    ) { _ in
      self.removeFromSuperview()
      done()
    }
  }

  func present() {
    layoutCard()
    presented = true
    card.alpha = 0
    let reduce = UIAccessibility.isReduceMotionEnabled
    card.transform = reduce ? .identity : CGAffineTransform(scaleX: 0.92, y: 0.92)
    UIView.animate(
      withDuration: reduce ? 0.2 : 0.32, delay: 0, usingSpringWithDamping: reduce ? 1 : 0.86, initialSpringVelocity: 0, options: [.allowUserInteraction]
    ) {
      self.card.alpha = 1
      self.card.transform = .identity
      self.backgroundColor = UIColor.black.withAlphaComponent(0.4)
    }
    // VoiceOver goes to the title (the card itself is not an element).
    UIAccessibility.post(notification: .screenChanged, argument: titleElement ?? card)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first, !card.frame.contains(touch.location(in: self)) else { return }
    dismissWithoutAnswer()
  }

  private func close(confirmed: Bool) {
    guard !closing else { return }
    closing = true
    animateOut { [weak self] in
      self?.finish?(confirmed)
      self?.finish = nil
    }
  }

  /// The dialog over the window, in the room the page has (the screen less the strip, the crease and the safe areas).
  /// False when none was put up (there is one already): nothing will be answered then.
  @discardableResult
  static func show(
    title: String, lines: [String], cancel: String = "取消", confirm: String, destructive: Bool = false, in window: UIWindow,
    dismissed: (() -> Void)? = nil, finish: @escaping (Bool) -> Void
  ) -> Bool {
    // One at a time, and with no keyboard under it (the list's search field may have one up).
    if showing?.superview != nil { return false }
    window.endEditing(true)
    let safe = window.safeAreaInsets
    let room = CGRect(
      x: safe.left, y: safe.top, width: window.bounds.width - safe.left - safe.right, height: window.bounds.height - safe.top - safe.bottom)
    let dialog = GlassConfirmDialog(
      frame: window.bounds, title: title, lines: lines, cancel: cancel, confirm: confirm, destructive: destructive, free: room, inset: 24,
      finish: finish)
    dialog.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    dialog.onDismiss = dismissed
    window.addSubview(dialog)
    showing = dialog
    dialog.present()
    return true
  }
}

// MARK: Glass notice

/// A notice that has to be read before it is agreed to (the first-run notice about what is sent to the AI service): a title, a few
/// short points each with a symbol, a line that opens a page, a small note on what "no" means, and two answers of equal width. It
/// stands in the middle of the room the page has (not under the strip of buttons), and its text scrolls when the room is short
/// (a large text size), with the two answers staying where they are.
final class GlassNoticeDialog: UIView {
  struct Point {
    let symbol: String
    let text: String
  }

  private let card: UIVisualEffectView
  private let scroll = UIScrollView()
  private let content = UIStackView()
  private let rootStack = UIStackView()
  private var scrollHeight: NSLayoutConstraint!
  private var free: CGRect
  private let inset: CGFloat
  private var finish: ((Bool) -> Void)?
  private var onLink: (() -> Void)?
  private var closing = false
  private var presented = false
  private weak static var showing: GlassNoticeDialog?
  static func dismissShowing() { showing?.close(confirmed: false) }
  private static let margins = UIEdgeInsets(top: 26, left: 22, bottom: 20, right: 22)
  private var buttons = UIStackView()
  private var titleElement: UILabel?

  init(
    frame: CGRect, title: String, points: [Point], link: String?, footnote: String?, cancel: String, confirm: String, free: CGRect,
    inset: CGFloat, onLink: (() -> Void)?, finish: @escaping (Bool) -> Void
  ) {
    self.free = free
    self.inset = inset
    self.finish = finish
    self.onLink = onLink
    card = UIVisualEffectView(effect: GlassRenameDialog.glass(clear: false))
    super.init(frame: frame)
    backgroundColor = UIColor.black.withAlphaComponent(0)
    accessibilityViewIsModal = true
    if #available(iOS 26.0, *) {
      card.cornerConfiguration = .corners(radius: .fixed(30))
    } else {
      card.layer.cornerRadius = 30
      card.layer.cornerCurve = .continuous
      card.clipsToBounds = true
    }

    let titleLabel = UILabel()
    titleLabel.text = title
    titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 21, weight: .semibold), maximumPointSize: 30)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 0
    titleLabel.accessibilityTraits = .header
    titleElement = titleLabel
    content.axis = .vertical
    content.spacing = 14
    content.addArrangedSubview(titleLabel)
    content.setCustomSpacing(16, after: titleLabel)

    for point in points {
      let icon = UIImageView(
        image: UIImage(systemName: point.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)))
      icon.tintColor = Palette.accent
      icon.contentMode = .top
      icon.setContentHuggingPriority(.required, for: .horizontal)
      icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
      icon.accessibilityElementsHidden = true
      let label = UILabel()
      label.text = point.text
      label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15), maximumPointSize: 22)
      label.adjustsFontForContentSizeCategory = true
      label.textColor = .label
      label.numberOfLines = 0
      let row = UIStackView(arrangedSubviews: [icon, label])
      row.axis = .horizontal
      row.alignment = .top
      row.spacing = 10
      content.addArrangedSubview(row)
    }

    if let link {
      var configuration = UIButton.Configuration.plain()
      configuration.title = link
      // No arrow and no underline: the accent colour alone says it is a link (as a link is in the system's own text).
      configuration.baseForegroundColor = Palette.accent
      configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: 22)
        return attributes
      }
      let button = UIButton(configuration: configuration)
      button.contentHorizontalAlignment = .center
      button.addAction(UIAction { [weak self] _ in self?.linkTapped() }, for: .touchUpInside)
      content.addArrangedSubview(button)
      content.setCustomSpacing(8, after: content.arrangedSubviews[content.arrangedSubviews.count - 2])
    }

    if let footnote {
      let label = UILabel()
      label.text = footnote
      label.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13), maximumPointSize: 19)
      label.adjustsFontForContentSizeCategory = true
      label.textColor = .secondaryLabel
      label.numberOfLines = 0
      label.textAlignment = .center
      content.addArrangedSubview(label)
    }

    content.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(content)
    scroll.alwaysBounceVertical = false
    scroll.showsVerticalScrollIndicator = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
    ])
    scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 200)
    scrollHeight.isActive = true

    let cancelButton = Self.button(cancel, prominent: false) { [weak self] in self?.close(confirmed: false) }
    let confirmButton = Self.button(confirm, prominent: true) { [weak self] in self?.close(confirmed: true) }
    buttons = UIStackView(arrangedSubviews: [cancelButton, confirmButton])
    buttons.axis = .horizontal
    buttons.spacing = 8
    buttons.distribution = .fillEqually

    rootStack.axis = .vertical
    rootStack.spacing = 20
    rootStack.addArrangedSubview(scroll)
    rootStack.addArrangedSubview(buttons)
    rootStack.isLayoutMarginsRelativeArrangement = true
    rootStack.layoutMargins = Self.margins
    // The margins are exactly these: left to itself the stack added the safe area to them (a turn of the device made that 84 pt on
    // one side for a moment), and the text was measured for a width it did not have.
    rootStack.insetsLayoutMarginsFromSafeArea = false
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    card.contentView.addSubview(rootStack)
    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
      rootStack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
      rootStack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
      rootStack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
    ])
    addSubview(card)
  }

  required init?(coder: NSCoder) { fatalError() }

  private static func button(_ title: String, prominent: Bool, action: @escaping () -> Void) -> UIButton {
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) { configuration = prominent ? .prominentGlass() : .glass() } else { configuration = prominent ? .filled() : .tinted() }
    configuration.cornerStyle = .capsule
    configuration.title = title
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 16, weight: prominent ? .semibold : .medium), maximumPointSize: 24)
      return attributes
    }
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
    let button = UIButton(configuration: configuration)
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  private func layoutCard() {
    // A little wider where there is plenty of room (a tablet, a wide inner display).
    let width = min(free.width >= 640 ? 420 : 380, max(280, free.width - 2 * inset))
    let inner = width - Self.margins.left - Self.margins.right
    // The text takes what it needs, or what the room allows (and then scrolls); the answers stay under it.
    let text = content.systemLayoutSizeFitting(
      CGSize(width: inner, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
    ).height
    // The answers' own height (it grows with the text size), not a figure assumed for them.
    let answers = buttons.systemLayoutSizeFitting(
      CGSize(width: inner, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
    ).height
    let chrome = Self.margins.top + Self.margins.bottom + rootStack.spacing + answers
    scrollHeight.constant = max(80, min(text, free.height - 2 * 12 - chrome))
    scroll.isScrollEnabled = text > scrollHeight.constant + 0.5
    let fit = card.contentView.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    card.bounds = CGRect(x: 0, y: 0, width: width, height: fit.height)
    card.center = CGPoint(x: free.midX, y: free.midY)
  }

  /// A turn or a fold changes the room: the card is set in the new one.
  override func layoutSubviews() {
    super.layoutSubviews()
    guard presented, !closing else { return }
    free = CGRect(
      x: safeAreaInsets.left, y: safeAreaInsets.top, width: bounds.width - safeAreaInsets.left - safeAreaInsets.right,
      height: bounds.height - safeAreaInsets.top - safeAreaInsets.bottom)
    layoutCard()
  }

  override func accessibilityPerformEscape() -> Bool {
    close(confirmed: false)
    return true
  }

  private func present() {
    layoutCard()
    presented = true
    card.alpha = 0
    let reduce = UIAccessibility.isReduceMotionEnabled
    card.transform = reduce ? .identity : CGAffineTransform(scaleX: 0.92, y: 0.92)
    UIView.animate(
      withDuration: reduce ? 0.2 : 0.32, delay: 0, usingSpringWithDamping: reduce ? 1 : 0.86, initialSpringVelocity: 0, options: [.allowUserInteraction]
    ) {
      self.card.alpha = 1
      self.card.transform = .identity
      self.backgroundColor = UIColor.black.withAlphaComponent(0.4)
    }
    UIAccessibility.post(notification: .screenChanged, argument: titleElement ?? card)
  }

  private func linkTapped() {
    guard !closing else { return }
    closing = true
    animateOut { [weak self] in
      self?.onLink?()
      self?.onLink = nil
      self?.finish = nil
    }
  }

  private func close(confirmed: Bool) {
    guard !closing else { return }
    closing = true
    animateOut { [weak self] in
      self?.finish?(confirmed)
      self?.finish = nil
    }
  }

  private func animateOut(_ done: @escaping () -> Void) {
    UIView.animate(
      withDuration: UIAccessibility.isReduceMotionEnabled ? 0.01 : 0.18, delay: 0, options: [.curveEaseIn],
      animations: {
        self.card.alpha = 0
        self.card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        self.backgroundColor = UIColor.black.withAlphaComponent(0)
      }
    ) { _ in
      self.removeFromSuperview()
      done()
    }
  }

  /// False when one is up already (the answer is then "no", and nothing is sent).
  @discardableResult
  static func show(
    title: String, points: [Point], link: String?, footnote: String?, cancel: String = "暂不", confirm: String = "同意", in window: UIWindow,
    onLink: (() -> Void)?, finish: @escaping (Bool) -> Void
  ) -> Bool {
    if showing?.superview != nil { return false }
    window.endEditing(true)
    let safe = window.safeAreaInsets
    let room = CGRect(
      x: safe.left, y: safe.top, width: window.bounds.width - safe.left - safe.right, height: window.bounds.height - safe.top - safe.bottom)
    let dialog = GlassNoticeDialog(
      frame: window.bounds, title: title, points: points, link: link, footnote: footnote, cancel: cancel, confirm: confirm, free: room,
      inset: 20, onLink: onLink, finish: finish)
    dialog.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(dialog)
    showing = dialog
    dialog.present()
    return true
  }
}
