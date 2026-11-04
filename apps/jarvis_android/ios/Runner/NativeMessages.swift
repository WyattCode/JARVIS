import ImageIO
import UIKit

// MARK: Data

/// One row of the chat as Flutter describes it. Flutter owns the conversation; the list draws what it is given and reports
/// what the user did.
struct RowData: Codable {
  struct Att: Codable, Hashable {
    var id: String
    var name: String
    var kind: String
  }
  struct Task: Codable {
    var id: String
    var kind: String
    var prompt: String
    var status: String
    var progress: Double
    var urls: [String]
    var error: String?
    var pending: Bool
    var canCancel: Bool
  }
  var id: String
  /// user, assistant, task or tool (the "calling a tool" line).
  var kind: String
  var text: String?
  var reasoning: String?
  var status: String?
  var error: String?
  var attachments: [Att]?
  var lastReply: Bool?
  var canContinue: Bool?
  var generating: Bool?
  var task: Task?
  var label: String?
}

struct ListEnv {
  var fontSize: CGFloat = 16
  var left: CGFloat = 18
  var right: CGFloat = 18
  var userMax: CGFloat = 560
  var assistantMax: CGFloat = 760
}

/// What the list says to its owner and asks of it. Flutter's platform view wires these to a channel; the native chat
/// page wires them straight to the Swift store.
final class MessageBridge {
  /// An action of the user (`{a: ...}`); `done` gets the answer for the ones that have one.
  var act: (([String: Any], @escaping ([String: Any]?) -> Void) -> Void)?
  /// A picture by key (`url:...`, `att:id`).
  var fetch: ((String, @escaping (Data?) -> Void) -> Void)?
  func send(_ a: [String: Any]) { act?(a) { _ in } }
  func ask(_ a: [String: Any], _ done: @escaping ([String: Any]?) -> Void) { act?(a, done) }
}


// MARK: Images

/// Pictures come from the owner (it holds the sign-in and the attachment store); decoded small, kept in memory.
final class PictureCache {
  static let shared = PictureCache()
  private let cache = NSCache<NSString, UIImage>()
  private var waiting: [String: [(UIImage?) -> Void]] = [:]
  weak var bridge: MessageBridge?

  func load(_ key: String, _ done: @escaping (UIImage?) -> Void) {
    if let image = cache.object(forKey: key as NSString) { return done(image) }
    if waiting[key] != nil { waiting[key]?.append(done); return }
    waiting[key] = [done]
    guard let fetch = bridge?.fetch else { return finish(key, nil) }
    fetch(key) { [weak self] data in
      DispatchQueue.global(qos: .userInitiated).async {
        let image = data.flatMap { PictureCache.downsample($0, maxPixel: 1400) }
        DispatchQueue.main.async {
          if let image { self?.cache.setObject(image, forKey: key as NSString) }
          self?.finish(key, image)
        }
      }
    }
  }

  private func finish(_ key: String, _ image: UIImage?) {
    let callbacks = waiting.removeValue(forKey: key) ?? []
    callbacks.forEach { $0(image) }
  }

  static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    return UIImage(cgImage: image)
  }
}

// MARK: Text

final class SelectableText: UITextView, UITextViewDelegate {
  var onLink: ((URL) -> Void)?
  /// The widest this text can be set (the bubble's column less its padding). The height is worked out for the width the text will
  /// really get, not for the one it happens to have now: a short line that grows (a spoken message coming in word by word) would
  /// otherwise be measured at its old, narrow width and stand many lines too tall.
  var widest: CGFloat?

  init() {
    // TextKit 1: TextKit 2 lays text out only for the part it believes is on screen, and inside a self-sizing table cell it
    // believed a long reply's far end was not: the end of the reply stayed blank.
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    super.init(frame: .zero, textContainer: container)
    isEditable = false
    isScrollEnabled = false
    isSelectable = true
    backgroundColor = .clear
    textContainerInset = .zero
    textContainer.lineFragmentPadding = 0
    linkTextAttributes = [:]
    delegate = self
    translatesAutoresizingMaskIntoConstraints = false
    setContentCompressionResistancePriority(.required, for: .vertical)
    setContentHuggingPriority(.required, for: .vertical)
  }

