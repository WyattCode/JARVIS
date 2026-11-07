import XCTest

@testable import JarvisCore

/// What a call keeps of the replies: whether each was finished (told to the server again when the history is given back),
/// the final text of a reply (which replaces the streamed one) and which late events are taken in.
extension VoiceTests {
  // MARK: Helpers

  private func created(_ id: String) {
    wire.emit(["type": .string("response.created"), "response": .object(["id": .string(id)])])
  }

  private func delta(
    _ item: String, _ text: String, response: String? = nil, kind: String = "response.audio_transcript.delta", part: Int? = nil
  ) {
    var e: [String: JSONValue] = ["type": .string(kind), "item_id": .string(item), "delta": .string(text)]
    if let response { e["response_id"] = .string(response) }
    if let part { e["content_index"] = .number(Double(part)) }
    wire.emit(e)
  }

  private func final(
    _ item: String, _ text: String, response: String? = nil, kind: String = "response.audio_transcript.done", part: Int? = nil
  ) {
    var e: [String: JSONValue] = ["type": .string(kind), "item_id": .string(item)]
    e[kind == "response.text.done" ? "text" : "transcript"] = .string(text)
    if let response { e["response_id"] = .string(response) }
    if let part { e["content_index"] = .number(Double(part)) }
    wire.emit(e)
  }

  private func done(_ id: String, status: String = "completed", output: [JSONValue] = []) {
    wire.emit([
      "type": .string("response.done"),
      "response": .object(["id": .string(id), "status": .string(status), "output": .array(output)]),
    ])
  }

  private func output(_ item: String, _ transcript: String, key: String = "transcript") -> JSONValue {
    .object([
      "id": .string(item), "type": .string("message"), "role": .string("assistant"),
      "content": .array([.object(["type": .string(key == "text" ? "text" : "audio"), key: .string(transcript)])]),
    ])
  }

  private var replies: [ChatMessage] { store.current.messages.filter { $0.role == "assistant" } }

  private func pause(_ seconds: Double = 0.1) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

  private func given(_ wire: FakeWire) -> [JSONValue] { wire.sent(type: "conversation.item.create").compactMap { $0["item"] } }

  private func history(_ messages: [ChatMessage]) {
    store.update(store.current.id) { $0.messages = messages }
  }

  // MARK: Whether a reply was finished

  func testReplayedRepliesSayWhetherTheyWereFinished() async {
    history([
      ChatMessage("user", "问一"), ChatMessage("assistant", "答一", status: "complete"),
      ChatMessage("user", "问二"), ChatMessage("assistant", "答二说到一半", status: "interrupted"),
      ChatMessage("user", "问三"), ChatMessage("assistant", "答三被截断", status: "length"),
      ChatMessage("user", "问四"), ChatMessage("assistant", "答四出错", status: "interrupted", error: "网络中断"),
      ChatMessage("assistant", "", status: "interrupted"),
    ])
    await startCall()
    let items = given(wire)
    XCTAssertEqual(items.map { $0["content"]?.array?[0]["text"]?.string ?? "" },
      ["问一", "答一", "问二", "答二说到一半", "问三", "答三被截断", "问四", "答四出错"], "the empty one is not given")
    XCTAssertEqual(items.filter { $0["role"] == .string("assistant") }.map { $0["status"]?.string ?? "-" },
      ["completed", "incomplete", "incomplete", "incomplete"])
    XCTAssertTrue(items.filter { $0["role"] == .string("user") }.allSatisfy { $0["status"] == nil }, "what the user said carries no status")
    // The words on the screen are untouched.
    XCTAssertEqual(store.current.messages.count, 9)
    XCTAssertEqual(store.current.messages[3].text, "答二说到一半")
  }

  func testAReplyCutByALostConnectionIsGivenBackAsIncomplete() async {
    await startCall()
    created("r1")
    delta("a1", "说到一半", response: "r1")
    await settle({ [self] in voice.lastBot == "说到一半" })
    let first = wire
    first.drop()
    await settle({ [self] in api.wires.count == 2 })
    await confirm()
    XCTAssertTrue(voice.ready)
    let again = given(wire).filter { $0["role"] == .string("assistant") }
    XCTAssertEqual(again.count, 1)
    XCTAssertEqual(again[0]["status"], .string("incomplete"))
    XCTAssertEqual(again[0]["content"]?.array?[0]["text"], .string("说到一半"))
    XCTAssertEqual(replies.first?.text, "说到一半", "what was on the screen stays")
    XCTAssertEqual(replies.first?.status, "interrupted")
  }

  func testAFinishedReplyIsGivenBackAsCompletedAfterAReconnect() async {
    await startCall()
    created("r1")
    delta("a1", "完整的回答", response: "r1")
    done("r1", output: [output("a1", "完整的回答")])
    await settle({ [self] in replies.first?.status == "complete" })
    wire.drop()
    await settle({ [self] in api.wires.count == 2 })
    await confirm()
    XCTAssertEqual(given(wire).filter { $0["role"] == .string("assistant") }.map { $0["status"] }, [.string("completed")])
  }

  func testWhetherARepliesWasFinishedSurvivesARestart() async throws {
    history([
      ChatMessage("user", "问"), ChatMessage("assistant", "完整", status: "complete"),
      ChatMessage("assistant", "被打断", status: "interrupted"), ChatMessage("assistant", "到上限", status: "length"),
      ChatMessage("assistant", "还在写时退出了", status: "generating"),
    ])
    await store.save()
    let again = JarvisStore(api: api, vault: vault)
    await again.initialize()
    let assistant = again.current.messages.filter { $0.role == "assistant" }
    XCTAssertEqual(assistant.map(\.status), ["complete", "interrupted", "length", "interrupted"])
    XCTAssertEqual(assistant.map(\.wireStatus), ["completed", "incomplete", "incomplete", "incomplete"])
    XCTAssertEqual(assistant.map(\.text), ["完整", "被打断", "到上限", "还在写时退出了"], "no words are lost")
    // and a call started after the restart says so to the server
    let voice2 = VoiceSession(store: again, audio: FakeAudio())
    again.voice = voice2
    await voice2.start(again.current.id)
    await settle({ [self] in api.wires.count >= 1 && !(api.wires.last!.sent(type: "conversation.item.create").isEmpty) })
    XCTAssertEqual(given(wire).filter { $0["role"] == .string("assistant") }.map { $0["status"]?.string ?? "-" },
      ["completed", "incomplete", "incomplete", "incomplete"])
    await voice2.stop()
  }

  func testAnUnknownSavedStatusIsNotTakenForAFinishedReply() {
    XCTAssertEqual(ChatMessage("assistant", "x", status: "complete").wireStatus, "completed")
    for status in ["interrupted", "length", "generating", "failed", ""] {
      XCTAssertEqual(ChatMessage("assistant", "x", status: status).wireStatus, "incomplete", status)
    }
    XCTAssertEqual(ChatMessage("assistant", "x", status: "complete", error: "出错").wireStatus, "incomplete")
  }

  // MARK: The final text

