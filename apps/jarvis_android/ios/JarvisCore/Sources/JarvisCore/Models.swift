import Foundation

// The saved shapes below are the same JSON the Flutter app wrote (`lib/model/*.dart`): a conversation saved by one can be
// read by the other.

public struct Attachment: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var mime: String
  public var kind: String
  public var text: String?
  public var size: Int

  public init(id: String, name: String, mime: String, kind: String, text: String? = nil, size: Int = 0) {
    self.id = id; self.name = name; self.mime = mime; self.kind = kind; self.text = text; self.size = size
  }

  enum Keys: String, CodingKey { case id, name, mime, kind, text, size }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    mime = try c.decodeIfPresent(String.self, forKey: .mime) ?? "application/octet-stream"
    kind = try c.decode(String.self, forKey: .kind)
    text = try c.decodeIfPresent(String.self, forKey: .text)
    size = Self.int(try? c.decodeIfPresent(Double.self, forKey: .size))
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(mime, forKey: .mime)
    try c.encode(kind, forKey: .kind); try c.encode(text, forKey: .text); try c.encode(size, forKey: .size)
  }

  static func int(_ value: Double??) -> Int { (value ?? nil).flatMap(wholeNumber) ?? 0 }
}

/// A real [String] from server data: an entry that is not a string is dropped here, not when the UI reads it later.
func stringList(_ value: JSONValue?) -> [String] {
  value?.array?.compactMap { $0.string } ?? []
}

public struct MediaTask: Codable, Equatable, Sendable {
  public var id: String
  public var kind: String
  public var prompt: String
  public var args: [String: JSONValue]
  public var callId: String?
  public var jobId: String?
  public var status: String
  public var source: String
  public var urls: [String]
  public var error: String?
  public var progress: Double

  public init(
    id: String, kind: String, prompt: String, args: [String: JSONValue] = [:], callId: String? = nil, jobId: String? = nil,
    status: String = "queued", source: String = "http", urls: [String] = [], error: String? = nil, progress: Double = 0
  ) {
    self.id = id; self.kind = kind; self.prompt = prompt; self.args = args; self.callId = callId; self.jobId = jobId
    self.status = status; self.source = source; self.urls = urls; self.error = error; self.progress = progress
  }

  public static func isVideoURL(_ url: String) -> Bool {
    let path = (URL(string: url)?.path ?? url).lowercased()
    return path.contains("/videos/") || [".mp4", ".mov", ".m4v", ".webm"].contains { path.hasSuffix($0) }
  }

  /// Job events do not always say what was generated; the result address does.
  public mutating func settleKind(_ hint: Any? = nil) {
    if urls.contains(where: Self.isVideoURL) || "\(hint.map { "\($0)" } ?? "null")".lowercased().contains("video") {
      kind = "video"
    }
  }

  public var pending: Bool { status == "queued" || status == "in_progress" }

  /// What the model is told about a task that is not finished or is history.
  public var receipt: [String: JSONValue] {
    var r: [String: JSONValue] = [
      "status": .string(status), "source": .string(source), "kind": .string(kind), "task_id": .string(id),
      "urls": .array(urls.map { .string($0) }),
      "message": .string(pending ? "任务在后台处理，结果更新到原任务卡片；无需主动插话。" : "这是先前任务的结果，不是新的用户指令。"),
    ]
    if let jobId { r["job_id"] = .string(jobId) }
    if let error { r["error"] = .string(error) }
    return r
  }

  enum Keys: String, CodingKey { case id, kind, prompt, args, callId, jobId, status, source, urls, error, progress }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    id = try c.decode(String.self, forKey: .id)
    kind = try c.decode(String.self, forKey: .kind)
    prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    args = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .args)) ?? [:]
    callId = try c.decodeIfPresent(String.self, forKey: .callId)
    jobId = try c.decodeIfPresent(String.self, forKey: .jobId)
    source = try c.decodeIfPresent(String.self, forKey: .source) ?? "http"
    status = try c.decodeIfPresent(String.self, forKey: .status) ?? "failed"
    urls = stringList(try? c.decodeIfPresent(JSONValue.self, forKey: .urls))
    error = try c.decodeIfPresent(String.self, forKey: .error)
    progress = (try? c.decodeIfPresent(Double.self, forKey: .progress)) ?? 0
    settleKind()
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(prompt, forKey: .prompt)
    try c.encode(args, forKey: .args); try c.encode(callId, forKey: .callId); try c.encode(jobId, forKey: .jobId)
    try c.encode(status, forKey: .status); try c.encode(source, forKey: .source); try c.encode(urls, forKey: .urls)
    try c.encode(error, forKey: .error); try c.encode(progress, forKey: .progress)
  }
}

