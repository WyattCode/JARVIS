import ImageIO
import UIKit

private let userBubble = Palette.containerHigh
private let cardFill = Palette.card

// MARK: Rows

private func iconButton(_ symbol: String, _ label: String, size: CGFloat = 17) -> UIButton {
  var c = UIButton.Configuration.plain()
  c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .light))
  c.baseForegroundColor = Palette.onSurfaceVariant
  c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 12)
  let b = UIButton(configuration: c)
  b.accessibilityLabel = label
  b.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44), b.heightAnchor.constraint(equalToConstant: 44)])
  return b
}

private func statusLine(_ text: String) -> UIView {
  let spinner = UIActivityIndicatorView(style: .medium)
  spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
  spinner.startAnimating()
  let label = UILabel()
  label.text = text
  label.font = .systemFont(ofSize: 13)
  label.textColor = Palette.onSurfaceVariant
  let s = UIStackView(arrangedSubviews: [spinner, label, UIView()])
  s.alignment = .center
  s.spacing = 4
  return s
}

/// "思考过程": a line that opens the model's reasoning.
final class ReasoningView: UIStackView {
  private let button = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let chevron = UIImageView()
  private let body = SelectableText()
  private let bar = UIView()
  private let box = UIView()
  private var id = ""
  var toggled: ((Bool) -> Void)?

  init() {
    super.init(frame: .zero)
    axis = .vertical
    spacing = 0
    // "思考过程" at the left, the chevron at the far right, as the original's expansion row was.
    titleLabel.font = .systemFont(ofSize: 13)
    titleLabel.textColor = Palette.onSurfaceVariant
    chevron.tintColor = Palette.onSurfaceVariant
    let row = UIStackView(arrangedSubviews: [titleLabel, UIView(), chevron])
    row.isUserInteractionEnabled = false
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: button.leadingAnchor), row.trailingAnchor.constraint(equalTo: button.trailingAnchor),
      row.topAnchor.constraint(equalTo: button.topAnchor), row.bottomAnchor.constraint(equalTo: button.bottomAnchor),
    ])
    button.heightAnchor.constraint(equalToConstant: 48).isActive = true
    button.addTarget(self, action: #selector(tap), for: .touchUpInside)
    bar.backgroundColor = MarkdownStyle.line
    bar.translatesAutoresizingMaskIntoConstraints = false
    box.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(bar)
    box.addSubview(body)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: box.leadingAnchor), bar.topAnchor.constraint(equalTo: box.topAnchor),
      bar.bottomAnchor.constraint(equalTo: box.bottomAnchor), bar.widthAnchor.constraint(equalToConstant: 2),
      body.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14), body.trailingAnchor.constraint(equalTo: box.trailingAnchor),
      body.topAnchor.constraint(equalTo: box.topAnchor), body.bottomAnchor.constraint(equalTo: box.bottomAnchor),
    ])
    addArrangedSubview(button)
    addArrangedSubview(box)
    box.isHidden = true
  }

  required init(coder: NSCoder) { fatalError() }

  private(set) var open = false

  func configure(id: String, text: String, thinking: Bool, open: Bool, size: CGFloat) {
    self.id = id
    self.open = open
    titleLabel.text = thinking ? "思考中…" : "思考过程"
    button.accessibilityLabel = titleLabel.text
    button.accessibilityValue = open ? "已展开" : "已收起"
    button.accessibilityHint = open ? "双击收起" : "双击展开"
    chevron.image = UIImage(systemName: open ? "chevron.up" : "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
    box.isHidden = !open
    if open {
      let p = NSMutableParagraphStyle()
      p.minimumLineHeight = (size - 1.5) * 1.6
      p.maximumLineHeight = (size - 1.5) * 1.6
      let f = UIFont.systemFont(ofSize: size - 1.5)
      body.attributedText = NSAttributedString(
        string: text, attributes: [.font: f, .foregroundColor: Palette.onSurfaceVariant, .paragraphStyle: p, .baselineOffset: ((size - 1.5) * 1.6 - f.lineHeight) / 2])
    }
  }

  @objc private func tap() {
    open.toggle()
    toggled?(open)
  }
}

