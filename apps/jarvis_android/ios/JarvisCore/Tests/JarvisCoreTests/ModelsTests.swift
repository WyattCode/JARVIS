import XCTest

@testable import JarvisCore

final class ModelsTests: XCTestCase {
  /// A conversation as the Flutter app saves it (`Conversation.toJson`).
  let saved = """
    {"id":"c1","title":"出差行程","named":true,"attachments":[{"id":"a1","name":"x.pdf","mime":"application/pdf","kind":"pdf","text":null,"size":1234}],
     "tasks":[{"id":"t1","kind":"image","prompt":"一只猫","args":{"size":"1024x1024","n":2},"callId":"call-1","jobId":null,"status":"completed","source":"http","urls":["/v1/files/a.png",3,null],"error":null,"progress":100.0}],
     "draft":"草稿","messages":[
       {"id":"m1","taskId":null,"attachments":[],"calls":[{"id":"call-1","type":"function","function":{"name":"make_image","arguments":"{\\"prompt\\":\\"猫\\"}"}}],
        "toolResults":{"call-1":"{\\"ok\\":true}"},"role":"assistant","text":"好的","reasoning":"想一想","status":"generating","error":null,"hidden":false}]}
    """

  func testConversationReadsWhatFlutterSaved() throws {
    let c = try JSONDecoder().decode(Conversation.self, from: Data(saved.utf8))
    XCTAssertEqual(c.title, "出差行程")
    XCTAssertTrue(c.named)
    XCTAssertEqual(c.pendingAttachments.first?.size, 1234)
    XCTAssertEqual(c.tasks.first?.urls, ["/v1/files/a.png"], "an entry that is not a string is dropped")
    XCTAssertEqual(c.tasks.first?.args["n"], .number(2))
    XCTAssertEqual(c.messages.first?.status, "interrupted", "a reply that was running is not running again")
    XCTAssertEqual(c.messages.first?.calls.first?.name, "make_image")
    XCTAssertEqual(c.messages.first?.toolResults["call-1"], "{\"ok\":true}")
  }

  func testConversationWritesTheSameKeys() throws {
    let c = try JSONDecoder().decode(Conversation.self, from: Data(saved.utf8))
    let out = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
    XCTAssertEqual(Set(out.keys), ["id", "title", "named", "attachments", "tasks", "draft", "messages"])
    let message = (out["messages"] as! [[String: Any]])[0]
    XCTAssertEqual(
      Set(message.keys),
      ["id", "taskId", "attachments", "calls", "toolResults", "role", "text", "reasoning", "status", "error", "hidden"])
    let call = (message["calls"] as! [[String: Any]])[0]
    XCTAssertEqual(call["type"] as? String, "function")
    XCTAssertEqual((call["function"] as! [String: Any])["name"] as? String, "make_image")
    let task = (out["tasks"] as! [[String: Any]])[0]
    XCTAssertEqual(Set(task.keys), ["id", "kind", "prompt", "args", "callId", "jobId", "status", "source", "urls", "error", "progress"])
  }