  required init?(coder: NSCoder) { fatalError() }

  // A text view with scrolling off sizes itself from its width.
  override var attributedText: NSAttributedString! {
    didSet { revision &+= 1 }
  }

  /// What was last measured, and for which text and width: measuring a long text is the most expensive thing the list does, and it
  /// used to be done again at every layout pass (several times a frame while a reply streams in).
  private var revision = 0
  /// For the current text: its natural width, and its size at each width it has been asked at (a table measures a cell at several
  /// widths in one pass; a single remembered size would be thrown away by the next).
  private var naturalWidth: (revision: Int, value: CGFloat)?
  private var sizes: [CGFloat: CGSize] = [:]
  private var sizesRevision = -1

  override var intrinsicContentSize: CGSize {
    // As wide as its text wants (a short message makes a narrow bubble); the column caps it, and the height follows the width it gets.
    let wanted = widest ?? (bounds.width > 0 ? bounds.width : 0)
    if sizesRevision != revision { sizes.removeAll(keepingCapacity: true); sizesRevision = revision }
    if let size = sizes[wanted] { return size }
    let natural: CGFloat
    if let n = naturalWidth, n.revision == revision {
      natural = n.value
    } else {
      natural = ceil(attributedText.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: .usesLineFragmentOrigin, context: nil).width) + 2
      naturalWidth = (revision, natural)
    }
    let width = widest.map { min(natural, $0) } ?? (bounds.width > 0 ? bounds.width : max(natural, 1))
    let size = CGSize(width: natural, height: ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    if sizes.count > 6 { sizes.removeAll(keepingCapacity: true) }
    sizes[wanted] = size
    return size
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if intrinsicContentSize.height != lastHeight {
      lastHeight = intrinsicContentSize.height
      invalidateIntrinsicContentSize()
    }
  }
  private var lastHeight: CGFloat = 0

  /// A touch on a link goes to the page (which asks the system to open it, if it is one it may); the system's own preview is not used.
  func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
    guard case .link(let url) = textItem.content else { return defaultAction }
    return UIAction { [weak self] _ in self?.onLink?(url) }
  }

  func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? { nil }
}

// MARK: List

final class MessageListView: UIView, UITableViewDataSource, UITableViewDelegate {
  let table = UITableView(frame: .zero, style: .plain)
  let bridge: MessageBridge
  private var rows: [String: RowData] = [:]
  private var order: [String] = []
  private var env = ListEnv()
  private var heights: [String: CGFloat] = [:]
  private var expanded: Set<String> = []
  private var fresh: Set<String> = []
  private var shown: Set<String> = []

  private var following = true
  /// The finger is on the list, or it is still gliding from a flick: the user's scrolling, not ours.
  private var userScrolling: Bool { table.isTracking || table.isDragging || table.isDecelerating }
  private var lastWidth: CGFloat = 0
  private var lastHeight: CGFloat = 0
  private var share: CGFloat = 1
  private var reportedAway = false
  private var reportedFar = false
  private var lastOffset: CGFloat = 0
  private var observation: NSKeyValueObservation?

