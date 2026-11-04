import Foundation

/// The sizes export and import agree on. A backup file never exceeds `importBytes`, so every file export produces is one
/// import accepts. Export aims for `partBytes`, well below it: import holds the text, the parsed document and the decoded
/// files at once, a few times the file size.
public struct BackupLimits: Sendable {
  public var importBytes = 128 * 1024 * 1024
  public var partBytes = 64 * 1024 * 1024
  public static let attachmentBytes = 20 * 1024 * 1024
  public init() {}
}

/// What `Backup.export` wrote: `files` are numbered parts (one when everything fits), each a complete backup of whole
/// conversations that imports on its own. Delete `folder` when done.
public struct BackupExport {
  public let folder: URL
  public let files: [URL]
  /// Attachments that could not be read and were left out.
  public let skipped: [String]

  public func dispose() { try? FileManager.default.removeItem(at: folder) }
}

public struct ImportedBackup {
  public var conversations: [Conversation]
  /// The decoded attachment files by their new ids.
  public var blobs: [String: Data]
}

private struct TooLarge: Error {}

private final class PartWriter {
  let handle: FileHandle
  let limit: Int
  var written = 0
  var pending = Data()

  init(handle: FileHandle, limit: Int) {
    self.handle = handle
    self.limit = limit
  }

  func add(_ text: String) throws { try add(Data(text.utf8)) }

  func add(_ data: Data) throws {
    written += data.count
    if written > limit { throw TooLarge() }
    pending.append(data)
    if pending.count > 1024 * 1024 { try flush() }
  }

  func flush() throws {
    guard !pending.isEmpty else { return }
    try handle.write(contentsOf: pending)
    pending.removeAll(keepingCapacity: true)
  }
}

