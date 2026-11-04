import Combine
import SwiftUI
import UIKit

// MARK: Sidebar

/// The sidebar as the original drew it: the brand row, a wide "新建会话" button, the list (search, headings, rows) and the
/// settings row at the foot, on the card colour.
struct SidebarView: View {
  @ObservedObject var list: ConversationListStore
  let foldable: Bool
  let onNew: () -> Void
  let onSettings: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        MarkRep()
          .frame(width: 22, height: 22)
          .frame(width: 32, height: 32)
          .background(Color.black, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        Text("JARVIS").font(.system(size: foldable ? 18 : 20, weight: .semibold)).foregroundStyle(Color(Palette.onSurface))
          .lineLimit(1).minimumScaleFactor(0.7)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 20)
      .padding(.top, 20)
      .padding(.bottom, 20)
      // A new conversation and the settings are in the header now; the list has a heading of its own (the day sections are its headings when there
      // are any, on the drawer too).
      if !list.state.rows.contains(where: { $0.kind == "header" }) {
        Text("最近")
          .font(.system(.subheadline, weight: .semibold))
          .foregroundStyle(Color(Palette.onSurfaceVariant))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20)
          .padding(.bottom, 12)
          .accessibilityAddTraits(.isHeader)
      }
      ConversationListView(store: list)
    }
    .background(Color(Palette.card))
  }
}

@MainActor
final class SidebarViewController: UIHostingController<SidebarView> {
  private let store: JarvisStore
  private let listStore: ConversationListStore
  private var query = ""
  private var bag = Set<AnyCancellable>()
  var onChoose: (() -> Void)?
  var onClose: (() -> Void)?
  var onSettings: (() -> Void)?
  private var searchOpen = false
  private var focusToken = 0
  /// The list stands beside the chat on a wide screen (see `ConversationListState.docked`).
  var docked = false {
    didSet { if docked != oldValue { refresh() } }
  }

