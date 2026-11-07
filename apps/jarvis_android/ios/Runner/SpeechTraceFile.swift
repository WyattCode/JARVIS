import Foundation

/// Keeps the call's speech trace (`VoiceSession.speechTrace`) in a file, `Documents/speech-trace.txt`, a line at a time with
/// the clock time in front, so that what happened in a call can be read after it. It holds counts and times only, never words.
final class SpeechTraceFile: @unchecked Sendable {
  static let shared = SpeechTraceFile()
  private let queue = DispatchQueue(label: "speech-trace")
  private let url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("speech-trace.txt")
  private let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  func write(_ line: String) {
    let stamped = clock.string(from: Date()) + " " + line + "\n"
    queue.async { [url] in
      let manager = FileManager.default
      // A new call starts a new file once the old one has grown large.
      if line.contains("=== call start"), let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 400_000 {
        try? manager.removeItem(at: url)
      }
      if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
      guard let handle = try? FileHandle(forWritingTo: url) else { return }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(stamped.utf8))
    }
  }
}