public enum Backup {
  /// Writes the backup to files under `temp`, streaming: only one attachment is in memory at a time. Conversations are
  /// grouped into parts of about `limits.partBytes`; a conversation is never split. A single conversation too big for any
  /// file to import makes this throw, naming it, so nothing unimportable is produced.
  public static func export(
    _ conversations: [Conversation], blobs: Vault, appName: String, temp: URL, limits: BackupLimits = BackupLimits(),
    now: Date = Date()
  ) throws -> BackupExport {
    let encoded = conversations.map { Persistence.encode($0) }
    var perConversation: [[String]] = []
    var sizes: [String: Int] = [:]
    var mimes: [String: String] = [:]
    for c in conversations {
      var ids: [String] = []
      for a in c.pendingAttachments + c.messages.flatMap(\.attachments) {
        if mimes[a.id] == nil {
          mimes[a.id] = a.mime
          sizes[a.id] = a.size
        }
        if !ids.contains(a.id) { ids.append(a.id) }
      }
      perConversation.append(ids)
    }
    // A recorded size of 0 is an old record: measure it rather than trust it.
    for id in sizes.keys where sizes[id] == 0 { sizes[id] = ((try? blobs.readBlob(id)) ?? nil)?.count ?? 0 }
    func cost(_ i: Int, _ ids: [String]) -> Int {
      encoded[i].utf8.count + ids.reduce(0) { $0 + (sizes[$1]! + 2) / 3 * 4 + 200 + mimes[$1]!.utf8.count }
    }
    var groups: [[Int]] = []
    var used = 0
    for i in conversations.indices {
      let own = cost(i, perConversation[i])
      if groups.isEmpty || used + own > limits.partBytes {
        groups.append([])
        used = 0
      }
      groups[groups.count - 1].append(i)
      used += own
    }
    if groups.isEmpty { groups.append([]) }

    let stamp = Int(now.timeIntervalSince1970 * 1000)
    let folder = temp.appendingPathComponent("jarvis-backup", isDirectory: true).appendingPathComponent("\(stamp)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var files: [URL] = []
    var skipped: [String] = []
    do {
      for (part, group) in groups.enumerated() {
        let name =
          groups.count == 1
          ? "jarvis-conversations-\(stamp).json" : "jarvis-conversations-\(stamp)-\(part + 1)of\(groups.count).json"
        let file = folder.appendingPathComponent(name)
        var ids: [String] = []
        for i in group { for id in perConversation[i] where !ids.contains(id) { ids.append(id) } }
        do {
          skipped += try writePart(
            file, group.map { encoded[$0] }, ids, mimes, blobs: blobs, appName: appName, now: now, part: part + 1,
            parts: groups.count, limit: limits.importBytes)
        } catch is TooLarge {
          // A part is whole conversations: one that alone is over the limit cannot be split, so say which it is.
          if group.count != 1 { throw JarvisException("备份文件超过导入上限，请删除部分带附件的会话后再导出") }
          let title = conversations[group[0]].title
          throw JarvisException("会话「\(title.isEmpty ? "未命名" : title)」的附件太大，无法放进一个备份文件；请先删除其中一部分图片或文件，或删除这个会话后再导出")
        }
        files.append(file)
      }
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
    return BackupExport(folder: folder, files: files, skipped: skipped)
  }

  private static func writePart(
    _ file: URL, _ conversationsJSON: [String], _ ids: [String], _ mimes: [String: String], blobs: Vault, appName: String,
    now: Date, part: Int, parts: Int, limit: Int
  ) throws -> [String] {
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    let out = PartWriter(handle: handle, limit: limit)
    var skipped: [String] = []
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func quoted(_ s: String) -> String { Persistence.encode(.string(s)) }
    // Deliberately exclude account cookies, API keys and other authentication material.
    try out.add(
      "{\"version\":3,\"app\":\(quoted(appName)),\"exported_at\":\(quoted(stamp.string(from: now))),\"part\":\(part),\"parts\":\(parts),\"conversations\":[\(conversationsJSON.joined(separator: ","))],\"files\":["
    )
    var first = true
    for id in ids {
      guard let bytes = (try? blobs.readBlob(id)) ?? nil else {
        // One lost file must not make the whole backup impossible; the caller can tell the user.
        skipped.append(id)
        continue
      }
      try out.add("\(first ? "" : ",")" + "{\"id\":\(quoted(id)),\"data\":\"data:\(mimes[id] ?? "application/octet-stream");base64,")
      first = false
      // Multiples of 3 bytes encode to base64 without padding, so the chunks join into one valid string.
      let chunk = 48 * 1024
      var i = 0
      while i < bytes.count {
        let end = min(i + chunk, bytes.count)
        try out.add(bytes[i..<end].base64EncodedString())
        i = end
      }
      try out.add("\"}")
    }
    try out.add("]\(skipped.isEmpty ? "" : ",\"missing_files\":\(Persistence.encode(.array(skipped.map { .string($0) })))")}")
    try out.flush()
    return skipped
  }

  // MARK: Import

  /// Reads a backup. Nothing is changed here: the caller stores the files and installs the conversations once the whole
  /// document has been read, so a bad file leaves what is there as it was. `mediaAllowed` says whether an old backup's
  /// picture address may be kept.
  public static func read(
    _ input: Data, limits: BackupLimits = BackupLimits(), now: Date = Date(), mediaAllowed: (String) -> Bool = { _ in true }
  ) throws -> ImportedBackup {
    if input.count > limits.importBytes { throw JarvisException("备份过大") }
    guard let root = try? JSONDecoder().decode(JSONValue.self, from: input), root.object != nil else {
      throw JarvisException("不是支持的贾维斯备份")
    }
    guard let version = root["version"]?.int, [2, 3].contains(version) else { throw JarvisException("不是支持的贾维斯备份") }
    guard let raw = root["conversations"]?.array, raw.count <= 10000 else { throw JarvisException("备份会话格式无效") }
    let prefix = "import_\(Int(now.timeIntervalSince1970 * 1_000_000))_"
    var remap: [String: String] = [:]
    func id(_ old: String) -> String {
      if let known = remap[old] { return known }
      let fresh = "\(prefix)\(remap.count)"
      remap[old] = fresh
      return fresh
    }
    var textById: [String: String] = [:]
    var mimeById: [String: String] = [:]
    var data: [String: Data] = [:]
    for f in root["files"]?.array ?? [] {
      guard let oldId = f["id"]?.string, let url = f["data"]?.string else { throw JarvisException("附件备份格式无效") }
      guard let comma = url.firstIndex(of: ","), url.hasPrefix("data:"), url[..<comma].hasSuffix(";base64") else {
        throw JarvisException("附件编码无效")
      }
      guard let bytes = Data(base64Encoded: String(url[url.index(after: comma)...])) else { throw JarvisException("附件编码无效") }
      if bytes.count > BackupLimits.attachmentBytes { throw JarvisException("备份中的单个附件过大") }
      let key = id(oldId)
      data[key] = bytes
      if let text = f["text"]?.string { textById[key] = text }
      mimeById[key] = String(url[url.index(url.startIndex, offsetBy: 5)..<url.index(comma, offsetBy: -7)])
    }
    func attachment(_ a: JSONValue) throws -> Attachment {
      let key = id(a["id"]?.string ?? "")
      guard let bytes = data[key] else { throw JarvisException("备份缺少附件数据") }
      return Attachment(
        id: key, name: a["name"]?.string ?? "附件", mime: mimeById[key] ?? "application/octet-stream",
        kind: a["kind"]?.string ?? "document", text: a["text"]?.string ?? textById[key], size: bytes.count)
    }
    // Files the exporting device could not read were left out on purpose; their messages keep a placeholder.
    let missing = Set((root["missing_files"]?.array ?? []).compactMap { $0.string })
    var imported: [Conversation] = []
    var usedKeys = Set<String>()
    for (index, original) in raw.enumerated() {
      guard var object = original.object else { throw JarvisException("备份会话格式无效") }
      // A conversation without an id, or one that repeats another's, would be given the same new id and overwrite it.
      var key = object["id"]?.string ?? ""
      if key.isEmpty || usedKeys.contains(key) { key += "#\(index)" }
      usedKeys.insert(key)
      object["id"] = .string(key)
      let j = JSONValue.object(object)
      if j["messages"] != nil {
        // Rewrite only owned blob/conversation identities, preserving message references and task records.
        var copy = j.object!
        copy["id"] = .string(id("conversation_\(j["id"]?.string ?? "")"))
        func rewrite(_ list: JSONValue?) throws -> JSONValue? {
          guard let items = list?.array else { return list }
          return .array(
            try items.map { item in
              guard var a = item.object else { return item }
              let old = a["id"]?.string ?? ""
              let new = id(old)
              a["id"] = .string(new)
              if data[new] == nil, !missing.contains(old) { throw JarvisException("备份缺少附件") }
              return .object(a)
            })
        }
        copy["attachments"] = try rewrite(copy["attachments"])
        copy["messages"] = .array(
          try (copy["messages"]?.array ?? []).map { m in
            guard var message = m.object else { return m }
            message["attachments"] = try rewrite(message["attachments"])
            return .object(message)
          })
        guard var c = try? JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(JSONValue.object(copy))) else {
          throw JarvisException("备份会话格式无效")
        }
        for i in c.tasks.indices where c.tasks[i].pending {
          c.tasks[i].status = "interrupted"
          c.tasks[i].error = "导入的任务不会自动重发，请检查原任务"
        }
        imported.append(c)
      } else {
        imported.append(try legacy(j, id: id, attachment: attachment, mediaAllowed: mediaAllowed))
      }
    }
    return ImportedBackup(conversations: imported, blobs: data)
  }

