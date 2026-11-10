import XCTest

@testable import JarvisCore

final class MediaProgressTests: XCTestCase {
  /// The reports of a real 1024x1024 picture on the service in use: (seconds since the request, phase, number).
  static let image: [(Double, String, Double)] = [
    (0.1, "queued", 0), (0.6, "generating", 0), (2.1, "generating", 12), (3.1, "generating", 25), (4.1, "generating", 37),
    (4.6, "generating", 50), (5.6, "generating", 62), (6.6, "generating", 75), (7.6, "generating", 87), (8.6, "generating", 95),
  ]
  static let imageDone = 10.6
  /// A real 3 s video: sixteen seconds at 0, a step every 3 s, eight seconds at 95.
  static let video: [(Double, String, Double)] = [
    (0.0, "queued", 0), (0.5, "submitting", 0), (1.0, "generating", 0), (17.1, "generating", 12), (19.6, "generating", 25),
    (22.6, "generating", 37), (25.6, "generating", 50), (28.7, "generating", 62), (31.7, "generating", 75), (34.7, "generating", 87),
    (37.7, "generating", 95),
  ]
  static let videoDone = 45.7

  /// Walks a recorded run: at every tenth of a second the reports so far are known, the snapshot is read.
  func replay(
    _ run: [(Double, String, Double)], done: Double, plan: MediaPlan
  ) -> [(t: Double, snapshot: MediaSnapshot)] {
    var track = MediaTrack(startedAt: 1000)
    var out: [(Double, MediaSnapshot)] = []
    var next = 0
    var t = 0.0
    while t < done {
      while next < run.count, run[next].0 <= t {
        track.note(MediaReport(progress: run[next].2, phase: run[next].1, status: "in_progress"), at: 1000 + run[next].0)
        next += 1
      }
      out.append((t, MediaProgress.snapshot(track: track, plan: plan, now: 1000 + t)))
      t += 0.1
    }
    return out
  }

  func testTheTrackRecordsWhenEachPartBegan() {
    var track = MediaTrack(startedAt: 0)
    track.note(MediaReport(progress: 0, phase: "queued"), at: 1)
    XCTAssertNil(track.genAt)
    track.note(MediaReport(progress: 0, phase: "generating"), at: 2)
    track.note(MediaReport(progress: 0, phase: "generating"), at: 3)
    XCTAssertEqual(track.genAt, 2)
    XCTAssertNil(track.stepAt)
    track.note(MediaReport(progress: 12, phase: "generating"), at: 6)
    track.note(MediaReport(progress: 25, phase: "generating"), at: 9)
    XCTAssertEqual(track.stepAt, 6)
    XCTAssertEqual(track.firstProgress, 12)
    XCTAssertEqual(track.lastAt, 9)
    XCTAssertEqual(track.prevAt, 6, "the wait at 0 is not a step: the first step has no step before it")
    XCTAssertEqual(track.prevProgress, 12)
    XCTAssertNil(track.tailAt)
    track.note(MediaReport(progress: 95, phase: "generating"), at: 20)
    XCTAssertEqual(track.tailAt, 20)
  }

  func testTheBarNeverGoesBackAndNeverReachesTheEndBeforeTheJobIsDone() {
    for (run, done) in [(Self.image, Self.imageDone), (Self.video, Self.videoDone)] {
      let plan = MediaTimings.prior.plan(kind: run.count == Self.image.count ? "image" : "video", args: ["seconds": .number(3)])
      var last = 0.0
      for (t, s) in replay(run, done: done, plan: plan) {
        XCTAssertLessThanOrEqual(s.fraction, 0.99, "t=\(t)")
        XCTAssertGreaterThanOrEqual(s.fraction, last - 0.02, "the bar may only step back by the width of one wrong guess, t=\(t)")
        last = max(last, s.fraction)
      }
      XCTAssertGreaterThan(last, 0.9)
    }
  }

  func testTheBarMovesDuringTheLongStretchesTheServiceReportsNothingIn() {
    // The video sits at 0 for sixteen seconds and at 95 for eight: the bar must not stand still through them.
    let plan = MediaTimings.prior.plan(kind: "video", args: ["seconds": .number(3)])
    let run = replay(Self.video, done: Self.videoDone, plan: plan)
    func f(_ at: Double) -> Double { run.first { $0.t >= at }!.snapshot.fraction }
    XCTAssertGreaterThan(f(10) - f(4), 0.05, "while the model is prepared")
    XCTAssertGreaterThan(f(44) - f(39), 0.02, "while the file is saved")
  }

