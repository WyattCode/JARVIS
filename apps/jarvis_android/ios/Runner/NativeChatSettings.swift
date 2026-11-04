import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the settings page shows and does, on the Swift store: the port of `settingsSnapshot` and `NativeSettings.act`
/// of the Flutter app. The page (`SettingsView`) keeps no data of its own; it gets a snapshot and sends actions back.
@MainActor
final class SettingsAdapter {
  private let store: JarvisStore
  private var job: String?
  var onChange: (() -> Void)?
  /// Called when signing out or erasing ended the session: the page has nothing left to show.
  var onSessionEnded: (() -> Void)?

  init(store: JarvisStore) { self.store = store }

  private var voiceSession: VoiceSession? { store.voice as? VoiceSession }

  func snapshot() -> SettingsState {
    let s = store.settings
    let chat = store.models.filter { $0.kind == "chat" }
    let speech = store.models.filter { $0.kind == "speech" }
    let engine = speech.first { $0.id == s.speechModel }
    let voice = engine.flatMap { s.voices[$0.id] }
    let preview = voiceSession
    return SettingsState(
      theme: store.theme,
      chat: .init(
        models: chat.map { .init(id: $0.id, name: displayModelName($0.name)) }, model: store.model, effort: store.effort,
        tools: s.tools, fontSize: Double(s.messageFontSize), maxTokens: s.maxTokens, instructions: s.instructions),
      speech: .init(
        engines: speech.map { .init(id: $0.id, name: displayModelName($0.name)) }, engine: engine?.id,
        voices: (engine?.voices ?? []).map { .init(id: $0.id, name: $0.name, description: $0.description) }, voice: voice,
        missing: engine.map { e in !e.voices.contains { $0.id == voice } } ?? false, previewId: preview?.previewVoice,
        previewLoading: preview?.previewLoading ?? false,
        previewPlaying: (preview?.previewing ?? false) && !(preview?.previewLoading ?? false),
        previewError: preview?.previewError),
      recognition: .init(language: s.language, prompt: s.transcriptionPrompt, echo: s.echoCancel),
      hands: .init(threshold: s.threshold, waitMs: s.waitMs),
      data: .init(job: job, wipeBlocked: wipeBlocked, canClear: !store.storageReadOnly),
      privacy: privacySections(server: store.api.endpoint.jarvisOrigin, email: AppInfo.supportEmail).map {
        .init(title: $0.title, footer: $0.footer, items: $0.items.map { .init(title: $0.title, text: $0.text) })
      },
      links: .init(policy: AppInfo.privacyPolicyUrl, email: AppInfo.supportEmail))
  }

  /// Running replies, media tasks or a call: the conversations cannot be removed while any of them is going.
  private var wipeBlocked: Bool {
    store.voice?.active == true || store.conversations.contains { store.isGenerating($0.id) || $0.tasks.contains { $0.pending } }
  }

