import ImageIO
import UIKit

// MARK: Blocks

final class CodeBlockView: UIView {
  private let language = UILabel()
  private let copy = UIButton(type: .system)
  private let scroll = UIScrollView()
  private let label = UILabel()
  private var code = ""
  private var timer: Timer?

  init(language lang: String, code: String, size: CGFloat) {
    super.init(frame: .zero)
    self.code = code
    backgroundColor = MarkdownStyle.codeBackground
    layer.cornerRadius = 10
    layer.cornerCurve = .continuous
    clipsToBounds = true
    translatesAutoresizingMaskIntoConstraints = false

    language.text = lang
    language.font = .systemFont(ofSize: 12)
    language.textColor = Palette.onSurfaceVariant
    var configuration = UIButton.Configuration.plain()
    configuration.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    configuration.title = "复制"
    configuration.imagePadding = 4
    configuration.baseForegroundColor = Palette.onSurfaceVariant
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var a = $0
      a.font = .systemFont(ofSize: 12)
      return a
    }
    copy.configuration = configuration
    copy.addTarget(self, action: #selector(copied), for: .touchUpInside)
    copy.accessibilityLabel = "复制代码"

    let header = UIStackView(arrangedSubviews: [language, UIView(), copy])
    header.alignment = .center
    header.isLayoutMarginsRelativeArrangement = true
    header.layoutMargins = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 2)
    header.translatesAutoresizingMaskIntoConstraints = false

    label.font = UIFont(name: "Menlo", size: size * 0.9) ?? .monospacedSystemFont(ofSize: size * 0.9, weight: .regular)
    label.textColor = Palette.onSurface
    label.numberOfLines = 0
    let p = NSMutableParagraphStyle()
    p.lineHeightMultiple = 1.25
    label.attributedText = NSAttributedString(string: code, attributes: [.font: label.font!, .foregroundColor: Palette.onSurface, .paragraphStyle: p])
    label.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(label)
    scroll.alwaysBounceHorizontal = false
    scroll.showsHorizontalScrollIndicator = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(header)
    addSubview(scroll)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: 36),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      label.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 14),
      label.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -14),
      label.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      label.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -14),
      scroll.heightAnchor.constraint(equalTo: scroll.contentLayoutGuide.heightAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func copied() {
    UIPasteboard.general.string = code
    UISelectionFeedbackGenerator().selectionChanged()
    copy.configuration?.title = "已复制"
    copy.configuration?.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    copy.configuration?.baseForegroundColor = MarkdownStyle.link
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
      self?.copy.configuration?.title = "复制"
      self?.copy.configuration?.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
      self?.copy.configuration?.baseForegroundColor = Palette.onSurfaceVariant
    }
  }
}

final class TableBlockView: UIView {
  private let scroll = UIScrollView()
  private let content = UIView()
  private var built = false
  private let header: [NSAttributedString]
  private let rows: [[NSAttributedString]]
  private var widths: [CGFloat] = []
  private var heights: [CGFloat] = []
  private var width: CGFloat = 0
  var contentWidth: CGFloat { widths.reduce(0, +) }

  init(header: [NSAttributedString], rows: [[NSAttributedString]]) {
    self.header = header
    self.rows = rows
    super.init(frame: .zero)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TableBlockView, _: UITraitCollection) in
      view.layer.borderColor = MarkdownStyle.line.cgColor
    }
    translatesAutoresizingMaskIntoConstraints = false
    layer.cornerRadius = 10
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = MarkdownStyle.line.cgColor
    clipsToBounds = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = true
    scroll.addSubview(content)
    addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    measure()
    heightAnchor.constraint(equalToConstant: heights.reduce(0, +)).isActive = true
    build()
  }

  required init?(coder: NSCoder) { fatalError() }


  private func measure() {
    let all = [header] + rows
    let columns = header.count
    widths = (0..<columns).map { c in
      let w = all.map { row in c < row.count ? ceil(row[c].boundingRect(with: CGSize(width: 10_000, height: 1000), options: .usesLineFragmentOrigin, context: nil).width) : 0 }.max() ?? 0
      return min(max(w + 24, 64), 280)
    }
    heights = all.map { row in
      (0..<columns).map { c -> CGFloat in
        guard c < row.count else { return 0 }
        let h = row[c].boundingRect(with: CGSize(width: widths[c] - 24, height: 10_000), options: .usesLineFragmentOrigin, context: nil).height
        return ceil(h) + 16
      }.max() ?? 0
    }
  }

  private func build() {
    let all = [header] + rows
    var y: CGFloat = 0
    for (r, row) in all.enumerated() {
      var x: CGFloat = 0
      for c in 0..<widths.count {
        let label = UILabel(frame: CGRect(x: x + 12, y: y + 8, width: widths[c] - 24, height: heights[r] - 16))
        label.numberOfLines = 0
        label.attributedText = c < row.count ? row[c] : nil
        content.addSubview(label)
        x += widths[c]
      }
      if r == 0 {
        let tint = UIView(frame: CGRect(x: 0, y: 0, width: widths.reduce(0, +), height: heights[0]))
        tint.backgroundColor = MarkdownStyle.codeBackground
        content.insertSubview(tint, at: 0)
      }
      y += heights[r]
      if r < all.count - 1 {
        let line = UIView(frame: CGRect(x: 0, y: y - 0.5, width: widths.reduce(0, +), height: 1))
        line.backgroundColor = MarkdownStyle.line
        content.addSubview(line)
      }
    }
    content.frame = CGRect(x: 0, y: 0, width: widths.reduce(0, +), height: y)
    scroll.contentSize = content.frame.size
  }
}

