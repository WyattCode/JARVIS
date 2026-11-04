import AVFoundation

/// The call's audio on the real hardware: one engine plays and captures (the system's echo cancellation needs both). The
/// Swift counterpart of `NativeAudioDevice`: the same epochs (audio queued before a flush or a stop never plays afterwards),
/// the same warm-up before the first playback, the same events.
@MainActor
final class EngineAudioDevice: AudioDevice {
  private let core = AudioBridge()
  private var epoch = 0
  private var warm = Data()
  private var warming = true
  private var output: Task<Void, Error> = Task {}
  private var listeners: [UUID: AsyncStream<[String: JSONValue]>.Continuation] = [:]
  /// About 0.18 s of 24 kHz audio is gathered before playback starts, so a first small packet does not stutter.
  private let warmBytes = 8640

  init() {
    core.onEvent = { [weak self] event in
      guard let self else { return }
      let mapped = event.compactMapValues { Self.json($0) }
      if let e = mapped["epoch"]?.int, e != self.epoch { return }
      for continuation in self.listeners.values { continuation.yield(mapped) }
    }
  }

  private static func json(_ value: Any) -> JSONValue? {
    switch value {
    case let v as Bool: return .bool(v)
    case let v as Int: return .number(Double(v))
    case let v as Int64: return .number(Double(v))
    case let v as Double: return .number(v)
    case let v as String: return .string(v)
    default: return nil
    }
  }

  /// A stream per listener: one that stops listening does not end the others.
  var events: AsyncStream<[String: JSONValue]> {
    AsyncStream { continuation in
      let id = UUID()
      listeners[id] = continuation
      continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[id] = nil } }
    }
  }

  func microphonePermission() async -> Bool {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: return true
    case .denied: return false
    default: return await AVAudioApplication.requestRecordPermission()
    }
  }

  func start(echoCancel: Bool, input: @escaping @Sendable (Data) -> Void) async throws {
    guard await microphonePermission() else { throw AudioError.micDenied }
    core.onInput = input
    epoch += 1
    // A start after a stop begins with the warm-up of the first packet, as the first start does.
    warm = Data()
    warming = true
    output = Task {}
    do {
      try await core.configureAsync(rate: 24000, epoch: epoch, echoCancel: echoCancel)
    } catch {
      try? await stop()
      throw AudioBridge.isNoInput(error) ? AudioError.noInput("未检测到可用的麦克风，请检查音频输入后再开启语音") : error
    }
  }

  /// Changing the echo-cancel setting rebuilds the engine, which discards queued playback, so it moves to a new epoch like
  /// `flush` does.
  func reconfigureInput(echoCancel: Bool, input: @escaping @Sendable (Data) -> Void) async throws {
    epoch += 1
    warm = Data()
    warming = true
    output = Task {}
    core.onInput = input
    do {
      try await core.startCaptureAsync(echo: echoCancel, epoch: epoch)
    } catch {
      throw AudioBridge.isNoInput(error) ? AudioError.noInput("未检测到可用的麦克风，请检查音频输入后再开启语音") : error
    }
  }

  func feed(_ pcm: Data) async throws {
    if pcm.count % 2 != 0 { throw NSError(domain: "audio", code: 2) }
    warm.append(pcm)
    if warming && warm.count < warmBytes { return }
    warming = false
    let bytes = warm
    warm = Data()
    let current = epoch
    let previous = output
    let core = self.core
    let task = Task { [weak self] in
      _ = await previous.result
      guard let self else { return }
      if self.epoch == current { try await core.feedAsync(epoch: current, data: bytes) }
    }
    output = task
    try await task.value
  }

  func finish() async throws {
    if !warm.isEmpty {
      warming = false
      try await feed(Data())
    }
    _ = await output.result
  }

  func flush() async throws {
    epoch += 1
    warm = Data()
    warming = true
    output = Task {}
    await core.clearAsync(epoch: epoch)
  }

  func preview(_ clip: PcmClip) async throws {
    try await flush()
    try await core.configureAsync(rate: clip.rate, epoch: epoch, echoCancel: nil, keepCapture: true)
    try await core.feedAsync(epoch: epoch, data: clip.bytes)
  }

  func resetRate() async throws {
    try await flush()
    try await core.configureAsync(rate: 24000, epoch: epoch, echoCancel: nil, keepCapture: true)
  }

  func setPaused(_ paused: Bool) async { core.setPaused(paused) }

  func stop() async throws {
    epoch += 1
    warm = Data()
    core.onInput = nil
    await core.stopAsync()
  }
}
