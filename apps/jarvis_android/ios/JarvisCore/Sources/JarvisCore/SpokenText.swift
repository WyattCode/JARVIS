import Foundation

/// A reply's words laid against its sound, so the call page can show where the voice is.
///
/// The server gives no times for the words, only the text and the audio. What is known exactly is how much of the audio has
/// been played; every character is given the time it is likely to take to say (its weight), and the played time is looked up
/// in that. The place found is an estimate: it can run ahead of or behind the voice, by a few words, sometimes more. It never
/// jumps, so the page draws it as a soft edge moving on, not as a mark on a word.
public struct SpokenText: Equatable {
  /// What the page shows: the reply without its Markdown marks (a `**` is not said, and not worth showing either).
  public let plain: String
  /// Runs to set heavier (UTF-16 offsets into `plain`).
  public let bold: [Range<Int>]
  /// The characters of `plain` as the reader sees them (UTF-16 offsets); together they cover all of it.
  public let clusters: [Range<Int>]
  /// Time before each character and in all, in units of one spoken Chinese character (`cumulative.count == clusters.count + 1`).
  private let cumulative: [Double]
  /// The places where the words make the voice rest at the end of a sentence or line: the unit before the pause and its length.
  private let pauses: [Pause]

  struct Pause: Equatable {
    var at: Double
    var units: Double
    /// The end of a sentence or line (the rest the sound is set by); a comma's pause only keeps the rests that belong to it away.
    var sentenceEnd: Bool { units >= 2 }
  }

  /// Seconds one unit takes when nothing better is known (measured on the service's voice: 0.186 to 0.192).
  public static let defaultPace = 0.19
  /// Paces outside this are not a voice (a reply whose words and sound do not belong together): they are not believed.
  public static let paceRange = 0.08...0.5

