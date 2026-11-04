import UIKit

// MARK: Blocks

/// A reply's Markdown cut into the pieces the message list draws: runs of text (paragraphs, headings, lists, quotes, all
/// in one selectable text view), code blocks, tables, pictures and rules.
enum MarkdownBlock {
  case text(NSAttributedString)
  case code(language: String, code: String)
  case table(header: [NSAttributedString], rows: [[NSAttributedString]])
  case image(alt: String, url: String)
  case rule

  /// What the block shows: equal signatures need no redrawing (finished blocks of a streaming reply are kept).
  var signature: String {
    switch self {
    case .text(let s): return "t\(s.string.hashValue)\(s.length)\((s.length > 0 ? (s.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize : nil) ?? 0)"
    case .code(let l, let c): return "c\(l)\(c.hashValue)"
    case .table(let h, let r): return "b\(h.map(\.string))\(r.map { $0.map(\.string) })"
    case .image(let a, let u): return "i\(a)\(u)"
    case .rule: return "r"
    }
  }
}

/// The type of the chat, as Flutter's Markdown style sheet set it: running text with a 1.6 line height, headings a step
/// larger and semibold, monospace code, links in the app's cyan.
struct MarkdownStyle {
  var size: CGFloat

  var body: UIFont { .systemFont(ofSize: size) }
  var lineHeight: CGFloat { size * 1.6 }
  var mono: UIFont { UIFont(name: "Menlo", size: size * 0.9) ?? .monospacedSystemFont(ofSize: size * 0.9, weight: .regular) }

  static let link = Palette.accent
  static let codeBackground = Palette.containerHigh
  static let line = Palette.outlineVariant

  func headingFont(_ level: Int) -> UIFont {
    let factor: CGFloat = level == 1 ? 1.5 : level == 2 ? 1.3 : level == 3 ? 1.15 : 1.0
    return .systemFont(ofSize: size * factor, weight: .semibold)
  }

  func paragraph(
    after: CGFloat, before: CGFloat = 0, indent: CGFloat = 0, hanging: CGFloat = 0, lineHeight: CGFloat? = nil, rtl: Bool = false
  ) -> NSMutableParagraphStyle {
    let p = NSMutableParagraphStyle()
    let height = lineHeight ?? self.lineHeight
    p.minimumLineHeight = height
    p.maximumLineHeight = height
    p.paragraphSpacing = after
    p.paragraphSpacingBefore = before
    p.firstLineHeadIndent = indent
    p.headIndent = indent + hanging
    p.baseWritingDirection = rtl ? .rightToLeft : .natural
    p.alignment = .natural
    if hanging > 0 { p.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)] }
    return p
  }

  /// The attributes that put a line of [font] in the middle of a taller line box.
  func centred(_ font: UIFont, lineHeight: CGFloat? = nil) -> [NSAttributedString.Key: Any] {
    let height = lineHeight ?? self.lineHeight
    return [.baselineOffset: (height - font.lineHeight) / 2]
  }
}

// MARK: Parsing

