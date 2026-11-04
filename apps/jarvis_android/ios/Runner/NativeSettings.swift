import SwiftUI
import UIKit

// The settings as a native SwiftUI page, pushed on the system's own navigation controller (slide, parallax, edge swipe
// back, and on an iPhone Duo the system moves the bar into the vertical strip by itself).
//
// The page keeps no data of its own. Flutter owns it: it sends a snapshot (`open`, `update`) and carries out the actions
// the page sends back (`act`); see lib/native_settings.dart.

// MARK: State

struct SettingsState: Codable {
  struct Option: Codable, Hashable {
    var id: String
    var name: String
  }
  struct Chat: Codable {
    var models: [Option]
    var model: String
    var effort: String
    var tools: Bool
    var fontSize: Double
    var maxTokens: Int
    var instructions: String
  }
  struct Voice: Codable, Hashable {
    var id: String
    var name: String
    var description: String
  }
  struct Speech: Codable {
    var engines: [Option]
    var engine: String?
    var voices: [Voice]
    var voice: String?
    var missing: Bool
    var previewId: String?
    var previewLoading: Bool
    var previewPlaying: Bool
    var previewError: String?
  }
  struct Recognition: Codable {
    var language: String
    var prompt: String
    var echo: Bool
  }
  struct Hands: Codable {
    var threshold: Double
    var waitMs: Int
  }
  struct DataState: Codable {
    var job: String?
    var wipeBlocked: Bool
    var canClear: Bool
  }
  struct PrivacyItem: Codable, Hashable {
    var title: String?
    var text: String
  }
  struct PrivacySection: Codable, Hashable {
    var title: String
    var footer: String?
    var items: [PrivacyItem]
  }
  struct Links: Codable {
    var policy: String
    var email: String
  }

  var theme: String
  var chat: Chat
  var speech: Speech
  var recognition: Recognition
  var hands: Hands
  var data: DataState
  var privacy: [PrivacySection]
  var links: Links
}

// MARK: Store

final class SettingsStore: ObservableObject {
  @Published var state: SettingsState
  @Published var toast: String?
  /// Counts the times the page was handed to the user: the fields that hold text read their values again.
  @Published var session = 0
  /// Sends an action to Flutter; answers the JSON Flutter returned.
  var transport: ((String, @escaping (String?) -> Void) -> Void)?
  var openPrivacy: (() -> Void)?
  private var toastTask: Task<Void, Never>?

  init(state: SettingsState) {
    self.state = state
  }

  func apply(_ json: String) {
    guard let data = json.data(using: .utf8), let next = try? JSONDecoder().decode(SettingsState.self, from: data)
    else { return }
    state = next
  }

  /// Carries out [a] in Flutter. [local] shows the change at once; the next snapshot from Flutter is the truth.
  func act(
    _ a: String, _ v: Any? = nil, extra: [String: Any] = [:], local: ((inout SettingsState) -> Void)? = nil,
    done: ((Bool) -> Void)? = nil
  ) {
    if let local { local(&state) }
    var message: [String: Any] = ["a": a]
    if let v { message["v"] = v }
    for (key, value) in extra { message[key] = value }
    guard let data = try? JSONSerialization.data(withJSONObject: message),
      let json = String(data: data, encoding: .utf8)
    else { return }
    transport?(json) { [weak self] answer in
      guard let self, let answer, let data = answer.data(using: .utf8),
        let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return }
      if let text = result["text"] as? String { UIPasteboard.general.string = text }
      if let notice = result["notice"] as? String { self.show(notice) }
      done?(result["ok"] as? Bool ?? true)
    }
  }

  func show(_ text: String) {
    toastTask?.cancel()
    toast = text
    if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: text) }
    toastTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 2_600_000_000)
      if !Task.isCancelled { self?.toast = nil }
    }
  }
}

// MARK: Bridge

