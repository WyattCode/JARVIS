import Foundation

/// A Swift String cannot hold an unpaired surrogate, so what Dart repaired by hand is already well formed here. These
/// keep the other rules of `text_clip.dart`: cut between user-perceived characters, never inside an emoji or a flag.
public enum TextClip {
  /// At most `max` characters; `ellipsis` is added after a cut.
  public static func clip(_ text: String, _ max: Int, ellipsis: String = "") -> String {
    guard text.count > max else { return text }
    return String(text.prefix(max)) + ellipsis
  }

  /// A one-line title: runs of whitespace and line breaks become one space, then it is clipped.
  public static func tidyTitle(_ text: String, max: Int = 24) -> String {
    let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    return clip(collapsed, max, ellipsis: "…")
  }
}

/// How model names are shown: the first letter of every word is capitalised and the rest is left alone,
/// e.g. `qwen3-asr-1.7b` -> `Qwen3-Asr-1.7b`.
public func displayModelName(_ name: String) -> String {
  var out = ""
  var start = true
  for ch in name {
    out += start ? String(ch).uppercased() : String(ch)
    start = ch == "-" || ch == "/" || ch == " " || ch == "_" || ch == "("
  }
  return out
}