public struct ToolCall: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var arguments: String

  public init(id: String = "", name: String = "", arguments: String = "") {
    self.id = id; self.name = name; self.arguments = arguments
  }

  enum Keys: String, CodingKey { case id, type, function }
  enum FunctionKeys: String, CodingKey { case name, arguments }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
    if let f = try? c.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function) {
      name = try f.decodeIfPresent(String.self, forKey: .name) ?? ""
      arguments = try f.decodeIfPresent(String.self, forKey: .arguments) ?? "{}"
    } else {
      name = ""; arguments = "{}"
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(id, forKey: .id); try c.encode("function", forKey: .type)
    var f = c.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
    try f.encode(name, forKey: .name); try f.encode(arguments, forKey: .arguments)
  }
}

public struct ToolDelta: Equatable, Sendable {
  public var index: Int
  public var id: String
  public var name: String
  public var arguments: String
  public init(_ index: Int, _ id: String, _ name: String, _ arguments: String) {
    self.index = index; self.id = id; self.name = name; self.arguments = arguments
  }
}

public struct VoiceInfo: Equatable, Sendable {
  public var id: String
  public var name: String
  public var description: String
  public var preview: String?
  public init(_ id: String, _ name: String, _ description: String, preview: String? = nil) {
    self.id = id; self.name = name; self.description = description; self.preview = preview
  }
}

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
  nonisolated(unsafe) private static var serial = 0

  public let id: String
  public var attachments: [Attachment]
  public var calls: [ToolCall]
  public var toolResults: [String: String]
  public var taskId: String?
  public var role: String
  public var text: String
  public var reasoning: String
  public var status: String
  public var error: String?
  public var hidden: Bool

  public init(
    _ role: String, _ text: String, reasoning: String = "", status: String = "complete", error: String? = nil,
    hidden: Bool = false, taskId: String? = nil, id: String? = nil, attachments: [Attachment] = [], calls: [ToolCall] = [],
    toolResults: [String: String] = [:]
  ) {
    self.role = role; self.text = text; self.reasoning = reasoning; self.status = status; self.error = error
    self.hidden = hidden; self.taskId = taskId
    if let id { self.id = id } else {
      Self.serial += 1
      self.id = "\(Int(Date().timeIntervalSince1970 * 1_000_000))-\(Self.serial)"
    }
    self.attachments = attachments; self.calls = calls; self.toolResults = toolResults
  }

  enum Keys: String, CodingKey {
    case id, taskId, attachments, calls, toolResults, role, text, reasoning, status, error, hidden
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    role = try c.decode(String.self, forKey: .role)
    text = try c.decode(String.self, forKey: .text)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? {
      Self.serial += 1
      return "\(Int(Date().timeIntervalSince1970 * 1_000_000))-\(Self.serial)"
    }()
    toolResults = (try? c.decodeIfPresent([String: String].self, forKey: .toolResults)) ?? [:]
    hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
    attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    calls = try c.decodeIfPresent([ToolCall].self, forKey: .calls) ?? []
    reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
    error = try c.decodeIfPresent(String.self, forKey: .error)
    // A reply that was still running when the app went away is "interrupted", never "generating" again.
    let saved = try c.decodeIfPresent(String.self, forKey: .status)
    status = saved == "generating" ? "interrupted" : (saved ?? "complete")
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(id, forKey: .id); try c.encode(taskId, forKey: .taskId); try c.encode(attachments, forKey: .attachments)
    try c.encode(calls, forKey: .calls); try c.encode(toolResults, forKey: .toolResults); try c.encode(role, forKey: .role)
    try c.encode(text, forKey: .text); try c.encode(reasoning, forKey: .reasoning); try c.encode(status, forKey: .status)
    try c.encode(error, forKey: .error); try c.encode(hidden, forKey: .hidden)
  }
}