final class PictureBlockView: UIView {
  private let imageView = UIImageView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let failure = UILabel()
  private let key: String
  private let onTap: () -> Void
  private var ratio: NSLayoutConstraint?
  /// The height the place has before the picture comes (taken away when it has).
  private var placeholderHeight: NSLayoutConstraint?

  init(key: String, alt: String, onTap: @escaping () -> Void) {
    self.key = key
    self.onTap = onTap
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    imageView.clipsToBounds = true
    imageView.layer.cornerRadius = 12
    imageView.layer.cornerCurve = .continuous
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.isAccessibilityElement = true
    imageView.accessibilityLabel = alt.isEmpty ? "图片" : alt
    imageView.accessibilityTraits = .button
    spinner.translatesAutoresizingMaskIntoConstraints = false
    failure.text = "无法加载图像。轻点以重试。"
    failure.font = .systemFont(ofSize: 13)
    failure.textColor = Palette.onSurfaceVariant
    failure.textAlignment = .center
    failure.isHidden = true
    failure.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)
    addSubview(spinner)
    addSubview(failure)
    let height = heightAnchor.constraint(equalToConstant: 120)
    height.priority = .defaultHigh
    placeholderHeight = height
    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: topAnchor), imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor), imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
      failure.centerXAnchor.constraint(equalTo: centerXAnchor), failure.centerYAnchor.constraint(equalTo: centerYAnchor),
      height,
    ])
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    load()
  }

  required init?(coder: NSCoder) { fatalError() }

  private var loaded = false

  private func load() {
    spinner.startAnimating()
    failure.isHidden = true
    PictureCache.shared.load(key) { [weak self] image in
      guard let self else { return }
      self.spinner.stopAnimating()
      guard let image else { self.failure.isHidden = false; return }
      self.loaded = true
      self.imageView.image = image
      self.imageView.alpha = 0
      UIView.animate(withDuration: 0.25) { self.imageView.alpha = 1 }
      let size = image.size
      self.ratio?.isActive = false
      let r = self.imageView.heightAnchor.constraint(equalTo: self.imageView.widthAnchor, multiplier: min(1.6, max(0.25, size.height / max(1, size.width))))
      r.isActive = true
      self.ratio = r
      self.placeholderHeight?.isActive = false
      self.invalidateIntrinsicContentSize()
      self.settleRow()
    }
  }

  /// The row it stands in is measured and laid out again for the picture (it stood at the placeholder's size and width, which a picture
  /// that arrives after the row was first laid out left as they were until something else made the list lay out). A picture the cache
  /// already holds arrives inside `init`, before the view is anywhere: it is settled when it gets to a window.
  private var rowSettled = false

  private func settleRow() {
    guard loaded else { return }
    superview?.setNeedsLayout()
    guard let cell = next(of: MessageCell.self) else { return }
    rowSettled = true
    cell.contentView.setNeedsLayout()
    cell.layoutIfNeeded()
    (next(of: MessageListView.self))?.remeasureRows()
    (next(of: MessageListView.self))?.contentChanged()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, !rowSettled { settleRow() }
  }


  /// A picture asks for the same width whatever else is in the row (and whatever the layout pass that is under way): as wide as it may be,
  /// less if there is no room. Without it its width was whatever the things beside it left, and a card came out wide, then as narrow as
  /// its buttons, and back.
  static var widest: CGFloat { ChatLayout.picture }
  private var askedWidth: CGFloat = 0
  override var intrinsicContentSize: CGSize { CGSize(width: Self.widest, height: UIView.noIntrinsicMetric) }

  override func layoutSubviews() {
    super.layoutSubviews()
    if askedWidth != Self.widest {
      askedWidth = Self.widest
      invalidateIntrinsicContentSize()
    }
  }

  @objc private func tapped() {
    if loaded { onTap() } else { load() }
  }
}

extension UIView {
  func next<T>(of type: T.Type) -> T? {
    var responder: UIResponder? = self
    while let r = responder {
      if let match = r as? T { return match }
      responder = r.next
    }
    return nil
  }
}

/// The reply's blocks, one under another; a block that is unchanged is left alone while the reply streams.
final class BlockStack: UIStackView {
  private var signatures: [String] = []

  init() {
    super.init(frame: .zero)
    axis = .vertical
    spacing = 8
    alignment = .fill
    translatesAutoresizingMaskIntoConstraints = false
  }

  required init(coder: NSCoder) { fatalError() }

