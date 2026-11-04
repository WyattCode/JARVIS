import SwiftUI
import UIKit

// MARK: State

/// What the model status page shows, as plain data. Flutter reads the service and owns the data; this page shows it.
struct StatusState: Codable {
  struct Row: Codable, Hashable {
    var name: String
    var label: String
    /// ok, busy, bad or off: the colour of the dot.
    var tone: String
  }
  var title: String
  var note: String
  var memory: String?
  var updated: String?
  var rows: [Row]
  /// A refresh is running.
  var loading: Bool
  /// Something has been read (the list may still be empty).
  var hasData: Bool
  /// The last refresh failed.
  var failed: Bool
}

final class StatusStore: ObservableObject {
  @Published var state: StatusState
  /// Asks Flutter to read the status again; answers when it has finished.
  var refresh: (() async -> Void)?

  init(state: StatusState) { self.state = state }

  func apply(_ json: String) {
    guard let data = json.data(using: .utf8), let next = try? JSONDecoder().decode(StatusState.self, from: data)
    else { return }
    state = next
  }
}

// MARK: Bridge

// MARK: Page

struct StatusView: View {
  @ObservedObject var store: StatusStore
  private var s: StatusState { store.state }

  var body: some View {
    Group {
      if !s.hasData {
        if s.loading {
          ProgressView("正在读取模型状态").tint(Color(Palette.onSurfaceVariant)).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          unavailable
        }
      } else {
        list
      }
    }
    .animation(.easeOut(duration: 0.2), value: s.hasData)
  }

