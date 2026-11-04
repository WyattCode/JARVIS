import XCTest

@testable import JarvisCore

final class FakeWire: RealtimeWire, @unchecked Sendable {
  let events: AsyncStream<WireEvent>
  private let continuation: AsyncStream<WireEvent>.Continuation
  private let lock = NSLock()
  private var _sent: [JSONValue] = []
  var sendFails = false
  private(set) var closed = false

  init() {
    var c: AsyncStream<WireEvent>.Continuation!
    events = AsyncStream { c = $0 }
    continuation = c
  }

  var sent: [JSONValue] { lock.lock(); defer { lock.unlock() }; return _sent }

  func sent(type: String) -> [JSONValue] { sent.filter { $0["type"]?.string == type } }

  func send(_ value: String) throws {
    if sendFails { throw URLError(.networkConnectionLost) }
    lock.lock()
    _sent.append(try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)))
    lock.unlock()
  }

  func close() async { closed = true; continuation.finish() }

  func emit(_ object: [String: JSONValue]) { continuation.yield(.text(Persistence.encode(.object(object)))) }
  func drop() { continuation.yield(.failed) }
}

@MainActor
final class FakeAudio: AudioDevice {
  let events: AsyncStream<[String: JSONValue]>
  private let continuation: AsyncStream<[String: JSONValue]>.Continuation
  var permission = true
  var startError: Error?
  var fed: [Data] = []
  var flushes = 0
  var finishes = 0
  var stops = 0
  var started = 0
  var reconfigured: [Bool] = []
  var previewed: [PcmClip] = []
  var rateResets = 0
  var flushFails = false
  var input: (@Sendable (Data) -> Void)?

  init() {
    var c: AsyncStream<[String: JSONValue]>.Continuation!
    events = AsyncStream { c = $0 }
    continuation = c
  }

  func emit(_ event: [String: JSONValue]) { continuation.yield(event) }
  func microphonePermission() async -> Bool { permission }
  func start(echoCancel: Bool, input: @escaping @Sendable (Data) -> Void) async throws {
    if let startError { throw startError }
    started += 1
    self.input = input
  }
  func reconfigureInput(echoCancel: Bool, input: @escaping @Sendable (Data) -> Void) async throws {
    reconfigured.append(echoCancel)
    self.input = input
  }
  func feed(_ pcm: Data) async throws { fed.append(pcm) }
  func flush() async throws {
    if flushFails { throw URLError(.cannotConnectToHost) }
    flushes += 1
  }
  func finish() async throws { finishes += 1 }
  func preview(_ clip: PcmClip) async throws { previewed.append(clip) }
  func resetRate() async throws { rateResets += 1 }
  func stop() async throws { stops += 1 }
}

func wavClip(rate: Int = 24000, samples: Int = 100) -> Data {
  var d = Data("RIFF".utf8)
  func le32(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
  func le16(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255)]) }
  let pcm = Data(repeating: 1, count: samples * 2)
  d.append(le32(36 + pcm.count))
  d.append(Data("WAVE".utf8))
  d.append(Data("fmt ".utf8))
  d.append(le32(16))
  d.append(le16(1))
  d.append(le16(1))
  d.append(le32(rate))
  d.append(le32(rate * 2))
  d.append(le16(2))
  d.append(le16(16))
  d.append(Data("data".utf8))
  d.append(le32(pcm.count))
  d.append(pcm)
  return d
}

@MainActor
final class VoiceTests: XCTestCase {
  var api: FakeTransport!
  var store: JarvisStore!
  var audio: FakeAudio!
  var voice: VoiceSession!
  var wire: FakeWire { api.wires.last! }

  override func setUp() async throws {
    LocalData.sweepOnStart = false
    api = FakeTransport()
    let efforts: [String: JSONValue] = ["high": .string("chat-voice")]
    let jarvis: [String: JSONValue] = ["voice_effort_models": .object(efforts)]
    let chat = ModelInfo("chat-a", "chat-a", metadata: ["jarvis": .object(jarvis)])
    let amy = VoiceInfo("amy", "Amy", "")
    let tts = ModelInfo("tts", "tts", kind: "speech", voices: [amy], defaultVoice: "amy")
    api.modelsResult = .success([chat, tts])
    store = JarvisStore(api: api, vault: MemoryVault())
    store.saveDebounce = 0.01
    await store.initialize()
    _ = await store.login("u", "p")
    audio = FakeAudio()
    voice = VoiceSession(store: store, audio: audio)
    store.voice = voice
    voice.reconnectDelay = { _ in 0.02 }
  }