  func testTheFinalTextReplacesAStreamedLongReply() async {
    await startCall()
    created("r1")
    var streamed = ""
    for i in 0..<300 {
      let piece = "第\(i)段，"
      streamed += piece
      delta("a1", piece, response: "r1")
    }
    await settle({ [self] in voice.lastBot == streamed })
    XCTAssertEqual(replies.first?.text, streamed)
    // The server checked the text and repaired it: this is what it keeps.
    let repaired = streamed.replacingOccurrences(of: "第7段，", with: "第七段，") + "完。"
    final("a1", repaired, response: "r1")
    await pause()
    XCTAssertEqual(replies.first?.text, streamed, "the final text waits for the reply's end")
    XCTAssertEqual(replies.first?.status, "generating", "the reply is not over until response.done")
    done("r1", output: [output("a1", repaired)])
    await settle({ [self] in replies.first?.status == "complete" })
    XCTAssertEqual(replies.first?.text, repaired)
    XCTAssertEqual(voice.lastBot, repaired, "the call page shows it too")
    XCTAssertEqual(voice.textCorrections, 1, "one correction, not two for the same text")
  }

  func testATextOnlyReplyIsSettledByItsTextDoneEvent() async {
    await startCall()
    created("r1")
    delta("a1", "你号", response: "r1", kind: "response.text.delta")
    final("a1", "你好", response: "r1", kind: "response.text.done")
    done("r1", output: [])
    await settle({ [self] in replies.first?.text == "你好" })
    XCTAssertEqual(replies.first?.text, "你好")
    XCTAssertEqual(voice.lastBot, "你好")
  }

  func testAnEmptyFinalTextDoesNotWipeTheReply() async {
    await startCall()
    created("r1")
    delta("a1", "已经说出的话", response: "r1")
    final("a1", "", response: "r1")
    await pause()
    XCTAssertEqual(replies.first?.text, "已经说出的话")
  }

  func testStreamedTextAfterTheFinalTextIsNotAddedTwice() async {
    await startCall()
    created("r1")
    delta("a1", "你好", response: "r1")
    final("a1", "你好呀", response: "r1")
    done("r1", output: [])
    await settle({ [self] in replies.first?.text == "你好呀" })
    delta("a1", "呀", response: "r1")
    await pause()
    XCTAssertEqual(replies.first?.text, "你好呀")
  }

  func testAReplyInSeveralPartsKeepsEachPart() async {
    await startCall()
    created("r1")
    delta("a1", "甲", response: "r1", part: 0)
    delta("a1", "乙", response: "r1", part: 1)
    final("a1", "甲甲", response: "r1", part: 0)
    done("r1", output: [])
    await settle({ [self] in replies.first?.text == "甲甲乙" })
    XCTAssertEqual(replies.first?.text, "甲甲乙", "settling one part leaves the other")
    final("a1", "乙乙", response: "r1", part: 1)
    await settle({ [self] in replies.first?.text == "甲甲乙乙" })
    XCTAssertEqual(replies.first?.text, "甲甲乙乙", "after the end the outcome is known, so a part settles at once")
  }

  // MARK: Without done events

  func testResponseDoneFillsInTheTextWhenNoDoneEventCame() async {
    await startCall()
    created("r1")
    delta("a1", "半截", response: "r1")
    done("r1", output: [output("a1", "完整的一句话")])
    await settle({ [self] in replies.first?.status == "complete" })
    XCTAssertEqual(replies.first?.text, "完整的一句话")
    XCTAssertEqual(voice.lastBot, "完整的一句话")
  }

  func testAReplyThatWasNeverStreamedIsShownFromResponseDone() async {
    await startCall()
    created("r1")
    done("r1", output: [output("a1", "一次给全", key: "text")])
    await settle({ [self] in !replies.isEmpty })
    XCTAssertEqual(replies.map(\.text), ["一次给全"])
    XCTAssertEqual(replies.first?.status, "complete")
  }

  func testAnIncompleteResponseKeepsWhatWasStreamed() async {
    await startCall()
    created("r1")
    delta("a1", "到上限", response: "r1")
    done("r1", status: "incomplete", output: [output("a1", "别的内容")])
    await settle({ [self] in replies.first?.status == "length" })
    XCTAssertEqual(replies.first?.text, "到上限", "only a completed response fills the text in")
    XCTAssertEqual(replies.first?.status, "length")
  }

  func testTheCompletedOutputOutranksTheDoneEventWhenTheyDiffer() async {
    await startCall()
    created("r1")
    delta("a1", "草稿", response: "r1")
    final("a1", "终稿事件的版本", response: "r1")
    done("r1", output: [output("a1", "输出里的版本")])
    await settle({ [self] in replies.first?.status == "complete" })
    XCTAssertEqual(replies.first?.text, "输出里的版本", "same order as the web and Android clients")
    XCTAssertEqual(voice.lastBot, "输出里的版本")
    // a done event that comes after the end cannot take it back
    final("a1", "终稿事件的版本", response: "r1")
    await pause()
    XCTAssertEqual(replies.first?.text, "输出里的版本")
  }

  func testTheDoneEventTextIsUsedWhereTheOutputHasNone() async {
    await startCall()
    created("r1")
    delta("a1", "草稿", response: "r1")
    final("a1", "终稿事件的版本", response: "r1")
    // no output at all, then an output item without the text
    done("r1", output: [.object(["id": .string("a1"), "type": .string("message"), "role": .string("assistant"), "content": .array([])])])
    await settle({ [self] in replies.first?.status == "complete" })
    XCTAssertEqual(replies.first?.text, "终稿事件的版本")
    // parts are judged one by one: the output has part 0, the done event gave part 1
    created("r2")
    delta("a2", "甲", response: "r2", part: 0)
    delta("a2", "乙", response: "r2", part: 1)
    final("a2", "甲(事件)", response: "r2", part: 0)
    final("a2", "乙(事件)", response: "r2", part: 1)
    done("r2", output: [output("a2", "甲(输出)")])
    await settle({ [self] in replies.count == 2 && replies.last?.status == "complete" })
    XCTAssertEqual(replies.last?.text, "甲(输出)乙(事件)")
  }

  func testAnOutputThatCameBeforeTheDoneEventIsKept() async {
    await startCall()
    created("r1")
    delta("a1", "草稿", response: "r1")
    done("r1", output: [output("a1", "输出里的版本")])
    await settle({ [self] in replies.first?.status == "complete" })
    final("a1", "较短", response: "r1")
    await pause()
    XCTAssertEqual(replies.first?.text, "输出里的版本")
  }


  func testAFailedResponseIsIncompleteAndKeepsItsWords() async {
    await startCall()
    created("r1")
    delta("a1", "写到这里出错", response: "r1")
    done("r1", status: "failed", output: [output("a1", "不该用的文字")])
    await settle({ [self] in replies.first?.status == "interrupted" })
    XCTAssertEqual(replies.first?.text, "写到这里出错")
    XCTAssertEqual(replies.first?.wireStatus, "incomplete")
  }

  // MARK: A short final text before the reply's end

  private var longReply: String { "这是一段已经完整显示在屏幕上的较长回答，说了很多内容。" }

  private func streamedLongReplyWithShortFinal() async {
    created("r1")
    delta("a1", longReply, response: "r1")
    await settle({ [self] in voice.lastBot == longReply })
    final("a1", "这是一段", response: "r1")
    await pause()
    XCTAssertEqual(replies.first?.text, longReply, "a final text alone never replaces what is shown")
    XCTAssertEqual(replies.first?.status, "generating")
  }