  func testTheTimeLeftIsCloseToTheTimeThatWasLeft() {
    // With the plan the app starts with (nothing learned yet), measured against what really happened.
    for (name, run, done, args) in [
      ("image", Self.image, Self.imageDone, [String: JSONValue]()), ("video", Self.video, Self.videoDone, ["seconds": .number(3)]),
    ] {
      let plan = MediaTimings.prior.plan(kind: name, args: args)
      var error = 0.0
      var count = 0.0
      for (t, s) in replay(run, done: done, plan: plan) where t > 1.2 {
        guard let remaining = s.remaining else { continue }
        error += abs(remaining - (done - t))
        count += 1
      }
      let mean = error / count
      print("\(name): mean error of the time left \(String(format: "%.2f", mean)) s over \(Int(count)) readings")
      XCTAssertLessThan(mean, name == "image" ? 2.5 : 6, name)
    }
  }

  func testOnceStepsAreSeenTheirSpeedDecidesTheTimeLeft() {
    // A service twice as slow as the plan: after three steps the estimate follows the real speed, not the plan.
    var track = MediaTrack(startedAt: 0)
    let plan = MediaPlan(prep: 4, work: 6, tail: 2)
    for (t, p) in [(1.0, 0.0), (4.0, 12.0), (10.0, 25.0), (16.0, 37.0)] {
      track.note(MediaReport(progress: p, phase: "generating"), at: t)
    }
    let s = MediaProgress.snapshot(track: track, plan: plan, now: 16.5)
    // 58 more percent at 12.5 per 6 s = 28 s, then 2 s of closing.
    XCTAssertEqual(s.remaining ?? 0, 30, accuracy: 3)
    XCTAssertEqual(s.stage, .working)
    XCTAssertFalse(s.stalled)
  }

  func testAJobThatStopsReportingIsSaidToStandStill() {
    var track = MediaTrack(startedAt: 0)
    let plan = MediaPlan(prep: 4, work: 6, tail: 2)
    for (t, p) in [(1.0, 0.0), (4.0, 12.0), (7.0, 25.0)] { track.note(MediaReport(progress: p, phase: "generating"), at: t) }
    XCTAssertFalse(MediaProgress.snapshot(track: track, plan: plan, now: 20).stalled)
    XCTAssertTrue(MediaProgress.snapshot(track: track, plan: plan, now: 60).stalled)
  }

  func testWaitingForATurnShowsNoProgress() {
    var track = MediaTrack(startedAt: 0)
    track.note(MediaReport(progress: 0, phase: "queued"), at: 0.2)
    let s = MediaProgress.snapshot(track: track, plan: MediaPlan(prep: 4, work: 6, tail: 2), now: 3)
    XCTAssertEqual(s.stage, .waiting)
    XCTAssertEqual(s.fraction, 0)
    XCTAssertEqual(s.remaining, 12)
  }

  func testAServiceThatOnlyAnswersAtTheEndStillGetsAMovingBar() {
    // The old way of asking for a picture: nothing comes back until it is done.
    let track = MediaTrack(startedAt: 0)
    let plan = MediaPlan(prep: 2, work: 6, tail: 2)
    let early = MediaProgress.snapshot(track: track, plan: plan, now: 2)
    let later = MediaProgress.snapshot(track: track, plan: plan, now: 8)
    let slow = MediaProgress.snapshot(track: track, plan: plan, now: 40)
    XCTAssertEqual(early.stage, .waiting)
    XCTAssertEqual(later.stage, .working)
    XCTAssertEqual(later.fraction, 0.8, accuracy: 0.01)
    XCTAssertLessThan(slow.fraction, 0.96)
    XCTAssertTrue(slow.late)
    XCTAssertNil(slow.remaining)
  }

