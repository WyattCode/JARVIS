import Combine
import Foundation

/// The call, as far as the store needs to know about it. The realtime voice session will be this.
@MainActor
public protocol VoiceHost: AnyObject {
  var active: Bool { get }
  var starting: Bool { get }
  var thinking: Bool { get }
  var conversationId: String? { get }
  var previewing: Bool { get }
  func typed(_ text: String) -> Bool
  func interrupt() async
  func stop() async
  func cancelHold()
  func updateSettings()
  func stopPreview() async
  func clearIdleError()
}

/// The app's state and what the user can do with it: conversations, the chat and tool loop, picture and video tasks,
/// settings, the saved session, saving. The Swift counterpart of `JarvisController`; it keeps the same rules, the same
/// messages and the same file.
@MainActor
public final class JarvisStore: ObservableObject {
  public let api: Transport
  public let vault: Vault
  let writer: StateWriter

  // MARK: State

  @Published public private(set) var conversations: [Conversation] = []
  @Published public private(set) var selectedId: String?
  @Published public private(set) var models: [ModelInfo] = []
  @Published public private(set) var modelSkill: [String: JSONValue] = ["enabled": .bool(false), "text": .string("")]
  @Published public private(set) var model = ""
  @Published public private(set) var effort = "high"
  @Published public private(set) var theme = "dark"
  @Published public private(set) var settings = ChatSettings()
  @Published public private(set) var initialized = false
  @Published public private(set) var authenticated = false
  @Published public private(set) var connecting = false
  @Published public private(set) var error: String?
  /// The page has told the person what `error` says.
  public func clearError() { error = nil }

  /// The sign-in page is typed on again: what the last try said (and, signed out, the word about the connection or the session that
  /// ended) is not kept up under the new one.
  public func clearSignInMessages() {
    error = nil
    if !authenticated { connectionError = nil }
  }
  @Published public private(set) var connectionError: String?
  @Published public private(set) var storageError: String?
  /// Attachments the last export could not read and left out.
  public var backupSkipped: [String] = []
  public weak var voice: VoiceHost?

  /// Asked before the model unloads or loads a model on its own; without it these tools are refused: an instruction
  /// hidden in an attachment must not be able to run them.
  public var confirmToolCall: ((String) async -> Bool)?

  // The saved file could not be read: saving would overwrite it, so persistence stays off until `startFresh`.
  private var storageBlocked = false
  private var saveFailed = false
  public var storageReadOnly: Bool { storageBlocked }
  public var persistFailed: Bool { storageBlocked || saveFailed }
  var blobsDirty = false
  /// Counts the times local data was cleared, the conversations wiped or the account left: an import that began before one of them is
  /// not put in after it (it would bring back what was just cleared).
  var dataEpoch = 0
  private var gcHold = false
  private var heldBlobs: [String: Int] = [:]
  private var trash: [(conversation: Conversation, until: Date)] = []
  public var undoWindow: TimeInterval = 10

  private var active: [String: (requestId: String, messageId: String)] = [:]
  private var mediaActive: [String: String] = [:]
  /// How long pictures and videos took on this phone, for the time a new one is said to need.
  public private(set) var mediaTimings = MediaTimings.prior
  public var timingDefaults: UserDefaults = .standard
  private static let timingKey = "mediaTimings.v1"
  /// Unix seconds (a test brings its own).
  public var clock: () -> Double = { Date().timeIntervalSince1970 }
  private var attachmentLoads: [String: Int] = [:]
  private var serial = 0
  private var catalogEpoch = 0
  private var authEpoch = 0
  private var disposed = false

  public private(set) var offlineSession = false
  private var retryTask: Task<Void, Never>?
  private var retryAttempts = 0
  private var lastConnectAt: Date?
  /// Wait before the n-th automatic reconnect while offline (5 s, 10 s ... 60 s).
  public var offlineRetryDelay: (Int) -> TimeInterval = { n in min(Double(5 << min(max(n, 0), 4)), 60) }
  /// Coming back to the foreground retries at most this often.
  public var resumeThrottle: TimeInterval = 3

  private let sessionStarters = SessionStarters()

  public init(api: Transport, vault: Vault) {
    self.api = api
    self.vault = vault
    writer = StateWriter(vault: vault)
  }

  public var current: Conversation {
    conversations.first { $0.id == selectedId } ?? conversations[0]
  }

  public func conversation(_ id: String) -> Conversation? { conversations.first { $0.id == id } }

  public func isGenerating(_ id: String) -> Bool {
    active[id] != nil || (voice?.active == true && voice?.conversationId == id && voice?.thinking == true)
  }

  public func attachmentsLoading(_ id: String) -> Bool { (attachmentLoads[id] ?? 0) > 0 }

  public func beginAttachment(_ id: String) { attachmentLoads[id, default: 0] += 1 }
  public func endAttachment(_ id: String) { attachmentLoads[id] = min(max((attachmentLoads[id] ?? 0) - 1, 0), 100) }

  public var starters: [Starter] {
    sessionStarters.available { kind in settings.tools && models.contains { $0.kind == kind } }
  }

  public var modelReady: Bool {
    guard let m = models.first(where: { $0.id == model }) else { return false }
    let state = JSONValue.object(m.metadata)
    return connectionError == nil && state["running"] != .bool(false)
      && !["loading", "failed", "unloaded"].contains(state["state"]?.string ?? "")
  }

  private var attachmentSerial = 0
  func nextAttachmentSerial() -> Int {
    attachmentSerial += 1
    return attachmentSerial
  }

  func newId() -> String {
    serial += 1
    return "\(Int(Date().timeIntervalSince1970 * 1_000_000))-\(serial)"
  }

  // MARK: Editing helpers (conversations are values; everything goes through these)

  private func index(_ cid: String) -> Int? { conversations.firstIndex { $0.id == cid } }

  func update(_ cid: String, _ body: (inout Conversation) -> Void) {
    guard let i = index(cid) else { return }
    body(&conversations[i])
  }

  func updateMessage(_ cid: String, _ mid: String, _ body: (inout ChatMessage) -> Void) {
    update(cid) { c in
      if let j = c.messages.firstIndex(where: { $0.id == mid }) { body(&c.messages[j]) }
    }
  }

  func updateTask(_ cid: String, _ tid: String, _ body: (inout MediaTask) -> Void) {
    update(cid) { c in
      if let j = c.tasks.firstIndex(where: { $0.id == tid }) { body(&c.tasks[j]) }
    }
  }

  private func task(_ cid: String, _ tid: String) -> MediaTask? { conversation(cid)?.tasks.first { $0.id == tid } }
  private func message(_ cid: String, _ mid: String) -> ChatMessage? { conversation(cid)?.messages.first { $0.id == mid } }

  // MARK: Start