  private var unavailable: some View {
    VStack(spacing: 12) {
      Image(systemName: "icloud.slash").font(.system(size: 30)).foregroundStyle(.secondary)
      Text("暂时无法读取模型状态")
      Button {
        Task { await store.refresh?() }
      } label: {
        Label("重试", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// The heading with what it says about the page: the title, the note, the memory, when it was read, and a failure to refresh.
  private var info: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(s.title).font(.system(.title2, weight: .semibold)).foregroundStyle(Color(Palette.onSurface))
        .accessibilityAddTraits(.isHeader)
      Text(s.note).font(.system(size: 14)).foregroundStyle(Color(Palette.onSurfaceVariant))
      if let memory = s.memory { Text(memory).font(.system(size: 14)).foregroundStyle(Color(Palette.onSurfaceVariant)) }
      if let updated = s.updated { Text(updated).font(.system(size: 14)).foregroundStyle(Color(Palette.onSurfaceVariant)) }
      if s.failed {
        Label("刷新失败，显示的是上一次的状态", systemImage: "exclamationmark.circle")
          .font(.system(size: 14)).foregroundStyle(Color(Palette.error))
      }
    }
  }

  private var empty: some View {
    VStack(spacing: 8) {
      Image(systemName: "memorychip").font(.system(.title)).foregroundStyle(Color(Palette.onSurfaceVariant))
      Text("服务暂未返回模型状态").foregroundStyle(Color(Palette.onSurface))
      Text("稍后下拉刷新，或点刷新重试。").font(.system(size: 14)).foregroundStyle(Color(Palette.onSurfaceVariant))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  private func line(_ row: StatusState.Row) -> some View {
    HStack(spacing: 16) {
      Circle().fill(color(row.tone)).frame(width: 12, height: 12)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.name).font(.system(.callout)).foregroundStyle(Color(Palette.onSurface))
        Text(row.label).font(.system(.footnote)).foregroundStyle(Color(Palette.onSurfaceVariant))
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// The wide page's left half: the title and note, the models counted by how they stand, and the memory and the time read.
  private var summary: some View {
    // How many models stand in each state, in the order they first appear.
    var order: [String] = []
    var counts: [String: (n: Int, tone: String)] = [:]
    for row in s.rows {
      if counts[row.label] == nil { order.append(row.label); counts[row.label] = (0, row.tone) }
      counts[row.label]!.n += 1
    }
    return VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Text(s.title).font(.system(size: 26, weight: .semibold)).foregroundStyle(Color(Palette.onSurface)).lineLimit(2)
          .accessibilityAddTraits(.isHeader)
        Text(s.note).font(.system(size: 14)).foregroundStyle(Color(Palette.onSurfaceVariant))
      }
      if !order.isEmpty {
        HStack(spacing: 10) {
          ForEach(order, id: \.self) { label in
            VStack(alignment: .leading, spacing: 4) {
              Text("\(counts[label]!.n)").font(.system(.title, weight: .semibold)).foregroundStyle(color(counts[label]!.tone))
              Text(label).font(.system(.caption)).foregroundStyle(Color(Palette.onSurfaceVariant)).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color(counts[label]!.tone).opacity(0.10), in: RoundedRectangle(cornerRadius: Radii.medium, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(counts[label]!.n) 个，\(label)")
          }
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        if let memory = s.memory { Label(memory, systemImage: "memorychip") }
        if let updated = s.updated { Label(updated, systemImage: "clock") }
        if s.failed {
          Label("刷新失败，显示的是上一次的状态", systemImage: "exclamationmark.circle").foregroundStyle(Color(Palette.error))
        }
      }
      .font(.system(size: 14))
      .foregroundStyle(Color(Palette.onSurfaceVariant))
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .panel()
  }

  /// A small rounded label for the wide page's header (the memory, when it was read).
  private func pill(_ text: String, tint: Color? = nil, icon: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon).font(.system(.caption, weight: .medium))
      Text(text).font(.system(.footnote)).lineLimit(1)
    }
    .foregroundStyle(tint ?? Color(Palette.onSurfaceVariant))
    .padding(.horizontal, 12).padding(.vertical, 7)
    .background(Color(Palette.card), in: Capsule())
    .overlay(Capsule().strokeBorder(Color(Palette.outlineVariant).opacity(0.7), lineWidth: 1))
  }

  /// A model on the wide page: how it stands (a dot and a word in its colour) over its name.
  private func card(_ row: StatusState.Row) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Circle().fill(color(row.tone)).frame(width: 10, height: 10)
        Text(row.label).font(.system(.footnote, weight: .medium)).foregroundStyle(color(row.tone))
        Spacer(minLength: 0)
      }
      Text(row.name).font(.system(.body, weight: .semibold)).foregroundStyle(Color(Palette.onSurface)).lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
    .background(Color(Palette.card), in: RoundedRectangle(cornerRadius: Radii.large, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Radii.large, style: .continuous).strokeBorder(Color(Palette.outlineVariant).opacity(0.7), lineWidth: 1))
    .accessibilityElement(children: .combine)
  }

  private var list: some View {
    GeometryReader { box in
      // Wide (the inner display held sideways, or a phone on its side): what the page says stands in a column at the left, and the
      // models are cards in two columns beside it, so that the width is used and the page does not scroll for a few lines.
      let wide = box.size.width >= 640 && box.size.width > box.size.height
      ScrollView {
        if wide {
          // Two halves: at the left what the page says about the services (the title, the note, how many models stand in each state,
          // the memory and when it was read); at the right the models themselves, a row each.
          HStack(alignment: .top, spacing: 16) {
            summary
              .frame(width: max(280, box.size.width * 0.4))
            Group {
              if s.rows.isEmpty {
                empty.panel()
              } else {
                VStack(spacing: 0) {
                  ForEach(Array(s.rows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 12) {
                      Circle().fill(color(row.tone)).frame(width: 11, height: 11)
                      Text(row.name).font(.system(.callout, weight: .medium)).foregroundStyle(Color(Palette.onSurface)).lineLimit(1)
                      Spacer(minLength: 8)
                      Text(row.label).font(.system(.footnote, weight: .medium)).foregroundStyle(color(row.tone))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(color(row.tone).opacity(0.14), in: Capsule())
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16)
                    .accessibilityElement(children: .combine)
                    if i < s.rows.count - 1 {
                      Rectangle().fill(Color(Palette.outlineVariant).opacity(0.6)).frame(height: 0.7).padding(.leading, 18)
                    }
                  }
                }
                .panel()
              }
            }
            .frame(maxWidth: .infinity)
          }
          .padding(.horizontal, Metrics.cardMargin)
          .padding(.top, 8)
          .padding(.bottom, 32)
        } else {
          VStack(alignment: .leading, spacing: 22) {
            info.padding(.horizontal, 10)
            if s.rows.isEmpty {
              empty
            } else {
              SettingsCard {
                ForEach(s.rows, id: \.self) { row in line(row) }
              }
            }
          }
          .padding(.horizontal, Metrics.cardMargin)
          .padding(.top, 8)
          .padding(.bottom, 32)
        }
      }
    }
    .background(Color(Palette.surface))
    .refreshable { await store.refresh?() }
    .overlay(alignment: .top) {
      if s.loading {
        ProgressView().progressViewStyle(.linear).tint(Color(Palette.onSurfaceVariant)).transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.18), value: s.loading)
    .onChange(of: s.loading) { was, now in
      // A refresh that ends says how it ended (the list under the finger does not move).
      guard was, !now, UIAccessibility.isVoiceOverRunning else { return }
      UIAccessibility.post(notification: .announcement, argument: s.failed ? "刷新失败" : "模型状态已更新")
    }
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
  }

  private func color(_ tone: String) -> Color {
    switch tone {
    case "ok": return Color(Palette.success)
    case "busy": return Color(Palette.warning)
    case "bad": return Color(Palette.error)
    default: return Color(Palette.onSurfaceVariant)
    }
  }
}


private extension View {
  /// The wide status page's halves: the card colour with a hairline.
  func panel() -> some View {
    self
      .background(Color(Palette.card), in: RoundedRectangle(cornerRadius: Radii.large, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Radii.large, style: .continuous).strokeBorder(Color(Palette.outlineVariant).opacity(0.7), lineWidth: 1))
  }
}
