import UIKit

/// The attachments of the message being written, inside the box above its text: a row of square tiles (a picture shows itself, a file
/// shows its first page with its kind on a label), each with a round button that takes it off. The row scrolls sideways when it is
/// longer than the box. Its height is nothing when there is nothing in it.
final class ComposerAttachments: UIView {
  static let tile: CGFloat = 110
  /// The tiles when the room above the keyboard is short (a phone on its side, typing): the box must not reach past the screen's top.
  static let smallTile: CGFloat = 60
  /// Room above the tiles (the box's edge) and before the first one.
  static let inset: CGFloat = 12
  /// The tiles' corners follow the box's (its radius less the room between them), so the two curves run side by side.
  static let radius: CGFloat = 16

  /// A picture for a tile: the attachment's own for a picture, its first page for a file (nil: a plain mark is shown).
  var thumbnail: ((Attachment, @escaping (UIImage?) -> Void) -> Void)?
  var onRemove: ((String) -> Void)?
  /// The row's height changed (it came or went, or its tiles changed their size).
  var onHeight: (() -> Void)?
  /// The tiles' side: `tile`, or `smallTile` where the room is short.
  var side: CGFloat = ComposerAttachments.tile {
    didSet {
      guard side != oldValue else { return }
      rebuild(added: false)
    }
  }

  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private var height: NSLayoutConstraint!
  private var items: [Attachment] = []
  private var shown: [String] = []
  private var loadingShown = false
  /// The pictures already made for the tiles (the row is made again when one is added or taken off: they must not flicker), and the
  /// ones still being made (asked for once, whatever tile shows the attachment when it comes).
  private var thumbs: [String: UIImage] = [:]
  private var asked: Set<String> = []
  /// The ones that gave no picture: not asked for again at every rebuild (the mark of a file stays on their tile).
  private var gaveUp: Set<String> = []

  /// Nothing in the row (and nothing on its way).
  var isEmpty: Bool { items.isEmpty && !loadingShown }

  /// The row is never left scrolled past what is in it (a turn to a wider box, a tile taken off, a first layout that had no width).
  override func layoutSubviews() {
    super.layoutSubviews()
    let end = max(0, scroll.contentSize.width - scroll.bounds.width)
    if scroll.contentOffset.x > end + 0.5 { scroll.setContentOffset(CGPoint(x: end, y: 0), animated: false) }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    stack.axis = .horizontal
    stack.spacing = 8
    stack.alignment = .top
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceHorizontal = false
    scroll.clipsToBounds = false
    addSubview(scroll)
    scroll.addSubview(stack)
    height = heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Self.inset),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Self.inset),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Self.inset),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
      height,
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  func apply(_ items: [Attachment], loading: Bool) {
    let ids = items.map(\.id)
    guard ids != shown || loading != loadingShown else { return }
    let added = ids.count > shown.count || (loading && !loadingShown)
    self.items = items
    shown = ids
    loadingShown = loading
    thumbs = thumbs.filter { ids.contains($0.key) }
    gaveUp = gaveUp.filter { ids.contains($0) }
    rebuild(added: added)
  }

  private func rebuild(added: Bool) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for item in items {
      let tile = AttachmentTile(item: item, side: side) { [weak self] in self?.onRemove?(item.id) }
      stack.addArrangedSubview(tile)
      if let known = thumbs[item.id] {
        tile.set(known)
      } else if !asked.contains(item.id), !gaveUp.contains(item.id), let thumbnail {
        asked.insert(item.id)
        thumbnail(item) { [weak self] image in
          guard let self else { return }
          self.asked.remove(item.id)
          // Kept only for one that is still there; given to the tile that shows it now (the row may have been made again meanwhile).
          guard self.shown.contains(item.id) else { return }
          guard let image else {
            self.gaveUp.insert(item.id)
            return
          }
          self.thumbs[item.id] = image
          self.stack.arrangedSubviews.compactMap { $0 as? AttachmentTile }.first { $0.id == item.id }?.set(image)
        }
      }
    }
    if loadingShown { stack.addArrangedSubview(AttachmentTile.loading(side: side)) }
    let target: CGFloat = items.isEmpty && !loadingShown ? 0 : side + Self.inset
    if abs(height.constant - target) > 0.5 {
      height.constant = target
      onHeight?()
    }
    layoutIfNeeded()
    // The newest one is brought into view (not before the row has a width and a window: it would be scrolled past what is there).
    if added, window != nil, scroll.bounds.width > 1 {
      let end = max(0, scroll.contentSize.width - scroll.bounds.width)
      scroll.setContentOffset(CGPoint(x: end, y: 0), animated: true)
    }
  }
}

/// One square of the row: a picture, or a file's first page on a card with its kind written under it; the round button at its top right
/// takes it off.
private final class AttachmentTile: UIView {
  let id: String
  private let image = UIImageView()
  private let page = UIImageView()
  private let file: Bool
  private let side: CGFloat
  /// A small tile has no label, and a smaller button.
  private var small: Bool { side < 80 }