  func testAShorterFinalTextFollowedByCancelledKeepsTheLongerTextAndMarksItIncomplete() async {
    await startCall()
    await streamedLongReplyWithShortFinal()
    done("r1", status: "cancelled", output: [output("a1", "这是一段")])
    await settle({ [self] in replies.first?.status == "interrupted" })
    XCTAssertEqual(replies.first?.text, longReply)
    XCTAssertEqual(voice.lastBot, longReply)
    XCTAssertEqual(replies.first?.wireStatus, "incomplete")
    XCTAssertEqual(voice.textCorrections, 0)
    wire.drop()
    await settle({ [self] in api.wires.count == 2 })
    await confirm()
    let again = given(wire).filter { $0["role"] == .string("assistant") }
    XCTAssertEqual(again.map { $0["status"]?.string }, ["incomplete"])
    XCTAssertEqual(again.first?["content"]?.array?[0]["text"]?.string, longReply, "the longer text is what is given back")
  }

  func testACancelledEndThatListsNoOutputStillKeepsTheLongerText() async {
    await startCall()
    await streamedLongReplyWithShortFinal()
    done("r1", status: "cancelled", output: [])
    await settle({ [self] in replies.first?.status == "interrupted" })
    XCTAssertEqual(replies.first?.text, longReply)
    XCTAssertEqual(voice.textCorrections, 0)
  }

  func testACompletedEndThatListsNoOutputStillShowsTheHeldFinalText() async {
    await startCall()
    await streamedLongReplyWithShortFinal()
    done("r1", status: "completed", output: [])
    await settle({ [self] in replies.first?.status == "complete" })
    XCTAssertEqual(replies.first?.text, "这是一段")
  }

  func testAShorterFinalTextFollowedByCompletedBecomesTheText() async {
    await startCall()
    await streamedLongReplyWithShortFinal()
    done("r1", status: "completed", output: [output("a1", "这是一段")])
    await settle({ [self] in replies.first?.status == "complete" })
    XCTAssertEqual(replies.first?.text, "这是一段", "the server confirmed the reply: its text is the text")
    XCTAssertEqual(voice.lastBot, "这是一段")
    XCTAssertEqual(replies.first?.wireStatus, "completed")
  }

  func testAShorterFinalTextFollowedByFailedOrIncompleteKeepsTheLongerText() async {
    for (state, mapped) in [("failed", "interrupted"), ("incomplete", "length")] {
      await voice.stop()
      history([])
      await startCall()
      await streamedLongReplyWithShortFinal()
      done("r1", status: state, output: [output("a1", "这是一段")])
      await settle({ [self] in replies.first?.status == mapped })
      XCTAssertEqual(replies.first?.text, longReply, state)
      XCTAssertEqual(replies.first?.status, mapped, state)
      XCTAssertEqual(replies.first?.wireStatus, "incomplete", state)
    }
  }

  func testTheOutcomeBeforeTheFinalTextDecidesAtOnce() async {
    // cancelled first: the late final text is dropped
    await startCall()
    created("r1")
    delta("a1", longReply, response: "r1")
    await settle({ [self] in voice.lastBot == longReply })
    done("r1", status: "cancelled", output: [])
    await settle({ [self] in replies.first?.status == "interrupted" })
    final("a1", "这是一段", response: "r1")
    await pause()
    XCTAssertEqual(replies.first?.text, longReply)
    XCTAssertEqual(replies.first?.status, "interrupted")
    // completed first: the final text then goes on the screen at once
    created("r2")
    delta("a2", "草稿", response: "r2")
    done("r2", status: "completed", output: [])
    await settle({ [self] in replies.last?.status == "complete" })
    final("a2", "定稿", response: "r2")
    await settle({ [self] in replies.last?.text == "定稿" })
    XCTAssertEqual(replies.map(\.text), [longReply, "定稿"])
  }

  func testALostConnectionAfterAShortFinalTextKeepsTheLongerTextAndMarksItIncomplete() async {
    await startCall()
    await streamedLongReplyWithShortFinal()
    let first = wire
    first.drop()
    await settle({ [self] in api.wires.count == 2 })
    XCTAssertEqual(replies.first?.text, longReply)
    XCTAssertEqual(replies.first?.status, "interrupted", "no end came: it is not taken for a finished reply")
    await confirm()
    XCTAssertEqual(given(wire).filter { $0["role"] == .string("assistant") }.map { $0["status"]?.string }, ["incomplete"])
    // the old connection saying its end afterwards changes nothing
    first.emit(["type": .string("response.done"), "response": .object(["id": .string("r1"), "status": .string("completed"), "output": .array([output("a1", "这是一段")])])])
    await pause()
    XCTAssertEqual(replies.first?.text, longReply)
    XCTAssertEqual(replies.first?.status, "interrupted")
  }

  func testHangingUpAfterAShortFinalTextKeepsTheLongerText() async {
    await startCall()
    await streamedLongReplyWithShortFinal()
    await voice.stop()
    XCTAssertEqual(replies.first?.text, longReply)
    XCTAssertEqual(replies.first?.status, "interrupted")
  }

  func testBargingInAfterAShortFinalTextKeepsTheLongerText() async {
    await startCall()
    await streamedLongReplyWithShortFinal()
    await voice.interrupt()
    done("r1", status: "cancelled", output: [output("a1", "这是一段")])
    await pause()
    XCTAssertEqual(replies.first?.text, longReply)
    XCTAssertEqual(replies.first?.status, "interrupted")
    // and the next reply is unaffected
    created("r2")
    delta("a2", "新的", response: "r2")
    final("a2", "新的回答", response: "r2")
    done("r2", output: [])
    await settle({ [self] in replies.last?.status == "complete" })
    XCTAssertEqual(replies.map(\.text), [longReply, "新的回答"])
  }

  func testAnEarlierRepliesHeldTextWaitsForItsOwnEnd() async {
    await startCall()
    created("r1")
    delta("a1", longReply, response: "r1")
    final("a1", "这是一段", response: "r1")
    created("r2")
    delta("a2", "第二个回答", response: "r2")
    await settle({ [self] in voice.lastBot == "第二个回答" })
    done("r2", output: [])
    await settle({ [self] in replies.last?.status == "complete" })
    XCTAssertEqual(replies.first?.text, longReply, "the end of r2 is not the end of r1")
    done("r1", output: [])
    await settle({ [self] in replies.first?.status == "complete" })
    XCTAssertEqual(replies.first?.text, "这是一段")
    XCTAssertEqual(replies.last?.text, "第二个回答")
    XCTAssertEqual(voice.lastBot, "第二个回答")
  }

  // MARK: Second review

  func testHalfRecognisedSpeechOfTheUserIsNotGivenBackAsSaid() async {
    history([
      ChatMessage("user", "完整的话", status: "complete"), ChatMessage("assistant", "回答", status: "complete"),
      ChatMessage("user", "只听到一半", status: "interrupted"), ChatMessage("user", "还在转写", status: "generating"),
    ])
    await startCall()
    XCTAssertEqual(given(wire).map { $0["content"]?.array?[0]["text"]?.string ?? "" }, ["完整的话", "回答"])
  }

