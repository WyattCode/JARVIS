import Foundation

public struct JarvisException: Error, Equatable, CustomStringConvertible {
  public let message: String
  public let unauthorized: Bool
  /// The HTTP status the service answered with, when the error is its answer.
  public let status: Int?
  /// A job the service stopped reporting on for too long (it may be stuck): followed no further, and a retry makes a new one.
  public let stalled: Bool
  public init(_ message: String, unauthorized: Bool = false, status: Int? = nil, stalled: Bool = false) {
    self.message = message
    self.unauthorized = unauthorized
    self.status = status
    self.stalled = stalled
  }
  public var description: String { message }
}

/// What a voice says when it is tried out without a clip from the server.
public let previewSentence = "你好，我是贾维斯。我们把问题理清楚，一步一步找到答案。"

/// Refuses every redirect: a login or a file the server moves is an answer to read, not a place to follow (a cookie must
/// not travel to another host).
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

/// One download into a temporary file, a task of its own. It stops as soon as more than `limit` bytes are on their way, or the answer
/// is an error status (whose body is not kept): a huge or endless answer does not fill the disk first.
private final class FileFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  enum Outcome {
    case finished(URL, HTTPURLResponse)
    case tooLarge
    case status(HTTPURLResponse)
  }

  private let limit: Int
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Outcome, Error>?
  private var task: URLSessionDownloadTask?
  private var stopped: Outcome?
  private var kept: URL?
  private var cancelled = false

  init(limit: Int) { self.limit = limit }

  func run(_ session: URLSession, _ request: URLRequest) async throws -> Outcome {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Outcome, Error>) in
        let t = session.downloadTask(with: request)
        // (its delegate is set before a cancel can reach it: a task cancelled without it would not report back here)
        t.delegate = self
        lock.lock()
        continuation = c
        task = t
        let early = cancelled
        lock.unlock()
        t.resume()
        // Cancelled before the task was there to be cancelled.
        if early { t.cancel() }
      }
    } onCancel: {
      lock.lock(); cancelled = true; let t = task; lock.unlock()
      t?.cancel()
    }
  }

  private func stop(_ why: Outcome, _ task: URLSessionTask) {
    lock.lock()
    let first = stopped == nil
    if first { stopped = why }
    lock.unlock()
    if first { task.cancel() }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      return stop(.status(http), downloadTask)
    }
    if totalBytesWritten > Int64(limit) || totalBytesExpectedToWrite > Int64(limit) { stop(.tooLarge, downloadTask) }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // The system removes its file when this returns: it is moved to one of ours.
    let mine = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-dl-\(UUID().uuidString)")
    if (try? FileManager.default.moveItem(at: location, to: mine)) != nil {
      lock.lock(); kept = mine; lock.unlock()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let c = continuation
    continuation = nil
    let why = stopped
    let file = kept
    // (the task holds this as its delegate, and this held the task)
    self.task = nil
    lock.unlock()
    guard let c else { return }
    if let why {
      if let file { try? FileManager.default.removeItem(at: file) }
      return c.resume(returning: why)
    }
    if let error {
      if let file { try? FileManager.default.removeItem(at: file) }
      return c.resume(throwing: error)
    }
    guard let http = task.response as? HTTPURLResponse, let file else { return c.resume(throwing: JarvisException("服务暂时不可用")) }
    c.resume(returning: .finished(file, http))
  }

  // The session's own delegate refuses the redirects; a task's own would be asked in its place for the other callbacks only.
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

/// Runs `operation`, giving up with `URLError.timedOut` after `seconds`.
func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw URLError(.timedOut)
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}

extension URL {
  /// `scheme://host[:port]`, as a browser names an origin.
  var jarvisOrigin: String {
    var out = "\(scheme ?? "")://\(host ?? "")"
    if let port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) { out += ":\(port)" }
    return out
  }
}

