import Combine
import Foundation

/// A timer that can be started over or cancelled; its body runs on the main actor.
@MainActor
final class Delay {
  private var task: Task<Void, Never>?
  var isActive: Bool { task != nil }

  func start(_ seconds: Double, _ body: @escaping @MainActor () async -> Void) {
    cancel()
    task = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.task = nil
      await body()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}

/// Work that must happen one after the other (audio handed to the device in order).
@MainActor
final class Chain {
  private(set) var tail: Task<Void, Never> = Task {}

  /// `onError` is called when the work throws; the chain goes on either way.
  func append(onError: @escaping @MainActor () -> Void = {}, _ work: @escaping @MainActor () async throws -> Void) {
    let previous = tail
    tail = Task {
      await previous.value
      do { try await work() } catch { onError() }
    }
  }

  func reset() { tail = Task {} }
}

/// The voice call: the realtime connection and the audio device, and what they say to each other. The Swift counterpart of
/// `VoiceSession`: same states, same words on the screen, same timings.
@MainActor
public final class VoiceSession: ObservableObject, VoiceHost {
  private let store: JarvisStore
  private let audio: AudioDevice
  private let now: () -> Date

  /// How long a committed recording or a sent message may wait for the server to react at all, and how long a started
  /// reply may stay silent (reasoning models think for a while before the first word).
  public var turnTimeout: Double = 30
  public var replyTimeout: Double = 120
  /// How long the server has to confirm the session's configuration.
  public var handshakeTimeout: Double = 20
  /// How long the tail of a push-to-talk recording stays open after the button is released.
  public var tailDuration: Double = 0.22
  /// Wait before the n-th reconnect (1 s, 2 s ... 15 s).
  public var reconnectDelay: (Int) -> Double = { n in min(Double(1 << max(n - 1, 0)), 15) }

  @Published public var owner: String?
  @Published public private(set) var open = false
  @Published public private(set) var ready = false
  @Published public private(set) var held = false
  @Published public private(set) var muted = false
  @Published public private(set) var thinking = false
  @Published public private(set) var speaking = false
  @Published public private(set) var previewing = false
  /// A preview was asked for but its first audio is not queued yet (the clip is still downloading).
  @Published public private(set) var previewLoading = false
  /// Why the last voice preview failed. Kept apart from `error`, which belongs to the call.
  @Published public private(set) var previewError: String?
  @Published public private(set) var previewVoice: String?
  /// The microphone permission was refused (or restricted); the call page stays closed so the UI can offer the settings.
  @Published public private(set) var permissionDenied = false
  @Published public private(set) var status = "已结束"
  @Published public private(set) var hint = ""
  @Published public private(set) var lastYou = ""
  @Published public private(set) var lastBot = ""
  @Published public private(set) var error: String?
  @Published public private(set) var levels = AudioLevels()
  public private(set) var capturedPcmBytes = 0
  public private(set) var sentPcmBytes = 0
  public private(set) var receivedPcmBytes = 0
  public private(set) var bufferedFrames = 0
  public private(set) var playbackRate = 24000
  /// Audio of the reply in flight: bytes received, whether the player has started on it, whether all of it has arrived and,
  /// when it was cut off while being said, how far it had got. They let the call page follow the voice through the words.
  private var replyAudioBytes = 0
  /// Finds the rests in this reply's sound, for the trace (see `SoundRests`).
  private var replyRests = SoundRests(rate: 24000)
  private var replyPlaying = false
  private var replyAudioDone = false
  /// The sound said its end (an end marker) and no more sound has come since, and the reply itself has ended.
  private var replyMarkerSeen = false
  private var replyEnded = false
  /// The pace this reply's sound turned out to have, taken on by the next reply once this one is over.
  private var replyMeasuredPace: Double?
  private var replyCutAt: Double?
  /// Seconds one spoken character took in the last reply of this call: the next reply is laid out with it until its own audio
  /// is all here.
  private var speechPace = SpokenText.defaultPace
  private var speechPaceKnown = false
  /// Where the pace of each voice is kept between calls (a voice's speed is the same from one call to the next, and the first
  /// reply of a call is the one that has nothing else to go by).
  public var paceDefaults: UserDefaults = .standard
  /// The reply ended with the server saying it failed: where the sound stopped is where the words stopped being said.
  private var replyFailed = false
  /// What happened to the sound and the words of the replies, line by line (times from the reply's start, no words, only
  /// counts), for finding out why the lit part of the words went where it did. The last lines are in the diagnostics.
  public private(set) var speechTrace: [String] = []
  /// Told every line as it is written (the app keeps them in a file).
  public var traceSink: ((String) -> Void)?
  private var traceTextAt = Date.distantPast
  private var traceAudioAt = Date.distantPast
  private var traceSampleAt = Date.distantPast
  private var traceTextLength = 0
  /// When the server last said anything at all, and when the heartbeat of the trace last ran.
  private var lastWireEventAt = Date.distantPast
  private var lastBeatAt = Date.distantPast
  private let heartbeat = Delay()

  private var wire: RealtimeWire?
  private var wireReader: Task<Void, Never>?
  private var audioReader: Task<Void, Never>?
  private let tail = Delay()
  private let reconnect = Delay()
  private let handshake = Delay()
  private let turnTimer = Delay()
  private var run = 0
  private var turn = 0
  private var pendingUpdates = 0
  private var retries = 0
  private var pendingClears = 0
  private var previewRun = 0
  private var audioBlocked = false
  private var captureEcho: Bool?
  private var captureBusy = false
  private var audioEpoch = 0
  private var queuedBytes = 0
  private let captureChain = Chain()
  private let audioChain = Chain()
  private var wanted = false
  private var disposed = false
  private var tailOpen = false
  private var hangups = 0
  private var response: String? {
    // A configuration change that waited for the reply to end goes out as soon as there is no reply.
    didSet { applyDeferredSettings() }
  }
  /// A settings change arrived while the call was busy: it is sent at the next quiet moment, not into the middle of a turn.
  private var settingsDeferred = false
  /// The server heard the user start speaking and has not heard them stop (hands-free mode).
  private var userSpeaking = false { didSet { applyDeferredSettings() } }

  /// Something is going on that a configuration change must not interrupt: a reply being made or spoken, the user talking
  /// or waiting for what they said to be recognised. Shutting the microphone then (a change makes the call "not ready"
  /// until the server confirms) would drop the words being spoken.
  private var busyForConfig: Bool {
    response != nil || speaking || speechTrailing || userSpeaking || awaitingItem != nil || held || tailOpen
  }

  /// The server is still sending the reply's speech: it said the reply is done (`response.done`) before it said the speech
  /// is (`speech_done`), and between two audio segments the player may be idle for a moment, which must not read as quiet.
  /// A speech that never reports its end stops counting after `speechGrace` without a new chunk.
  private var speechOpen = false
  private var lastAudioAt: Date?
  private let speechGrace: TimeInterval = 8
  private var speechTrailing: Bool {
    speechOpen && now().timeIntervalSince(lastAudioAt ?? .distantPast) < speechGrace
  }

  /// A change is waiting for a quiet moment (shown in the diagnostics, so a long wait can be seen).
  public var configPending: Bool { settingsDeferred }

  /// Sends a change that waited for a quiet moment. Called wherever the call may have just become quiet.
  private func applyDeferredSettings() {
    guard settingsDeferred, wanted, wire != nil, !busyForConfig else { return }
    settingsDeferred = false
    updateSettings()
  }
  private var awaitingItem: String? { didSet { applyDeferredSettings() } }
  private var expectedVoice: String?
  private var expectedSpeech: String?
  private var expectedModel: String?
  /// The reasoning flag the latest `session.update` asked for; the confirmation is judged against this, not against whatever
  /// the settings say by the time it arrives.
  private var expectedReasoning = false
  /// The settings ask for a configuration the server cannot run; no confirmation of an older one may make the call ready.
  private var configBlocked = false
  /// How a reply's audio arrived, for judging the voice: the wait for the first sound, and the stalls after it (an audio
  /// chunk arriving after what was already queued had finished playing).
  public private(set) var firstAudioWait: Double?
  public private(set) var longestStall: Double = 0
  public private(set) var stalls = 0
  private var replyAudioLogged = false
  private var replyStartedAt: Date?
  private var playbackEndsAt: Date?
  /// What the call knows of one item the server is writing: the message it is shown as, the reply it belongs to, and the text
  /// of each of its parts (streamed first, then settled by the text the server gives as final).
  private struct Item {
    var messageId: String
    var role: String
    var responseId: String?
    var parts: [Int: String] = [:]
    /// Final text the server has given but whose reply has not ended yet. It is held, not shown: a reply that ends cancelled,
    /// failed or incomplete keeps the (longer) text already on the screen.
    var pending: [Int: String] = [:]
    /// Parts whose final text is on the screen; a stray delta must not add to them.
    var settled: Set<Int> = []
    /// Parts taken from a completed `response.done`'s output, which outranks a done event: nothing replaces them afterwards.
    var fixed: Set<Int> = []

