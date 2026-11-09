import XCTest

@testable import JarvisCore

final class MessageRowsTests: XCTestCase {
  func conversation() -> Conversation {
    Conversation(
      "c", messages: [
        ChatMessage("user", "hi", id: "u1", attachments: [Attachment(id: "a", name: "a.jpg", mime: "image/jpeg", kind: "image")]),
        ChatMessage("assistant", "", id: "t1", calls: [ToolCall(id: "k", name: "f", arguments: "{}")]),
        ChatMessage("tool", "{}", hidden: true, id: "h1"),
        ChatMessage("assistant", "", taskId: "task1", id: "m1"),
        ChatMessage("assistant", "", taskId: "missing", id: "gone"),
        ChatMessage("assistant", "answer", reasoning: "why", id: "r1"),
      ],
      tasks: [MediaTask(id: "task1", kind: "image", prompt: "猫", status: "in_progress", progress: 0.5)])
  }

  func testWhichMessagesAreRowsAndOfWhatKind() {
    let idle = MessageRows.rows(conversation(), generating: false)
    XCTAssertEqual(idle.map(\.id), ["u1", "m1", "r1"])
    XCTAssertEqual(idle.map { $0.json["kind"]?.string }, ["user", "task", "assistant"])
    // While a reply is going the tool step is shown as a status line.
    let busy = MessageRows.rows(conversation(), generating: true)
    XCTAssertEqual(busy.map(\.id), ["u1", "t1", "m1", "r1"])
    XCTAssertEqual(busy[1].json["kind"]?.string, "tool")
  }

  func testASameLengthCorrectionInTheMiddleStillChangesTheRow() {
    var c = conversation()
    let before = MessageRows.rows(c, generating: false).last!.revision
    let i = c.messages.firstIndex { $0.id == "r1" }!
    c.messages[i].text = "answer"
    XCTAssertEqual(MessageRows.rows(c, generating: false).last!.revision, before, "nothing changed")
    c.messages[i].text = "anSwer"
    c.messages[i].revision += 1
    XCTAssertNotEqual(MessageRows.rows(c, generating: false).last!.revision, before)
  }

  func testRegeneratingIsOfferedOnlyWhenItCanRun() {
    let on = MessageRows.rows(conversation(), generating: false)
    let off = MessageRows.rows(conversation(), generating: false, canRegenerate: false)
    XCTAssertEqual(on.last?.json["canRegenerate"]?.bool, true)
    XCTAssertEqual(off.last?.json["canRegenerate"]?.bool, false)
    XCTAssertNotEqual(on.last?.revision, off.last?.revision, "the row is drawn again when a call starts or ends")
  }

  func testRowJSONCarriesWhatTheListReads() {
    let rows = MessageRows.rows(conversation(), generating: false, canContinue: false, canCancelTask: true)
    let user = rows[0].json
    XCTAssertEqual(user["attachments"]?.array?.first?["name"]?.string, "a.jpg")
    XCTAssertEqual(user["lastReply"]?.bool, false)
    XCTAssertEqual(user["canContinue"]?.bool, false)
    let task = rows[1].json["task"]
    XCTAssertEqual(task?["id"]?.string, "task1")
    XCTAssertEqual(task?["pending"]?.bool, true)
    XCTAssertEqual(task?["canCancel"]?.bool, true)
    XCTAssertEqual(task?["progress"]?.double, 0.5)
    XCTAssertEqual(rows[2].json["lastReply"]?.bool, true)
    XCTAssertEqual(rows[2].json["reasoning"]?.string, "why")
  }

  func testTheRevisionChangesExactlyWhenTheRowDoes() {
    var c = conversation()
    let before = MessageRows.rows(c, generating: false)
    XCTAssertEqual(MessageRows.rows(c, generating: false).map(\.revision), before.map(\.revision))
    c.messages[5].text = "answer longer"
    let after = MessageRows.rows(c, generating: false)
    XCTAssertEqual(after[0].revision, before[0].revision)
    XCTAssertNotEqual(after[2].revision, before[2].revision)
    c.tasks[0].progress = 0.9
    XCTAssertNotEqual(MessageRows.rows(c, generating: false)[1].revision, after[1].revision)
    XCTAssertNotEqual(MessageRows.rows(c, generating: true)[0].revision, after[0].revision)
  }

  func testLastReplyIsTheLastVisibleAssistantMessage() {
    var c = conversation()
    XCTAssertEqual(MessageRows.lastReply(c), "r1")
    c.messages[5].hidden = true
    XCTAssertEqual(MessageRows.lastReply(c), "gone")
  }

  func testARunningTaskCarriesItsTimelineAndPlanAndRedrawsWhenAReportComes() {
    var c = conversation()
    let plain = MessageRows.rows(c, generating: false)
    c.tasks[0].phase = "generating"
    c.tasks[0].track = MediaTrack(startedAt: 5)
    c.tasks[0].track?.note(MediaReport(progress: 12, phase: "generating"), at: 9)
    let rows = MessageRows.rows(c, generating: false)
    let task = rows[1].json["task"]
    XCTAssertEqual(task?["phase"]?.string, "generating")
    XCTAssertEqual(task?["track"]?["startedAt"]?.double, 5)
    XCTAssertEqual(task?["track"]?["stepAt"]?.double, 9)
    XCTAssertGreaterThan(task?["plan"]?["prep"]?.double ?? 0, 0)
    XCTAssertNotEqual(rows[1].revision, plain[1].revision)
    c.tasks[0].track?.note(MediaReport(progress: 25, phase: "generating"), at: 12)
    XCTAssertNotEqual(MessageRows.rows(c, generating: false)[1].revision, rows[1].revision, "each new report redraws the card")
  }
}