public final class JarvisAPI: @unchecked Sendable {
  public let base: URL
  public var apiKey = ""
  public var cookie: String?

  /// How long a chat request may take to start answering. Unlike the 30 s of the cheap calls it covers uploading a body
  /// with images and a slow model reading a long prompt before its first byte.
  public var chatHeaderTimeout: Double = 90
  /// How long the video poll waits between two looks (tests make it short).
  public var pollInterval: Double = 1
  /// How long a job may report nothing before it is given up as stuck (nil: by kind, see `MediaProgress.quietLimit`).
  public var quietLimit: TimeInterval?

  private let configuration: URLSessionConfiguration
  private let lock = NSLock()
  private var authSequence = 0
  private var requests: [String: URLSession] = [:]
  static let downloadLimit = 256 * 1024 * 1024
  static let previewLimit = 8 * 1024 * 1024

  public init(base: URL, configuration: URLSessionConfiguration = .ephemeral) throws {
    guard base.scheme == "https", let host = base.host, !host.isEmpty, base.user == nil, base.password == nil,
      URLComponents(url: base, resolvingAgainstBaseURL: false)?.query == nil,
      URLComponents(url: base, resolvingAgainstBaseURL: false)?.fragment == nil,
      base.path.isEmpty || base.path == "/"
    else { throw JarvisException("请输入 HTTPS 服务地址，不包含路径或账户信息") }
    self.base = base
    let config = configuration.copy() as! URLSessionConfiguration
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.httpCookieAcceptPolicy = .never
    config.urlCache = nil
    config.timeoutIntervalForRequest = 60
    self.configuration = config
  }

  public var endpoint: URL { base }

  /// The headers a media request to the server carries (the cookie, or the key).
  public var mediaHeaders: [String: String] {
    var h: [String: String] = [:]
    if let cookie { h["Cookie"] = cookie }
    if !apiKey.isEmpty { h["Authorization"] = "Bearer \(apiKey)" }
    return h
  }

  /// An address of the server, or of a foreign https host; a server file named with another host's origin is taken
  /// from the server itself.
  public func mediaURL(_ path: String) throws -> URL {
    guard let url = URL(string: path, relativeTo: base)?.absoluteURL,
      ["https", "http"].contains(url.scheme ?? ""), url.user == nil
    else { throw JarvisException("媒体地址无效") }
    if url.jarvisOrigin != base.jarvisOrigin, url.path.hasPrefix("/v1/files/") || url.path.hasPrefix("/v1/videos/") {
      var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
      parts.path = url.path
      parts.query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
      return parts.url!
    }
    // Plain http to a foreign host is refused.
    guard url.scheme == "https" else { throw JarvisException("媒体地址无效") }
    return url
  }

  // MARK: Plumbing

  private func makeSession(idle: Double = 60, total: Double? = nil) -> URLSession {
    let config = configuration.copy() as! URLSessionConfiguration
    config.timeoutIntervalForRequest = idle
    if let total { config.timeoutIntervalForResource = total }
    return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
  }

  private func nextAuthSequence() -> Int {
    lock.lock(); defer { lock.unlock() }
    authSequence += 1
    return authSequence
  }

