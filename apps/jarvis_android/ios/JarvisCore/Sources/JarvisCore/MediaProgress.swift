import Foundation

// What a picture or video being made shows: a percentage that keeps moving, what the service is doing, and how long it still
// takes. The service reports in coarse steps (a picture: eight of them, a video: eight, each a few seconds), sits at 0 while it
// loads the model and at 95 while it finishes the file, so the raw number alone stands still for most of the wait.
// The estimate is built from the real reports (which stage, how fast the steps come) and from how long earlier runs took on this
// phone, never from a made-up curve that claims more than it knows.

/// One answer of the service about a running job.
public struct MediaReport: Equatable, Sendable {
  /// 0 to 100 (the service holds it at 95 until the file is saved).
  public var progress: Double
  /// queued, submitting, generating, downloading ... (empty when the service names none).
  public var phase: String
  public var status: String

  public init(progress: Double, phase: String = "", status: String = "") {
    self.progress = progress
    self.phase = phase
    self.status = status
  }
}

/// The timeline of one run as the reports came in (Unix seconds of this phone).
public struct MediaTrack: Codable, Equatable, Hashable, Sendable {
  public var startedAt: Double
  /// The first report that said the work had begun (before it the job only waited for its turn).
  public var genAt: Double?
  /// The first report with a step done, and its number.
  public var stepAt: Double?
  public var firstProgress: Double = 0
  /// The first report of the closing stage (the file being made and saved).
  public var tailAt: Double?
  public var phase: String = ""
  /// When the number last changed, and what it was before that (for the speed of the steps).
  public var lastAt: Double?
  public var lastProgress: Double = 0
  public var prevAt: Double?
  public var prevProgress: Double = 0
  /// Some report named a stage or carried a number; false when the service only ever answers at the end.
  public var informed: Bool = false

  public init(startedAt: Double) { self.startedAt = startedAt }

  /// The progress at which the service says "closing": it holds this number while the file is made.
  public static let closing: Double = 95

  public mutating func note(_ report: MediaReport, at t: Double) {
    let phase = report.phase
    if !phase.isEmpty { self.phase = phase }
    if report.progress > 0 || !phase.isEmpty { informed = true }
    // Anything but waiting for a turn is work (the service in use says "generating"; another may name its own stages).
    let working = !["", "queued", "submitting", "cancelling"].contains(phase) || report.progress > 0
    if working, genAt == nil { genAt = t }
    if report.progress > 0, stepAt == nil {
      stepAt = t
      firstProgress = report.progress
    }
    if report.progress >= Self.closing || phase == "downloading" {
      tailAt = tailAt ?? t
      if stepAt == nil { stepAt = t; firstProgress = min(report.progress, Self.closing) }
    }
    if lastAt == nil || report.progress != lastProgress {
      // The speed of the steps is read from two reports with a step done; the wait at 0 before the first one is not a step.
      if lastAt != nil, lastProgress > 0 {
        prevAt = lastAt
        prevProgress = lastProgress
      } else {
        prevAt = nil
        prevProgress = 0
      }
      lastAt = t
      lastProgress = report.progress
    }
  }
}

/// How long the three parts of a run are expected to take (seconds).
public struct MediaPlan: Codable, Equatable, Hashable, Sendable {
  /// From the start of the work to the first step done (loading the model, reading the prompt, the first step).
  public var prep: Double
  /// From the first step done to the closing stage (the other steps).
  public var work: Double
  /// The closing stage (the file made and saved).
  public var tail: Double

  public init(prep: Double, work: Double, tail: Double) {
    self.prep = max(prep, 0.5)
    self.work = max(work, 0.5)
    self.tail = max(tail, 0.5)
  }

  public var total: Double { prep + work + tail }
}

/// What earlier runs took, per kind. `work` and `tail` are per unit (a video: per second of film, a picture: per megapixel).
public struct MediaTimings: Codable, Equatable, Sendable {
  public struct Rate: Codable, Equatable, Sendable {
    public var prep: Double
    public var work: Double
    public var tail: Double
    public var runs: Int
    public init(prep: Double, work: Double, tail: Double, runs: Int = 0) {
      self.prep = prep; self.work = work; self.tail = tail; self.runs = runs
    }
  }

  /// Measured on the service in use (a 1024x1024 picture: 1.5 s + 6.5 s + 2 s; a 3 s video: 16 s + 20 s + 8 s).
  public var image = Rate(prep: 2, work: 6.2, tail: 1.9)
  public var video = Rate(prep: 16, work: 6.9, tail: 2.7)

  public init() {}

  public static let prior = MediaTimings()