  /// Carries out one action of the page. Answers the JSON the page reads: `{"notice": text}` when something is to be
  /// said, `{"ok": false}` when a value was refused, `{"text": ...}` for what the page is to copy.
  func act(_ message: String) async -> String {
    guard let data = message.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return reply(["ok": false]) }
    let result = await perform(a)
    onChange?()
    return reply(result)
  }

  private func reply(_ object: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  private func perform(_ a: [String: Any]) async -> [String: Any] {
    let v = a["v"]
    switch a["a"] as? String {
    case "theme": store.setTheme(v as? String ?? "")
    case "model": store.setModel(v as? String ?? "")
    case "effort": store.setEffort(v as? String ?? "")
    case "tools": store.changeSettings { $0.tools = v as? Bool ?? true }
    case "fontSize":
      guard let size = (v as? NSNumber)?.doubleValue, [12.0, 14, 16, 18, 20, 22, 24].contains(size) else { return ["ok": false] }
      store.changeSettings { $0.messageFontSize = CGFloat(size) }
    case "maxTokens":
      guard let n = Self.parseTokens(v as? String ?? "") else { return ["ok": false] }
      store.changeSettings { $0.maxTokens = n }
    case "instructions": store.changeSettings { $0.instructions = v as? String ?? "" }
    case "language": store.changeSettings { $0.language = v as? String ?? "" }
    case "prompt": store.changeSettings { $0.transcriptionPrompt = v as? String ?? "" }
    case "echo": store.changeSettings { $0.echoCancel = v as? Bool ?? true }
    case "threshold": store.changeSettings { $0.threshold = (v as? NSNumber)?.doubleValue ?? 0.5 }
    case "waitMs": store.changeSettings { $0.waitMs = (v as? NSNumber)?.intValue ?? 800 }
    case "engine":
      guard let id = v as? String, let engine = store.models.first(where: { $0.kind == "speech" && $0.id == id }) else {
        return ["ok": false]
      }
      store.changeSettings {
        $0.speechModel = id
        if $0.voices[id] == nil { $0.voices[id] = engine.defaultVoice }
      }
    case "voice":
      guard let engine = a["engine"] as? String, let id = v as? String else { return ["ok": false] }
      store.changeSettings { $0.voices[engine] = id }
    case "preview":
      guard let id = v as? String, let engine = a["engine"] as? String, let session = voiceSession else { return ["ok": false] }
      let playing = session.previewVoice == id && (session.previewing || session.previewLoading)
      if playing {
        await session.stopPreview()
      } else if let info = store.models.first(where: { $0.kind == "speech" && $0.id == engine })?.voices.first(where: { $0.id == id }) {
        Task { await session.playPreview(info, engine: engine) }
      }
    case "export": return await run("export") { await self.exportBackup() }
    case "import": return await run("import") { await self.importBackup() }
    case "diagnostics": return ["text": store.diagnostics(), "notice": "诊断信息已复制"]
    case "deleteAll":
      let blocked = "请先结束通话或等待当前任务完成，再删除全部会话"
      if wipeBlocked || !store.wipeConversations() { return ["notice": blocked] }
      return ["notice": "已删除全部会话"]
    case "logout":
      if (v as? String) == "clear" {
        let failure = "未能清除本机数据，请稍后重试"
        if store.storageReadOnly { return ["notice": failure] }
        if !(await store.clearLocalData()) { return ["notice": failure] }
        BiometricLogin.wanted = false
        BiometricLogin.remove()
      } else {
        await store.logout()
      }
      onSessionEnded?()
    default: return ["ok": false]
    }
    return ["ok": true]
  }

  static func parseTokens(_ v: String) -> Int? {
    if v.isEmpty { return 0 }
    guard let n = Int(v), n >= 16, n <= 32768 else { return nil }
    return n
  }

  /// Runs an export or import; a second one while one is going does nothing.
  private func run(_ name: String, _ work: () async -> String?) async -> [String: Any] {
    if job != nil { return ["ok": false] }
    job = name
    onChange?()
    defer {
      job = nil
      onChange?()
    }
    var result: [String: Any] = ["ok": true]
    if let notice = await work() { result["notice"] = notice }
    return result
  }

  private func exportBackup() async -> String? {
    let temp = FileManager.default.temporaryDirectory
    do {
      let export = try store.exportBackup(temp: temp, appName: "jarvis-ios")
      defer { export.dispose() }
      let files = export.files.map { FileSource(name: $0.lastPathComponent, bytes: nil, path: $0.path) }
      guard try await FilesService.shared.save(files) else { return nil }
      if files.count > 1 { return "备份较大，已分成 \(files.count) 个文件，导入时可一次选全" }
      if !export.skipped.isEmpty { return "已导出，\(export.skipped.count) 个附件无法读取，已跳过" }
      return nil
    } catch let e as JarvisException {
      return e.message
    } catch let e as FilesFailure {
      return e.message
    } catch {
      return "备份未能导出，原资料保持不变"
    }
  }

  private func importBackup() async -> String? {
    do {
      let files = try await FilesService.shared.openFiles(types: [.json], multiple: true)
      if files.isEmpty { return nil }
      var total = 0
      for file in files {
        defer { FilesService.discardCopy(file) }
        do {
          let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
          if size > BackupLimits().importBytes {
            throw JarvisException("备份文件超过\(BackupLimits().importBytes / (1024 * 1024))MB，无法导入")
          }
          total += try await store.importBackup(try await Task.detached { try Data(contentsOf: file) }.value)
        } catch {
          if total == 0 { throw error }
          // Earlier parts are already in; say so instead of pretending nothing happened.
          let why = (error as? JarvisException)?.message ?? "文件无效"
          return "已导入 \(total) 个会话，但“\(file.lastPathComponent)”未能导入：\(why)"
        }
      }
      return total > 0 ? "已导入 \(total) 个会话" : "没有可导入的会话"
    } catch let e as JarvisException {
      return e.message
    } catch let e as FilesFailure {
      return e.message
    } catch {
      return "备份无法导入，原资料保持不变"
    }
  }
}

