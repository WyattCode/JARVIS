import Foundation

public let modelToolNames: Set<String> = ["list_models", "reserve_for", "unload_model", "load_model"]

private func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], required: [String] = []) -> [String: JSONValue] {
  var parameters: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
  if !required.isEmpty { parameters["required"] = .array(required.map { .string($0) }) }
  return [
    "type": .string("function"),
    "function": .object(["name": .string(name), "description": .string(description), "parameters": .object(parameters)]),
  ]
}

private func type(_ name: String) -> JSONValue { .object(["type": .string(name)]) }

/// The model-management tools the chat model may call.
public func modelToolSchema() -> [[String: JSONValue]] {
  [
    tool("list_models", "查询当前模型状态、内存需求、被暂时换出的模型；不执行加载或卸载。", [:]),
    tool(
      "reserve_for", "为模型任务预留空间。先用dry_run检查影响，实际操作遵循服务端保护；不能卸载当前聊天模型。",
      ["model": type("string"), "seconds": type("integer"), "dry_run": type("boolean")], required: ["model"]),
    tool("unload_model", "暂时卸载指定模型，不能卸载当前聊天模型；由服务端负责后续恢复。", ["model": type("string"), "hold_s": type("integer")], required: ["model"]),
    tool("load_model", "按服务端规则加载指定模型。", ["model": type("string")], required: ["model"]),
  ]
}

/// The picture and video tools, for the kinds the server has a model for.
public func mediaToolSchema(_ models: [ModelInfo]) -> [[String: JSONValue]] {
  var out: [[String: JSONValue]] = []
  for kind in ["image", "video"] {
    guard let model = models.first(where: { $0.kind == kind }) else { continue }
    let maxSeconds = JSONValue.object(model.metadata)["limits"]?["max_seconds"]?.int ?? 5
    var properties: [String: JSONValue] = ["prompt": type("string")]
    if kind == "image" {
      properties["size"] = .object(["type": .string("string"), "description": .string("宽x高，16的整数倍，例如1024x1024")])
    } else {
      properties["seconds"] = .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(Double(maxSeconds))])
    }
    out.append(
      tool(
        "generate_\(kind)",
        kind == "image" ? "根据详细描述生成图片，结果展示在原任务卡片中。" : "生成短视频，耗时较长，将在后台处理；结果更新到原任务卡片。",
        properties, required: ["prompt"]))
  }
  return out
}
