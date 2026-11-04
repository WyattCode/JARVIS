import Foundation

/// Facts the App Store listing needs. Empty values mean "not provided yet": the UI hides what depends on them.
public enum AppInfo {
  public static let privacyPolicyUrl = ""
  public static let supportEmail = ""
  public static let appName = "JARVIS"
}

/// A paragraph of the privacy page: an optional heading and its text.
public struct PrivacyItem: Equatable, Sendable {
  public let title: String?
  public let text: String
}

/// A card of the privacy page.
public struct PrivacySection: Equatable, Sendable {
  public let title: String
  public let footer: String?
  public let items: [PrivacyItem]
}

/// The words of the privacy page, the same as the Flutter app's.
public func privacySections(server: String, email: String) -> [PrivacySection] {
  [
    PrivacySection(
      title: "会发送到服务的内容", footer: "服务器地址：\(server)",
      items: [
        PrivacyItem(title: "文字", text: "你输入的文字。"),
        PrivacyItem(title: "图片与文件", text: "你在对话里添加的图片、拍摄的照片和文件。只发送你亲自选的，应用不会浏览你的相册。"),
        PrivacyItem(
          title: "通话语音",
          text: "语音通话中，麦克风的声音会实时发送到服务，用于识别你的话并生成回答。按住说话时只在按住期间发送，静音或通话结束后不再发送。"),
        PrivacyItem(title: "模型与语音设置", text: "你选择的模型、音色和语音识别等设置，会随请求一起发送。"),
      ]),
    PrivacySection(
      title: "保存在这台设备上的内容", footer: nil,
      items: [
        PrivacyItem(title: nil, text: "会话、通话的文字记录和附件保存在本机的加密文件里，加密密钥由系统钥匙串保管。退出登录不会删除它们。")
      ]),
    PrivacySection(
      title: "关于 AI 生成的内容", footer: nil,
      items: [
        PrivacyItem(title: nil, text: "回复由人工智能生成，可能不准确、不完整或已过时。重要的事请自行核实，不要把它当作医疗、法律或财务方面的专业意见。")
      ]),
    PrivacySection(
      title: "如何删除数据", footer: nil,
      items: [
        PrivacyItem(title: "删除一个会话", text: "在会话列表里可以删除单个会话。"),
        PrivacyItem(title: "删除全部", text: "在 设置 > 数据 > 删除全部会话，清除这台设备上的全部会话和附件。"),
        PrivacyItem(title: "退出登录", text: "退出登录会中断进行中的任务和通话。已经发送到服务的内容会保留多久，由服务提供者决定。"),
      ]),
    PrivacySection(
      title: "遇到不当内容", footer: nil,
      items: [
        PrivacyItem(
          title: nil,
          text: email.isEmpty
            ? "如果回复含有不当或有害的内容，请联系你的服务提供者，并附上相关的对话内容。"
            : "如果回复含有不当或有害的内容，请发邮件到 \(email)，并附上相关的对话内容。")
      ]),
  ]
}
