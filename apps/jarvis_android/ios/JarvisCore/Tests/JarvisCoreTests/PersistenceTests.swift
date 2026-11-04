import XCTest

@testable import JarvisCore

final class PersistenceTests: XCTestCase {
  let server = "https://jarvis.test"

  /// A file as the Flutter app wrote it.
  func flutterFile(server: String? = "https://jarvis.test", theme: String = "light", themeVersion: Bool = true) -> String {
    let serverPart = server.map { "\"server\":\"\($0)\"," } ?? ""
    return """
      {"version":1,\(serverPart)"model":"chat-a","settings":{"tools":false,"apiKey":"sk-1","maxTokens":4096,"voices":{"tts":"b"},"voiceMode":"vad"},
       "cookie":"__Host-jarvis_session=abc","selectedId":"c2","effort":"medium","theme":"\(theme)"\(themeVersion ? ",\"themePreferenceVersion\":1" : ""),
       "conversations":[{"id":"c1","title":"一","messages":[]},{"id":"c2","title":"二","draft":"d","messages":[{"role":"user","text":"hi"}]}]}
      """
  }

  func testNothingSavedIsEmpty() {
    XCTAssertEqual(Persistence.load(MemoryVault(), server: server), .empty)
  }

  func testLoadsWhatFlutterSaved() {
    guard case .loaded(let s) = Persistence.load(MemoryVault(state: flutterFile()), server: server) else { return XCTFail() }
    XCTAssertEqual(s.model, "chat-a")
    XCTAssertEqual(s.cookie, "__Host-jarvis_session=abc")
    XCTAssertEqual(s.settings.apiKey, "sk-1")
    XCTAssertFalse(s.settings.tools)
    XCTAssertEqual(s.settings.maxTokens, 4096)
    XCTAssertEqual(s.settings.voices, ["tts": "b"])
    XCTAssertEqual(s.settings.voiceMode, "vad")
    XCTAssertEqual(s.selectedId, "c2")
    XCTAssertEqual(s.effort, "medium")
    XCTAssertEqual(s.theme, "light")
    XCTAssertEqual(s.conversations.map(\.id), ["c1", "c2"])
    XCTAssertEqual(s.conversations[1].draft, "d")
  }

  func testAnotherServersCookieAndKeyAreNotKept() {
    guard case .loaded(let s) = Persistence.load(MemoryVault(state: flutterFile()), server: "https://other.test") else { return XCTFail() }
    XCTAssertNil(s.cookie)
    XCTAssertEqual(s.settings.apiKey, "")
  }

  func testAFileFromBeforeTheServerWasSavedBelongsToTheDefaultOne() {
    guard case .loaded(let a) = Persistence.load(MemoryVault(state: flutterFile(server: nil)), server: "https://jarvis.example.com") else { return XCTFail() }
    XCTAssertNotNil(a.cookie)
    guard case .loaded(let b) = Persistence.load(MemoryVault(state: flutterFile(server: nil)), server: server) else { return XCTFail() }
    XCTAssertNil(b.cookie)
  }

  func testTheOldImplicitSystemThemeBecomesDarkOnce() {
    guard case .loaded(let old) = Persistence.load(MemoryVault(state: flutterFile(theme: "system", themeVersion: false)), server: server) else { return XCTFail() }
    XCTAssertEqual(old.theme, "dark")
    guard case .loaded(let chosen) = Persistence.load(MemoryVault(state: flutterFile(theme: "system")), server: server) else { return XCTFail() }
    XCTAssertEqual(chosen.theme, "system")
    guard case .loaded(let junk) = Persistence.load(MemoryVault(state: flutterFile(theme: "blue")), server: server) else { return XCTFail() }
    XCTAssertEqual(junk.theme, "dark")
  }

  func testAFileItCannotReadStaysUnreadableAndIsNotHalfApplied() {
    for bad in ["not json", #"{"version":2,"conversations":[]}"#, #"{"version":1}"#, #"{"version":1,"conversations":[{"title":"no id","messages":[]}]}"#] {
      XCTAssertEqual(Persistence.load(MemoryVault(state: bad), server: server), .unreadable, bad)
    }
    struct Broken: Vault {
      func readState() throws -> String? { throw VaultError.corrupt }
      func writeState(_ value: String) throws {}
      func readBlob(_ id: String) throws -> Data? { nil }
      func writeBlob(_ id: String, _ bytes: Data) throws {}
      func deleteBlob(_ id: String) throws {}
      func listBlobs() throws -> [String] { [] }
      func keepUnreadable() throws {}
      func wipeEvidence() throws {}
      func eraseState() throws {}
    }
    XCTAssertEqual(Persistence.load(Broken(), server: server), .unreadable)
  }

  func testWhatIsWrittenIsReadBackAndKeepsTheFlutterShape() throws {
    var state = AppState(server: server)
    state.model = "m"
    state.cookie = "c=1"
    state.selectedId = "c1"
    state.gcHold = true
    state.conversations = [Conversation("c1", title: "标题 /x", messages: [ChatMessage("user", "你好", id: "m1")])]
    let vault = MemoryVault()
    let writer = StateWriter(vault: vault)
    try writer.write(state)
    let text = try vault.readState()!
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    XCTAssertEqual(
      Set(object.keys),
      ["version", "server", "model", "settings", "cookie", "selectedId", "effort", "theme", "themePreferenceVersion", "gcHold", "conversations"])
    XCTAssertEqual(object["version"] as? Int, 1)
    XCTAssertTrue(text.contains("标题 /x"), "slashes are not escaped")
    guard case .loaded(let back) = Persistence.load(vault, server: server) else { return XCTFail() }
    XCTAssertEqual(back.conversations, state.conversations)
    XCTAssertEqual(back.cookie, "c=1")
    XCTAssertTrue(back.gcHold)
    XCTAssertEqual(back.theme, "dark")
    state.gcHold = false
    XCTAssertFalse(Persistence.head(state).contains("gcHold"))
  }

  func testACheapSaveReusesWhatItEncodedBeforeExceptTheDraftsThatChanged() throws {
    var state = AppState(server: server)
    state.conversations = [Conversation("a", draft: "1"), Conversation("b", draft: "1")]
    let writer = StateWriter(vault: MemoryVault())
    _ = writer.text(state)
    state.conversations[0].draft = "2"
    state.conversations[1].draft = "2"
    let cheap = writer.text(state, cheap: true, draftDirty: ["a"])
    XCTAssertTrue(cheap.contains("\"draft\":\"2\""))
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(cheap.utf8))
    let drafts = decoded["conversations"]!.array!.map { $0["draft"]!.string! }
    XCTAssertEqual(drafts, ["2", "1"], "b was not named, so its last encoding is reused")
  }

  func testOrphanedAttachmentsAreOnlyThoseNothingRefersTo() {
    let keepA = Attachment(id: "a", name: "", mime: "", kind: "image")
    let keepB = Attachment(id: "b", name: "", mime: "", kind: "image")
    let conversations = [
      Conversation("c", messages: [ChatMessage("user", "x", attachments: [keepA])], attachments: [keepB])
    ]
    XCTAssertEqual(Set(orphanedBlobs(stored: ["a", "b", "c", "d"], conversations: conversations, held: ["d"])), ["c"])
  }
}