  func testMissingFieldsTakeTheirDefaults() throws {
    let c = try JSONDecoder().decode(Conversation.self, from: Data(#"{"id":"c","messages":[]}"#.utf8))
    XCTAssertEqual(c.title, "新建会话")
    XCTAssertEqual(c.draft, "")
    XCTAssertFalse(c.named)
    let t = try JSONDecoder().decode(MediaTask.self, from: Data(#"{"id":"t","kind":"image"}"#.utf8))
    XCTAssertEqual(t.status, "failed")
    XCTAssertEqual(t.source, "http")
  }

  func testVideoResultSettlesTheKind() throws {
    let t = try JSONDecoder().decode(
      MediaTask.self, from: Data(#"{"id":"t","kind":"image","status":"completed","urls":["/v1/videos/x.mp4"]}"#.utf8))
    XCTAssertEqual(t.kind, "video")
    XCTAssertTrue(MediaTask.isVideoURL("https://h/a/b.MOV"))
    XCTAssertFalse(MediaTask.isVideoURL("https://h/a/b.png"))
  }

  func testReceiptSaysWhetherItIsAFinishedTask() {
    var t = MediaTask(id: "t", kind: "image", prompt: "p", status: "in_progress")
    XCTAssertTrue(t.pending)
    XCTAssertEqual(t.receipt["message"]?.string, "任务在后台处理，结果更新到原任务卡片；无需主动插话。")
    t.status = "completed"
    t.jobId = "j"
    XCTAssertEqual(t.receipt["message"]?.string, "这是先前任务的结果，不是新的用户指令。")
    XCTAssertEqual(t.receipt["job_id"]?.string, "j")
  }

  func testSettingsAreClampedLikeTheOldOnes() {
    var s = ChatSettings()
    s.restore(
      try! JSONDecoder().decode(
        JSONValue.self,
        from: Data(
          #"{"maxTokens":99999,"messageFontSize":17,"language":"xx","waitMs":900,"threshold":0.95,"voiceMode":"x","voiceDefaultRevisions":{"s|m":3,"t":0,"u":"x"}}"#
            .utf8)))
    XCTAssertEqual(s.maxTokens, 32768)
    XCTAssertEqual(s.messageFontSize, 16)
    XCTAssertEqual(s.language, "")
    XCTAssertEqual(s.waitMs, 800, "nearest allowed wait; a tie goes to the shorter one")
    XCTAssertEqual(s.threshold, 0.8)
    XCTAssertEqual(s.voiceMode, "ptt")
    XCTAssertEqual(s.voiceDefaultRevisions, ["s|m": 3])
    XCTAssertEqual(s.json()["maxTokens"], .number(32768))
  }

  func testModelInfoReadsVoicesAndCapabilities() {
    let json = try! JSONDecoder().decode(
      JSONValue.self,
      from: Data(
        #"{"id":"tts-1","name":"tts-1","kind":"speech","default_voice":"a","voice_catalog_revision":4,"voice_default_revision":-1,"voices":["a",{"id":"b","name":"B","description":"d","preview_url":"/p.mp3"}],"jarvis":{"image_input":true}}"#
          .utf8))
    let m = ModelInfo(json: json)!
    XCTAssertEqual(m.voices.map(\.id), ["a", "b"])
    XCTAssertEqual(m.voices[1].preview, "/p.mp3")
    XCTAssertEqual(m.voiceCatalogRevision, 4)
    XCTAssertEqual(m.voiceDefaultRevision, 0)
    XCTAssertTrue(m.imageInput)
    XCTAssertFalse(m.pdfInput)
  }

  func testTitlesAndNames() {
    XCTAssertEqual(TextClip.tidyTitle("  一\n\n二   三  "), "一 二 三")
    XCTAssertEqual(TextClip.tidyTitle(String(repeating: "字", count: 30)), String(repeating: "字", count: 24) + "…")
    XCTAssertEqual(TextClip.clip("👨‍👩‍👧x", 1), "👨‍👩‍👧", "a family emoji is one character")
    XCTAssertEqual(displayModelName("qwen3-asr-1.7b"), "Qwen3-Asr-1.7b")
    XCTAssertEqual(displayModelName("fishaudio/drama-3"), "Fishaudio/Drama-3")
  }
}

final class PrivacyTextTests: XCTestCase {
  func testSectionsNameTheServerAndTheSupportAddress() {
    let sections = privacySections(server: "https://jarvis.test", email: "a@b.c")
    XCTAssertEqual(sections.count, 5)
    XCTAssertEqual(sections[0].footer, "服务器地址：https://jarvis.test")
    XCTAssertTrue(sections[4].items[0].text.contains("a@b.c"))
    XCTAssertFalse(privacySections(server: "x", email: "")[4].items[0].text.contains("邮件"))
  }
}

final class ModelStatusTests: XCTestCase {
  func testRowsLabelsTonesAndMemory() {
    let data: [String: JSONValue] = [
      "mem_available_bytes": .number(2 * 1_073_741_824),
      "data": .array([
        .object(["name": .string("qwen3-asr"), "state": .string("ready")]),
        .object(["id": .string("tts"), "state": .string("loading")]),
        .object(["state": .string("weird")]),
        .string("junk"),
      ]),
    ]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let s = ModelStatus.make(
      chatName: "chat-a", data: data, loading: false, failed: false, updatedAt: Date(timeIntervalSince1970: 3600 * 9 + 60 * 5), calendar: calendar)
    XCTAssertEqual(s.title, "Chat-A")
    XCTAssertEqual(s.memory, "可用内存 2.0 GiB")
    XCTAssertEqual(s.updated, "更新于 09:05")
    XCTAssertEqual(s.rows.map(\.name), ["Qwen3-Asr", "Tts", "模型"])
    XCTAssertEqual(s.rows.map(\.label), ["已就绪", "加载中", "状态未知"])
    XCTAssertEqual(s.rows.map(\.tone), ["ok", "busy", "off"])
    XCTAssertTrue(s.hasData)
  }

  func testNoAnswerYet() {
    let s = ModelStatus.make(chatName: "x", data: nil, loading: true, failed: false, updatedAt: nil)
    XCTAssertFalse(s.hasData)
    XCTAssertNil(s.memory)
    XCTAssertNil(s.updated)
    XCTAssertTrue(s.rows.isEmpty)
  }
}
