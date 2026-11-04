import SwiftUI
import UIKit

// MARK: State

/// What the conversation list shows, as plain data. Flutter owns the conversations: the list shows what it is given and
/// reports what the user did (see [ConversationListView]).
struct ConversationListState: Codable, Equatable {
  struct Row: Codable, Hashable, Identifiable {
    /// "header" or "conversation".
    var kind: String
    var id: String
    var title: String
    var selected: Bool
    var generating: Bool
    /// The docked list's second line (how the conversation ends) and the time on the right.
    var subtitle: String? = nil
    var time: String? = nil
  }
  var rows: [Row]
  /// The search field is shown (the list is long, or a search is going).
  var showSearch: Bool
  /// What the search matched nothing of.
  var empty: Bool
  /// A swipe to the left deletes a row (the docked list); in the drawer that swipe is the drawer's own, which closes it.
  var swipeDelete: Bool
  /// The list is short in height (a phone on its side): rows are lower.
  var compact: Bool
  /// Counts up each time the search button is pressed: the field takes the keyboard.
  var focus = 0
  /// The list stands beside the chat on a wide screen (sections by day, rows of two lines with the time).
  var docked = false
}

final class ConversationListStore: ObservableObject {
  @Published var state: ConversationListState
  /// What the user did: {a: "select" | "delete" | "menu" | "search" | "closeDrawer", ...}.
  var send: (([String: Any]) -> Void)?

  init(state: ConversationListState) { self.state = state }

  func apply(_ json: String) {
    guard let data = json.data(using: .utf8),
      let next = try? JSONDecoder().decode(ConversationListState.self, from: data)
    else { return }
    state = next
  }
}

// MARK: Platform view

// MARK: Liquid Glass

extension View {
  /// The system's Liquid Glass in this shape on iOS 26 and later (a flat fill before it).
  @ViewBuilder
  func jarvisGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(interactive ? (tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive()) : (tint.map { Glass.regular.tint($0) } ?? Glass.regular), in: shape)
    } else {
      background(Color(Palette.containerHigh), in: shape)
    }
  }
}

// MARK: List

/// How much of the list's width a row's highlight and the search box take (the same for both).
let listShare: CGFloat = 1.0

struct ConversationListView: View {
  @ObservedObject var store: ConversationListStore
  @State private var query = ""
  @FocusState private var searching: Bool

  private var s: ConversationListState { store.state }

