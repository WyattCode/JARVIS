import Foundation

/// A server in memory: every request goes to `StubProtocol.handler`, which says what comes back.
final class StubProtocol: URLProtocol {
  struct Reply {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    /// Seconds before the answer starts.
    var delay: Double = 0
    /// Seconds between chunks.
    var gap: Double = 0
    /// Ends the stream with an error instead of finishing it.
    var failure: URLError?
  }

  nonisolated(unsafe) static var handler: ((URLRequest, Data) -> Reply)?
  nonisolated(unsafe) static var seen: [(request: URLRequest, body: Data)] = []
  private var stopped = false

  static func reset() { handler = nil; seen = [] }

  static var configuration: URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubProtocol.self]
    return c
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var body = Data()
    if let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        body.append(contentsOf: buffer[0..<n])
      }
      stream.close()
    } else if let b = request.httpBody {
      body = b
    }
    StubProtocol.seen.append((request, body))
    let reply = StubProtocol.handler?(request, body) ?? Reply(status: 404)
    DispatchQueue.global().async { [self] in
      Thread.sleep(forTimeInterval: reply.delay)
      guard !stopped else { return }
      let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      for chunk in reply.chunks {
        guard !stopped else { return }
        client?.urlProtocol(self, didLoad: chunk)
        if reply.gap > 0 { Thread.sleep(forTimeInterval: reply.gap) }
      }
      guard !stopped else { return }
      if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: failure) } else { client?.urlProtocolDidFinishLoading(self) }
    }
  }

  override func stopLoading() { stopped = true }
}