final class AttachmentView: UIView {
  init(att: RowData.Att, bridge: MessageBridge) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    if att.kind == "image" {
      let v = UIImageView()
      v.contentMode = .scaleAspectFill
      v.clipsToBounds = true
      v.layer.cornerRadius = 12
      v.layer.cornerCurve = .continuous
      v.backgroundColor = cardFill
      v.translatesAutoresizingMaskIntoConstraints = false
      addSubview(v)
      NSLayoutConstraint.activate([
        v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
        v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
        widthAnchor.constraint(equalToConstant: 96), heightAnchor.constraint(equalToConstant: 96),
      ])
      PictureCache.shared.load("att:\(att.id)") { v.image = $0 }
    } else {
      var c = UIButton.Configuration.tinted()
      c.cornerStyle = .capsule
      c.image = UIImage(systemName: "doc.text", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
      c.imagePadding = 6
      c.title = att.name
      c.baseForegroundColor = Palette.onSurface
      c.titleLineBreakMode = .byTruncatingMiddle
      let b = UIButton(configuration: c)
      b.translatesAutoresizingMaskIntoConstraints = false
      b.isUserInteractionEnabled = false
      addSubview(b)
      NSLayoutConstraint.activate([
        b.topAnchor.constraint(equalTo: topAnchor), b.bottomAnchor.constraint(equalTo: bottomAnchor),
        b.leadingAnchor.constraint(equalTo: leadingAnchor), b.trailingAnchor.constraint(equalTo: trailingAnchor),
        widthAnchor.constraint(lessThanOrEqualToConstant: 220), heightAnchor.constraint(equalToConstant: 34),
      ])
    }
    isAccessibilityElement = true
    accessibilityLabel = att.name
    // Only a picture opens; a document is shown by its name and has nothing behind it.
    if att.kind == "image" {
      accessibilityTraits = .button
      addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    } else {
      accessibilityTraits = .staticText
    }
    self.att = att
    self.bridge = bridge
  }

  private var att: RowData.Att?
  private weak var bridge: MessageBridge?
  required init?(coder: NSCoder) { fatalError() }
  @objc private func tapped() { if let att { bridge?.send(["a": "attachment", "id": att.id]) } }
}

/// A row of attachments that wraps.
final class AttachmentFlow: UIStackView {
  func apply(_ items: [RowData.Att], bridge: MessageBridge) {
    arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
    axis = .horizontal
    spacing = 6
    alignment = .leading
    for a in items { addArrangedSubview(AttachmentView(att: a, bridge: bridge)) }
    addArrangedSubview(UIView())
    isHidden = items.isEmpty
  }
}