/// Namespace of the settings pages' helpers.
@MainActor
enum NativeChatSettings {}

/// The settings page on the chat's navigation controller; it owns the adapter and follows the store.
@MainActor
final class SettingsHostController: UIHostingController<SettingsView> {
  /// Every way up, the upside-down portrait too (the system leaves it out for an iPhone unless the page in front says so).
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

  private let adapter: SettingsAdapter
  private let model: SettingsStore
  private var bag = Set<AnyCancellable>()

  init(store: JarvisStore, onSessionEnded: @escaping () -> Void) {
    adapter = SettingsAdapter(store: store)
    model = SettingsStore(state: adapter.snapshot())
    super.init(rootView: SettingsView(store: model))
    title = "设置"
    model.transport = { [weak self] message, answer in
      guard let adapter = self?.adapter else { return answer(nil) }
      Task { answer(await adapter.act(message)) }
    }
    model.openPrivacy = { [weak self] in
      guard let self else { return }
      let page = UIHostingController(rootView: PrivacyView(sections: model.state.privacy, links: model.state.links))
      page.title = "隐私与数据使用"
      navigationController?.pushViewController(PageContainer(title: "隐私与数据使用", content: page), animated: true)
    }
    adapter.onChange = { [weak self] in self?.refresh() }
    adapter.onSessionEnded = onSessionEnded
    // The page shows what the store holds: every change of it makes a new snapshot.
    store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.refresh() }
    }.store(in: &bag)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  private func refresh() { model.state = adapter.snapshot() }
}

extension NativeChatSettings {
  /// The privacy page on its own (from the notice).
  static func privacyPage(store: JarvisStore) -> ClosingHostController<PrivacyView> {
    let sections = privacySections(server: store.api.endpoint.jarvisOrigin, email: AppInfo.supportEmail).map {
      SettingsState.PrivacySection(title: $0.title, footer: $0.footer, items: $0.items.map { .init(title: $0.title, text: $0.text) })
    }
    let page = ClosingHostController(
      rootView: PrivacyView(sections: sections, links: .init(policy: AppInfo.privacyPolicyUrl, email: AppInfo.supportEmail)))
    page.title = "隐私与数据使用"
    return page
  }
}

/// The model status page: reads the service through the store's transport and shows the answer.
@MainActor
final class StatusHostController: UIHostingController<StatusView> {
  /// Every way up, the upside-down portrait too (the system leaves it out for an iPhone unless the page in front says so).
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

  private let store: JarvisStore
  private let model: StatusStore
  private var data: [String: JSONValue]?
  private var loading = true
  private var failed = false
  private var updatedAt: Date?
  private var generation = 0
  private var bag = Set<AnyCancellable>()