  func testAPartialTranscriptCutByAReconnectIsNotGivenBack() async {
    await startCall()
    wire.emit(["type": .string("localrouter.transcription.partial"), "item_id": .string("u1"), "transcript": .string("我想问")])
    await settle({ [self] in store.current.messages.contains { $0.text == "我想问" } })
    wire.drop()
    await settle({ [self] in api.wires.count == 2 })
    await confirm()
    XCTAssertTrue(given(wire).isEmpty, "nothing complete to give")
    XCTAssertEqual(store.current.messages.first?.text, "我想问", "the screen keeps it")
  }

  func testAReplyCutByTheConnectionSaysSoAndOneThePersonStoppedDoesNot() async {
    await startCall()
    created("r1")
    delta("a1", "说到一半", response: "r1")
    await settle({ [self] in voice.lastBot == "说到一半" })
    wire.drop()
    await settle({ [self] in api.wires.count == 2 })
    XCTAssertEqual(replies.first?.status, "interrupted")
    XCTAssertEqual(replies.first?.error, "连接中断，回复未说完")
    await confirm()
    // stopped by speaking over it: no error, just stopped
    created("r2")
    delta("a2", "又说到一半", response: "r2")
    await settle({ [self] in voice.lastBot == "又说到一半" })
    await voice.interrupt()
    XCTAssertEqual(replies.last?.status, "interrupted")
    XCTAssertNil(replies.last?.error)
    // stopped by hanging up: the same
    created("r3")
    delta("a3", "第三条", response: "r3")
    await settle({ [self] in voice.lastBot == "第三条" })
    await voice.stop()
    XCTAssertEqual(replies.last?.status, "interrupted")
    XCTAssertNil(replies.last?.error)
  }

  func testAReplyThatHadSaidNothingShowsNoConnectionError() async {
    await startCall()
    created("r1")
    sound()
    await settle({ [self] in audio.fed.count == 1 })
    wire.drop()
    await settle({ [self] in api.wires.count == 2 })
    XCTAssertNil(replies.first?.error, "an empty reply is not shown at all")
  }

  func testTheOutputNamesAnItemTheReplyNeverStreamedEvenIfANewerReplyWasAnnouncedFirst() async {
    await startCall()
    created("r1")
    created("r2")
    done("r1", output: [output("a9", "只在输出里")])
    await settle({ [self] in !replies.isEmpty })
    XCTAssertEqual(replies.map(\.text), ["只在输出里"])
    XCTAssertEqual(replies.first?.status, "complete")
  }

  func testACorrectionBumpsTheRowRevisionSoTheListDrawsIt() async {
    await startCall()
    created("r1")
    delta("a1", "第7段", response: "r1")
    final("a1", "第七段", response: "r1")
    done("r1", output: [])
    await settle({ [self] in replies.first?.text == "第七段" })
    XCTAssertEqual(replies.first?.revision, 1)
  }

  // MARK: Late events

  func testLateEventsOfAnInterruptedReplyAreRefused() async {
    await startCall()
    created("r1")
    delta("a1", "说到一半", response: "r1")
    await settle({ [self] in voice.lastBot == "说到一半" })
    await voice.interrupt()
    created("r2")
    delta("a2", "新的回答", response: "r2")
    await settle({ [self] in voice.lastBot == "新的回答" })
    // everything the server still says about the first reply
    final("a1", "旧回答的完整版", response: "r1")
    final("a2", "错投到新回复", response: "r1")
    done("r1", status: "cancelled", output: [output("a1", "旧回答的完整版")])
    await pause()
    XCTAssertEqual(replies.map(\.text), ["说到一半", "新的回答"])
    XCTAssertEqual(replies.map(\.status), ["interrupted", "generating"])
    XCTAssertEqual(voice.lastBot, "新的回答")
    XCTAssertTrue(voice.replying, "the old reply's end did not end the new one")
  }

  func testAnEarlierRepliesLateTextCorrectsItselfAndNeverTheNewOne() async {
    await startCall()
    created("r1")
    delta("a1", "旧回答初稿", response: "r1")
    done("r1", output: [])
    await settle({ [self] in replies.first?.status == "complete" })
    created("r2")
    delta("a2", "新回答", response: "r2")
    await settle({ [self] in voice.lastBot == "新回答" })
    final("a1", "旧回答定稿", response: "r1")
    await settle({ [self] in replies.first?.text == "旧回答定稿" })
    XCTAssertEqual(replies.map(\.text), ["旧回答定稿", "新回答"])
    XCTAssertEqual(voice.lastBot, "新回答", "the page still shows the latest reply")
    // an item the call never saw, of a reply already closed, is nobody's now
    final("a9", "来路不明", response: "r1")
    final("a1", "写给别的回复", response: "r2")
    await pause()
    XCTAssertEqual(replies.map(\.text), ["旧回答定稿", "新回答"])
    XCTAssertEqual(replies.count, 2)
  }

  func testAnOldResponseDoneDoesNotEndTheReplyInFlight() async {
    await startCall()
    created("r1")
    delta("a1", "第一", response: "r1")
    created("r2")
    delta("a2", "第二", response: "r2")
    await settle({ [self] in voice.lastBot == "第二" })
    XCTAssertTrue(voice.replying)
    done("r1")
    await pause()
    XCTAssertTrue(voice.replying, "r1 finishing late does not close r2")
    XCTAssertEqual(replies.map(\.status), ["complete", "generating"])
    done("r2")
    await settle({ [self] in !voice.replying })
    XCTAssertEqual(replies.map(\.status), ["complete", "complete"])
  }

  func testAnEventForAnotherItemOfTheSameReplyIsKeptApart() async {
    await startCall()
    created("r1")
    delta("a1", "前一段", response: "r1")
    delta("a2", "后一段", response: "r1")
    final("a1", "前一段定稿", response: "r1")
    done("r1", output: [])
    await settle({ [self] in replies.first?.text == "前一段定稿" })
    XCTAssertEqual(replies.map(\.text), ["前一段定稿", "后一段"])
  }

  // MARK: Several turns, interruptions, reconnects

  func testSeveralTurnsKeepEachRepliesOwnText() async {
    await startCall()
    for turn in 1...3 {
      created("r\(turn)")
      delta("a\(turn)", "草稿\(turn)", response: "r\(turn)")
      final("a\(turn)", "定稿\(turn)", response: "r\(turn)")
      done("r\(turn)", output: [output("a\(turn)", "定稿\(turn)")])
      await settle({ [self] in replies.count == turn && replies.last?.status == "complete" })
    }
    XCTAssertEqual(replies.map(\.text), ["定稿1", "定稿2", "定稿3"])
    XCTAssertEqual(replies.map(\.status), ["complete", "complete", "complete"])
    wire.drop()
    await settle({ [self] in api.wires.count == 2 })
    await confirm()
    XCTAssertEqual(given(wire).map { $0["content"]?.array?[0]["text"]?.string ?? "" }, ["定稿1", "定稿2", "定稿3"])
  }