    var text: String {
      if parts.count == 1, let only = parts.values.first { return only }
      return parts.keys.sorted().map { parts[$0] ?? "" }.joined()
    }
  }

  /// Items of the call (by the server's item id).
  private var items: [String: Item] = [:]
  private var cancelled: Set<String> = []
  private var cut: Set<String> = []
  /// The reply the server announced last (kept after it is done) and the replies already closed, so that a late event for an
  /// item the call never saw can be told from the reply in flight.
  private var latestResponse: String?
  private var finished: [String] = []
  /// How each reply ended (`response.done`'s status), for the replies still remembered.
  private var outcomes: [String: String] = [:]
  /// The item the call page shows as JARVIS's last words.
  private var lastBotItem: String?
  /// How many times a reply's streamed text was replaced by the server's final text (shown in the diagnostics).
  public private(set) var textCorrections = 0
  /// The reply is over (`response.done`) but its speech has not said so: if no more sound comes this long, what the player
  /// still holds back is played out instead of waiting for an end marker that may never come.
  public var speechTailWait: Double = 0.4
  private let speechWatch = Delay()
  private var heldAt: Date?
  private var closing: Task<Void, Never> = Task {}
  private var previewClosing: Task<Void, Never> = Task {}
  private var deviceClosing: Task<Void, Never> = Task {}
  private var startingFlag = false
  private var stopping = false
  private var keepOpen = false

  public init(store: JarvisStore, audio: AudioDevice, now: @escaping () -> Date = Date.init) {
    self.store = store
    self.audio = audio
    self.now = now
  }

  // MARK: VoiceHost

  public var active: Bool { wanted }
  /// A call is being set up (the microphone permission may still be asked): not `active` yet, but its voice is final.
  public var starting: Bool { startingFlag }
  public var conversationId: String? { owner }
  public var replying: Bool { response != nil && !thinking && !lastBot.isEmpty }
  public var expressing: Bool { !previewing && (speaking || replying) }
  public var needsRecovery: Bool { error != nil && !ready }
  public var speech: ModelInfo? { store.models.first { $0.id == store.settings.speechModel && $0.kind == "speech" } }
  public var voice: String { store.settings.voices[store.settings.speechModel] ?? "" }
  /// Mute only exists in hands-free mode; in push-to-talk the button is the switch and there is nothing to unmute.
  public var mutedInVad: Bool { muted && store.settings.voiceMode == "vad" }

  private var readyHint: String { store.settings.voiceMode == "ptt" ? "按住按钮开始说话" : "直接说话即可，停顿后我会回答" }
  private var replyHint: String { store.settings.voiceMode == "ptt" ? "按住按钮可打断回复" : "直接说话即可打断回复" }

  private func setLevels(input: Double? = nil, output: Double? = nil, playing: Bool? = nil) {
    if disposed { return }
    let new = AudioLevels(input: input ?? levels.input, output: output ?? levels.output, playing: playing ?? levels.playing)
    if new != levels { levels = new }
  }

  private func resetLevels() { setLevels(input: 0, output: 0, playing: false) }

  private func presentReadyState() {
    if held {
      status = "正在聆听"
      hint = "松开发送"
    } else if awaitingItem != nil {
      status = "正在识别"
      hint = "正在处理这段语音"
    } else if speaking || queuedBytes > 0 {
      status = "正在说话"
      hint = replyHint
    } else if thinking {
      status = "正在思考"
      hint = "正在整理回复"
    } else if replying {
      status = "正在回复"
      hint = replyHint
    } else {
      status = mutedInVad ? "已静音" : "已就绪"
      hint = mutedInVad ? "点击麦克风恢复聆听" : readyHint
    }
  }

  private func clearTurnError() {
    // A valid new turn clears retryable errors, never a blocked device/config.
    if ready && !audioBlocked { error = nil }
  }

  private func changed() {
    if !disposed { store.scheduleSave() }
    // A reply that is over (or cut off) is no longer held.
    if playbackPaused && !expressing { playbackPaused = false; Task { await audio.setPaused(false) } }
  }

  /// A tap while JARVIS speaks holds its voice; the next one lets it go on from the same word.
  @Published public private(set) var playbackPaused = false

  /// False when there is nothing being said to hold.
  @discardableResult
  public func togglePlaybackPause() -> Bool {
    if playbackPaused {
      playbackPaused = false
      Task { await audio.setPaused(false) }
      return true
    }
    guard expressing, !previewing else { return false }
    playbackPaused = true
    Task { await audio.setPaused(true) }
    return true
  }

  private func addMessage(_ role: String, _ text: String, status: String = "complete") -> String? {
    guard let owner else { return nil }
    let message = ChatMessage(role, text, status: status)
    store.update(owner) { $0.messages.append(message) }
    return message.id
  }

  private func edit(_ id: String, _ body: (inout ChatMessage) -> Void) {
    if let owner { store.updateMessage(owner, id, body) }
  }

  /// Sends a typed message into the call. False when it cannot go (the draft stays in the composer).
  public func typed(_ text: String) -> Bool {
    if !ready || thinking || response != nil || owner == nil { return false }
    // Send first: if the connection is gone the draft stays in the composer and nothing is shown as sent.
    let sent =
      send([
        "type": .string("conversation.item.create"),
        "item": .object([
          "type": .string("message"), "role": .string("user"),
          "content": .array([.object(["type": .string("input_text"), "text": .string(text)])]),
        ]),
      ]) && send(["type": .string("response.create")])
    if !sent { return false }
    clearTurnError()
    _ = addMessage("user", text)
    lastYou = text
    thinking = true
    status = "正在思考"
    hint = "正在整理回复"
    syncTurnTimer()
    changed()
    return true
  }

  @discardableResult
  private func send(_ value: [String: JSONValue]) -> Bool {
    guard let wire else { return false }
    do {
      try wire.send(Persistence.encode(.object(value)))
    } catch {
      // A socket that closed under us throws instead of reporting through the stream.
      let run = self.run
      Task { await lost(run, wire) }
      return false
    }
    if value["type"]?.string == "input_audio_buffer.clear" { pendingClears += 1 }
    return true
  }

  // MARK: Starting

  public func start(_ conversationId: String) async { await begin(conversationId, recovering: false) }

  /// Restarts the call after an error. The call page stays open throughout (unlike `stop` followed by `start`, which closes
  /// it and leaves it closed when the restart fails), so a refused permission or an unavailable voice shows up on the page
  /// as `error` / `permissionDenied` instead of the page silently disappearing. True when the call is up.
  public func recover() async -> Bool {
    guard let c = owner, !disposed else { return false }
    let before = hangups
    open = true
    await stopCall(keepOpen: true)
    // Hanging up while this was restarting wins.
    if hangups != before || disposed { return false }
    await begin(c, recovering: true)
    return wanted
  }

