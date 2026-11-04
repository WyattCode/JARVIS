import LocalAuthentication
import Security
import UIKit

/// Signing in with Face ID or Touch ID. The password is kept in the keychain under an access control that asks for the device's
/// biometrics each time it is read (and that stops being readable if the set of enrolled faces or fingers changes, and never
/// leaves this device); nothing else about it is kept anywhere. Reading it brings up the system's own prompt.
enum BiometricLogin {
  private static let service = "com.example.jarvis.sign-in"
  private static let declinedKey = "jarvis.biometric.declined"
  private static let usernameKey = "jarvis.biometric.username"
  private static let wantedKey = "jarvis.biometric.wanted"

  /// The person turned it on in the settings: the next sign-in with the password keeps it (no question asked then).
  static var wanted: Bool {
    get { UserDefaults.standard.bool(forKey: wantedKey) }
    set { UserDefaults.standard.set(newValue, forKey: wantedKey) }
  }

  /// What the switch shows: a password is kept, or one is to be kept at the next sign-in.
  static var enabled: Bool { savedUsername != nil || wanted }

  private static var cachedKind: LABiometryType?
  private static var watching = false

  /// What the device can check. Asked of the system once and kept (it was asked at every use: the settings page alone did it several
  /// times for each change of a field), and asked again when the app comes to the front (the person may have set a face up).
  private static var kind: LABiometryType {
    if !watching {
      watching = true
      NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
        cachedKind = nil
      }
    }
    if let cachedKind { return cachedKind }
    let context = LAContext()
    var error: NSError?
    var found: LABiometryType =
      context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) ? context.biometryType : .none
    // Locked out for too many wrong tries: the device still has it (the card and the choice to turn it off stay; a lock ends with the
    // passcode).
    if found == .none, let code = error?.code, code == LAError.biometryLockout.rawValue, context.biometryType != .none {
      found = context.biometryType
    }
    cachedKind = found
    return found
  }

  /// This device can check a face or a fingerprint (and has one enrolled).
  static var available: Bool { kind != .none }

  static var name: String {
    switch kind {
    case .faceID: return "Face ID"
    case .touchID: return "Touch ID"
    case .opticID: return "Optic ID"
    default: return "生物识别"
    }
  }

  static var symbol: String {
    switch kind {
    case .faceID: return "faceid"
    case .touchID: return "touchid"
    case .opticID: return "opticid"
    default: return "lock.shield"
    }
  }

  /// The person said no to the offer after a sign-in: it is not made again (the switch in the settings brings it back).
  static var declined: Bool {
    get { UserDefaults.standard.bool(forKey: declinedKey) }
    set { UserDefaults.standard.set(newValue, forKey: declinedKey) }
  }

  /// The account whose password is kept, if one is. Remembered beside the keychain item (in the app's own defaults), not read from
  /// it: asking a keychain item that needs biometrics for even its name, with no prompt allowed, is refused on a phone, and the
  /// page then never knew the password had been kept.
  static var savedUsername: String? {
    let name = UserDefaults.standard.string(forKey: usernameKey)
    return (name ?? "").isEmpty ? nil : name
  }

  /// Why the last `save` failed (the keychain's status).
  private(set) static var lastStatus: OSStatus = errSecSuccess

  /// Keeps the password. A trial item is written (and deleted) first: if the keychain would refuse the real one, the one kept
  /// until now is not touched, where it used to be deleted before the new one was tried.
  @discardableResult
  static func save(_ username: String, _ password: String) -> Bool {
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error)
    else {
      lastStatus = errSecParam
      return false
    }
    func item(_ service: String, _ account: String, _ secret: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        kSecValueData as String: Data(secret.utf8), kSecAttrAccessControl as String: access,
      ]
    }
    let trial: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".trial"]
    SecItemDelete(trial as CFDictionary)
    lastStatus = SecItemAdd(item(service + ".trial", "trial", "x") as CFDictionary, nil)
    SecItemDelete(trial as CFDictionary)
    guard lastStatus == errSecSuccess else { return false }
    let old: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    SecItemDelete(old as CFDictionary)
    lastStatus = SecItemAdd(item(service, username, password) as CFDictionary, nil)
    guard lastStatus == errSecSuccess else {
      UserDefaults.standard.removeObject(forKey: usernameKey)
      return false
    }
    UserDefaults.standard.set(username, forKey: usernameKey)
    return true
  }

  static func remove() {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    SecItemDelete(query as CFDictionary)
    UserDefaults.standard.removeObject(forKey: usernameKey)
  }

  enum Kept {
    case found(username: String, password: String)
    /// The person dismissed the system prompt.
    case cancelled
    /// Nothing is kept any more: the enrolled faces or fingers changed, or the passcode was taken off.
    case invalidated
    case failed(OSStatus)
  }

  /// The kept account and password, after the system's Face ID or Touch ID prompt.
  static func load(reason: String) async -> Kept {
    await Task.detached {
      let context = LAContext()
      context.localizedReason = reason
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true,
        kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context,
      ]
      var found: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &found)
      switch status {
      case errSecSuccess:
        guard let item = found as? [String: Any], let account = item[kSecAttrAccount as String] as? String,
          let data = item[kSecValueData as String] as? Data, let password = String(data: data, encoding: .utf8)
        else { return .failed(errSecDecode) }
        return .found(username: account, password: password)
      case errSecUserCanceled: return .cancelled
      case errSecItemNotFound: return .invalidated
      default: return .failed(status)
      }
    }.value
  }
}

