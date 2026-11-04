import XCTest

@testable import JarvisCore

final class BackupTests: XCTestCase {
  var temp: URL!

  override func setUp() {
    temp = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-backup-test-\(UUID().uuidString)")
  }

  override func tearDown() { try? FileManager.default.removeItem(at: temp) }

  func conversation(_ id: String, title: String, attachments: [Attachment] = []) -> Conversation {
    Conversation(id, title: title, messages: [ChatMessage("user", "你好", id: "m-\(id)", attachments: attachments)])
  }

  func testAnExportImportsBackWithItsFiles() throws {
    let blobs = MemoryVault()
    let png = Data((0..<5000).map { UInt8($0 % 251) })
    try blobs.writeBlob("a1", png)
    let c = conversation("c1", title: "带图", attachments: [Attachment(id: "a1", name: "x.png", mime: "image/png", kind: "image", size: png.count)])
    let out = try Backup.export([c], blobs: blobs, appName: "jarvis-ios", temp: temp)
    XCTAssertEqual(out.files.count, 1)
    XCTAssertTrue(out.skipped.isEmpty)
    let data = try Data(contentsOf: out.files[0])
    let document = try JSONDecoder().decode(JSONValue.self, from: data)
    XCTAssertEqual(document["version"], .number(3))
    XCTAssertEqual(document["app"], .string("jarvis-ios"))
    XCTAssertNil(document["cookie"], "no credentials in a backup")
    let back = try Backup.read(data)
    XCTAssertEqual(back.conversations.count, 1)
    let imported = back.conversations[0]
    XCTAssertNotEqual(imported.id, "c1")
    XCTAssertEqual(imported.title, "带图")
    let attachment = imported.messages[0].attachments[0]
    XCTAssertTrue(attachment.id.hasPrefix("import_"))
    XCTAssertEqual(back.blobs[attachment.id], png)
    XCTAssertEqual(attachment.mime, "image/png")
    XCTAssertEqual(attachment.size, png.count)
    out.dispose()
    XCTAssertFalse(FileManager.default.fileExists(atPath: out.folder.path))
  }

  func testALostFileIsLeftOutAndNamedNotFatal() throws {
    let c = conversation("c1", title: "x", attachments: [Attachment(id: "gone", name: "g.png", mime: "image/png", kind: "image", size: 10)])
    let out = try Backup.export([c], blobs: MemoryVault(), appName: "jarvis-ios", temp: temp)
    XCTAssertEqual(out.skipped, ["gone"])
    let back = try Backup.read(try Data(contentsOf: out.files[0]))
    XCTAssertEqual(back.conversations.count, 1, "its message keeps a placeholder instead of failing the import")
  }

  func testManyConversationsAreSplitIntoPartsThatImportOnTheirOwn() throws {
    var limits = BackupLimits()
    limits.partBytes = 500
    let list = (1...4).map { conversation("c\($0)", title: "会话\($0)") }
    let out = try Backup.export(list, blobs: MemoryVault(), appName: "jarvis-ios", temp: temp, limits: limits)
    XCTAssertGreaterThan(out.files.count, 1)
    var titles: [String] = []
    for file in out.files {
      let part = try Backup.read(try Data(contentsOf: file))
      titles += part.conversations.map(\.title)
      XCTAssertTrue(file.lastPathComponent.contains("of\(out.files.count)"))
    }
    XCTAssertEqual(titles, ["会话1", "会话2", "会话3", "会话4"])
  }

