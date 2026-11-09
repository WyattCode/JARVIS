import XCTest

@testable import JarvisCore

/// A reply's words laid against its sound: what the marks become, how long each character takes, and how far a time has got.
final class SpokenTextTests: XCTestCase {
  private let universe =
    "这个问题挺有意思的，得分两层看。第一层是**可观测宇宙**，也就是光从大爆炸到现在来得及传给我们那部分。它的直径大约是930亿光年。这个数字看着矛盾——宇宙才138亿岁，怎么能有930亿光年？因为空间本身在膨胀。"

  private func shown(_ t: SpokenText, _ range: Range<Int>) -> String {
    String(decoding: Array(t.plain.utf16)[range], as: UTF16.self)
  }

  func testBoldMarksAreShownAsWeightNotAsStars() {
    let t = SpokenText(universe)
    XCTAssertFalse(t.plain.contains("*"))
    XCTAssertEqual(t.bold.count, 1)
    let u = Array(t.plain.utf16)
    XCTAssertEqual(String(decoding: u[t.bold[0]], as: UTF16.self), "可观测宇宙")
  }

  func testABoldMarkStillWaitingForItsPartnerAlreadyBoldsWhatFollows() {
    let t = SpokenText("第一层是**可观测")
    XCTAssertEqual(t.plain, "第一层是可观测")
    let u = Array(t.plain.utf16)
    XCTAssertEqual(String(decoding: u[t.bold[0]], as: UTF16.self), "可观测")
  }

  func testHeadingsListsCodeAndLinksLoseTheirMarks() {
    let t = SpokenText("## 步骤\n- 先装 `swift`\n* 再看[文档](https://x.y/z)\n```\nlet a = 1\n```\n结束")
    XCTAssertEqual(t.plain, "步骤\n· 先装 swift\n· 再看文档\nlet a = 1\n结束")
    XCTAssertEqual(t.bold.count, 1, "the heading is set heavy")
    let u = Array(t.plain.utf16)
    XCTAssertEqual(String(decoding: u[t.bold[0]], as: UTF16.self), "步骤")
  }

  func testAStarBetweenSpacesIsASignAndStays() {
    XCTAssertEqual(SpokenText("2 * 3 等于 6。").plain, "2 * 3 等于 6。")
  }

  func testPlainTextPassesThroughAndEmptyTextHasNothingToFollow() {
    XCTAssertEqual(SpokenText("你好。").plain, "你好。")
    XCTAssertTrue(SpokenText("").isEmpty)
    XCTAssertFalse(SpokenText(" ").isEmpty)
    XCTAssertEqual(SpokenText(" \n ").totalWeight, 2, accuracy: 0.001, "a line break is a pause, blanks are nothing")
  }

  func testTheCharactersCoverAllOfTheTextWithoutGapsOrOverlap() {
    let t = SpokenText(universe + "😀 e\u{301}")
    XCTAssertEqual(t.clusters.first?.lowerBound, 0)
    XCTAssertEqual(t.clusters.last?.upperBound, t.plain.utf16.count)
    for (a, b) in zip(t.clusters, t.clusters.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }
    XCTAssertEqual(shown(t, t.clusters[t.clusters.count - 1]), "e\u{301}", "a letter with its accent is one character")
  }

  func testNumbersAndPausesTakeTimeAndMarksTakeNone() {
    let plain = SpokenText("你好吗")
    let pause = SpokenText("你好吗。")
    let digits = SpokenText("你好930")
    XCTAssertEqual(plain.totalWeight, 3, accuracy: 0.001)
    XCTAssertGreaterThan(pause.totalWeight, plain.totalWeight + 2, "a full stop is a pause")
    XCTAssertGreaterThan(digits.totalWeight, plain.totalWeight, "a number is said in words")
    XCTAssertEqual(SpokenText("你好吗？！？").totalWeight, SpokenText("你好吗？").totalWeight, "a run of marks is one pause")
    XCTAssertEqual(SpokenText("**你好吗**").totalWeight, plain.totalWeight, "marks are not said")
  }

  func testThePositionIsHowManyCharactersHaveBeenSaidWithThePartOfTheOneBeingSaid() throws {
    let t = SpokenText("一二三四五")
    XCTAssertEqual(try XCTUnwrap(t.position(at: 0, pace: 0.2)), 0, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(t.position(at: 0.2, pace: 0.2)), 1, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(t.position(at: 0.5, pace: 0.2)), 2.5, accuracy: 0.001, "half way through the third")
    XCTAssertEqual(try XCTUnwrap(t.position(at: 1.0, pace: 0.2)), 5, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(t.position(at: 50, pace: 0.2)), 5, "past the end: everything is said")
    XCTAssertEqual(try XCTUnwrap(t.position(at: -3, pace: 0.2)), 0)
  }