  init(bridge: MessageBridge) {
    self.bridge = bridge
    super.init(frame: .zero)
    backgroundColor = .clear
    table.backgroundColor = .clear
    table.separatorStyle = .none
    table.dataSource = self
    table.delegate = self
    table.allowsSelection = false
    table.keyboardDismissMode = .onDrag
    table.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
    table.estimatedRowHeight = 120
    table.rowHeight = UITableView.automaticDimension
    table.cellLayoutMarginsFollowReadableWidth = false
    table.insetsContentViewsToSafeArea = false
    table.contentInsetAdjustmentBehavior = .never
    table.register(UserCell.self, forCellReuseIdentifier: "user")
    table.register(AssistantCell.self, forCellReuseIdentifier: "assistant")
    table.register(TaskCell.self, forCellReuseIdentifier: "task")
    table.register(ToolCell.self, forCellReuseIdentifier: "tool")
    table.frame = bounds
    table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(table)
    let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    tap.cancelsTouchesInView = false
    table.addGestureRecognizer(tap)
    observation = table.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.contentChanged() }
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func tapped() { bridge.send(["a": "tap"]) }

  // MARK: State

  func apply(_ state: [String: Any]) {
    if let size = state["fontSize"] as? Double { env.fontSize = CGFloat(size) }
    if let v = state["left"] as? Double { env.left = CGFloat(v) }
    if let v = state["right"] as? Double { env.right = CGFloat(v) }
    if let v = state["userMax"] as? Double { env.userMax = CGFloat(v) }
    if let v = state["assistantMax"] as? Double { env.assistantMax = CGFloat(v) }
    let envChanged = state["fontSize"] != nil || state["left"] != nil || state["userMax"] != nil
    var changedIDs: [String] = []
    if let changed = state["changed"] as? [String: String] {
      for (id, json) in changed {
        guard let data = json.data(using: .utf8), let row = try? JSONDecoder().decode(RowData.self, from: data) else { continue }
        rows[id] = row
        changedIDs.append(id)
      }
    }
    if let ids = state["fresh"] as? [String] { fresh.formUnion(ids) }
    let newOrder = (state["order"] as? [String]) ?? order
    let orderChanged = newOrder != order
    order = newOrder
    let kept = Set(order)
    rows = rows.filter { kept.contains($0.key) }
    if orderChanged || envChanged {
      if envChanged { heights.removeAll() }
      table.reloadData()
      if following { scrollToBottom() }
      return
    }
    // The same rows: the changed ones are drawn again in place.
    var any = false
    for id in changedIDs {
      guard let i = order.firstIndex(of: id), let cell = table.cellForRow(at: IndexPath(row: i, section: 0)) as? MessageCell, let row = rows[id] else { continue }
      cell.configure(row, env: env, bridge: bridge, expanded: expanded.contains(id)) { [weak self] open in self?.reasoningToggled(id, open) }
      any = true
    }
    if any {
      UIView.performWithoutAnimation {
        table.beginUpdates()
        table.endUpdates()
        table.layoutIfNeeded()
      }
    }
  }

  private func reasoningToggled(_ id: String, _ open: Bool) {
    if open {
      expanded.insert(id)
      // Opening it at the tail would otherwise follow the new bottom and scroll its start away.
      following = false
      report()
    } else {
      expanded.remove(id)
    }
    if let i = order.firstIndex(of: id), let cell = table.cellForRow(at: IndexPath(row: i, section: 0)) as? MessageCell, let row = rows[id] {
      cell.configure(row, env: env, bridge: bridge, expanded: open) { [weak self] o in self?.reasoningToggled(id, o) }
      UIView.animate(withDuration: 0.2) {
        self.table.beginUpdates()
        self.table.endUpdates()
      }
    }
  }

  // MARK: Table

  func numberOfSections(in tableView: UITableView) -> Int { 1 }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { order.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let id = order[indexPath.row]
    let row = rows[id]
    // (every kind is registered, so a cell that is not a MessageCell cannot come; if it did, an empty row is better than a crash)
    guard let cell = tableView.dequeueReusableCell(withIdentifier: row?.kind ?? "assistant", for: indexPath) as? MessageCell else {
      return UITableViewCell()
    }
    if let row {
      cell.configure(row, env: env, bridge: bridge, expanded: expanded.contains(id)) { [weak self] open in self?.reasoningToggled(id, open) }
    } else {
      // No row for it (its data did not decode): nothing of the message this cell showed before is left in it.
      cell.rowID = ""
      cell.prepareForReuse()
    }
    return cell
  }