class MessageCell: UITableViewCell {
  var env = ListEnv()
  var bridge: MessageBridge!
  var rowID = ""
  let column = UIView()
  private var active: [NSLayoutConstraint] = []

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none
    column.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(column)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// A cell is measured at the width the table gives it, and its text must know that width first: a text view works out its height
  /// from the width it has, which until it is laid out is the one it had a moment ago (or none), and a long reply came out a good deal
  /// too tall or too short after the list changed its width.
  override func systemLayoutSizeFitting(
    _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
    verticalFittingPriority: UILayoutPriority
  ) -> CGSize {
    guard targetSize.width > 0, targetSize.width < 10_000 else {
      return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
    }
    let moved = abs(contentView.bounds.width - targetSize.width) > 0.5
    if moved {
      bounds.size.width = targetSize.width
      contentView.frame = CGRect(x: 0, y: 0, width: targetSize.width, height: max(contentView.bounds.height, 1))
    }
    // Only when the width really changed is the text laid out again here (a reply that streams in is measured at every piece).
    for _ in 0..<(moved ? 2 : 1) {
      if moved { contentView.setNeedsLayout() }
      contentView.layoutIfNeeded()
    }
    return contentView.systemLayoutSizeFitting(
      CGSize(width: targetSize.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
  }

  /// Places the column: the user's on the right (at most [width] wide), the reply's on the left.
  func place(trailing: Bool, width: CGFloat) {
    NSLayoutConstraint.deactivate(active)
    var cs: [NSLayoutConstraint] = [
      column.topAnchor.constraint(equalTo: contentView.topAnchor),
      column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
      column.widthAnchor.constraint(lessThanOrEqualToConstant: width),
    ]
    if trailing {
      cs += [
        column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -env.right),
        column.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: env.left),
      ]
    } else {
      let fill = column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -env.right)
      // Above the pull of anything inside (a picture asks for its own width at the same strength the column was asked to fill the row
      // with: which of the two won depended on the order the layout took them in, and a card came out as wide as the column, then as
      // narrow as its buttons, and back, as the list was laid out again).
      fill.priority = UILayoutPriority(999)
      cs += [
        column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: env.left),
        column.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -env.right), fill,
      ]
    }
    active = cs
    NSLayoutConstraint.activate(cs)
  }

  func configure(_ row: RowData, env: ListEnv, bridge: MessageBridge, expanded: Bool, toggled: @escaping (Bool) -> Void) {}

}