enum MarkdownParser {
  private static let fence = try! NSRegularExpression(pattern: #"^( {0,15})(`{3,}|~{3,})\s*(\S*)(.*)$"#)
  private static let heading = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$"#)
  private static let rule = try! NSRegularExpression(pattern: #"^ {0,3}([-*_])( *\1){2,} *$"#)
  private static let item = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$"#)
  private static let separator = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)
  private static let imageLine = try! NSRegularExpression(pattern: #"^\s*!\[([^\]]*)\]\(\s*(\S+?)(?:\s+"[^"]*")?\s*\)\s*$"#)

  private static func match(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
  }

  private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
    guard let r = Range(m.range(at: i), in: s) else { return "" }
    return String(s[r])
  }

  enum Raw {
    case paragraph(String)
    case heading(Int, String)
    case item(ordered: Int?, depth: Int, String)
    case quote(String)
    case code(String, String)
    case table([String], [[String]])
    case image(String, String)
    case rule
  }

  /// The opening of a fenced block: its indent, its marks and the language after them. A backtick fence whose words hold a backtick
  /// is not one ("```print(1)``` in a sentence"); a tilde fence may have them.
  static func fenceOpen(_ line: String) -> (indent: Int, mark: String, language: String)? {
    guard let m = match(fence, line) else { return nil }
    let mark = group(m, 2, line), language = group(m, 3, line), rest = group(m, 4, line)
    if mark.first == "`", (language + rest).contains("`") { return nil }
    return (group(m, 1, line).count, mark, language)
  }

  static func isBlockStart(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    return fenceOpen(line) != nil || match(heading, line) != nil || match(rule, line) != nil || match(item, line) != nil
      || t.hasPrefix(">") || match(imageLine, line) != nil
  }

  static func cells(_ line: String) -> [String] {
    var t = line.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("|") { t.removeFirst() }
    // (a closing bar written as "\|" is part of the last cell: the backslashes before it must be an even number to be the edge)
    if t.hasSuffix("|") {
      let slashes = t.dropLast().reversed().prefix { $0 == "\\" }.count
      if slashes % 2 == 0 { t.removeLast() }
    }
    // A bar inside a code span, or escaped with a backslash, is text and not the edge of a cell. "\|" is a bar inside code too (as
    // GitHub reads a table: `grep a\|b` shows a|b); any other backslash is kept as it was written.
    var cells: [String] = []
    var current = ""
    var inCode = false
    let chars = Array(t)
    var skip = false
    for (n, ch) in chars.enumerated() {
      if skip { skip = false; continue }
      if ch == "\\", n + 1 < chars.count, chars[n + 1] == "|" {
        current.append("|")
        skip = true
        continue
      }
      // (a lone backtick is a character: it opens code only when another one closes it further on)
      if ch == "`", inCode || chars[(n + 1)...].contains("`") { inCode.toggle() }
      if ch == "|" && !inCode {
        cells.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      } else {
        current.append(ch)
      }
    }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    return cells
  }

  /// "**注意：**后面": the closing marks come after a punctuation mark and before a letter, which CommonMark does not take as the end of
  /// the bold (it is left as asterisks). The punctuation is moved out of the bold: "**注意**：后面".
  static func cjkEmphasis(_ text: String) -> String {
    guard text.contains("**") else { return text }
    let chars = Array(text)
    // The markers, paired from the left as they open and close, outside code spans.
    var marks: [Int] = []
    var i = 0
    var inCode = false
    while i < chars.count {
      if chars[i] == "`" {
        inCode.toggle()
      } else if !inCode, chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "*" {
        marks.append(i)
        i += 2
        continue
      } else if chars[i] == "\n" {
        // a pair does not run over a line end
        if marks.count % 2 == 1 { marks.removeLast() }
        inCode = false
      }
      i += 1
    }
    if marks.count % 2 == 1 { marks.removeLast() }
    func isMark(_ c: Character) -> Bool { c.isPunctuation || c.isSymbol }
    // From the last pair back, so that the places of the earlier ones stay where they were.
    var out = chars
    var k = marks.count - 2
    while k >= 0 {
      let open = marks[k], close = marks[k + 1]
      let after = close + 2
      var cut = close
      while cut > open + 2, isMark(out[cut - 1]), out[cut - 1] != "*" { cut -= 1 }
      // Only a pair that closes after punctuation and before a letter, with words left inside it, is changed.
      if cut < close, cut > open + 2, after < out.count, out[after].isLetter || out[after].isNumber {
        let moved = Array(out[cut..<close])
        out.replaceSubrange(cut..<(close + 2), with: ["*", "*"] + moved)
      }
      k -= 2
    }
    return String(out)
  }

  static func parse(_ source: String) -> [Raw] {
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var out: [Raw] = []
    var i = 0
    while i < lines.count {
      let line = lines[i]
      if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
      if let open = fenceOpen(line) {
        let mark = open.mark
        let language = open.language
        var body: [String] = []
        i += 1
        while i < lines.count {
          let t = lines[i].trimmingCharacters(in: .whitespaces)
          if t.hasPrefix(String(mark.first!)) && t.count >= mark.count && t.allSatisfy({ $0 == mark.first! }) { i += 1; break }
          // The fence's own indent (a block written inside a list item) is not part of the code.
          var line = Substring(lines[i])
          var drop = open.indent
          while drop > 0, line.first == " " { line.removeFirst(); drop -= 1 }
          body.append(String(line))
          i += 1
        }
        out.append(.code(language, body.joined(separator: "\n")))
        continue
      }
      if let m = match(heading, line) {
        out.append(.heading(group(m, 1, line).count, group(m, 2, line)))
        i += 1
        continue
      }
      if match(rule, line) != nil { out.append(.rule); i += 1; continue }
      if let m = match(imageLine, line) {
        out.append(.image(group(m, 1, line), group(m, 2, line)))
        i += 1
        continue
      }
      if line.contains("|"), i + 1 < lines.count, lines[i + 1].contains("-"), match(separator, lines[i + 1]) != nil,
        lines[i + 1].contains("|") || lines[i + 1].contains("-")
      {
        let header = cells(line)
        var rows: [[String]] = []
        i += 2
        while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
          var r = cells(lines[i])
          while r.count < header.count { r.append("") }
          rows.append(Array(r.prefix(header.count)))
          i += 1
        }
        out.append(.table(header, rows))
        continue
      }
      if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
        var quoted: [String] = []
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
          var t = lines[i].trimmingCharacters(in: .whitespaces)
          t.removeFirst()
          quoted.append(t.hasPrefix(" ") ? String(t.dropFirst()) : t)
          i += 1
        }
        out.append(.quote(quoted.joined(separator: "\n")))
        continue
      }
      if let m = match(item, line) {
        // (a tab counts as four spaces: a nested item written with tabs was at the top)
        let indent = group(m, 1, line).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let marker = group(m, 2, line)
        var text = group(m, 3, line)
        i += 1
        // A line that carries on the item: indented, no marker of its own.
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, match(item, lines[i]) == nil,
          lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t"), !isBlockStart(lines[i])
        {
          text = joined([text, lines[i].trimmingCharacters(in: .whitespaces)])
          i += 1
        }
        let number = Int(marker.dropLast())
        out.append(.item(ordered: number, depth: min(3, indent / 2), text))
        continue
      }
      var paragraph = [line.trimmingCharacters(in: .whitespaces)]
      i += 1
      while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !isBlockStart(lines[i]) {
        // A table starts under a paragraph without a blank line.
        if lines[i].contains("|"), i + 1 < lines.count, match(separator, lines[i + 1]) != nil { break }
        paragraph.append(lines[i].trimmingCharacters(in: .whitespaces))
        i += 1
      }
      out.append(.paragraph(joined(paragraph)))
    }
    return out
  }

  /// A soft line break reads as a space, except between two Chinese (or other unspaced) characters.
  static func joined(_ lines: [String]) -> String {
    var s = ""
    for line in lines {
      if let last = s.unicodeScalars.last, let first = line.unicodeScalars.first, isUnspaced(last), isUnspaced(first) {
        s += line
      } else if s.isEmpty {
        s = line
      } else {
        s += " " + line
      }
    }
    return s
  }

  private static func isUnspaced(_ u: Unicode.Scalar) -> Bool {
    (0x3000...0x9FFF).contains(u.value) || (0xFF00...0xFFEF).contains(u.value) || (0x20000...0x2FFFF).contains(u.value)
  }
}

