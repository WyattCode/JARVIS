import Foundation

/// One row of the conversation list: a heading (今天 / 昨天 / 更早) or a conversation.
public struct SidebarRow: Equatable, Sendable, Identifiable {
  public var isHeader: Bool
  public var id: String
  public var title: String
  public var selected: Bool
  public var generating: Bool
}

/// The sidebar's rows, the Swift port of the Flutter app's `conversationRows`.
public enum ConversationRows {
  /// The conversation list shows a search field from this many conversations on.
  public static let searchFrom = 6

  /// When `c` was last active, read from the timestamp in the id of its latest message (ids are made from the clock);
  /// nil for ids that are not.
  public static func lastActive(_ c: Conversation) -> Date? {
    let id = c.messages.last?.id ?? c.id
    guard let micros = Int(id.split(separator: "-", omittingEmptySubsequences: false).first ?? ""),
      micros >= 946_684_800_000_000, micros <= 4_102_444_800_000_000
    else { return nil }
    return Date(timeIntervalSince1970: Double(micros) / 1_000_000)
  }

  /// The conversations that match `query` (title or any message), in the order given, with the headings between them
  /// whenever more than one of those groups is present.
  public static func rows(
    _ all: [Conversation], query: String, selected: String?, generating: (String) -> Bool, now: Date = Date(),
    calendar: Calendar = .current, grouped: Bool = true
  ) -> (rows: [SidebarRow], found: Int) {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let shown =
      needle.isEmpty
      ? all
      : all.filter { c in
        c.title.lowercased().contains(needle) || c.messages.contains { !$0.hidden && $0.text.lowercased().contains(needle) }
      }
    let today = calendar.startOfDay(for: now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
    func group(_ c: Conversation) -> String {
      guard let at = lastActive(c) else { return "更早" }
      let day = calendar.startOfDay(for: at)
      if day >= today { return "今天" }
      return day >= yesterday ? "昨天" : "更早"
    }
    let groups = shown.map(group)
    // `grouped: false`: one plain list, no 今天 / 昨天 / 更早 headings.
    let headed = grouped && Set(groups).count >= 2
    var rows: [SidebarRow] = []
    var previous: String?
    for (i, c) in shown.enumerated() {
      if headed, groups[i] != previous {
        previous = groups[i]
        rows.append(SidebarRow(isHeader: true, id: "header-\(groups[i])", title: groups[i], selected: false, generating: false))
      }
      rows.append(
        SidebarRow(isHeader: false, id: c.id, title: c.title, selected: c.id == selected, generating: generating(c.id)))
    }
    return (rows, shown.count)
  }
}