/// The form itself, with no Flutter in it: what it reports goes to `emit` (`submit` {username, password}), what its owner tells it
/// comes through `handle` (`update`, `dismiss`, `clear`). Its height is its own (the stack inside it sets it), so the page around
/// it can place it above the keyboard and give the rest to the emblem.
final class NativeLoginForm: NSObject, UITextFieldDelegate {
  private let root: UIView
  var emit: (String, Any?) -> Void = { _, _ in }
  private let titleLabel = UILabel()
  private let subtitle = UILabel()
  private let username = UITextField()
  private let password = UITextField()
  private let eye = UIButton(type: .system)
  private let submit = UIButton(type: .system)
  private let stack = UIStackView()
  private var compact = false
  private var submitHeight: NSLayoutConstraint!
  private let bio = UIButton(type: .system)
  private var biometricName: String?
  private var passBox = UIView()
  private var keyboard = false
  private var connecting = false

  private static let greeting = "从这里，继续你的探索。"

  init(frame: CGRect, args: [String: Any]) {
    root = UIView(frame: frame)
    super.init()
    root.backgroundColor = .clear
    build()
    apply(args)
  }

  func view() -> UIView { root }

  @discardableResult
  func handle(_ method: String, _ arguments: Any?) -> Bool {
    switch method {
    case "update": apply(arguments as? [String: Any] ?? [:])
    case "dismiss": root.endEditing(true)
    case "clear":
      password.text = ""
      refreshButton()
    default: return false
    }
    return true
  }

  // MARK: Building

  /// The show/hide eye, drawn here: a small almond of smooth arcs with a round iris and pupil, fine rounded lines, and a slash when the password is shown
  /// (the system's symbol was too large and too heavy beside the field's other icons). A template: it takes the button's colour.
  private static func eyeImage(slashed: Bool) -> UIImage {
    let size = CGSize(width: 20, height: 14)
    let image = UIGraphicsImageRenderer(size: size).image { context in
      let c = context.cgContext
      let w = size.width, mid = size.height / 2
      c.setStrokeColor(UIColor.black.cgColor)
      c.setFillColor(UIColor.black.cgColor)
      c.setLineWidth(1.4)
      c.setLineCap(.round)
      c.setLineJoin(.round)
      // The lids are two smooth arcs that meet in soft corners, mirror images of each other about the middle line, where the iris is.
      let left = CGPoint(x: 1.6, y: mid), right = CGPoint(x: w - 1.6, y: mid)
      let lid = UIBezierPath()
      lid.move(to: left)
      lid.addCurve(to: right, controlPoint1: CGPoint(x: 5.4, y: mid - 6.6), controlPoint2: CGPoint(x: w - 5.4, y: mid - 6.6))
      lid.addCurve(to: left, controlPoint1: CGPoint(x: w - 5.4, y: mid + 6.6), controlPoint2: CGPoint(x: 5.4, y: mid + 6.6))
      lid.close()
      c.addPath(lid.cgPath)
      c.strokePath()
      // The iris, and a small pupil in it.
      c.strokeEllipse(in: CGRect(x: w / 2 - 2.5, y: mid - 2.5, width: 5, height: 5))
      c.fillEllipse(in: CGRect(x: w / 2 - 0.8, y: mid - 0.8, width: 1.6, height: 1.6))
      if slashed {
        // The slash cuts a thin gap in the eye where it crosses.
        let from = CGPoint(x: 5.4, y: size.height - 2.2), to = CGPoint(x: w - 5.4, y: 2.2)
        c.saveGState()
        c.setBlendMode(.clear)
        c.setLineWidth(3.4)
        c.move(to: from)
        c.addLine(to: to)
        c.strokePath()
        c.restoreGState()
        c.setLineWidth(1.4)
        c.move(to: from)
        c.addLine(to: to)
        c.strokePath()
      }
    }
    return image.withRenderingMode(.alwaysTemplate)
  }

