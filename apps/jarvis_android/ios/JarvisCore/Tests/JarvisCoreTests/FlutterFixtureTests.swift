import XCTest

@testable import JarvisCore

/// The files the Flutter app really wrote (`test/swift_fixtures_test.dart` makes them), read and written back by the
/// Swift core: each side must take what the other saved, field for field.
final class FlutterFixtureTests: XCTestCase {
  static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

  func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.folder.appendingPathComponent(name)) }

  /// The first place two JSON trees differ, or nil.
  func difference(_ a: JSONValue, _ b: JSONValue, _ path: String = "") -> String? {
    switch (a, b) {
    case (.object(let x), .object(let y)):
      for k in Set(x.keys).union(y.keys).sorted() {
        guard let l = x[k] else { return "\(path)/\(k): missing on the left" }
        guard let r = y[k] else { return "\(path)/\(k): missing on the right" }
        if let d = difference(l, r, "\(path)/\(k)") { return d }
      }
      return nil
    case (.array(let x), .array(let y)):
      if x.count != y.count { return "\(path): \(x.count) vs \(y.count) items" }
      for i in x.indices { if let d = difference(x[i], y[i], "\(path)[\(i)]") { return d } }
      return nil
    default:
      return a == b ? nil : "\(path): \(a) vs \(b)"
    }
  }

  func decode(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

  func testWhatFlutterSavedLoadsAndSavesBackTheSame() throws {
    let text = String(decoding: try fixture("flutter_state.json"), as: UTF8.self)
    guard case .loaded(var state) = Persistence.load(MemoryVault(state: text), server: "https://jarvis.example.com") else {
      return XCTFail("not loaded")
    }
    XCTAssertEqual(state.conversations.map(\.id), ["c1", "c2"])
    XCTAssertEqual(state.selectedId, "c2")
    XCTAssertEqual(state.settings.voices, ["tts-1": "nova"])
    XCTAssertEqual(state.settings.instructions, "简短回答\n用中文 \"引号\" 😀")
    XCTAssertEqual(state.conversations[0].messages.count, 5)
    XCTAssertEqual(state.conversations[0].tasks.map(\.status), ["completed", "in_progress", "failed"])
    // Flutter turns a reply that was still going when the app stopped into an interrupted one; so does the core.
    XCTAssertEqual(state.conversations[0].messages[4].status, "interrupted")

    let written = StateWriter(vault: MemoryVault()).text(state)
    var expected = try decode(text)
    // The only changes loading makes to the file are that one status and the voice strength.
    guard case .object(var root) = expected, case .array(var convs) = root["conversations"],
      case .object(var first) = convs[0], case .array(var messages) = first["messages"],
      case .object(var last) = messages[4]
    else { return XCTFail("shape") }
    last["status"] = .string("interrupted")
    messages[4] = .object(last)
    first["messages"] = .array(messages)
    convs[0] = .object(first)
    root["conversations"] = .array(convs)
    // ...and the call's own thinking strength, which a file written before it had does not carry: it follows the server.
    guard case .object(var settings) = root["settings"] else { return XCTFail("settings") }
    settings["voiceEffort"] = .string("")
    root["settings"] = .object(settings)
    expected = .object(root)
    XCTAssertNil(difference(expected, try decode(written)))
    state.cookie = nil
  }

  func testAFlutterBackupReadsAndTheSwiftOneSaysTheSame() throws {
    let bytes = try fixture("flutter_backup.json")
    let backup = try Backup.read(bytes)
    XCTAssertEqual(backup.conversations.count, 2)
    let first = backup.conversations[0]
    XCTAssertEqual(first.title, "第一个 😀")
    XCTAssertEqual(first.messages.count, 5)
    // The attachment files came along under their new ids.
    let ids = Set(first.messages.flatMap(\.attachments).map(\.id))
    XCTAssertEqual(ids.count, 2)
    for id in ids { XCTAssertNotNil(backup.blobs[id]) }
    XCTAssertEqual(backup.blobs.values.map(\.count).sorted(), [12, 1000])

    // Export again and compare with what Flutter wrote: same conversations once the ids are mapped back.
    let vault = MemoryVault()
    for (id, data) in backup.blobs { try vault.writeBlob(id, data) }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let export = try Backup.export(backup.conversations, blobs: vault, appName: "JARVIS", temp: temp)
    XCTAssertEqual(export.files.count, 1)
    let again = try decode(String(decoding: try Data(contentsOf: export.files[0]), as: UTF8.self))
    let original = try decode(String(decoding: bytes, as: UTF8.self))
    XCTAssertEqual(again["version"], original["version"])
    XCTAssertEqual(again["conversations"]?.array?.count, 2)
    XCTAssertEqual(again["files"]?.array?.count, original["files"]?.array?.count)
    // Re-reading our own export gives back the same conversations.
    let reread = try Backup.read(try Data(contentsOf: export.files[0]))
    XCTAssertEqual(reread.conversations.map(\.title), backup.conversations.map(\.title))
    XCTAssertEqual(reread.conversations[0].messages.map(\.text), backup.conversations[0].messages.map(\.text))
    XCTAssertEqual(reread.blobs.values.map(\.count).sorted(), [12, 1000])
    export.dispose()
  }
}