  init(store: JarvisStore) {
    self.store = store
    model = StatusStore(state: StatusHostController.state(store, nil, true, false, nil))
    super.init(rootView: StatusView(store: model))
    title = "模型状态"
    // The pull-down runs this inside the list's own task, and SwiftUI cancels that task as soon as the page changes under it (the
    // spinner state is such a change): the request then failed at once. The read runs in a task of its own, which a cancelled
    // pull does not reach; the pull waits for it.
    model.refresh = { [weak self] in await Task { await self?.refresh() }.value }
    store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.push() }
    }.store(in: &bag)
    Task { await refresh() }
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  private static func state(_ store: JarvisStore, _ data: [String: JSONValue]?, _ loading: Bool, _ failed: Bool, _ at: Date?) -> StatusState {
    let chat = store.models.first { $0.id == store.model }
    let s = ModelStatus.make(chatName: chat?.name ?? store.model, data: data, loading: loading, failed: failed, updatedAt: at)
    return StatusState(
      title: s.title, note: s.note, memory: s.memory, updated: s.updated,
      rows: ModelOrder.apply(s.rows) { $0.name }.map { .init(name: $0.name, label: $0.label, tone: $0.tone) }, loading: s.loading, hasData: s.hasData, failed: s.failed)
  }

  private func push() { model.state = Self.state(store, data, loading, failed, updatedAt) }

  /// Reads the status again. The last answer stays on the page while it runs or when it fails.
  func refresh() async {
    generation += 1
    let mine = generation
    loading = true
    failed = false
    push()
    do {
      let result = try await store.api.toolsStatus()
      guard mine == generation else { return }
      data = result
      updatedAt = Date()
      loading = false
    } catch let e as JarvisException {
      guard mine == generation else { return }
      if e.unauthorized { store.expireSession() }
      loading = false
      failed = true
    } catch {
      guard mine == generation else { return }
      loading = false
      failed = true
    }
    push()
  }
}

/// The generated works (pictures and videos, running and finished, newest first) as a system sheet on the Swift store.
/// Brings the works sheet up by itself when a picture or a video of the conversation is ready (while the person chats or talks), as the
/// work arrives. Looks at the store at every change: a work that was not ready the last time and is now, in the conversation that is
/// open. What was ready before the page looked (or before the conversation was opened) does not bring it up.
@MainActor
final class WorksAutoPop {
  private var conversation = ""
  private var ready: Set<String> = []
  private var primed = false
  /// A work came ready while the person was typing: the sheet waits for the keyboard to go (a sheet over the box would take the keys
  /// away in the middle of a sentence).
  private var waiting = false

  /// The keyboard went: what waited comes up now.
  func flush(store: JarvisStore, presenter: UIViewController?) {
    guard waiting, let presenter else { return }
    waiting = false
    show(store: store, presenter: presenter)
  }

  /// `presenter`: where the sheet comes up from, if this page is the one in front; nil: only note what is ready. `typing`: the box has
  /// the keyboard.
  func check(store: JarvisStore, presenter: UIViewController?, typing: Bool = false) {
    let current = store.current
    let nowReady = Set(current.tasks.filter { $0.status == "completed" && !$0.urls.isEmpty }.map(\.id))
    defer { ready = nowReady; conversation = current.id }
    guard primed, conversation == current.id else { primed = true; return }
    guard !nowReady.subtracting(ready).isEmpty, let presenter, presenter.viewIfLoaded?.window != nil,
      presenter.presentedViewController == nil, !presenter.isBeingDismissed
    else { return }
    if typing {
      waiting = true
      return
    }
    show(store: store, presenter: presenter)
  }

  private func show(store: JarvisStore, presenter: UIViewController) {
    // A moment after the work is done, so that its file is there when the sheet asks for it.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak presenter] in
      guard let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil, !presenter.isBeingDismissed else { return }
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      WorksSheet.present(store: store, from: presenter)
      if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: "作品已生成") }
    }
  }
}

@MainActor
final class WorksSheet {
  private let store: JarvisStore
  private let model: WorksStore
  private var bag = Set<AnyCancellable>()