  /// Pictures: megapixels of the size asked for. Videos: seconds of film.
  public static func units(kind: String, args: [String: JSONValue]) -> Double {
    if kind == "video" {
      let s = args["seconds"].flatMap { $0.double ?? $0.string.flatMap(Double.init) } ?? 5
      return min(max(s, 1), 120)
    }
    let size = args["size"]?.string ?? "1024x1024"
    let parts = size.lowercased().split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return 1.05 }
    return min(max(parts[0] * parts[1] / 1_000_000, 0.25), 16)
  }

  public func plan(kind: String, args: [String: JSONValue]) -> MediaPlan {
    let r = kind == "video" ? video : image
    let u = Self.units(kind: kind, args: args)
    return MediaPlan(prep: r.prep, work: r.work * u, tail: r.tail * u)
  }

  /// Takes in a run that went through every stage; anything odd (a resumed job, a stage skipped) is left out.
  public mutating func learn(kind: String, args: [String: JSONValue], track: MediaTrack, finishedAt: Double) {
    // A run followed from the middle (the app was away, the job was picked up again) is not a whole run: left out.
    guard let gen = track.genAt, let step = track.stepAt, let tail = track.tailAt, gen <= step, step <= tail, tail <= finishedAt,
      track.firstProgress <= 30
    else { return }
    let u = Self.units(kind: kind, args: args)
    let seen = (prep: step - gen, work: (tail - step) / u, tail: (finishedAt - tail) / u)
    var r = kind == "video" ? video : image
    let base = MediaTimings.prior
    let prior = kind == "video" ? base.video : base.image
    func blend(_ old: Double, _ new: Double, _ anchor: Double) -> Double {
      // A reading far from anything sensible (a run that stood still for minutes) is not trusted.
      guard new > 0, new < anchor * 20 else { return old }
      return r.runs == 0 ? (old + new) / 2 : old * 0.5 + new * 0.5
    }
    r.prep = blend(r.prep, seen.prep, prior.prep)
    r.work = blend(r.work, seen.work, prior.work)
    r.tail = blend(r.tail, seen.tail, prior.tail)
    r.runs += 1
    if kind == "video" { video = r } else { image = r }
  }
}

public enum MediaStage: String, Sendable {
  case waiting, preparing, working, finishing
}

/// What to draw for a running job at one moment.
public struct MediaSnapshot: Equatable, Sendable {
  public var stage: MediaStage
  /// Where the bar should be (0 to 0.99; it reaches the end only when the job is done).
  public var fraction: Double
  public var elapsed: Double
  /// Seconds still to go by the speed seen so far; nil when that cannot be said.
  public var remaining: Double?
  /// Slower than runs before it, or than the plan.
  public var late: Bool
  /// No new report for much longer than the steps take.
  public var stalled: Bool
  /// Seconds since the last report (or since the start while there was none).
  public var quiet: Double = 0
}

public enum MediaProgress {
  /// A curve that follows `x` (the share of the expected time passed) and flattens out below 0.95, so a part that takes longer
  /// than expected slows the bar down instead of sending it to the end of its stretch.
  static func eased(_ x: Double) -> Double {
    let x = max(x, 0)
    return x < 0.8 ? x : 0.8 + 0.15 * (1 - exp(-(x - 0.8) * 3))
  }

  public static func snapshot(track: MediaTrack?, plan: MediaPlan, now: Double) -> MediaSnapshot {
    var s = core(track: track, plan: plan, now: now)
    if let track { s.quiet = max(now - (track.lastAt ?? track.startedAt), 0) }
    return s
  }

  /// How long a job may report nothing before it is given up as stuck (a step takes a second or a few; the file being saved
  /// under ten).
  /// A longer film has longer steps, so it is given longer (never more than the 30 minutes a job is followed for).
  public static func quietLimit(kind: String, args: [String: JSONValue] = [:]) -> Double {
    kind == "video" ? min(600 + 20 * MediaTimings.units(kind: kind, args: args), 1800) : 300
  }

  public static func quietMessage(_ seconds: Double) -> String {
    MediaCopy.timedOut
  }

  /// "12 秒", "3 分钟": how long nothing has been heard.
  public static func quietSpan(_ seconds: Double) -> String {
    seconds < 60 ? "\(Int(max(seconds, 1))) 秒" : "\(Int(seconds / 60)) 分钟"
  }

