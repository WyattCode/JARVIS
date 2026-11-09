import XCTest

@testable import JarvisCore

final class APITests: XCTestCase {
  let base = URL(string: "https://jarvis.test")!

  override func setUp() { StubProtocol.reset() }

  func api() throws -> JarvisAPI { try JarvisAPI(base: base, configuration: StubProtocol.configuration) }

  func testOnlyAPlainHTTPSAddressIsAccepted() {
    for bad in ["http://jarvis.test", "https://u:p@jarvis.test", "https://jarvis.test/path", "https://jarvis.test?x=1", "https://jarvis.test#f"] {
      XCTAssertThrowsError(try JarvisAPI(base: URL(string: bad)!), bad)
    }
    XCTAssertNoThrow(try JarvisAPI(base: URL(string: "https://jarvis.test/")!))
  }

  func testLoginSendsAFormWithOriginAndKeepsTheSessionCookie() async throws {
    StubProtocol.handler = { _, _ in
      .init(status: 303, headers: ["Set-Cookie": "__Host-jarvis_session=test-cookie; Path=/; Secure; HttpOnly", "Location": "/"])
    }
    let api = try api()
    try await api.login("测试用户", "a@ b")
    let (request, body) = StubProtocol.seen[0]
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertNil(request.url?.query)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://jarvis.test")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "username=%E6%B5%8B%E8%AF%95%E7%94%A8%E6%88%B7&password=a%40+b")
    XCTAssertEqual(api.cookie, "__Host-jarvis_session=test-cookie")
    XCTAssertEqual(StubProtocol.seen.count, 1, "the redirect is not followed")
  }

  func testLoginRefusedOrRateLimited() async throws {
    StubProtocol.handler = { _, _ in .init(status: 200) }
    let api = try api()
    do { try await api.login("a", "b"); XCTFail() } catch { XCTAssertEqual((error as? JarvisException)?.message, "登录未成功，请检查账户与密码") }
    StubProtocol.handler = { _, _ in .init(status: 429) }
    do { try await api.login("a", "b"); XCTFail() } catch { XCTAssertEqual((error as? JarvisException)?.message, "尝试次数较多，请稍后再试") }
    // A server that is down is not a refused password (what is kept for Face ID is forgotten only on a refusal).
    StubProtocol.handler = { _, _ in .init(status: 502) }
    do { try await api.login("a", "b"); XCTFail() } catch { XCTAssertEqual((error as? JarvisException)?.message, "服务暂时不可用（502）") }
    StubProtocol.handler = { _, _ in .init(status: 401) }
    do { try await api.login("a", "b"); XCTFail() } catch { XCTAssertEqual((error as? JarvisException)?.message, JarvisAPI.loginRejectedMessage) }
    XCTAssertNil(api.cookie)
  }

  func testAnExpiredSessionIsSaidSo() async throws {
    StubProtocol.handler = { _, _ in .init(status: 401) }
    let api = try api()
    do { _ = try await api.models(); XCTFail() } catch {
      XCTAssertEqual((error as? JarvisException)?.unauthorized, true)
    }
    StubProtocol.handler = { _, _ in .init(status: 500) }
    do { _ = try await api.models(); XCTFail() } catch { XCTAssertEqual((error as? JarvisException)?.message, "服务暂时不可用（500）") }
  }

  func testModelsMergeTheListsVoiceRevisionsIntoSpeechEngines() async throws {
    let body = """
      {"voice_catalog_revision":7,"voice_default_revision":2,"data":[
       {"id":"chat-a","name":"chat-a"},
       {"id":"hidden","qualified":false},
       {"id":"tts","kind":"speech","voice_catalog_revision":9,"voices":["x"]}]}
      """
    StubProtocol.handler = { _, _ in .init(chunks: [Data(body.utf8)]) }
    let models = try await api().models()
    XCTAssertEqual(models.map(\.id), ["chat-a", "tts"])
    XCTAssertEqual(models[1].voiceCatalogRevision, 9, "the engine's own revision wins")
    XCTAssertEqual(models[1].voiceDefaultRevision, 2, "the list's fills the gap")
    XCTAssertEqual(models[0].voiceCatalogRevision, 0)
  }