  static func present(store: JarvisStore, from presenter: UIViewController) {
    guard presenter.presentedViewController == nil else { return }
    let sheet = WorksSheet(store: store)
    let host = WorksSheetHost(rootView: WorksView(store: sheet.model) { [weak presenter] in presenter?.dismiss(animated: true) })
    host.sheet = sheet
    host.modalPresentationStyle = .pageSheet
    host.view.backgroundColor = Palette.card
    if let detents = host.sheetPresentationController {
      detents.prefersGrabberVisible = true
      detents.preferredCornerRadius = Radii.sheet
      detents.detents = [.medium(), .large()]
      detents.prefersGrabberVisible = true
      detents.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    presenter.present(host, animated: true)
  }

  private init(store: JarvisStore) {
    self.store = store
    model = WorksStore(state: WorksSheet.state(store))
    VideoCover.load = { [store] address, file in try await store.api.download(address, to: file) }
    VideoCover.normalize = { [store] address in (try? store.api.mediaURL(address))?.absoluteString ?? address }
    model.transport = { [weak self] message, answer in
      guard let self else { return answer(nil) }
      Task { answer(await self.act(message)) }
    }
    model.fetch = { [store] url, answer in
      // The service may name its files with another host or scheme than the one it is reached by: the API rewrites those of its own
      // paths to this server and sends the session only there, so no check of the origin is made here.
      Task { answer(try? await store.api.download(url)) }
    }
    store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.refresh() }
    }.store(in: &bag)
  }

  private static func state(_ store: JarvisStore) -> WorksState {
    let tasks = store.conversations.flatMap { $0.tasks.reversed() }
    return WorksState(
      canCancel: true,
      tasks: tasks.map {
        .init(
          id: $0.id, kind: $0.kind, prompt: $0.prompt, status: $0.status, progress: $0.progress, error: $0.error, pending: $0.pending,
          urls: $0.status == "completed" ? $0.urls : [], highlight: false)
      })
  }

  private func refresh() { model.state = Self.state(store) }

  private func owner(of task: String) -> String? { store.conversations.first { $0.tasks.contains { $0.id == task } }?.id }

  private func act(_ message: [String: Any]) async -> [String: Any]? {
    guard let id = message["id"] as? String else { return nil }
    switch message["a"] as? String {
    case "cancel": if let o = owner(of: id) { store.cancelMediaTask(o, id) }
    case "retry": if let o = owner(of: id) { await store.retryMedia(o, id) }
    case "settings": await withCheckedContinuation { c in FilesService.shared.openAppSettings { _ in c.resume() } }
    case "save": return ["result": await save(id)]
    default: break
    }
    return ["ok": true]
  }

  /// Saves every picture or video of a task into Photos. The result the button shows: saved, denied or failed.
  private func save(_ id: String) async -> String {
    guard let task = store.conversations.flatMap(\.tasks).first(where: { $0.id == id }) else { return "failed" }
    var result = "other"
    for (i, url) in task.urls.enumerated() {
      // The ones an earlier try already put in Photos are not put in again.
      if savedParts[id]?.contains(i) == true { result = "saved"; continue }
      do {
        let suffix = task.urls.count > 1 ? "-\(i + 1)" : ""
        if task.kind == "video", let file = await VideoCover.saved(url) {
          // A video is in the cache already (the cover and the player use it): it is put into Photos from there, not read into memory.
          _ = try await FilesService.shared.saveToPhotos(
            FileSource(name: "jarvis-\(id)\(suffix).mp4", bytes: nil, path: file.path), mime: "video/mp4")
        } else {
          let data = try await store.api.download(url)
          let kind = Self.sniff(data, task.kind)
          _ = try await FilesService.shared.saveToPhotos(
            FileSource(name: "jarvis-\(id)\(suffix).\(kind.ext)", bytes: data, path: nil), mime: kind.mime)
        }
        result = "saved"
        savedParts[id, default: []].insert(i)
      } catch let e as FilesFailure {
        return e.code == "photos_denied" ? "denied" : "failed"
      } catch {
        return "failed"
      }
    }
    savedParts[id] = nil
    return result
  }

  /// The parts of a task with several pictures that are already in Photos (a retry after a failure goes on from there).
  private var savedParts: [String: Set<Int>] = [:]

  static func sniff(_ data: Data, _ kind: String) -> (mime: String, ext: String) {
    let b = [UInt8](data.prefix(12))
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
    if b.starts(with: [0xFF, 0xD8]) { return ("image/jpeg", "jpg") }
    if b.starts(with: [0x47, 0x49, 0x46]) { return ("image/gif", "gif") }
    if b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x45, 0x42, 0x50] { return ("image/webp", "webp") }
    if b.count >= 8, b[4..<8] == [0x66, 0x74, 0x79, 0x70] { return ("video/mp4", "mp4") }
    return kind == "video" ? ("video/mp4", "mp4") : ("image/png", "png")
  }
}