  func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
    heights[order[indexPath.row]] ?? 120
  }

  func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
    let id = order[indexPath.row]
    if fresh.contains(id), !shown.contains(id), !UIAccessibility.isReduceMotionEnabled {
      cell.contentView.alpha = 0
      cell.contentView.transform = CGAffineTransform(translationX: 0, y: 12)
      UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
        cell.contentView.alpha = 1
        cell.contentView.transform = .identity
      }
    }
    shown.insert(id)
  }

  func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
    // Keyed by the message the cell showed, not by the place: after the list changed, that place holds another message now.
    if let id = (cell as? MessageCell)?.rowID, !id.isEmpty, rows[id] != nil { heights[id] = cell.bounds.height }
  }

  // MARK: Following the tail

  var distanceFromBottom: CGFloat {
    table.contentSize.height + table.contentInset.bottom - (table.contentOffset.y + table.bounds.height)
  }

  func scrollToBottom() {
    let y = max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
    if abs(table.contentOffset.y - y) > 0.5 { table.setContentOffset(CGPoint(x: 0, y: y), animated: false) }
  }

  /// How far the page's floating controls reach up from the bottom edge: the list runs under them, so what scrolls past shows
  /// around the box instead of being cut off by a band of page colour.
  var bottomInset: CGFloat = 0 {
    didSet {
      guard abs(bottomInset - oldValue) > 0.5 else { return }
      let atTail = following && !userScrolling
      table.contentInset.bottom = 16 + bottomInset
      if atTail { scrollToBottom() }
    }
  }

  private var tailScheduled = false

  /// A row grew (a picture arrived, a reply streamed in): while following, the tail stays in view. Done once the layout
  /// pass in progress is over (the table moves the offset itself while it measures rows), and again if it moved on.
  /// The rows are measured again, with no animation (a picture came in, and a row has another height).
  func remeasureRows() {
    guard !frozen else { return }
    UIView.performWithoutAnimation {
      table.beginUpdates()
      table.endUpdates()
    }
  }

  func contentChanged() {
    report()
    guard following, !userScrolling, !tailScheduled else { return }
    tailScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.tailScheduled = false
      guard self.following, !self.userScrolling else { return }
      self.table.layoutIfNeeded()
      self.scrollToBottom()
    }
  }

  /// A different conversation: back to following its tail, whatever the last one was doing.
  func resetScroll() {
    following = true
    reportedAway = false
    reportedFar = false
  }

  func debugDump() -> String {
    var out = "contentSize=\(table.contentSize) offset=\(table.contentOffset) bounds=\(table.bounds) inset=\(table.contentInset)\n"
    for cell in table.visibleCells {
      out += "cell frame=\(cell.frame) alpha=\(cell.contentView.alpha) tf=\(cell.contentView.transform)\n"
      func walk(_ v: UIView, _ d: Int) {
        if d > 4 { return }
        out += String(repeating: "  ", count: d) + "\(type(of: v)) f=\(v.frame) hid=\(v.isHidden) a=\(v.alpha)\n"
        if d < 4 { v.subviews.prefix(6).forEach { walk($0, d + 1) } }
      }
      walk(cell.contentView, 1)
      func stacks(_ v: UIView) {
        if let b = v as? BlockStack {
          out += "BLOCKS count=\(b.arrangedSubviews.count)\n"
          for (i, x) in b.arrangedSubviews.enumerated() where i < 3 || i > b.arrangedSubviews.count - 8 {
            let t = (x as? UITextView)?.attributedText.string.prefix(14) ?? ""
            out += "  [\(i)] \(type(of: x)) f=\(x.frame) hid=\(x.isHidden) a=\(x.alpha) text=\(t)\n"
          }
        }
        v.subviews.forEach(stacks)
      }
      stacks(cell.contentView)
    }
    return out
  }

  func toTail() {
    let y = max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, delay: 0, options: .curveEaseOut, animations: {
      self.table.contentOffset = CGPoint(x: 0, y: y)
    }) { _ in
      self.following = true
      self.report()
    }
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    bridge.send(["a": "drag"])
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { settle() }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

  /// The user let go: near the tail the list follows it again.
  private func settle() {
    following = distanceFromBottom < 64
    report()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let offset = scrollView.contentOffset.y
    let range = scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height
    if range > 0 { share = min(1, max(0, (offset + scrollView.contentInset.top) / (range + scrollView.contentInset.top))) }
    if userScrolling {
      let delta = offset - lastOffset
      following = delta >= 0 && distanceFromBottom < 64
    }
    lastOffset = offset
    report()
  }

  /// Measures every row again (rows that changed while the page was covered, by a call, may still carry an old height).
  func remeasure() {
    guard bounds.width > 0 else { return }
    // Only the rows on screen are measured again; the others keep the heights they had, so the offset still points at the same
    // place (a reload with every height forgotten estimates 120 pt a row and the page lands somewhere else).
    guard !order.isEmpty else { return }
    let visible = table.indexPathsForVisibleRows ?? []
    for path in visible where path.row < order.count { heights[order[path.row]] = nil }
    UIView.performWithoutAnimation {
      table.reloadRows(at: visible, with: .none)
      table.layoutIfNeeded()
    }
    if following { scrollToBottom() }
  }

  private func report() {
    let away = !following
    let far = distanceFromBottom > 400
    if away != reportedAway || far != reportedFar {
      reportedAway = away
      reportedFar = far
      bridge.send(["a": "scroll", "away": away, "far": far])
    }
  }

  /// The list is held as it stands while the chat around it changes its width (see `ChatViewController.beginSettle`): nothing of it is
  /// laid out again until it is let go, and then once, for the width it has by then.
  private(set) var frozen = false

  func freeze(_ on: Bool) {
    guard on != frozen else { return }
    frozen = on
    if on {
      table.autoresizingMask = []
    } else {
      UIView.performWithoutAnimation {
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.frame = bounds
        setNeedsLayout()
        layoutIfNeeded()
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if frozen { return }
    let widthChanged = abs(bounds.width - lastWidth) > 0.5
    let heightChanged = abs(bounds.height - lastHeight) > 0.5
    if widthChanged && lastWidth > 0 {
      // Re-wrapped text: the same share of the conversation stays in view, not the same pixel offset.
      let kept = share
      heights.removeAll()
      // Without animation: when the width changes inside an animation (the list folding away beside the chat) the rows made anew
      // would otherwise fly in from the corner.
      UIView.performWithoutAnimation {
        table.reloadData()
        table.layoutIfNeeded()
        // A cell measures its text at the width the text had a moment ago, and a long reply came out a good deal too tall or too short
        // (blank page under it, or its end cut off). The cells are measured again, now that they stand at the new width, until the page
        // stops changing.
        for _ in 0..<4 {
          let before = table.contentSize.height
          table.beginUpdates()
          table.endUpdates()
          table.layoutIfNeeded()
          if abs(table.contentSize.height - before) < 1 { break }
        }
      }
      if following {
        scrollToBottom()
      } else {
        let range = table.contentSize.height + table.contentInset.bottom - table.bounds.height
        if range > 0 { table.contentOffset.y = kept * (range + table.contentInset.top) - table.contentInset.top }
      }
    } else if heightChanged && lastHeight > 0 && following {
      scrollToBottom()
    }
    lastWidth = bounds.width
    lastHeight = bounds.height
  }
}

// MARK: Platform view

extension JSONValue {
  /// The length of the text a message row carries (0 for anything else): what the pacer judges how often to draw by.
  var stringLength: Int {
    if case .object(let o) = self, case .string(let t)? = o["text"] { return t.utf16.count }
    return 0
  }
}