  public init(_ raw: String) {
    var plain = ""
    var bold: [Range<Int>] = []
    var offset = 0
    var inFence = false
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    for (n, source) in lines.enumerated() {
      var line = String(source)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        inFence.toggle()
        continue
      }
      var headed = false
      if !inFence {
        if let r = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
          line.removeSubrange(r)
          headed = true
        } else if let r = line.range(of: #"^\s{0,3}>\s?"#, options: .regularExpression) {
          line.removeSubrange(r)
        } else if let r = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
          line.replaceSubrange(r, with: "· ")
        }
      }
      let (text, runs) = inFence ? (line, []) : Self.inline(line)
      let base = offset
      plain += text
      let length = text.utf16.count
      for run in runs { bold.append((base + run.lowerBound)..<(base + run.upperBound)) }
      if headed, length > 0 { bold.append(base..<(base + length)) }
      offset += length
      if n < lines.count - 1 {
        plain += "\n"
        offset += 1
      }
    }
    self.plain = plain
    self.bold = Self.merged(bold)
    let units = Array(plain.utf16)
    let each = Self.weights(units)
    var clusters: [Range<Int>] = []
    var cumulative = [0.0]
    var at = 0
    for character in plain {
      let end = at + character.utf16.count
      clusters.append(at..<end)
      cumulative.append(cumulative[cumulative.count - 1] + each[at..<end].reduce(0, +))
      at = end
    }
    self.clusters = clusters
    self.cumulative = cumulative
    var pauses: [Pause] = []
    for i in clusters.indices where cumulative[i + 1] - cumulative[i] >= 1.2 { pauses.append(Pause(at: cumulative[i], units: cumulative[i + 1] - cumulative[i])) }
    self.pauses = pauses
  }

  public var isEmpty: Bool { clusters.isEmpty }
  public var totalWeight: Double { cumulative[cumulative.count - 1] }

  /// How far the voice is `seconds` into the reply when one unit takes `pace` seconds: the number of characters it has said,
  /// with the part of the one it is on (so 3.5 is half way through the fourth). All of them when it is past the end.
  public func position(at seconds: Double, pace: Double) -> Double? {
    guard !clusters.isEmpty, pace > 0, seconds.isFinite else { return nil }
    let units = max(0, seconds) / pace
    guard units < totalWeight else { return Double(clusters.count) }
    // The first character that ends after this time (characters that take no time are passed over).
    var low = 0
    var high = clusters.count - 1
    while low < high {
      let mid = (low + high) / 2
      if cumulative[mid + 1] > units { high = mid } else { low = mid + 1 }
    }
    let width = cumulative[low + 1] - cumulative[low]
    return Double(low) + (width > 0 ? (units - cumulative[low]) / width : 0)
  }

  /// Where the voice is `seconds` into the reply, given the rests the sound really has (see `SoundRests`). The words only
  /// estimate when the voice pauses between sentences; the sound says when it did. Each sentence end the words predict is set
  /// against the real rest nearest to it, and the time between two such rests is laid out evenly between them: an estimate that
  /// is a little fast or slow in one sentence is put right at its end instead of carrying on into the next. Without any rest
  /// found (or none that fits) this is `position(at:pace:)`.
  public func position(at seconds: Double, pace: Double, rests: [SoundRests.Rest]) -> Double? {
    guard !clusters.isEmpty, pace > 0, seconds.isFinite else { return nil }
    let anchors = Self.anchors(pauses: pauses, pace: pace, rests: rests)
    guard !anchors.isEmpty else { return position(at: seconds, pace: pace) }
    return position(at: Self.wordTime(forSoundTime: max(0, seconds), anchors: anchors), pace: pace)
  }

  /// How many of the reply's sentence ends were set against a rest of the sound, and how many there are (for the trace).
  public func alignedPauses(pace: Double, rests: [SoundRests.Rest]) -> (matched: Int, of: Int) {
    (Self.anchors(pauses: pauses, pace: pace, rests: rests).count / 2, pauses.filter(\.sentenceEnd).count)
  }

  /// A rest shorter than this is a breath, not the pause at the end of a sentence.
  static let shortestSentenceRest = 0.3
  /// A rest is taken for the end of a sentence only when it is within this many seconds of where the words put it, counted from
  /// the place of the last one found (so a voice that runs a little slow does not lose the thread).
  static let restReach = 1.2
  /// Between two rests found, the sound may take at most this many times (or at least this fraction of) the time the words give.
  static let stretch = 0.6...1.6

  /// Pairs of (time by the words, time in the sound): the start and the end of every rest that fits a sentence end.
  struct Anchor: Equatable {
    var words: Double
    var sound: Double
  }

  static func anchors(pauses: [Pause], pace: Double, rests: [SoundRests.Rest]) -> [Anchor] {
    var found: [Anchor] = []
    var next = 0
    // How much longer or shorter the sound takes than the words say (a voice a little off the pace the words were laid out
    // with), from the rests found so far: where the next rest is expected is worked out with it.
    var scale = 1.0
    func expected(_ pause: Pause) -> Double {
      let start = pause.at * pace
      guard let last = found.last else { return start }
      return last.sound + (start - last.words) * scale
    }
    for (k, pause) in pauses.enumerated() where pause.sentenceEnd {
      let start = pause.at * pace
      let length = pause.units * pace
      let target = expected(pause)
      // The pauses at commas before and after this one: a rest nearer to one of those than to this sentence end is theirs.
      var neighbours: [Double] = []
      if k > 0, !pauses[k - 1].sentenceEnd { neighbours.append(expected(pauses[k - 1])) }
      if k + 1 < pauses.count, !pauses[k + 1].sentenceEnd { neighbours.append(expected(pauses[k + 1])) }
      var best: (score: Double, index: Int)?
      var index = next
      while index < rests.count {
        let rest = rests[index]
        if rest.at > target + Self.restReach { break }
        index += 1
        guard rest.length >= Self.shortestSentenceRest else { continue }
        let off = abs(rest.at - target)
        guard off <= Self.restReach else { continue }
        if neighbours.contains(where: { abs(rest.at - $0) + 0.1 < off }) { continue }
        // Rests that cannot follow the last one found (or the start of the reply, for the first), at a believable speed, are not
        // it: the silence at the very start of the sound is not the end of a short first sentence.
        let last = found.last ?? Anchor(words: 0, sound: 0)
        let sound = rest.at - last.sound
        let words = start - last.words
        guard sound > 0, words > 0, Self.stretch.contains(words / sound) else { continue }
        let score = off + 1.5 * abs(rest.length - length)
        if best == nil || score < best!.score { best = (score, index - 1) }
      }
      guard let choice = best else { continue }
      let rest = rests[choice.index]
      found.append(Anchor(words: start, sound: rest.at))
      found.append(Anchor(words: start + length, sound: rest.at + rest.length))
      scale = Self.scale(of: found)
      next = choice.index + 1
    }
    return found
  }

  /// How much longer (above 1) or shorter the sound takes than the words say, counted from the start of the reply to the last
  /// rest found. (Counting only from the first rest found was tried: a voice that is slow through the middle of a reply and
  /// quick at the end made it pick a comma's rest for a sentence end, and the error went from 0.07 s to 0.5 s; counting from the
  /// start did not, at paces anywhere from 12% under to 12% over.)
  static func scale(of anchors: [Anchor]) -> Double {
    guard let last = anchors.last, last.words > 0 else { return 1 }
    return min(max(last.sound / last.words, 0.85), 1.2)
  }

  /// The time by the words for a time in the sound: straight lines between the anchors, and one to one before the first and
  /// after the last.
  static func wordTime(forSoundTime t: Double, anchors: [Anchor]) -> Double {
    guard let first = anchors.first, let last = anchors.last else { return t }
    if t <= first.sound { return first.sound > 0 ? t * first.words / first.sound : t }
    if t >= last.sound { return last.words + (t - last.sound) / scale(of: anchors) }
    var low = 0
    var high = anchors.count - 1
    while high - low > 1 {
      let mid = (low + high) / 2
      if anchors[mid].sound <= t { low = mid } else { high = mid }
    }
    let a = anchors[low]
    let b = anchors[high]
    let span = b.sound - a.sound
    guard span > 0 else { return a.words }
    return a.words + (t - a.sound) * (b.words - a.words) / span
  }

  /// Where the words make the voice rest at the end of a sentence (or line): seconds into the sound from where the rest begins,
  /// and its length, when one unit takes `pace`. Only for the call's trace, to set against the rests the sound really has.
  public func sentenceRests(pace: Double) -> [(at: Double, length: Double)] {
    var found: [(at: Double, length: Double)] = []
    for i in clusters.indices {
      let weight = cumulative[i + 1] - cumulative[i]
      if weight >= 2 { found.append((cumulative[i] * pace, weight * pace)) }
    }
    return found
  }

  /// The pace that makes these words fill `seconds` of sound, once all of the sound is known.
  public func pace(forTotal seconds: Double) -> Double {
    let w = totalWeight
    guard w > 0, seconds > 0, seconds.isFinite else { return Self.defaultPace }
    return min(max(seconds / w, Self.paceRange.lowerBound), Self.paceRange.upperBound)
  }

  // MARK: Parts

  /// Inline marks of one line: `**bold**` is kept as a run, `code`, `*emphasis*` and `[text](link)` lose their marks. A `**`
  /// still waiting for its partner (the reply is being written) already bolds what follows.
  private static func inline(_ line: String) -> (String, [Range<Int>]) {
    let chars = Array(line)
    var out = ""
    var runs: [Range<Int>] = []
    var length = 0
    var boldFrom: Int?
    var i = 0
    func emit(_ s: String) { out += s; length += s.utf16.count }
    while i < chars.count {
      let c = chars[i]
      if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
        if let from = boldFrom {
          if length > from { runs.append(from..<length) }
          boldFrom = nil
        } else {
          boldFrom = length
        }
        i += 2
        while i < chars.count, chars[i] == "*" { i += 1 }
        continue
      }
      if c == "*" || c == "`" {
        // A lone star or a backtick is a mark; a star between two spaces ("2 * 3") is a sign, and stays.
        let spaced = c == "*" && i > 0 && chars[i - 1] == " " && i + 1 < chars.count && chars[i + 1] == " "
        if spaced { emit("*") }
        i += 1
        continue
      }
      if c == "[", let close = chars[i...].firstIndex(of: "]"), close + 1 < chars.count, chars[close + 1] == "(",
        let end = chars[(close + 1)...].firstIndex(of: ")")
      {
        emit(String(chars[(i + 1)..<close]))
        i = end + 1
        continue
      }
      emit(String(c))
      i += 1
    }
    if let from = boldFrom, length > from { runs.append(from..<length) }
    return (out, runs)
  }

  private static func merged(_ runs: [Range<Int>]) -> [Range<Int>] {
    var result: [Range<Int>] = []
    for run in runs.sorted(by: { $0.lowerBound < $1.lowerBound }) where !run.isEmpty {
      if let last = result.last, run.lowerBound <= last.upperBound {
        result[result.count - 1] = last.lowerBound..<max(last.upperBound, run.upperBound)
      } else {
        result.append(run)
      }
    }
    return result
  }

  private static let enders: Set<UInt16> = Set("。！？!?；;…".utf16)

  /// The time of every UTF-16 unit, in units of one spoken Chinese character: a character 1, a digit about 1.3 (a number is
  /// said as its words), a Latin letter a third, a comma a short pause and a full stop a long one (the pause is the stop's
  /// own time, so the voice rests on it). A run like "?!" or "……" is one pause, not one for every mark.
  private static func weights(_ units: [UInt16]) -> [Double] {
    var result = [Double](repeating: 0, count: units.count)
    var afterEnd = false
    for i in units.indices {
      let c = units[i]
      let dot = c == 0x2E && (i + 1 >= units.count || units[i + 1] == 0x20 || units[i + 1] == 0x0A)
      if enders.contains(c) || dot {
        if !afterEnd { result[i] = 2.5 }
        afterEnd = true
        continue
      }
      afterEnd = false
      switch c {
      case 0x30...0x39: result[i] = 1.3
      case 0x41...0x5A, 0x61...0x7A: result[i] = 0.35
      case 0x20, 0x09, 0x3000: result[i] = 0
      case 0x0A: result[i] = 2
      case 0x2C, 0xFF0C, 0x3001, 0x3A, 0xFF1A: result[i] = 1.2
      case 0x2E: result[i] = 0.5
      case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF: result[i] = 1
      default: result[i] = 0.3
      }
    }
    return result
  }
}