  func settle(_ condition: @escaping () -> Bool = { false }, timeout: Double = 2) async {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  func confirm(effort: String = "high", model: String = "chat-voice", voiceId: String = "amy") async {
    await settle({ [self] in !(wire.sent(type: "session.update").isEmpty) })
    wire.emit(["type": .string("session.updated"), "session": .object(["reasoning": .bool(effort != "none"), "speech_model": .string("tts"), "voice": .string(voiceId), "model": .string(model)])])
    await settle({ [self] in voice.ready })
  }

  func startCall() async {
    await voice.start(store.current.id)
    await confirm()
  }

  func testACallStartsConfirmsItsConfigurationAndIsReady() async throws {
    await voice.start(store.current.id)
    XCTAssertTrue(voice.active)
    XCTAssertTrue(voice.open)
    XCTAssertEqual(audio.started, 1)
    await settle({ [self] in !wire.sent(type: "session.update").isEmpty })
    let update = wire.sent(type: "session.update")[0]["session"]!
    XCTAssertEqual(update["voice"], .string("amy"))
    XCTAssertEqual(update["speech_model"], .string("tts"))
    XCTAssertEqual(update["model"], .string("chat-voice"), "the model the server names for this effort")
    XCTAssertEqual(update["reasoning"], .bool(true))
    XCTAssertEqual(update["turn_detection"], .null, "push to talk")
    XCTAssertEqual(update["tool_choice"], .string("auto"))
    XCTAssertEqual(update["max_response_output_tokens"], .string("inf"))
    XCTAssertEqual(voice.status, "正在确认语音配置")
    XCTAssertFalse(voice.ready)
    await confirm()
    XCTAssertTrue(voice.ready)
    XCTAssertEqual(voice.status, "已就绪")
    XCTAssertEqual(voice.hint, "按住按钮开始说话")
  }

  func testAConfigurationTheServerChangedIsNotAccepted() async {
    await voice.start(store.current.id)
    await settle({ [self] in !wire.sent(type: "session.update").isEmpty })
    wire.emit(["type": .string("session.updated"), "session": .object(["reasoning": .bool(true), "speech_model": .string("tts"), "voice": .string("other"), "model": .string("chat-voice")])])
    await settle({ [self] in voice.error != nil })
    XCTAssertFalse(voice.ready)
    XCTAssertEqual(voice.error, "服务器确认的音色或思考配置不一致，请重新选择")
  }

  func testWithoutTheMicrophoneTheCallDoesNotOpen() async {
    audio.permission = false
    await voice.start(store.current.id)
    XCTAssertFalse(voice.active)
    XCTAssertFalse(voice.open)
    XCTAssertTrue(voice.permissionDenied)
    XCTAssertEqual(voice.error, "需要麦克风权限才能语音通话，请在系统设置中允许")
    XCTAssertEqual(audio.started, 0)
  }

  func testAVoiceThatIsNotThereStopsTheCall() async {
    store.changeSettings { $0.voices["tts"] = "gone" }
    await voice.start(store.current.id)
    XCTAssertFalse(voice.active)
    XCTAssertEqual(voice.error, "所选音色不可用，请在设置中重新选择")
    XCTAssertEqual(voice.status, "音色未确认")
  }

  func testNoMicrophoneOnTheDeviceIsSaidSo() async {
    audio.startError = AudioError.noInput("未检测到可用的麦克风")
    await voice.start(store.current.id)
    XCTAssertFalse(voice.active)
    XCTAssertEqual(voice.error, "未检测到可用的麦克风")
    XCTAssertEqual(voice.status, "语音未开启")
  }

  func testAnExpiredSessionAtTheHandshakeSignsOut() async {
    api.realtimeFailure = JarvisException("登录已过期，请重新登录", unauthorized: true)
    await voice.start(store.current.id)
    XCTAssertFalse(voice.active)
    XCTAssertFalse(store.authenticated)
  }

  func testPushToTalkSendsTheRecordingAndAnswersTheTranscript() async throws {
    var now = Date(timeIntervalSince1970: 1000)
    voice = VoiceSession(store: store, audio: audio, now: { now })
    store.voice = voice
    await startCall()
    voice.hold()
    XCTAssertTrue(voice.held)
    XCTAssertEqual(voice.status, "正在聆听")
    XCTAssertFalse(wire.sent(type: "input_audio_buffer.clear").isEmpty)
    audio.input?(Data(repeating: 5, count: 960))
    await settle({ [self] in voice.sentPcmBytes > 0 })
    XCTAssertEqual(voice.sentPcmBytes, 960)
    XCTAssertEqual(wire.sent(type: "input_audio_buffer.append").count, 1)
    now = now.addingTimeInterval(1)
    voice.release()
    XCTAssertEqual(voice.hint, "正在处理这段语音")
    await settle({ [self] in !wire.sent(type: "input_audio_buffer.commit").isEmpty })
    XCTAssertEqual(wire.sent(type: "input_audio_buffer.commit").count, 1)
    XCTAssertEqual(voice.status, "正在识别")
    wire.emit(["type": .string("input_audio_buffer.cleared")])
    wire.emit(["type": .string("input_audio_buffer.committed"), "item_id": .string("u1")])
    wire.emit(["type": .string("conversation.item.input_audio_transcription.completed"), "item_id": .string("u1"), "transcript": .string(" 你好 ")])
    await settle({ [self] in !wire.sent(type: "response.create").isEmpty })
    XCTAssertEqual(wire.sent(type: "response.create").count, 1)
    XCTAssertEqual(voice.lastYou, "你好")
    XCTAssertEqual(store.current.messages.last?.text, "你好")
    wire.emit(["type": .string("response.created"), "response": .object(["id": .string("r1")])])
    wire.emit(["type": .string("response.audio_transcript.delta"), "item_id": .string("a1"), "delta": .string("你好，")])
    wire.emit(["type": .string("response.audio_transcript.delta"), "item_id": .string("a1"), "delta": .string("请讲")])
    await settle({ [self] in voice.lastBot == "你好，请讲" })
    XCTAssertEqual(store.current.messages.last?.text, "你好，请讲")
    XCTAssertEqual(store.current.messages.last?.status, "generating")
    wire.emit(["type": .string("response.done"), "response": .object(["status": .string("completed"), "output": .array([.object(["id": .string("a1")])])])])
    await settle({ [self] in voice.status == "已就绪" })
    XCTAssertEqual(store.current.messages.last?.status, "complete")
    XCTAssertFalse(voice.thinking)
  }

  func testATooShortPressSendsNothing() async {
    await startCall()
    voice.hold()
    voice.release()
    await settle({ [self] in voice.hint == "请按住按钮后说话" })
    XCTAssertEqual(voice.hint, "请按住按钮后说话")
    XCTAssertTrue(wire.sent(type: "input_audio_buffer.commit").isEmpty)
  }

  func testTheMicrophoneIsNotSentWhenNobodyIsTalking() async {
    await startCall()
    audio.input?(Data(repeating: 5, count: 960))
    await settle({ [self] in voice.capturedPcmBytes > 0 })
    XCTAssertEqual(voice.capturedPcmBytes, 960)
    XCTAssertEqual(voice.sentPcmBytes, 0)
    XCTAssertTrue(wire.sent(type: "input_audio_buffer.append").isEmpty)
  }

  func testATypedMessageGoesIntoTheCall() async {
    await startCall()
    XCTAssertTrue(voice.typed("打字问你"))
    XCTAssertEqual(wire.sent(type: "conversation.item.create").last?["item"]?["content"]?.array?[0]["text"], .string("打字问你"))
    XCTAssertEqual(wire.sent(type: "response.create").count, 1)
    XCTAssertTrue(voice.thinking)
    XCTAssertEqual(store.current.messages.last?.text, "打字问你")
    XCTAssertFalse(voice.typed("再来一条"), "not while an answer is pending")
  }

  func testANotReadyCallRefusesTypedText() async {
    XCTAssertFalse(voice.typed("x"))
    await voice.start(store.current.id)
    XCTAssertFalse(voice.typed("x"), "the configuration is not confirmed yet")
  }

  func testTheModelsAudioIsPlayedInOrderAndDroppedAfterAnInterruption() async {
    await startCall()
    wire.emit(["type": .string("response.created"), "response": .object(["id": .string("r1")])])
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "delta": .string(Data([1, 2]).base64EncodedString())])
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "delta": .string(Data([3, 4]).base64EncodedString())])
    wire.emit(["type": .string("response.audio.done"), "item_id": .string("a1")])
    await settle({ [self] in audio.finishes == 1 })
    XCTAssertEqual(audio.fed, [Data([1, 2]), Data([3, 4])])
    XCTAssertEqual(audio.finishes, 1)
    XCTAssertEqual(voice.receivedPcmBytes, 4)
    await voice.interrupt()
    XCTAssertGreaterThan(audio.flushes, 0)
    XCTAssertEqual(wire.sent(type: "response.cancel").count, 1)
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "response_id": .string("r1"), "delta": .string(Data([9, 9]).base64EncodedString())])
    try? await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(audio.fed.count, 2, "what came after the interruption is not played")
  }

  func testAFunctionCallBecomesATask() async {
    await startCall()
    wire.emit(["type": .string("response.output_item.done"), "item": .object(["type": .string("function_call"), "name": .string("generate_image"), "call_id": .string("c1"), "arguments": .string("{\"prompt\":\"海\"}")])])
    await settle({ [self] in !store.current.tasks.isEmpty })
    XCTAssertEqual(store.current.tasks.first?.prompt, "海")
    XCTAssertEqual(store.current.tasks.first?.source, "voice")
  }

  func testALostConnectionReconnectsAndInterruptsWhatWasBeingSaid() async {
    await startCall()
    wire.emit(["type": .string("response.created"), "response": .object(["id": .string("r1")])])
    wire.emit(["type": .string("response.audio_transcript.delta"), "item_id": .string("a1"), "delta": .string("半句")])
    await settle({ [self] in voice.lastBot == "半句" })
    let first = wire
    first.drop()
    await settle({ [self] in api.wires.count == 2 })
    XCTAssertEqual(api.wires.count, 2, "it connected again")
    XCTAssertEqual(store.current.messages.last?.status, "interrupted")
    await confirm()
    XCTAssertTrue(voice.ready)
    XCTAssertTrue(voice.active)
    XCTAssertTrue(first.closed)
    // the earlier turns are given to the new connection
    XCTAssertFalse(wire.sent(type: "conversation.item.create").isEmpty)
  }

  func testGivingUpAfterTooManyFailedReconnects() async {
    await startCall()
    api.realtimeFailure = URLError(.cannotConnectToHost)
    wire.drop()
    await settle({ [self] in !voice.active }, timeout: 5)
    XCTAssertFalse(voice.active)
    XCTAssertEqual(voice.error, "语音连接未能恢复，已保留对话")
  }

  func testAServerThatNeverConfirmsIsReported() async {
    voice.handshakeTimeout = 0.05
    await voice.start(store.current.id)
    await settle({ [self] in voice.error != nil })
    XCTAssertEqual(voice.error, "服务器尚未确认语音配置，请重试连接")
  }

  func testASilentServerEndsTheWait() async {
    voice.turnTimeout = 0.05
    await startCall()
    XCTAssertTrue(voice.typed("在吗"))
    await settle({ [self] in voice.status == "没有收到回复" })
    XCTAssertEqual(voice.status, "没有收到回复")
    XCTAssertEqual(voice.error, "服务器长时间没有回应，请再说一次或重试")
    XCTAssertFalse(voice.thinking)
  }

  func testHangingUpClosesEverything() async {
    await startCall()
    let w = wire
    await voice.stop()
    XCTAssertFalse(voice.active)
    XCTAssertFalse(voice.open)
    XCTAssertFalse(voice.ready)
    XCTAssertEqual(voice.status, "已结束")
    XCTAssertTrue(w.closed)
    XCTAssertGreaterThan(audio.stops, 0)
  }

  func testLosingTheAudioFocusPausesTheCall() async {
    await startCall()
    audio.emit(["type": .string("focus_lost")])
    await settle({ [self] in voice.error != nil })
    XCTAssertFalse(voice.ready)
    XCTAssertEqual(voice.error, "语音已暂停，麦克风或音频设备不可用")
    XCTAssertTrue(voice.needsRecovery)
    // and it comes back on request
    let ok = await voice.recover()
    XCTAssertTrue(ok)
    await confirm()
    XCTAssertTrue(voice.ready)
    XCTAssertNil(voice.error)
  }

  func testPlaybackReportsDriveTheSpeakingState() async {
    await startCall()
    audio.emit(["type": .string("playback"), "active": .bool(true), "rms": .number(0.4), "buffered_frames": .number(100), "sample_rate": .number(24000)])
    await settle({ [self] in voice.speaking })
    XCTAssertTrue(voice.speaking)
    XCTAssertEqual(voice.levels.output, 0.4)
    XCTAssertEqual(voice.status, "正在说话")
    audio.emit(["type": .string("playback"), "active": .bool(false), "rms": .number(0)])
    await settle({ [self] in !voice.speaking })
    XCTAssertEqual(voice.status, "已就绪")
    XCTAssertEqual(voice.levels.output, 0)
  }

  func testChangingTheEchoSettingRebuildsTheInput() async {
    await startCall()
    store.changeSettings { $0.echoCancel = false }
    voice.updateSettings()
    await settle({ [self] in !audio.reconfigured.isEmpty })
    XCTAssertEqual(audio.reconfigured, [false])
  }

  func testHandsFreeModeUsesServerDetectionAndCanBeMuted() async {
    store.changeSettings { $0.voiceMode = "vad"; $0.waitMs = 1000 }
    await voice.start(store.current.id)
    await settle({ [self] in !wire.sent(type: "session.update").isEmpty })
    let td = wire.sent(type: "session.update")[0]["session"]?["turn_detection"]
    XCTAssertEqual(td?["type"], .string("server_vad"))
    XCTAssertEqual(td?["silence_duration_ms"], .number(1000))
    await confirm()
    XCTAssertEqual(voice.hint, "直接说话即可，停顿后我会回答")
    voice.toggleMute()
    XCTAssertEqual(voice.status, "已静音")
    audio.input?(Data(repeating: 5, count: 960))
    await settle({ [self] in voice.capturedPcmBytes > 0 })
    XCTAssertEqual(voice.sentPcmBytes, 0, "muted")
    voice.toggleMute()
    XCTAssertEqual(voice.status, "已就绪")
  }

  func testAVoiceTryOutPlaysTheClip() async {
    api.previewBytes = wavClip()
    voice.playPreviewForTest()
    await voice.playPreview(VoiceInfo("amy", "Amy", ""), engine: "tts")
    XCTAssertEqual(audio.previewed.count, 1)
    XCTAssertEqual(audio.previewed[0].rate, 24000)
    XCTAssertTrue(voice.speaking)
    XCTAssertFalse(voice.previewLoading)
    XCTAssertNil(voice.previewError)
  }

  func testATryOutThatFailsSaysSoApartFromTheCall() async {
    api.previewFailure = URLError(.cannotConnectToHost)
    await voice.playPreview(VoiceInfo("amy", "Amy", ""), engine: "tts")
    XCTAssertEqual(voice.previewError, "试听暂时不可用，请重试；已选音色保持不变")
    XCTAssertNil(voice.error)
    XCTAssertFalse(voice.previewing)
    XCTAssertFalse(voice.previewLoading)
  }

  func testAClipTheAppCannotDecodeIsReplacedByTheVoiceSpeaking() async {
    api.previewBytes = Data("not a wav".utf8)
    await voice.playPreview(VoiceInfo("amy", "Amy", "", preview: "/clip.mp3"), engine: "tts")
    XCTAssertEqual(voice.previewError, "试听暂时不可用，请重试；已选音色保持不变", "synthesis returns the same junk here")
    api.previewBytes = wavClip()
    await voice.playPreview(VoiceInfo("amy", "Amy", ""), engine: "tts")
    XCTAssertEqual(audio.previewed.count, 1)
  }

  func testWavParsing() throws {
    XCTAssertEqual(try PcmClip.wav(wavClip(rate: 16000, samples: 10)).rate, 16000)
    for bad in [Data(), Data(count: 50), Data("RIFF....WAVE".utf8) + Data(count: 40)] {
      XCTAssertThrowsError(try PcmClip.wav(bad))
    }
    XCTAssertThrowsError(try PcmClip.wav(wavClip(rate: 4000))) { XCTAssertEqual(($0 as? PcmClip.Invalid)?.message, "试听需为16位单声道PCM音频") }
    XCTAssertEqual(pcmRms(Data([0, 0, 0, 0])), 0)
    XCTAssertEqual(pcmRms(Data([0xFF, 0x7F])), 32767.0 / 32768, accuracy: 0.0001)
  }
}

extension VoiceSession {
  func playPreviewForTest() {}
}