final class UserCell: MessageCell {
  private let bubble = UIView()
  private let stack = UIStackView()
  private let flow = AttachmentFlow()
  private let text = SelectableText()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    bubble.backgroundColor = userBubble
    bubble.layer.cornerRadius = 20
    bubble.layer.cornerCurve = .continuous
    bubble.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(flow)
    stack.addArrangedSubview(text)
    bubble.addSubview(stack)
    column.addSubview(bubble)
    NSLayoutConstraint.activate([
      bubble.topAnchor.constraint(equalTo: column.topAnchor), bubble.bottomAnchor.constraint(equalTo: column.bottomAnchor),
      bubble.leadingAnchor.constraint(equalTo: column.leadingAnchor), bubble.trailingAnchor.constraint(equalTo: column.trailingAnchor),
      stack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -12),
      stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  override func configure(_ row: RowData, env: ListEnv, bridge: MessageBridge, expanded: Bool, toggled: @escaping (Bool) -> Void) {
    self.env = env
    self.bridge = bridge
    rowID = row.id
    place(trailing: true, width: env.userMax)
    text.widest = env.userMax - 32
    let body = row.text ?? ""
    let f = UIFont.systemFont(ofSize: env.fontSize)
    let height = env.fontSize * 1.6
    let p = NSMutableParagraphStyle()
    p.minimumLineHeight = height
    p.maximumLineHeight = height
    p.baseWritingDirection = MarkdownRenderer.rtl(body) ? .rightToLeft : .natural
    text.attributedText = NSAttributedString(
      string: body, attributes: [.font: f, .foregroundColor: Palette.onSurface, .paragraphStyle: p, .baselineOffset: (height - f.lineHeight) / 2])
    text.isHidden = body.isEmpty
    text.onLink = { bridge.send(["a": "link", "url": $0.absoluteString]) }
    flow.apply(row.attachments ?? [], bridge: bridge)
    text.invalidateIntrinsicContentSize()
    accessibilityLabel = "你"
  }
}

final class AssistantCell: MessageCell {
  private let stack = UIStackView()
  private let reasoning = ReasoningView()
  private let flow = AttachmentFlow()
  private let blocks = BlockStack()
  private let waiting = UIView()
  private let note = UIStackView()
  private let actions = UIStackView()
  private let copy = iconButton("doc.on.doc", "复制回复", size: 11)
  private let regenerate = iconButton("arrow.clockwise", "重新生成", size: 12)
  private var copyTimer: Timer?
  private var currentText = ""

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    waiting.addSubview(statusLine("正在思考…"))
    note.axis = .horizontal
    note.alignment = .center
    note.spacing = 6
    actions.axis = .horizontal
    actions.alignment = .center
    actions.spacing = 0
    actions.addArrangedSubview(copy)
    actions.addArrangedSubview(regenerate)
    actions.addArrangedSubview(UIView())
    for v in [reasoning, flow, waiting, blocks, note, actions] { stack.addArrangedSubview(v) }
    column.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: column.topAnchor, constant: 4), stack.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -4),
      stack.leadingAnchor.constraint(equalTo: column.leadingAnchor), stack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
    ])
    if let line = waiting.subviews.first {
      line.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        line.topAnchor.constraint(equalTo: waiting.topAnchor, constant: 4), line.bottomAnchor.constraint(equalTo: waiting.bottomAnchor, constant: -4),
        line.leadingAnchor.constraint(equalTo: waiting.leadingAnchor), line.trailingAnchor.constraint(equalTo: waiting.trailingAnchor),
      ])
    }
    copy.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
    regenerate.addTarget(self, action: #selector(regenTapped), for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func configure(_ row: RowData, env: ListEnv, bridge: MessageBridge, expanded: Bool, toggled: @escaping (Bool) -> Void) {
    self.env = env
    self.bridge = bridge
    rowID = row.id
    place(trailing: false, width: env.assistantMax)
    let text = row.text ?? ""
    currentText = text
    let status = row.status ?? "complete"
    let generating = status == "generating"
    let reasoningText = row.reasoning ?? ""
    reasoning.isHidden = reasoningText.isEmpty
    if !reasoningText.isEmpty {
      reasoning.configure(id: row.id, text: reasoningText, thinking: generating && text.isEmpty, open: expanded, size: env.fontSize)
      reasoning.toggled = toggled
    }
    flow.apply(row.attachments ?? [], bridge: bridge)
    waiting.isHidden = !(text.isEmpty && generating)
    let rtl = MarkdownRenderer.rtl(text)
    if text.isEmpty {
      blocks.apply([], size: env.fontSize, rtl: rtl, bridge: bridge)
      blocks.isHidden = true
    } else {
      blocks.isHidden = false
      blocks.apply(MarkdownRenderer.blocks(text, style: MarkdownStyle(size: env.fontSize)), size: env.fontSize, rtl: rtl, bridge: bridge)
    }
    // The status note: stopped, failed, cut at the length limit.
    note.arrangedSubviews.forEach { note.removeArrangedSubview($0); $0.removeFromSuperview() }
    note.isHidden = true
    let canAct = (row.lastReply ?? false) && !(row.generating ?? false)
    if status == "interrupted" {
      note.isHidden = false
      let failed = row.error != nil
      let icon = UIImageView(image: UIImage(systemName: failed ? "exclamationmark.circle" : "stop.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)))
      icon.tintColor = failed ? Palette.error : Palette.onSurfaceVariant
      let label = UILabel()
      label.text = row.error ?? "已停止"
      label.font = .systemFont(ofSize: 12)
      label.textColor = failed ? Palette.error : Palette.onSurfaceVariant
      label.numberOfLines = 0
      note.addArrangedSubview(icon)
      note.addArrangedSubview(label)
      if canAct && (row.canRegenerate ?? true) { note.addArrangedSubview(link("重试", "retry")) }
      note.addArrangedSubview(UIView())
    } else if status == "length" {
      note.isHidden = false
      let label = UILabel()
      label.text = "已达到输出长度上限"
      label.font = .systemFont(ofSize: 12)
      note.addArrangedSubview(label)
      if canAct && (row.canContinue ?? false) { note.addArrangedSubview(link("继续生成", "continue")) }
      note.addArrangedSubview(UIView())
    }
    // Copy and regenerate wait until the reply is written.
    actions.isHidden = text.isEmpty || generating
    regenerate.isHidden = !(canAct && status != "interrupted" && (row.canRegenerate ?? true))
    accessibilityLabel = "JARVIS"
  }

  private func link(_ title: String, _ action: String) -> UIButton {
    var c = UIButton.Configuration.plain()
    c.title = title
    c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
    c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var a = $0
      a.font = .systemFont(ofSize: 12)
      return a
    }
    let b = UIButton(configuration: c)
    b.heightAnchor.constraint(equalToConstant: 44).isActive = true
    b.addAction(UIAction { [weak self] _ in self?.bridge.send(["a": action]) }, for: .touchUpInside)
    return b
  }

  @objc private func copyTapped() {
    UIPasteboard.general.string = currentText
    UISelectionFeedbackGenerator().selectionChanged()
    copy.configuration?.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    copy.accessibilityLabel = "已复制"
    copyTimer?.invalidate()
    copyTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in self?.resetCopy() }
  }

  /// The copy button as it is at rest (also for a cell that is used again for another message while "已复制" is up).
  private func resetCopy() {
    copyTimer?.invalidate()
    copyTimer = nil
    copy.configuration?.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .light))
    copy.accessibilityLabel = "复制回复"
  }

  @objc private func regenTapped() { bridge.send(["a": "regenerate"]) }

  override func prepareForReuse() {
    super.prepareForReuse()
    resetCopy()
  }
}