// MARK: Rendering

enum MarkdownRenderer {
  static func rtl(_ s: String) -> Bool {
    for u in s.unicodeScalars where CharacterSet.letters.contains(u) {
      let v = u.value
      return (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
    }
    return false
  }

  /// Inline Markdown (bold, italic, code, strikethrough, links) as attributed text on [base] attributes.
  static func inline(
    _ text: String, style: MarkdownStyle, font: UIFont, color: UIColor = Palette.onSurface, base: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    options.failurePolicy = .returnPartiallyParsedIfPossible
    let prepared = MarkdownParser.cjkEmphasis(text)
    let parsed = (try? AttributedString(markdown: prepared, options: options)) ?? AttributedString(text)
    let out = NSMutableAttributedString()
    for run in parsed.runs {
      var attributes = base
      attributes[.foregroundColor] = color
      var f = font
      let intent = run.inlinePresentationIntent ?? []
      var traits: UIFontDescriptor.SymbolicTraits = []
      if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
      if intent.contains(.emphasized) { traits.insert(.traitItalic) }
      if !traits.isEmpty, let d = font.fontDescriptor.withSymbolicTraits(traits.union(font.fontDescriptor.symbolicTraits)) {
        f = UIFont(descriptor: d, size: font.pointSize)
      }
      if intent.contains(.code) {
        f = style.mono
        attributes[.backgroundColor] = MarkdownStyle.codeBackground
      }
      if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      attributes[.font] = f
      if let link = run.link {
        attributes[.link] = link
        attributes[.foregroundColor] = MarkdownStyle.link
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
      }
      out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
    }
    return out
  }

  static func blocks(_ source: String, style: MarkdownStyle) -> [MarkdownBlock] {
    let raws = MarkdownParser.parse(source)
    var out: [MarkdownBlock] = []
    var run = NSMutableAttributedString()

    func flush() {
      if run.length > 0 {
        // The last paragraph's spacing after it is the stack's job.
        let last = run.length - 1
        if run.string.hasSuffix("\n") { run.deleteCharacters(in: NSRange(location: last, length: 1)) }
        out.append(.text(run))
        run = NSMutableAttributedString()
      }
    }

    func append(_ piece: NSAttributedString, paragraph: NSParagraphStyle) {
      let m = NSMutableAttributedString(attributedString: piece)
      m.append(NSAttributedString(string: "\n"))
      m.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: m.length))
      run.append(m)
    }