  func testChatKeepsSplitUnicodeToolDeltasAndDone() async throws {
    let text =
      "data: {\"choices\":[{\"delta\":{\"content\":\"中文\",\"tool_calls\":[{\"index\":0,\"id\":\"call1\",\"function\":{\"name\":\"generate_video\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}\r\n\r\ndata: [DONE]\n\n"
    StubProtocol.handler = { _, _ in .init(chunks: Array(text.utf8).map { Data([$0]) }) }
    let api = try api()
    api.cookie = "cookie=test"
    api.apiKey = "test-key"
    var parts: [ChatDelta] = []
    for try await part in api.chat(
      requestId: "r", model: "model", effort: "high", messages: [["role": .string("user"), "content": .string("中文")]],
      options: ChatOptions(maxTokens: 24000))
    { parts.append(part) }
    XCTAssertEqual(parts.first?.text, "中文")
    XCTAssertEqual(parts.first?.toolDeltas.first?.name, "generate_video")
    XCTAssertEqual(parts.first?.finishReason, "tool_calls")
    XCTAssertEqual(parts.last?.done, true)
    let (request, body) = StubProtocol.seen[0]
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "cookie=test")
    let json = try JSONDecoder().decode(JSONValue.self, from: body)
    XCTAssertEqual(json["max_tokens"], .number(24000))
    XCTAssertEqual(json["chat_template_kwargs"]?["enable_thinking"], .bool(true))
    XCTAssertEqual(json["stream"], .bool(true))
    XCTAssertNil(json["tools"])
  }

  func testChatWithoutDoneIsAnInterruptionEvenAfterPartialText() async throws {
    StubProtocol.handler = { _, _ in .init(chunks: [Data("data: {\"choices\":[{\"delta\":{\"content\":\"半句\"}}]}\n\n".utf8)]) }
    var seen: [String] = []
    do {
      for try await part in try api().chat(requestId: "r", model: "m", effort: "none", messages: []) { seen.append(part.text) }
      XCTFail("a stream without [DONE] must not look complete")
    } catch {
      XCTAssertEqual((error as? JarvisException)?.message, "连接中断，已保留收到的内容；未自动重试")
    }
    XCTAssertEqual(seen, ["半句"])
  }

  func testASlowChatStartIsWaitedForLongerThanACheapCall() async throws {
    StubProtocol.handler = { _, _ in .init(chunks: [Data("data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}\n\ndata: [DONE]\n\n".utf8)], delay: 0.3) }
    let api = try api()
    XCTAssertGreaterThanOrEqual(api.chatHeaderTimeout, 90)
    api.chatHeaderTimeout = 0.08
    do {
      for try await _ in api.chat(requestId: "r", model: "m", effort: "high", messages: []) {}
      XCTFail()
    } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
    api.chatHeaderTimeout = 5
    var texts: [String] = []
    for try await part in api.chat(requestId: "r2", model: "m", effort: "high", messages: []) { texts.append(part.text) }
    XCTAssertEqual(texts.first, "好")
  }

  func testCancelStopsAChatThatIsStillRunning() async throws {
    StubProtocol.handler = { _, _ in
      .init(chunks: [Data("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n".utf8)] + Array(repeating: Data(": keep\n".utf8), count: 100), gap: 0.05)
    }
    let api = try api()
    var count = 0
    do {
      for try await _ in api.chat(requestId: "slow", model: "m", effort: "high", messages: []) {
        count += 1
        api.cancel("slow")
      }
    } catch {}
    XCTAssertEqual(count, 1)
  }

  func testChatToolsAreSentWithAutoChoice() async throws {
    StubProtocol.handler = { _, _ in .init(chunks: [Data("data: [DONE]\n\n".utf8)]) }
    let api = try api()
    for try await _ in api.chat(requestId: "r", model: "m", effort: "none", messages: [], options: ChatOptions(tools: modelToolSchema())) {}
    let json = try JSONDecoder().decode(JSONValue.self, from: StubProtocol.seen[0].body)
    XCTAssertEqual(json["tool_choice"], .string("auto"))
    XCTAssertEqual(json["tools"]?.array?.count, 4)
    XCTAssertEqual(json["chat_template_kwargs"]?["enable_thinking"], .bool(false))
  }

  func testMediaCredentialsAreNotForwardedToAnotherOrigin() throws {
    let api = try api()
    api.cookie = "cookie=test"
    XCTAssertEqual(try api.mediaURL("http://old-worker/v1/files/image.png").jarvisOrigin, "https://jarvis.test")
    XCTAssertEqual(try api.mediaURL("http://old-worker/v1/files/image.png?x=1").absoluteString, "https://jarvis.test/v1/files/image.png?x=1")
    XCTAssertEqual(try api.mediaURL("https://other.test/p.png").jarvisOrigin, "https://other.test")
    XCTAssertEqual(try api.mediaURL("/v1/files/a.png").absoluteString, "https://jarvis.test/v1/files/a.png")
    XCTAssertThrowsError(try api.mediaURL("javascript:alert(1)"))
    XCTAssertThrowsError(try api.mediaURL("http://other.test/p.png"))
  }

  func testDownloadSendsCredentialsOnlyToTheServer() async throws {
    StubProtocol.handler = { _, _ in .init(chunks: [Data("abc".utf8)]) }
    let api = try api()
    api.cookie = "cookie=test"
    let own = try await api.download("/v1/files/a.png")
    XCTAssertEqual(own, Data("abc".utf8))
    XCTAssertEqual(StubProtocol.seen[0].request.value(forHTTPHeaderField: "Cookie"), "cookie=test")
    _ = try await api.download("https://other.test/p.png")
    XCTAssertNil(StubProtocol.seen[1].request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(StubProtocol.seen[1].request.value(forHTTPHeaderField: "Origin"))
  }

  func testDownloadToAFileAppearsOnlyWhenComplete() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: file) }
    StubProtocol.handler = { _, _ in .init(chunks: [Data(repeating: 1, count: 100_000), Data(repeating: 2, count: 50_000)]) }
    let api = try api()
    let total = try await api.download("/v1/videos/x/content", to: file)
    XCTAssertEqual(total, 150_000)
    XCTAssertEqual(try Data(contentsOf: file).count, 150_000)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("part").path))

    let other = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-\(UUID().uuidString).bin")
    StubProtocol.handler = { _, _ in .init(chunks: [Data(repeating: 1, count: 100)], failure: URLError(.networkConnectionLost)) }
    do { _ = try await api.download("/v1/videos/y/content", to: other); XCTFail() } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathExtension("part").path))
  }

  func testAFailedDownloadToAFileKeepsWhatWasThere() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("v.mp4")
    let api = try api()
    // The folder is made when it is not there.
    StubProtocol.handler = { _, _ in .init(chunks: [Data(repeating: 7, count: 10)]) }
    let size = try await api.download("/v1/videos/x/content", to: file)
    XCTAssertEqual(size, 10)
    // A refusal leaves the earlier file as it was, and nothing else beside it.
    StubProtocol.handler = { _, _ in .init(status: 404, chunks: [Data("no".utf8)]) }
    do { _ = try await api.download("/v1/videos/x/content", to: file); XCTFail() } catch {}
    XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 7, count: 10))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["v.mp4"])
  }

  func testModelToolRefusesUnknownNamesAndReadsTheReply() async throws {
    let api = try api()
    do { _ = try await api.modelTool(requestId: "t", name: "rm_rf", args: [:]); XCTFail() } catch {
      XCTAssertEqual((error as? JarvisException)?.message, "此工具未开放")
    }
    StubProtocol.handler = { _, _ in
      .init(chunks: [Data(#"{"result":{"content":[{"type":"text","text":"a"},{"type":"image"},{"type":"text","text":"b"}]}}"#.utf8)])
    }
    let r1 = try await api.modelTool(requestId: "t", name: "list_models", args: [:])
    XCTAssertEqual(r1, "a\nb")
    StubProtocol.handler = { _, _ in .init(chunks: [Data(#"{"result":{"isError":true,"content":[{"type":"text","text":"boom"}]}}"#.utf8)]) }
    let r2 = try await api.modelTool(requestId: "t", name: "load_model", args: ["model": .string("m")])
    XCTAssertEqual(r2, #"{"error":"boom"}"#)
    StubProtocol.handler = { _, _ in .init(chunks: [Data(#"{"error":{"message":"nope"}}"#.utf8)]) }
    let r3 = try await api.modelTool(requestId: "t", name: "list_models", args: [:])
    XCTAssertEqual(r3, #"{"error":"nope"}"#)
  }

  func testImageGenerationReturnsTheUrls() async throws {
    StubProtocol.handler = { _, _ in .init(chunks: [Data(#"{"data":[{"url":"/v1/files/1.png"},{"url":"/v1/files/2.png"}]}"#.utf8)]) }
    let urls = try await api().generate(requestId: "g", kind: "image", args: ["prompt": .string("猫"), "size": .string("1024x1024")])
    XCTAssertEqual(urls, ["/v1/files/1.png", "/v1/files/2.png"])
    let body = try JSONDecoder().decode(JSONValue.self, from: StubProtocol.seen[0].body)
    XCTAssertEqual(body["response_format"], .string("url"))
    XCTAssertEqual(body["size"], .string("1024x1024"))
  }

  func testVideoGenerationPollsUntilDone() async throws {
    var polls = 0
    StubProtocol.handler = { request, _ in
      if request.httpMethod == "POST" { return .init(chunks: [Data(#"{"id":"v 1","status":"queued"}"#.utf8)]) }
      polls += 1
      let status = polls < 3 ? "in_progress" : "completed"
      return .init(chunks: [Data(#"{"id":"v 1","status":"\#(status)","progress":\#(polls * 30)}"#.utf8)])
    }
    let api = try api()
    api.pollInterval = 0.01
    var job: String?
    var progress: [Double] = []
    let urls = try await api.generate(
      requestId: "g", kind: "video", args: ["prompt": .string("海"), "seconds": .number(4)], onJob: { job = $0 }, onProgress: { progress.append($0.progress) })
    XCTAssertEqual(job, "v 1")
    XCTAssertEqual(urls, ["/v1/videos/v%201/content"])
    XCTAssertEqual(progress, [0, 30, 60])
    let first = try JSONDecoder().decode(JSONValue.self, from: StubProtocol.seen[0].body)
    XCTAssertEqual(first["seconds"], .string("4"))
  }

  func testAFailedVideoSaysSo() async throws {
    StubProtocol.handler = { _, _ in .init(chunks: [Data(#"{"id":"v","status":"failed"}"#.utf8)]) }
    do { _ = try await api().generate(requestId: "g", kind: "video", args: ["prompt": .string("x")]); XCTFail() } catch {
      XCTAssertEqual((error as? JarvisException)?.message, "视频生成失败，请检查原任务")
    }
  }

  func testADownloadPastItsLimitStopsAndLeavesNothing() async throws {
    let before = ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("jarvis-dl-") }.count
    StubProtocol.handler = { _, _ in .init(chunks: Array(repeating: Data(repeating: 1, count: 60), count: 6), gap: 0.05) }
    let api = try api()
    do { _ = try await api.fetchFile("/v1/files/big", limit: 100); XCTFail() } catch {
      XCTAssertEqual((error as? JarvisException)?.message, "文件过大")
    }
    let after = ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("jarvis-dl-") }.count
    XCTAssertEqual(after, before)
  }

  func testAnErrorStatusIsNotKeptOnDisk() async throws {
    StubProtocol.handler = { _, _ in .init(status: 500, chunks: [Data(repeating: 1, count: 5_000)]) }
    do { _ = try await api().fetchFile("/v1/files/x", limit: 1_000_000); XCTFail() } catch {
      XCTAssertEqual((error as? JarvisException)?.message, "服务暂时不可用（500）")
    }
  }

  func testRetryingAVideoTheServiceGaveUpOnMakesANewJob() async throws {
    StubProtocol.handler = { request, _ in
      if request.httpMethod == "POST" { return .init(chunks: [Data(#"{"id":"new","status":"completed"}"#.utf8)]) }
      return .init(chunks: [Data(#"{"id":"old","status":"failed"}"#.utf8)])
    }
    let api = try api()
    var job: String?
    let urls = try await api.generate(
      requestId: "g", kind: "video", args: ["prompt": .string("海")], resumeJobId: "old", onJob: { job = $0 })
    XCTAssertEqual(job, "new")
    XCTAssertEqual(urls, ["/v1/videos/new/content"])
    XCTAssertEqual(StubProtocol.seen.map { $0.request.httpMethod }, ["GET", "POST"])
  }

  func testPreviewTakesTheServersClipThenFallsBackToSpeech() async throws {
    StubProtocol.handler = { request, _ in
      if request.url?.path == "/p.mp3" { return .init(status: 404) }
      return .init(chunks: [Data("WAV".utf8)])
    }
    let api = try api()
    let data = try await api.preview(VoiceInfo("a", "A", "", preview: "/p.mp3"), model: "tts")
    XCTAssertEqual(data, Data("WAV".utf8))
    let speech = StubProtocol.seen.last!
    XCTAssertEqual(speech.request.url?.path, "/v1/audio/speech")
    let body = try JSONDecoder().decode(JSONValue.self, from: speech.body)
    XCTAssertEqual(body["input"], .string(previewSentence))
    XCTAssertEqual(body["response_format"], .string("wav"))
  }

  func testLogoutClearsTheCookieAndSendsItOnce() async throws {
    StubProtocol.handler = { _, _ in .init(status: 303) }
    let api = try api()
    api.cookie = "c=1"
    try await api.logout()
    XCTAssertNil(api.cookie)
    XCTAssertEqual(StubProtocol.seen[0].request.value(forHTTPHeaderField: "Cookie"), "c=1")
    XCTAssertEqual(StubProtocol.seen[0].request.url?.path, "/logout")
  }

  func testSSEParserHandlesCommentsMultilineAndTheUnterminatedLastRecord() {
    var p = SSEParser()
    var out = p.feed(Data(": hi\r\ndata: a\r\ndata: b\r\n\r\nevent: x\r\n\r\ndata:c".utf8))
    XCTAssertEqual(out, ["a\nb"])
    out = p.finish()
    XCTAssertEqual(out, ["c"])
  }
}

// MARK: Pictures as jobs

extension APITests {
  func testAPictureIsAskedForAsAJobAndFollowedWithItsProgress() async throws {
    var polls = 0
    StubProtocol.handler = { request, _ in
      if request.httpMethod == "POST" { return .init(status: 202, chunks: [Data(#"{"id":"img_1","status":"queued","phase":"queued","progress":0}"#.utf8)]) }
      polls += 1
      if polls < 3 {
        return .init(chunks: [Data(#"{"id":"img_1","status":"in_progress","phase":"generating","progress":\#(polls * 25)}"#.utf8)])
      }
      return .init(chunks: [Data(#"{"id":"img_1","status":"completed","phase":"completed","progress":100,"urls":["/v1/files/img_1/0.png"]}"#.utf8)])
    }
    let api = try api()
    api.pollInterval = 0.01
    var job: String?
    var reports: [MediaReport] = []
    let urls = try await api.generate(
      requestId: "g", kind: "image", args: ["prompt": .string("猫"), "size": .string("1024x1024")], onJob: { job = $0 },
      onProgress: { reports.append($0) })
    XCTAssertEqual(job, "img_1")
    XCTAssertEqual(urls, ["/v1/files/img_1/0.png"])
    XCTAssertEqual(reports.map(\.progress), [0, 25, 50])
    XCTAssertEqual(reports.map(\.phase), ["queued", "generating", "generating"])
    let body = try JSONDecoder().decode(JSONValue.self, from: StubProtocol.seen[0].body)
    XCTAssertEqual(body["wait_s"], .number(0))
    XCTAssertEqual(body["response_format"], .string("url"))
    XCTAssertEqual(StubProtocol.seen[1].request.url?.path, "/v1/jobs/img_1")
  }

  func testAServiceThatDoesNotKnowTheJobOptionIsAskedTheOldWay() async throws {
    StubProtocol.handler = { _, body in
      if String(decoding: body, as: UTF8.self).contains("wait_s") { return .init(status: 400, chunks: [Data("{}".utf8)]) }
      return .init(chunks: [Data(#"{"data":[{"url":"/v1/files/1.png"}]}"#.utf8)])
    }
    let urls = try await api().generate(requestId: "g", kind: "image", args: ["prompt": .string("猫")])
    XCTAssertEqual(urls, ["/v1/files/1.png"])
    XCTAssertEqual(StubProtocol.seen.count, 2)
  }

  func testAPictureTheServiceHadReadyAtOnceIsReturnedWithoutPolling() async throws {
    StubProtocol.handler = { _, _ in .init(chunks: [Data(#"{"created":1,"id":"img_2","data":[{"url":"/v1/files/img_2/0.png"}]}"#.utf8)]) }
    let urls = try await api().generate(requestId: "g", kind: "image", args: ["prompt": .string("猫")])
    XCTAssertEqual(urls, ["/v1/files/img_2/0.png"])
    XCTAssertEqual(StubProtocol.seen.count, 1)
  }

  func testAFailedPictureJobSaysSoAndABriefDropOfTheConnectionDoesNotEndIt() async throws {
    var polls = 0
    StubProtocol.handler = { request, _ in
      if request.httpMethod == "POST" { return .init(status: 202, chunks: [Data(#"{"id":"img_3","status":"queued"}"#.utf8)]) }
      polls += 1
      if polls == 1 { return .init(status: 502) }
      return .init(chunks: [Data(#"{"id":"img_3","status":"failed"}"#.utf8)])
    }
    let api = try api()
    api.pollInterval = 0.01
    do { _ = try await api.generate(requestId: "g", kind: "image", args: ["prompt": .string("x")]); XCTFail() } catch {
      XCTAssertEqual((error as? JarvisException)?.message, "图片生成失败，请检查原任务")
    }
    XCTAssertEqual(polls, 2)
  }

  func testAJobThatReportsNothingForTooLongIsGivenUpAsStuck() async throws {
    StubProtocol.handler = { request, _ in
      if request.httpMethod == "POST" { return .init(status: 202, chunks: [Data(#"{"id":"img_9","status":"queued"}"#.utf8)]) }
      return .init(chunks: [Data(#"{"id":"img_9","status":"in_progress","phase":"generating","progress":50}"#.utf8)])
    }
    let api = try api()
    api.pollInterval = 0.01
    api.quietLimit = 0.1
    do { _ = try await api.generate(requestId: "g", kind: "image", args: ["prompt": .string("x")]); XCTFail() } catch {
      let e = error as? JarvisException
      XCTAssertEqual(e?.stalled, true)
      XCTAssertTrue(e?.message.contains("没有新进展") == true)
    }
  }

  func testAJobWaitingForItsTurnIsNotGivenUpOnItsQuiet() async throws {
    var polls = 0
    StubProtocol.handler = { request, _ in
      if request.httpMethod == "POST" { return .init(status: 202, chunks: [Data(#"{"id":"img_8","status":"queued","phase":"queued"}"#.utf8)]) }
      polls += 1
      if polls < 30 { return .init(chunks: [Data(#"{"id":"img_8","status":"queued","phase":"queued","progress":0}"#.utf8)]) }
      return .init(chunks: [Data(#"{"id":"img_8","status":"completed","urls":["/v1/files/img_8/0.png"]}"#.utf8)])
    }
    let api = try api()
    api.pollInterval = 0.01
    api.quietLimit = 0.05
    let urls = try await api.generate(requestId: "g", kind: "image", args: ["prompt": .string("x")])
    XCTAssertEqual(urls, ["/v1/files/img_8/0.png"])
  }

  func testAJobTheServiceCallsQueuedWithoutAStageIsNotGivenUpWhileItWaits() async throws {
    var polls = 0
    StubProtocol.handler = { request, _ in
      if request.httpMethod == "POST" { return .init(status: 202, chunks: [Data(#"{"id":"img_7","status":"queued"}"#.utf8)]) }
      polls += 1
      if polls < 30 { return .init(chunks: [Data(#"{"id":"img_7","status":"queued","progress":0}"#.utf8)]) }
      return .init(chunks: [Data(#"{"id":"img_7","status":"completed","urls":["/v1/files/img_7/0.png"]}"#.utf8)])
    }
    let api = try api()
    api.pollInterval = 0.01
    api.quietLimit = 0.05
    let urls = try await api.generate(requestId: "g", kind: "image", args: ["prompt": .string("x")])
    XCTAssertEqual(urls, ["/v1/files/img_7/0.png"])
  }
}