/// The rests in a reply's sound (stretches of near-silence long enough to be a pause between phrases), found as the sound
/// arrives. The words give only an estimate of when the voice pauses; these are where it really did, for the call's trace.
public struct SoundRests {
  public struct Rest: Equatable {
    /// Seconds into the sound where the rest began, and how long it was.
    public let at: Double
    public let length: Double
  }

  /// Under this level (of full scale, as RMS over one look) the sound is taken to be silent.
  public static let quietLevel = 0.012
  /// Rests shorter than this (seconds) are the voice's own gaps between sounds, not pauses.
  public static let shortest = 0.15

  private let rate: Int
  /// Samples in one look (20 ms).
  private let look: Int
  private var sum = 0.0
  private var count = 0
  /// Samples before the look being filled.
  private var seen = 0
  /// Looks of silence in a row, and the sample where they began.
  private var quiet = 0
  private var quietFrom = 0
  /// Half a sample left over from the last chunk.
  private var carry: UInt8?

  public init(rate: Int) {
    self.rate = max(rate, 1)
    self.look = max(self.rate / 50, 1)
  }

  /// Takes the next 16-bit little-endian samples; returns the rests that ended in them (a rest is known to be over only when
  /// sound comes after it, so the silence at the very end is not one).
  public mutating func add(_ pcm: Data) -> [Rest] {
    var bytes = pcm
    if let half = carry {
      bytes = Data([half]) + pcm
      carry = nil
    }
    if bytes.count % 2 == 1 { carry = bytes.last }
    var found: [Rest] = []
    bytes.withUnsafeBytes { raw in
      for i in 0..<(bytes.count / 2) {
        let value = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
        sum += value * value
        count += 1
        guard count == look else { continue }
        if (sum / Double(count)).squareRoot() >= Self.quietLevel {
          let length = Double(quiet * look) / Double(rate)
          if quiet > 0, length >= Self.shortest { found.append(Rest(at: Double(quietFrom) / Double(rate), length: length)) }
          quiet = 0
        } else {
          if quiet == 0 { quietFrom = seen }
          quiet += 1
        }
        seen += count
        sum = 0
        count = 0
      }
    }
    return found
  }
}