  /// A backup from the first version of the app (`msgs` instead of `messages`).
  private static func legacy(
    _ j: JSONValue, id: (String) -> String, attachment: (JSONValue) throws -> Attachment, mediaAllowed: (String) -> Bool
  ) throws -> Conversation {
    var c = Conversation(
      id("conversation_\(j["id"]?.string ?? "")"), title: j["title"]?.string ?? "导入的会话", draft: j["draft"]?.string ?? "",
      named: j["named"]?.bool ?? false)
    for a in j["pendingAttachments"]?.array ?? [] where a["loading"]?.bool != true {
      c.pendingAttachments.append(try attachment(a))
    }
    for (position, m) in (j["msgs"]?.array ?? []).enumerated() {
      if m["gone"]?.bool == true || m["partial"]?.bool == true { continue }
      let role = m["role"]?.string
      if role == "tool" {
        let kind = m["kind"]?.string == "video" ? "video" : "image"
        let media = m["media"]?.array ?? []
        let args = m["args"]?.object ?? [:]
        let prompt = args["prompt"]?.string ?? m["text"]?.string ?? ""
        // (a tool message without an id is told from the others by its place)
        let taskId = id("task_\(m["id"]?.string ?? "\(j["id"]?.string ?? "")@\(position)")")
        let task = MediaTask(
          id: taskId, kind: kind, prompt: prompt, args: args, callId: m["callId"]?.string, jobId: m["jobId"]?.string,
          status: media.isEmpty ? "interrupted" : "completed",
          urls: media.compactMap { $0["url"]?.string }.filter(mediaAllowed),
          error: media.isEmpty ? "导入的任务不会自动重发，请检查原任务" : nil)
        c.tasks.append(task)
        c.messages.append(ChatMessage("tool", task.prompt, taskId: task.id))
        continue
      }
      let normalized = ["user", "assistant"].contains(role ?? "") ? role! : "system"
      c.messages.append(
        ChatMessage(
          normalized, m["text"]?.string ?? "", reasoning: m["reasoning"]?.string ?? "",
          status: m["streaming"]?.bool == true || m["interrupted"]?.bool == true ? "interrupted" : "complete",
          attachments: try (m["attachments"]?.array ?? []).map(attachment),
          calls: (m["calls"]?.array ?? []).compactMap {
            try? JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode($0))
          }))
    }
    return c
  }
}