  private func begin(_ conversationId: String, recovering: Bool) async {
    if wanted {
      open = true
      return
    }
    // An attempt that was hung up on may still be winding down (its connection waits up to 20 s): a new one waits for it instead of
    // being dropped, which left the page doing nothing.
    var waited = 0
    while startingFlag, !wanted, !disposed, waited < 200 {
      try? await Task.sleep(nanoseconds: 50_000_000)
      waited += 1
    }
    if wanted {
      open = true
      return
    }
    if startingFlag || disposed { return }
    startingFlag = true
    defer { startingFlag = false }
    let before = run
    await closing.value
    await previewClosing.value
    await deviceClosing.value
    if disposed || before != run { return }
    if previewing || audioReader != nil { await stopPreview() }
    if disposed || before != run { return }
    if !voiceAvailable {
      error = "所选音色不可用，请在设置中重新选择"
      status = "音色未确认"
      if recovering { open = true }
      return
    }
    // Ask before the call page opens, so a refusal does not make it slide in and straight back out.
    permissionDenied = false
    let granted = await audio.microphonePermission()
    if disposed || before != run { return }
    if !granted {
      permissionDenied = true
      error = "需要麦克风权限才能语音通话，请在系统设置中允许"
      status = "语音未开启"
      if recovering { open = true }
      return
    }
    wanted = true
    muted = false
    audioBlocked = false
    retries = 0
    owner = conversationId
    open = true
    status = "连接中"
    capturedPcmBytes = 0
    sentPcmBytes = 0
    receivedPcmBytes = 0
    bufferedFrames = 0
    playbackRate = 24000
    resetReplyAudio()
    loadSpeechPace()
    speechTrace = []
    trace("=== call start")
    error = nil
    lastYou = ""
    lastBot = ""
    run += 1
    let current = run
    do {
      listenToAudio()
      try await audio.start(echoCancel: store.settings.echoCancel, input: inputHandler())
      captureEcho = store.settings.echoCancel
      if !wanted || current != run {
        try? await audio.stop()
        return
      }
      try await connect(current)
    } catch {
      if current == run {
        await stopCall(keepOpen: recovering)
        permissionDenied = (error as? AudioError) == .micDenied
        if error is VoiceUnavailable {
          self.error = "所选音色不可用，请在设置中重新选择"
        } else if let e = error as? JarvisException {
          self.error = e.message
        } else if case AudioError.noInput(let message) = error {
          self.error = message.isEmpty ? "未检测到可用的麦克风" : message
        } else {
          self.error = "无法开启语音，请检查麦克风权限与网络"
        }
        status = error is VoiceUnavailable ? "音色未确认" : "语音未开启"
        if let e = error as? JarvisException, e.unauthorized { store.expireSession() }
      }
    }
  }

  /// The speech engine is listed and, when it lists voices, the chosen voice is one of them.
  private var voiceAvailable: Bool {
    guard let speaker = speech else { return false }
    return speaker.voices.isEmpty || speaker.voices.contains { $0.id == voice }
  }

  private struct VoiceUnavailable: Error {}

  private func inputHandler() -> @Sendable (Data) -> Void {
    { [weak self] bytes in Task { @MainActor in self?.input(bytes) } }
  }