/// How far the voice has got in the reply on screen (`VoiceSession.speechProgress`).
public struct SpeechProgress: Equatable {
  /// Seconds of this reply's sound already played.
  public var played: Double
  /// Seconds of sound in all, once all of it has arrived.
  public var total: Double?
  /// Seconds one spoken character takes, for as long as `total` is not known.
  public var pace: Double
  /// The reply is being said now.
  public var live: Bool
  /// The reply was cut off, and `played` is where.
  public var cut: Bool
  /// The rests found in the sound that has arrived (see `SoundRests`): they put the words right at the end of each sentence.
  public var rests: [SoundRests.Rest]

  public init(played: Double, total: Double?, pace: Double, live: Bool, cut: Bool, rests: [SoundRests.Rest] = []) {
    self.played = played
    self.total = total
    self.pace = pace
    self.live = live
    self.cut = cut
    self.rests = rests
  }

  /// The eye is on a word a moment before it is said, and the lit edge is drawn a few characters behind its front: so the edge
  /// is placed as far ahead of the sound as that, which is what makes it look level with the voice. (0.35 looked a little late
  /// on the Duo's long replies, so it is 0.5.)
  public static let lead = 0.5

  /// How many characters of `text` the voice has said, nil when the reply is not being followed any more (it was said to the end).
  public func position(in text: SpokenText) -> Double? {
    guard live || cut else { return nil }
    return text.position(at: played + Self.lead, pace: total.map { text.pace(forTotal: $0) } ?? pace, rests: rests)
  }
}

