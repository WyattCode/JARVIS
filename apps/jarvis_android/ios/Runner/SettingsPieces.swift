import SwiftUI
import UIKit

// MARK: Pieces

// MARK: Original look

/// A card of the settings page: a title above, the rows inside a rounded card with a hairline, a divider between rows.
struct SettingsCard<Content: View>: View {
  let title: String?
  @ViewBuilder let content: Content

  init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title {
        Text(title).font(.system(.caption, weight: .medium)).foregroundStyle(Color(Palette.onSurfaceVariant)).padding(.leading, 10)
      }
      VStack(spacing: 0) {
        Group(subviews: content) { rows in
          ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
            row.padding(.horizontal, 16).padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
            if i < rows.count - 1 {
              Rectangle().fill(Color(Palette.outlineVariant).opacity(0.6)).frame(height: 0.7).padding(.leading, 16)
            }
          }
        }
      }
      .background(Color(Palette.card), in: RoundedRectangle(cornerRadius: Radii.medium + 2, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Radii.medium + 2, style: .continuous).strokeBorder(Color(Palette.outlineVariant).opacity(0.7), lineWidth: 1))
    }
  }
}

/// A button that is a whole row of a settings card: it answers a touch anywhere on the row. The card pads its rows from outside, and a
/// button inside that padding was only as big as its words (some 20 pt); the padding is taken into the button here, and given back by
/// the negative one around it, so that nothing moves.
struct CardRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

  /// (a style of its own does not dim a button that is turned off, as the system's does: it is done here)
  private struct Row: View {
    let configuration: Configuration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
      configuration.label
        .padding(.horizontal, 16).padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.55 : 1)
        .padding(.horizontal, -16).padding(.vertical, -15)
    }
  }
}

/// A row that names its value and opens a menu of the choices, with the up/down mark after it.
struct PickRow: View {
  let title: String
  /// A line under the title, as the switches have (a grey `footnote`).
  var subtitle: String?
  let value: String
  let options: [(id: String, name: String)]
  let selected: String
  let pick: (String) -> Void

  var body: some View {
    Menu {
      ForEach(options, id: \.id) { option in
        Button { pick(option.id) } label: {
          if option.id == selected { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
        }
      }
    } label: {
      HStack(spacing: 8) {
        // The name keeps its room (a long model id as the value is cut in its middle, not the name pressed into a column of letters).
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(.callout)).foregroundStyle(Color(Palette.onSurface))
          if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Color(Palette.onSurfaceVariant)) }
        }
        .layoutPriority(1)
        Spacer(minLength: 12)
        Text(value).font(.system(.subheadline)).foregroundStyle(Color(Palette.onSurfaceVariant)).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.up.chevron.down").font(.system(.caption2, weight: .medium)).foregroundStyle(Color(Palette.onSurfaceVariant))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(CardRowButtonStyle())
  }
}

/// The tab bar at the top of the page: four segments in a rounded track; the chosen one is raised. A tap takes the page to
/// that card.
struct SettingsTabs: View {
  let titles: [String]
  @Binding var selected: Int
  let go: (Int) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
        Button {
          selected = i
          go(i)
        } label: {
          Text(title)
            .font(.system(size: 14, weight: i == selected ? .semibold : .regular))
            .foregroundStyle(Color(i == selected ? Palette.onSurface : Palette.onSurfaceVariant))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(i == selected ? Color(Palette.containerHighest) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(i == selected ? .isSelected : [])
      }
    }
    .padding(4)
    .background(Color(Palette.card), in: Capsule())
    .overlay(Capsule().strokeBorder(Color(Palette.outlineVariant).opacity(0.7), lineWidth: 1))
  }
}