  func testThereIsNoPositionWithoutWordsOrAPace() {
    XCTAssertNil(SpokenText("").position(at: 1, pace: 0.2))
    XCTAssertNil(SpokenText("你好").position(at: 1, pace: 0))
    XCTAssertNil(SpokenText("你好").position(at: .nan, pace: 0.2))
    XCTAssertNil(SpokenText("你好").position(at: .infinity, pace: 0.2), "an unbounded time is not a place")
  }

  func testTheVoiceRestsOnAFullStopForTheLengthOfThePause() throws {
    let t = SpokenText("你好。再见")
    // 你 0–0.2, 好 0.2–0.4, 。 0.4–0.9 (2.5 units), 再 0.9–1.1 ...
    XCTAssertEqual(try XCTUnwrap(t.position(at: 0.4, pace: 0.2)), 2, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(t.position(at: 0.65, pace: 0.2)), 2.5, accuracy: 0.001, "half way through the stop's pause")
    XCTAssertEqual(try XCTUnwrap(t.position(at: 0.9, pace: 0.2)), 3, accuracy: 0.001)
  }

  func testBlanksTakeNoTimeAndArePassedOver() throws {
    let t = SpokenText("你  好")
    XCTAssertEqual(try XCTUnwrap(t.position(at: 0.2, pace: 0.2)), 3, accuracy: 0.001, "after 你 comes the blank, which takes nothing, so 好 is next")
  }

  func testThePositionNeverGoesBackAsTheTimeGoesOn() throws {
    let t = SpokenText(universe)
    let pace = t.pace(forTotal: 42)
    XCTAssertEqual(pace * t.totalWeight, 42, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(t.position(at: 42, pace: pace)), Double(t.clusters.count), accuracy: 0.001, "the end of the sound is the end of the words")
    var last = -1.0
    for step in 0...420 {
      let p = try XCTUnwrap(t.position(at: Double(step) * 0.1, pace: pace))
      XCTAssertGreaterThanOrEqual(p, last)
      last = p
    }
  }

  func testAPaceNobodyCouldSpeakAtIsNotBelieved() {
    let t = SpokenText("你好。")
    XCTAssertEqual(t.pace(forTotal: 0.0001), SpokenText.paceRange.lowerBound)
    XCTAssertEqual(t.pace(forTotal: 500), SpokenText.paceRange.upperBound)
    XCTAssertEqual(t.pace(forTotal: 0), SpokenText.defaultPace)
    XCTAssertEqual(SpokenText("").pace(forTotal: 5), SpokenText.defaultPace)
  }

  func testProgressFollowsOnlyAReplyThatIsBeingSaidOrWasCut() throws {
    let t = SpokenText("一二三。四五六。")
    var p = SpeechProgress(played: 0.4 - SpeechProgress.lead, total: nil, pace: 0.2, live: true, cut: false)
    XCTAssertEqual(try XCTUnwrap(p.position(in: t)), 2, accuracy: 0.001)
    p.live = false
    XCTAssertNil(p.position(in: t), "said to the end: nothing is marked any more")
    p.cut = true
    p.played = 0.4 - SpeechProgress.lead
    XCTAssertEqual(try XCTUnwrap(p.position(in: t)), 2, accuracy: 0.001, "a cut reply keeps its place")
  }

  func testOnceAllTheSoundIsHereItsLengthDecidesTheWordsNotTheOldPace() throws {
    let t = SpokenText("一二三。四五六。")
    // 11 units in all. At the old pace (0.2 s a unit) the voice (a second in, with the lead) is in the first sentence's stop. The sound turns out to be only
    // 1.6 s long, so the same moment is already well into the second sentence.
    let moment = 1.0 - SpeechProgress.lead
    let before = SpeechProgress(played: moment, total: nil, pace: 0.2, live: true, cut: false)
    let after = SpeechProgress(played: moment, total: 1.6, pace: 0.2, live: true, cut: false)
    XCTAssertLessThan(try XCTUnwrap(before.position(in: t)), 4)
    XCTAssertGreaterThan(try XCTUnwrap(after.position(in: t)), 4)
  }

  // MARK: The edge never jumps

