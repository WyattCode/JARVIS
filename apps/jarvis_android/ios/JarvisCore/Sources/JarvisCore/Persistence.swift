import Foundation

/// Everything the app keeps on the device, as the Flutter app's saved file shaped it (`version` 1).
public struct AppState: Equatable, Sendable {
  public var server: String
  public var model = ""
  public var settings = ChatSettings()
  public var cookie: String?
  public var selectedId: String?
  public var effort = "high"
  public var theme = "dark"
  /// After "start fresh" the preserved unreadable file still refers to attachments: nothing is collected from then on.
  public var gcHold = false
  public var conversations: [Conversation] = []

  public init(server: String) { self.server = server }
}

public enum LoadOutcome: Equatable, Sendable {
  /// Nothing saved yet.
  case empty
  case loaded(AppState)
  /// A file is there and cannot be read: saving would overwrite the only copy, so the caller stays read-only until the
  /// user starts fresh.
  case unreadable
}

public enum Persistence {
  static let defaultServer = "https://jarvis.example.com"

  /// Reads the saved file. Everything is parsed before anything is returned: a half-read file must never be saved back
  /// over the original.
  public static func load(_ vault: Vault, server: String) -> LoadOutcome {
    let raw: String?
    do { raw = try vault.readState() } catch { return .unreadable }
    guard let raw else { return .empty }
    guard let data = raw.data(using: .utf8), let saved = try? JSONDecoder().decode(JSONValue.self, from: data),
      saved["version"]?.int == 1, let list = saved["conversations"]?.array
    else { return .unreadable }
    var conversations: [Conversation] = []
    for entry in list {
      guard let c = try? JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(entry)) else { return .unreadable }
      conversations.append(c)
    }
    var state = AppState(server: server)
    let savedServer = saved["server"]?.string
    let sameServer = savedServer == server || (savedServer == nil && server == defaultServer)
    state.cookie = sameServer ? saved["cookie"]?.string : nil
    state.settings.restore(saved["settings"] ?? .object([:]))
    if !sameServer { state.settings.apiKey = "" }
    state.model = saved["model"]?.string ?? ""
    state.gcHold = saved["gcHold"]?.bool == true
    state.conversations = conversations
    state.selectedId = saved["selectedId"]?.string
    let effort = saved["effort"]?.string
    state.effort = ["none", "low", "medium", "high"].contains(effort ?? "") ? effort! : "high"
    let theme = saved["theme"]?.string
    state.theme = ["system", "light", "dark"].contains(theme ?? "") ? theme! : "dark"
    // The old implicit system default is moved to dark once; a system choice made since is kept by the version below.
    if state.theme == "system", saved["themePreferenceVersion"] == nil || saved["themePreferenceVersion"] == .null {
      state.theme = "dark"
    }
    return .loaded(state)
  }

  /// Everything but the conversations; small, and it also catches changes made behind the store's back (the cookie).
  public static func head(_ state: AppState) -> String {
    var object: [String: JSONValue] = [
      "version": .number(1), "server": .string(state.server), "model": .string(state.model),
      "settings": .object(state.settings.json()), "cookie": state.cookie.map { .string($0) } ?? .null,
      "selectedId": state.selectedId.map { .string($0) } ?? .null, "effort": .string(state.effort),
      "theme": .string(state.theme), "themePreferenceVersion": .number(1),
    ]
    if state.gcHold { object["gcHold"] = .bool(true) }
    return encode(.object(object))
  }

  static func encode(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(value)) ?? Data("null".utf8), as: UTF8.self)
  }

  static func encode(_ conversation: Conversation) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(conversation)) ?? Data("{}".utf8), as: UTF8.self)
  }
}

/// Writes the state, re-encoding only what changed. A draft is typed into all the time; encoding every conversation for
/// each keystroke's save would be most of the work of the whole app.
public final class StateWriter: @unchecked Sendable {
  private let vault: Vault
  private let lock = NSLock()
  private var encoded: [String: String] = [:]

  public init(vault: Vault) { self.vault = vault }

  /// The file's text: the head with the conversations' JSON inside it. A `cheap` save reuses the last encoding of every
  /// conversation not named in `draftDirty`.
  public func text(_ state: AppState, cheap: Bool = false, draftDirty: Set<String> = []) -> String {
    lock.lock(); defer { lock.unlock() }
    var fresh: [String: String] = [:]
    var order: [String] = []
    for c in state.conversations {
      let reuse = cheap && !draftDirty.contains(c.id) ? encoded[c.id] : nil
      fresh[c.id] = reuse ?? Persistence.encode(c)
      order.append(c.id)
    }
    encoded = fresh
    let head = Persistence.head(state)
    return "\(head.dropLast()),\"conversations\":[\(order.map { fresh[$0]! }.joined(separator: ","))]}"
  }

  public func write(_ state: AppState, cheap: Bool = false, draftDirty: Set<String> = []) throws {
    try vault.writeState(text(state, cheap: cheap, draftDirty: draftDirty))
  }
}

/// Attachment files nothing refers to any more: left by a crash, an earlier version, or a deleted conversation.
public func orphanedBlobs(stored: [String], conversations: [Conversation], held: Set<String> = []) -> [String] {
  var keep = held
  for c in conversations {
    for a in c.pendingAttachments { keep.insert(a.id) }
    for m in c.messages { for a in m.attachments { keep.insert(a.id) } }
  }
  return stored.filter { !keep.contains($0) }
}