  private func glassBox(icon: String, field: UITextField, trailing: UIView? = nil) -> UIView {
    // The original's field: the card colour, the hairline, a rounded corner; nothing glassy.
    let box = UIVisualEffectView(effect: nil)
    // (the edge of a field is told by 3:1 against the card, which the lighter hairline did not give in the light theme)
    box.styleSurface(Palette.card, radius: Radii.medium + 2, border: Palette.outline)
    box.clipsToBounds = true
    let image = UIImageView(
      image: UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)))
    image.tintColor = Palette.onSurfaceVariant
    image.contentMode = .center
    image.setContentHuggingPriority(.required, for: .horizontal)
    // Follows the system's text size (up to a limit: the form has to stay on the page).
    field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16), maximumPointSize: 24)
    field.adjustsFontForContentSizeCategory = true
    field.textColor = Palette.onSurface
    field.tintColor = Palette.accent
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    // Both fields are set up alike. They used to differ (ASCII on the account, the default on the password), and going from one
    // to the other the system changed the whole keyboard over, which showed as a flash of the keys.
    field.keyboardType = .asciiCapable
    field.smartQuotesType = .no
    field.smartDashesType = .no
    field.smartInsertDeleteType = .no
    field.inlinePredictionType = .no
    field.keyboardAppearance = .default
    field.delegate = self
    field.addTarget(self, action: #selector(edited), for: .editingChanged)
    var views: [UIView] = [image, field]
    if let trailing { views.append(trailing) }
    let row = UIStackView(arrangedSubviews: views)
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    row.isLayoutMarginsRelativeArrangement = true
    row.layoutMargins = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: trailing == nil ? 16 : 6)
    row.translatesAutoresizingMaskIntoConstraints = false
    box.contentView.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: box.contentView.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: box.contentView.trailingAnchor),
      row.topAnchor.constraint(equalTo: box.contentView.topAnchor),
      row.bottomAnchor.constraint(equalTo: box.contentView.bottomAnchor),
      box.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
      image.widthAnchor.constraint(equalToConstant: 22),
    ])
    return box
  }

  private func build() {
    titleLabel.text = "登录"
    titleLabel.textAlignment = .center
    titleLabel.textColor = Palette.onSurface
    titleLabel.accessibilityTraits = .header
    // Never squeezed: with too little room the form goes taller than the column's gap, or the page drops the heading.
    titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    subtitle.setContentCompressionResistancePriority(.required, for: .vertical)
    subtitle.textAlignment = .center
    subtitle.numberOfLines = 0
    subtitle.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15), maximumPointSize: 22)
    subtitle.adjustsFontForContentSizeCategory = true

    username.attributedPlaceholder = NSAttributedString(string: "账户", attributes: [.foregroundColor: Palette.onSurfaceVariant.withAlphaComponent(0.8)])
    username.textContentType = .username
    username.returnKeyType = .next
    password.attributedPlaceholder = NSAttributedString(string: "密码", attributes: [.foregroundColor: Palette.onSurfaceVariant.withAlphaComponent(0.8)])
    password.textContentType = .password
    password.isSecureTextEntry = true
    password.returnKeyType = .go

    var eyeConfiguration = UIButton.Configuration.plain()
    eyeConfiguration.image = Self.eyeImage(slashed: false)
    // Softer than the other icons: it is a small helper at the end of the field, not a mark of its own.
    eyeConfiguration.baseForegroundColor = Palette.onSurfaceVariant.withAlphaComponent(0.7)
    eye.configuration = eyeConfiguration
    eye.accessibilityLabel = "显示密码"
    eye.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        let show = self.password.isSecureTextEntry
        // Switching the secure flag drops the text in some cases: keep it.
        let text = self.password.text
        self.password.isSecureTextEntry = !show
        self.password.text = text
        self.eye.configuration?.image = Self.eyeImage(slashed: show)
        self.eye.accessibilityLabel = show ? "隐藏密码" : "显示密码"
      }, for: .touchUpInside)
    eye.widthAnchor.constraint(equalToConstant: 44).isActive = true

    let userBox = glassBox(icon: "person", field: username)
    passBox = glassBox(icon: "lock", field: password, trailing: eye)

    bio.addAction(UIAction { [weak self] _ in self?.emit("biometric", nil) }, for: .touchUpInside)
    bio.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    submit.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)
    submitHeight = submit.heightAnchor.constraint(greaterThanOrEqualToConstant: 54)
    submitHeight.isActive = true

    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 14
    stack.addArrangedSubview(titleLabel)
    stack.addArrangedSubview(subtitle)
    stack.addArrangedSubview(userBox)
    stack.addArrangedSubview(passBox)
    stack.addArrangedSubview(submit)
    stack.addArrangedSubview(bio)
    spaceOut()
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      stack.topAnchor.constraint(equalTo: root.topAnchor),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    styleTitle()
    refreshButton()
    refreshBio()
  }

  // MARK: State

  private func apply(_ args: [String: Any]) {
    compact = args["compact"] as? Bool ?? compact
    error = args["error"] as? String
    connecting = args["connecting"] as? Bool ?? connecting
    if args.keys.contains("biometric") { biometricName = args["biometric"] as? String }
    styleTitle()
    let shown = error ?? Self.greeting
    if subtitle.text != shown, error != nil, UIAccessibility.isVoiceOverRunning {
      // A failed sign-in, or a word about Face ID, is spoken: nothing else tells a person who cannot see the page.
      UIAccessibility.post(notification: .announcement, argument: shown)
    }
    subtitle.text = shown
    subtitle.textColor = error == nil ? Palette.onSurfaceVariant : Palette.error
    spaceOut()
    username.isUserInteractionEnabled = !connecting
    password.isUserInteractionEnabled = !connecting
    refreshButton()
    refreshBio()
    syncHeading()
    // The form's height is its own: the page around it moves with it.
    root.setNeedsLayout()
    UIView.animate(withDuration: 0.18) { (self.root.superview ?? self.root).layoutIfNeeded() }
  }

  /// The gaps: tighter with the keyboard up (the emblem is gone and the form has to hold its heading in what is left).
  private func spaceOut() {
    stack.spacing = keyboard ? 12 : 14
    stack.setCustomSpacing(keyboard ? 6 : 8, after: titleLabel)
    stack.setCustomSpacing(keyboard ? 14 : (compact ? 18 : 26), after: subtitle)
    stack.setCustomSpacing(keyboard ? 16 : 20, after: passBox)
    stack.setCustomSpacing(6, after: submit)
    submitHeight.constant = keyboard ? 50 : 54
  }

  /// A field has the keyboard, or something has been typed: the page does not bring up Face ID over it.
  var isEditing: Bool {
    username.isFirstResponder || password.isFirstResponder || !(username.text ?? "").isEmpty || !(password.text ?? "").isEmpty
  }

  func setKeyboard(_ up: Bool) {
    guard up != keyboard else { return }
    keyboard = up
    spaceOut()
    refreshBio()
  }

  /// The button that signs in with Face ID or Touch ID: there when a password is kept for it, and not with the keyboard up (the
  /// room is for the fields) or while a sign-in is under way.
  private func refreshBio() {
    UIView.performWithoutAnimation {
      bio.isHidden = biometricName == nil || keyboard || connecting
      bio.alpha = bio.isHidden ? 0 : 1
      // Nothing kept: the button is emptied as well as hidden (a glass button that was hidden stayed on the page).
      guard let name = biometricName else {
        bio.configuration = nil
        return
      }
      // No background: the accent-coloured symbol and words alone, the symbol the size of the text.
      var configuration = UIButton.Configuration.plain()
      configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18)
      configuration.title = "使用 \(name) 登录"
      configuration.image = UIImage(systemName: BiometricLogin.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
      configuration.imagePadding = 7
      configuration.baseForegroundColor = Palette.accent
      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 15, weight: .medium))
        return attributes
      }
      bio.configuration = configuration
      bio.accessibilityLabel = "使用 \(name) 登录"
    }
  }

  private var error: String?
  /// No room for the heading: only the fields and the button stay (a short window with the keyboard up). A message from the
  /// server stays; it is what the person must read.
  private var tight = false
  private func syncHeading() {
    // Never animated: inside the keyboard's animation a stack view animates a hidden label's height, and the heading stayed
    // half squeezed.
    UIView.performWithoutAnimation {
      titleLabel.isHidden = tight
      subtitle.isHidden = tight && error == nil
    }
  }


  var isTight: Bool { tight }

  /// Whether it changed.
  @discardableResult
  func setTight(_ value: Bool) -> Bool {
    guard value != tight else { return false }
    tight = value
    syncHeading()
    return true
  }

  /// How tall the form is now, as it stands (heading shown or not), at `width`.
  func currentHeight(width: CGFloat) -> CGFloat {
    stack.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
    ).height
  }

  /// How tall the form is with its heading showing, at `width`: what the page needs to know to decide whether the heading fits. Worked
  /// out from the heading's parts, not by showing and hiding them (that dirtied the stack at every layout pass).
  func fullHeight(width: CGFloat) -> CGFloat {
    var height = currentHeight(width: width)
    let fit = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
    if titleLabel.isHidden { height += titleLabel.sizeThatFits(fit).height + stack.customSpacing(after: titleLabel) }
    if subtitle.isHidden { height += subtitle.sizeThatFits(fit).height + stack.customSpacing(after: subtitle) }
    return height
  }

  private func styleTitle() {
    titleLabel.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: compact ? 26 : 30, weight: .semibold), maximumPointSize: 40)
    titleLabel.adjustsFontForContentSizeCategory = true
  }

  private var canSubmit: Bool {
    !connecting && !(username.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty && !(password.text ?? "").isEmpty
  }

  private func refreshButton() {
    // A filled button: the primary colour when it can be pressed, the soft one with dimmed text when it cannot.
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .fixed
    configuration.background.cornerRadius = Radii.medium + 2
    // Not pressable: a step lighter than the page and the text only half dimmed (it was so grey that it looked unfinished).
    configuration.baseBackgroundColor = canSubmit || connecting ? Palette.primary : Palette.containerHighest
    configuration.baseForegroundColor =
      canSubmit || connecting ? Palette.onPrimary : Palette.onSurface.withAlphaComponent(0.62)
    configuration.title = connecting ? "正在登录…" : "登录"
    configuration.showsActivityIndicator = connecting
    configuration.imagePadding = 10
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16, weight: .semibold), maximumPointSize: 24)
      return attributes
    }
    submit.configuration = configuration
    submit.isEnabled = true
    submit.isUserInteractionEnabled = canSubmit
    // Said to VoiceOver as well (it was only not touchable, and was read out as a working button).
    submit.accessibilityTraits = canSubmit ? .button : [.button, .notEnabled]
  }

  // MARK: Input

  @objc private func edited() {
    refreshButton()
    // The words of the last failed sign-in are not kept up while a new one is typed: the page's own greeting is back.
    if error != nil {
      error = nil
      subtitle.text = Self.greeting
      subtitle.textColor = Palette.onSurfaceVariant
      spaceOut()
      // The page that keeps the words (its own notice, the store's error) forgets them too, or its next update brings them back.
      emit("edited", nil)
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === username {
      password.becomeFirstResponder()
    } else {
      send()
    }
    return false
  }

  private func send() {
    guard canSubmit else { return }
    root.endEditing(true)
    emit("submit", ["username": username.text ?? "", "password": password.text ?? ""])
  }
}