  func testAConversationTooBigForAnyFileIsNamed() throws {
    var limits = BackupLimits()
    limits.importBytes = 120
    let c = conversation("c1", title: "大会话")
    XCTAssertThrowsError(try Backup.export([c], blobs: MemoryVault(), appName: "x", temp: temp, limits: limits)) {
      XCTAssertTrue(($0 as? JarvisException)?.message.contains("「大会话」") == true)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("jarvis-backup").path + "/x"), "nothing is left behind")
  }

  func testImportRefusesWhatItDoesNotUnderstand() {
    let cases: [(String, String)] = [
      ("not json", "不是支持的贾维斯备份"), (#"{"version":9,"conversations":[]}"#, "不是支持的贾维斯备份"),
      (#"{"version":3,"conversations":5}"#, "备份会话格式无效"),
      (#"{"version":3,"conversations":[],"files":[{"id":"a","data":"nope"}]}"#, "附件编码无效"),
      (#"{"version":3,"conversations":[],"files":[{"id":"a"}]}"#, "附件备份格式无效"),
      (#"{"version":3,"conversations":[{"id":"c","messages":[{"role":"user","text":"x","attachments":[{"id":"zz","name":"n","kind":"image"}]}]}]}"#, "备份缺少附件"),
    ]
    for (text, message) in cases {
      XCTAssertThrowsError(try Backup.read(Data(text.utf8)), text) { XCTAssertEqual(($0 as? JarvisException)?.message, message, text) }
    }
    var limits = BackupLimits()
    limits.importBytes = 10
    XCTAssertThrowsError(try Backup.read(Data(count: 11), limits: limits)) { XCTAssertEqual(($0 as? JarvisException)?.message, "备份过大") }
  }

  func testRunningTasksComeBackInterrupted() throws {
    var c = conversation("c1", title: "x")
    c.tasks = [MediaTask(id: "t", kind: "video", prompt: "p", status: "in_progress")]
    let out = try Backup.export([c], blobs: MemoryVault(), appName: "x", temp: temp)
    let back = try Backup.read(try Data(contentsOf: out.files[0]))
    XCTAssertEqual(back.conversations[0].tasks[0].status, "interrupted")
    XCTAssertEqual(back.conversations[0].tasks[0].error, "导入的任务不会自动重发，请检查原任务")
  }

  func testAnOldBackupIsReadToo() throws {
    let text = """
      {"version":2,"conversations":[{"id":"old","title":"旧会话","msgs":[
        {"role":"user","text":"你好","id":"1"},
        {"role":"assistant","text":"半句","streaming":true,"id":"2"},
        {"role":"tool","kind":"video","id":"3","args":{"prompt":"海"},"media":[{"url":"/v1/videos/x/content"},{"url":"javascript:1"}]},
        {"role":"user","text":"gone","gone":true,"id":"4"}]}],"files":[]}
      """
    let back = try Backup.read(Data(text.utf8)) { $0.hasPrefix("/v1/") }
    let c = back.conversations[0]
    XCTAssertEqual(c.title, "旧会话")
    XCTAssertEqual(c.messages.map(\.role), ["user", "assistant", "tool"])
    XCTAssertEqual(c.messages[1].status, "interrupted")
    XCTAssertEqual(c.tasks[0].urls, ["/v1/videos/x/content"])
    XCTAssertEqual(c.tasks[0].status, "completed")
    XCTAssertEqual(c.tasks[0].prompt, "海")
    XCTAssertEqual(c.messages[2].taskId, c.tasks[0].id)
  }

  func testConversationsWithoutAnIdOrWithTheSameOneStayApart() throws {
    let text = """
      {"version":2,"conversations":[
        {"title":"一","msgs":[{"role":"tool","kind":"image","args":{"prompt":"a"},"media":[{"url":"/v1/files/a"}]}]},
        {"title":"二","msgs":[{"role":"tool","kind":"image","args":{"prompt":"b"},"media":[{"url":"/v1/files/b"}]}]},
        {"id":"same","title":"三","msgs":[]},{"id":"same","title":"四","msgs":[]}],"files":[]}
      """
    let back = try Backup.read(Data(text.utf8)) { $0.hasPrefix("/v1/") }
    XCTAssertEqual(Set(back.conversations.map(\.id)).count, 4)
    let taskIds = back.conversations.flatMap { $0.tasks.map(\.id) }
    XCTAssertEqual(Set(taskIds).count, 2)
  }
}

@MainActor
final class StoreBackupTests: XCTestCase {
  func store() async -> (JarvisStore, FakeTransport, MemoryVault) {
    let api = FakeTransport()
    let vault = MemoryVault()
    let s = JarvisStore(api: api, vault: vault)
    await s.initialize()
    return (s, api, vault)
  }

  func testExportThenImportIntoAnotherStore() async throws {
    let (a, _, vaultA) = await store()
    try vaultA.writeBlob("img", Data(repeating: 7, count: 300))
    a.update(a.current.id) {
      $0.title = "一"
      $0.messages = [ChatMessage("user", "hi", attachments: [Attachment(id: "img", name: "a.jpg", mime: "image/jpeg", kind: "image", size: 300)])]
    }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sb-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let export = try a.exportBackup(temp: temp)
    XCTAssertEqual(export.files.count, 1)

    let (b, _, vaultB) = await store()
    let n = try await b.importBackup(try Data(contentsOf: export.files[0]))
    XCTAssertEqual(n, 1)
    XCTAssertEqual(b.current.title, "一")
    let imported = b.current.messages[0].attachments[0]
    XCTAssertNotEqual(imported.id, "img")
    XCTAssertEqual(try vaultB.readBlob(imported.id), Data(repeating: 7, count: 300))
  }

  func testABadBackupLeavesTheConversationsAlone() async {
    let (b, _, _) = await store()
    let before = b.conversations
    do {
      _ = try await b.importBackup(Data("{\"version\":9}".utf8))
      XCTFail("accepted")
    } catch {}
    XCTAssertEqual(b.conversations, before)
  }

  func testDiagnosticsCarriesNoSecrets() async {
    let (s, _, _) = await store()
    s.changeSettings { $0.apiKey = "sk-secret" }
    let text = s.diagnostics()
    XCTAssertFalse(text.contains("sk-secret"))
    XCTAssertTrue(text.contains("\"api_key_present\" : true"))
    XCTAssertTrue(text.contains("\"server\" : \"https://jarvis.test\""))
  }
}