  func testTalkingAfterBeingInterruptedContinuesCleanly() async {
    await startCall()
    created("r1")
    delta("a1", "说到一半", response: "r1")
    await settle({ [self] in voice.lastBot == "说到一半" })
    await voice.interrupt()
    created("r2")
    delta("a2", "接着回答", response: "r2")
    final("a2", "接着回答完整版", response: "r2")
    done("r2", output: [output("a2", "接着回答完整版")])
    await settle({ [self] in replies.last?.status == "complete" })
    XCTAssertEqual(replies.map(\.text), ["说到一半", "接着回答完整版"])
    XCTAssertEqual(replies.map(\.status), ["interrupted", "complete"])
    XCTAssertFalse(voice.thinking)
    wire.drop()
    await settle({ [self] in api.wires.count == 2 })
    await confirm()
    XCTAssertEqual(given(wire).map { $0["status"]?.string ?? "-" }, ["incomplete", "completed"])
  }

  func testEventsOfALostConnectionAreIgnoredAfterTheReconnect() async {
    await startCall()
    created("r1")
    delta("a1", "旧连接上的话", response: "r1")
    await settle({ [self] in voice.lastBot == "旧连接上的话" })
    let old = wire
    old.drop()
    await settle({ [self] in api.wires.count == 2 })
    await confirm()
    old.emit(["type": .string("response.audio_transcript.done"), "item_id": .string("a1"), "response_id": .string("r1"), "transcript": .string("迟到的定稿")])
    await pause()
    XCTAssertEqual(replies.first?.text, "旧连接上的话")
    // the new connection starts a reply with the same ids and gets its own text
    created("r1")
    delta("a1", "新连接上的话", response: "r1")
    await settle({ [self] in voice.lastBot == "新连接上的话" })
    XCTAssertEqual(replies.map(\.text), ["旧连接上的话", "新连接上的话"])
  }

  // MARK: The tail of a reply