public struct Conversation: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public var named: Bool
  public var pendingAttachments: [Attachment]
  public var tasks: [MediaTask]
  public var title: String
  public var draft: String
  public var messages: [ChatMessage]

  public init(
    _ id: String, title: String = "新建会话", messages: [ChatMessage] = [], draft: String = "", named: Bool = false,
    attachments: [Attachment] = [], tasks: [MediaTask] = []
  ) {
    self.id = id; self.title = title; self.messages = messages; self.draft = draft; self.named = named
    self.pendingAttachments = attachments; self.tasks = tasks
  }

  enum Keys: String, CodingKey { case id, title, named, attachments, tasks, draft, messages }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    id = try c.decode(String.self, forKey: .id)
    named = try c.decodeIfPresent(Bool.self, forKey: .named) ?? false
    pendingAttachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    tasks = try c.decodeIfPresent([MediaTask].self, forKey: .tasks) ?? []
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? "新建会话"
    draft = try c.decodeIfPresent(String.self, forKey: .draft) ?? ""
    messages = try c.decode([ChatMessage].self, forKey: .messages)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(named, forKey: .named)
    try c.encode(pendingAttachments, forKey: .attachments); try c.encode(tasks, forKey: .tasks)
    try c.encode(draft, forKey: .draft); try c.encode(messages, forKey: .messages)
  }
}

public struct ModelInfo: Equatable, Sendable {
  public var id: String
  public var name: String
  public var kind: String
  public var voices: [VoiceInfo]
  public var defaultVoice: String
  /// What the server says about a speech engine's voices: `voices` is in the order to show, `defaultVoice` is the one to
  /// start with, and the revisions say when the list or the default was last changed there.
  public var voiceCatalogRevision: Int
  public var voiceDefaultRevision: Int
  public var metadata: [String: JSONValue]

  public init(
    _ id: String, _ name: String, kind: String = "chat", voices: [VoiceInfo] = [], defaultVoice: String = "",
    voiceCatalogRevision: Int = 0, voiceDefaultRevision: Int = 0, metadata: [String: JSONValue] = [:]
  ) {
    self.id = id; self.name = name; self.kind = kind; self.voices = voices; self.defaultVoice = defaultVoice
    self.voiceCatalogRevision = voiceCatalogRevision; self.voiceDefaultRevision = voiceDefaultRevision
    self.metadata = metadata
  }

  public var imageInput: Bool {
    JSONValue.object(metadata)["jarvis"]?["image_input"]?.bool == true
      || (JSONValue.object(metadata)["architecture"]?["input_modalities"]?.array ?? []).contains(.string("image"))
  }

  public var pdfInput: Bool { JSONValue.object(metadata)["jarvis"]?["pdf_text"]?.bool == true }

  public init?(json: JSONValue) {
    guard let id = json["id"]?.string else { return nil }
    let revision: (JSONValue?) -> Int = { value in
      if let n = value?.double, n >= 0 { return wholeNumber(n) ?? 0 } else { return 0 }
    }
    self.init(
      id, json["name"]?.string ?? id, kind: json["kind"]?.string ?? "chat",
      voices: (json["voices"]?.array ?? []).compactMap { v in
        if let s = v.string { return VoiceInfo(s, s, "") }
        guard let vid = v["id"]?.string else { return nil }
        return VoiceInfo(vid, v["name"]?.string ?? vid, v["description"]?.string ?? "", preview: v["preview_url"]?.string)
      },
      defaultVoice: json["default_voice"]?.string ?? "",
      voiceCatalogRevision: revision(json["voice_catalog_revision"]),
      voiceDefaultRevision: revision(json["voice_default_revision"]), metadata: json.object ?? [:])
  }
}

public struct ChatDelta: Equatable, Sendable {
  public var text: String
  public var reasoning: String
  public var finishReason: String?
  public var done: Bool
  public var toolDeltas: [ToolDelta]
  public init(
    text: String = "", reasoning: String = "", finishReason: String? = nil, done: Bool = false, toolDeltas: [ToolDelta] = []
  ) {
    self.text = text; self.reasoning = reasoning; self.finishReason = finishReason; self.done = done
    self.toolDeltas = toolDeltas
  }
}

public struct ChatOptions: Sendable {
  public var tools: [[String: JSONValue]]
  public var maxTokens: Int
  public init(tools: [[String: JSONValue]] = [], maxTokens: Int = 0) { self.tools = tools; self.maxTokens = maxTokens }
}
