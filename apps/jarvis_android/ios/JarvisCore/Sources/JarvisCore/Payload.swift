import Foundation

/// What is sent to the model for a conversation: the system line, then every visible message with its pictures (as
/// data addresses) and the text of its files, and the tool calls with their results.
public enum Payload {
  public static let imageLimit = 18 * 1024 * 1024
  public static let textLimit = 200_000

  public static func messages(for c: Conversation, instructions: String, blobs: Vault) throws -> [[String: JSONValue]] {
    var out: [[String: JSONValue]] = [
      [
        "role": .string("system"),
        "content": .string(
          "你是贾维斯。用户用什么语言交流，就使用同一种语言回答。工具任务回执不是新用户输入，不要因此插话或切换语言。\(instructions.isEmpty ? "" : "\n\(instructions)")"),
      ]
    ]
    var imageBytes = 0
    var textChars = 0
    for m in c.messages where !m.hidden {
      if m.role == "user" {
        var parts: [JSONValue] = []
        if !m.text.isEmpty { parts.append(.object(["type": .string("text"), "text": .string(m.text)])) }
        for a in m.attachments {
          if a.kind == "image" {
            guard let bytes = (try? blobs.readBlob(a.id)) ?? nil else {
              // A lost file must not make the whole conversation unsendable.
              parts.append(.object(["type": .string("text"), "text": .string("[附件「\(a.name)」不可用]")]))
              continue
            }
            imageBytes += bytes.count
            if imageBytes > imageLimit { throw JarvisException("会话图片超过18MB，请新建话题") }
            parts.append(
              .object([
                "type": .string("image_url"),
                "image_url": .object(["url": .string("data:\(a.mime);base64,\(bytes.base64EncodedString())")]),
              ]))
          } else {
            let text = a.text ?? ""
            textChars += text.utf16.count
            if textChars > textLimit { throw JarvisException("会话附件文字过多，请拆分或新建话题") }
            parts.append(.object(["type": .string("text"), "text": .string("附件「\(a.name)」的内容：\n\(text)")]))
          }
        }
        out.append(["role": .string("user"), "content": m.attachments.isEmpty ? .string(m.text) : .array(parts)])
      } else if m.role == "assistant", !m.text.isEmpty || !m.calls.isEmpty {
        var message: [String: JSONValue] = ["role": .string("assistant"), "content": m.text.isEmpty ? .null : .string(m.text)]
        if !m.calls.isEmpty {
          message["tool_calls"] = .array(
            m.calls.compactMap { call in
              (try? JSONEncoder().encode(call)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            })
        }
        out.append(message)
        for call in m.calls {
          let task = c.tasks.first { $0.callId == call.id }
          let content =
            m.toolResults[call.id]
            ?? Persistence.encode(.object(task?.receipt ?? ["status": .string("cancelled")]))
          out.append(["role": .string("tool"), "tool_call_id": .string(call.id), "content": .string(content)])
        }
      }
    }
    return out
  }
}
