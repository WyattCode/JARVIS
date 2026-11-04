import XCTest

@testable import JarvisCore

final class PayloadTests: XCTestCase {
  func testTheSystemLineCarriesTheUsersInstructions() throws {
    let plain = try Payload.messages(for: Conversation("c"), instructions: "", blobs: MemoryVault())
    XCTAssertEqual(plain.count, 1)
    XCTAssertTrue(plain[0]["content"]!.string!.hasSuffix("不要因此插话或切换语言。"))
    let custom = try Payload.messages(for: Conversation("c"), instructions: "简短", blobs: MemoryVault())
    XCTAssertTrue(custom[0]["content"]!.string!.hasSuffix("\n简短"))
  }

  func testHiddenMessagesAreLeftOutAndPlainUserTextStaysAString() throws {
    let c = Conversation("c", messages: [ChatMessage("user", "你好"), ChatMessage("user", "secret", hidden: true), ChatMessage("assistant", "")])
    let out = try Payload.messages(for: c, instructions: "", blobs: MemoryVault())
    XCTAssertEqual(out.count, 2)
    XCTAssertEqual(out[1]["content"], .string("你好"))
  }

  func testPicturesGoAsDataAddressesAndFilesAsText() throws {
    let blobs = MemoryVault()
    try blobs.writeBlob("img", Data([1, 2, 3]))
    let m = ChatMessage(
      "user", "看",
      attachments: [
        Attachment(id: "img", name: "a.png", mime: "image/png", kind: "image"),
        Attachment(id: "doc", name: "n.txt", mime: "text/plain", kind: "text", text: "内容"),
        Attachment(id: "gone", name: "lost.png", mime: "image/png", kind: "image"),
      ])
    let out = try Payload.messages(for: Conversation("c", messages: [m]), instructions: "", blobs: blobs)
    let parts = out[1]["content"]!.array!
    XCTAssertEqual(parts[0]["text"], .string("看"))
    XCTAssertEqual(parts[1]["image_url"]?["url"], .string("data:image/png;base64,AQID"))
    XCTAssertEqual(parts[2]["text"], .string("附件「n.txt」的内容：\n内容"))
    XCTAssertEqual(parts[3]["text"], .string("[附件「lost.png」不可用]"), "a lost file does not stop the conversation")
  }

  func testTooManyPicturesOrTooMuchTextIsRefused() throws {
    let blobs = MemoryVault()
    try blobs.writeBlob("big", Data(count: Payload.imageLimit + 1))
    let pic = ChatMessage("user", "", attachments: [Attachment(id: "big", name: "b", mime: "image/png", kind: "image")])
    XCTAssertThrowsError(try Payload.messages(for: Conversation("c", messages: [pic]), instructions: "", blobs: blobs)) {
      XCTAssertEqual(($0 as? JarvisException)?.message, "会话图片超过18MB，请新建话题")
    }
    let text = ChatMessage("user", "", attachments: [Attachment(id: "t", name: "t", mime: "text/plain", kind: "text", text: String(repeating: "字", count: Payload.textLimit + 1))])
    XCTAssertThrowsError(try Payload.messages(for: Conversation("c", messages: [text]), instructions: "", blobs: blobs)) {
      XCTAssertEqual(($0 as? JarvisException)?.message, "会话附件文字过多，请拆分或新建话题")
    }
  }

  func testToolCallsAreFollowedByTheirResultsOrTheTaskReceipt() throws {
    let call = ToolCall(id: "k1", name: "generate_image", arguments: "{}")
    let other = ToolCall(id: "k2", name: "generate_image", arguments: "{}")
    let done = ToolCall(id: "k3", name: "list_models", arguments: "{}")
    let reply = ChatMessage("assistant", "", calls: [call, other, done], toolResults: ["k3": "{\"ok\":true}"])
    let task = MediaTask(id: "t", kind: "image", prompt: "p", callId: "k1", status: "in_progress")
    let out = try Payload.messages(for: Conversation("c", messages: [reply], tasks: [task]), instructions: "", blobs: MemoryVault())
    XCTAssertEqual(out[1]["content"], .null)
    XCTAssertEqual(out[1]["tool_calls"]?.array?.count, 3)
    XCTAssertEqual(out[1]["tool_calls"]?.array?[0]["function"]?["name"], .string("generate_image"))
    XCTAssertTrue(out[2]["content"]!.string!.contains("\"status\":\"in_progress\""))
    XCTAssertEqual(out[3]["content"], .string("{\"status\":\"cancelled\"}"))
    XCTAssertEqual(out[4]["content"], .string("{\"ok\":true}"))
    XCTAssertEqual(out[2]["tool_call_id"], .string("k1"))
  }
}