/// The slide of a page over the chat: from the right edge in, to the right edge out, with a soft shadow on its leading
/// edge and a light dim on what it covers. The edge swipe drives the way out under the finger.
final class SlideTransition: NSObject, UIViewControllerAnimatedTransitioning {
  var presenting = true
  var onFinished: (() -> Void)?
  private(set) var interaction: UIPercentDrivenInteractiveTransition?
  private var dismiss: (() -> Void)?

  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
    UIAccessibility.isReduceMotionEnabled ? 0.01 : 0.3
  }

  func attachEdgeSwipe(to nav: UINavigationController, dismiss: @escaping () -> Void) {
    self.dismiss = dismiss
    let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swipe(_:)))
    edge.edges = .left
    nav.view.addGestureRecognizer(edge)
  }

  @objc private func swipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
    guard let view = gesture.view else { return }
    // Inside a pushed page the navigation controller's own swipe goes back one page.
    if let nav = (view.next as? UINavigationController), nav.viewControllers.count > 1 { return }
    let progress = max(0, min(1, gesture.translation(in: view).x / view.bounds.width))
    switch gesture.state {
    case .began:
      interaction = UIPercentDrivenInteractiveTransition()
      interaction?.completionCurve = .easeOut
      dismiss?()
    case .changed:
      interaction?.update(progress)
    case .ended, .cancelled:
      let flick = gesture.velocity(in: view).x > 500
      if gesture.state == .ended, progress > 0.4 || flick {
        interaction?.finish()
      } else {
        interaction?.cancel()
      }
      interaction = nil
    default:
      break
    }
  }

  func animateTransition(using context: UIViewControllerContextTransitioning) {
    let container = context.containerView
    // Over full screen, what is covered is not part of the transition: the page is the only view it hands over.
    guard let page = context.view(forKey: presenting ? .to : .from) else {
      return context.completeTransition(false)
    }
    let width = container.bounds.width
    let dim = UIView(frame: container.bounds)
    dim.backgroundColor = .black
    dim.isUserInteractionEnabled = false
    page.layer.shadowColor = UIColor.black.cgColor
    page.layer.shadowOpacity = 0.25
    page.layer.shadowRadius = 8
    page.layer.shadowOffset = CGSize(width: -3, height: 0)
    if presenting {
      container.addSubview(dim)
      container.addSubview(page)
      page.frame = container.bounds.offsetBy(dx: width, dy: 0)
      dim.alpha = 0
    } else {
      container.insertSubview(dim, belowSubview: page)
      dim.alpha = 0.12
    }
    let animations = {
      if self.presenting {
        page.frame = container.bounds
        dim.alpha = 0.12
      } else {
        page.frame = container.bounds.offsetBy(dx: width, dy: 0)
        dim.alpha = 0
      }
    }
    let finish = {
      let done = !context.transitionWasCancelled
      page.layer.shadowOpacity = 0
      dim.removeFromSuperview()
      if !self.presenting && !done { page.frame = container.bounds }
      context.completeTransition(done)
      if !self.presenting && done { self.onFinished?() }
    }
    if context.isInteractive || UIAccessibility.isReduceMotionEnabled {
      // Under the finger the page follows linearly; with Reduce Motion it is all but at once.
      UIView.animate(
        withDuration: transitionDuration(using: context), delay: 0,
        options: context.isInteractive ? .curveLinear : .curveEaseOut, animations: animations
      ) { _ in finish() }
    } else {
      // The same spring as the conversation drawer (Flutter's drawer settles with a critically damped spring of
      // stiffness 500, mass 1), so the two slides move alike.
      let spring = UISpringTimingParameters(
        mass: 1, stiffness: 500, damping: 2 * 500.0.squareRoot(), initialVelocity: .zero)
      let animator = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
      animator.addAnimations(animations)
      animator.addCompletion { _ in finish() }
      animator.startAnimation()
    }
  }
}

// MARK: Settings page

private let haptic = UISelectionFeedbackGenerator()

struct SettingsView: View {
  @ObservedObject var store: SettingsStore
  @State private var tokens = ""
  @State private var tokensError: String?
  @State private var tokensTask: Task<Void, Never>?
  @State private var instructions = ""
  @State private var prompt = ""
  /// One waiting send for each field: a letter typed in one must not drop what the other was about to send.
  @State private var typing: [String: Task<Void, Never>] = [:]
  @State private var biometricOn = BiometricLogin.enabled
  @State private var biometricHint = false
  /// Which text field has the keyboard (one state for all of them: the button that puts the keyboard away works for each).
  private enum Field { case tokens, instructions, prompt }
  @FocusState private var focus: Field?

  private static let sizes: [Double] = [12, 14, 16, 18, 20, 22, 24]
  private static let languages: [(String, String)] = [
    ("", "多语言自动"), ("zh", "中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"), ("fr", "法语"),
    ("de", "德语"), ("es", "西班牙语"),
  ]
  private static let waits = [300, 500, 800, 1000, 1500, 2000, 3000, 4000, 5000]

