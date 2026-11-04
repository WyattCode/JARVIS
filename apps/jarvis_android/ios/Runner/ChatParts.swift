import Combine
import SwiftUI
import UIKit

// MARK: Chat status

enum ChatStatus {
  /// Why sending is not possible right now, when it is something to tell the person.
  static func sendBlockedReason(hasDraft: Bool, generating: Bool, authenticated: Bool, hasModel: Bool, loading: Bool) -> String? {
    if !hasDraft || generating { return nil }
    if !authenticated || !hasModel { return "模型未连接，暂时无法发送" }
    if loading { return "附件处理中，稍后即可发送" }
    return nil
  }
}

// MARK: One-time notices

/// The notice about what is sent to the AI service: asked before the first message or call on this device, remembered once
/// accepted. False when the person declines (nothing is sent).
@MainActor
enum AiNotice {
  static func ensure(store: JarvisStore, from presenter: UIViewController) async -> Bool {
    if store.settings.aiNoticeAccepted { return true }
    let server = store.api.endpoint.jarvisOrigin
    while true {
      // Looked at again at each round: a second asker may have had the notice accepted while the privacy page was open here.
      if store.settings.aiNoticeAccepted { return true }
      let choice = await ask(server: server, presenter: presenter)
      switch choice {
      case "link":
        let page = NativeChatSettings.privacyPage(store: store)
        let container = PageContainer(title: "隐私与数据使用", content: page)
        if let nav = presenter as? UINavigationController ?? presenter.navigationController {
          nav.pushViewController(container, animated: true)
        } else {
          container.modalPresentationStyle = .fullScreen
          presenter.present(container, animated: true)
        }
        // The notice comes back once the page has been read and closed. If the page never came up (a push that the navigation
        // controller dropped in the middle of another move), it comes back at once, and the person's send is not lost to a wait.
        Task { @MainActor [weak page] in
          try? await Task.sleep(nanoseconds: 1_500_000_000)
          if let page, !page.hasAppeared { page.release() }
        }
        await page.closed()
        continue
      case "confirm":
        store.changeSettings { $0.aiNoticeAccepted = true }
        return true
      default: return false
      }
    }
  }

  private static func ask(server: String, presenter: UIViewController) async -> String {
    await withCheckedContinuation { continuation in
      var answered = false
      func answer(_ value: String) {
        guard !answered else { return }
        answered = true
        continuation.resume(returning: value)
      }
      guard let window = presenter.view.window else { return answer("cancel") }
      // The privacy line closes the notice, shows the page, and brings the notice back.
      let shown = GlassNoticeDialog.show(
        title: "使用前请知悉",
        points: [
          .init(symbol: "sparkles", text: "JARVIS 是人工智能助手，回复由 AI 生成，可能有误，重要的事请自行核实。"),
          .init(symbol: "paperplane", text: "你输入的文字、添加的图片和文件，以及通话中的语音，会发送到 JARVIS 服务（\(server)）来生成回复。"),
          .init(symbol: "iphone", text: "会话保存在这台设备上，可以随时在“设置 → 数据”里删除。"),
        ],
        link: "查看隐私与数据使用", footnote: "选“暂不”，不会发送任何内容。", in: window,
        onLink: { answer("link") }, finish: { confirmed in answer(confirmed ? "confirm" : "cancel") })
      // One is up already: this asker says no, and the one on the page answers for itself.
      if !shown { answer("cancel") }
    }
  }
}

/// A pushed page that says when it has gone.
@MainActor
final class ClosingHostController<Content: View>: UIHostingController<Content> {
  /// Every way up, the upside-down portrait too (the system leaves it out for an iPhone unless the page in front says so).
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var gone = false
  /// The page has been on the screen at least once.
  private(set) var hasAppeared = false

  func closed() async {
    if gone { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  /// Says it has gone (also for a page that never came up).
  func release() {
    gone = true
    waiting.forEach { $0.resume() }
    waiting = []
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    hasAppeared = true
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Gone when it is leaving its parent; or when it is off the screen with nothing standing over it. Popped by the system's back
    // button (in the strip) the page's parent was not flagged as leaving, so it is also read from the screen. Covered by a full-screen
    // page of something else it is not gone (it comes back when that is closed).
    let nav = navigationController ?? parent?.navigationController
    let covered = presentedViewController != nil || parent?.presentedViewController != nil || nav?.presentedViewController != nil
    guard isMovingFromParent || isBeingDismissed || parent?.isMovingFromParent == true || parent?.isBeingDismissed == true
      || (view.window == nil && !covered)
    else { return }
    release()
  }
}

// MARK: Header

/// The connection, as the dot in the header says it.
enum StoreLink { case connecting, ready, down }

extension JarvisStore {
  var link: StoreLink { connecting ? .connecting : modelReady ? .ready : .down }
}

/// The header's title: on a foldable iPhone the conversation's name; on a phone the app name and, beside it once there are
/// messages, the conversation's name small; then the connection dot.
final class ChatHeadingView: UIView {
  private let name = UILabel()
  private let sub = UILabel()
  private let dot = StatusDotView()
  private let row = UIStackView()
  var onTap: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    name.font = .systemFont(ofSize: 16, weight: .semibold)
    name.textColor = Palette.onSurface
    name.lineBreakMode = .byTruncatingTail
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    sub.font = .systemFont(ofSize: 12)
    sub.textColor = Palette.onSurfaceVariant
    sub.lineBreakMode = .byTruncatingTail
    sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    row.addArrangedSubview(name)
    row.addArrangedSubview(sub)
    row.addArrangedSubview(dot)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
      dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func tapped() { onTap?() }

  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

  func update(title: String, hasMessages: Bool, foldable: Bool, link: StoreLink) {
    if foldable {
      name.text = title
      sub.isHidden = true
    } else {
      name.text = "JARVIS"
      sub.text = title
      sub.isHidden = !hasMessages
    }
    dot.link = link
    let state: String
    switch link {
    case .connecting: state = "正在连接"
    case .ready: state = "模型已连接"
    case .down: state = "模型未连接"
    }
    accessibilityLabel = "\(foldable ? title : "JARVIS")，\(state)"
  }
}

/// The 10 pt dot: filled green when the model is ready, a ring in amber while connecting, red with a dash when it is not.
final class StatusDotView: UIView {
  var link: StoreLink = .down { didSet { setNeedsDisplay() } }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ rect: CGRect) {
    guard let c = UIGraphicsGetCurrentContext() else { return }
    let box = bounds
    switch link {
    case .ready:
      c.setFillColor(Palette.success.resolvedColor(with: traitCollection).cgColor)
      c.fillEllipse(in: box)
    case .connecting:
      c.setStrokeColor(Palette.warning.resolvedColor(with: traitCollection).cgColor)
      c.setLineWidth(2)
      c.strokeEllipse(in: box.insetBy(dx: 1, dy: 1))
    case .down:
      c.setFillColor(Palette.error.resolvedColor(with: traitCollection).cgColor)
      c.fillEllipse(in: box)
      c.setFillColor(Palette.surface.resolvedColor(with: traitCollection).cgColor)
      c.fill(CGRect(x: box.midX - 2.5, y: box.midY - 0.75, width: 5, height: 1.5))
    }
  }
}

/// Lets a display link hold its target weakly (the link retains whatever it is given).
@MainActor
final class DisplayProxy: NSObject {
  private weak var target: ChatViewController?
  init(_ target: ChatViewController) { self.target = target }
  @objc func tick(_ link: CADisplayLink) {
    guard let target else { return link.invalidate() }
    target.pacerTick()
  }
}