  func testTheTimeIsSaidTheWayItIsSpoken() {
    XCTAssertEqual(MediaProgress.span(3.2), "约 4 秒")
    XCTAssertEqual(MediaProgress.span(0.2), "约 1 秒")
    XCTAssertEqual(MediaProgress.span(23), "约 25 秒")
    XCTAssertEqual(MediaProgress.span(80), "约 1 分 20 秒")
    XCTAssertEqual(MediaProgress.span(120), "约 2 分钟")
    XCTAssertEqual(MediaProgress.span(1500), "约 25 分钟")
    XCTAssertEqual(MediaProgress.clock(5), "0:05")
    XCTAssertEqual(MediaProgress.clock(125.9), "2:05")
  }

  func testThePlanScalesWithWhatIsAsked() {
    let t = MediaTimings.prior
    XCTAssertGreaterThan(t.plan(kind: "image", args: ["size": .string("2048x2048")]).total, t.plan(kind: "image", args: [:]).total)
    XCTAssertGreaterThan(t.plan(kind: "video", args: ["seconds": .number(15)]).total, t.plan(kind: "video", args: ["seconds": .string("3")]).total)
    XCTAssertEqual(MediaTimings.units(kind: "image", args: ["size": .string("bad")]), 1.05)
    XCTAssertEqual(MediaTimings.units(kind: "video", args: ["seconds": .number(500)]), 120)
  }

  func testWhatARunTookIsLearnedAndAnOddRunIsNot() {
    var t = MediaTimings.prior
    var track = MediaTrack(startedAt: 0)
    track.genAt = 1
    track.stepAt = 11  // ten seconds to the first step: the model was not in memory
    track.tailAt = 11 + 7
    t.learn(kind: "image", args: ["size": .string("1024x1024")], track: track, finishedAt: 20)
    XCTAssertGreaterThan(t.image.prep, MediaTimings.prior.image.prep)
    XCTAssertLessThan(t.image.prep, 10)
    XCTAssertEqual(t.image.runs, 1)
    XCTAssertEqual(t.video, MediaTimings.prior.video)
    var odd = MediaTrack(startedAt: 0)
    odd.genAt = 1
    odd.stepAt = 400  // stood still for minutes
    odd.tailAt = 405
    var u = MediaTimings.prior
    u.learn(kind: "image", args: [:], track: odd, finishedAt: 406)
    XCTAssertEqual(u.image.prep, MediaTimings.prior.image.prep)
    var incomplete = MediaTrack(startedAt: 0)
    incomplete.genAt = 1
    var v = MediaTimings.prior
    v.learn(kind: "image", args: [:], track: incomplete, finishedAt: 5)
    XCTAssertEqual(v.image.runs, 0)
  }

  func testTheSnapshotSaysHowLongTheServiceHasBeenQuiet() {
    var track = MediaTrack(startedAt: 100)
    track.note(MediaReport(progress: 12, phase: "generating"), at: 110)
    let s = MediaProgress.snapshot(track: track, plan: MediaTimings.prior.plan(kind: "image", args: [:]), now: 170)
    XCTAssertEqual(s.quiet, 60, accuracy: 0.001)
    XCTAssertEqual(MediaProgress.quietSpan(45), "45 秒")
    XCTAssertEqual(MediaProgress.quietSpan(190), "3 分钟")
    XCTAssertEqual(MediaProgress.quietMessage(320), MediaCopy.timedOut)
  }

  func testARunFollowedFromTheMiddleIsNotLearnedFrom() {
    var track = MediaTrack(startedAt: 0)
    track.genAt = 1
    track.stepAt = 1
    track.firstProgress = 62  // the first report seen was already past the middle
    track.tailAt = 5
    var t = MediaTimings.prior
    t.learn(kind: "image", args: [:], track: track, finishedAt: 8)
    XCTAssertEqual(t.image.runs, 0)
  }

  func testALongerFilmIsGivenLongerBeforeItIsCalledStuck() {
    let short = MediaProgress.quietLimit(kind: "video", args: ["seconds": .number(3)])
    let long = MediaProgress.quietLimit(kind: "video", args: ["seconds": .number(15)])
    XCTAssertEqual(short, 660, accuracy: 0.001)
    XCTAssertGreaterThan(long, short)
    XCTAssertLessThanOrEqual(MediaProgress.quietLimit(kind: "video", args: ["seconds": .number(120)]), 1800)
    XCTAssertEqual(MediaProgress.quietLimit(kind: "image"), 300)
  }
}