    var orderedCounters: [Int: Int] = [:]
    for (index, raw) in raws.enumerated() {
      let next: MarkdownParser.Raw? = index + 1 < raws.count ? raws[index + 1] : nil
      var nextIsItem = false
      if case .item = next { nextIsItem = true }
      switch raw {
      case .paragraph(let t):
        orderedCounters = [:]
        let dir = rtl(t)
        append(
          inline(t, style: style, font: style.body, base: style.centred(style.body)),
          paragraph: style.paragraph(after: 8, rtl: dir))
      case .heading(let level, let t):
        orderedCounters = [:]
        let f = style.headingFont(level)
        let height = max(style.lineHeight, f.lineHeight * 1.25)
        append(
          inline(t, style: style, font: f, base: style.centred(f, lineHeight: height)),
          paragraph: style.paragraph(after: 8, before: run.length == 0 ? 0 : (level <= 2 ? 12 : 10), lineHeight: height, rtl: rtl(t)))
      case .item(let ordered, let depth, let t):
        let indent = 10 + CGFloat(depth) * 20
        var marker = "•"
        if let ordered {
          let n = (orderedCounters[depth] ?? (ordered - 1)) + 1
          orderedCounters[depth] = n
          marker = "\(n)."
        } else {
          orderedCounters[depth] = nil
        }
        let line = NSMutableAttributedString(
          string: marker + "\t", attributes: [.font: style.body, .foregroundColor: Palette.onSurfaceVariant] + style.centred(style.body))
        line.append(inline(t, style: style, font: style.body, base: style.centred(style.body)))
        // The words start after the marker with room to spare: a two-digit number ("10.", "12.") is wider than the fixed 20 pt and
        // its tab then jumped to the next line, leaving the number alone above its words.
        let markerWidth = ceil((marker as NSString).size(withAttributes: [.font: style.body]).width)
        append(line, paragraph: style.paragraph(after: nextIsItem ? 10 : 10, indent: indent, hanging: max(20, markerWidth + 8)))
      case .quote(let t):
        orderedCounters = [:]
        // Every line of the quote has its bar, not the first alone.
        let q = NSMutableAttributedString()
        for (k, quoted) in t.components(separatedBy: "\n").enumerated() {
          if k > 0 { q.append(NSAttributedString(string: "\n", attributes: style.centred(style.body))) }
          q.append(NSAttributedString(
            string: "▎ ", attributes: [.font: style.body, .foregroundColor: MarkdownStyle.line] + style.centred(style.body)))
          q.append(inline(quoted, style: style, font: style.body, color: Palette.onSurfaceVariant, base: style.centred(style.body)))
        }
        append(q, paragraph: style.paragraph(after: 8, indent: 0, hanging: 14))
      case .code(let language, let code):
        flush()
        orderedCounters = [:]
        out.append(.code(language: language, code: code))
      case .table(let header, let rows):
        flush()
        orderedCounters = [:]
        let small = UIFont.systemFont(ofSize: style.size * 0.95)
        let bold = UIFont.systemFont(ofSize: style.size * 0.95, weight: .semibold)
        out.append(
          .table(
            header: header.map { inline($0, style: style, font: bold, base: [:]) },
            rows: rows.map { $0.map { inline($0, style: style, font: small, base: [:]) } }))
      case .image(let alt, let url):
        flush()
        orderedCounters = [:]
        out.append(.image(alt: alt, url: url))
      case .rule:
        flush()
        orderedCounters = [:]
        out.append(.rule)
      }
    }
    flush()
    return out
  }
}

func + (lhs: [NSAttributedString.Key: Any], rhs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
  lhs.merging(rhs) { _, new in new }
}