  private static func core(track: MediaTrack?, plan: MediaPlan, now: Double) -> MediaSnapshot {
    guard let track else {
      return MediaSnapshot(stage: .waiting, fraction: 0, elapsed: 0, remaining: plan.total, late: false, stalled: false)
    }
    let elapsed = max(now - track.startedAt, 0)
    let total = plan.total
    let f1 = plan.prep / total
    let f2 = (plan.prep + plan.work) / total

    // The service never said anything about stages: one stretch of the expected length.
    if !track.informed, now - track.startedAt > 4 {
      let x = elapsed / total
      return MediaSnapshot(
        stage: .working, fraction: eased(x), elapsed: elapsed, remaining: x < 1 ? total - elapsed : nil, late: x > 1, stalled: false)
    }

    if track.genAt == nil {
      return MediaSnapshot(stage: .waiting, fraction: 0, elapsed: elapsed, remaining: total, late: false, stalled: false)
    }

    if let tail = track.tailAt {
      let e = max(now - tail, 0)
      let x = e / plan.tail
      return MediaSnapshot(
        stage: .finishing, fraction: f2 + (1 - f2) * eased(x), elapsed: elapsed,
        remaining: x < 1 ? max(plan.tail - e, 0.5) : nil, late: x > 1, stalled: e > max(plan.tail * 4, 40))
    }

    guard track.stepAt != nil, let lastAt = track.lastAt else {
      let e = max(now - (track.genAt ?? now), 0)
      let x = e / plan.prep
      return MediaSnapshot(
        stage: .preparing, fraction: f1 * eased(x), elapsed: elapsed,
        remaining: max(plan.prep - e, plan.prep * 0.15) + plan.work + plan.tail, late: x > 1.2,
        stalled: e > max(plan.prep * 4, 60))
    }

    // Steps are coming in: the speed of the last two reports carries the number on to just short of the next one.
    let first = track.firstProgress
    let span = max(Self.closingSpan(first), 1)
    let stepSize = track.prevAt != nil ? max(track.lastProgress - track.prevProgress, 0.5) : max(first, 0.5)
    var rate = span / plan.work
    var interval = plan.work / max(span / stepSize, 1)
    if let prevAt = track.prevAt, lastAt > prevAt, track.lastProgress > track.prevProgress {
      rate = (track.lastProgress - track.prevProgress) / (lastAt - prevAt)
      interval = lastAt - prevAt
    }
    let ahead = min(rate * max(now - lastAt, 0), stepSize * 0.92)
    let predicted = min(track.lastProgress + ahead, MediaTrack.closing - 0.05)
    let w = min(max((predicted - first) / span, 0), 1)
    let remaining = rate > 0 ? max((MediaTrack.closing - predicted) / rate, 0) + plan.tail : nil
    return MediaSnapshot(
      stage: .working, fraction: f1 + (f2 - f1) * w, elapsed: elapsed, remaining: remaining,
      late: false, stalled: now - lastAt > max(interval * 6, 30))
  }

  private static func closingSpan(_ first: Double) -> Double { MediaTrack.closing - first }

  /// "m:ss".
  public static func clock(_ seconds: Double) -> String {
    let s = Int(max(seconds, 0))
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  /// "约 12 秒", "约 1 分 20 秒", "约 3 分钟": rounded the way a wait is said aloud.
  public static func span(_ seconds: Double) -> String {
    let s = max(seconds, 1)
    if s < 15 { return "约 \(Int(s.rounded(.up))) 秒" }
    if s < 60 { return "约 \(Int((s / 5).rounded(.up)) * 5) 秒" }
    if s < 600 {
      let total = Int((s / 10).rounded(.up)) * 10
      return total % 60 == 0 ? "约 \(total / 60) 分钟" : "约 \(total / 60) 分 \(total % 60) 秒"
    }
    return "约 \(Int((s / 60).rounded(.up))) 分钟"
  }

  public static func label(_ stage: MediaStage, kind: String) -> String {
    switch stage {
    case .waiting: return "正在等待…"
    case .preparing: return "正在准备…"
    case .working: return kind == "video" ? "正在生成视频" : "正在生成图像"
    case .finishing: return "正在下载…"
    }
  }
}

/// What the cards say when a picture or video did not come. The wording follows the system's own apps: what could not be
/// done ("未能生成图像"), then one short sentence on what to do; never the inner cause, never the server.
public enum MediaCopy {
  public static func noun(_ kind: String) -> String { kind == "video" ? "视频" : "图像" }
  public static func failedTitle(_ kind: String) -> String { "未能生成" + noun(kind) }
  public static func cancelledTitle(_ kind: String) -> String { noun(kind) + "生成已取消" }
  public static func unavailable(_ kind: String) -> String { noun(kind) + "生成不可用" }
  public static func failed(_ kind: String) -> String { failedTitle(kind) + "。请重试。" }
  public static func nothing(_ kind: String) -> String { "未生成" + noun(kind) + "。请重试。" }
  public static let retry = "请重试。"
  public static let timedOut = "请求超时。请重试。"
  public static let network = "请检查互联网连接，然后重试。"
  public static let signIn = "登录以继续"
  /// The mark of a run the person stopped (kept as it was stored by earlier versions).
  public static let cancelled = "已取消"

  /// What is shown for a stored reason: the ones earlier versions wrote are put in today's words.
  public static func shown(_ error: String?, kind: String) -> String? {
    guard let error, !error.isEmpty else { return nil }
    if error.contains("已退出登录") { return signIn }
    if error.contains("没有新进展") || error.contains("等待时间过长") || error.contains("仍未完成") { return timedOut }
    if error.contains("暂时无法检查") { return network }
    if error.contains("没有返回作品") || error.contains("未返回作品") { return nothing(kind) }
    if error.contains("不支持此任务") { return unavailable(kind) }
    if error.contains("生成失败") || error.contains("应用退出时") { return failed(kind) }
    return error
  }
}