  func testTheFirstEstimateOfAReplyIsTakenAsItIs() {
    var edge = ReadingEdge()
    XCTAssertEqual(edge.advance(to: 120, now: 5), 120, "a page opened in the middle of a reply starts where the voice is")
  }

  func testTheEdgeMovesOnNoFasterThanAQuickSpeaker() {
    var edge = ReadingEdge()
    _ = edge.advance(to: 100, now: 0)
    // the estimate leaps 200 characters ahead (a wrong pace, a marker that came too early): the edge does not follow at once
    XCTAssertEqual(edge.advance(to: 300, now: 0.5), 100 + ReadingEdge.maxSpeed * 0.5, accuracy: 0.001)
    XCTAssertEqual(edge.advance(to: 300, now: 1.0), 100 + ReadingEdge.maxSpeed * 1.0, accuracy: 0.001)
    XCTAssertEqual(edge.advance(to: 118, now: 1.5), 118, "it stops at the estimate when it gets there")
  }

  func testTheEdgeNeverGoesBackAndWaitsForTheVoiceToCatchUp() {
    var edge = ReadingEdge()
    _ = edge.advance(to: 100, now: 0)
    XCTAssertEqual(edge.advance(to: 80, now: 0.5), 100, "an estimate that fell back does not unlight what was lit")
    XCTAssertEqual(edge.advance(to: 100.5, now: 1.0), 100.5, accuracy: 0.001)
  }

  func testAPageThatWasAwayStartsOverAtTheEstimate() {
    var edge = ReadingEdge()
    _ = edge.advance(to: 10, now: 0)
    XCTAssertEqual(edge.advance(to: 400, now: 30), 400, "after half a minute away the catching up is not drawn")
  }

  func testAResetStartsTheNextReplyAtItsEstimate() {
    var edge = ReadingEdge()
    _ = edge.advance(to: 200, now: 0)
    edge.reset()
    XCTAssertNil(edge.value)
    XCTAssertEqual(edge.advance(to: 3, now: 0.1), 3)
  }

  func testACutReplyKeepsTheEdgeWhereItWasDrawn() {
    var edge = ReadingEdge()
    _ = edge.advance(to: 50, now: 0)
    XCTAssertEqual(edge.freeze(at: 90), 50, "the person saw it at 50: that is where the voice stopped for them")
    var fresh = ReadingEdge()
    XCTAssertEqual(fresh.freeze(at: 90), 90, "nothing was drawn yet: the estimate")
  }

  func testTheEdgeIsPlacedALittleAheadOfTheSoundSoItLooksLevelWithTheVoice() throws {
    let t = SpokenText("一二三四五六七八九十")
    let p = SpeechProgress(played: 1, total: nil, pace: 0.2, live: true, cut: false)
    XCTAssertEqual(try XCTUnwrap(p.position(in: t)), (1 + SpeechProgress.lead) / 0.2, accuracy: 0.001)
  }

  // MARK: Rests