  func testSpeechArrivingAfterResponseDoneIsStillPlayedToTheEnd() async {
    await startCall()
    created("r1")
    delta("a1", "你好", response: "r1")
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "response_id": .string("r1"), "delta": .string(Data([1, 2]).base64EncodedString())])
    done("r1", output: [output("a1", "你好")])
    await settle({ [self] in replies.first?.status == "complete" })
    audio.emit(["type": .string("playback"), "active": .bool(true), "buffered_frames": .number(4800), "sample_rate": .number(24000), "rms": .number(0.2)])
    await settle({ [self] in voice.speaking })
    XCTAssertEqual(voice.status, "正在说话", "the phone is still saying it")
    // the rest of the speech comes after the reply was reported done
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "response_id": .string("r1"), "delta": .string(Data([3, 4]).base64EncodedString())])
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "response_id": .string("r1"), "delta": .string(Data([5, 6]).base64EncodedString())])
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await settle({ [self] in audio.finishes == 1 })
    XCTAssertEqual(audio.fed, [Data([1, 2]), Data([3, 4]), Data([5, 6])])
    XCTAssertEqual(audio.finishes, 1)
    XCTAssertEqual(audio.flushes, 0, "response.done did not cut the sound")
    XCTAssertEqual(replies.first?.status, "complete")
    audio.emit(["type": .string("playback"), "active": .bool(false), "buffered_frames": .number(0), "sample_rate": .number(24000), "rms": .number(0)])
    await settle({ [self] in !voice.speaking })
    await settle({ [self] in voice.status == "已就绪" })
    XCTAssertEqual(voice.status, "已就绪")
  }

  func testWithoutAnEndMarkerWhatThePlayerHoldsBackIsPlayedOut() async {
    voice.speechTailWait = 0.05
    await startCall()
    created("r1")
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "response_id": .string("r1"), "delta": .string(Data([1, 2]).base64EncodedString())])
    done("r1", output: [])
    await pause(0.02)
    XCTAssertEqual(audio.finishes, 0, "not before the wait is over")
    // more sound comes: the wait starts over
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "response_id": .string("r1"), "delta": .string(Data([3, 4]).base64EncodedString())])
    await pause(0.03)
    XCTAssertEqual(audio.finishes, 0)
    await settle({ [self] in audio.finishes == 1 })
    XCTAssertEqual(audio.finishes, 1)
    XCTAssertEqual(audio.fed.count, 2)
  }

  func testAnEndMarkerMakesTheWaitUnnecessary() async {
    voice.speechTailWait = 0.05
    await startCall()
    created("r1")
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "response_id": .string("r1"), "delta": .string(Data([1, 2]).base64EncodedString())])
    done("r1", output: [])
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await settle({ [self] in audio.finishes == 1 })
    await pause(0.15)
    XCTAssertEqual(audio.finishes, 1, "finished once, by the marker")
  }

  private func sound(_ bytes: [UInt8] = [1, 2], response: String = "r1") {
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "response_id": .string(response), "delta": .string(Data(bytes).base64EncodedString())])
  }

  func testACancelledOrFailedReplyIsNotPlayedOutAndItsHeldStartIsDropped() async {
    voice.speechTailWait = 0.05
    await startCall()
    for (index, state) in ["cancelled", "failed"].enumerated() {
      let id = "r\(index + 1)"
      created(id)
      sound(response: id)
      await settle({ [self] in audio.fed.count == index + 1 })
      done(id, status: state, output: [])
      await settle({ [self] in audio.discards == index + 1 })
      await pause(0.15)
      XCTAssertEqual(audio.finishes, 0, state)
      XCTAssertEqual(audio.discards, index + 1, "\(state): what the player held back is dropped")
    }
  }

  func testAReplyThatStoppedAtTheLengthLimitIsPlayedOutLikeACompletedOne() async {
    voice.speechTailWait = 0.05
    await startCall()
    created("r1")
    sound()
    await settle({ [self] in audio.fed.count == 1 })
    done("r1", status: "incomplete", output: [])
    await settle({ [self] in audio.finishes == 1 })
    XCTAssertEqual(audio.finishes, 1)
    XCTAssertEqual(audio.discards, 0)
  }

  func testACompletedReplyKeepsWhatThePlayerHolds() async {
    await startCall()
    created("r1")
    sound()
    await settle({ [self] in audio.fed.count == 1 })
    done("r1", output: [])
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await settle({ [self] in audio.finishes == 1 })
    XCTAssertEqual(audio.discards, 0)
  }

  func testSoundArrivingAfterAFailedEndIsNotPlayed() async {
    await startCall()
    created("r1")
    sound()
    await settle({ [self] in audio.fed.count == 1 })
    done("r1", status: "failed", output: [])
    await settle({ [self] in audio.discards == 1 })
    sound([9, 9])
    await pause(0.15)
    XCTAssertEqual(audio.fed.count, 1)
  }

  func testTheStatusComesBackAfterAFailedEndEvenWithSoundStillQueued() async {
    audio.feedDelay = 0.2
    await startCall()
    created("r1")
    sound()
    done("r1", status: "failed", output: [])
    await settle({ [self] in voice.status == "已就绪" && audio.fed.count == 1 }, timeout: 3)
    XCTAssertEqual(voice.status, "已就绪", "it does not stay on 'speaking' once the queue is empty")
  }

  func testATimerArmedBeforeANewReplyCannotTouchTheNewOne() async {
    voice.speechTailWait = 0.15
    await startCall()
    created("r1")
    sound()
    await settle({ [self] in audio.fed.count == 1 })
    done("r1", output: [])
    await pause(0.03)
    // the next reply starts before the old reply's wait is over
    created("r2")
    sound([7, 8], response: "r2")
    await settle({ [self] in audio.fed.count == 2 })
    await pause(0.3)
    XCTAssertEqual(audio.finishes, 0, "r2 is still being said: nothing finishes its audio early")
    done("r2", output: [])
    await settle({ [self] in audio.finishes == 1 })
    XCTAssertEqual(audio.finishes, 1, "r2's own wait plays it out")
  }

  func testATimerArmedOnALostConnectionDoesNothingOnTheNextOne() async {
    voice.speechTailWait = 0.15
    await startCall()
    created("r1")
    sound()
    await settle({ [self] in audio.fed.count == 1 })
    done("r1", output: [])
    await pause(0.03)
    let old = wire
    old.drop()
    await settle({ [self] in api.wires.count == 2 })
    await confirm()
    created("r1")
    sound([5, 6])
    await settle({ [self] in audio.fed.count == 2 })
    await pause(0.12)
    XCTAssertEqual(audio.finishes, 0, "the old connection's timer did not play out the new connection's audio")
  }

  func testAFreshTimerDoesNotFireOnAnOlderChunksClock() async {
    voice.speechTailWait = 0.15
    await startCall()
    created("r1")
    sound()
    done("r1", output: [])
    await pause(0.1)
    sound([3, 4])
    await pause(0.1)
    XCTAssertEqual(audio.finishes, 0, "0.2 s after the first chunk but only 0.1 s after the last")
    await settle({ [self] in audio.finishes == 1 })
    XCTAssertEqual(audio.finishes, 1)
  }

  func testATimerThatFiredBehindABusyPlayerStillChecksAgainBeforePlaying() async {
    audio.feedDelay = 0.3
    voice.speechTailWait = 0.05
    await startCall()
    created("r1")
    sound()
    done("r1", output: [])
    // the wait is over while the first chunk is still being handed over, so the play-out is queued behind it
    await pause(0.15)
    created("r2")
    sound([7, 8], response: "r2")
    done("r2", output: [])
    await settle({ [self] in audio.fed.count == 2 }, timeout: 3)
    await settle({ [self] in audio.finishes >= 1 }, timeout: 3)
    await pause(0.4)
    XCTAssertEqual(audio.finishes, 1, "r1's queued play-out saw a newer reply and did nothing; r2's own wait played it out once")
  }

  func testATimerThatFiredBehindABusyPlayerDoesNothingAfterAReconnect() async {
    audio.feedDelay = 0.3
    voice.speechTailWait = 0.05
    await startCall()
    created("r1")
    sound()
    done("r1", output: [])
    await pause(0.15)
    wire.drop()
    await settle({ [self] in api.wires.count == 2 })
    await confirm()
    await pause(0.6)
    XCTAssertEqual(audio.finishes, 0, "the lost connection's leftovers were not played out on the new one")
  }

  func testBargingInStopsTheWaitForTheTail() async {
    voice.speechTailWait = 0.3
    await startCall()
    created("r1")
    wire.emit(["type": .string("response.audio.delta"), "item_id": .string("a1"), "response_id": .string("r1"), "delta": .string(Data([1, 2]).base64EncodedString())])
    await settle({ [self] in audio.fed.count == 1 })
    done("r1", output: [])
    await pause(0.05)
    await voice.interrupt()
    await pause(0.45)
    XCTAssertEqual(audio.finishes, 0, "what was cut is not played out")
  }

  // MARK: Where the voice is in the words

  /// One second of sound at 24 kHz (pcm16, mono), sent as the next chunk of the reply.
  private func second(_ response: String = "r1") {
    wire.emit([
      "type": .string("response.audio.delta"), "item_id": .string("a1"), "response_id": .string(response),
      "delta": .string(Data(count: 48000).base64EncodedString()),
    ])
  }

  private func playing(buffered: Int, active: Bool = true) {
    audio.emit([
      "type": .string("playback"), "active": .bool(active), "buffered_frames": .number(Double(buffered)),
      "sample_rate": .number(24000), "rms": .number(active ? 0.2 : 0),
    ])
  }

  func testThereIsNothingToFollowBeforeThePlayerHasStartedOnTheReply() async {
    await startCall()
    created("r1")
    delta("a1", "你好你好。", response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    XCTAssertNil(voice.speechProgress, "sound is queued but nothing has been heard")
  }

  func testTheTimePlayedIsWhatArrivedLessWhatIsStillWaiting() async throws {
    await startCall()
    created("r1")
    delta("a1", "你好你好。", response: "r1")
    second()
    second()
    await settle({ [self] in audio.fed.count == 2 })
    playing(buffered: 36000)
    await settle({ [self] in voice.speaking })
    let p = try XCTUnwrap(voice.speechProgress)
    XCTAssertEqual(p.played, 0.5, accuracy: 0.001, "two seconds arrived, 1.5 are still in the player")
    XCTAssertTrue(p.live)
    XCTAssertFalse(p.cut)
    XCTAssertNil(p.total, "more sound may still come")
    playing(buffered: 12000)
    await pause(0.05)
    XCTAssertEqual(try XCTUnwrap(voice.speechProgress).played, 1.5, accuracy: 0.001)
  }

  func testTheLengthOfTheSoundIsKnownOnceItIsAllHere() async throws {
    await startCall()
    created("r1")
    delta("a1", "你好你好。", response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    playing(buffered: 24000)
    await settle({ [self] in voice.speaking })
    XCTAssertNil(voice.speechProgress?.total)
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    done("r1", output: [output("a1", "你好你好。")])
    await settle({ [self] in voice.speechProgress?.total != nil })
    XCTAssertEqual(try XCTUnwrap(voice.speechProgress?.total), 1, accuracy: 0.001)
  }

  func testAFinishedReplyIsNotFollowedAndANewReplyStartsFromNothing() async throws {
    await startCall()
    created("r1")
    delta("a1", "你好你好。", response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    playing(buffered: 24000)
    await settle({ [self] in voice.speaking })
    // the reply ends and its sound is out (a reply still being made would be waiting for more sound, and is followed)
    done("r1", output: [output("a1", "你好你好。")])
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    playing(buffered: 0, active: false)
    await settle({ [self] in !voice.speaking })
    await settle({ [self] in voice.speechProgress?.live == false })
    let p = try XCTUnwrap(voice.speechProgress)
    XCTAssertFalse(p.live)
    XCTAssertFalse(p.cut)
    XCTAssertEqual(p.played, 1, accuracy: 0.001)
    XCTAssertNil(p.position(in: SpokenText("你好你好。")), "said to the end: nothing marked")
    // pressing to talk after it ended is not a cut
    await voice.interrupt()
    XCTAssertEqual(voice.speechProgress?.cut, false)
    created("r2")
    await settle({ [self] in voice.speechProgress == nil })
    XCTAssertNil(voice.speechProgress, "the new reply has no words and no sound yet")
  }

  func testACutReplyKeepsThePlaceItHadReachedUntilTheNextReplyBegins() async throws {
    await startCall()
    created("r1")
    delta("a1", "你好你好。", response: "r1")
    second()
    second()
    await settle({ [self] in audio.fed.count == 2 })
    playing(buffered: 36000)
    await settle({ [self] in voice.speaking })
    await voice.interrupt()
    let p = try XCTUnwrap(voice.speechProgress)
    XCTAssertTrue(p.cut)
    XCTAssertFalse(p.live)
    XCTAssertEqual(p.played, 0.5, accuracy: 0.001)
    // what the player does afterwards does not move it
    playing(buffered: 0, active: false)
    await pause(0.05)
    XCTAssertEqual(try XCTUnwrap(voice.speechProgress).played, 0.5, accuracy: 0.001)
    XCTAssertEqual(voice.speechProgress?.cut, true)
    created("r2")
    await settle({ [self] in voice.speechProgress == nil })
    XCTAssertNil(voice.speechProgress)
  }

  func testALostConnectionAlsoLeavesTheMarkWhereTheVoiceStopped() async throws {
    await startCall()
    created("r1")
    delta("a1", "你好你好。", response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    playing(buffered: 12000)
    await settle({ [self] in voice.speaking })
    wire.drop()
    await settle({ [self] in voice.speechProgress?.cut == true })
    XCTAssertEqual(try XCTUnwrap(voice.speechProgress).played, 0.5, accuracy: 0.001)
  }

  func testAVoiceThatSpeaksFasterThanTheStartingPaceIsLearnedForTheNextReply() async throws {
    await startCall()
    // "你好你好" weighs 4 units and its sound is one second long: a pace of 0.25 s a unit
    created("r1")
    delta("a1", "你好你好", response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    playing(buffered: 24000)
    await settle({ [self] in voice.speaking })
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await settle({ [self] in voice.speechProgress?.total != nil })
    done("r1", output: [output("a1", "你好你好")])
    playing(buffered: 0, active: false)
    await settle({ [self] in !voice.speaking })
    created("r2")
    delta("a2", "再来一句", response: "r2")
    second("r2")
    await settle({ [self] in audio.fed.count == 2 })
    playing(buffered: 24000)
    await settle({ [self] in voice.speaking })
    XCTAssertEqual(try XCTUnwrap(voice.speechProgress).pace, 0.25, accuracy: 0.001, "r2 starts from what r1 showed")
  }

  // MARK: A reply the sound of which ends in parts

  private var twoParagraphs: String { String(repeating: "一二三四五六七八九十", count: 4) + "。\n\n" + String(repeating: "上下左右前后东西南北", count: 4) + "。" }

  /// What the lit edge says right now for the reply on screen (the estimate before any smoothing).
  private func estimate() -> Double? {
    voice.speechProgress?.position(in: SpokenText(voice.lastBot))
  }

  func testAnEndMarkerForOnlyTheFirstParagraphDoesNotMakeTheEdgeLeap() async throws {
    await startCall()
    created("r1")
    delta("a1", twoParagraphs, response: "r1")
    // the first paragraph's sound arrives (8 s), and 4 s of it have been played
    second()
    second()
    second()
    second()
    second()
    second()
    second()
    second()
    await settle({ [self] in audio.fed.count == 8 })
    playing(buffered: 4 * 24000)
    await settle({ [self] in voice.speaking })
    let before = try XCTUnwrap(estimate())
    // the server says the sound of its first part is done (the reply itself is not: its second paragraph is still being made)
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1"), "content_index": .number(0)])
    await pause(0.1)
    let after = try XCTUnwrap(estimate())
    XCTAssertEqual(after, before, accuracy: 1, "a part's end says nothing about how long the whole reply's sound is")
    XCTAssertNil(voice.speechProgress?.total)
  }

  func testTheSoundIsTakenAsCompleteOnlyWhenTheReplyHasEndedAndMarkedItsEnd() async throws {
    await startCall()
    created("r1")
    delta("a1", twoParagraphs, response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    playing(buffered: 12000)
    await settle({ [self] in voice.speaking })
    done("r1", output: [output("a1", twoParagraphs)])
    await pause(0.1)
    XCTAssertNil(voice.speechProgress?.total, "the reply ended but its sound has not said so")
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await settle({ [self] in voice.speechProgress?.total != nil })
    XCTAssertEqual(try XCTUnwrap(voice.speechProgress?.total), 1, accuracy: 0.001)
  }

  func testSoundThatComesAfterTheEndWasTakenRevokesIt() async throws {
    await startCall()
    created("r1")
    delta("a1", twoParagraphs, response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    playing(buffered: 12000)
    await settle({ [self] in voice.speaking })
    done("r1", output: [output("a1", twoParagraphs)])
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await settle({ [self] in voice.speechProgress?.total != nil })
    // the next paragraph's sound arrives after all
    second()
    await settle({ [self] in audio.fed.count == 2 })
    XCTAssertNil(voice.speechProgress?.total, "it was not complete")
  }

  func testTheEndMarkerBeforeTheReplyEndsStillCountsOnceTheReplyEnds() async throws {
    await startCall()
    created("r1")
    delta("a1", twoParagraphs, response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    playing(buffered: 12000)
    await settle({ [self] in voice.speaking })
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await pause(0.05)
    XCTAssertNil(voice.speechProgress?.total)
    done("r1", output: [output("a1", twoParagraphs)])
    await settle({ [self] in voice.speechProgress?.total != nil })
    XCTAssertEqual(try XCTUnwrap(voice.speechProgress?.total), 1, accuracy: 0.001)
  }

  func testAReplyThatWasRevokedDoesNotTeachTheNextOneAWrongPace() async throws {
    await startCall()
    created("r1")
    delta("a1", twoParagraphs, response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    playing(buffered: 12000)
    await settle({ [self] in voice.speaking })
    done("r1", output: [output("a1", twoParagraphs)])
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await settle({ [self] in voice.speechProgress?.total != nil })
    // more sound: the first reading of the sound's length (1 s for 90 characters) was wrong
    for _ in 0..<17 { second() }
    await settle({ [self] in audio.fed.count == 18 })
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await settle({ [self] in voice.speechProgress?.total != nil })
    playing(buffered: 0, active: false)
    await settle({ [self] in !voice.speaking })
    created("r2")
    delta("a2", "再来一句话", response: "r2")
    second("r2")
    await settle({ [self] in audio.fed.count == 19 })
    playing(buffered: 12000)
    await settle({ [self] in voice.speaking })
    let words = SpokenText(twoParagraphs)
    XCTAssertEqual(try XCTUnwrap(voice.speechProgress).pace, 18 / words.totalWeight, accuracy: 0.002, "18 s for those words, not 1 s")
  }

  func testTheTraceTellsWhatHappenedToTheSoundAndTheWords() async {
    var lines: [String] = []
    voice.traceSink = { lines.append($0) }
    await startCall()
    created("r1")
    delta("a1", "你好你好", response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    playing(buffered: 12000)
    await settle({ [self] in voice.speaking })
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1"), "content_index": .number(0)])
    done("r1", output: [output("a1", "你好你好")])
    await settle({ [self] in voice.speechTrace.contains { $0.contains("all sound taken as arrived") } })
    let trace = voice.speechTrace.joined(separator: "\n")
    for expected in ["=== call start", "created reply=", "text item=", "audio ", "player started", "marker localrouter.response.speech_done", "part=0", "response.done", "all sound taken as arrived"] {
      XCTAssertTrue(trace.contains(expected), "the trace has \(expected): \(trace)")
    }
    XCTAssertEqual(lines, voice.speechTrace, "the sink gets every line")
    XCTAssertFalse(trace.contains("你好"), "no words in the trace")
  }

  // MARK: A reply the server failed, and what is learned of a voice

  func testAReplyTheServerFailedKeepsTheMarkWhereTheSoundRanOut() async throws {
    await startCall()
    created("r1")
    delta("a1", twoParagraphs, response: "r1")
    for _ in 0..<3 { second() }
    await settle({ [self] in audio.fed.count == 3 })
    playing(buffered: 24000)
    await settle({ [self] in voice.speaking })
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    done("r1", status: "failed")
    await settle({ [self] in replies.first?.status == "interrupted" })
    // the sound that was already there plays out, then stops
    playing(buffered: 0, active: false)
    await settle({ [self] in !voice.speaking })
    let p = try XCTUnwrap(voice.speechProgress, "the words are not turned back into plain text")
    XCTAssertTrue(p.cut)
    XCTAssertFalse(p.live)
    XCTAssertEqual(p.played, 3, accuracy: 0.001, "all the sound there was")
    XCTAssertLessThan(try XCTUnwrap(p.position(in: SpokenText(voice.lastBot))), Double(SpokenText(twoParagraphs).clusters.count) / 2, "well short of the end of the words")
  }

  func testTheMarkStaysWhereTheSoundStoppedWhileTheServerIsStillMakingTheReply() async throws {
    await startCall()
    created("r1")
    delta("a1", twoParagraphs, response: "r1")
    for _ in 0..<3 { second() }
    await settle({ [self] in audio.fed.count == 3 })
    playing(buffered: 24000)
    await settle({ [self] in voice.speaking })
    // the sound ran dry, the reply is not over: the voice is waiting, the words are not turned plain
    playing(buffered: 0, active: false)
    await settle({ [self] in !voice.speaking })
    let waiting = try XCTUnwrap(voice.speechProgress, "a stall is not the end of the reply")
    XCTAssertTrue(waiting.live)
    XCTAssertFalse(waiting.cut)
    XCTAssertEqual(waiting.played, 3, accuracy: 0.001)
    XCTAssertNotNil(waiting.position(in: SpokenText(voice.lastBot)))
    // when the reply does end and the sound is out, the words are plain again
    done("r1", output: [output("a1", twoParagraphs)])
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await settle({ [self] in voice.speechProgress?.live == false })
    XCTAssertNil(voice.speechProgress?.position(in: SpokenText(voice.lastBot)))
  }

  func testTheServersSpeechErrorKeepsTheMarkFromThatMomentNotFromTheReplyEnd() async throws {
    await startCall()
    created("r1")
    delta("a1", twoParagraphs, response: "r1")
    for _ in 0..<3 { second() }
    await settle({ [self] in audio.fed.count == 3 })
    playing(buffered: 24000)
    await settle({ [self] in voice.speaking })
    playing(buffered: 0, active: false)
    await settle({ [self] in !voice.speaking })
    // the error arrives a moment before `response.done`; the words must not be plain in between
    wire.emit(["type": .string("error"), "error": .object(["code": .string("speech_failed"), "message": .string("x")])])
    await settle({ [self] in voice.error != nil })
    let p = try XCTUnwrap(voice.speechProgress)
    XCTAssertTrue(p.cut)
    XCTAssertFalse(p.live)
    XCTAssertEqual(p.played, 3, accuracy: 0.001)
  }

  func testWhatAVoiceShowedOfItsSpeedIsKeptForTheNextCall() async throws {
    await startCall()
    created("r1")
    delta("a1", "你好你好", response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    playing(buffered: 24000)
    await settle({ [self] in voice.speaking })
    done("r1", output: [output("a1", "你好你好")])
    wire.emit(["type": .string("localrouter.response.speech_done"), "response_id": .string("r1")])
    await settle({ [self] in voice.speechProgress?.total != nil })
    await voice.stop()
    XCTAssertTrue(voice.paceDefaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("speechPace.") })
    // the next call starts from it
    await startCall()
    XCTAssertEqual(voice.carriedSpeechPace, 0.25, accuracy: 0.001, "1 s for four characters")
  }

  func testTheServersErrorsAndLongSilencesAreInTheTrace() async {
    await startCall()
    created("r1")
    delta("a1", "你好你好", response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    wire.emit(["type": .string("error"), "error": .object(["code": .string("speech_failed"), "message": .string("tts upstream timed out")])])
    await settle({ [self] in voice.speechTrace.contains { $0.contains("error event") } })
    wire.emit([
      "type": .string("response.done"),
      "response": .object(["id": .string("r1"), "status": .string("failed"), "output": .array([]), "status_details": .object(["type": .string("failed"), "error": .object(["code": .string("tts_timeout"), "message": .string("no sound for 8 s")])])]),
    ])
    await settle({ [self] in voice.speechTrace.contains { $0.contains("reply failed") } })
    let trace = voice.speechTrace.joined(separator: "\n")
    XCTAssertTrue(trace.contains("error event: type=- code=speech_failed message=tts upstream timed out"), trace)
    XCTAssertTrue(trace.contains("reply failed: type=failed") && trace.contains("tts_timeout") && trace.contains("no sound for 8 s"), trace)
  }

  func testSoundThatComesAfterALongSilenceIsNoted() async {
    var now = Date(timeIntervalSince1970: 5000)
    voice = VoiceSession(store: store, audio: audio, now: { now })
    voice.paceDefaults = UserDefaults(suiteName: "voice-tests-" + UUID().uuidString) ?? .standard
    store.voice = voice
    await startCall()
    created("r1")
    delta("a1", "你好你好", response: "r1")
    second()
    await settle({ [self] in audio.fed.count == 1 })
    now = now.addingTimeInterval(7.2)
    second()
    await settle({ [self] in audio.fed.count == 2 })
    XCTAssertTrue(voice.speechTrace.contains { $0.contains("sound came again after 7.2s without any") }, voice.speechTrace.joined(separator: "\n"))
  }

  func testTheHeartbeatTellsASilentServerFromABusyPhone() async {
    var now = Date(timeIntervalSince1970: 9000)
    voice = VoiceSession(store: store, audio: audio, now: { now })
    voice.paceDefaults = UserDefaults(suiteName: "voice-tests-" + UUID().uuidString) ?? .standard
    store.voice = voice
    await startCall()
    created("r1")
    delta("a1", "你好", response: "r1")
    await settle({ [self] in voice.lastBot == "你好" })
    // the server says nothing for 5 s while the reply is still being made
    now = now.addingTimeInterval(5)
    await settle({ [self] in voice.speechTrace.contains { $0.contains("heartbeat") } }, timeout: 3)
    let line = voice.speechTrace.first { $0.contains("heartbeat") } ?? ""
    XCTAssertTrue(line.contains("server silent for 5.0s (reply still being made)"), line)
    XCTAssertTrue(line.contains("this check ran 4.0s late") || line.contains("this check ran"), line)
  }
}
