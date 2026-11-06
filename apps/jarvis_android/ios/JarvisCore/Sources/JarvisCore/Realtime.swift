import Foundation

/// What the realtime connection says: a text frame, or that it is gone.
public enum WireEvent: Sendable {
  case text(String)
  case closed
  case failed
}

/// The realtime WebSocket. `JarvisAPI` opens a real one; tests bring their own.
public protocol RealtimeWire: AnyObject, Sendable {
  var events: AsyncStream<WireEvent> { get }
  func send(_ value: String) throws
  func close() async
}

/// A WebSocket to `/v1/realtime` (sub-protocol `realtime`), pinged every 20 seconds.
public final class WebSocketWire: NSObject, RealtimeWire, URLSessionWebSocketDelegate, @unchecked Sendable {
  private let task: URLSessionWebSocketTask
  private let session: URLSession
  public let events: AsyncStream<WireEvent>
  private let continuation: AsyncStream<WireEvent>.Continuation
  private var pinger: Task<Void, Never>?
  private var opened: CheckedContinuation<Void, Error>?
  private let lock = NSLock()

  init(session: URLSession, task: URLSessionWebSocketTask) {
    self.session = session
    self.task = task
    var c: AsyncStream<WireEvent>.Continuation!
    events = AsyncStream { c = $0 }
    continuation = c
    super.init()
  }

  /// Waits for the handshake; a refused upgrade is the server saying no to the session, not a network problem.
  func connect(timeout: Double) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
          self.lock.lock(); self.opened = c; self.lock.unlock()
          self.task.resume()
        }
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw URLError(.timedOut)
      }
      do {
        try await group.next()
        group.cancelAll()
      } catch {
        group.cancelAll()
        self.task.cancel(with: .goingAway, reason: nil)
        // The session holds its delegate; one that never connected is let go here (close() is not reached for it).
        self.session.invalidateAndCancel()
        throw error
      }
    }
    pinger = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        guard let self, !Task.isCancelled else { return }
        // A ping nobody answers is a dead connection: the task is ended, which reports it like any other loss.
        self.task.sendPing { [weak self] error in
          if error != nil { self?.task.cancel(with: .abnormalClosure, reason: nil) }
        }
      }
    }
    read()
  }

  private func read() {
    task.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(.string(let s)):
        self.continuation.yield(.text(s))
        self.read()
      case .success:
        self.read()  // binary frames are not part of the protocol
      case .failure:
        self.continuation.yield(.failed)
        self.continuation.finish()
      }
    }
  }

  public func send(_ value: String) throws {
    guard task.state == .running else { throw URLError(.networkConnectionLost) }
    task.send(.string(value)) { [weak self] error in
      if error != nil { self?.continuation.yield(.failed) }
    }
  }

  public func close() async {
    pinger?.cancel()
    task.cancel(with: .normalClosure, reason: nil)
    continuation.finish()
    session.finishTasksAndInvalidate()
  }

  public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    lock.lock(); let c = opened; opened = nil; lock.unlock()
    c?.resume()
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock(); let c = opened; opened = nil; lock.unlock()
    if let c {
      // The upgrade was refused: 401, 403 and 303 mean the session is gone.
      let status = (task.response as? HTTPURLResponse)?.statusCode
      if let status, [401, 403, 303].contains(status) {
        c.resume(throwing: JarvisException("登录已过期，请重新登录", unauthorized: true))
      } else {
        c.resume(throwing: error ?? URLError(.badServerResponse))
      }
    } else {
      continuation.yield(error == nil ? .closed : .failed)
      continuation.finish()
    }
  }
}

extension JarvisAPI {
  /// Opens the realtime WebSocket; waits at most 20 seconds for it, and a socket that opens late is closed, not leaked.
  public func openRealtime() async throws -> RealtimeWire {
    var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    parts.scheme = "wss"
    parts.path = "/v1/realtime"
    var request = URLRequest(url: parts.url!)
    request.setValue(base.jarvisOrigin, forHTTPHeaderField: "Origin")
    for (k, v) in mediaHeaders { request.setValue(v, forHTTPHeaderField: k) }
    request.setValue("realtime", forHTTPHeaderField: "Sec-WebSocket-Protocol")
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    let owner = WebSocketBox()
    let session = URLSession(configuration: config, delegate: owner, delegateQueue: nil)
    let task = session.webSocketTask(with: request)
    let wire = WebSocketWire(session: session, task: task)
    owner.wire = wire
    try await wire.connect(timeout: 20)
    return wire
  }
}

/// Hands the session's delegate callbacks to the wire (a session keeps its delegate strongly, the wire keeps the session).
final class WebSocketBox: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  weak var wire: WebSocketWire?
  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    wire?.urlSession(session, webSocketTask: webSocketTask, didOpenWithProtocol: `protocol`)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    wire?.urlSession(session, task: task, didCompleteWithError: error)
  }
}

/// The audio hardware: the microphone and the speaker on one engine (the system's echo cancellation needs both).
@MainActor
public protocol AudioDevice: AnyObject {
  /// `playback` (buffered_frames, sample_rate, active, rms), `focus_lost`, `input_error`, `output_error`,
  /// `open_requested`, `stop_requested`.
  var events: AsyncStream<[String: JSONValue]> { get }
  /// Asks for the microphone permission; false when it is refused or restricted.
  func microphonePermission() async -> Bool
  func start(echoCancel: Bool, input: @escaping @Sendable (Data) -> Void) async throws
  func reconfigureInput(echoCancel: Bool, input: @escaping @Sendable (Data) -> Void) async throws
  func feed(_ pcm: Data) async throws
  func flush() async throws
  func finish() async throws
  func preview(_ clip: PcmClip) async throws
  /// Back to the voice's own sample rate after a try-out.
  func resetRate() async throws
  func stop() async throws
  /// Holds what is playing where it is (and plays on from there), without losing the queue.
  func setPaused(_ paused: Bool) async
  /// Drops the beginning of a reply that the player is still holding back before it starts (it waits for a little more first),
  /// leaving what is already playing alone. For a reply that was cancelled or failed: its leftovers must not be heard in front
  /// of the next one.
  func discardHeld() async
}

public extension AudioDevice {
  func setPaused(_ paused: Bool) async {}
  func discardHeld() async {}
}

public enum AudioError: Error, Equatable {
  case micDenied
  case noInput(String)
}