  /// 16-bit samples at 24 kHz: a loud tone for `loud` seconds, or silence.
  private func sound(_ seconds: Double, loud: Bool) -> Data {
    var data = Data()
    for i in 0..<Int(seconds * 24000) {
      let value: Int16 = loud ? Int16(8000 * sin(Double(i) * 0.3)) : 0
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  func testARestInTheSoundIsFoundWhereItBeginsAndHowLongItLasts() {
    var rests = SoundRests(rate: 24000)
    var found = rests.add(sound(1.0, loud: true))
    found += rests.add(sound(0.4, loud: false))
    XCTAssertTrue(found.isEmpty, "a rest is over only when sound comes after it")
    found += rests.add(sound(0.5, loud: true))
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found[0].at, 1.0, accuracy: 0.03)
    XCTAssertEqual(found[0].length, 0.4, accuracy: 0.03)
  }

  func testAShortGapAndTheSilenceAtTheEndAreNotRests() {
    var rests = SoundRests(rate: 24000)
    var found = rests.add(sound(0.5, loud: true))
    found += rests.add(sound(0.08, loud: false))
    found += rests.add(sound(0.5, loud: true))
    found += rests.add(sound(2, loud: false))
    XCTAssertTrue(found.isEmpty)
  }

  func testARestIsFoundWhateverHowTheSoundIsCutIntoChunks() {
    var whole = SoundRests(rate: 24000)
    var pieces = SoundRests(rate: 24000)
    var all = sound(0.7, loud: true)
    all.append(sound(0.3, loud: false))
    all.append(sound(0.6, loud: true))
    let expected = whole.add(all)
    var found: [SoundRests.Rest] = []
    var at = 0
    // Chunks of 1001 bytes, so a sample is cut in two as well.
    while at < all.count {
      let end = min(at + 1001, all.count)
      found += pieces.add(all.subdata(in: at..<end))
      at = end
    }
    XCTAssertEqual(found, expected)
    XCTAssertEqual(expected.count, 1)
  }

  func testTheWordsSayWhereTheVoiceRestsAtTheEndOfASentence() throws {
    let t = SpokenText("一二三。四五，六七八！")
    let rests = t.sentenceRests(pace: 0.2)
    XCTAssertEqual(rests.count, 2, "a comma is a shorter rest and is not listed")
    XCTAssertEqual(rests[0].at, 3 * 0.2, accuracy: 1e-9)
    XCTAssertEqual(rests[0].length, 2.5 * 0.2, accuracy: 1e-9)
    XCTAssertEqual(rests[1].at, (3 + 2.5 + 2 + 1.2 + 3) * 0.2, accuracy: 1e-9)
  }

  // MARK: Words set against the rests of the sound

  /// Three sentences of ten characters each: at 0.2 s a unit the words put the rests at 2.0, 4.5 and 7.0 s, 0.5 s long.
  private let threeSentences = "一二三四五六七八九十。一二三四五六七八九十。一二三四五六七八九十。"
  private func rest(_ at: Double, _ length: Double = 0.5) -> SoundRests.Rest { SoundRests.Rest(at: at, length: length) }

  func testWithoutRestsThePlaceIsTheOneTheWordsGive() {
    let t = SpokenText(threeSentences)
    for s in stride(from: 0.0, through: 9.0, by: 0.7) {
      XCTAssertEqual(try XCTUnwrap(t.position(at: s, pace: 0.2, rests: [])), try XCTUnwrap(t.position(at: s, pace: 0.2)), accuracy: 1e-9)
    }
  }

  func testAVoiceThatPausesLaterThanTheWordsSayIsNotRunAheadOf() {
    let t = SpokenText(threeSentences)
    // the voice pauses 0.6 s later than the words say, each time
    let rests = [rest(2.6), rest(5.7), rest(8.8)]
    // the words alone are on the full stop's second half by now; set against the rest, it is at the stop
    XCTAssertGreaterThan(try XCTUnwrap(t.position(at: 2.6, pace: 0.2)), 10.5)
    XCTAssertEqual(try XCTUnwrap(t.position(at: 2.6, pace: 0.2, rests: rests)), 10, accuracy: 0.01)
    // and when the rest is over, the words go on from the first character after the stop
    XCTAssertEqual(try XCTUnwrap(t.position(at: 3.1, pace: 0.2, rests: rests)), 11, accuracy: 0.05)
  }

  func testTheEdgeNeverGoesBackWhenRestsAreSet() throws {
    let t = SpokenText(threeSentences)
    let rests = [rest(2.4), rest(5.0, 0.6), rest(9.0)]
    var last = -1.0
    for s in stride(from: 0.0, through: 10.0, by: 0.05) {
      let p = try XCTUnwrap(t.position(at: s, pace: 0.2, rests: rests))
      XCTAssertGreaterThanOrEqual(p, last - 1e-9, "went back at \(s)")
      last = p
    }
  }

  func testABreathIsNotTheEndOfASentence() {
    let t = SpokenText(threeSentences)
    XCTAssertEqual(t.alignedPauses(pace: 0.2, rests: [rest(2.6, 0.2), rest(5.7, 0.25)]).matched, 0)
    XCTAssertEqual(try XCTUnwrap(t.position(at: 2.6, pace: 0.2, rests: [rest(2.6, 0.2)])), try XCTUnwrap(t.position(at: 2.6, pace: 0.2)), accuracy: 1e-9)
  }

  func testARestFarFromWhereTheWordsPutItIsNotTheirSentenceEnd() {
    let t = SpokenText(threeSentences)
    XCTAssertEqual(t.alignedPauses(pace: 0.2, rests: [rest(3.25)]).matched, 0, "1.25 s from the first sentence end and from the second")
    XCTAssertEqual(t.alignedPauses(pace: 0.2, rests: [rest(10.5)]).matched, 0)
    let found = t.alignedPauses(pace: 0.2, rests: [rest(2.6), rest(7.5)])
    XCTAssertEqual(found.of, 3)
    XCTAssertEqual(found.matched, 2)
  }

  func testAFalseMatchAtAnImpossibleSpeedIsLeftOut() {
    let t = SpokenText(threeSentences)
    // the second rest would make the second sentence last 0.8 s of sound for 2.0 s of words
    XCTAssertEqual(t.alignedPauses(pace: 0.2, rests: [rest(2.0), rest(3.3)]).matched, 1)
  }

  func testTheCountsAreForTheTraceAndTheTextWithoutPausesHasNone() {
    let t = SpokenText("没有句号的一段话")
    XCTAssertEqual(t.alignedPauses(pace: 0.2, rests: [rest(2.0)]).matched, 0)
    XCTAssertEqual(t.alignedPauses(pace: 0.2, rests: [rest(2.0)]).of, 0)
    XCTAssertEqual(try XCTUnwrap(t.position(at: 1.0, pace: 0.2, rests: [rest(2.0)])), try XCTUnwrap(t.position(at: 1.0, pace: 0.2)), accuracy: 1e-9)
  }

  func testTheSpeechProgressPlacesTheWordsByItsRests() {
    let t = SpokenText(threeSentences)
    let plain = SpeechProgress(played: 2.1, total: nil, pace: 0.2, live: true, cut: false)
    let set = SpeechProgress(played: 2.1, total: nil, pace: 0.2, live: true, cut: false, rests: [rest(2.6), rest(5.7), rest(8.8)])
    // 2.1 s played + 0.5 s lead = the rest's start: the edge is at the stop
    XCTAssertEqual(try XCTUnwrap(set.position(in: t)), 10, accuracy: 0.01)
    XCTAssertGreaterThan(try XCTUnwrap(plain.position(in: t)), 10.5)
  }

  func testAVoiceSevenPercentOffThePaceTheWordsWereLaidOutWithStaysWithTheSentences() throws {
    let t = SpokenText(String(repeating: "一二三四五六七八九十。", count: 8))
    // The words are laid out at 0.2 s a unit; the voice really takes 0.186 s (7% quicker), rests as long as the words say.
    let real = 0.186
    var rests: [SoundRests.Rest] = []
    for k in 0..<8 { rests.append(rest((Double(k) * 12.5 + 10) * real, 2.5 * real)) }
    for k in 1..<8 {
      let endOfSentence = Double(k) * 12.5 + 10 // units before the full stop of sentence k
      let p = try XCTUnwrap(t.position(at: endOfSentence * real, pace: 0.2, rests: rests))
      XCTAssertEqual(p, Double(k * 11 + 10), accuracy: 0.05, "sentence \(k) ends where the words end")
    }
    // without the rests the last one would be 7% (about 5 characters) off
    let plain = try XCTUnwrap(t.position(at: (7 * 12.5 + 10) * real, pace: 0.2))
    XCTAssertGreaterThan(abs(plain - Double(7 * 11 + 10)), 3)
  }

  func testARestAtACommaIsNotTakenForTheNextSentenceEnd() {
    // sentence one ends at 2.0 s (rest 0.5 s); the comma in sentence two is at about 3.4 s; the voice runs 0.5 s slow
    let t = SpokenText("一二三四五六七八九十。一二三四五，六七八九十。")
    let rests = [rest(2.5), rest(3.9, 0.35), rest(6.2)]
    let found = t.alignedPauses(pace: 0.2, rests: rests)
    XCTAssertEqual(found.of, 2)
    XCTAssertEqual(found.matched, 2, "the comma's rest stays out, the second full stop finds its own")
    // and the second sentence end is set against the last rest, not against the comma's
    XCTAssertEqual(try XCTUnwrap(t.position(at: 6.2, pace: 0.2, rests: rests)), 22, accuracy: 0.05)
  }

  func testTheSilenceAtTheStartOfTheSoundIsNotTheEndOfAShortFirstSentence() throws {
    // "好的。" is over at 0.4 s by the words; the sound opens with 0.4 s of silence; the second sentence ends at 3.34 s by the words
    let t = SpokenText("好的。这是第二句话，说得长一点。")
    let rests = [rest(0, 0.4), rest(3.6)]
    let found = t.alignedPauses(pace: 0.2, rests: rests)
    XCTAssertEqual(found.of, 2)
    XCTAssertEqual(found.matched, 1, "only the rest at 3.6 s is a sentence end; the silence at 0 s is not the first one")
    // and the edge is not carried past the first sentence while the silence plays
    XCTAssertLessThan(try XCTUnwrap(t.position(at: 0.4, pace: 0.2, rests: [rest(0, 0.4)])), 3)
  }
}