  /// A long run of text is cut into pieces at line ends. One text view as tall as a whole long reply (thousands of points) is
  /// past what a layer can draw: its far end shows nothing, a blank page with only the buttons under it. Pieces also let a
  /// streaming reply leave the finished ones alone.
  private static func pieces(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
    var out: [MarkdownBlock] = []
    for block in blocks {
      guard case .text(let text) = block, text.length > 900 else { out.append(block); continue }
      let whole = text.string as NSString
      var start = 0
      while start < whole.length {
        var end = min(start + 700, whole.length)
        var drop = 0
        if end < whole.length {
          let line = whole.range(of: "\n", options: [], range: NSRange(location: end, length: min(400, whole.length - end)))
          if line.location == NSNotFound {
            // No line end near: cut after the last sentence mark or space before the limit, never inside a character.
            var cut = min(start + 1100, whole.length)
            let hunt = NSRange(location: end, length: cut - end)
            let marks = CharacterSet(charactersIn: "。！？.!? ，,；;")
            let found = whole.rangeOfCharacter(from: marks, options: .backwards, range: hunt)
            if found.location != NSNotFound { cut = found.location + found.length }
            if cut < whole.length { cut = whole.rangeOfComposedCharacterSequence(at: cut).location }
            end = cut
          } else {
            // The chunk stops before the line end, and the line end itself is dropped: a chunk that ended in "\n" would show an empty
            // last line (a gap at every seam).
            end = line.location
            drop = 1
          }
          // Never cut right after a list marker (a short line such as "12."): its words are on the next line.
          while end < whole.length {
            let before = whole.range(of: "\n", options: .backwards, range: NSRange(location: start, length: end - 1 - start))
            let lineStart = before.location == NSNotFound ? start : before.location + 1
            if end - 1 - lineStart > 4 { break }
            let next = whole.range(of: "\n", options: [], range: NSRange(location: end, length: whole.length - end))
            end = next.location == NSNotFound ? whole.length : next.location + 1
            // The chunk now ends after its line end, which stays in it: nothing after it is to be skipped.
            drop = 0
          }
        }
        out.append(.text(text.attributedSubstring(from: NSRange(location: start, length: end - start))))
        start = end + drop
      }
    }
    return out
  }

  func apply(_ original: [MarkdownBlock], size: CGFloat, rtl: Bool, bridge: MessageBridge) {
    let blocks = Self.pieces(original)
    for (i, block) in blocks.enumerated() {
      let signature = block.signature
      if i < signatures.count, signatures[i] == signature { continue }
      let view = make(block, size: size, rtl: rtl, bridge: bridge)
      if i < arrangedSubviews.count {
        let old = arrangedSubviews[i]
        removeArrangedSubview(old)
        old.removeFromSuperview()
        insertArrangedSubview(view, at: i)
      } else {
        addArrangedSubview(view)
      }
      if i < signatures.count { signatures[i] = signature } else { signatures.append(signature) }
    }
    while arrangedSubviews.count > blocks.count {
      let last = arrangedSubviews.last!
      removeArrangedSubview(last)
      last.removeFromSuperview()
      signatures.removeLast()
    }
  }

  private func make(_ block: MarkdownBlock, size: CGFloat, rtl: Bool, bridge: MessageBridge) -> UIView {
    switch block {
    case .text(let attributed):
      let t = SelectableText()
      t.attributedText = attributed
      t.semanticContentAttribute = rtl ? .forceRightToLeft : .unspecified
      t.onLink = { bridge.send(["a": "link", "url": $0.absoluteString]) }
      return t
    case .code(let language, let code):
      return CodeBlockView(language: language, code: code, size: size)
    case .table(let header, let rows):
      // As wide as its columns, at the left; wider than the reply it scrolls sideways.
      let table = TableBlockView(header: header, rows: rows)
      let holder = UIView()
      holder.translatesAutoresizingMaskIntoConstraints = false
      holder.addSubview(table)
      let exact = table.widthAnchor.constraint(equalToConstant: table.contentWidth)
      exact.priority = .defaultHigh
      NSLayoutConstraint.activate([
        table.topAnchor.constraint(equalTo: holder.topAnchor), table.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        table.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
        table.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor), exact,
      ])
      return holder
    case .image(let alt, let url):
      // A picture in a reply stands at the left at a fixed most (its width does not depend on how the list happens to be laid out).
      let picture = PictureBlockView(key: "url:\(url)", alt: alt) { bridge.send(["a": "preview", "kind": "image", "url": url, "prompt": alt]) }
      let holder = UIView()
      holder.translatesAutoresizingMaskIntoConstraints = false
      holder.addSubview(picture)
      NSLayoutConstraint.activate([
        picture.topAnchor.constraint(equalTo: holder.topAnchor), picture.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        picture.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
        picture.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
      ])
      return holder
    case .rule:
      let v = UIView()
      v.backgroundColor = MarkdownStyle.line
      v.translatesAutoresizingMaskIntoConstraints = false
      v.heightAnchor.constraint(equalToConstant: 1).isActive = true
      return v
    }
  }
}