  var body: some View {
    GeometryReader { box in
    VStack(spacing: 0) {
      if s.showSearch { searchField.frame(width: (box.size.width - 24) * listShare + 24, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading) }
      if s.empty {
        Spacer()
        Text("没有匹配的会话").foregroundStyle(Color(Palette.onSurfaceVariant))
        Spacer()
      } else {
        list
      }
    }
    .animation(.easeOut(duration: 0.18), value: s.showSearch)
    }
    .onChange(of: s.focus) { DispatchQueue.main.async { searching = true } }
    .onChange(of: s.showSearch) { if !s.showSearch { query = ""; searching = false } }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(Color(Palette.onSurfaceVariant))
      TextField("搜索会话", text: $query)
        .focused($searching)
        .submitLabel(.search)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onChange(of: query) { store.send?(["a": "search", "v": query]) }
        .onSubmit { searching = false }
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(Color(Palette.onSurfaceVariant))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("清除搜索")
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 46)
    .jarvisGlass(Capsule(), interactive: true)
    .padding(.horizontal, 12)
    .padding(.bottom, s.compact ? 6 : 8)
    .transition(.opacity)
  }

  private var list: some View {
    List {
      // Two rows are never taken for one, whatever their ids (an id is only as unique as the clock that made it).
      ForEach(Array(s.rows.enumerated()), id: \.offset) { _, row in
        if row.kind == "header" {
          Text(row.title)
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(Color(Palette.onSurfaceVariant))
            .padding(.top, 12)
            .padding(.leading, 8)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
        } else {
          ConversationRow(row: row, compact: s.compact, docked: s.docked, swipeDelete: s.swipeDelete, send: { store.send?($0) })
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .scrollDismissesKeyboard(.immediately)
    // A touch on the list puts the keyboard away (the touch goes on to what it hit).
    .simultaneousGesture(TapGesture().onEnded { searching = false })
    .environment(\.defaultMinListRowHeight, 40)
  }
}

/// Asks the row's own view where it stands in the window when it is needed (a long press), instead of keeping a measured copy.
final class RowProbe {
  weak var view: UIView?
  var frame: CGRect { view.map { $0.convert($0.bounds, to: nil) } ?? .zero }
}

private struct RowFrame: UIViewRepresentable {
  let probe: RowProbe
  func makeUIView(context: Context) -> UIView {
    let v = UIView()
    v.isUserInteractionEnabled = false
    probe.view = v
    return v
  }
  func updateUIView(_ view: UIView, context: Context) { probe.view = view }
}

private struct ConversationRow: View {
  let row: ConversationListState.Row
  let compact: Bool
  let docked: Bool
  let swipeDelete: Bool
  let send: ([String: Any]) -> Void
  @State private var probe = RowProbe()
  @State private var pressed = false
  private var frame: CGRect { probe.frame }

  private var plainContent: some View {
    Text(row.title)
      .font(.system(size: 14, weight: row.selected ? .semibold : .regular))
      .foregroundStyle(Color(Palette.onSurface))
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, 12)
  }

  /// The wide screen's row: the title, how the conversation ends under it, and when it was last at on the right.
  private var dockedContent: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text(row.title)
          .font(.system(size: 15, weight: row.selected ? .semibold : .medium))
          .foregroundStyle(Color(Palette.onSurface))
          .lineLimit(1)
        if let sub = row.subtitle, !sub.isEmpty {
          Text(sub)
            .font(.system(size: 12.5))
            .foregroundStyle(Color(Palette.onSurfaceVariant))
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if row.generating {
        ProgressView().controlSize(.small)
      } else if let time = row.time, !time.isEmpty {
        Text(time)
          .font(.system(size: 11.5))
          .foregroundStyle(Color(Palette.onSurfaceVariant))
          .lineLimit(1)
          .fixedSize()
      }
    }
    .padding(.leading, 14).padding(.trailing, 12)
  }

  var body: some View {
    GeometryReader { g in
    HStack(spacing: 4) {
      Group {
        plainContent
      }
      .contentShape(Rectangle())
      .onTapGesture { send(["a": "select", "id": row.id]) }
      .onLongPressGesture(
        minimumDuration: 0.45,
        perform: {
          send([
            "a": "menu", "id": row.id,
            "x": Double(frame.minX), "y": Double(frame.minY), "w": Double(frame.width), "h": Double(frame.height),
          ])
        }, onPressingChanged: { pressed = $0 })
      if row.generating { ProgressView().controlSize(.small).padding(.trailing, 10) }
    }
    .frame(width: max(0, (g.size.width - 4) * listShare), height: g.size.height, alignment: .leading)
    }
    .scaleEffect(pressed ? 0.96 : 1)
    .animation(.spring(response: 0.3, dampingFraction: 0.66), value: pressed)
    .frame(height: compact ? 48 : 58)
    .background(
      GeometryReader { g in
        // The menu hangs from the card the person sees, not from the whole row.
        RowFrame(probe: probe).frame(width: max(0, (g.size.width - 4) * listShare), alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
      }
    )
    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 8))
    .listRowSeparator(.hidden)
    .listRowBackground(
      // Every row stands on the same soft card (one colour for all, a little raised from the drawer); the one that is open is
      // glass with a fine edge in the accent, the one under the finger is a step brighter. All of them are clipped to the same
      // shape, so nothing shows outside it while the list loads or moves.
      GeometryReader { g in
        let shape = RoundedRectangle(cornerRadius: Radii.medium, style: .continuous)
        ZStack {
          shape.fill(Color(Palette.containerHigh).opacity(0.55))
          if pressed { shape.fill(Color(Palette.containerHighest)) }
          if row.selected {
            Color.clear.jarvisGlass(shape)
            shape.strokeBorder(Color(Palette.accent).opacity(0.45), lineWidth: 1)
          }
        }
        .clipShape(shape)
        .frame(width: max(0, (g.size.width - 24) * listShare), alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: pressed)
        .padding(.vertical, 2).padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    )
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(row.selected ? .isSelected : [])
    .accessibilityAction(named: "更多操作（重命名、删除）") {
      send(["a": "menu", "id": row.id, "x": Double(frame.minX), "y": Double(frame.minY), "w": Double(frame.width), "h": Double(frame.height)])
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: swipeDelete) {
      if swipeDelete {
        Button(role: .destructive) {
          send(["a": "delete", "id": row.id])
        } label: {
          Label("删除", systemImage: "trash")
        }
      }
    }
  }
}
