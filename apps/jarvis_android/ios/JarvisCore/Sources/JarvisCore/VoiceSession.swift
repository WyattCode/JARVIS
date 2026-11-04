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
  private var response: String?
  private var awaitingItem: String?
  private var expectedVoice: String?
  private var expectedSpeech: String?
  private var expectedModel: String?
  /// Items of the call (by the server's item id): the message each one is shown as.
  private var items: [String: (messageId: String, role: String)] = [:]
  private var cancelled: Set<String> = []
  private var cut: Set<String> = []
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
    } else if speaking {
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

  private func text(of id: String) -> String {
    guard let owner, let c = store.conversation(owner) else { return "" }
    return c.messages.first { $0.id == id }?.text ?? ""
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
    let speaker = speech
    if speaker == nil || (!speaker!.voices.isEmpty && !speaker!.voices.contains { $0.id == voice }) {
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
        if let e = error as? JarvisException {
          self.error = e.message
        } else if case AudioError.noInput(let message) = error {
          self.error = message.isEmpty ? "未检测到可用的麦克风" : message
        } else {
          self.error = "无法开启语音，请检查麦克风权限与网络"
        }
        status = "语音未开启"
        if let e = error as? JarvisException, e.unauthorized { store.expireSession() }
      }
    }
  }

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
    let wire = try await store.api.openRealtime()
    if current != run || !wanted {
      await wire.close()
      return
    }
    attach(current, wire)
  }

  private func attach(_ current: Int, _ wire: RealtimeWire) {
    self.wire = wire
    items = [:]
    cancelled = []
    cut = []
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
      let turns = c.messages.filter { ["user", "assistant"].contains($0.role) && !$0.text.isEmpty && $0.status != "generating" }
      for m in turns.suffix(40) {
        send([
          "type": .string("conversation.item.create"),
          "item": .object([
            "type": .string("message"), "role": .string(m.role),
            "content": .array([.object(["type": .string(m.role == "user" ? "input_text" : "text"), "text": .string(m.text)])]),
          ]),
        ])
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
    let speaker = speech
    let chat = store.models.first { $0.id == store.model }
    expectedSpeech = speaker?.id
    expectedVoice = voice
    expectedModel = JSONValue.object(chat?.metadata ?? [:])["jarvis"]?["voice_effort_models"]?[store.effort]?.string
    pendingUpdates += 1
    ready = false
    error = nil
    status = "正在确认语音配置"
    var session: [String: JSONValue] = [
      "modalities": .array([.string("audio"), .string("text")]), "input_audio_format": .string("pcm16"),
      "output_audio_format": .string("pcm16"), "model": .string(expectedModel ?? store.model),
      "reasoning": .bool(store.effort != "none"), "voice": .string(voice),
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

  private func input(_ bytes: Data) {
    if !wanted { return }
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
      let rms = e["rms"]?.double ?? 0
      setLevels(output: active && !previewing && rms.isFinite ? min(max(rms, 0), 1) : 0, playing: active && !previewing)
      if active != speaking {
        speaking = active
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
    audioEpoch += 1
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
        !audioBlocked && !captureBusy && pendingUpdates == 0 && s?["reasoning"]?.bool == (store.effort != "none")
        && (expectedSpeech == nil || (s?["speech_model"]?.string == expectedSpeech && s?["voice"]?.string == expectedVoice))
        && (expectedModel == nil || s?["model"]?.string == expectedModel)
      if ready {
        handshake.cancel()
        retries = 0
        presentReadyState()
        error = nil
      } else if pendingUpdates == 0 && !audioBlocked && !captureBusy {
        fail("服务器确认的音色或思考配置不一致，请重新选择")
      }
    case "input_audio_buffer.speech_started":
      if store.settings.voiceMode != "vad" || muted { break }
      clearTurnError()
      Task { await interrupt() }
      awaitingItem = nil
      lastYou = ""
      status = "正在聆听"
      hint = "正在听你说话"
    case "input_audio_buffer.committed":
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
      response = e["response"]?["id"]?.string
      lastBot = ""
      thinking = true
      status = "正在思考"
      hint = "正在整理回复"
    case "response.text.delta", "response.audio_transcript.delta":
      guard let id else { break }
      let m = bot(id)
      let delta = e["delta"]?.string ?? ""
      edit(m) { $0.text += delta }
      lastBot = text(of: m)
      thinking = false
      status = speaking ? "正在说话" : "正在回复"
      hint = replyHint
    case "response.audio.delta":
      guard let id else { break }
      _ = bot(id)
      let data = Data(base64Encoded: e["delta"]?.string ?? "") ?? Data()
      receivedPcmBytes += data.count
      let current = run
      let epoch = audioEpoch
      if queuedBytes + data.count > 1_440_000 {
        Task { await interrupt() }
        fail("语音播放积压，已停止当前语音；文字回复已保留")
        break
      }
      queuedBytes += data.count
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
    case "response.done":
      thinking = false
      response = nil
      let result = e["response"] ?? .object([:])
      for item in result["output"]?.array ?? [] {
        guard let itemId = item["id"]?.string, let m = items[itemId] else { continue }
        let state = result["status"]?.string
        edit(m.messageId) { $0.status = state == "completed" ? "complete" : state == "incomplete" ? "length" : "interrupted" }
      }
      status = speaking ? "正在说话" : mutedInVad ? "已静音" : "已就绪"
      hint = speaking ? replyHint : mutedInVad ? "点击麦克风恢复聆听" : readyHint
    case "error":
      thinking = false
      let code = e["error"]?["code"]?.string
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

  private func item(_ id: String, _ role: String) -> String {
    if let known = items[id] { return known.messageId }
    let m = addMessage(role, "", status: "generating") ?? ""
    items[id] = (m, role)
    return m
  }

  private func user(_ id: String) -> String { item(id, "user") }
  private func bot(_ id: String) -> String { item(id, "assistant") }

  private func lost(_ current: Int, _ lostWire: RealtimeWire) async {
    if wire !== lostWire || current != run || !wanted { return }
    wire = nil
    resetLevels()
    audioEpoch += 1
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
    // Mark only the lost connection's items before awaiting device I/O.
    for (_, item) in items { edit(item.messageId) { if $0.status == "generating" { $0.status = "interrupted" } } }
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
