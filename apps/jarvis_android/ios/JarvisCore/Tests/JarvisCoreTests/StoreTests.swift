import XCTest

@testable import JarvisCore

/// A service in memory: what it answers is set per test.
final class FakeTransport: Transport, @unchecked Sendable {
  var apiKey = ""
  var cookie: String?
  let endpoint = URL(string: "https://jarvis.test")!
  var loginResult: Result<String, Error> = .success("__Host-jarvis_session=ok")
  var modelsResult: Result<[ModelInfo], Error> = .success([ModelInfo("chat-a", "chat-a"), ModelInfo("img", "img", kind: "image")])
  var skill: [String: JSONValue] = ["enabled": .bool(false), "text": .string("")]
  /// One script per chat call, used in turn.
  var chats: [[Result<ChatDelta, Error>]] = []
  var chatRequests: [[[String: JSONValue]]] = []
  var chatOptions: [ChatOptions] = []
  var chatGate: (() async -> Void)?
  var generated: Result<[String], Error> = .success(["/v1/files/1.png"])
  var generateDelay: Double = 0
  var cancelled: [String] = []
  var jobs: [[String: JSONValue]] = []
  var toolReply = "{\"ok\":true}"
  var toolCalls: [(String, [String: JSONValue])] = []
  private let lock = NSLock()