  private var s: SettingsState { store.state }

  private static func waitName(_ n: Int) -> String {
    n % 1000 == 0 ? "\(n / 1000) 秒" : String(format: "%g 秒", Double(n) / 1000)
  }

  /// On an iPhone Duo the system arranges the two views for every pose: side by side where the screen is wide (the
  /// inner display, half-folded or flat), the list alone where it is not (the outer display, a tall inner display),
  /// and never across the fold. Elsewhere the list is the page.
  var body: some View {
    if #available(iOS 27.1, *) {
      // The preview on the left, the settings on the right, as the settings page has always been laid out on the inner
      // display: the arrangement puts its primary view first in the reading direction, so it is set right to left and
      // the two views set back to left to right.
      ArrangementView {
        list.environment(\.layoutDirection, .leftToRight)
      } secondary: {
        ChatPreview(size: s.chat.fontSize).environment(\.layoutDirection, .leftToRight)
      }
      .arrangementViewStyle(.split.axes(.horizontal))
      .environment(\.layoutDirection, .rightToLeft)
    } else {
      list
    }
  }

  @State private var tab = 0

  private var list: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 0) {
        SettingsTabs(titles: ["外观", "聊天", "语音", "数据"], selected: $tab) { i in
          withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(["appearance", "chat", "voice", "data"][i], anchor: .top) }
        }
        .padding(.horizontal, Metrics.cardMargin)
        .padding(.top, 4)
        .padding(.bottom, 8)
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            appearance.id("appearance")
            chat.id("chat")
            voices.id("voice")
            recognition
            handsFree
            dataSection.id("data")
            if BiometricLogin.available { biometricCard }
            SettingsCard {
              Button {
                ask("退出登录？", ["退出后需要重新登录才能继续使用。", "会话仍保存在这台设备上；正在进行的任务和通话会被中断。"], confirm: "退出登录", destructive: true) {
                  store.act("logout", "keep")
                }
              } label: {
                HStack(spacing: 14) {
                  Image(systemName: "rectangle.portrait.and.arrow.right").frame(width: 24)
                  Text("退出登录")
                  Spacer()
                }
                .foregroundStyle(Color(Palette.onSurface))
              }
              .buttonStyle(.plain)
              .disabled(s.data.job != nil)
            }
          }
          .padding(.horizontal, Metrics.cardMargin)
          // Room to scroll the last rows clear of the button that puts the keyboard away.
          .padding(.bottom, focus == nil ? 32 : 96)
        }
      }
      .background(Color(Palette.surface))
    }
    .scrollDismissesKeyboard(.interactively)
    // The page's own sizes are fixed (as the whole app's are), and a few rows follow the system's text size: at a large size those few
    // came out several times as big as the rest. All of them follow it, up to a size the layout holds.
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
    .onAppear(perform: loadFields)
    .onChange(of: store.session) { loadFields() }
    .overlay(alignment: .bottom) { toast }
    .overlay(alignment: .bottomTrailing) { if focus != nil { keyboardButton } }
    .animation(.easeOut(duration: 0.2), value: focus)
    .animation(.easeOut(duration: 0.2), value: store.toast)
  }

  // MARK: Face ID / Touch ID

  /// Signing in with Face ID or Touch ID. It is turned on by the offer made after a sign-in with the password (the password is not
  /// at hand here); turned off here, the kept password is deleted.
  private var biometricCard: some View {
    SettingsCard("安全") {
      Toggle(
        isOn: Binding(
          get: { biometricOn },
          set: { value in
            if value {
              // On at once. Nothing is kept until the password is next typed (it is not at hand here): that sign-in keeps it.
              BiometricLogin.wanted = true
              BiometricLogin.declined = false
              biometricOn = true
              if BiometricLogin.savedUsername == nil { biometricHint = true }
            } else {
              BiometricLogin.wanted = false
              BiometricLogin.remove()
              biometricOn = false
            }
          })
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text("使用 \(BiometricLogin.name) 登录")
          Text("打开 JARVIS 时用 \(BiometricLogin.name) 直接登录。密码保存在这台设备的钥匙串里。").font(.footnote).foregroundStyle(Color(Palette.onSurfaceVariant))
        }
      }
    }
    .onAppear { biometricOn = BiometricLogin.enabled }
    .alert("下次登录时启用", isPresented: $biometricHint) {
      Button("好") {}
    } message: {
      Text("现在已打开。密码不在这里，所以退出登录后，用密码登录一次，JARVIS 就会保存下来，之后可以用 \(BiometricLogin.name) 登录。")
    }
  }

  // MARK: Appearance

  private var appearance: some View {
    SettingsCard("外观") {
      ThemeSwatches(value: s.theme) { value in
        store.act("theme", value) { $0.theme = value }
      }
    }
  }

  // MARK: Chat

  private var chat: some View {
    SettingsCard("聊天") {
      PickRow(
        title: "聊天模型", value: s.chat.models.first { $0.id == s.chat.model }?.name ?? "",
        options: s.chat.models.map { ($0.id, $0.name) }, selected: s.chat.model
      ) { value in store.act("model", value) { $0.chat.model = value } }
      PickRow(
        title: "思考深度",
        value: ["none": "关闭", "low": "低", "medium": "中", "high": "高（默认）"][s.chat.effort] ?? s.chat.effort,
        options: [("none", "关闭"), ("low", "低"), ("medium", "中"), ("high", "高（默认）")], selected: s.chat.effort
      ) { value in store.act("effort", value) { $0.chat.effort = value } }
      Toggle(
        isOn: Binding(
          get: { s.chat.tools },
          set: { value in store.act("tools", value) { $0.chat.tools = value } })
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text("图片与视频工具")
          Text("打开后，助手可以在对话里直接生成图片和视频。").font(.footnote).foregroundStyle(Color(Palette.onSurfaceVariant))
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("聊天字号")
          Spacer()
          Text("\(Int(s.chat.fontSize))\(s.chat.fontSize == 16 ? "（默认）" : "")").foregroundStyle(Color(Palette.onSurfaceVariant))
        }
        Slider(
          value: Binding(
            get: { s.chat.fontSize },
            set: { value in
              if value != s.chat.fontSize { haptic.selectionChanged() }
              store.act("fontSize", value) { $0.chat.fontSize = value }
            }), in: 12...24, step: 2
        )
        .tint(Color(Palette.onSurface))
        .accessibilityLabel("聊天字号")
        Text("预览：你好，我是 JARVIS。")
          .font(.system(size: s.chat.fontSize))
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(Palette.surface), in: RoundedRectangle(cornerRadius: Radii.medium, style: .continuous))
      }
      .padding(.vertical, 4)
      VStack(alignment: .leading, spacing: 4) {
        Text("回复长度上限（Token）")
        TextField("回复长度上限", text: $tokens, prompt: Text("模型默认").foregroundStyle(Color(uiColor: Palette.onSurfaceVariant)))
          .keyboardType(.numberPad)
          .focused($focus, equals: .tokens)
          .onChange(of: tokens) { _, value in tokensChanged(value) }
          .onChange(of: focus) { old, new in if old == .tokens && new != .tokens { tokensBlur() } }
        if let tokensError {
          Text(tokensError).font(.footnote).foregroundStyle(Color(Palette.error))
        } else {
          Text("留空时使用模型默认值").font(.footnote).foregroundStyle(Color(Palette.onSurfaceVariant))
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("助手指令")
        TextField("助手指令", text: $instructions, prompt: Text("为助手设定角色或回答风格").foregroundStyle(Color(uiColor: Palette.onSurfaceVariant)), axis: .vertical)
          .focused($focus, equals: .instructions)
          .lineLimit(3...6)
          .onChange(of: instructions) { _, value in typed("instructions", value) }
      }
    }
  }

  private func loadFields() {
    tokens = s.chat.maxTokens == 0 ? "" : String(s.chat.maxTokens)
    instructions = s.chat.instructions
    prompt = s.recognition.prompt
  }

  private func tokensChanged(_ text: String) {
    let digits = text.filter(\.isNumber)
    if digits != text {
      tokens = digits
      return
    }
    tokensTask?.cancel()
    if text.isEmpty || (Int(text).map { (16...32768).contains($0) } ?? false) {
      tokensError = nil
      store.act("maxTokens", text) { $0.chat.maxTokens = Int(text) ?? 0 }
      return
    }
    // "1" and "10" on the way to "1024" are not mistakes: the error waits for a pause in typing.
    tokensTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 800_000_000)
      if !Task.isCancelled { tokensError = "请输入16至32768，或留空" }
    }
  }

  /// Leaving the field with a value that was never applied puts the saved one back.
  private func tokensBlur() {
    tokensTask?.cancel()
    let saved = s.chat.maxTokens
    let valid = tokens.isEmpty || (Int(tokens).map { (16...32768).contains($0) } ?? false)
    if !valid { tokens = saved == 0 ? "" : String(saved) }
    tokensError = nil
  }

  /// A text that is sent a moment after the typing stops, not with every letter.
  private func typed(_ key: String, _ value: String) {
    typing[key]?.cancel()
    typing[key] = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 350_000_000)
      if !Task.isCancelled { store.act(key, value) }
    }
  }

  // MARK: Voices

  private var voices: some View {
    SettingsCard("语音与音色") {
      if s.speech.engines.isEmpty {
        Text("服务当前没有提供语音引擎")
      } else {
        // The engine in use is named under the label, on the left edge with it (the value of a plain picker row sits
        // on the right).
        Menu {
          Picker(
            "语音引擎",
            selection: Binding(
              get: { s.speech.engine ?? "" },
              set: { value in store.act("engine", value) { $0.speech.engine = value } })
          ) {
            ForEach(s.speech.engines, id: \.id) { Text($0.name).tag($0.id) }
          }
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("语音引擎").font(.footnote).foregroundStyle(Color(Palette.onSurfaceVariant))
              Text(s.speech.engines.first { $0.id == s.speech.engine }?.name ?? "")
                .foregroundStyle(.primary)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(Color(Palette.onSurfaceVariant))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      if let engine = s.speech.engine {
        ForEach(s.speech.voices, id: \.id) { voice in
          VoiceRow(
            voice: voice, selected: s.speech.voice == voice.id,
            loading: s.speech.previewId == voice.id && s.speech.previewLoading,
            playing: s.speech.previewId == voice.id && s.speech.previewPlaying,
            select: { store.act("voice", voice.id, extra: ["engine": engine]) { $0.speech.voice = voice.id } },
            play: { store.act("preview", voice.id, extra: ["engine": engine]) }
          )
        }
        if s.speech.missing {
          Text("所选音色暂不可用，请重新选择；不会自动替换为其他声音。").font(.footnote).foregroundStyle(Color(Palette.onSurfaceVariant))
        }
        if let error = s.speech.previewError {
          Text(error).font(.footnote).foregroundStyle(Color(Palette.error))
        }
      }
    }
  }

  // MARK: Recognition

  private var recognition: some View {
    SettingsCard("语音识别") {
      PickRow(
        title: "识别语言", value: Self.languages.first { $0.0 == s.recognition.language }?.1 ?? "多语言自动",
        options: Self.languages.map { ($0.0, $0.1) }, selected: s.recognition.language
      ) { value in store.act("language", value) { $0.recognition.language = value } }
      VStack(alignment: .leading, spacing: 4) {
        Text("常用词与专有名词")
        TextField("例如：贾维斯，DGX Spark，TensorFold", text: $prompt, axis: .vertical)
          .focused($focus, equals: .prompt)
          .lineLimit(2...4)
          .onChange(of: prompt) { _, value in
            if value.count > 500 {
              prompt = String(value.prefix(500))
            } else {
              typed("prompt", value)
            }
          }
        Text("\(prompt.count)/500").font(.footnote).foregroundStyle(Color(Palette.onSurfaceVariant))
      }
      Toggle(
        isOn: Binding(
          get: { s.recognition.echo },
          set: { value in store.act("echo", value) { $0.recognition.echo = value } })
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text("回声抑制")
          Text("避免把扬声器的回复识别为你的声音").font(.footnote).foregroundStyle(Color(Palette.onSurfaceVariant))
        }
      }
    }
  }

  // MARK: Hands-free

  private var handsFree: some View {
    let level = min(max((0.8 - s.hands.threshold) / 0.6, 0), 1)
    return SettingsCard("免按对话") {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("麦克风灵敏度")
          Spacer()
          Text("\(Int((level * 100).rounded()))%").foregroundStyle(Color(Palette.onSurfaceVariant))
        }
        Slider(
          value: Binding(
            get: { level },
            set: { value in
              if abs(value - level) > 0.001 { haptic.selectionChanged() }
              let threshold = 0.8 - value * 0.6
              store.act("threshold", threshold) { $0.hands.threshold = threshold }
            }), in: 0...1, step: 0.05
        )
        .tint(Color(Palette.onSurface))
        .accessibilityLabel("麦克风灵敏度")
      }
      .padding(.vertical, 4)
      PickRow(
        title: "停顿多久算说完", value: Self.waitName(s.hands.waitMs),
        options: Self.waits.map { (String($0), Self.waitName($0)) }, selected: String(s.hands.waitMs)
      ) { value in
        let n = Int(value) ?? 800
        store.act("waitMs", n) { $0.hands.waitMs = n }
      }
    }
  }

  // MARK: Data

  private var dataSection: some View {
    let busy = s.data.job != nil
    return SettingsCard("数据") {
      Button {
        store.act("export")
      } label: {
        row("square.and.arrow.down", s.data.job == "export" ? "正在导出" : "导出会话备份", working: s.data.job == "export")
      }
      .buttonStyle(CardRowButtonStyle())
      .disabled(busy)
      Button {
        store.act("import")
      } label: {
        row("square.and.arrow.up", s.data.job == "import" ? "正在导入" : "导入会话备份", working: s.data.job == "import")
      }
      .buttonStyle(CardRowButtonStyle())
      .disabled(busy)
      Button {
        store.act("diagnostics")
      } label: {
        row("doc.on.doc", "复制诊断信息")
      }
      .buttonStyle(CardRowButtonStyle())
      Button {
        store.openPrivacy?()
      } label: {
        HStack {
          row("hand.raised", "隐私与数据使用")
          Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
      }
      .buttonStyle(CardRowButtonStyle())
      Button(role: .destructive) {
        ask("删除全部会话？", ["这会清除这台设备上的全部会话和附件，无法撤销。", "建议先导出备份。"], confirm: "删除全部", destructive: true) {
          store.act("deleteAll")
        }
      } label: {
        row("trash", "删除全部会话", destructive: true)
      }
      .buttonStyle(CardRowButtonStyle())
      .disabled(busy)
      // Apart from the plain sign-out (they sat side by side as two big buttons, and one deletes things).
      if s.data.canClear {
        Button(role: .destructive) {
          ask("退出并清除本机数据？", ["这台设备上的会话、附件和登录信息都会被删除，无法撤销。", "建议先导出备份。"], confirm: "退出并清除", destructive: true) {
            store.act("logout", "clear")
          }
        } label: {
          row("xmark.bin", "退出并清除本机数据", destructive: true)
        }
        .buttonStyle(CardRowButtonStyle())
      .disabled(busy)
      }
    }
  }

  /// A question in the app's own glass card (centred, the page dimmed, cancel beside the answer), not the system's popover with an
  /// arrow, which covered the page and had no cancel.
  private func ask(_ title: String, _ lines: [String], confirm: String, destructive: Bool = false, then: @escaping () -> Void) {
    let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
    guard let window else { return }
    GlassConfirmDialog.show(title: title, lines: lines, confirm: confirm, destructive: destructive, in: window) { ok in
      if ok { then() }
    }
  }

  private func row(_ symbol: String, _ title: String, working: Bool = false, destructive: Bool = false) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol).frame(width: 24)
      Text(title)
      if working {
        Spacer()
        ProgressView()
      }
    }
    // (the row's own style does not tint its words as the system's does: the colours are set here)
    .foregroundStyle(Color(destructive ? Palette.error : Palette.onSurface))
  }

  /// Puts the keyboard away: a round glass button with an icon, floating above the keyboard (not a bar on top of it).
  private var keyboardButton: some View {
    Button { focus = nil } label: {
      Image(systemName: "keyboard.chevron.compact.down")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(Color(Palette.onSurface))
        .frame(width: 48, height: 48)
        .jarvisGlass(Circle(), interactive: true)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("收起键盘")
    .padding(.trailing, 18)
    .padding(.bottom, 20)
    // With Reduce Motion it only fades.
    .transition(UIAccessibility.isReduceMotionEnabled ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
  }

  private var toast: some View {
    Group {
      if let text = store.toast {
        Text(text)
          .font(.subheadline)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(.regularMaterial, in: Capsule())
          .shadow(radius: 6, y: 2)
          .padding(.bottom, 24)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
  }
}
