import Foundation

/// Server-sent events: the `data:` of every event, joined by newlines when it spans lines. Handles UTF-8 split across
/// chunks, CRLF, comment lines and a last record with no blank line after it (callers still require `[DONE]` to tell a
/// complete answer from a broken stream).
public struct SSEParser {
  private var data: [String] = []
  private var pending = Data()

  public init() {}

  /// Feeds bytes; returns the events they complete.
  public mutating func feed(_ bytes: Data) -> [String] {
    pending.append(bytes)
    var events: [String] = []
    while let newline = pending.firstIndex(of: 0x0A) {
      var line = pending[pending.startIndex..<newline]
      pending = Data(pending[pending.index(after: newline)...])
      if line.last == 0x0D { line = line.dropLast() }
      if let event = consume(String(decoding: line, as: UTF8.self)) { events.append(event) }
    }
    return events
  }

  /// The end of the stream: a record still open is returned too.
  public mutating func finish() -> [String] {
    var events: [String] = []
    if !pending.isEmpty {
      var line = pending
      if line.last == 0x0D { line = line.dropLast() }
      pending = Data()
      if let event = consume(String(decoding: line, as: UTF8.self)) { events.append(event) }
    }
    if !data.isEmpty {
      events.append(data.joined(separator: "\n"))
      data = []
    }
    return events
  }

  private mutating func consume(_ line: String) -> String? {
    if line.isEmpty {
      guard !data.isEmpty else { return nil }
      defer { data = [] }
      return data.joined(separator: "\n")
    }
    if line.hasPrefix(":") { return nil }
    let field: Substring
    var value: Substring = ""
    if let colon = line.firstIndex(of: ":") {
      field = line[line.startIndex..<colon]
      value = line[line.index(after: colon)...]
    } else {
      field = line[...]
    }
    guard field == "data" else { return nil }
    if value.hasPrefix(" ") { value = value.dropFirst() }
    data.append(String(value))
    return nil
  }
}