  func login(_ username: String, _ password: String) async throws {
    switch loginResult {
    case .success(let c): cookie = c
    case .failure(let e): throw e
    }
  }
  func logout() async throws { cookie = nil }
  var modelsCalls = 0
  /// The speech engine the voice tests use.
  var speechModel: ModelInfo { ModelInfo("tts", "tts", kind: "speech", voices: [VoiceInfo("amy", "Amy", "")], defaultVoice: "amy") }
  func models() async throws -> [ModelInfo] {
    modelsCalls += 1
    return try modelsResult.get()
  }
  func modelSkill() async throws -> [String: JSONValue] { skill }
  func modelTool(requestId: String, name: String, args: [String: JSONValue]) async throws -> String {
    toolCalls.append((name, args))
    return toolReply
  }
  func chat(requestId: String, model: String, effort: String, messages: [[String: JSONValue]], options: ChatOptions)
    -> AsyncThrowingStream<ChatDelta, Error>
  {
    lock.lock()
    chatRequests.append(messages)
    chatOptions.append(options)
    let script = chats.isEmpty ? [] : chats.removeFirst()
    lock.unlock()
    return AsyncThrowingStream { continuation in
      let task = Task {
        await self.chatGate?()
        for step in script {
          if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
          switch step {
          case .success(let d): continuation.yield(d)
          case .failure(let e): continuation.finish(throwing: e); return
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
  func download(_ path: String) async throws -> Data { Data() }
  func download(_ path: String, to file: URL) async throws -> Int { 0 }
  func toolsStatus() async throws -> [String: JSONValue] { ["data": .array([])] }
  func cancel(_ requestId: String) { lock.lock(); cancelled.append(requestId); lock.unlock() }
  func generate(
    requestId: String, kind: String, args: [String: JSONValue], resumeJobId: String?, onJob: ((String) -> Void)?,
    onProgress: ((MediaReport) -> Void)?
  ) async throws -> [String] {
    onJob?("job-1")
    onProgress?(MediaReport(progress: 50, phase: "generating", status: "in_progress"))
    if generateDelay > 0 { try await Task.sleep(nanoseconds: UInt64(generateDelay * 1_000_000_000)) }
    return try generated.get()
  }
  func jobStatus(_ id: String) async throws -> [String: JSONValue] {
    lock.lock(); defer { lock.unlock() }
    return jobs.isEmpty ? ["status": .string("in_progress")] : jobs.removeFirst()
  }
  func mediaURL(_ path: String) throws -> URL { URL(string: path, relativeTo: endpoint)!.absoluteURL }
  var wires: [FakeWire] = []
  var realtimeFailure: Error?
  func openRealtime() async throws -> RealtimeWire {
    if let realtimeFailure { throw realtimeFailure }
    let wire = FakeWire()
    lock.lock(); wires.append(wire); lock.unlock()
    return wire
  }
  var previewBytes = Data()
  var previewFailure: Error?
  func preview(_ voice: VoiceInfo, model: String) async throws -> Data {
    if let previewFailure { throw previewFailure }
    return previewBytes
  }
  func synthesize(_ voice: VoiceInfo, model: String) async throws -> Data { previewBytes }
  func close() {}
}

func reply(_ text: String, done: Bool = true, finish: String? = nil) -> [Result<ChatDelta, Error>] {
  [.success(ChatDelta(text: text, finishReason: finish)), .success(ChatDelta(done: done))]
}

@MainActor
final class StoreTests: XCTestCase {
  var api: FakeTransport!
  var vault: MemoryVault!
  var store: JarvisStore!

  override func setUp() async throws {
    LocalData.sweepOnStart = false
    api = FakeTransport()
    vault = MemoryVault()
    store = JarvisStore(api: api, vault: vault)
    store.saveDebounce = 0.01
  }

  func signedIn() async {
    await store.initialize()
    let ok = await store.login("u", "p")
    XCTAssertTrue(ok)
  }

  func saved() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(try vault.readState()!.utf8))
  }

  func testAFreshStartHasOneEmptyConversationAndIsSignedOut() async {
    await store.initialize()
    XCTAssertTrue(store.initialized)
    XCTAssertFalse(store.authenticated)
    XCTAssertEqual(store.conversations.count, 1)
    XCTAssertEqual(store.selectedId, store.conversations[0].id)
  }

  func testASavedSessionConnectsAndPicksAModel() async throws {
    try vault.writeState(#"{"version":1,"server":"https://jarvis.test","model":"gone","cookie":"c=1","settings":{"apiKey":"k"},"conversations":[{"id":"a","title":"旧","messages":[]}]}"#)
    await store.initialize()
    XCTAssertTrue(store.authenticated)
    XCTAssertEqual(store.model, "chat-a", "a saved model the server no longer has is replaced")
    XCTAssertEqual(api.apiKey, "k")
    XCTAssertEqual(store.conversations.map(\.id), ["a"])
  }

  func testAnUnreadableFileKeepsTheStoreReadOnly() async throws {
    try vault.writeState("garbage")
    await store.initialize()
    XCTAssertTrue(store.storageReadOnly)
    XCTAssertNotNil(store.storageError)
    store.setDraft("x")
    await store.save()
    XCTAssertEqual(try vault.readState(), "garbage", "nothing overwrites the only copy")
    await store.startFresh()
    XCTAssertFalse(store.storageReadOnly)
    XCTAssertNotEqual(try vault.readState(), "garbage")
  }

  func testLoginWritesTheSessionDownAndFailureSaysWhy() async throws {
    await signedIn()
    XCTAssertEqual(try saved()["cookie"]?.string, "__Host-jarvis_session=ok")
    let other = JarvisStore(api: FakeTransport(), vault: MemoryVault())
    let bad = other.api as! FakeTransport
    bad.loginResult = .failure(JarvisException("登录未成功，请检查账户与密码"))
    await other.initialize()
    let ok = await other.login("u", "p")
    XCTAssertFalse(ok)
    XCTAssertEqual(other.error, "登录未成功，请检查账户与密码")
    XCTAssertFalse(other.connecting)
  }

  func testASignInIsToldApartByWhatTheServerSaid() async throws {
    // The password was good but the catalogue could not be fetched after it: not connected, yet accepted.
    api.modelsResult = .failure(URLError(.notConnectedToInternet))
    store.offlineRetryDelay = { _ in 3600 }
    await store.initialize()
    let accepted = await store.signIn("u", "p")
    XCTAssertEqual(accepted, .accepted)
    // A refused password is rejected; a server that is down says nothing about the password.
    func outcome(_ error: JarvisException) async -> JarvisStore.LoginOutcome {
      let other = JarvisStore(api: FakeTransport(), vault: MemoryVault())
      (other.api as! FakeTransport).loginResult = .failure(error)
      await other.initialize()
      return await other.signIn("u", "bad")
    }
    let refused = await outcome(JarvisException(JarvisAPI.loginRejectedMessage))
    XCTAssertEqual(refused, .rejected)
    let down = await outcome(JarvisException("服务暂时不可用（502）"))
    XCTAssertEqual(down, .failed)
  }

  func testAServerThatIsDownAfterLoginKeepsTheSessionOffline() async throws {
    try vault.writeState(#"{"version":1,"server":"https://jarvis.test","cookie":"c=1","conversations":[{"id":"a","messages":[]}]}"#)
    api.modelsResult = .failure(URLError(.notConnectedToInternet))
    store.offlineRetryDelay = { _ in 3600 }
    await store.initialize()
    XCTAssertFalse(store.authenticated)
    XCTAssertTrue(store.offlineSession)
    XCTAssertEqual(store.connectionError, "暂时无法连接服务，请检查网络后重试")
    api.modelsResult = .success([ModelInfo("chat-a", "chat-a")])
    await store.retryConnect()
    XCTAssertTrue(store.authenticated)
    XCTAssertFalse(store.offlineSession)
  }

  func testAnExpiredSessionSendsTheUserBackToLogin() async throws {
    try vault.writeState(#"{"version":1,"server":"https://jarvis.test","cookie":"c=1","conversations":[{"id":"a","messages":[]}]}"#)
    api.modelsResult = .failure(JarvisException("登录已过期，请重新登录", unauthorized: true))
    await store.initialize()
    XCTAssertFalse(store.authenticated)
    XCTAssertNil(api.cookie)
    XCTAssertEqual(store.error, "登录已过期，请重新登录")
  }

  func testSendingStreamsTheReplyTitlesTheConversationAndSavesIt() async throws {
    await signedIn()
    api.chats = [reply("你好呀")]
    store.setDraft("  你好  ")
    await store.send()
    let c = store.current
    XCTAssertEqual(c.title, "你好")
    XCTAssertEqual(c.messages.map(\.role), ["user", "assistant"])
    XCTAssertEqual(c.messages[0].text, "你好")
    XCTAssertEqual(c.messages[1].text, "你好呀")
    XCTAssertEqual(c.messages[1].status, "complete")
    XCTAssertEqual(c.draft, "")
    XCTAssertFalse(store.isGenerating(c.id))
    let first = try saved()["conversations"]!.array![0]
    XCTAssertEqual(first["messages"]?.array?.count, 2)
    // what the model was sent: the system line and the user's text
    XCTAssertEqual(api.chatRequests[0].last?["content"], .string("你好"))
  }

  func testNothingIsSentWithoutTextOrSignIn() async {
    await store.initialize()
    store.setDraft("hi")
    await store.send()
    XCTAssertTrue(store.current.messages.isEmpty, "signed out")
    await signedIn()
    store.setDraft("   ")
    await store.send()
    XCTAssertTrue(store.current.messages.isEmpty)
  }

  func testAStreamThatStopsWithoutDoneIsMarkedInterrupted() async {
    await signedIn()
    api.chats = [[.success(ChatDelta(text: "半句"))]]
    store.setDraft("x")
    await store.send()
    let m = store.current.messages[1]
    XCTAssertEqual(m.text, "半句")
    XCTAssertEqual(m.status, "interrupted")
  }

  func testAReplyCutAtTheLengthLimitSaysSo() async {
    await signedIn()
    api.chats = [reply("很长", finish: "length")]
    store.setDraft("x")
    await store.send()
    XCTAssertEqual(store.current.messages[1].status, "length")
  }

  func testAFailureKeepsWhatArrivedAndSaysWhat() async {
    await signedIn()
    api.chats = [[.success(ChatDelta(text: "半")), .failure(JarvisException("模型返回错误，已保留收到的内容"))]]
    store.setDraft("x")
    await store.send()
    let m = store.current.messages[1]
    XCTAssertEqual(m.text, "半")
    XCTAssertEqual(m.status, "interrupted")
    XCTAssertEqual(m.error, "模型返回错误，已保留收到的内容")
  }

  func testAnExpiredSessionDuringChatSignsOut() async {
    await signedIn()
    api.chats = [[.failure(JarvisException("登录已过期，请重新登录", unauthorized: true))]]
    store.setDraft("x")
    await store.send()
    XCTAssertFalse(store.authenticated)
    XCTAssertEqual(store.current.messages[1].error, "登录已过期，请重新登录")
  }

  func testCancellingStopsTheReplyAndTheRequest() async throws {
    await signedIn()
    let started = expectation(description: "stream started")
    api.chatGate = { started.fulfill(); try? await Task.sleep(nanoseconds: 5_000_000_000) }
    api.chats = [reply("never")]
    store.setDraft("x")
    let sending = Task { await store.send() }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertTrue(store.isGenerating(store.current.id))
    store.cancel(store.current.id)
    XCTAssertEqual(store.current.messages[1].status, "interrupted")
    XCTAssertEqual(api.cancelled.count, 1)
    sending.cancel()
    await sending.value
  }

  func testAPictureToolCallMakesATaskThatCompletes() async throws {
    await signedIn()
    api.chats = [[.success(ChatDelta(finishReason: "tool_calls", toolDeltas: [ToolDelta(0, "call-1", "generate_image", "{\"prompt\":\"猫\"}")])), .success(ChatDelta(done: true))]]
    store.setDraft("画只猫")
    await store.send()
    // the task runs in the background
    for _ in 0..<50 where store.current.tasks.first?.status != "completed" { try await Task.sleep(nanoseconds: 20_000_000) }
    let c = store.current
    XCTAssertEqual(c.tasks.count, 1)
    XCTAssertEqual(c.tasks[0].status, "completed")
    XCTAssertEqual(c.tasks[0].urls, ["/v1/files/1.png"])
    XCTAssertEqual(c.tasks[0].prompt, "猫")
    XCTAssertEqual(c.tasks[0].callId, "call-1")
    XCTAssertEqual(c.tasks[0].jobId, "job-1")
    XCTAssertEqual(c.messages.map(\.role), ["user", "assistant", "tool"])
    XCTAssertEqual(c.messages[2].taskId, c.tasks[0].id)
    XCTAssertEqual(c.messages[1].calls.first?.name, "generate_image")
  }

  func testAToolTheModelWasNotOfferedIsRefused() async {
    await signedIn()
    api.chats = [[.success(ChatDelta(toolDeltas: [ToolDelta(0, "c", "rm_rf", "{}")])), .success(ChatDelta(done: true))]]
    store.setDraft("x")
    await store.send()
    let m = store.current.messages[1]
    XCTAssertEqual(m.error, "模型请求了未开放的工具，未执行")
    XCTAssertTrue(store.current.tasks.isEmpty)
  }

  func testManagementToolsAreAskedAboutAndContinueTheConversation() async throws {
    api.skill = ["enabled": .bool(true), "text": .string("管理说明")]
    await signedIn()
    store.confirmToolCall = { action in
      XCTAssertEqual(action, "卸载模型 big")
      return false
    }
    api.chats = [
      [.success(ChatDelta(toolDeltas: [ToolDelta(0, "t1", "unload_model", "{\"model\":\"big\"}"), ToolDelta(1, "t2", "list_models", "{}")])), .success(ChatDelta(done: true))],
      reply("好的"),
    ]
    store.setDraft("腾出内存")
    await store.send()
    let c = store.current
    XCTAssertEqual(c.messages.count, 3, "user, the call round, the answer round")
    XCTAssertEqual(c.messages[1].toolResults["t1"], #"{"error":"用户没有同意此操作（卸载模型 big），未执行"}"#)
    XCTAssertEqual(c.messages[1].toolResults["t2"], "{\"ok\":true}")
    XCTAssertEqual(api.toolCalls.map(\.0), ["list_models"], "the refused one never ran")
    XCTAssertEqual(c.messages[2].text, "好的")
    XCTAssertTrue(api.chatRequests[0][0]["content"]!.string!.contains("管理说明"))
    XCTAssertEqual(api.chatOptions[0].tools.count, 5, "the picture tool (one image model here) and the four management tools")
  }

  func testRegenerateHidesTheLastExchangeAndAsksAgain() async {
    await signedIn()
    api.chats = [reply("一"), reply("二")]
    store.setDraft("问")
    await store.send()
    await store.regenerate()
    let c = store.current
    XCTAssertEqual(c.messages.count, 4)
    XCTAssertTrue(c.messages[0].hidden && c.messages[1].hidden)
    XCTAssertEqual(c.messages[3].text, "二")
    // the hidden pair is not sent again
    XCTAssertEqual(api.chatRequests[1].count, 2)
  }

  func testContinueReplyLeavesNoPromptBehind() async {
    await signedIn()
    api.chats = [reply("长", finish: "length"), reply("后续")]
    store.setDraft("写")
    await store.send()
    await store.continueReply()
    XCTAssertEqual(store.current.messages.count, 4)
    XCTAssertEqual(store.current.messages[2].text, "请继续")
    XCTAssertEqual(store.current.draft, "")
  }

  func testAnEmptyConversationIsReusedNotStacked() async {
    await store.initialize()
    let first = store.newConversation()
    XCTAssertEqual(store.conversations.count, 1)
    store.setDraft("草稿")
    let second = store.newConversation()
    XCTAssertEqual(store.conversations.count, 2)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(store.selectedId, second.id)
  }

  func testDeletingCanBeUndoneAndItsAttachmentsOnlyGoAfterTheWindow() async throws {
    await signedIn()
    store.undoWindow = 0.2
    try vault.writeBlob("att1", Data([1]))
    let owner = store.current.id
    try await store.addAttachment(owner, Attachment(id: "att1", name: "a", mime: "image/png", kind: "image"), bytes: nil)
    store.setDraft("x")
    api.chats = [reply("y")]
    await store.send()
    let doomed = store.current
    store.newConversation()
    store.setDraft("别的")
    let removed = store.deleteConversation(doomed.id)
    XCTAssertNotNil(removed)
    await store.save()
    XCTAssertNotNil(try vault.readBlob("att1"), "kept while the undo is offered")
    store.restoreConversation(removed!)
    XCTAssertTrue(store.conversations.contains { $0.id == doomed.id })
    XCTAssertEqual(store.selectedId, doomed.id)
  }

  func testAnAttachmentNobodyReferencesIsCollected() async throws {
    try vault.writeBlob("orphan", Data([1]))
    try vault.writeState(#"{"version":1,"server":"https://jarvis.test","conversations":[{"id":"a","messages":[]}]}"#)
    await store.initialize()
    // The clean-up is not part of starting (it waited for the first page before); it runs a moment after.
    XCTAssertNotNil(try vault.readBlob("orphan"), "not before the first page is up")
    await store.collectBlobs()
    XCTAssertNil(try vault.readBlob("orphan"))
  }

  func testAtMostFourAttachmentsPerMessage() async throws {
    await store.initialize()
    let id = store.current.id
    for i in 0..<4 { try await store.addAttachment(id, Attachment(id: "a\(i)", name: "n", mime: "x/y", kind: "document"), bytes: Data([1])) }
    do {
      try await store.addAttachment(id, Attachment(id: "a5", name: "n", mime: "x/y", kind: "document"), bytes: Data([1]))
      XCTFail()
    } catch { XCTAssertEqual((error as? JarvisException)?.message, "每条消息最多4个附件") }
    XCTAssertNil(try vault.readBlob("a5"), "the refused file is not left behind")
  }

  func testDraftsAreSavedWithoutReencodingAndRestored() async throws {
    await signedIn()
    store.setDraft("写到一半")
    await store.save()
    let again = JarvisStore(api: FakeTransport(), vault: vault)
    await again.initialize()
    XCTAssertEqual(again.current.draft, "写到一半")
  }

  func testSignOutKeepsTheHistoryButNotTheSession() async throws {
    await signedIn()
    api.chats = [reply("ok")]
    store.setDraft("hi")
    await store.send()
    await store.logout()
    XCTAssertFalse(store.authenticated)
    XCTAssertEqual(store.current.messages.count, 2)
    XCTAssertEqual(try saved()["cookie"], .null)
  }

  func testEraseRemovesEverything() async throws {
    await signedIn()
    api.chats = [reply("ok")]
    store.setDraft("hi")
    await store.send()
    try vault.writeBlob("x", Data([1]))
    let erased = await store.clearLocalData()
    XCTAssertTrue(erased)
    XCTAssertEqual(store.conversations.count, 1)
    XCTAssertTrue(store.conversations[0].messages.isEmpty)
    XCTAssertTrue(try vault.listBlobs().isEmpty)
    XCTAssertEqual(try saved()["cookie"], .null)
    XCTAssertEqual(try saved()["conversations"]?.array?.count, 1)
  }

  func testAVoiceJobEventMakesATaskAndFollowsIt() async throws {
    await signedIn()
    store.voicePollInterval = 0.01
    api.jobs = [["status": .string("in_progress"), "progress": JSONValue.number(30)], ["status": .string("completed"), "urls": .array([.string("/v1/files/v.png")])]]
    let owner = store.current.id
    store.voiceTask(owner, ["type": .string("call"), "name": .string("generate_image"), "call_id": .string("vc"), "arguments": .string("{\"prompt\":\"海\"}")])
    XCTAssertEqual(store.current.tasks.count, 1)
    XCTAssertEqual(store.current.tasks[0].source, "voice")
    XCTAssertEqual(store.current.messages.last?.role, "tool")
    store.voiceTask(owner, ["type": .string("localrouter.job.created"), "call_id": .string("vc"), "job_id": .string("j9")])
    for _ in 0..<100 where store.current.tasks.first?.status != "completed" { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertEqual(store.current.tasks[0].status, "completed")
    XCTAssertEqual(store.current.tasks[0].urls, ["/v1/files/v.png"])
    XCTAssertEqual(store.current.tasks[0].jobId, "j9")
  }

  func testAPendingTaskCannotBeDeletedWithItsConversationUntilCancelled() async throws {
    await signedIn()
    api.generateDelay = 5
    store.startMedia(kind: "image", prompt: "慢")
    for _ in 0..<50 where store.current.tasks.first?.status != "in_progress" { try await Task.sleep(nanoseconds: 20_000_000) }
    let c = store.current
    XCTAssertFalse(store.canDeleteConversation(c.id))
    store.cancelMediaTask(c.id, c.tasks[0].id)
    XCTAssertEqual(store.current.tasks[0].status, "interrupted")
    XCTAssertEqual(store.current.tasks[0].error, "已取消")
    XCTAssertTrue(store.canDeleteConversation(c.id))
  }

  func testChangingSettingsSavesThemAndPassesTheKeyOn() async throws {
    await signedIn()
    store.changeSettings { $0.apiKey = "k2"; $0.maxTokens = 100 }
    XCTAssertEqual(api.apiKey, "k2")
    await store.save()
    XCTAssertEqual(try saved()["settings"]?["maxTokens"], .number(100))
  }

  func testRenameMarksTheTitleAsTheUsers() async {
    await store.initialize()
    store.rename(store.current.id, "  我的名字 ")
    XCTAssertEqual(store.current.title, "我的名字")
    XCTAssertTrue(store.current.named)
    store.rename(store.current.id, "   ")
    XCTAssertEqual(store.current.title, "我的名字")
  }

  func testAFinishedRunTeachesTheNextOneHowLongItTakes() async throws {
    await signedIn()
    let defaults = UserDefaults(suiteName: "media-timings-\(UUID().uuidString)")!
    store.timingDefaults = defaults
    var now = 5000.0
    store.clock = { now }
    api.generateDelay = 5
    store.startMedia(kind: "image", prompt: "猫", args: ["size": .string("1024x1024")])
    for _ in 0..<50 where store.current.tasks.first?.status != "in_progress" { try await Task.sleep(nanoseconds: 20_000_000) }
    let owner = store.current.id
    let id = store.current.tasks[0].id
    XCTAssertNotNil(store.current.tasks[0].track, "a run starts its timeline")
    store.updateTask(owner, id) {
      var track = MediaTrack(startedAt: 5000)
      track.genAt = 5001
      track.stepAt = 5011
      track.tailAt = 5018
      $0.track = track
    }
    now = 5020
    store.learnTimings(owner, id)
    XCTAssertEqual(store.mediaTimings.image.runs, 1)
    XCTAssertGreaterThan(store.mediaTimings.image.prep, MediaTimings.prior.image.prep)
    XCTAssertNotNil(defaults.data(forKey: "mediaTimings.v1"))
    store.cancelMediaTask(owner, id)
  }

  func testAReportMovesTheCardsNumberStageAndTimeline() async throws {
    await signedIn()
    store.clock = { 100 }
    api.generateDelay = 5
    store.startMedia(kind: "image", prompt: "海")
    for _ in 0..<50 where store.current.tasks.first?.status != "in_progress" { try await Task.sleep(nanoseconds: 20_000_000) }
    let owner = store.current.id
    let id = store.current.tasks[0].id
    store.noteMedia(owner, id, MediaReport(progress: 37, phase: "generating", status: "in_progress"))
    let task = store.current.tasks[0]
    XCTAssertEqual(task.progress, 37)
    XCTAssertEqual(task.phase, "generating")
    XCTAssertEqual(task.track?.lastProgress, 37)
    store.cancelMediaTask(owner, id)
    store.noteMedia(owner, id, MediaReport(progress: 80, phase: "generating"))
    XCTAssertEqual(store.current.tasks[0].progress, 37, "a cancelled card is not moved by a late report")
  }

  func testAVoiceJobThatStopsReportingIsInterruptedAndItsRetrySubmitsANewOne() async throws {
    await signedIn()
    store.voicePollInterval = 0.01
    store.voiceQuietLimit = 0.1
    api.jobs = Array(repeating: ["status": .string("in_progress"), "phase": .string("generating"), "progress": JSONValue.number(51)], count: 400)
    let owner = store.current.id
    store.voiceTask(owner, ["type": .string("call"), "name": .string("generate_image"), "call_id": .string("vs"), "arguments": .string("{\"prompt\":\"海\"}")])
    store.voiceTask(owner, ["type": .string("localrouter.job.created"), "call_id": .string("vs"), "job_id": .string("jstuck")])
    for _ in 0..<150 where store.current.tasks.first?.status != "interrupted" { try await Task.sleep(nanoseconds: 20_000_000) }
    let task = store.current.tasks[0]
    XCTAssertEqual(task.status, "interrupted")
    XCTAssertTrue(task.error?.contains("没有新进展") == true)
    XCTAssertNil(task.jobId, "a stuck job is not followed again")
    XCTAssertEqual(task.source, "http")
    XCTAssertEqual(task.progress, 51)
  }

  func testRetryingAVoiceJobClearsTheOldMessage() async throws {
    await signedIn()
    store.voicePollInterval = 0.01
    api.jobs = [["status": .string("completed"), "urls": .array([.string("/v1/files/r.png")])]]
    let owner = store.current.id
    store.voiceTask(owner, ["type": .string("call"), "name": .string("generate_image"), "call_id": .string("vr"), "arguments": .string("{\"prompt\":\"海\"}")])
    store.voiceTask(owner, ["type": .string("localrouter.job.created"), "call_id": .string("vr"), "job_id": .string("jr")])
    for _ in 0..<100 where store.current.tasks.first?.status != "completed" { try await Task.sleep(nanoseconds: 20_000_000) }
    let id = store.current.tasks[0].id
    store.updateTask(owner, id) { $0.status = "interrupted"; $0.error = "任务等待时间过长" }
    api.jobs = [["status": .string("completed"), "urls": .array([.string("/v1/files/r.png")])]]
    await store.retryMedia(owner, id)
    XCTAssertNil(store.current.tasks[0].error)
    XCTAssertEqual(store.current.tasks[0].status, "completed")
  }
}
