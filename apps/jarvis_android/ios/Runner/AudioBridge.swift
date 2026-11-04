import AVFoundation

/// Tiny RMS envelopes indexed by submitted frames, never by arrival time (port of PcmLevelTimeline.kt).
struct PcmLevelTimeline {
  private struct Span {
    let start: Int64
    let end: Int64
    let rms: Double
  }

  private var spans: [Span] = []
  private var head = 0

  mutating func clear() {
    spans.removeAll()
    head = 0
  }

  mutating func append(_ samples: [Int16], firstFrame: Int64, rate: Int) {
    let window = max(1, rate / 50)  // 20ms, constant memory independent of reply size
    var at = 0
    while at < samples.count {
      let stop = min(at + window, samples.count)
      var sum = 0.0
      for i in at..<stop {
        let sample = Double(samples[i]) / 32768.0
        sum += sample * sample
      }
      spans.append(
        Span(start: firstFrame + Int64(at), end: firstFrame + Int64(stop), rms: (sum / Double(stop - at)).squareRoot()))
      at = stop
    }
    if spans.count - head > 600 { head = spans.count - 600 }
    if head > 600 {
      spans.removeFirst(head)
      head = 0
    }
  }

  mutating func level(at played: Int64) -> Double {
    while head < spans.count && spans[head].end <= played { head += 1 }
    guard head < spans.count else { return 0 }
    let span = spans[head]
    return played >= span.start && played < span.end ? span.rms : 0
  }
}

/// The call's audio engine: mono PCM16 in, every call carries an epoch so audio queued before clear()/stop() can never play
/// afterwards. The microphone is captured here too, on the playback engine; this class owns the shared AVAudioSession
/// (playAndRecord + voiceChat, which is what gives the system echo cancellation on input). `EngineAudioDevice` is its owner.
// All of its state is touched on `queue` (or under a lock), whichever thread calls in.
final class AudioBridge: NSObject, @unchecked Sendable {
  private enum AudioError: Error { case badRate, format, noInput }

  static func isNoInput(_ error: Error) -> Bool {
    if case AudioError.noInput = error { return true }
    return false
  }

