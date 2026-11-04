import Foundation

/// One row of the chat's message list, as the native list reads it: its id, a revision that changes whenever the JSON
/// would (a row that has not changed is not encoded again) and the JSON itself.
public struct MessageRow: Equatable, Sendable {
  public let id: String
  public let revision: Int
  public let json: JSONValue
}

/// What the message list shows for a conversation: the Swift port of the Flutter app's `nativeRows`, so the native list
/// is fed the same rows from the Swift store.
public enum MessageRows {
  /// The last visible reply is the one that offers "regenerate".
  public static func lastReply(_ c: Conversation) -> String? {
    // An empty reply (stopped before its first word) is not shown, so it cannot be the one that offers "regenerate".
    c.messages.last {
      $0.role == "assistant" && !$0.hidden
        && !($0.text.isEmpty && $0.reasoning.isEmpty && $0.attachments.isEmpty && $0.calls.isEmpty && $0.taskId == nil && $0.error == nil
          && $0.status != "generating")
    }?.id
  }

  public static func rows(
    _ c: Conversation, generating: Bool, canContinue: Bool = true, canCancelTask: Bool = true
  ) -> [MessageRow] {
    let last = lastReply(c)
    var rows: [MessageRow] = []
    for m in c.messages {
      if m.hidden { continue }
      let task = m.taskId.flatMap { id in c.tasks.first { $0.id == id } }
      if m.taskId != nil && task == nil { continue }
      let tool = task == nil && m.role == "assistant" && m.text.isEmpty && !m.calls.isEmpty && m.error == nil
      if tool && !generating { continue }
      // A turn with nothing in it shows nothing: a spoken message whose words have not come yet is an empty bubble, and a reply
      // that was cut off before its first word is a row of buttons for nothing.
      let empty = task == nil && !tool && m.text.isEmpty && m.reasoning.isEmpty && m.attachments.isEmpty && m.calls.isEmpty
      if empty && m.error == nil && (m.role == "user" || m.status != "generating") { continue }

      var hasher = Hasher()
      hasher.combine(m.text.utf16.count)
      hasher.combine(m.reasoning.utf16.count)
      hasher.combine(m.status)
      hasher.combine(m.error)
      hasher.combine(m.attachments.count)
      hasher.combine(m.calls.count)
      hasher.combine(last == m.id)
      hasher.combine(generating)
      hasher.combine(canContinue)
      if let task {
        hasher.combine(task.status)
        hasher.combine(task.progress)
        hasher.combine(task.urls.count)
        hasher.combine(task.error)
        hasher.combine(task.kind)
        hasher.combine(canCancelTask)
      }
      // A same-length edit (rare) still shows once something else changes.
      hasher.combine(m.text.utf16.last ?? 0)

      var object: [String: JSONValue] = [
        "id": .string(m.id),
        "kind": .string(task != nil ? "task" : tool ? "tool" : (m.role == "user" ? "user" : "assistant")),
        "text": .string(m.text),
        "reasoning": .string(m.reasoning),
        "status": .string(m.status),
        "error": m.error.map { .string($0) } ?? .null,
        "attachments": .array(
          m.attachments.map { .object(["id": .string($0.id), "name": .string($0.name), "kind": .string($0.kind)]) }),
        "lastReply": .bool(last == m.id),
        "canContinue": .bool(canContinue),
        "generating": .bool(generating),
        "label": .string("正在调用工具…"),
      ]
      if let task {
        object["task"] = .object([
          "id": .string(task.id),
          "kind": .string(task.kind),
          "prompt": .string(task.prompt),
          "status": .string(task.status),
          "progress": .number(task.progress),
          "urls": .array(task.urls.map { .string($0) }),
          "error": task.error.map { .string($0) } ?? .null,
          "pending": .bool(task.pending),
          "canCancel": .bool(canCancelTask),
        ])
      }
      rows.append(MessageRow(id: m.id, revision: hasher.finalize(), json: .object(object)))
    }
    return rows
  }
}
