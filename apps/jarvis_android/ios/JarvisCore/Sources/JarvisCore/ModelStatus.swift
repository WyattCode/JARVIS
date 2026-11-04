import Foundation

/// What the model status page shows for one answer of the service: the Swift port of the Flutter `statusSnapshot`.
public struct ModelStatus: Equatable, Sendable {
  public struct Row: Equatable, Sendable {
    public var name: String
    public var label: String
    /// ok, busy, bad or off: the colour of the dot.
    public var tone: String
  }
  public var title: String
  public var note: String
  public var memory: String?
  public var updated: String?
  public var rows: [Row]
  public var loading: Bool
  public var hasData: Bool
  public var failed: Bool

  static let labels = [
    "ready": "已就绪", "running": "运行中", "idle": "空闲", "disabled": "未启用", "stopped": "已停止", "error": "需要检查",
    "busy": "正在处理", "loading": "加载中", "unloaded": "按需加载", "failed": "需要检查",
  ]

  static func tone(_ state: String?) -> String {
    switch state {
    case "ready", "running", "idle": return "ok"
    case "loading", "busy": return "busy"
    case "failed", "error": return "bad"
    default: return "off"
    }
  }

  public static func make(
    chatName: String, data: [String: JSONValue]?, loading: Bool, failed: Bool, updatedAt: Date?, calendar: Calendar = .current
  ) -> ModelStatus {
    let rows = (data?["data"]?.array ?? []).compactMap { entry -> Row? in
      guard entry.object != nil else { return nil }
      let state = entry["state"]?.string
      let name = entry["name"]?.string ?? entry["id"]?.string ?? "模型"
      return Row(name: displayModelName(name), label: labels[state ?? ""] ?? "状态未知", tone: tone(state))
    }
    let memory = data?["mem_available_bytes"]?.double.map { String(format: "可用内存 %.1f GiB", $0 / 1_073_741_824) }
    let updated = updatedAt.map { t -> String in
      let c = calendar.dateComponents([.hour, .minute], from: t)
      return String(format: "更新于 %02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
    return ModelStatus(
      title: displayModelName(chatName), note: "语音、图片和视频模型可以按需加载；未加载不表示聊天模型故障。", memory: memory, updated: updated,
      rows: rows, loading: loading, hasData: data != nil, failed: failed)
  }
}