  private let queue = DispatchQueue(label: "ai.jarvis.app.audio")
  /// The events and the captured audio go to the owner (`EngineAudioDevice`), on the main queue.
  var onEvent: (([String: Any]) -> Void)?
  var onInput: ((Data) -> Void)?
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var format: AVAudioFormat?
  private var epoch = 0
  private var rate = 24000
  private var submitted: Int64 = 0
  private var levels = PcmLevelTimeline()
  private var timer: DispatchSourceTimer?
  private var observers: [NSObjectProtocol] = []
  /// Microphone capture shares the playback engine, so the system echo canceller hears exactly what we play.
  private var captureEcho: Bool?
  private let captureLock = NSLock()
  private var captureConverter: AVAudioConverter?
  private var captureSource: AVAudioFormat?
  private var captureBuffers = 0  // under captureLock
  private var captureGeneration = 0  // under captureLock; bumped on every rebuild so late tap callbacks are ignored
  private var tapInstalled = false
  private var watchdogAttempts = 0
  private static let captureTarget = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)
  /// About 20s of audio; matches the practical queue depth of the Android player and gives feed() real backpressure.
  private let maxBufferedFrames: Int64 = 24000 * 20
  private let chunkBytes = 4800

  // MARK: Entry points

  /// Builds the session and the engine (with the microphone on the same engine when `echoCancel` is given).
  func configureAsync(rate: Int, epoch: Int, echoCancel: Bool?, keepCapture: Bool = false) async throws {
    try await onQueue { [self] in
      try configure(rate: rate, epoch: epoch, capture: keepCapture ? captureEcho : echoCancel)
    }
  }

  func startCaptureAsync(echo: Bool, epoch: Int) async throws {
    try await onQueue { [self] in try startCapture(echo: echo, epoch: epoch) }
  }

  func clearAsync(epoch: Int) async {
    try? await onQueue { [self] in
      self.epoch = epoch
      dropQueued()
    }
  }

  func stopAsync() async { try? await onQueue { [self] in endAudio() } }

  /// Hands PCM to the player; waits while the player has too much buffered (backpressure) and gives up silently when the
  /// epoch changed meanwhile.
  func feedAsync(epoch: Int, data: Data) async throws {
    let ok: Bool = await withCheckedContinuation { continuation in
      queue.async { self.feed(epoch: epoch, data: data, offset: 0) { continuation.resume(returning: $0) } }
    }
    if !ok { throw NSError(domain: "audio", code: 1) }
  }

  private func onQueue(_ work: @escaping () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        do {
          try work()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// The `record` plugin installs a tap using the engine input node's format, and with no usable input AVAudioEngine
  /// raises an Objective-C exception Dart can't catch, ending the app. So Dart asks first and shows an error instead.
  ///
  /// On a device the audio session tells us. In the iOS simulator it cannot: the session always looks healthy while the
  /// host Mac may have no microphone (a Mac mini), and even touching `AVAudioEngine().inputNode` then crashes inside
  /// CoreAudio. So the simulator refuses voice unless launched with `SIMCTL_CHILD_JARVIS_SIM_HAS_MIC=1`, meaning an
  /// audio input device is attached to the Mac.
  static func inputUsable() -> Bool {
    #if targetEnvironment(simulator)
      return ProcessInfo.processInfo.environment["JARVIS_SIM_HAS_MIC"] == "1"
    #else
      let session = AVAudioSession.sharedInstance()
      return session.isInputAvailable && session.inputNumberOfChannels > 0 && session.sampleRate > 0
    #endif
  }

  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { self.onEvent?(event) }
  }

  // MARK: Session and engine

  private func activateSession(capturing: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    if capturing {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
    } else {
      // A voice try-out only plays. In the call's voice-chat mode, without the echo-cancelling input that goes with it,
      // the same clip came out quieter than in the call; plain playback is at the normal media volume.
      try session.setCategory(.playback, mode: .default, options: [])
    }
    do {
      try session.setActive(true)
    } catch {
      // Another call or app holds the audio (a phone call, say): that is what the person is told, not "check the microphone".
      let busy = (error as NSError).code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue
        || (error as NSError).code == AVAudioSession.ErrorCode.isBusy.rawValue
      if busy { throw JarvisException("音频正被其他通话或应用占用，请结束后重试") }
      throw error
    }
    installObservers()
  }

  private func buildEngine() throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1) else {
      throw AudioError.format
    }
    let engine = AVAudioEngine()
    if let echo = captureEcho, echo {
      // Must be set before the engine starts; it also makes the output side the echo reference.
      try engine.inputNode.setVoiceProcessingEnabled(true)
    }
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    var tap = false
    if captureEcho != nil {
      tap = installCaptureTap(engine)
      // No usable input right now: starting would run a dead tap. Fail like a missing microphone.
      guard tap else { throw AudioError.noInput }
    }
    try engine.start()
    if !held { player.play() }
    self.engine = engine
    self.player = player
    self.format = format
    tapInstalled = tap
    if tap { scheduleCaptureWatchdog() }
  }

  private func teardownEngine() {
    if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
    tapInstalled = false
    // Late tap callbacks and the old converter must not leak into the next engine.
    captureLock.lock()
    captureGeneration += 1
    captureConverter = nil
    captureSource = nil
    captureLock.unlock()
    player?.stop()
    engine?.stop()
    engine?.reset()
    player = nil
    engine = nil
    format = nil
  }

  /// Right after the session is (re)activated the input route can take a moment to appear.
  private func awaitInput() throws {
    for _ in 0..<10 where !Self.inputUsable() { usleep(50_000) }
    guard Self.inputUsable() else { throw AudioError.noInput }
  }

  private func configure(rate: Int, epoch: Int, capture: Bool?) throws {
    guard (8000...192000).contains(rate) else { throw AudioError.badRate }
    try activateSession(capturing: capture != nil)
    if capture != nil { try awaitInput() }
    teardownEngine()
    self.rate = rate
    self.epoch = epoch
    captureEcho = capture
    watchdogAttempts = 0
    submitted = 0
    levels.clear()
    try buildEngine()
    publish()
  }

  private func endAudio() {
    teardownEngine()
    captureEcho = nil
    watchdogAttempts = 0
    epoch += 1
    submitted = 0
    levels.clear()
    publish()
    removeObservers()
    // Fails harmlessly if the capture engine has not finished stopping; Dart stops capture first.
    let session = AVAudioSession.sharedInstance()
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
    // The call's playAndRecord/voiceChat category would otherwise outlive it: video played afterwards would come out at
    // the quiet call volume through the receiver path. A category can be changed while the session is inactive.
    try? session.setCategory(.playback, mode: .default, options: [])
  }

  /// Drops everything scheduled but keeps the engine and session, so the next reply starts instantly.
  private func dropQueued() {
    submitted = 0
    levels.clear()
    if let player, let engine {
      player.stop()
      do {
        if !engine.isRunning { try engine.start() }
        // AVAudioPlayerNode.play() on a stopped engine raises an exception that ends the app.
        if engine.isRunning, !held { player.play() }
      } catch {
        emit(["type": "output_error"])
      }
    }
    publish()
  }

  // MARK: Capture

  /// Changes the echo-cancel setting mid-call: rebuilds the engine, so queued playback is discarded with a new epoch.
  private func startCapture(echo: Bool, epoch: Int) throws {
    // The epoch is the device's from the first: if the input is not there (or the rebuild fails), the audio that comes is still
    // told from the old one, instead of being dropped as stale for the rest of the call.
    self.epoch = epoch
    if engine == nil {
      // A failed rebuild earlier left none: it is made again here (not after the call has ended: nothing then would stop it).
      guard captureEcho != nil else { throw AudioError.format }
      try awaitInput()
      submitted = 0
      levels.clear()
      captureEcho = echo
      watchdogAttempts = 0
      try buildEngine()
      publish()
      return
    }
    try awaitInput()
    submitted = 0
    levels.clear()
    captureEcho = echo
    watchdogAttempts = 0
    teardownEngine()
    try buildEngine()
    publish()
  }

  /// Returns false when the input has no valid format (no microphone right now); installing a tap would raise.
  private func installCaptureTap(_ engine: AVAudioEngine) -> Bool {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      // A tap from before a route change still carries the old format: it must not keep running (or restart) on this one.
      input.removeTap(onBus: 0)
      captureLock.lock()
      captureGeneration += 1
      captureLock.unlock()
      return false
    }
    input.removeTap(onBus: 0)
    captureLock.lock()
    captureGeneration += 1
    let generation = captureGeneration
    captureBuffers = 0
    captureLock.unlock()
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
      self?.captured(buffer, generation: generation)
    }
    return true
  }

  /// If no audio arrives shortly after start (the input route was not ready), rebuild up to twice, then report it.
  private func scheduleCaptureWatchdog() {
    captureLock.lock()
    let generation = captureGeneration
    captureLock.unlock()
    queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, self.captureEcho != nil else { return }
      self.captureLock.lock()
      let current = self.captureGeneration, count = self.captureBuffers
      self.captureLock.unlock()
      guard current == generation, count == 0 else { return }
      guard self.watchdogAttempts < 2 else { return self.emit(["type": "input_error"]) }
      self.watchdogAttempts += 1
      try? AVAudioSession.sharedInstance().setActive(true)
      self.teardownEngine()
      // The new player starts from nothing: what was counted as queued for the old one is not there.
      self.submitted = 0
      self.levels.clear()
      do {
        try self.buildEngine()
      } catch {
        self.emit(["type": "input_error"])
      }
    }
  }

  /// Takes channel 0 (the processed mono signal), resamples to 24 kHz mono PCM16 and hands it to Dart.
  private func captured(_ buffer: AVAudioPCMBuffer, generation: Int) {
    let frames = Int(buffer.frameLength)
    guard frames > 0, let data = buffer.floatChannelData, let target = Self.captureTarget else { return }
    captureLock.lock()
    guard generation == captureGeneration else {
      captureLock.unlock()
      return
    }
    captureBuffers += 1
    if captureSource == nil || captureSource?.sampleRate != buffer.format.sampleRate {
      let mono = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false)
      captureSource = mono
      captureConverter = mono.flatMap { AVAudioConverter(from: $0, to: target) }
    }
    let converter = captureConverter, monoFormat = captureSource
    captureLock.unlock()
    guard let converter, let monoFormat,
      let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength)
    else { return }
    mono.frameLength = buffer.frameLength
    mono.floatChannelData![0].update(from: data[0], count: frames)
    let capacity = AVAudioFrameCount(Double(frames) * 24000 / monoFormat.sampleRate) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
    var provided = false
    var failure: NSError?
    converter.convert(to: out, error: &failure) { _, status in
      if provided {
        status.pointee = .noDataNow
        return nil
      }
      provided = true
      status.pointee = .haveData
      return mono
    }
    guard failure == nil, out.frameLength > 0, let pcm = out.int16ChannelData else { return }
    let bytes = Data(bytes: pcm[0], count: Int(out.frameLength) * 2)
    DispatchQueue.main.async {
      self.onInput?(bytes)
    }
  }

  // MARK: Playback

  /// `result` says whether the audio was taken (false: it could not be played).
  private func feed(epoch: Int, data: Data, offset: Int, result: @escaping (Bool) -> Void) {
    guard data.count % 2 == 0 else {
      return result(false)
    }
    guard !data.isEmpty, epoch == self.epoch, let player, let format else { return result(true) }
    var at = offset
    while at < data.count {
      if bufferedFrames() > maxBufferedFrames {
        // Backpressure without blocking the queue: retry the remainder shortly, still epoch-guarded.
        queue.asyncAfter(deadline: .now() + 0.008) {
          self.feed(epoch: epoch, data: data, offset: at, result: result)
        }
        return
      }
      let end = min(at + chunkBytes, data.count)
      let samples = data.subdata(in: (data.startIndex + at)..<(data.startIndex + end)).withUnsafeBytes {
        Array($0.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) }
      }
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
        let channel = buffer.floatChannelData?[0]
      else {
        return result(false)
      }
      buffer.frameLength = AVAudioFrameCount(samples.count)
      for (i, sample) in samples.enumerated() { channel[i] = Float(sample) / 32768.0 }
      // After an underrun the playhead ran on with nothing to play; new audio starts at the playhead, so counting from
      // the old total would undercount what is buffered (and misplace the levels).
      let played = playedFrames()
      if played > submitted { submitted = played }
      levels.append(samples, firstFrame: submitted, rate: rate)
      submitted += Int64(samples.count)
      player.scheduleBuffer(buffer, completionHandler: nil)
      at = end
    }
    publish()
    result(true)
  }

  private func playedFrames() -> Int64 {
    guard let player, let node = player.lastRenderTime, let time = player.playerTime(forNodeTime: node) else {
      return 0
    }
    return max(0, time.sampleTime)
  }

  private func bufferedFrames() -> Int64 { max(0, submitted - playedFrames()) }

  /// Reports transitions and occupancy from the render playhead, not from queue emptiness.
  private func publish() {
    let played = playedFrames()
    let frames = max(0, submitted - played)
    let active = player != nil && frames > 0
    emit([
      "type": "playback", "active": active, "buffered_frames": frames, "sample_rate": rate,
      "epoch": epoch, "rms": active ? levels.level(at: played) : 0.0,
    ])
    if active, timer == nil {
      let source = DispatchSource.makeTimerSource(queue: queue)
      source.schedule(deadline: .now() + 0.05, repeating: 0.05)
      source.setEventHandler { [weak self] in self?.publish() }
      source.resume()
      timer = source
    } else if !active, let source = timer {
      source.cancel()
      timer = nil
    }
  }

  // MARK: Interruptions and route changes

  private func installObservers() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    // A notification is only safe to read inside its own callout: the system may release what it carries (the engine
    // that changed, the user info) before a block queued for later runs, and copying them then crashed the app. What is
    // needed is taken out here, and only plain values travel to the audio queue.
    observers = [
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        self?.queue.async { self?.interruption(type) }
      },
      // Only our own playback engine: the `record` plugin runs a capture engine whose changes must not stop playback.
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
        guard let sender = note.object.map({ ObjectIdentifier($0 as AnyObject) }) else { return }
        self?.queue.async {
          guard let self, let engine = self.engine, ObjectIdentifier(engine) == sender else { return }
          self.recoverEngine()
        }
      },
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) {
        [weak self] _ in
        self?.queue.async { self?.rebuildAfterReset() }
      },
    ]
  }

  private func removeObservers() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
  }

  private func interruption(_ type: AVAudioSession.InterruptionType) {
    switch type {
    case .began:
      // Same behaviour as losing Android audio focus: stop output and let the voice session decide.
      submitted = 0
      levels.clear()
      player?.stop()
      publish()
      emit(["type": "focus_lost"])
    case .ended:
      guard engine != nil else { return }
      try? AVAudioSession.sharedInstance().setActive(true)
      recoverEngine()
    @unknown default:
      break
    }
  }

  /// Holds playback where it is, or lets it go on; what is queued stays queued.
  func setPaused(_ paused: Bool) {
    queue.async { [self] in
      held = paused
      guard let player, let engine, engine.isRunning else { return }
      if paused { player.pause() } else { player.play() }
    }
  }

  /// Playback is being held (a tap on the call page): a restart of the engine must not start it again.
  private var held = false

  /// Route changes (Bluetooth, headphones) restart the engine and discard its queued buffers.
  private func recoverEngine() {
    guard let engine, let player else { return }
    submitted = 0
    levels.clear()
    player.stop()
    do {
      if captureEcho != nil {
        tapInstalled = installCaptureTap(engine)
        if !tapInstalled {
          // The new route has no usable input: starting now would run without (or on a stale) tap. Report it instead.
          emit(["type": "input_error"])
          publish()
          return
        }
      }
      if !engine.isRunning { try engine.start() }
      if !held { player.play() }
    } catch {
      emit(["type": "output_error"])
    }
    publish()
  }

  private func rebuildAfterReset() {
    guard engine != nil else { return }
    // The media services daemon restarted, so the old engine, player and tap belong to a dead process: calling into them
    // (removeTap, stop, reset) is what teardown would do. Only forget them; configure then builds from nothing.
    tapInstalled = false
    captureLock.lock()
    captureGeneration += 1
    captureConverter = nil
    captureSource = nil
    captureLock.unlock()
    player = nil
    engine = nil
    format = nil
    do {
      try configure(rate: rate, epoch: epoch, capture: captureEcho)
    } catch {
      emit(["type": "output_error"])
    }
  }
}