/// Keeps the sheet's model alive as long as the page is.
final class WorksSheetHost: UIHostingController<WorksView> {
  /// Every way up, the upside-down portrait too (the system leaves it out for an iPhone unless the page in front says so).
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

  var sheet: WorksSheet?
}


/// The original's back arrow: the bare chevron at the leading edge, no capsule behind it.
@MainActor
func installBackButton(_ page: UIViewController, onSessionEnded: (() -> Void)?) {
  page.navigationItem.setHidesBackButton(true, animated: false)
  page.navigationItem.leftItemsSupplementBackButton = false
  page.navigationItem.backButtonDisplayMode = .minimal
  let item = UIBarButtonItem(
    image: UIImage(systemName: "chevron.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)),
    primaryAction: UIAction { [weak page] _ in
      if let nav = page?.navigationController, nav.viewControllers.count > 1 {
        nav.popViewController(animated: true)
      } else {
        page?.dismiss(animated: true)
      }
    })
  item.tintColor = Palette.onSurface
  item.accessibilityLabel = "返回"
  if #available(iOS 26.0, *) { item.hidesSharedBackground = true }
  page.navigationItem.leftBarButtonItem = item
  let bar = UINavigationBarAppearance()
  bar.configureWithTransparentBackground()
  bar.backgroundColor = Palette.surface
  bar.shadowColor = .clear
  bar.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: Palette.onSurface]
  page.navigationItem.standardAppearance = bar
  page.navigationItem.scrollEdgeAppearance = bar
}

extension NativeChatSettings {
  /// The voices of the speech engine in use, as a sheet: choose one, hear it, close.
  static func voicePicker(store: JarvisStore, done: @escaping () -> Void) -> UIViewController {
    let host = VoicePickerHost(store: store, done: done)
    host.modalPresentationStyle = .pageSheet
    host.view.backgroundColor = Palette.card
    if let sheet = host.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = Radii.sheet
    }
    return host
  }
}

/// The voice sheet; it follows the store like the settings page does.
@MainActor
final class VoicePickerHost: UIHostingController<VoicePickerView> {
  /// Every way up, the upside-down portrait too (the system leaves it out for an iPhone unless the page in front says so).
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

  private let adapter: SettingsAdapter
  private let model: SettingsStore
  private var bag = Set<AnyCancellable>()

  init(store: JarvisStore, done: @escaping () -> Void) {
    adapter = SettingsAdapter(store: store)
    model = SettingsStore(state: adapter.snapshot())
    super.init(rootView: VoicePickerView(store: model, done: done))
    model.transport = { [weak self] message, answer in
      guard let adapter = self?.adapter else { return answer(nil) }
      Task { answer(await adapter.act(message)) }
    }
    adapter.onChange = { [weak self] in self?.refresh() }
    store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.refresh() }
    }.store(in: &bag)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  private func refresh() { model.state = adapter.snapshot() }
}


/// A page of the navigation stack that draws its own back arrow: the system's is taken away each time it appears.
protocol OwnsBackButton: UIViewController {}

extension OwnsBackButton {
  func hideSystemBack() {
    navigationItem.setHidesBackButton(true, animated: false)
    navigationItem.leftItemsSupplementBackButton = false
  }
}