  public func initialize() async {
    // Exports, backups and downloads staged before a kill sit in the temp folders as plain text.
    LocalData.clearStaleCachedMedia()
    if let data = timingDefaults.data(forKey: Self.timingKey), let seen = try? JSONDecoder().decode(MediaTimings.self, from: data) {
      mediaTimings = seen
    }
    var loaded = false
    switch Persistence.load(vault, server: api.endpoint.jarvisOrigin) {
    case .empty: break
    case .loaded(let state):
      api.cookie = state.cookie
      settings = state.settings
      api.apiKey = settings.apiKey
      model = state.model
      gcHold = state.gcHold
      conversations = state.conversations
      selectedId = state.selectedId
      effort = state.effort
      theme = state.theme
      loaded = true
    case .unreadable:
      // Read-only until the user explicitly starts fresh: the first save would overwrite the only copy.
      storageBlocked = true
      conversations = []
      storageError = "未能读取本机保存的资料，原文件未删除；本次修改不会保存，可重启应用重试，或选择从空白开始"
    }
    if conversations.isEmpty { _ = newConversation(save: false) }
    if !conversations.contains(where: { $0.id == selectedId }) { selectedId = conversations[0].id }
    initialized = true
    // Orphans left by a crash or an earlier version; never while the saved state could not be read.
    if loaded {
      blobsDirty = true
      // Not before the first page is up: listing the stored files and deleting orphans runs on the main thread, and with many
      // attachments it held the first page (and the launch flight) back. A short while later is as good for a clean-up.
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await self?.collectBlobs()
      }
    }
    if api.cookie != nil { await connect() }
    for owner in conversations {
      for task in owner.tasks where task.pending {
        if authenticated, task.source == "voice", task.jobId != nil {
          pollVoiceTask(owner.id, task.id)
        } else if authenticated, task.jobId != nil {
          runMedia(owner.id, task.id, resume: true)
        } else {
          updateTask(owner.id, task.id) {
            $0.status = "interrupted"
            $0.error = "应用退出时任务没做完"
          }
        }
      }
    }
  }

  // MARK: Connection and account

  public func connect() async {
    catalogEpoch += 1
    let run = catalogEpoch
    lastConnectAt = Date()
    connecting = true
    error = nil
    defer { if run == catalogEpoch { connecting = false } }
    do {
      let found = try await api.models()
      if run != catalogEpoch || disposed { return }
      let voiceBefore = voiceConfigSignature
      models = found
      connectionError = nil
      let chats = models.filter { $0.kind == "chat" }
      if chats.isEmpty { throw JarvisException("服务未提供可用的聊天模型") }
      if !chats.contains(where: { $0.id == model }) { model = chats[0].id }
      if settings.speechModel.isEmpty, let speech = models.first(where: { $0.kind == "speech" }) {
        settings.speechModel = speech.id
      }
      applyVoiceDefaults()
      // The server's default for calls moved while a call is up: the call follows it (after the reply being spoken, if any).
      if voice?.active == true, voiceConfigSignature != voiceBefore { voice?.updateSettings() }
      do {
        let skill = try await api.modelSkill()
        if run != catalogEpoch || disposed { return }
        modelSkill = skill
      } catch {
        if run != catalogEpoch || disposed { return }
        modelSkill = ["enabled": .bool(false), "text": .string("")]
      }
      authenticated = true
      offlineSession = false
      retryAttempts = 0
      retryTask?.cancel()
      retryTask = nil
    } catch let e as JarvisException {
      if run != catalogEpoch || disposed { return }
      connectionError = e.message
      error = e.message
      if e.unauthorized { expireSession() } else { wentOffline() }
    } catch {
      if run != catalogEpoch || disposed { return }
      connectionError = "暂时无法连接服务，请检查网络后重试"
      self.error = connectionError
      wentOffline()
    }
  }

  /// Takes the voice the server names as default, once per revision of that default (kept by server and speech engine):
  /// the voice the user picks afterwards stays. A voice is also chosen when none is stored yet. A call in progress keeps
  /// its voice; the next refresh takes the default then.
  func applyVoiceDefaults() {
    if voice?.active == true || voice?.starting == true { return }
    let server = api.endpoint.jarvisOrigin
    var picks: [String: String] = [:]
    var applied: [String: Int] = [:]
    for m in models where m.kind == "speech" {
      let key = "\(server)|\(m.id)"
      let known = !m.defaultVoice.isEmpty && m.voices.contains { $0.id == m.defaultVoice }
      if !known { continue }
      let newer = m.voiceDefaultRevision > (settings.voiceDefaultRevisions[key] ?? 0)
      if newer || settings.voices[m.id] == nil {
        if settings.voices[m.id] != m.defaultVoice { picks[m.id] = m.defaultVoice }
        if newer { applied[key] = m.voiceDefaultRevision }
      }
    }
    if picks.isEmpty && applied.isEmpty { return }
    // No call is running, so there is no session to renegotiate: only what the voice list and a try-out show changes.
    settings.voices.merge(picks) { _, new in new }
    settings.voiceDefaultRevisions.merge(applied) { _, new in new }
    if !picks.isEmpty {
      voice?.clearIdleError()
      if voice?.previewing == true { Task { await voice?.stopPreview() } }
    }
    scheduleSave()
  }

  /// Asks the server for the voices again; whatever fails leaves the voices already known as they are.
  public func refreshVoiceCatalog() async {
    guard authenticated, !disposed else { return }
    let run = catalogEpoch
    guard let speech = try? await api.models().filter({ $0.kind == "speech" }) else { return }
    if run != catalogEpoch || disposed || speech.isEmpty { return }
    models = models.filter { $0.kind != "speech" } + speech
    applyVoiceDefaults()
  }

  private func wentOffline() {
    // Only a session that was already saved counts; a failed login has no cookie and stays on the login page.
    offlineSession = !authenticated && api.cookie != nil
    retryTask?.cancel()
    retryTask = nil
    if !offlineSession || disposed { return }
    let delay = offlineRetryDelay(retryAttempts)
    retryAttempts += 1
    retryTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      self.retryTask = nil
      await self.retryConnect()
    }
  }

  /// Tries the saved session again (the banner's button, the backoff timer, coming back to the foreground).
  public func retryConnect() async {
    if disposed || authenticated || connecting || api.cookie == nil { return }
    retryTask?.cancel()
    retryTask = nil
    await connect()
    // A session first reached after a login that could not connect yet was never written down.
    if authenticated { await save() }
  }

  /// The app came back to the foreground: a dropped connection is worth another try right away.
  public func appResumed() {
    if !offlineSession || connecting { return }
    if let last = lastConnectAt, Date().timeIntervalSince(last) < resumeThrottle { return }
    Task { await retryConnect() }
  }

  /// How a sign-in went. `login` says only whether it ended connected (the models fetched too), which a slow or failing connection
  /// can spoil after a good sign-in; this tells the rest apart, so that what is kept for Face ID / Touch ID depends on whether the
  /// server took the password and not on the connection.
  public enum LoginOutcome: Equatable {
    /// Signed in and connected.
    case connected
    /// The server took the password, but the connection failed after it.
    case accepted
    /// The server turned the password down.
    case rejected
    /// No answer, or one that says nothing about the password (a server that is down).
    case failed
    /// Another sign-in is under way: nothing was tried.
    case busy
  }

  public func login(_ username: String, _ password: String) async -> Bool {
    await signIn(username, password) == .connected
  }

  public func signIn(_ username: String, _ password: String) async -> LoginOutcome {
    if connecting { return .busy }
    authEpoch += 1
    let run = authEpoch
    connecting = true
    error = nil
    defer { if run == authEpoch { connecting = false } }
    do {
      try await api.login(username.trimmingCharacters(in: .whitespacesAndNewlines), password)
      if run != authEpoch || disposed { return .failed }
      await connect()
      if authenticated { await save() }
      return authenticated ? .connected : .accepted
    } catch let e as JarvisException {
      error = e.message
      return e.message == JarvisAPI.loginRejectedMessage ? .rejected : .failed
    } catch {
      self.error = "登录连接失败，请检查网络后重试"
      return .failed
    }
  }

  public func expireSession() {
    catalogEpoch += 1
    authEpoch += 1
    authenticated = false
    connecting = false
    offlineSession = false
    retryTask?.cancel()
    retryTask = nil
    api.cookie = nil
    connectionError = "登录已过期，请重新登录"
    error = connectionError
    if voice?.active == true { Task { await voice?.stop() } }
    for id in Array(active.keys) { cancel(id) }
    for request in mediaActive.values { api.cancel(request) }
    mediaActive.removeAll()
    interruptPendingTasks("已退出登录；任务可能仍在服务器运行，请重新登录后检查原任务")
    scheduleSave()
  }

  private func interruptPendingTasks(_ message: String) {
    for i in conversations.indices {
      for j in conversations[i].tasks.indices where conversations[i].tasks[j].pending {
        conversations[i].tasks[j].status = "interrupted"
        conversations[i].tasks[j].error = message
      }
    }
  }

  /// Signs out of the service. Conversations, settings (including the API key, which stays in the encrypted vault) and
  /// attachments stay on the device so signing in again picks up where the user left off; only cached media goes.
  public func logout() async {
    catalogEpoch += 1
    authEpoch += 1
    authenticated = false
    connecting = false
    offlineSession = false
    retryTask?.cancel()
    retryTask = nil
    await voice?.stop()
    for id in Array(active.keys) { cancel(id) }
    do { try await api.logout() } catch { api.cookie = nil }
    for request in mediaActive.values { api.cancel(request) }
    mediaActive.removeAll()
    interruptPendingTasks("已退出登录；任务可能仍在服务器运行，请重新登录后检查原任务")
    authenticated = false
    error = nil
    dataEpoch += 1
    await save()
    LocalData.clearCachedMedia()
  }

  /// Signs out and erases everything this app keeps on the device. Returns false when the saved file could not be read:
  /// that copy is evidence the user has not decided about yet (see `startFresh`).
  public func clearLocalData() async -> Bool {
    if storageBlocked { return false }
    await logout()
    conversations = []
    trash = []
    heldBlobs = [:]
    selectedId = nil
    theme = "dark"
    models = []
    modelSkill = ["enabled": .bool(false), "text": .string("")]
    model = ""
    effort = "high"
    settings = ChatSettings()
    api.apiKey = ""
    api.cookie = nil
    connectionError = nil
    storageError = nil
    gcHold = false
    _ = newConversation(save: false)
    // Blobs first: the state file must never be the only thing left saying what existed.
    do {
      for id in try vault.listBlobs() { try vault.deleteBlob(id) }
    } catch { blobsDirty = true }
    // The preserved copies of earlier unreadable files hold the old data too.
    do { try vault.wipeEvidence() } catch { blobsDirty = true }
    await save()
    if saveFailed {
      // The old file (history and session cookie) would sign the next launch straight back in: remove it outright.
      do {
        try vault.eraseState()
        saveFailed = false
        storageError = nil
      } catch {}
      if saveFailed { self.error = "未能清除本机数据，请稍后重试" }
    }
    return !persistFailed
  }

  // MARK: Conversations

  /// Returns the empty conversation that is already selected instead of stacking another one.
  @discardableResult
  public func newConversation(save: Bool = true) -> Conversation {
    if let selected = conversations.first(where: { $0.id == selectedId }), selected.messages.isEmpty, selected.tasks.isEmpty,
      selected.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, selected.pendingAttachments.isEmpty,
      !attachmentsLoading(selected.id), !(voice?.active == true && voice?.conversationId == selected.id)
    {
      return selected
    }
    let c = Conversation(newId())
    conversations.insert(c, at: 0)
    selectedId = c.id
    if save { scheduleSave() }
    return c
  }

  public func select(_ id: String) {
    guard conversations.contains(where: { $0.id == id }) else { return }
    selectedId = id
    scheduleSave()
  }

  public func setDraft(_ value: String) {
    let id = current.id
    update(id) { $0.draft = value }
    draftDirty.insert(id)
    // Typing must not re-encode the whole history; see `save`.
    scheduleSave(draftOnly: true)
  }

  /// The chat's thinking strength. A call has its own (`voiceEffort`), so this never touches a call.
  public func setEffort(_ value: String) {
    guard ChatSettings.efforts.contains(value), value != effort else { return }
    effort = value
    scheduleSave()
  }

  // MARK: The voice's thinking strength

  private var chatModelMetadata: JSONValue {
    JSONValue.object(models.first { $0.id == model && $0.kind == "chat" }?.metadata ?? [:])["jarvis"] ?? .object([:])
  }

  /// What the server says a call thinks with when nobody chose: `jarvis.voice_defaults.reasoning_effort` of the chat model.
  /// A server without the field, or with a value this app does not know, gets "low".
  /// The catalog has the chat model, so its voice defaults (or their absence) are the server's word and not a guess.
  public var voiceServerEffortKnown: Bool { models.contains { $0.id == model && $0.kind == "chat" } }

  /// What a call set up now would be asked for (strength and model); a change in it because the catalog moved (the server's
  /// default strength) reaches a live call. The voice cannot change that way: the voice defaults are not taken during a call.
  private var voiceConfigSignature: String { "\(voiceEffort)|\(voiceModel(for: voiceEffort) ?? "")" }

  public var voiceServerEffort: String {
    let raw = chatModelMetadata["voice_defaults"]?["reasoning_effort"]?.string ?? ""
    return ChatSettings.efforts.contains(raw) ? raw : "low"
  }

  /// The strength a call is set up with: the user's own pick, otherwise the server's default.
  public var voiceEffort: String {
    ChatSettings.efforts.contains(settings.voiceEffort) ? settings.voiceEffort : voiceServerEffort
  }

  /// The server lists voice models per thinking strength at all (an older one does not).
  public var voiceModelsListed: Bool { chatModelMetadata["voice_effort_models"]?.object?.isEmpty == false }

  /// The model the server names for `effort` (`jarvis.voice_effort_models`); nil when it names none.
  public func voiceModel(for effort: String) -> String? {
    let id = chatModelMetadata["voice_effort_models"]?[effort]?.string ?? ""
    return id.isEmpty ? nil : id
  }

  /// Takes the model list again before a call is set up or set up again, so the server's defaults and model names are the
  /// current ones. A failure keeps the list already known (the call will say if the server is out of reach).
  public func refreshModelCatalog() async {
    guard authenticated, !disposed else { return }
    let run = catalogEpoch
    do {
      // Not the 30 s a plain request may take: a call that cannot reach the server should fail on its own, not wait here first.
      let api = self.api
      let found = try await withTimeout(5) { try await api.models() }
      if run != catalogEpoch || disposed { return }
      let chats = found.filter { $0.kind == "chat" }
      guard !chats.isEmpty else { return }
      models = found
      if !chats.contains(where: { $0.id == model }) {
        model = chats[0].id
        scheduleSave()
      }
      applyVoiceDefaults()
    } catch let e as JarvisException {
      if e.unauthorized, run == catalogEpoch, !disposed { expireSession() }
    } catch {}
  }

  public func setTheme(_ value: String) {
    guard ["system", "light", "dark"].contains(value) else { return }
    theme = value
    scheduleSave()
  }

  public func setModel(_ id: String) {
    guard models.contains(where: { $0.id == id && $0.kind == "chat" }) else { return }
    model = id
    voice?.cancelHold()
    voice?.updateSettings()
    scheduleSave()
  }

  public func rename(_ id: String, _ title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard conversation(id) != nil, !trimmed.isEmpty else { return }
    update(id) {
      $0.title = trimmed
      $0.named = true
    }
    scheduleSave()
  }

  private func voiceSettingsSignature() -> String {
    var config = settings.json()
    config["messageFontSize"] = nil
    config["voiceDefaultRevisions"] = nil
    return Persistence.encode(.object(config))
  }

  public func changeSettings(_ edit: (inout ChatSettings) -> Void) {
    let previousSpeech = settings.speechModel
    let previousVoice = settings.voices[settings.speechModel]
    let previousConfig = voiceSettingsSignature()
    edit(&settings)
    api.apiKey = settings.apiKey
    // Presentation-only/no-op edits must not discard a microphone buffer or pause an already confirmed voice session.
    if voiceSettingsSignature() != previousConfig {
      let voiceChanged = previousSpeech != settings.speechModel || previousVoice != settings.voices[settings.speechModel]
      if voice?.active == true && voiceChanged { Task { await voice?.interrupt() } }
      // The error was about the old engine/voice; a live call keeps its own.
      if voiceChanged { voice?.clearIdleError() }
      voice?.cancelHold()
      if voice?.previewing == true { Task { await voice?.stopPreview() } }
      voiceSettingsTask?.cancel()
      voiceSettingsTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 200_000_000)
        if !Task.isCancelled { self?.voice?.updateSettings() }
      }
    }
    scheduleSave()
  }

  private var voiceSettingsTask: Task<Void, Never>?

  /// A conversation can't be deleted while it generates, is in a call, or has pending work.
  public func canDeleteConversation(_ id: String) -> Bool {
    guard let c = conversation(id) else { return false }
    return !isGenerating(id) && !(voice?.active == true && voice?.conversationId == id) && !c.tasks.contains { $0.pending }
  }

  @discardableResult
  public func deleteConversation(_ id: String) -> Conversation? {
    guard canDeleteConversation(id), let i = index(id) else { return nil }
    let c = conversations.remove(at: i)
    if conversations.isEmpty { _ = newConversation(save: false) }
    if selectedId == id { selectedId = conversations[0].id }
    // Its attachments stay on disk while the undo is still offered.
    trash.append((c, Date().addingTimeInterval(undoWindow)))
    blobsDirty = true
    scheduleSave()
    return c
  }

  public func restoreConversation(_ c: Conversation) {
    if conversations.contains(where: { $0.id == c.id }) { return }
    trash.removeAll { $0.conversation.id == c.id }
    conversations.insert(c, at: 0)
    select(c.id)
  }

  @discardableResult
  public func wipeConversations() -> Bool {
    if conversations.contains(where: { isGenerating($0.id) || $0.tasks.contains { $0.pending } }) || voice?.active == true {
      return false
    }
    conversations = []
    dataEpoch += 1
    // Nothing is left to undo, so the attachment files can go at the next save.
    trash = []
    blobsDirty = true
    LocalData.clearCachedMedia()
    newConversation()
    return true
  }

  public func installImported(_ imported: [Conversation]) {
    conversations.insert(contentsOf: imported, at: 0)
    if let first = imported.first { selectedId = first.id }
    scheduleSave()
  }

  // MARK: Attachments

  public func addAttachment(_ ownerId: String, _ attachment: Attachment, bytes: Data?) async throws {
    guard let owner = conversation(ownerId) else { return }
    if owner.pendingAttachments.count >= 4 { throw JarvisException("每条消息最多4个附件") }
    if let bytes {
      // Held from before the write so a collection in between cannot take a blob nothing references yet.
      holdBlobs([attachment.id])
      defer { releaseBlobs([attachment.id]) }
      try vault.writeBlob(attachment.id, bytes)
      guard let now = conversation(ownerId) else {
        discardBlob(attachment.id)
        return
      }
      if now.pendingAttachments.count >= 4 {
        discardBlob(attachment.id)
        throw JarvisException("每条消息最多4个附件")
      }
      update(ownerId) { $0.pendingAttachments.append(attachment) }
    } else {
      update(ownerId) { $0.pendingAttachments.append(attachment) }
    }
    await save()
  }

  private func discardBlob(_ id: String) {
    do { try vault.deleteBlob(id) } catch { blobsDirty = true }
  }

  public func removeAttachment(_ id: String) {
    update(current.id) { $0.pendingAttachments.removeAll { $0.id == id } }
    blobsDirty = true
    scheduleSave()
  }

  /// Keeps blobs that are written but not yet referenced by a conversation (an import in progress) out of the collection.
  public func holdBlobs(_ ids: [String]) { for id in ids { heldBlobs[id, default: 0] += 1 } }

  public func releaseBlobs(_ ids: [String]) {
    for id in ids {
      let n = (heldBlobs[id] ?? 1) - 1
      if n <= 0 { heldBlobs[id] = nil } else { heldBlobs[id] = n }
    }
  }

  /// Deletes attachment files that no conversation, undo window or write in flight refers to.
  func collectBlobs() async {
    if !blobsDirty || storageBlocked || gcHold || disposed { return }
    trash.removeAll { $0.until < Date() }
    // Something may still be undone; look again after the next save.
    if !trash.isEmpty { return }
    blobsDirty = false
    do {
      let stored = try vault.listBlobs()
      for id in orphanedBlobs(stored: stored, conversations: conversations, held: Set(heldBlobs.keys)) {
        // A conversation deleted while this runs may still be undone.
        if !trash.isEmpty {
          blobsDirty = true
          return
        }
        try vault.deleteBlob(id)
      }
    } catch { blobsDirty = true }
  }

  public func messagePayload(_ c: Conversation, instruction: String? = nil) throws -> [[String: JSONValue]] {
    try Payload.messages(for: c, instructions: instruction ?? settings.instructions, blobs: vault)
  }

  // MARK: Sending

  public func cancel(_ id: String) {
    let entry = active.removeValue(forKey: id)
    if entry == nil, voice?.conversationId == id {
      Task { await voice?.interrupt() }
      return
    }
    if let entry {
      updateMessage(id, entry.messageId) { $0.status = "interrupted" }
      api.cancel(entry.requestId)
      scheduleSave()
    }
  }

  private func changesModels(_ tool: String, _ args: [String: JSONValue]) -> String? {
    let name = (args["model"].map { $0.string ?? "" } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let label = name.isEmpty ? "指定的模型" : "模型 \(name)"
    switch tool {
    case "unload_model": return "卸载\(label)"
    case "load_model": return "加载\(label)"
    case "reserve_for" where args["dry_run"] != .bool(true): return "为\(label)预留空间"
    default: return nil
    }
  }

  private func confirmed(_ action: String) async -> Bool {
    guard let ask = confirmToolCall else { return false }
    return await ask(action)
  }

  public func send() async {
    let cid = current.id
    guard let c = conversation(cid) else { return }
    let text = c.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if attachmentsLoading(cid) {
      error = "附件仍在处理，草稿已保留"
      return
    }
    if !authenticated || (text.isEmpty && c.pendingAttachments.isEmpty) || model.isEmpty || active[cid] != nil { return }
    if voice?.active == true, voice?.conversationId == cid, c.pendingAttachments.isEmpty {
      if voice?.typed(text) == true {
        update(cid) { $0.draft = "" }
        scheduleSave()
      } else {
        error = "语音尚未就绪或上一条回复仍在输出，草稿已保留"
      }
      return
    }
    let attachments = c.pendingAttachments
    update(cid) {
      $0.pendingAttachments = []
      $0.draft = ""
    }
    if c.messages.isEmpty && !c.named {
      let title = TextClip.tidyTitle(text.isEmpty ? attachments[0].name : text)
      if !title.isEmpty { update(cid) { $0.title = title } }
    }
    update(cid) { $0.messages.append(ChatMessage("user", text, attachments: attachments)) }
    var reply = ChatMessage("assistant", "", status: "generating")
    update(cid) { $0.messages.append(reply) }
    let requestId = newId()
    active[cid] = (requestId, reply.id)
    error = nil
    scheduleSave()
    let management = settings.tools && modelSkill["enabled"] == .bool(true)
    let options = ChatOptions(
      tools: settings.tools ? mediaToolSchema(models) + (management ? modelToolSchema() : []) : [], maxTokens: settings.maxTokens)
    let requestModel = model
    let requestEffort = effort
    let instruction = settings.instructions + (management ? "\n\n\(modelSkill["text"]?.string ?? "")" : "")
    let rounds = management ? 8 : 4
    func isCurrent() -> Bool { active[cid]?.messageId == reply.id }
    func loop() async throws {
      for round in 0..<rounds {
        if round > 0 {
          // The reply this round follows must still be the one running: a cancel (and a new send after it) ends this loop.
          if !isCurrent() || disposed { return }
          reply = ChatMessage("assistant", "", status: "generating")
          update(cid) { $0.messages.append(reply) }
          active[cid] = (requestId, reply.id)
        }
        var calls: [Int: ToolCall] = [:]
        var order: [Int] = []
        var done = false
        let messages = try messagePayload(conversation(cid) ?? c, instruction: instruction)
        if !isCurrent() { return }
        let replyId = reply.id
        for try await delta in api.chat(
          requestId: requestId, model: requestModel, effort: requestEffort, messages: messages, options: options)
        {
          if disposed || !isCurrent() { break }
          for d in delta.toolDeltas {
            if calls[d.index] == nil {
              calls[d.index] = ToolCall()
              order.append(d.index)
            }
            if !d.id.isEmpty { calls[d.index]!.id = d.id }
            calls[d.index]!.name += d.name
            calls[d.index]!.arguments += d.arguments
          }
          done = done || delta.done
          updateMessage(cid, replyId) { m in
            m.text += delta.text
            m.reasoning += delta.reasoning
            if delta.finishReason == "length" { m.status = "length" }
            if delta.done && m.status == "generating" { m.status = "complete" }
          }
          scheduleSave()
        }
        updateMessage(cid, replyId) { if $0.status == "generating" { $0.status = "interrupted" } }
        let status = message(cid, replyId)?.status
        if !done || status != "complete" || !isCurrent() { return }
        if calls.isEmpty { break }
        var background = false
        var continued = false
        for key in order {
          var call = calls[key]!
          if !isCurrent() { return }
          if call.id.isEmpty { call.id = "call_\(newId())" }
          let isMedia = ["generate_image", "generate_video"].contains(call.name)
          let isManagement = management && modelToolNames.contains(call.name)
          if !isMedia && !isManagement {
            updateMessage(cid, replyId) {
              $0.error = "模型请求了未开放的工具，未执行"
              $0.status = "interrupted"
            }
            continue
          }
          updateMessage(cid, replyId) { $0.calls.append(call) }
          let args =
            (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)))?.object ?? [:]
          if isManagement {
            let result: String
            if let action = changesModels(call.name, args), !(await confirmed(action)) {
              if !isCurrent() { return }
              result = Persistence.encode(.object(["error": .string("用户没有同意此操作（\(action)），未执行")]))
            } else {
              // Cancelled while the question was open: the change the person agreed to afterwards is not made.
              if !isCurrent() { return }
              result = try await api.modelTool(requestId: requestId, name: call.name, args: args)
              if !isCurrent() { return }
            }
            updateMessage(cid, replyId) { $0.toolResults[call.id] = result }
            continued = true
          } else {
            let kind = call.name == "generate_video" ? "video" : "image"
            let task = MediaTask(id: newId(), kind: kind, prompt: args["prompt"]?.string ?? "", args: args, callId: call.id)
            update(cid) {
              $0.tasks.append(task)
              $0.messages.append(ChatMessage("tool", task.prompt, taskId: task.id))
            }
            runMedia(cid, task.id)
            background = true
          }
        }
        scheduleSave()
        if background || !continued { break }
        if round == rounds - 1 {
          updateMessage(cid, reply.id) {
            $0.error = "已达到本轮工具调用上限，请明确下一步操作"
            $0.status = "interrupted"
          }
        }
      }
    }
    do {
      try await loop()
    } catch let e as JarvisException {
      if isCurrent() {
        updateMessage(cid, reply.id) {
          $0.status = "interrupted"
          $0.error = e.message
        }
        if e.unauthorized { expireSession() }
      }
    } catch {
      if isCurrent() {
        updateMessage(cid, reply.id) {
          $0.status = "interrupted"
          $0.error = "连接中断，已保留收到的内容；未自动重试"
        }
      }
    }
    if active[cid]?.messageId == reply.id { active[cid] = nil }
    if !disposed { await save() }
  }

  /// Asks the model to carry on after a reply that stopped at the length limit.
  public func continueReply() async {
    let c = current
    if !c.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !c.pendingAttachments.isEmpty || isGenerating(c.id) { return }
    // Sending is refused (and the draft would linger in the composer) while signed out, without a model or loading.
    if !authenticated || model.isEmpty || attachmentsLoading(c.id) { return }
    update(c.id) { $0.draft = "请继续" }
    await send()
    // A send that did not start (voice not ready, say) must not leave the prompt behind for the person to find.
    if conversation(c.id)?.draft == "请继续" {
      update(c.id) { $0.draft = "" }
      scheduleSave(draftOnly: true)
    }
  }

  public func regenerate() async {
    let c = current
    if isGenerating(c.id) || (voice?.active == true && voice?.conversationId == c.id) { return }
    guard let index = c.messages.lastIndex(where: { $0.role == "user" && !$0.hidden }) else { return }
    let following = c.messages[(index + 1)...]
    if following.contains(where: { m in m.taskId != nil && c.tasks.contains { $0.id == m.taskId && $0.pending } }) {
      error = "原媒体任务仍在运行，可以直接发送新的请求"
      return
    }
    // The composer is not ours to overwrite, and nothing may be hidden unless the resend is going to start.
    if !c.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !c.pendingAttachments.isEmpty {
      error = "输入框里还有未发送的内容，请先发送或清空后再重新生成"
      return
    }
    if attachmentsLoading(c.id) || !authenticated || model.isEmpty {
      error = attachmentsLoading(c.id) ? "附件仍在处理，请稍后再重新生成" : "当前无法发送，请检查连接后再重新生成"
      return
    }
    let user = c.messages[index]
    update(c.id) { c in
      for j in index..<c.messages.count { c.messages[j].hidden = true }
      c.draft = user.text
      c.pendingAttachments = user.attachments
    }
    await send()
  }

  // MARK: Pictures and videos

  public func retryMedia(_ ownerId: String, _ taskId: String) async {
    guard let task = task(ownerId, taskId), mediaActive[taskId] == nil else { return }
    if task.source == "voice", task.jobId != nil, task.status != "failed" {
      updateTask(ownerId, taskId) {
        $0.status = "in_progress"
        $0.error = nil
      }
      await pollVoiceTaskNow(ownerId, taskId)
      return
    }
    updateTask(ownerId, taskId) {
      $0.source = "http"
      $0.error = nil
      $0.status = "queued"
    }
    await runMediaNow(ownerId, taskId, resume: task.jobId != nil)
  }

  /// Stops a running image or video task: the service call is cancelled and the card says so (and can be retried), which
  /// also lets the conversation be deleted again.
  public func cancelMediaTask(_ ownerId: String, _ taskId: String) {
    if let request = mediaActive.removeValue(forKey: taskId) { api.cancel(request) }
    if task(ownerId, taskId)?.pending == true {
      updateTask(ownerId, taskId) {
        $0.status = "interrupted"
        $0.error = "已取消"
      }
    }
    scheduleSave()
  }

  public func startMedia(kind: String, prompt: String, args: [String: JSONValue] = [:]) {
    guard authenticated, settings.tools else { return }
    let owner = current.id
    var merged = args
    merged["prompt"] = .string(prompt)
    let task = MediaTask(id: newId(), kind: kind, prompt: prompt, args: merged)
    update(owner) {
      $0.tasks.append(task)
      $0.messages.append(ChatMessage("tool", prompt, taskId: task.id))
    }
    runMedia(owner, task.id)
  }

  /// Runs in the background; `runMediaNow` is the same awaited.
  func runMedia(_ ownerId: String, _ taskId: String, resume: Bool = false) {
    Task { await runMediaNow(ownerId, taskId, resume: resume) }
  }

  public func runMediaNow(_ ownerId: String, _ taskId: String, resume: Bool = false) async {
    if mediaActive[taskId] != nil { return }
    let request = "media_\(newId())"
    mediaActive[taskId] = request
    let began = clock()
    updateTask(ownerId, taskId) {
      $0.status = "in_progress"
      // A job that is followed again after the app was away keeps its timeline; a new run starts one.
      if !(resume && $0.track != nil) {
        $0.track = MediaTrack(startedAt: began)
        $0.progress = 0
        $0.phase = ""
      }
    }
    scheduleSave()
    do {
      guard let task = task(ownerId, taskId) else { throw JarvisException("任务不存在") }
      let model = models.first { $0.kind == task.kind }
      if model == nil || task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw JarvisException("当前模型不支持此任务，或提示词为空")
      }
      let maxSeconds = JSONValue.object(model!.metadata)["limits"]?["max_seconds"]?.int ?? 5
      if let seconds = task.args["seconds"], seconds != .null {
        guard let n = seconds.double, n >= 1, n <= Double(maxSeconds) else { throw JarvisException("当前视频支持1至\(maxSeconds)秒") }
      }
      var args = task.args
      args["model"] = .string(model!.id)
      let urls = try await api.generate(
        requestId: request, kind: task.kind, args: args, resumeJobId: resume ? task.jobId : nil,
        onJob: { [weak self] id in
          Task { @MainActor in
            self?.updateTask(ownerId, taskId) { $0.jobId = id }
            self?.scheduleSave()
          }
        },
        onProgress: { [weak self] report in Task { @MainActor in self?.noteMedia(ownerId, taskId, report) } })
      if mediaActive[taskId] != request { return }
      if urls.isEmpty { throw JarvisException("任务没有返回作品地址") }
      updateTask(ownerId, taskId) {
        $0.urls = urls
        $0.status = "completed"
        $0.error = nil
        $0.progress = 100
      }
      learnTimings(ownerId, taskId)
    } catch {
      if mediaActive[taskId] == request {
        let stuck = (error as? JarvisException)?.stalled == true
        updateTask(ownerId, taskId) {
          $0.status = stuck ? "interrupted" : "failed"
          $0.error = (error as? JarvisException)?.message ?? "生成失败，请稍后重试原任务"
          // A job that stopped reporting is not followed again: the retry submits a new one.
          if stuck { $0.jobId = nil }
        }
      }
    }
    if mediaActive[taskId] == request { mediaActive[taskId] = nil }
    if !disposed { await save() }
  }

  /// A report of the service about a running job: the number, the stage, and when each part of the run began.
  func noteMedia(_ ownerId: String, _ taskId: String, _ report: MediaReport) {
    let at = clock()
    updateTask(ownerId, taskId) { task in
      guard task.pending else { return }
      task.progress = report.progress
      if !report.phase.isEmpty { task.phase = report.phase }
      var track = task.track ?? MediaTrack(startedAt: at)
      track.note(report, at: at)
      task.track = track
    }
  }

  /// What a finished run took becomes part of what the next one is said to need.
  func learnTimings(_ ownerId: String, _ taskId: String) {
    guard let task = task(ownerId, taskId), let track = task.track else { return }
    var seen = mediaTimings
    seen.learn(kind: task.kind, args: task.args, track: track, finishedAt: clock())
    guard seen != mediaTimings else { return }
    mediaTimings = seen
    if let data = try? JSONEncoder().encode(seen) { timingDefaults.set(data, forKey: Self.timingKey) }
  }

  /// How often a voice job is asked about, and how long it is followed before it is marked interrupted (a stuck server
  /// task would otherwise be polled forever and keep its conversation from being deleted).
  public var voicePollInterval: TimeInterval = 1
  public var voicePollDeadline: TimeInterval = 30 * 60
  /// How long a followed job may report nothing before it is given up as stuck (nil: by kind).
  public var voiceQuietLimit: TimeInterval?

  func pollVoiceTask(_ ownerId: String, _ taskId: String) {
    Task { await pollVoiceTaskNow(ownerId, taskId) }
  }

  func pollVoiceTaskNow(_ ownerId: String, _ taskId: String) async {
    guard mediaActive[taskId] == nil, let jobId = task(ownerId, taskId)?.jobId else { return }
    let request = "poll_\(newId())"
    mediaActive[taskId] = request
    var failures = 0
    let started = Date()
    var lastKey = ""
    var lastMove = Date()
    // Checked after asking, never before: the first poll after iOS kept the app suspended past the deadline must not
    // write off a job the server has finished in the meantime.
    func overdue() -> Bool { Date().timeIntervalSince(started) > voicePollDeadline }
    func pending() -> Bool { task(ownerId, taskId)?.pending == true }
    func interrupt(_ message: String) { updateTask(ownerId, taskId) { $0.status = "interrupted"; $0.error = message } }
    loop: while !disposed, authenticated, pending(), mediaActive[taskId] == request {
      try? await Task.sleep(nanoseconds: UInt64(voicePollInterval * 1_000_000_000))
      if disposed || !authenticated || !pending() || mediaActive[taskId] != request { break }
      let state: [String: JSONValue]
      do {
        state = try await api.jobStatus(jobId)
        failures = 0
      } catch {
        if let e = error as? JarvisException, e.unauthorized {
          expireSession()
          break loop
        }
        failures += 1
        if failures >= 20 {
          interrupt("暂时无法检查任务，服务器可能仍在运行；请检查原任务")
          break loop
        }
        if overdue() {
          interrupt("任务等待时间过长，服务器可能仍在运行；请检查原任务")
          break loop
        }
        continue
      }
      if mediaActive[taskId] != request || !pending() { break }
      let status = state["status"]?.string
      var justCompleted = false
      noteMedia(
        ownerId, taskId,
        MediaReport(progress: state["progress"]?.double ?? 0, phase: state["phase"]?.string ?? "", status: status ?? ""))
      updateTask(ownerId, taskId) { task in
        task.progress = state["progress"]?.double ?? task.progress
        if ["completed", "succeeded"].contains(status ?? "") {
          var urls = stringList(state["urls"])
          if state["urls"] == nil || state["urls"] == .null {
            urls = (state["data"]?.array ?? []).compactMap { $0["url"]?.string }
          }
          task.urls = urls
          task.settleKind((state["kind"] ?? state["job_type"] ?? state["object"])?.string)
          if task.urls.isEmpty && task.kind == "video" { task.urls = ["/v1/videos/\(JarvisAPI.pathEncode(jobId))/content"] }
          task.status = task.urls.isEmpty ? "failed" : "completed"
          task.error = task.urls.isEmpty ? "任务未返回作品地址" : nil
          task.progress = 100
          justCompleted = !task.urls.isEmpty
        } else if ["failed", "cancelled"].contains(status ?? "") {
          task.status = "failed"
          task.error = "生成失败，请重试原任务"
        }
      }
      if justCompleted { learnTimings(ownerId, taskId) }
      if pending() {
        let key = "\(state["progress"]?.double ?? 0)|\(state["phase"]?.string ?? "")"
        if key != lastKey || state["phase"]?.string == "queued" || status == "queued" {
          lastKey = key
          lastMove = Date()
        } else if let t = task(ownerId, taskId),
          Date().timeIntervalSince(lastMove) > (voiceQuietLimit ?? MediaProgress.quietLimit(kind: t.kind, args: t.args))
        {
          let message = MediaProgress.quietMessage(Date().timeIntervalSince(lastMove))
          updateTask(ownerId, taskId) {
            $0.status = "interrupted"
            $0.error = message
            // Followed no more; the retry submits a new job.
            $0.jobId = nil
            $0.source = "http"
          }
          scheduleSave()
          break loop
        }
      }
      if pending() && overdue() { interrupt("任务等待时间过长，服务器可能仍在运行；请检查原任务") }
      scheduleSave()
    }
    if mediaActive[taskId] == request { mediaActive[taskId] = nil }
    if !disposed { await save() }
  }

  /// A job event of a call (the realtime session's): a task is made or updated and, for a new job, followed.
  public func voiceTask(_ ownerId: String, _ event: [String: JSONValue]) {
    guard let owner = conversation(ownerId) else { return }
    let call = (event["call_id"] ?? event["id"])?.string
    let jobId = event["job_id"]?.string
    let type = event["type"]?.string
    var task = owner.tasks.first { t in (call != nil && t.callId == call) || (jobId != nil && t.jobId == jobId) }
    // A job event that names neither the call nor a known job belongs to the newest voice task still waiting for one.
    if task == nil, type != "call" {
      task = owner.tasks.last { $0.source == "voice" && $0.pending && $0.jobId == nil }
    }
    let hint = (event["kind"] ?? event["job_type"] ?? event["object"]).map { $0.string ?? "\($0)" } ?? "null"
    if type == "call" {
      guard ["generate_image", "generate_video"].contains(event["name"]?.string ?? "") else { return }
      let args = (try? JSONDecoder().decode(JSONValue.self, from: Data((event["arguments"]?.string ?? "{}").utf8)))?.object ?? [:]
      if task == nil {
        task = MediaTask(
          id: newId(), kind: event["name"]?.string == "generate_video" ? "video" : "image", prompt: args["prompt"]?.string ?? "",
          args: args, callId: call, status: "in_progress", source: "voice")
        task?.track = MediaTrack(startedAt: clock())
      }
    } else if task == nil {
      task = MediaTask(
        id: newId(), kind: hint.contains("video") ? "video" : "image", prompt: "", args: [:], callId: call,
        status: "in_progress", source: "voice")
      task?.track = MediaTrack(startedAt: clock())
    }
    guard var task else { return }
    if !owner.tasks.contains(where: { $0.id == task.id }) {
      update(ownerId) {
        $0.tasks.append(task)
        $0.messages.append(ChatMessage("tool", task.prompt, taskId: task.id))
      }
    }
    if let jobId { task.jobId = jobId }
    if type == "localrouter.job.done" {
      task.status = event["status"]?.string == "completed" ? "completed" : "failed"
      task.urls = stringList(event["urls"])
      task.settleKind(hint)
      if task.status == "completed", task.urls.isEmpty, task.kind == "video", let id = task.jobId {
        task.urls = ["/v1/videos/\(JarvisAPI.pathEncode(id))/content"]
      }
      task.error = task.status == "failed" ? "生成失败，请重试原任务" : nil
    }
    let saved = task
    updateTask(ownerId, saved.id) { $0 = saved }
    if type == "localrouter.job.created", saved.jobId != nil { pollVoiceTask(ownerId, saved.id) }
    scheduleSave()
  }

  // MARK: Saving

  private var saveTimer: Task<Void, Never>?
  private var saveTail: Task<Void, Never> = Task {}
  private var draftDirty: Set<String> = []
  private var fullSaveDue = true
  private var dirty = true
  private var savedHead: String?
  private var lastSaveAt = Date()
  /// The longest a pending change waits for the debounce while saves keep being rescheduled.
  public var maxSaveWait: TimeInterval = 5
  public var saveDebounce: TimeInterval = 0.5

  private var appState: AppState {
    var s = AppState(server: api.endpoint.jarvisOrigin)
    s.model = model
    s.settings = settings
    s.cookie = api.cookie
    s.selectedId = selectedId
    s.effort = effort
    s.theme = theme
    s.gcHold = gcHold
    s.conversations = conversations
    return s
  }

  /// `draftOnly`: nothing but a draft changed (the timer may then take the cheap path).
  public func scheduleSave(draftOnly: Bool = false) {
    if disposed { return }
    dirty = true
    if !draftOnly { fullSaveDue = true }
    // Every streamed delta restarts the debounce: a long reply would otherwise not be written until it ends.
    let due = initialized && !storageBlocked && Date().timeIntervalSince(lastSaveAt) > maxSaveWait
    saveTimer?.cancel()
    if due {
      Task { await saveNow(cheap: !fullSaveDue) }
      return
    }
    let wait = saveDebounce
    saveTimer = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      await self.saveNow(cheap: !self.fullSaveDue)
    }
  }

  public func save() async { await saveNow(cheap: false) }

  /// Writes now what a moment's wait was holding back, the quick way (the conversations not changed keep their last encoding): for the
  /// app going inactive, which may be the last chance (swiped away in the app switcher), without the cost of a whole save each time.
  public func flushPending() async {
    guard saveTimer != nil else { return }
    await saveNow(cheap: !fullSaveDue)
  }

  /// `save` unless nothing changed since the last write: the app going inactive and then paused would otherwise re-encode
  /// and re-encrypt the whole history twice for nothing.
  public func saveIfDirty() async {
    if !initialized || storageBlocked {
      await saveTail.value
      return
    }
    if dirty || saveFailed || saveTimer != nil || Persistence.head(appState) != savedHead {
      await save()
      return
    }
    // The write still running can yet fail, and nothing else would try it again.
    await saveTail.value
    if saveFailed && !disposed { await save() }
  }

  private func saveNow(cheap: Bool) async {
    saveTimer?.cancel()
    saveTimer = nil
    // Before the saved file is read the lists are empty and the cookie is null: writing now would erase it.
    if !initialized || storageBlocked {
      await saveTail.value
      return
    }
    lastSaveAt = Date()
    let state = appState
    let text = writer.text(state, cheap: cheap, draftDirty: draftDirty)
    draftDirty = []
    fullSaveDue = false
    // A draft-only save reuses the other conversations' last encodings: a change made since without asking for a save is
    // not in it, so only a full save counts as having written everything.
    if !cheap { dirty = false }
    savedHead = Persistence.head(state)
    let vault = self.vault
    let previous = saveTail
    let write = Task { [weak self] () -> Void in
      await previous.value
      let failed: Bool
      do {
        try await Task.detached { try vault.writeState(text) }.value
        failed = false
      } catch { failed = true }
      await MainActor.run {
        guard let self else { return }
        if failed {
          self.dirty = true
          self.saveFailed = true
          self.storageError = "本机保存失败，请勿清除应用资料"
        } else if self.saveFailed {
          self.saveFailed = false
          self.storageError = nil
        }
      }
      if !failed { await self?.collectBlobs() }
    }
    saveTail = write
    await write.value
  }

  /// Leaves the unreadable saved file aside and lets saving replace it. The user has to ask for this.
  public func startFresh() async {
    guard storageBlocked else { return }
    do { try vault.keepUnreadable() } catch {
      storageError = "无法备份原文件，未清空；请重启应用重试"
      return
    }
    storageBlocked = false
    storageError = nil
    blobsDirty = false
    // The preserved file still names attachments; collecting now (or after the next launch) would delete them.
    gcHold = true
    await save()
  }

  public func dispose() {
    disposed = true
    catalogEpoch += 1
    voiceSettingsTask?.cancel()
    retryTask?.cancel()
    saveTimer?.cancel()
    api.close()
  }
}

