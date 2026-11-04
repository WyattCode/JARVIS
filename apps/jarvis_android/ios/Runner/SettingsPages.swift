import SwiftUI
import UIKit

// MARK: Privacy page

struct PrivacyView: View {
  let sections: [SettingsState.PrivacySection]
  let links: SettingsState.Links

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        ForEach(sections, id: \.self) { section in
          VStack(alignment: .leading, spacing: 6) {
            SettingsCard(section.title) {
              ForEach(section.items, id: \.self) { item in
                VStack(alignment: .leading, spacing: 4) {
                  if let title = item.title {
                    Text(title).font(.system(.callout, weight: .semibold)).foregroundStyle(Color(Palette.onSurface))
                  }
                  Text(item.text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(Color(Palette.onSurfaceVariant))
                }
              }
            }
            if let footer = section.footer {
              Text(footer).font(.system(.caption)).foregroundStyle(Color(Palette.onSurfaceVariant)).padding(.leading, 10)
            }
          }
        }
        if !links.policy.isEmpty || !links.email.isEmpty {
          SettingsCard("更多") {
            if !links.policy.isEmpty, let url = URL(string: links.policy) {
              Link(destination: url) { Label("隐私政策", systemImage: "checkmark.shield") }.foregroundStyle(Color(Palette.accent))
            }
            if !links.email.isEmpty, let url = URL(string: "mailto:\(links.email)") {
              Link(destination: url) { Label("联系支持", systemImage: "envelope") }.foregroundStyle(Color(Palette.accent))
            }
          }
        }
      }
      .padding(.horizontal, Metrics.cardMargin)
      .padding(.top, 8)
      .padding(.bottom, 32)
    }
    .background(Color(Palette.surface))
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
  }
}

// MARK: Voice picker

struct VoicePickerView: View {
  @ObservedObject var store: SettingsStore
  let done: () -> Void
  private var s: SettingsState { store.state }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("选择音色").font(.system(.title3, weight: .semibold)).foregroundStyle(Color(Palette.onSurface))
        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.top, 22)
      .padding(.bottom, 4)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if s.speech.engines.isEmpty {
            Text("请在设置中选择可用语音引擎").foregroundStyle(Color(Palette.onSurfaceVariant))
          } else {
            if s.speech.engines.count > 1 {
              SettingsCard {
                PickRow(
                  title: "语音引擎", value: s.speech.engines.first { $0.id == s.speech.engine }?.name ?? "",
                  options: s.speech.engines.map { ($0.id, $0.name) }, selected: s.speech.engine ?? ""
                ) { value in store.act("engine", value) { $0.speech.engine = value } }
              }
            }
            if let engine = s.speech.engine {
              SettingsCard {
                ForEach(s.speech.voices, id: \.id) { voice in
                  VoiceRow(
                    voice: voice, selected: s.speech.voice == voice.id,
                    loading: s.speech.previewId == voice.id && s.speech.previewLoading,
                    playing: s.speech.previewId == voice.id && s.speech.previewPlaying,
                    select: { store.act("voice", voice.id, extra: ["engine": engine]) { $0.speech.voice = voice.id } },
                    play: { store.act("preview", voice.id, extra: ["engine": engine]) })
                }
              }
              if let error = s.speech.previewError {
                Text(error).font(.system(.footnote)).foregroundStyle(Color(Palette.error))
              }
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
      }
    }
    .background(Color(Palette.card))
  }
}


// MARK: Privacy page on its own
