import Foundation

/// What the store needs from the service. `JarvisAPI` is the real one; tests bring a fake.
public protocol Transport: AnyObject, Sendable {
  var apiKey: String { get set }
  var cookie: String? { get set }
  var endpoint: URL { get }

  func login(_ username: String, _ password: String) async throws
  func logout() async throws
  func models() async throws -> [ModelInfo]
  func modelSkill() async throws -> [String: JSONValue]
  /// What the service says about its models (`GET /v1/tools`).
  func toolsStatus() async throws -> [String: JSONValue]
  func modelTool(requestId: String, name: String, args: [String: JSONValue]) async throws -> String
  func chat(requestId: String, model: String, effort: String, messages: [[String: JSONValue]], options: ChatOptions)
    -> AsyncThrowingStream<ChatDelta, Error>
  func cancel(_ requestId: String)
  func generate(
    requestId: String, kind: String, args: [String: JSONValue], resumeJobId: String?, onJob: ((String) -> Void)?,
    onProgress: ((MediaReport) -> Void)?
  ) async throws -> [String]
  func jobStatus(_ id: String) async throws -> [String: JSONValue]
  func mediaURL(_ path: String) throws -> URL
  /// A file of this server (a generated picture, an uploaded file) by its address.
  func download(_ path: String) async throws -> Data
  /// The same into [file] (written as it comes, never held in memory); the byte count.
  func download(_ path: String, to file: URL) async throws -> Int
  func openRealtime() async throws -> RealtimeWire
  func preview(_ voice: VoiceInfo, model: String) async throws -> Data
  func synthesize(_ voice: VoiceInfo, model: String) async throws -> Data
  func close()
}

extension JarvisAPI: Transport {}