/// The edge the page draws, which follows the estimated place of the voice but never jumps to it: it moves on at most as fast
/// as a quick speaker (a few times the speed of speech) and never goes back. An estimate that is wrong therefore shows as the
/// edge being a little early or late, not as the lit part leaping across the text.
public struct ReadingEdge: Equatable {
  /// Where the edge is drawn now (characters said), nil before the first estimate of a reply.
  public private(set) var value: Double?
  private var at: Double?

  /// The fastest the edge moves, in characters a second (speech is about five).
  public static let maxSpeed = 14.0
  /// Longer than this between two looks (the page was away) and the edge is set to the estimate at once.
  public static let longestGap = 1.0

  public init() {}

  public mutating func reset() {
    value = nil
    at = nil
  }

  /// The edge at `now` (seconds, any clock) given the estimate `raw`.
  public mutating func advance(to raw: Double, now: Double) -> Double {
    guard let current = value, let last = at, now >= last, now - last <= Self.longestGap else {
      value = raw
      at = now
      return raw
    }
    let next = raw > current ? min(raw, current + Self.maxSpeed * (now - last)) : current
    value = next
    at = now
    return next
  }

  /// A reply that was cut off keeps the edge where it was drawn (or at the estimate, if nothing was drawn yet).
  public mutating func freeze(at raw: Double) -> Double {
    if let current = value { return current }
    value = raw
    return raw
  }
}