  init(store: JarvisStore) {
    self.store = store
    listStore = ConversationListStore(
      state: ConversationListState(rows: [], showSearch: false, empty: false, swipeDelete: false, compact: false))
    super.init(rootView: SidebarView(list: listStore, foldable: false, onNew: {}, onSettings: {}))
    rootView = SidebarView(
      list: listStore, foldable: false, onNew: { [weak self] in self?.newChat() }, onSettings: { [weak self] in self?.openSettings() })
    listStore.send = { [weak self] a in self?.handle(a) }
    // No title: the list has its brand row, and a title would stand in the bar above it.
    navigationItem.title = ""
    navigationItem.largeTitleDisplayMode = .never
    store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.refresh() }
    }.store(in: &bag)
    refresh()
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.card
    // Beside a vertical strip: close, search and new conversation, round glass buttons the system stacks in the strip.
    let image = { (name: String) in UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)) }
    let close = makeCloseButton()
    let search = UIBarButtonItem(image: image("magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.openSearch() })
    search.accessibilityLabel = "搜索会话"
    let fresh = UIBarButtonItem(image: image("square.and.pencil"), primaryAction: UIAction { [weak self] _ in self?.newChat() })
    fresh.accessibilityLabel = "新建会话"
    for item in [close, search, fresh] { item.tintColor = Palette.onSurface }
    searchItem = search
    newItem = fresh
    // A touch anywhere but the search field puts the keyboard away.
    let away = UITapGestureRecognizer(target: self, action: #selector(tappedAway))
    away.cancelsTouchesInView = false
    away.delegate = self
    view.addGestureRecognizer(away)
    navigationItem.leftBarButtonItem = close
    navigationItem.rightBarButtonItems = [fresh, .fixedSpace(0), search]
    let bar = UINavigationBarAppearance()
    bar.configureWithTransparentBackground()
    bar.backgroundColor = Palette.card
    bar.shadowColor = .clear
    navigationItem.standardAppearance = bar
    navigationItem.scrollEdgeAppearance = bar
  }

  @objc private func tappedAway() { view.endEditing(true) }

  /// VoiceOver's two-finger scrub: the open list closes.
  override func accessibilityPerformEscape() -> Bool {
    onClose?()
    return true
  }

  private func makeCloseButton() -> UIBarButtonItem {
    let close = UIBarButtonItem(image: ChatViewController.listIcon(), primaryAction: UIAction { [weak self] _ in self?.onClose?() })
    close.accessibilityLabel = "收起会话列表"
    close.tintColor = Palette.onSurface
    return close
  }

  /// The search button: the first press brings the box in and puts the keyboard in it, the next one takes the box away again
  /// (clearing what was typed, so the whole list is back).
  private func openSearch() {
    if searchOpen {
      searchOpen = false
      query = ""
      view.endEditing(true)
    } else {
      searchOpen = true
      focusToken += 1
    }
    refresh()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyBar()
  }

  /// The bar exists only for the strip; otherwise the list's own header and the drawer's gestures do its work. `windowSize` is the
  /// window's size-to-be while it turns (the root says it before the turn, so the bar is not changed in the turn's first layout).
  private func applyBar(windowSize: CGSize? = nil) {
    let vertical = hasVerticalBar(traitCollection)
    // Held upright (the foldable's inner display, or a straight phone) the list is the whole window and the bar is along the top.
    let size = windowSize ?? view.window?.bounds.size
    let upright = !vertical && (size.map { isInnerDisplayUpright($0) } ?? false || isStraightPortrait(view, size: size))
    let strip = vertical || upright
    if navigationController?.isNavigationBarHidden != !strip { navigationController?.setNavigationBarHidden(!strip, animated: false) }
    // Held upright the top bar has room for the settings too (beside a vertical strip the drawer has the three it always had).
    let items: [UIBarButtonItem] = upright ? [settingsItem, .fixedSpace(0), newItem, .fixedSpace(0), searchItem] : [newItem, .fixedSpace(0), searchItem]
    if navigationItem.rightBarButtonItems?.count != items.count || upright != barUpright {
      barUpright = upright
      navigationItem.rightBarButtonItems = items
    }
  }

  func prepareBar(windowSize: CGSize) { if isViewLoaded { applyBar(windowSize: windowSize) } }

  private var barUpright = false
  private lazy var settingsItem: UIBarButtonItem = {
    let item = UIBarButtonItem(
      image: UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)),
      primaryAction: UIAction { [weak self] _ in self?.openSettings() })
    item.accessibilityLabel = "设置"
    item.tintColor = Palette.onSurface
    return item
  }()
  private var newItem: UIBarButtonItem!
  private var searchItem: UIBarButtonItem!

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyBar()
    let foldable = isFoldablePhone(view)
    guard foldable != lastFoldable else { return }
    lastFoldable = foldable
    rootView = SidebarView(
      list: listStore, foldable: foldable, onNew: { [weak self] in self?.newChat() }, onSettings: { [weak self] in self?.openSettings() })
  }

  private var lastFoldable = false

  private func newChat() {
    _ = store.newConversation()
    onChoose?()
  }

  /// The settings page: from the list it is the chat's own (the list goes, the page is pushed over the chat, and the way back, the
  /// button or the swipe from the edge, is to the chat); alone on a stack of its own only when there is no chat to push on.
  private func openSettings() {
    if let onSettings { return onSettings() }
    let page = SettingsHostController(store: store) { [weak self] in self?.dismiss(animated: true) }
    let nav = UINavigationController(rootViewController: PageContainer(title: "设置", content: page))
    nav.modalPresentationStyle = .fullScreen
    present(nav, animated: true)
  }

  private func refresh() {
    let found = ConversationRows.rows(
      store.conversations, query: query, selected: store.selectedId, generating: { [store] in store.isGenerating($0) }, grouped: true)
    let next = ConversationListState(
      rows: found.rows.map { row in
        let made = ConversationListState.Row(
          kind: row.isHeader ? "header" : "conversation", id: row.id, title: row.title, selected: row.selected, generating: row.generating)
        return made
      },
      showSearch: searchOpen,
      empty: found.found == 0, swipeDelete: false, compact: false, focus: focusToken, docked: docked)
    // Streaming changes the store at every piece; the list is told only when it would look different.
    if next != listStore.state { listStore.state = next }
  }

  /// How a conversation ends, in one line: its last message, or what a new one says.
  private static func ending(of c: Conversation) -> String {
    guard let last = c.messages.last(where: { !$0.hidden && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
      return c.messages.isEmpty ? "还没有消息" : "图片或文件"
    }
    let line = last.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? last.text
    return (last.role == "user" ? "我：" : "") + line.trimmingCharacters(in: .whitespaces)
  }

  /// When it was last at: the time today, "昨天", or the date.
  private static func when(_ c: Conversation) -> String {
    guard let at = ConversationRows.lastActive(c) else { return "" }
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    if calendar.isDateInToday(at) { formatter.dateFormat = "HH:mm"; return formatter.string(from: at) }
    if calendar.isDateInYesterday(at) { return "昨天" }
    formatter.dateFormat = calendar.isDate(at, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
    return formatter.string(from: at)
  }

  private func handle(_ a: [String: Any]) {
    switch a["a"] as? String {
    case "select":
      if let id = a["id"] as? String {
        store.select(id)
        onChoose?()
      }
    case "delete":
      guard let id = a["id"] as? String else { return }
      if store.canDeleteConversation(id) {
        let title = store.conversation(id)?.title ?? "这个会话"
        guard let window = view.window else { return }
        GlassConfirmDialog.show(
          title: "删除会话", lines: ["“\(title)”", "会从这台设备上删除，此操作无法撤销。"], confirm: "删除", destructive: true, in: window
        ) { [store] confirmed in
          if confirmed { _ = store.deleteConversation(id) }
        }
      } else {
        notice("请先结束通话或等待当前任务完成，再删除这个会话")
      }
    case "search":
      query = a["v"] as? String ?? ""
      refresh()
    case "menu":
      guard let id = a["id"] as? String, let c = store.conversation(id) else { return }
      let row = CGRect(
        x: (a["x"] as? Double) ?? 0, y: (a["y"] as? Double) ?? 0, width: (a["w"] as? Double) ?? 0, height: (a["h"] as? Double) ?? 0)
      menu(for: c, row: row)
    default: break
    }
  }

  /// A long press on a row: rename or delete, in the Liquid Glass menu a little below the row.
  private func menu(for c: Conversation, row: CGRect) {
    guard let window = view.window else { return }
    GlassMenu.show(
      items: [
        .init(title: "重命名", symbol: "pencil") { [weak self] in self?.rename(c) },
        .init(title: "删除", symbol: "trash", destructive: true) { [weak self] in self?.handle(["a": "delete", "id": c.id]) },
      ], row: row, in: window)
  }

  private func rename(_ c: Conversation) {
    guard let window = view.window else { return }
    let safe = window.safeAreaInsets
    let room = CGRect(
      x: safe.left, y: safe.top, width: window.bounds.width - safe.left - safe.right, height: window.bounds.height - safe.top - safe.bottom)
    GlassRenameDialog.show(title: "重命名会话", text: c.title, in: window, room: room) { [store] name in
      if let name { store.rename(c.id, name) }
    }
  }

  private func notice(_ text: String) { showNotice(text) }
}


extension SidebarViewController: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var hit: UIView? = touch.view
    while let v = hit {
      if v is UITextField || v is UITextView { return false }
      hit = v.superview
    }
    return true
  }
}