  private func isLatestAuth(_ sequence: Int) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return sequence == authSequence
  }

  private func register(_ id: String, _ session: URLSession) {
    lock.lock(); requests[id] = session; lock.unlock()
  }

  private func isCurrent(_ id: String, _ session: URLSession) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return requests[id] === session
  }

  private func unregister(_ id: String, _ session: URLSession) {
    lock.lock()
    if requests[id] === session { requests[id] = nil }
    lock.unlock()
  }

  private func request(_ method: String, _ path: String, body: Data? = nil, type: String? = nil, to url: URL? = nil) -> URLRequest {
    var r = URLRequest(url: url ?? URL(string: path, relativeTo: base)!.absoluteURL)
    r.httpMethod = method
    r.httpShouldHandleCookies = false
    r.setValue(base.jarvisOrigin, forHTTPHeaderField: "Origin")
    if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    if let cookie { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
    if let body {
      r.setValue(type ?? "application/json", forHTTPHeaderField: "Content-Type")
      r.httpBody = body
    }
    return r
  }

  /// Sends the request and returns the answer's headers with a stream of its body.
  private func open(_ session: URLSession, _ request: URLRequest, headerTimeout: Double = 30) async throws
    -> (URLSession.AsyncBytes, HTTPURLResponse)
  {
    let (bytes, response) = try await withTimeout(headerTimeout) { try await session.bytes(for: request) }
    guard let http = response as? HTTPURLResponse else { throw JarvisException("服务暂时不可用") }
    return (bytes, http)
  }

  private func check(_ r: HTTPURLResponse) throws {
    if r.statusCode == 401 || r.statusCode == 303 { throw JarvisException("登录已过期，请重新登录", unauthorized: true) }
    if !(200..<300).contains(r.statusCode) {
      throw JarvisException(r.statusCode == 429 ? "请求过于频繁，请稍后重试" : "服务暂时不可用（\(r.statusCode)）", status: r.statusCode)
    }
  }

  private func text(_ bytes: URLSession.AsyncBytes, limit: Int = Int.max) async throws -> Data {
    var data = Data()
    for try await byte in bytes {
      data.append(byte)
      if data.count > limit { throw JarvisException("文件过大") }
    }
    return data
  }

  private func json(
    _ method: String, _ path: String, body: [String: JSONValue]? = nil, wait: Double = 30, session owned: URLSession? = nil
  ) async throws -> [String: JSONValue] {
    let session = owned ?? makeSession(idle: wait)
    defer { if owned == nil { session.finishTasksAndInvalidate() } }
    let payload = try body.map { try JSONEncoder().encode($0) }
    let (bytes, response) = try await open(session, request(method, path, body: payload), headerTimeout: wait)
    try check(response)
    let data = try await withTimeout(wait) { [self] in try await text(bytes) }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let object = value.object else {
      throw JarvisException("服务返回的内容无法读取")
    }
    return object
  }

  // MARK: Account

  /// What a login the server turned down says (the caller tells a refused password from a failed connection by it).
  public static let loginRejectedMessage = "登录未成功，请检查账户与密码"

  public func login(_ username: String, _ password: String) async throws {
    let sequence = nextAuthSequence()
    let session = makeSession()
    defer { session.finishTasksAndInvalidate() }
    let body = "username=\(Self.formEncode(username))&password=\(Self.formEncode(password))"
    let (_, response) = try await open(
      session, request("POST", "/login", body: Data(body.utf8), type: "application/x-www-form-urlencoded"))
    var fields: [String: String] = [:]
    for (k, v) in response.allHeaderFields { if let k = k as? String, let v = v as? String { fields[k] = v } }
    let tokens = HTTPCookie.cookies(withResponseHeaderFields: fields, for: base).filter { $0.name == "__Host-jarvis_session" }
    if response.statusCode == 303, tokens.count == 1, let token = tokens.first, !token.value.isEmpty {
      if !isLatestAuth(sequence) { throw JarvisException("登录操作已结束") }
      cookie = "\(token.name)=\(token.value)"
      return
    }
    switch response.statusCode {
    case 429: throw JarvisException("尝试次数较多，请稍后再试")
    // What a refused sign-in looks like: the form again (200), a redirect with no session (303), or a plain refusal.
    case 200, 303, 400, 401, 403, 422: throw JarvisException(Self.loginRejectedMessage)
    // Anything else (a server that is down, an error page in the way) says nothing about the password: it is not a refusal.
    default: throw JarvisException("服务暂时不可用（\(response.statusCode)）")
    }
  }

  public func logout() async throws {
    _ = nextAuthSequence()
    let previous = cookie
    cookie = nil
    let session = makeSession(idle: 20)
    defer { session.finishTasksAndInvalidate() }
    var r = request("POST", "/logout", body: Data(), type: "application/x-www-form-urlencoded")
    if let previous { r.setValue(previous, forHTTPHeaderField: "Cookie") }
    _ = try await open(session, r, headerTimeout: 20)
  }

  /// application/x-www-form-urlencoded: unreserved characters as they are, a space as `+`, everything else as %XX of its
  /// UTF-8 bytes.
  static func formEncode(_ s: String) -> String {
    var out = ""
    for byte in s.utf8 {
      switch byte {
      case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
        UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
        out.append(Character(UnicodeScalar(byte)))
      case UInt8(ascii: " "): out += "+"
      default: out += String(format: "%%%02X", byte)
      }
    }
    return out
  }

  // MARK: Models and chat

  public func models() async throws -> [ModelInfo] {
    let value = try await json("GET", "/v1/models")
    // The voice revisions may sit on the list itself instead of on the speech engine; the engine's own win.
    var listRevisions: [String: JSONValue] = [:]
    for key in ["voice_catalog_revision", "voice_default_revision"] {
      if let v = value[key], v != .null { listRevisions[key] = v }
    }
    let found = (value["data"]?.array ?? []).compactMap { entry -> ModelInfo? in
      guard var object = entry.object, object["qualified"] != .bool(false) else { return nil }
      if object["kind"]?.string == "speech" { object = listRevisions.merging(object) { _, own in own } }
      return ModelInfo(json: .object(object))
    }
    return ModelOrder.apply(found) { $0.name }
  }

  public func chat(
    requestId: String, model: String, effort: String, messages: [[String: JSONValue]], options: ChatOptions = ChatOptions()
  ) -> AsyncThrowingStream<ChatDelta, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        let session = makeSession(idle: 120)
        register(requestId, session)
        defer {
          unregister(requestId, session)
          session.invalidateAndCancel()
        }
        do {
          var body: [String: JSONValue] = [
            "model": .string(model), "messages": .array(messages.map { .object($0) }), "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)]), "reasoning_effort": .string(effort),
            "chat_template_kwargs": .object(["enable_thinking": .bool(effort != "none")]),
          ]
          if options.maxTokens > 0 { body["max_tokens"] = .number(Double(options.maxTokens)) }
          if !options.tools.isEmpty {
            body["tools"] = .array(options.tools.map { .object($0) })
            body["tool_choice"] = .string("auto")
          }
          let (bytes, response) = try await open(
            session, request("POST", "/v1/chat/completions", body: try JSONEncoder().encode(body)),
            headerTimeout: chatHeaderTimeout)
          try check(response)
          var parser = SSEParser()
          var finished = false
          var buffer = Data()
          func handle(_ events: [String]) throws -> Bool {
            for data in events {
              if data == "[DONE]" {
                continuation.yield(ChatDelta(done: true))
                return true
              }
              guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else { continue }
              if let error = event["error"], error != .null { throw JarvisException("模型返回错误，已保留收到的内容") }
              guard let choice = event["choices"]?.array?.first else { continue }
              let delta = choice["delta"] ?? .object([:])
              let tools = (delta["tool_calls"]?.array ?? []).map { t -> ToolDelta in
                let f = t["function"]
                return ToolDelta(t["index"]?.int ?? 0, t["id"]?.string ?? "", f?["name"]?.string ?? "", f?["arguments"]?.string ?? "")
              }
              continuation.yield(
                ChatDelta(
                  text: delta["content"]?.string ?? "", reasoning: delta["reasoning_content"]?.string ?? "",
                  finishReason: choice["finish_reason"]?.string, toolDeltas: tools))
            }
            return false
          }
          for try await byte in bytes {
            buffer.append(byte)
            // Hand the parser what has arrived at each line end, so a delta is not held back.
            if byte == 0x0A {
              if try handle(parser.feed(buffer)) { finished = true; break }
              buffer.removeAll(keepingCapacity: true)
            }
          }
          if !finished { finished = try handle(parser.feed(buffer) + parser.finish()) }
          if !finished { throw JarvisException("连接中断，已保留收到的内容；未自动重试") }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func cancel(_ requestId: String) {
    lock.lock()
    let session = requests.removeValue(forKey: requestId)
    lock.unlock()
    session?.invalidateAndCancel()
  }

  public func close() {
    lock.lock()
    let all = Array(requests.values)
    requests.removeAll()
    lock.unlock()
    all.forEach { $0.invalidateAndCancel() }
  }

  // MARK: Tools and jobs

  public func modelSkill() async throws -> [String: JSONValue] { try await json("GET", "/v1/skills/model-manager", wait: 5) }
  public func toolsStatus() async throws -> [String: JSONValue] { try await json("GET", "/v1/tools") }
  public func jobStatus(_ id: String) async throws -> [String: JSONValue] {
    try await json("GET", "/v1/jobs/\(Self.pathEncode(id))")
  }

  static func pathEncode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")) ?? s
  }

  public func modelTool(requestId: String, name: String, args: [String: JSONValue]) async throws -> String {
    guard modelToolNames.contains(name) else { throw JarvisException("此工具未开放") }
    let session = makeSession(idle: 600)
    register(requestId, session)
    defer {
      unregister(requestId, session)
      session.invalidateAndCancel()
    }
    let reply = try await json(
      "POST", "/mcp",
      body: [
        "jsonrpc": .string("2.0"), "id": .number(Double(Int(Date().timeIntervalSince1970 * 1_000_000))),
        "method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(args)]),
      ], wait: 600, session: session)
    func encode(_ message: String) -> String {
      (try? String(data: JSONEncoder().encode(["error": message]), encoding: .utf8)) ?? #"{"error":""}"#
    }
    if let error = reply["error"], error != .null { return encode(error["message"]?.string ?? "") }
    let result = reply["result"]?.object ?? [:]
    let text = (result["content"]?.array ?? []).filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }
      .joined(separator: "\n")
    return result["isError"]?.bool == true ? encode(text) : text
  }

  // MARK: Files

  /// Fetches [path] into a temporary file the system writes as the bytes come (a large video is never held in memory, nor read a byte at
  /// a time) and returns the file with its size. The caller moves or removes the file.
  func fetchFile(_ path: String, limit: Int) async throws -> (file: URL, size: Int) {
    // A whole file may take a while, but not for ever: the idle limit of the session is not all (a trickle never trips it).
    let session = makeSession(total: limit == Self.downloadLimit ? 900 : 120)
    defer { session.finishTasksAndInvalidate() }
    let url = try mediaURL(path)
    var r = URLRequest(url: url)
    r.httpShouldHandleCookies = false
    if url.jarvisOrigin == base.jarvisOrigin { r = request("GET", "", to: url) }
    let outcome = try await FileFetch(limit: limit).run(session, r)
    switch outcome {
    case .status(let http):
      try check(http)
      throw JarvisException("服务暂时不可用（\(http.statusCode)）")
    case .tooLarge:
      throw JarvisException(limit == Self.downloadLimit ? "文件超过256MB，请通过网页下载" : "文件过大")
    case .finished(let temp, let http):
      do {
        try check(http)
        let size = (try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > limit { throw JarvisException(limit == Self.downloadLimit ? "文件超过256MB，请通过网页下载" : "文件过大") }
        return (temp, size)
      } catch {
        try? FileManager.default.removeItem(at: temp)
        throw error
      }
    }
  }

  public func download(_ path: String) async throws -> Data { try await bytesOf(path, limit: Self.downloadLimit) }

  private func bytesOf(_ path: String, limit: Int) async throws -> Data {
    let (temp, _) = try await fetchFile(path, limit: limit)
    defer { try? FileManager.default.removeItem(at: temp) }
    return try Data(contentsOf: temp)
  }

  /// Saves [path] into [file] and returns the byte count. It goes to disk as it comes, and only a complete download appears under the
  /// final name (a failed one leaves nothing, and what was at [file] before stays).
  public func download(_ path: String, to file: URL) async throws -> Int {
    let (temp, size) = try await fetchFile(path, limit: Self.downloadLimit)
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: file)
      try FileManager.default.moveItem(at: temp, to: file)
    } catch {
      try? FileManager.default.removeItem(at: temp)
      throw error
    }
    return size
  }

  public func extractPDF(_ pdf: Data) async throws -> String {
    let session = makeSession(idle: 90)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await open(
      session, request("POST", "/v1/jarvis/extract-pdf", body: pdf, type: "application/pdf"), headerTimeout: 90)
    try check(response)
    let data = try await withTimeout(30) { [self] in try await text(bytes) }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let s = value["text"]?.string else {
      throw JarvisException("服务返回的内容无法读取")
    }
    return s
  }

  // MARK: Voices

  /// The server's own clip first, played as it is; the same sentence is spoken only when the server names no clip or it
  /// cannot be fetched.
  public func preview(_ voice: VoiceInfo, model: String) async throws -> Data {
    if let clip = voice.preview, !clip.isEmpty, let data = try? await bytesOf(clip, limit: Self.previewLimit) { return data }
    return try await synthesize(voice, model: model)
  }

  public func synthesize(_ voice: VoiceInfo, model: String) async throws -> Data {
    let session = makeSession(idle: 45)
    defer { session.invalidateAndCancel() }
    let body: [String: JSONValue] = [
      "model": .string(model), "voice": .string(voice.id), "input": .string(previewSentence), "response_format": .string("wav"),
    ]
    let (bytes, response) = try await open(
      session, request("POST", "/v1/audio/speech", body: try JSONEncoder().encode(body)), headerTimeout: 120)
    try check(response)
    var data = Data()
    for try await byte in bytes {
      data.append(byte)
      if data.count > Self.previewLimit { throw JarvisException("试听音频过大") }
    }
    return data
  }

  // MARK: Pictures and videos

  public func generate(
    requestId: String, kind: String, args: [String: JSONValue], resumeJobId: String? = nil,
    onJob: ((String) -> Void)? = nil, onProgress: ((MediaReport) -> Void)? = nil
  ) async throws -> [String] {
    let session = makeSession(idle: 900)
    register(requestId, session)
    defer {
      unregister(requestId, session)
      session.invalidateAndCancel()
    }
    func show(_ value: JSONValue?) -> String {
      switch value {
      case .string(let s): return s
      case .number(let n):
        if n == n.rounded(), let whole = wholeNumber(n) { return String(whole) }
        return String(n)
      case .bool(let b): return String(b)
      default: return ""
      }
    }
    func report(_ j: [String: JSONValue]) -> MediaReport {
      MediaReport(progress: j["progress"]?.double ?? 0, phase: j["phase"]?.string ?? "", status: j["status"]?.string ?? "")
    }
    func files(_ j: [String: JSONValue]) -> [String] {
      let urls = stringList(j["urls"])
      if !urls.isEmpty { return urls }
      let named = stringList(j["files"])
      if !named.isEmpty { return named }
      return (j["data"]?.array ?? []).compactMap { $0["url"]?.string }
    }
    let gone = ["failed", "cancelled", "canceled", "expired"]
    let running = ["queued", "in_progress", "running"]
    var request: [String: JSONValue] = ["prompt": args["prompt"] ?? .null]
    if let model = args["model"], model != .null { request["model"] = model }

    var j: [String: JSONValue]
    let path: (String) -> String
    let failure: String
    if kind == "image" {
      if let size = args["size"], size != .null { request["size"] = .string(show(size)) }
      request["response_format"] = .string("url")
      path = { "/v1/jobs/\(Self.pathEncode($0))" }
      failure = "图片生成失败，请检查原任务"
      // Asked for as a job: the answer is the job's number at once and the picture follows, so the wait can show how far it is.
      // A service that does not know the option (400) or answers with the finished picture is served the old way.
      func create() async throws -> [String: JSONValue] {
        var asked = request
        asked["wait_s"] = .number(0)
        do {
          return try await json("POST", "/v1/images/generations", body: asked, wait: 900, session: session)
        } catch let e as JarvisException where e.status == 400 || e.status == 422 {
          return try await json("POST", "/v1/images/generations", body: request, wait: 900, session: session)
        }
      }
      if let resumeJobId, let old = try? await json("GET", path(resumeJobId), session: session), !gone.contains(old["status"]?.string ?? "gone") {
        j = old
      } else {
        j = try await create()
      }
      // The finished picture itself (the service waited for it).
      if j["id"] == nil || (j["status"] == nil && j["data"] != nil) {
        let done = files(j)
        if !done.isEmpty { return done }
        throw JarvisException("服务返回的内容无法读取")
      }
    } else {
      if let seconds = args["seconds"], seconds != .null { request["seconds"] = .string(show(seconds)) }
      path = { "/v1/videos/\(Self.pathEncode($0))" }
      failure = "视频生成失败，请检查原任务"
      if let resumeJobId {
        j = try await json("GET", path(resumeJobId), session: session)
        // A job the service has given up on is not looked at again (that would fail the same way every time): a new one is made.
        if gone.contains(j["status"]?.string ?? "") {
          j = try await json("POST", "/v1/videos", body: request, session: session)
        }
      } else {
        j = try await json("POST", "/v1/videos", body: request, session: session)
      }
    }
    guard let id = j["id"]?.string ?? resumeJobId else { throw JarvisException("服务返回的内容无法读取") }
    onJob?(id)
    let deadline = Date().addingTimeInterval(30 * 60)
    var failures = 0
    var lastKey = ""
    var lastMove = Date()
    while running.contains(j["status"]?.string ?? "") {
      if !isCurrent(requestId, session) { throw JarvisException("任务跟踪已取消") }
      // Nothing new for much longer than any step takes: the job is probably stuck on the server. (A job waiting for its turn
      // may take as long as the ones before it, so that wait is only bounded by the deadline below.)
      let key = "\(j["progress"]?.double ?? 0)|\(j["phase"]?.string ?? "")"
      if key != lastKey || j["phase"]?.string == "queued" || j["status"]?.string == "queued" {
        lastKey = key
        lastMove = Date()
      } else if Date().timeIntervalSince(lastMove) > (quietLimit ?? MediaProgress.quietLimit(kind: kind, args: args)) {
        throw JarvisException(MediaProgress.quietMessage(Date().timeIntervalSince(lastMove)), stalled: true)
      }
      if Date() > deadline { throw JarvisException(kind == "image" ? "图片仍未完成，请稍后重新检查原任务" : "视频仍未完成，请稍后重新检查原任务") }
      onProgress?(report(j))
      try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
      if !isCurrent(requestId, session) { throw JarvisException("任务跟踪已取消") }
      do {
        j = try await json("GET", path(id), session: session)
        failures = 0
      } catch let e as JarvisException {
        // A dropped connection for a second (a phone moving between networks) does not end a job that is still running.
        failures += 1
        if e.unauthorized || failures > 5 { throw e }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failures += 1
        if failures > 5 { throw error }
      }
    }
    guard j["status"]?.string == "completed" else { throw JarvisException(failure) }
    if kind == "image" {
      let done = files(j)
      if done.isEmpty { throw JarvisException("任务没有返回作品地址") }
      return done
    }
    return ["/v1/videos/\(Self.pathEncode(id))/content"]
  }
}