/// The temp folders this app fills with media it can fetch again; none of it is user data.
public enum LocalData {
  public static let folders = ["jarvis-video", "jarvis-transfer", "jarvis-backup"]
  nonisolated(unsafe) public static var tempRoot: URL = FileManager.default.temporaryDirectory
  nonisolated(unsafe) public static var sweepOnStart = true

  public static func clearStaleCachedMedia() {
    if sweepOnStart { clear() }
  }

  /// The folders kept in the system's cache folder between launches (a video is not fetched again at every start); they go with
  /// the sign-out and the clearing of local data, not at launch.
  public static let cacheFolders = ["jarvis-video"]
  nonisolated(unsafe) public static var cacheRoot: URL =
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
  /// Called after the media is cleared, for what is kept in memory besides (the covers of the videos).
  nonisolated(unsafe) public static var onCleared: (@Sendable () -> Void)?

  public static func clearCachedMedia() {
    clear()
    for name in cacheFolders { try? FileManager.default.removeItem(at: cacheRoot.appendingPathComponent(name, isDirectory: true)) }
    onCleared?()
  }

  private static func clear() {
    for name in folders {
      let folder = tempRoot.appendingPathComponent(name, isDirectory: true)
      for entry in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
        try? FileManager.default.removeItem(at: entry)
      }
    }
  }
}
