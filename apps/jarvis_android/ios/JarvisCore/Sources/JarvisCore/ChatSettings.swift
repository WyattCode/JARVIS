import Foundation

public struct ChatSettings: Equatable, Sendable {
  public var tools = true
  public var maxTokens = 0
  public var messageFontSize = 16.0
  public var instructions = ""
  public var apiKey = ""
  public var speechModel = ""
  public var voices: [String: String] = [:]
  /// The server's voice-default revision already applied here, by `<server>|<speech model>`: a default the server
  /// changes is taken once, and the voice the user picks afterwards is kept.
  public var voiceDefaultRevisions: [String: Int] = [:]
  public var voiceMode = "ptt"
  /// The thinking strength the user picked for calls: "none", "low", "medium" or "high"; empty follows the server's voice
  /// default. Kept apart from the chat's strength, which a call never inherits.
  public var voiceEffort = ""
  public var language = ""
  public var transcriptionPrompt = ""
  public var waitMs = 800
  public var threshold = 0.5
  public var echoCancel = true
  /// The one-time notice about what is sent to the AI service was accepted on this device.
  public var aiNoticeAccepted = false

  public init() {}

  public static let efforts = ["none", "low", "medium", "high"]
  static let fontSizes: [Double] = [12, 14, 16, 18, 20, 22, 24]
  static let languages = ["", "zh", "en", "ja", "ko", "fr", "de", "es"]
  static let waits = [300, 500, 800, 1000, 1500, 2000, 3000, 4000, 5000]

  public func json() -> [String: JSONValue] {
    [
      "tools": .bool(tools), "maxTokens": .number(Double(maxTokens)), "messageFontSize": .number(messageFontSize),
      "instructions": .string(instructions), "apiKey": .string(apiKey), "speechModel": .string(speechModel),
      "voices": .object(voices.mapValues { .string($0) }),
      "voiceDefaultRevisions": .object(voiceDefaultRevisions.mapValues { .number(Double($0)) }),
      "voiceMode": .string(voiceMode), "voiceEffort": .string(voiceEffort), "language": .string(language), "transcriptionPrompt": .string(transcriptionPrompt),
      "waitMs": .number(Double(waitMs)), "threshold": .number(threshold), "echoCancel": .bool(echoCancel),
      "aiNoticeAccepted": .bool(aiNoticeAccepted),
    ]
  }

  /// Takes what was saved, putting every value back into its allowed range.
  public mutating func restore(_ j: JSONValue) {
    aiNoticeAccepted = j["aiNoticeAccepted"]?.bool ?? false
    tools = j["tools"]?.bool ?? true
    maxTokens = min(max(j["maxTokens"]?.int ?? 0, 0), 32768)
    let font = j["messageFontSize"]?.double
    messageFontSize = font.flatMap { Self.fontSizes.contains($0) ? $0 : nil } ?? 16
    instructions = j["instructions"]?.string ?? ""
    apiKey = j["apiKey"]?.string ?? ""
    speechModel = j["speechModel"]?.string ?? ""
    voices = (j["voices"]?.object ?? [:]).compactMapValues { $0.string }
    voiceDefaultRevisions = [:]
    for (key, value) in j["voiceDefaultRevisions"]?.object ?? [:] {
      if let n = value.double, n > 0, let whole = wholeNumber(n) { voiceDefaultRevisions[key] = whole }
    }
    voiceMode = j["voiceMode"]?.string == "vad" ? "vad" : "ptt"
    // Saved before calls had their own strength (or with a value this app does not know): follow the server.
    let savedEffort = j["voiceEffort"]?.string ?? ""
    voiceEffort = Self.efforts.contains(savedEffort) ? savedEffort : ""
    let savedLanguage = j["language"]?.string ?? ""
    language = Self.languages.contains(savedLanguage) ? savedLanguage : ""
    transcriptionPrompt = TextClip.clip(j["transcriptionPrompt"]?.string ?? "", 500)
    let wait = min(max(j["waitMs"]?.int ?? 800, 300), 5000)
    waitMs = Self.waits.min { abs($0 - wait) < abs($1 - wait) || (abs($0 - wait) == abs($1 - wait) && $0 < $1) } ?? 800
    threshold = min(max(j["threshold"]?.double ?? 0.5, 0.2), 0.8)
    echoCancel = j["echoCancel"]?.bool ?? true
  }
}