  private func listenToAudio() {
    if audioReader != nil { return }
    let events = audio.events
    audioReader = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        self.onAudio(event)
      }
    }
  }

  private func connect(_ current: Int) async throws {
    ready = false
    status = retries > 0 ? "正在重连" : "连接中"
    // The server's voice defaults and model names may have changed since the last call or connection.
    let slow = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled, let self, current == self.run, self.wanted else { return }
      self.status = "正在刷新配置"
    }
    await store.refreshModelCatalog()
    slow.cancel()
    if current != run || !wanted { return }
    status = retries > 0 ? "正在重连" : "连接中"
    // The refresh can take a voice or an engine away; say so now instead of failing at the server's confirmation.
    if !voiceAvailable { throw VoiceUnavailable() }
    let wire = try await store.api.openRealtime()
    if current != run || !wanted {
      await wire.close()
      return
    }
    attach(current, wire)
  }

  private func attach(_ current: Int, _ wire: RealtimeWire) {
    self.wire = wire
    settingsDeferred = false
    userSpeaking = false
    speechOpen = false
    speechWatch.cancel()
    items = [:]
    cancelled = []
    cut = []
    latestResponse = nil
    finished = []
    outcomes = [:]
    lastBotItem = nil
    pendingUpdates = 0
    pendingClears = 0
    awaitingItem = nil
    response = nil
    wireReader?.cancel()
    let events = wire.events
    wireReader = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        guard self.wire === wire else { return }
        switch event {
        case .text(let raw):
          if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)), let object = value.object {
            self.handle(object)
          } else {
            self.fail("收到无效的语音事件，文字内容已保留")
          }
        case .closed, .failed:
          await self.lost(current, wire)
          return
        }
      }
      await self?.lost(current, wire)
    }
    updateSettings()
    // Seed complete turns only; a tool receipt is a sourced system note, never new user input.
    if let owner, let c = store.conversation(owner) {
      // A half-recognised sentence of the user is not given back as if it had been said whole.
      let turns = c.messages.filter {
        !$0.text.isEmpty && ($0.role == "assistant" ? $0.status != "generating" : $0.role == "user" && $0.status == "complete")
      }
      for m in turns.suffix(40) {
        var item: [String: JSONValue] = [
          "type": .string("message"), "role": .string(m.role),
          "content": .array([.object(["type": .string(m.role == "user" ? "input_text" : "text"), "text": .string(m.text)])]),
        ]
        // Whether a reply was finished is part of what the call remembers: one that was stopped, failed or cut at the length
        // limit must not be taken for a complete answer.
        if m.role == "assistant" { item["status"] = .string(m.wireStatus) }
        send(["type": .string("conversation.item.create"), "item": .object(item)])
      }
    }
  }

  // MARK: Settings

  public func updateSettings() {
    let s = store.settings
    // Mute belongs to hands-free mode; switching to push-to-talk must not carry it over.
    if muted && s.voiceMode != "vad" { muted = false }
    if wanted && (captureBusy || captureEcho != s.echoCancel) {
      ready = false
      if captureBusy { return }
      captureBusy = true
      let current = run
      captureChain.append(
        onError: { [weak self] in
          guard let self else { return }
          self.captureBusy = false
          if current == self.run && self.wanted {
            self.audioBlocked = true
            self.ready = false
            self.fail("麦克风配置未能更新，请恢复语音")
          }
        }
      ) { [weak self] in
        guard let self else { return }
        while current == self.run && self.wanted && self.captureEcho != self.store.settings.echoCancel {
          let echo = self.store.settings.echoCancel
          try await self.audio.reconfigureInput(echoCancel: echo, input: self.inputHandler())
          self.captureEcho = echo
        }
        self.captureBusy = false
        if current == self.run && self.wanted { self.updateSettings() }
      }
      return
    }
    guard wire != nil else { return }
    // A confirmed call that is busy keeps its configuration until it is quiet (the server may refuse a model change in the
    // middle of a reply, and the microphone would be shut while the user speaks). Not confirmed yet: nothing is running
    // that the change could break, so send at once.
    if busyForConfig, ready, !configBlocked {
      settingsDeferred = true
      return
    }
    settingsDeferred = false
    let speaker = speech
    // The call's own strength: the user's pick, else the server's default. The chat's strength has no part in it.
    let effort = store.voiceEffort
    expectedSpeech = speaker?.id
    expectedVoice = voice
    expectedModel = store.voiceModel(for: effort)
    expectedReasoning = effort != "none"
    // A server that lists models per strength but none for this one cannot run it; sending the chat model instead would be a
    // different configuration than the one asked for. (A server that lists none at all is an older one: the chat model stays.)
    configBlocked = store.voiceModelsListed && expectedModel == nil
    if configBlocked {
      ready = false
      handshake.cancel()
      fail("该思考强度暂不可用，挂断后在设置中更换")
      return
    }
    pendingUpdates += 1
    ready = false
    error = nil
    status = "正在确认语音配置"
    var session: [String: JSONValue] = [
      "modalities": .array([.string("audio"), .string("text")]), "input_audio_format": .string("pcm16"),
      "output_audio_format": .string("pcm16"), "model": .string(expectedModel ?? store.model),
      "reasoning": .bool(expectedReasoning), "voice": .string(voice),
      "tool_choice": .string(s.tools ? "auto" : "none"),
      "max_response_output_tokens": s.maxTokens > 0 ? .number(Double(s.maxTokens)) : .string("inf"),
      "instructions": .string(
        "你是贾维斯。用户使用什么语言，就使用同一种语言回答。任务回执不是用户输入，不要主动插话。\(s.instructions.isEmpty ? "" : "\n\(s.instructions)")"
      ),
      "input_audio_transcription": .object(["language": .string(s.language), "prompt": .string(s.transcriptionPrompt)]),
      "turn_detection": s.voiceMode == "ptt"
        ? .null
        : .object([
          "type": .string("server_vad"), "threshold": .number(s.threshold), "silence_duration_ms": .number(Double(s.waitMs)),
          "prefix_padding_ms": .number(300), "create_response": .bool(false), "interrupt_response": .bool(true),
        ]),
    ]
    if let speaker { session["speech_model"] = .string(speaker.id) }
    send(["type": .string("session.update"), "session": .object(session)])
    let current = run
    handshake.start(handshakeTimeout) { [weak self] in
      guard let self, current == self.run, !self.ready else { return }
      self.fail("服务器尚未确认语音配置，请重试连接")
    }
  }

  /// One line per reply for judging the voice (the wait for the first sound, the stalls after it); written once, when the
  /// reply is over or cut off, whichever comes first.
  private func logReplyAudio(_ how: String) {
    guard let wait = firstAudioWait, !replyAudioLogged else { return }
    replyAudioLogged = true
    NSLog("[voice] %@: first audio after %.2f s, %d stall(s), longest %.2f s", how, wait, stalls, longestStall)
  }

  /// Records when a chunk of reply audio arrived against what was already queued to play (pcm16, mono).
  private func noteAudioArrival(_ bytes: Int) {
    let arrived = now()
    speechOpen = true
    lastAudioAt = arrived
    let length = Double(bytes) / 2 / Double(max(playbackRate, 1))
    if let ends = playbackEndsAt {
      if arrived > ends {
        stalls += 1
        longestStall = max(longestStall, arrived.timeIntervalSince(ends))
      }
      playbackEndsAt = max(arrived, ends).addingTimeInterval(length)
    } else {
      if let started = replyStartedAt { firstAudioWait = arrived.timeIntervalSince(started) }
      playbackEndsAt = arrived.addingTimeInterval(length)
    }
  }

  private func trace(_ line: String) {
    let t = replyStartedAt.map { now().timeIntervalSince($0) } ?? 0
    let text = String(format: "%7.2f ", t) + line
    speechTrace.append(text)
    if speechTrace.count > 400 { speechTrace.removeFirst(100) }
    traceSink?(text)
  }

  /// Where the words say the voice rests at the end of a sentence, to be set against the "rest in the sound" lines that follow.
  private func traceModelRests() {
    let rests = SpokenText(lastBot).sentenceRests(pace: speechPace)
    guard !rests.isEmpty else { return }
    let list = rests.prefix(40).map { String(format: "%.1f+%.1f", $0.at, $0.length) }.joined(separator: " ")
    trace(String(format: "words say the voice rests (pace %.3f) at: ", speechPace) + list)
  }

  /// While a reply is being made, once a second: how long the server has said nothing, and whether this check itself came late.
  /// A silent server and a phone too busy to listen look the same from the sound alone; they do not look the same here.
  private func armHeartbeat() {
    heartbeat.start(1) { [weak self] in
      guard let self, self.wanted else { return }
      let t = self.now()
      let late = t.timeIntervalSince(self.lastBeatAt) - 1
      let silent = t.timeIntervalSince(self.lastWireEventAt)
      let waiting = self.response != nil
      if (waiting && silent >= 2) || late >= 0.5 {
        let rate = Double(max(self.playbackRate, 1))
        self.trace(String(format: "heartbeat: server silent for %.1fs (reply %@), this check ran %.1fs late, player holds %.2fs, %.2fs waits to be handed over",
          silent, waiting ? "still being made" : "over", max(late, 0), Double(self.bufferedFrames) / rate, Double(self.queuedBytes) / 2 / rate))
      }
      self.lastBeatAt = t
      if waiting || self.speaking || self.queuedBytes > 0 { self.armHeartbeat() }
    }
  }

  /// The last four characters of an id: enough to tell replies and items apart in the trace.
  private func tag(_ id: String?) -> String { id.map { String($0.suffix(4)) } ?? "-" }

  /// The call page tells where it has drawn the lit edge (at most twice a second), next to what the call knows.
  public func traceReading(raw: Double?, shown: Double?, characters: Int) {
    guard now().timeIntervalSince(traceSampleAt) >= 0.5 else { return }
    traceSampleAt = now()
    let rate = Double(max(playbackRate, 1))
    let progress = speechProgress
    trace(String(format: "edge shown=%@ estimated=%@ of %d chars | played=%.2fs total=%@ pace=%.3f live=%@ cut=%@ | queued=%.2fs buffered=%.2fs",
      shown.map { String(format: "%.1f", $0) } ?? "-", raw.map { String(format: "%.1f", $0) } ?? "-", characters,
      progress?.played ?? 0, progress?.total.map { String(format: "%.2fs", $0) } ?? "-", progress?.pace ?? speechPace,
      progress?.live == true ? "yes" : "no", progress?.cut == true ? "yes" : "no", Double(queuedBytes) / 2 / rate, Double(bufferedFrames) / rate))
  }

  private func resetReplyAudio() {
    replyAudioBytes = 0
    replyRests = SoundRests(rate: playbackRate)
    replyPlaying = false
    replyAudioDone = false
    replyMarkerSeen = false
    replyEnded = false
    replyFailed = false
    replyMeasuredPace = nil
    replyCutAt = nil
  }

  /// Seconds of the reply's audio the player has got through: what arrived, less what still waits to be handed over and what
  /// the player holds. (The pre-roll the player keeps back for its first 0.18 s counts as played; the error is that small.)
  private var replyPlayedSeconds: Double {
    guard replyPlaying else { return 0 }
    let waiting = Double(queuedBytes) / 2 + Double(bufferedFrames)
    return max(0, Double(replyAudioBytes) / 2 - waiting) / Double(max(playbackRate, 1))
  }

  /// All of the reply's sound is here: its length is known now, which says how fast this voice speaks. That is only taken to
  /// be so when the reply has ended and the sound has marked its end after the last of it: a marker that comes in the middle
  /// of the reply ends a part (a paragraph) and says nothing about how long the whole is.
  private func noteReplyAudioComplete() {
    guard replyAudioBytes > 0, !replyAudioDone, replyMarkerSeen, replyEnded else { return }
    replyAudioDone = true
    let seconds = Double(replyAudioBytes) / 2 / Double(max(playbackRate, 1))
    let words = SpokenText(lastBot)
    let measured = words.pace(forTotal: seconds)
    replyMeasuredPace = measured
    trace(String(format: "all sound taken as arrived: %.2fs for %d chars, measured pace %.3f (carried pace %.3f)", seconds, words.clusters.count, measured, speechPace))
  }

  /// What the last reply showed of this voice's speed is the starting point for the next one, and for the next call.
  private func adoptMeasuredPace() {
    guard let measured = replyMeasuredPace else { return }
    speechPace = speechPaceKnown ? speechPace * 0.4 + measured * 0.6 : measured
    speechPaceKnown = true
    replyMeasuredPace = nil
    paceDefaults.set(speechPace, forKey: paceKey)
  }

  /// Seconds one spoken character is taken to last until the sound of the reply says otherwise.
  public var carriedSpeechPace: Double { speechPace }

  private var paceKey: String { "speechPace.\(store.settings.speechModel).\(voice)" }

  private func loadSpeechPace() {
    let saved = paceDefaults.double(forKey: paceKey)
    if SpokenText.paceRange.contains(saved) {
      speechPace = saved
      speechPaceKnown = true
    } else {
      speechPace = SpokenText.defaultPace
      speechPaceKnown = false
    }
  }

  /// A reply cut off while it was being said keeps the place it had reached, for the page to show where the voice stopped.
  private func markSpeechCut() {
    guard replyCutAt == nil, replyPlaying, speaking || queuedBytes > 0 else { return }
    replyCutAt = replyPlayedSeconds
  }

  /// Where the voice is in the reply the page shows, or nil when there is nothing to follow (no sound yet, a voice preview).
  public var speechProgress: SpeechProgress? {
    guard !previewing, replyAudioBytes > 0, !lastBot.isEmpty else { return nil }
    if let cut = replyCutAt { return SpeechProgress(played: cut, total: nil, pace: speechPace, live: false, cut: true) }
    guard replyPlaying else { return nil }
    let sounding = speaking || queuedBytes > 0
    // A reply the server failed stops being said part way: the words keep the mark where the sound ran out, so it shows how far
    // the reply was said (and not, as plain text would, that all of it was).
    if replyFailed, !sounding { return SpeechProgress(played: replyPlayedSeconds, total: nil, pace: speechPace, live: false, cut: true) }
    // The player has run dry while the server is still making the reply: the voice is waiting for more sound, not done. The
    // mark stays where the sound stopped (it would otherwise turn all the words bright, as if they had all been said, for as
    // long as the server takes to go on, or to fail).
    let waiting = response != nil && !replyEnded && !replyFailed
    let live = sounding || waiting
    let total = replyAudioDone ? Double(replyAudioBytes) / 2 / Double(max(playbackRate, 1)) : nil
    return SpeechProgress(played: replyPlayedSeconds, total: total, pace: speechPace, live: live, cut: false)
  }

  private func input(_ bytes: Data) {
    if !wanted { return }
    if settingsDeferred { applyDeferredSettings() }
    capturedPcmBytes += bytes.count
    if !ready || muted || previewing || wire == nil || (store.settings.voiceMode == "ptt" && !held && !tailOpen) {
      if levels.input != 0 { setLevels(input: 0) }
      return
    }
    setLevels(input: pcmRms(bytes))
    sentPcmBytes += bytes.count
    send(["type": .string("input_audio_buffer.append"), "audio": .string(bytes.base64EncodedString())])
  }

  // MARK: The device

  func onAudio(_ e: [String: JSONValue]) {
    let type = e["type"]?.string
    if type == "playback" {
      bufferedFrames = e["buffered_frames"]?.int ?? 0
      playbackRate = e["sample_rate"]?.int ?? 24000
      let active = e["active"]?.bool == true
      if active, replyAudioBytes > 0, replyCutAt == nil { replyPlaying = true }
      let rms = e["rms"]?.double ?? 0
      setLevels(output: active && !previewing && rms.isFinite ? min(max(rms, 0), 1) : 0, playing: active && !previewing)
      if active != speaking {
        trace(String(format: "player %@ buffered=%.2fs queued=%.2fs", active ? "started" : "stopped", Double(bufferedFrames) / Double(max(playbackRate, 1)), Double(queuedBytes) / 2 / Double(max(playbackRate, 1))))
        speaking = active
        if !active { applyDeferredSettings() }
        if !active && previewing {
          previewing = false
          previewLoading = false
          if wanted {
            Task { try? await audio.resetRate() }
          } else {
            Task { await stopPreview() }
          }
        }
        if !held && ready && error == nil { presentReadyState() }
        changed()
      }
    }
    if ["focus_lost", "input_error", "output_error"].contains(type ?? "") {
      cancelHold()
      // The input is blocked until the call is recovered; only hands-free mode shows that as "muted".
      muted = store.settings.voiceMode == "vad"
      audioBlocked = true
      ready = false
      handshake.cancel()
      previewRun += 1
      previewing = false
      previewLoading = false
      previewVoice = nil
      let previous = deviceClosing
      deviceClosing = Task { [weak self] in
        await previous.value
        guard let self else { return }
        await self.interrupt()
        do { try await self.audio.stop() } catch { self.fail("音频设备暂停失败，请结束并重新开启通话") }
      }
      fail(type == "output_error" ? "音频播放失败，请恢复语音；文字回复已保留" : "语音已暂停，麦克风或音频设备不可用")
    }
    if type == "open_requested" { open = true }
    if type == "stop_requested" { Task { await stop() } }
  }

  public func interrupt() async {
    if playbackPaused { playbackPaused = false; await audio.setPaused(false) }
    markSpeechCut()
    trace(String(format: "interrupt: played=%.2fs cut=%@", replyPlayedSeconds, replyCutAt.map { String(format: "%.2fs", $0) } ?? "no"))
    audioEpoch += 1
    speechOpen = false
    speechWatch.cancel()
    logReplyAudio("cut off")
    if let response {
      cancelled.insert(response)
      send(["type": .string("response.cancel")])
    }
    for (_, item) in items where item.role == "assistant" {
      edit(item.messageId) { if $0.status == "generating" { $0.status = "interrupted" } }
    }
    for (id, item) in items where item.role == "assistant" { cut.insert(id) }
    response = nil
    thinking = false
    speaking = false
    syncTurnTimer()
    setLevels(output: 0, playing: false)
    try? await audio.flush()
    changed()
  }

  // MARK: Push to talk

  public func hold() {
    if !ready || held || store.settings.voiceMode != "ptt" || previewing { return }
    clearTurnError()
    tail.cancel()
    tailOpen = false
    turn += 1
    held = true
    muted = false
    heldAt = now()
    awaitingItem = nil
    status = "正在聆听"
    hint = "松开发送"
    send(["type": .string("input_audio_buffer.clear")])
    Task { await interrupt() }
    changed()
  }

  public func release() {
    if !held { return }
    held = false
    hint = "正在处理这段语音"
    tailOpen = true
    let turn = self.turn
    let current = run
    let length = Int(now().timeIntervalSince(heldAt ?? now()) * 1000)
    tail.start(tailDuration) { [weak self] in
      guard let self else { return }
      self.tailOpen = false
      self.setLevels(input: 0)
      if current != self.run || turn != self.turn || self.held || !self.ready { return }
      if length < 250 {
        self.send(["type": .string("input_audio_buffer.clear")])
        self.status = "已就绪"
        self.hint = "请按住按钮后说话"
        return
      }
      self.awaitingItem = "pending"
      self.send(["type": .string("input_audio_buffer.commit"), "event_id": .string("ptt_\(current)_\(turn)")])
      self.thinking = true
      self.status = "正在识别"
      self.syncTurnTimer()
      self.changed()
    }
    changed()
  }

  public func cancelHold() {
    setLevels(input: 0)
    turn += 1
    tail.cancel()
    tailOpen = false
    held = false
    awaitingItem = nil
    send(["type": .string("input_audio_buffer.clear")])
    if ready && !thinking && !speaking {
      status = mutedInVad ? "已静音" : "已就绪"
      hint = mutedInVad ? "点击麦克风恢复聆听" : readyHint
    }
    syncTurnTimer()
    changed()
  }

  public func toggleMute() {
    muted.toggle()
    if muted { cancelHold() }
    // Through the same path as everything else, so a reply in progress keeps its own status.
    presentReadyState()
    changed()
  }

  public func minimize() {
    if held { cancelHold() }
    open = false
  }

  public func expand() { open = true }

  private func fail(_ text: String) {
    error = text
    hint = text
    changed()
  }

  // MARK: What the server says

  func handle(_ e: [String: JSONValue]) {
    lastWireEventAt = now()
    let type = e["type"]?.string ?? ""
    let id = e["item_id"]?.string
    let responseId = e["response_id"]?.string ?? e["response"]?["id"]?.string
    if (responseId != nil && cancelled.contains(responseId!)) || (id != nil && cut.contains(id!)) { return }
    if pendingClears > 0,
      ["input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "input_audio_buffer.committed"].contains(type)
    {
      return
    }
    switch type {
    case "input_audio_buffer.cleared":
      pendingClears = min(max(pendingClears - 1, 0), 100)
    case "session.updated":
      pendingUpdates = min(max(pendingUpdates - 1, 0), 100)
      let s = e["session"]
      ready =
        !audioBlocked && !configBlocked && !captureBusy && pendingUpdates == 0 && s?["reasoning"]?.bool == expectedReasoning
        && (expectedSpeech == nil || (s?["speech_model"]?.string == expectedSpeech && s?["voice"]?.string == expectedVoice))
        && (expectedModel == nil || s?["model"]?.string == expectedModel)
      if ready {
        handshake.cancel()
        retries = 0
        presentReadyState()
        error = nil
      } else if pendingUpdates == 0 && !audioBlocked && !configBlocked && !captureBusy {
        fail("服务器确认的音色或思考配置不一致，请重新选择")
      }
    case "input_audio_buffer.speech_started":
      if store.settings.voiceMode != "vad" || muted { break }
      userSpeaking = true
      clearTurnError()
      Task { await interrupt() }
      awaitingItem = nil
      lastYou = ""
      status = "正在聆听"
      hint = "正在听你说话"
    case "input_audio_buffer.speech_stopped":
      userSpeaking = false
    case "input_audio_buffer.committed":
      userSpeaking = false
      if store.settings.voiceMode == "vad" || awaitingItem == "pending" { awaitingItem = id }
    case "localrouter.transcription.partial":
      guard let id else { break }
      let m = user(id)
      let transcript = e["transcript"]?.string ?? ""
      edit(m) { $0.text = transcript }
      lastYou = transcript
    case "conversation.item.input_audio_transcription.completed":
      guard let id else { break }
      let m = user(id)
      let transcript = (e["transcript"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      edit(m) {
        $0.text = transcript
        $0.status = "complete"
      }
      lastYou = transcript
      if awaitingItem == id && !held && !muted && !previewing && ready && !transcript.isEmpty {
        clearTurnError()
        awaitingItem = nil
        thinking = true
        status = "正在思考"
        hint = "正在整理回复"
        send(["type": .string("response.create")])
      } else if awaitingItem == id {
        awaitingItem = nil
        thinking = false
        status = "没有听清"
        fail("没有识别到有效语音，请再说一次")
      }
    case "conversation.item.input_audio_transcription.failed":
      if awaitingItem == id {
        awaitingItem = nil
        thinking = false
        status = "没有听清"
        fail("这次语音识别失败，请重新说一次")
      }
    case "response.created":
      clearTurnError()
      // The reply that was the latest is closed now: what still arrives for an item it never showed is from an earlier turn.
      if let previous = latestResponse { close(previous) }
      response = e["response"]?["id"]?.string
      latestResponse = response
      lastBotItem = nil
      speechOpen = false
      speechWatch.cancel()
      adoptMeasuredPace()
      replyStartedAt = now()
      resetReplyAudio()
      traceTextAt = .distantPast
      traceAudioAt = .distantPast
      traceSampleAt = .distantPast
      trace("created reply=\(tag(response)) previous-latest=\(tag(latestResponse))")
      lastBeatAt = now()
      armHeartbeat()
      replyAudioLogged = false
      playbackEndsAt = nil
      firstAudioWait = nil
      longestStall = 0
      stalls = 0
      lastBot = ""
      thinking = true
      status = "正在思考"
      hint = "正在整理回复"
    case "response.text.delta", "response.audio_transcript.delta":
      guard let id else { break }
      let m = bot(id, responseId)
      let delta = e["delta"]?.string ?? ""
      let part = e["content_index"]?.int ?? 0
      // Text the server has already given as final is not added to.
      if items[id]?.settled.contains(part) == true { break }
      items[id]?.parts[part, default: ""] += delta
      let whole = items[id]?.text ?? ""
      edit(m) { $0.text = whole }
      if lastBotItem != id || whole.count - traceTextLength >= 40 || now().timeIntervalSince(traceTextAt) > 1 {
        traceTextAt = now()
        traceTextLength = whole.count
        trace("text item=\(tag(id)) part=\(part) len=\(whole.count)\(lastBotItem != id ? " (the page now shows this item)" : "")")
      }
      lastBot = whole
      lastBotItem = id
      thinking = false
      status = speaking ? "正在说话" : "正在回复"
      hint = replyHint
    case "response.audio.delta":
      guard let id else { break }
      // A reply the server ended as cancelled or failed is not played any further.
      if let responseId, let outcome = outcomes[responseId], outcome != "completed", outcome != "incomplete" { break }
      _ = bot(id, responseId)
      let data = Data(base64Encoded: e["delta"]?.string ?? "") ?? Data()
      receivedPcmBytes += data.count
      replyAudioBytes += data.count
      if replyAudioBytes == data.count { traceModelRests() }
      for rest in replyRests.add(data) { trace(String(format: "rest in the sound at %.2fs for %.2fs", rest.at, rest.length)) }
      if replyAudioBytes > data.count, let last = lastAudioAt, now().timeIntervalSince(last) >= 2 {
        trace(String(format: "sound came again after %.1fs without any (the player holds %.2fs)", now().timeIntervalSince(last), Double(bufferedFrames) / Double(max(playbackRate, 1))))
      }
      replyMarkerSeen = false
      if replyAudioDone {
        // More sound after the end was taken: it was the end of a part, not of the reply's sound.
        replyAudioDone = false
        replyMeasuredPace = nil
        trace("more sound came after its end was taken: the sound is not complete")
      }
      if replyAudioBytes == data.count || now().timeIntervalSince(traceAudioAt) >= 0.5 {
        traceAudioAt = now()
        trace(String(format: "audio %@ chunk=%.2fs received=%.2fs queued=%.2fs player-buffer=%.2fs", tag(responseId), Double(data.count) / 2 / Double(max(playbackRate, 1)), Double(replyAudioBytes) / 2 / Double(max(playbackRate, 1)), Double(queuedBytes) / 2 / Double(max(playbackRate, 1)), Double(bufferedFrames) / Double(max(playbackRate, 1))))
      }
      noteAudioArrival(data.count)
      let current = run
      let epoch = audioEpoch
      if queuedBytes + data.count > 1_440_000 {
        Task { await interrupt() }
        fail("语音播放积压，已停止当前语音；文字回复已保留")
        break
      }
      queuedBytes += data.count
      // Sound is still coming: if the reply is already done, wait for more before playing out what is held back.
      watchSpeechEnd(responseId)
      audioChain.append(onError: { [weak self] in self?.fail("语音播放失败，文字回复已保留") }) { [weak self] in
        guard let self else { return }
        defer { self.queuedBytes -= data.count }
        if current == self.run && epoch == self.audioEpoch && self.wire != nil && !self.cut.contains(id)
          && !(responseId != nil && self.cancelled.contains(responseId!))
        {
          try await self.audio.feed(data)
        }
      }
    case "localrouter.response.speech_done", "response.audio.done":
      trace(String(format: "marker %@ reply=%@ item=%@ part=%@ received=%.2fs text=%d chars", type, tag(responseId), tag(id), e["content_index"]?.int.map(String.init) ?? "-", Double(replyAudioBytes) / 2 / Double(max(playbackRate, 1)), lastBot.count))
      if responseId == nil || responseId == latestResponse {
        replyMarkerSeen = true
        noteReplyAudioComplete()
      }
      speechOpen = false
      speechWatch.cancel()
      applyDeferredSettings()
      let current = run
      let epoch = audioEpoch
      audioChain.append(onError: { [weak self] in self?.fail("语音播放失败，文字回复已保留") }) { [weak self] in
        guard let self else { return }
        if current == self.run && epoch == self.audioEpoch && self.wanted && !(responseId != nil && self.cancelled.contains(responseId!)) {
          try await self.audio.finish()
        }
      }
    case "response.output_item.done":
      if let item = e["item"], item["type"]?.string == "function_call", let owner {
        var event = item.object ?? [:]
        event["type"] = .string("call")
        store.voiceTask(owner, event)
      }
    case "localrouter.job.created", "localrouter.job.done":
      if let owner { store.voiceTask(owner, e) }
    case "response.audio_transcript.done", "response.text.done":
      // The text as the server finally has it (it may have been checked or repaired after it was streamed). It can arrive
      // before the reply's end is known, so it waits for `response.done` and only a completed reply puts it on the screen.
      guard let id else { break }
      let final = (type == "response.text.done" ? e["text"]?.string : e["transcript"]?.string) ?? e["transcript"]?.string ?? e["text"]?.string
      hold(id, responseId, part: e["content_index"]?.int ?? 0, text: final ?? "")
    case "response.done":
      let result = e["response"] ?? .object([:])
      trace(String(format: "response.done reply=%@ status=%@ outputs=%d received=%.2fs text=%d chars", tag(responseId ?? response), result["status"]?.string ?? "-", result["output"]?.array?.count ?? 0, Double(replyAudioBytes) / 2 / Double(max(playbackRate, 1)), lastBot.count))
      // `response.done` of a reply that is not the one in flight (an earlier turn finishing late) closes that reply's own items
      // and leaves the current one alone.
      let closing = responseId ?? response
      let inFlight = closing == nil || response == nil || closing == response
      if inFlight {
        thinking = false
        response = nil
        logReplyAudio("reply")
      }
      let state = result["status"]?.string
      let completed = state == "completed"
      if state == "failed", inFlight {
        replyFailed = true
        let why = result["status_details"]
        trace("reply failed: type=\(why?["type"]?.string ?? "-") reason=\(why?["reason"]?.string ?? "-") error=\(why?["error"]?["code"]?.string ?? why?["error"]?["type"]?.string ?? "-") message=\(String((why?["error"]?["message"]?.string ?? "-").prefix(120)))")
      }
      let mapped = completed ? "complete" : state == "incomplete" ? "length" : "interrupted"
      var listed: Set<String> = []
      for item in result["output"]?.array ?? [] {
        guard let itemId = item["id"]?.string, !cut.contains(itemId) else { continue }
        listed.insert(itemId)
        if completed, (item["role"]?.string ?? "assistant") == "assistant" {
          // The completed reply's own output is the text (the same order as the web and Android clients); the done events'
          // text fills in the parts the output does not have.
          for (index, part) in (item["content"]?.array ?? []).enumerated() {
            fill(itemId, closing, part: index, text: part["transcript"]?.string ?? part["text"]?.string ?? "")
          }
          applyPending(itemId)
        }
        if !completed { items[itemId]?.pending = [:] }
        if let m = items[itemId] { edit(m.messageId) { $0.status = mapped } }
      }
      // Whatever else the reply wrote is over as well.
      if let closing {
        for (id, item) in items where item.role == "assistant" && item.responseId == closing && !listed.contains(id) && !cut.contains(id) {
          if completed { applyPending(id) } else { items[id]?.pending = [:] }
          edit(item.messageId) { if $0.status == "generating" { $0.status = mapped } }
        }
        noteOutcome(closing, state ?? "")
      }
      // The reply is over but its speech may not be: sound still held back is played out if no more of it comes.
      if inFlight { endSpeech(closing, state ?? "") } else { speechWatch.cancel() }
      // A change that waited for this reply may just have gone out: the call is then confirming, not ready, and says so.
      if ready {
        // The phone is still saying what the server has already finished writing.
        let talking = speaking || queuedBytes > 0
        status = talking ? "正在说话" : mutedInVad ? "已静音" : "已就绪"
        hint = talking ? replyHint : mutedInVad ? "点击麦克风恢复聆听" : readyHint
      }
    case "error":
      thinking = false
      let code = e["error"]?["code"]?.string
      trace("error event: type=\(e["error"]?["type"]?.string ?? "-") code=\(code ?? "-") message=\(String((e["error"]?["message"]?.string ?? "-").prefix(120)))")
      // The server's word that the speech failed comes just before `response.done`: the mark is kept from this moment, not drawn
      // plain for the instant between the two.
      if code == "speech_failed", responseId == nil || responseId == latestResponse || responseId == response { replyFailed = true }
      fail(code == "speech_failed" ? "语音生成失败，文字回复仍可查看" : "语音服务返回错误，请重试当前操作")
    case "localrouter.voice.paused":
      ready = false
      status = "语音暂时暂停"
      hint = "模型任务结束后恢复"
    case "localrouter.voice.resumed":
      updateSettings()
    default: break
    }
    // Any word from the server proves it is alive; the wait for the next one starts over.
    syncTurnTimer(restart: turnTimer.isActive)
    changed()
  }

  /// A recording or message has gone out and nothing came back: don't leave "recognising / thinking" up forever.
  private func syncTurnTimer(restart: Bool = false) {
    let waiting = wanted && ready && (awaitingItem != nil || thinking)
    if !waiting {
      turnTimer.cancel()
      return
    }
    if turnTimer.isActive && !restart { return }
    let current = run
    turnTimer.start(response != nil ? replyTimeout : turnTimeout) { [weak self] in
      guard let self, current == self.run, self.wanted else { return }
      self.awaitingItem = nil
      self.thinking = false
      await self.interrupt()
      self.status = "没有收到回复"
      self.fail("服务器长时间没有回应，请再说一次或重试")
    }
  }

  private func item(_ id: String, _ role: String, _ responseId: String? = nil) -> String {
    if let known = items[id] { return known.messageId }
    let m = addMessage(role, "", status: "generating") ?? ""
    items[id] = Item(messageId: m, role: role, responseId: role == "assistant" ? (responseId ?? response) : nil)
    return m
  }

  private func user(_ id: String) -> String { item(id, "user") }
  private func bot(_ id: String, _ responseId: String? = nil) -> String { item(id, "assistant", responseId) }

  /// A reply is closed: late items of it that the call never saw are no longer taken in.
  private func close(_ responseId: String) {
    if finished.contains(responseId) { return }
    finished.append(responseId)
    if finished.count > 64 {
      for old in finished.prefix(finished.count - 64) { outcomes[old] = nil }
      finished.removeFirst(finished.count - 64)
    }
  }

  private func noteOutcome(_ responseId: String, _ state: String) {
    outcomes[responseId] = state
    close(responseId)
  }

  /// Whether an event for this item may touch it: not one of a cancelled reply or of an item that was cut off, not an item of
  /// another reply, and not an unseen item of a reply already closed (a late one from an earlier turn). Such events are dropped,
  /// so they cannot change what is shown now.
  private func admits(_ id: String, _ responseId: String?, ending: Bool = false) -> Bool {
    if cut.contains(id) { return false }
    if let responseId, cancelled.contains(responseId) { return false }
    if let known = items[id] {
      if known.role != "assistant" { return false }
      if let responseId, let own = known.responseId, responseId != own { return false }
      return true
    }
    // The reply's own end may name an item it never streamed, even when a newer reply was announced before the end arrived.
    if let responseId { return ending || !finished.contains(responseId) }
    return response != nil
  }

  /// The final text of a part, from a done event. Held until the reply has ended: only a completed reply shows it, a reply that
  /// was cancelled, failed or stopped short keeps the words already on the screen.
  private func hold(_ id: String, _ responseId: String?, part: Int, text: String) {
    if text.isEmpty || !admits(id, responseId) { return }
    _ = bot(id, responseId)
    guard let entry = items[id] else { return }
    if let rid = entry.responseId ?? responseId, let outcome = outcomes[rid] {
      // The reply's end came first: its outcome decides at once.
      if outcome == "completed" && !entry.fixed.contains(part) { show(id, part: part, text: text) }
      return
    }
    items[id]?.pending[part] = text
  }

  /// Puts the held final text of an item on the screen (the reply is completed).
  private func applyPending(_ id: String) {
    guard let entry = items[id], !entry.pending.isEmpty else { return }
    items[id]?.pending = [:]
    for part in entry.pending.keys.sorted() where !entry.fixed.contains(part) { show(id, part: part, text: entry.pending[part] ?? "") }
  }

  /// The text of a completed reply's `response.done` output. It outranks a done event's text, so it replaces whatever a
  /// done event put on the screen and keeps later ones from replacing it.
  private func fill(_ id: String, _ responseId: String?, part: Int, text: String) {
    if text.isEmpty || !admits(id, responseId, ending: true) { return }
    _ = bot(id, responseId)
    items[id]?.fixed.insert(part)
    show(id, part: part, text: text)
  }

  /// Replaces the streamed text of a part with its final text.
  private func show(_ id: String, part: Int, text: String) {
    guard var entry = items[id] else { return }
    let before = entry.text
    entry.parts[part] = text
    entry.pending[part] = nil
    entry.settled.insert(part)
    items[id] = entry
    let whole = entry.text
    if whole != before {
      trace("text corrected item=\(tag(id)) part=\(part) len \(before.count) -> \(whole.count)")
      textCorrections += before.isEmpty ? 0 : 1
      edit(entry.messageId) {
        $0.text = whole
        $0.revision += 1
      }
    }
    // The call page shows the latest reply; a late correction of an earlier one must not replace it.
    if lastBotItem == id || (lastBotItem == nil && (entry.responseId == nil || entry.responseId == latestResponse)) {
      lastBot = whole
      lastBotItem = id
    }
  }

  /// The reply is done but its speech has not said so. If no more sound arrives for a moment, play out what the player holds
  /// back (it waits for a little more before it starts) instead of leaving the end of the reply unsaid.
  ///
  /// The timer belongs to one connection, one reply and one player generation, and is checked again when it fires and when
  /// the work runs: a hang-up, a lost connection, a barge-in, a new reply or a reply that was cancelled or failed all make it
  /// stale, and a stale one does nothing (it must neither play an older reply's leftovers nor touch the new reply's audio).
  private func watchSpeechEnd(_ reply: String? = nil) {
    speechWatch.cancel()
    guard speechOpen, response == nil, wanted, let wire else { return }
    let reply = reply ?? latestResponse
    // A reply that ended (completed, or stopped at the length limit) is played out; a cancelled or failed one is not.
    if let reply {
      guard let outcome = outcomes[reply], outcome == "completed" || outcome == "incomplete" else { return }
    }
    let current = run
    let epoch = audioEpoch
    let armed = lastAudioAt
    func ours(_ s: VoiceSession) -> Bool {
      current == s.run && epoch == s.audioEpoch && s.wanted && s.wire === wire && s.response == nil && s.speechOpen
        && reply == s.latestResponse && armed == s.lastAudioAt
    }
    speechWatch.start(speechTailWait) { [weak self] in
      guard let self, ours(self) else { return }
      self.audioChain.append(onError: { [weak self] in self?.fail("语音播放失败，文字回复已保留") }) { [weak self] in
        guard let self, ours(self) else { return }
        try await self.audio.finish()
      }
    }
  }

  /// The reply ended with `state`. Once the audio already queued has been handed to the player: a cancelled or failed reply
  /// loses what the player still holds back (it must not be heard in front of the next reply), and the status is shown again
  /// (it said "speaking" because sound was queued).
  private func endSpeech(_ reply: String?, _ state: String) {
    speechWatch.cancel()
    guard wanted, let wire else { return }
    let drain = state == "completed" || state == "incomplete"
    if drain, reply == nil || reply == latestResponse {
      replyEnded = true
      noteReplyAudioComplete()
    }
    if drain { watchSpeechEnd(reply) }
    let current = run
    let epoch = audioEpoch
    audioChain.append(onError: {}) { [weak self] in
      guard let self, current == self.run, epoch == self.audioEpoch, self.wanted, self.wire === wire, self.response == nil,
        reply == self.latestResponse
      else { return }
      if !drain { await self.audio.discardHeld() }
      if self.ready, self.error == nil, !self.held { self.presentReadyState() }
    }
  }

  private func lost(_ current: Int, _ lostWire: RealtimeWire) async {
    if wire !== lostWire || current != run || !wanted { return }
    wire = nil
    resetLevels()
    markSpeechCut()
    audioEpoch += 1
    speechWatch.cancel()
    wireReader?.cancel()
    wireReader = nil
    Task { await lostWire.close() }
    ready = false
    held = false
    thinking = false
    speaking = false
    response = nil
    syncTurnTimer()
    tail.cancel()
    tailOpen = false
    awaitingItem = nil
    handshake.cancel()
    // Mark only the lost connection's items before awaiting device I/O. A reply cut by the connection says so (it is not one the
    // person stopped).
    for (_, item) in items {
      edit(item.messageId) {
        guard $0.status == "generating" else { return }
        $0.status = "interrupted"
        if item.role == "assistant" && !$0.text.isEmpty { $0.error = "连接中断，回复未说完" }
      }
    }
    status = "正在重连"
    hint = "连接中断，正在自动重连"
    do { try await audio.flush() } catch {
      if current == run && wanted && !disposed {
        audioBlocked = true
        fail("音频设备暂时无法重置，请恢复语音后继续")
      }
      return
    }
    // stop()/a new call can finish while the old device flush is pending.
    if current != run || !wanted || disposed { return }
    retries += 1
    if retries > 8 {
      await stopCall()
      fail("语音连接未能恢复，已保留对话")
      return
    }
    status = "正在重连"
    reconnect.start(reconnectDelay(retries)) { [weak self] in
      guard let self, current == self.run, self.wanted else { return }
      do {
        try await self.connect(current)
      } catch {
        if current != self.run || !self.wanted { return }
        if error is VoiceUnavailable {
          // Trying again cannot bring the voice back.
          await self.stopCall()
          self.fail("所选音色不可用，请在设置中重新选择")
          return
        }
        if let e = error as? JarvisException, e.unauthorized {
          // Retrying with a session the service rejected only repeats the refusal.
          await self.stopCall()
          self.fail("登录已过期，请重新登录")
          self.store.expireSession()
          return
        }
        self.wire = lostWire
        await self.lost(current, lostWire)
      }
    }
  }

  // MARK: Voice try-out

  public func playPreview(_ voice: VoiceInfo, engine: String) async {
    previewRun += 1
    let preview = previewRun
    previewLoading = true
    defer {
      // Whatever ended this attempt (a guard, a stop, a failure) the spinner must not outlive it; a newer attempt owns the
      // flag once it has bumped `previewRun`.
      if preview == previewRun && previewLoading { previewLoading = false }
    }
    await closing.value
    await previewClosing.value
    if preview != previewRun || disposed || startingFlag { return }
    cancelHold()
    previewError = nil
    // An earlier failure belongs to the earlier attempt; a live call keeps its own error.
    if !wanted { error = nil }
    previewing = true
    previewVoice = voice.id
    await interrupt()
    if preview != previewRun { return }
    listenToAudio()
    previewing = true
    previewVoice = voice.id
    do {
      // The server's clip is played as it is, but one this app cannot decode (not 16-bit mono WAV) is replaced by the voice
      // speaking the same sentence, rather than failing the try-out.
      let bytes = try await store.api.preview(voice, model: engine)
      let clip: PcmClip
      do { clip = try PcmClip.wav(bytes) } catch {
        if voice.preview == nil { throw error }
        clip = try PcmClip.wav(try await store.api.synthesize(voice, model: engine))
      }
      if preview != previewRun || !previewing { return }
      try await audio.preview(clip)
      if preview != previewRun { return }
      previewLoading = false
      speaking = true
    } catch {
      if preview == previewRun {
        previewing = false
        previewLoading = false
        // Not `error`: that one belongs to the call and would show up on the call page.
        previewError = "试听暂时不可用，请重试；已选音色保持不变"
      }
    }
  }

  /// Drops an error that no longer applies, e.g. after the speech engine or voice changed. A live call keeps its own.
  public func clearIdleError() {
    if previewError != nil { previewError = nil }
    if wanted || error == nil { return }
    error = nil
    hint = ""
    status = "已结束"
  }

  public func stopPreview() async {
    previewRun += 1
    previewError = nil
    previewing = false
    previewLoading = false
    previewVoice = nil
    let previous = previewClosing
    let work = Task { [weak self] in
      await previous.value
      guard let self else { return }
      try? await self.audio.flush()
      if self.wanted {
        try? await self.audio.resetRate()
      } else {
        try? await self.audio.stop()
        self.audioReader?.cancel()
        self.audioReader = nil
      }
    }
    previewClosing = work
    await work.value
  }

  // MARK: Ending

  public func stop() async {
    hangups += 1
    // A hang-up that joins a restart already in progress turns it into a plain stop.
    keepOpen = false
    open = false
    await stopCall()
  }

  private func stopCall(keepOpen keep: Bool = false) async {
    resetLevels()
    // What the last reply showed of the voice's speed is kept for the next call.
    adoptMeasuredPace()
    heartbeat.cancel()
    if stopping {
      await closing.value
      return
    }
    stopping = true
    keepOpen = keep
    let work = Task { [weak self] in
      await self?.finishCall()
      self?.stopping = false
    }
    closing = work
    await work.value
  }

  private func finishCall() async {
    if playbackPaused { playbackPaused = false; await audio.setPaused(false) }
    wanted = false
    retries = 0
    audioEpoch += 1
    previewRun += 1
    run += 1
    turn += 1
    tail.cancel()
    speechWatch.cancel()
    handshake.cancel()
    reconnect.cancel()
    ready = false
    held = false
    if !keepOpen { open = false }
    tailOpen = false
    syncTurnTimer()
    let old = wire
    wire = nil
    wireReader?.cancel()
    wireReader = nil
    await old?.close()
    audioReader?.cancel()
    audioReader = nil
    await previewClosing.value
    await deviceClosing.value
    await captureChain.tail.value
    try? await audio.stop()
    for (_, item) in items { edit(item.messageId) { if $0.status == "generating" { $0.status = "interrupted" } } }
    thinking = false
    speaking = false
    previewing = false
    previewLoading = false
    status = keepOpen ? "连接中" : "已结束"
    hint = ""
  }

  public func dispose() async {
    turnTimer.cancel()
    disposed = true
    await stop()
    try? await audio.stop()
  }
}