final class ToolCell: MessageCell {
  private var line: UIView?

  override func configure(_ row: RowData, env: ListEnv, bridge: MessageBridge, expanded: Bool, toggled: @escaping (Bool) -> Void) {
    self.env = env
    rowID = row.id
    place(trailing: false, width: env.assistantMax)
    line?.removeFromSuperview()
    let v = statusLine(row.label ?? "正在调用工具…")
    v.translatesAutoresizingMaskIntoConstraints = false
    column.addSubview(v)
    NSLayoutConstraint.activate([
      v.topAnchor.constraint(equalTo: column.topAnchor, constant: 4), v.bottomAnchor.constraint(equalTo: column.bottomAnchor),
      v.leadingAnchor.constraint(equalTo: column.leadingAnchor), v.trailingAnchor.constraint(equalTo: column.trailingAnchor),
    ])
    line = v
  }
}

/// An image or video task: its results, its prompt, its progress and its buttons.
final class TaskCell: MessageCell {
  private let card = UIView()
  private let stack = UIStackView()
  private var saveButton: UIButton?
  private var task: RowData.Task?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TaskCell, _: UITraitCollection) in
      view.card.layer.borderColor = MarkdownStyle.line.cgColor
    }
    card.backgroundColor = cardFill
    card.layer.cornerRadius = 16
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1
    card.layer.borderColor = MarkdownStyle.line.cgColor
    card.clipsToBounds = true
    card.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    column.addSubview(card)
    NSLayoutConstraint.activate([
      card.topAnchor.constraint(equalTo: column.topAnchor, constant: 2), card.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -2),
      card.leadingAnchor.constraint(equalTo: column.leadingAnchor), card.trailingAnchor.constraint(equalTo: column.trailingAnchor),
      stack.topAnchor.constraint(equalTo: card.topAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }


  override func configure(_ row: RowData, env: ListEnv, bridge: MessageBridge, expanded: Bool, toggled: @escaping (Bool) -> Void) {
    self.env = env
    self.bridge = bridge
    rowID = row.id
    guard let task = row.task else { return }
    self.task = task
    place(trailing: false, width: env.userMax)
    stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    let video = task.kind == "video"
    if task.status == "completed" {
      for (i, url) in task.urls.enumerated() {
        if i > 0 { stack.addArrangedSubview(spacer(4)) }
        stack.addArrangedSubview(result(url, video: video, task: task))
      }
    }
    let info = UIStackView()
    info.axis = .vertical
    info.spacing = 8
    info.isLayoutMarginsRelativeArrangement = true
    info.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 4, right: 16)
    let prompt = UILabel()
    prompt.numberOfLines = 3
    prompt.font = .systemFont(ofSize: 16)
    prompt.text = task.prompt.isEmpty ? (video ? "视频任务" : "图片任务") : task.prompt
    info.addArrangedSubview(prompt)
    if task.pending {
      let bar = UIProgressView(progressViewStyle: .bar)
      bar.progress = Float(task.progress / 100)
      if task.progress <= 0 { bar.progress = 0.05 }
      let note = UILabel()
      note.font = .systemFont(ofSize: 12)
      note.textColor = Palette.onSurfaceVariant
      note.text = "后台生成中\(task.progress > 0 ? " · \(Int(task.progress.rounded()))%" : "")，可以继续对话"
      info.addArrangedSubview(bar)
      info.addArrangedSubview(note)
    }
    if let error = task.error {
      let e = UILabel()
      e.numberOfLines = 0
      e.font = .systemFont(ofSize: 14)
      e.textColor = Palette.error
      e.text = error
      info.addArrangedSubview(e)
    }
    stack.addArrangedSubview(info)
    let buttons = UIStackView()
    buttons.axis = .horizontal
    buttons.spacing = 4
    buttons.isLayoutMarginsRelativeArrangement = true
    buttons.layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 6, right: 4)
    if !task.prompt.isEmpty {
      buttons.addArrangedSubview(action("doc.on.doc", "复制提示词") { [weak self] b in
        UIPasteboard.general.string = task.prompt
        UISelectionFeedbackGenerator().selectionChanged()
        b.configuration?.title = "已复制"
        b.configuration?.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { _ = self; b.configuration?.title = "复制提示词"; b.configuration?.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)) }
      })
    }
    if task.status == "completed" && !task.urls.isEmpty {
      let b = action("arrow.down.to.line", task.urls.count > 1 ? "全部保存" : "下载") { [weak self] b in self?.save(b) }
      saveButton = b
      buttons.addArrangedSubview(b)
    }
    if task.pending && task.canCancel {
      buttons.addArrangedSubview(action("xmark", "取消") { [weak self] _ in self?.bridge.send(["a": "cancelTask", "id": task.id]) })
    }
    if !task.pending && task.status != "completed" {
      buttons.addArrangedSubview(action("arrow.clockwise", "重试") { [weak self] _ in self?.bridge.send(["a": "retryTask", "id": task.id]) })
    }
    buttons.addArrangedSubview(UIView())
    stack.addArrangedSubview(buttons)
  }

  private func spacer(_ h: CGFloat) -> UIView {
    let v = UIView()
    v.heightAnchor.constraint(equalToConstant: h).isActive = true
    return v
  }

  private func action(_ symbol: String, _ title: String, _ run: @escaping (UIButton) -> Void) -> UIButton {
    var c = UIButton.Configuration.plain()
    c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    c.title = title
    c.titleLineBreakMode = .byTruncatingTail
    c.imagePadding = 6
    c.baseForegroundColor = Palette.onSurfaceVariant
    c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
    c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var a = $0
      a.font = .systemFont(ofSize: 13)
      return a
    }
    let b = UIButton(configuration: c)
    b.heightAnchor.constraint(equalToConstant: 44).isActive = true
    b.setContentCompressionResistancePriority(.required, for: .horizontal)
    b.addAction(UIAction { [unowned b] _ in run(b) }, for: .touchUpInside)
    return b
  }

  private func save(_ b: UIButton) {
    guard let task else { return }
    b.configuration?.title = "保存中"
    b.isEnabled = false
    bridge.ask(["a": "save", "id": task.id]) { reply in
      b.isEnabled = true
      let result = reply?["result"] as? String ?? "failed"
      let (symbol, title): (String, String) =
        result == "saved" ? ("checkmark.circle", "已保存")
        : result == "denied" ? ("gearshape", "去设置开启") : result == "other" ? ("arrow.down.to.line", task.urls.count > 1 ? "全部保存" : "下载") : ("exclamationmark.circle", "保存失败，点按重试")
      b.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
      b.configuration?.title = title
      DispatchQueue.main.asyncAfter(deadline: .now() + (result == "denied" ? 9 : 2.2)) {
        if result == "denied" { return }
        b.configuration?.image = UIImage(systemName: "arrow.down.to.line", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        b.configuration?.title = task.urls.count > 1 ? "全部保存" : "下载"
      }
    }
  }

  private func result(_ url: String, video: Bool, task: RowData.Task) -> UIView {
    let open = { [weak self] in self?.bridge.send(["a": "preview", "kind": task.kind, "url": url, "prompt": task.prompt, "id": task.id]) }
    if video {
      let v = UIView()
      v.translatesAutoresizingMaskIntoConstraints = false
      var hash = 0
      for u in task.id.unicodeScalars { hash = (hash &* 31 &+ Int(u.value)) & 0x7fffffff }
      let hue = CGFloat(hash % 360) / 360
      let gradient = CAGradientLayer()
      gradient.colors = [UIColor(hue: hue, saturation: 0.45, brightness: 0.4, alpha: 1).cgColor, UIColor(hue: (hue + 0.11).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.2, alpha: 1).cgColor]
      gradient.startPoint = .zero
      gradient.endPoint = CGPoint(x: 1, y: 1)
      let layerView = GradientView(gradient)
      layerView.translatesAutoresizingMaskIntoConstraints = false
      v.addSubview(layerView)
      let cover = UIImageView()
      cover.contentMode = .scaleAspectFill
      cover.clipsToBounds = true
      cover.translatesAutoresizingMaskIntoConstraints = false
      v.addSubview(cover)
      if let known = VideoCover.cached(url) {
        cover.image = known
      } else {
        Task { @MainActor [weak cover] in
          let image = await VideoCover.cover(url)
          cover?.image = image
        }
      }
      let play = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)))
      play.tintColor = UIColor.white.withAlphaComponent(0.9)
      play.translatesAutoresizingMaskIntoConstraints = false
      v.addSubview(play)
      NSLayoutConstraint.activate([
        layerView.topAnchor.constraint(equalTo: v.topAnchor), layerView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        layerView.leadingAnchor.constraint(equalTo: v.leadingAnchor), layerView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        cover.topAnchor.constraint(equalTo: v.topAnchor), cover.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        cover.leadingAnchor.constraint(equalTo: v.leadingAnchor), cover.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        play.centerXAnchor.constraint(equalTo: v.centerXAnchor), play.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        v.heightAnchor.constraint(equalTo: v.widthAnchor, multiplier: 9.0 / 16.0),
      ])
      v.isAccessibilityElement = true
      v.accessibilityLabel = task.prompt.isEmpty ? "播放视频" : "播放视频：\(task.prompt)"
      v.accessibilityTraits = .button
      v.addGestureRecognizer(ClosureTap { open() })
      return v
    }
    let p = PictureBlockView(key: "url:\(url)", alt: task.prompt) { open() }
    return p
  }
}

final class GradientView: UIView {
  let gradient: CAGradientLayer
  init(_ g: CAGradientLayer) {
    gradient = g
    super.init(frame: .zero)
    layer.addSublayer(g)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews()
    gradient.frame = bounds
  }
}

final class ClosureTap: UITapGestureRecognizer {
  private let run: () -> Void
  init(_ run: @escaping () -> Void) {
    self.run = run
    super.init(target: nil, action: nil)
    addTarget(self, action: #selector(fire))
  }
  @objc private func fire() { run() }
}