  init(item: Attachment, side: CGFloat, remove: @escaping () -> Void) {
    id = item.id
    file = item.kind != "image"
    self.side = side
    super.init(frame: .zero)
    build()
    accessibilityLabel = item.name
    if file {
      backgroundColor = Palette.containerHigh
      let label = Self.label(for: item)
      let pill = PaddedLabel()
      pill.text = label
      pill.font = .systemFont(ofSize: 13, weight: .medium)
      pill.textColor = .white
      pill.backgroundColor = UIColor.black.withAlphaComponent(0.72)
      pill.layer.cornerRadius = 11
      pill.layer.cornerCurve = .continuous
      pill.clipsToBounds = true
      pill.translatesAutoresizingMaskIntoConstraints = false
      page.contentMode = .scaleAspectFill
      page.clipsToBounds = true
      page.backgroundColor = .white
      page.layer.cornerRadius = 2
      page.image = UIImage(systemName: "doc.text", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .light))
      page.tintColor = UIColor(white: 0.55, alpha: 1)
      page.contentMode = .center
      page.translatesAutoresizingMaskIntoConstraints = false
      addSubview(page)
      addSubview(pill)
      pill.isHidden = small
      NSLayoutConstraint.activate([
        page.topAnchor.constraint(equalTo: topAnchor, constant: side * 0.12),
        page.centerXAnchor.constraint(equalTo: centerXAnchor),
        page.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.62),
        page.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -side * 0.1),
        pill.centerXAnchor.constraint(equalTo: centerXAnchor),
        pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -side * 0.08),
        pill.heightAnchor.constraint(equalToConstant: 22),
      ])
      accessibilityLabel = "\(label)，\(item.name)"
    } else {
      backgroundColor = Palette.containerHigh
      image.contentMode = .scaleAspectFill
      image.clipsToBounds = true
      image.translatesAutoresizingMaskIntoConstraints = false
      insertSubview(image, at: 0)
      NSLayoutConstraint.activate([
        image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor),
        image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
      ])
      accessibilityLabel = "图片，\(item.name)"
    }
    let close = WideHitButton(type: .system)
    var c = UIButton.Configuration.filled()
    c.cornerStyle = .capsule
    c.baseBackgroundColor = UIColor.black.withAlphaComponent(0.62)
    c.baseForegroundColor = .white
    c.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
    c.contentInsets = .zero
    close.configuration = c
    close.accessibilityLabel = "移除附件 \(item.name)"
    close.translatesAutoresizingMaskIntoConstraints = false
    close.addAction(UIAction { _ in remove() }, for: .touchUpInside)
    addSubview(close)
    // (drawn at 26 pt, it answers a touch over 44: see `WideHitButton`)
    let button: CGFloat = small ? 20 : 26
    let margin: CGFloat = small ? 4 : 6
    NSLayoutConstraint.activate([
      close.widthAnchor.constraint(equalToConstant: button), close.heightAnchor.constraint(equalToConstant: button),
      close.topAnchor.constraint(equalTo: topAnchor, constant: margin),
      close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
    ])
    isAccessibilityElement = false
    accessibilityElements = [close]
    close.accessibilityHint = accessibilityLabel
  }

  required init?(coder: NSCoder) { fatalError() }

  /// A tile that only says something is on its way (a picture being made smaller, a file being read).
  static func loading(side: CGFloat) -> UIView {
    let tile = UIView()
    tile.backgroundColor = Palette.containerHigh
    tile.layer.cornerRadius = ComposerAttachments.radius
    tile.layer.cornerCurve = .continuous
    tile.translatesAutoresizingMaskIntoConstraints = false
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.startAnimating()
    spinner.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(spinner)
    NSLayoutConstraint.activate([
      tile.widthAnchor.constraint(equalToConstant: side),
      tile.heightAnchor.constraint(equalToConstant: side),
      spinner.centerXAnchor.constraint(equalTo: tile.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
    ])
    tile.accessibilityLabel = "附件处理中"
    tile.isAccessibilityElement = true
    return tile
  }

  private func build() {
    layer.cornerRadius = ComposerAttachments.radius
    layer.cornerCurve = .continuous
    clipsToBounds = true
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: side),
      heightAnchor.constraint(equalToConstant: side),
    ])
  }

  func set(_ picture: UIImage?) {
    guard let picture else { return }
    if file {
      page.contentMode = .scaleAspectFill
      page.image = picture
    } else {
      image.image = picture
    }
  }

  /// The word on a file's label: its kind, from the end of its name.
  private static func label(for item: Attachment) -> String {
    let ext = (item.name as NSString).pathExtension.lowercased()
    if item.mime == "application/pdf" || ext == "pdf" { return "PDF" }
    if ext.isEmpty { return "文件" }
    return String(ext.uppercased().prefix(5))
  }
}

/// A small round button that answers a touch a little outside what is drawn (a 26 pt button over a 44 pt square).
private final class WideHitButton: UIButton {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { bounds.insetBy(dx: -9, dy: -9).contains(point) }
}

/// A label with room around its words (a pill).
private final class PaddedLabel: UILabel {
  private let padding = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
  override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: padding)) }
  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + padding.left + padding.right, height: size.height)
  }
}