struct VoiceRow: View {
  let voice: SettingsState.Voice
  let selected: Bool
  let loading: Bool
  let playing: Bool
  let select: () -> Void
  let play: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      // The voice in use: a check in the cyan, in a gutter of its own at the left.
      Image(systemName: "checkmark").font(.system(.subheadline, weight: .medium)).foregroundStyle(Color(Palette.accent))
        .frame(width: 32).opacity(selected ? 1 : 0)
        .accessibilityHidden(true)
      Button(action: select) {
        VStack(alignment: .leading, spacing: 2) {
          Text(voice.name).font(.system(.callout)).foregroundStyle(Color(Palette.onSurface))
          if !voice.description.isEmpty {
            Text(voice.description).font(.system(.footnote)).foregroundStyle(Color(Palette.onSurfaceVariant))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Button(action: play) {
        Group {
          if loading {
            ProgressView().tint(Color(Palette.accent))
          } else {
            Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 14)).foregroundStyle(Color(Palette.accent))
          }
        }
        // 44 pt (the least a button may be): the row is 5% lower than with 48.
        .frame(width: 44, height: 44)
        .background(Color(Palette.accent).opacity(0.14), in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(playing || loading ? "停止试听 \(voice.name)" : "试听 \(voice.name)")
    }
    .animation(.easeOut(duration: 0.2), value: selected)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// A few messages at the chosen text size, for the free half of a folded screen.
/// What the chat will look like with the current theme and text size, set as the chat sets it: your messages in a
/// bubble, the reply plain, with the Markdown the replies carry (bold, a list, code). It follows the size slider as it
/// moves; the theme is the whole app's, so it changes with the swatches.
struct ChatPreview: View {
  let size: Double

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("实时预览")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
        VStack(spacing: 16) {
          mine("帮我把这周的计划整理一下")
          reply
          mine("排一下")
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.secondary.opacity(0.28)))
      }
      .padding(16)
      .frame(maxWidth: 520)
      .frame(maxWidth: .infinity)
    }
    .background(Color(Palette.surface).ignoresSafeArea())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("聊天字号预览")
  }

  private var reply: some View {
    VStack(alignment: .leading, spacing: size * 0.5) {
      Text("好的。这周有三件事：").font(.system(size: size)).lineSpacing(size * 0.45)
      item(Text("周一").bold() + Text("交方案"))
      item(Text("周三").bold() + Text("评审"))
      item(Text("周五").bold() + Text("发版，截止 ") + Text("18:00").font(.system(size: size * 0.9, design: .monospaced)))
      Text("需要我按优先级排一下吗？").font(.system(size: size)).lineSpacing(size * 0.45)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }

  private func item(_ content: Text) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("•")
      content
    }
    .font(.system(size: size))
    .lineSpacing(size * 0.45)
  }

  private func mine(_ message: String) -> some View {
    HStack {
      Spacer(minLength: 40)
      Text(message)
        .font(.system(size: size))
        .lineSpacing(size * 0.45)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 20))
    }
  }
}

struct ThemeSwatches: View {
  let value: String
  let choose: (String) -> Void
  private let items = [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]

  var body: some View {
    HStack(spacing: 12) {
      ForEach(items, id: \.0) { item in
        Button {
          choose(item.0)
        } label: {
          VStack(spacing: 6) {
            preview(item.0)
              .frame(height: 64)
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .overlay(
                RoundedRectangle(cornerRadius: 10)
                  .strokeBorder(
                    value == item.0 ? Color(Palette.onSurface).opacity(0.85) : Color(Palette.outlineVariant),
                    lineWidth: value == item.0 ? 2.5 : 1)
              )
              .overlay(alignment: .bottomTrailing) {
                if value == item.0 {
                  Image(systemName: "checkmark.circle.fill").font(.system(.title3))
                    .foregroundStyle(Color(Palette.onSurface), Color(Palette.outline)).padding(6)
                }
              }
            Text(item.1).font(.system(size: 13, weight: value == item.0 ? .semibold : .regular))
              .foregroundStyle(Color(value == item.0 ? Palette.onSurface : Palette.onSurfaceVariant))
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.1)
        .accessibilityAddTraits(value == item.0 ? .isSelected : [])
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func preview(_ kind: String) -> some View {
    switch kind {
    case "light": swatch(dark: false)
    case "dark": swatch(dark: true)
    default:
      HStack(spacing: 0) {
        swatch(dark: false)
        swatch(dark: true)
      }
    }
  }

  private func swatch(dark: Bool) -> some View {
    ZStack(alignment: .topLeading) {
      (dark ? Color(white: 0.1) : Color.white)
      VStack(alignment: .leading, spacing: 5) {
        Capsule().fill(dark ? Color(white: 0.35) : Color(white: 0.8)).frame(width: 26, height: 5)
        Capsule().fill(dark ? Color(white: 0.25) : Color(white: 0.88)).frame(width: 38, height: 5)
      }
      .padding(8)
    }
  }
}
