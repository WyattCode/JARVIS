import UIKit

#if DEBUG
  /// Starts the app on the native chat with a made-up service, for looking at it in the simulator:
  /// `SIMCTL_CHILD_JARVIS_NATIVE_CHAT=1 xcrun simctl launch …`. Never in a release build.
  final class PreviewTransport: Transport, @unchecked Sendable {
    var apiKey = ""
    var cookie: String?
    let endpoint = URL(string: "https://jarvis.preview")!
    private var reply: String {
      ProcessInfo.processInfo.environment["JARVIS_LONG_REPLY"] == "1" ? Self.longReply : Self.shortReply
    }
    static let longReply: String = {
      var t = "## 一、背景\n\n这是一份很长的审查提纲，用来复现列表里的高度问题。\n\n"
      for part in ["二、目标与约束", "三、方案取舍", "四、审查重点与产出形式"] {
        t += "**\(part)**\n\n"
        for i in 1...12 {
          t += "\(i). 第 \(i) 点：先问清目标，再看约束，再看当前实现。\n   - 子项 A：为什么这样取舍？（这部分对审查最关键，能避免我提你已经权衡过的点）\n   - 子项 B：有没有更简单的做法\n"
        }
        t += "\n"
      }
      return t
    }()
    private static let shortReply = """
      好的，这是一个快速排序：

      ```swift
      func sort(_ a: [Int]) -> [Int] { a.sorted() }
      ```

      平均复杂度 **O(n log n)**，最坏 O(n²)。下面是对比：

      | 算法 | 平均 | 最坏 |
      | --- | --- | --- |
      | 快速排序 | O(n log n) | O(n²) |
      | 归并排序 | O(n log n) | O(n log n) |
      """

    func login(_ username: String, _ password: String) async throws { cookie = "preview" }
    func logout() async throws { cookie = nil }
    func models() async throws -> [ModelInfo] {
      [ModelInfo("preview", "Preview", metadata: ["jarvis": .object(["image_input": .bool(true)])])]
    }
    func modelSkill() async throws -> [String: JSONValue] { ["enabled": .bool(false), "text": .string("")] }
    func toolsStatus() async throws -> [String: JSONValue] {
      // JARVIS_SLOW_STATUS=1: answers after 1.5 s, as a real network does (a pull-down then runs long enough to be cancelled).
      if ProcessInfo.processInfo.environment["JARVIS_SLOW_STATUS"] == "1" { try await Task.sleep(nanoseconds: 1_500_000_000) }
      return [
        "mem_available_bytes": .number(48 * 1_073_741_824),
        "data": .array([
          .object(["name": .string("qwen3-asr"), "state": .string("ready")]),
          .object(["name": .string("fishaudio/drama-3"), "state": .string("unloaded")]),
          .object(["name": .string("image-gen"), "state": .string("failed")]),
        ]),
      ]
    }
    func modelTool(requestId: String, name: String, args: [String: JSONValue]) async throws -> String { "{}" }
    func chat(requestId: String, model: String, effort: String, messages: [[String: JSONValue]], options: ChatOptions)
      -> AsyncThrowingStream<ChatDelta, Error>
    {
      let text = reply
      return AsyncThrowingStream { continuation in
        let task = Task {
          continuation.yield(ChatDelta(reasoning: "先想一想怎么回答……"))
          try? await Task.sleep(nanoseconds: 400_000_000)
          var index = text.startIndex
          while index < text.endIndex, !Task.isCancelled {
            let next = text.index(index, offsetBy: 6, limitedBy: text.endIndex) ?? text.endIndex
            continuation.yield(ChatDelta(text: String(text[index..<next])))
            index = next
            try? await Task.sleep(nanoseconds: 60_000_000)
          }
          continuation.yield(ChatDelta(finishReason: "stop", done: true))
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
    func cancel(_ requestId: String) {}
    func generate(
      requestId: String, kind: String, args: [String: JSONValue], resumeJobId: String?, onJob: ((String) -> Void)?,
      onProgress: ((Double) -> Void)?
    ) async throws -> [String] { [] }
    func jobStatus(_ id: String) async throws -> [String: JSONValue] { [:] }
    func mediaURL(_ path: String) throws -> URL { URL(string: path, relativeTo: endpoint)!.absoluteURL }
    func download(_ path: String, to file: URL) async throws -> Int {
      // JARVIS_DEMO_VIDEO_BROKEN=1: the file is cut short, as one fetched before the service had finished writing it.
      var data = try await download(path)
      if ProcessInfo.processInfo.environment["JARVIS_DEMO_VIDEO_BROKEN"] != nil { data = Data(data.prefix(2_000)) }
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: file, options: .atomic)
      return data.count
    }
    func download(_ path: String) async throws -> Data {
      // JARVIS_DEMO_VIDEO=<file>: the video the preview serves for the file named `clip`.
      if path.contains("clip"), let file = ProcessInfo.processInfo.environment["JARVIS_DEMO_VIDEO"], let video = try? Data(contentsOf: URL(fileURLWithPath: file)) {
        return video
      }
      return path.contains("sunset") ? Self.square : Self.picture
    }

    /// A square one (a generated picture is often square), for the file named `sunset`.
    private static let square: Data = {
      let work = {
        let size = CGSize(width: 1024, height: 1024)
        let image = UIGraphicsImageRenderer(size: size).image { context in
          let colors = [UIColor.systemOrange.cgColor, UIColor.systemPink.cgColor] as CFArray
          let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
          context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        return image.pngData() ?? Data()
      }
      return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }()

    /// A made-up picture for every file the preview asks for, drawn once (on the main thread).
    private static let picture: Data = {
      let work = {
        let size = CGSize(width: 640, height: 400)
        let image = UIGraphicsImageRenderer(size: size).image { context in
          let colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor] as CFArray
          let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
          context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        return image.pngData() ?? Data()
      }
      return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }()
    func openRealtime() async throws -> RealtimeWire { throw JarvisException("预览环境没有语音") }
    func preview(_ voice: VoiceInfo, model: String) async throws -> Data { Data() }
    func synthesize(_ voice: VoiceInfo, model: String) async throws -> Data { Data() }
    func close() {}
  }

  @MainActor
  enum NativeChatPreview {
    private static var store: JarvisStore?

    /// False when the preview was not asked for.
    static func install(on window: UIWindow) -> Bool {
      // JARVIS_NATIVE_LOGIN=1: the sign-in page on its own (nothing is signed in).
      if ProcessInfo.processInfo.environment["JARVIS_NATIVE_LOGIN"] == "1" {
        let store = JarvisStore(api: PreviewTransport(), vault: MemoryVault())
        Self.store = store
        // JARVIS_BIO_GHOST=1: a kept password that is gone from the keychain (as after a change of the enrolled fingers).
        // JARVIS_BIO_RESET=1: nothing kept, nothing wanted (clears what a test left).
        if ProcessInfo.processInfo.environment["JARVIS_BIO_RESET"] == "1" {
          BiometricLogin.remove()
          BiometricLogin.wanted = false
        }
        // "2": the same, without the prompt that comes up as the page opens (for looking at the button).
        let ghost = ProcessInfo.processInfo.environment["JARVIS_BIO_GHOST"]
        if ghost == "1" || ghost == "2" { UserDefaults.standard.set("ghost", forKey: "jarvis.biometric.username") }
        if ghost == "2" { LoginViewController.autoPrompted = true }
        // JARVIS_THEME=light|dark: the page in that theme.
        if let theme = ProcessInfo.processInfo.environment["JARVIS_THEME"] {
          window.overrideUserInterfaceStyle = theme == "light" ? .light : .dark
        }
        window.rootViewController = LoginViewController(store: store)
        return true
      }
      guard ProcessInfo.processInfo.environment["JARVIS_NATIVE_CHAT"] == "1" else { return false }
      let store = JarvisStore(api: PreviewTransport(), vault: MemoryVault())
      Self.store = store
      Task {
        await store.initialize()
        _ = await store.login("preview", "preview")
        if ProcessInfo.processInfo.environment["JARVIS_NATIVE_CHAT_SEED"] == "1" { seed(store) }
        // JARVIS_DEMO_ATTACH=<n>: n attachments waiting in the box (pictures, a PDF, a table), for looking at the row of tiles.
        if let n = Int(ProcessInfo.processInfo.environment["JARVIS_DEMO_ATTACH"] ?? ""), n > 0 { await demoAttachments(store, count: n) }
        // JARVIS_MANY_CONVS=<n>: n more conversations in the list (the last one made is the open one), for looking at the rows.
        if let n = Int(ProcessInfo.processInfo.environment["JARVIS_MANY_CONVS"] ?? ""), n > 0 {
          for i in 1...n {
            let c = store.newConversation()
            store.update(c.id) {
              $0.title = i == 2 ? "帮我审查一个技术方案，请先问目标、约束和当前实现，再给出审查意见" : "会话 \(i)"
              $0.named = true
              // Ids made from the clock, as the real ones are: the list sorts them under 今天 / 昨天 / 更早 and shows when.
              let at = Int((Date().timeIntervalSince1970 - Double(n - i) * 40_000 - 600) * 1_000_000)
              $0.messages = [ChatMessage("user", "你好，帮我看看这个", id: "\(at)-u\(i)"), ChatMessage("assistant", "好的，先说说背景和目标吧。", id: "\(at + 1000)-a\(i)")]
            }
          }
        }
        // JARVIS_MANY_MSGS=<n>: the open conversation holds n messages of mixed length (for timing what a change of width costs).
        if let n = Int(ProcessInfo.processInfo.environment["JARVIS_MANY_MSGS"] ?? ""), n > 0 {
          let c = store.newConversation()
          store.update(c.id) {
            $0.title = "压力测试"
            $0.named = true
            $0.messages = (0..<n).map { i in
              let body = (0..<(1 + i % 7)).map { "第 \(i) 条的第 \($0) 段：这是一段用来测量排版时间的文字，带有**加粗**和 `代码` 以及一个很长很长的句子，直到换行为止。" }.joined(separator: "\n\n")
              return ChatMessage(i % 2 == 0 ? "user" : "assistant", body, id: "m\(i)")
            }
          }
        }
        // JARVIS_LONG_SEED=1: the open conversation holds a long Markdown reply from the start (no waiting for one to stream in).
        if ProcessInfo.processInfo.environment["JARVIS_LONG_SEED"] == "1" {
          let c = store.newConversation()
          store.update(c.id) {
            $0.title = "长回复"
            $0.named = true
            $0.messages = [ChatMessage("user", "检查一个想法", id: "long-u"), ChatMessage("assistant", PreviewTransport.longReply, id: "long-a")]
          }
        }
        if let theme = ProcessInfo.processInfo.environment["JARVIS_THEME"] { store.setTheme(theme) }
        // JARVIS_DEMO_WORK=<seconds>: the conversation's unfinished picture is ready after that long (the works sheet comes up by itself).
        if let delay = Double(ProcessInfo.processInfo.environment["JARVIS_DEMO_WORK"] ?? "") {
          DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            store.update(store.current.id) { c in
              if let i = c.tasks.firstIndex(where: { $0.status != "completed" }) {
                c.tasks[i].status = "completed"
                c.tasks[i].urls = ["/v1/files/sunset.png"]
                c.tasks[i].progress = 1
              }
            }
          }
        }
        // JARVIS_DEMO_VOICE=<seconds>: a spoken turn lands in the conversation after that long (while the call page may be up).
        if let delay = Double(ProcessInfo.processInfo.environment["JARVIS_DEMO_VOICE"] ?? "") {
          DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let id = store.current.id
            store.update(id) { $0.messages.append(ChatMessage("user", "那个", id: "demo-voice")) }
            // The spoken words come in a little at a time: a short line that grows into a long one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
              store.update(id) { c in if let i = c.messages.firstIndex(where: { $0.id == "demo-voice" }) { c.messages[i].text = "那个长时间说话和按住说话的那个滑动按钮里面的那个白色的圆圈可以稍微小一点然后这两个按钮的相互滑动效果做的不自然要优化一下" } }
            }
          }
        }
        // JARVIS_NATIVE_LAUNCH=1 goes through the real root, so that the launch flight can be looked at.
        if ProcessInfo.processInfo.environment["JARVIS_NATIVE_LAUNCH"] == "1" {
          window.rootViewController = NativeAppRootViewController(store: store)
        } else {
          window.rootViewController = NativeChatApp.makeRoot(store: store)
        }
      }
      return true
    }

    private static func demoAttachments(_ store: JarvisStore, count: Int) async {
      func picture(_ a: UIColor, _ b: UIColor) -> Data {
        let size = CGSize(width: 600, height: 600)
        return UIGraphicsImageRenderer(size: size).image { context in
          let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
          context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }.pngData() ?? Data()
      }
      let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
        context.beginPage()
        let title = "季度报告" as NSString
        title.draw(at: CGPoint(x: 60, y: 60), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28)])
        let body = String(repeating: "这是一段用来看文件预览的文字，内容只是为了占满页面。", count: 30) as NSString
        body.draw(in: CGRect(x: 60, y: 120, width: 475, height: 660), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
      }
      let csv = Data("指标,数值,说明\n体脂率,18.2,正常\n肌肉量,52.1,良好\n水分,55.0,正常\n".utf8)
      let items: [(Attachment, Data)] = [
        (Attachment(id: "demo_p1", name: "封面.png", mime: "image/png", kind: "image", size: 1), picture(.systemOrange, .systemPink)),
        (Attachment(id: "demo_p2", name: "海报.png", mime: "image/png", kind: "image", size: 1), picture(.systemTeal, .systemIndigo)),
        (Attachment(id: "demo_f1", name: "季度报告.pdf", mime: "application/pdf", kind: "document", text: "季度报告", size: pdf.count), pdf),
        (Attachment(id: "demo_f2", name: "指标.csv", mime: "text/csv", kind: "document", text: "指标", size: csv.count), csv),
      ]
      for (item, bytes) in items.prefix(count) { try? await store.addAttachment(store.current.id, item, bytes: bytes) }
    }

    /// A conversation with a picture card and a picture in a reply, for looking at the viewer.
    private static func seed(_ store: JarvisStore) {
      let id = store.current.id
      store.update(id) {
        // JARVIS_DEMO_VIDEO also puts a finished video in, named with another host and scheme than the service's (as a real one may be).
        if ProcessInfo.processInfo.environment["JARVIS_DEMO_VIDEO"] != nil {
          $0.tasks = [MediaTask(id: "tv", kind: "video", prompt: "草泥马吃草", status: "completed", urls: ["http://internal.host:9000/v1/files/clip.mp4"], progress: 1)]
          $0.messages = [ChatMessage("user", "做个视频", id: "v0"), ChatMessage("assistant", "", taskId: "tv", id: "v1")]
          $0.title = "视频"
          $0.named = true
          return
        }
        $0.title = ProcessInfo.processInfo.environment["JARVIS_LONG_TITLE"] == "1" ? "帮我审查一个技术方案，请先问目标、约束和当前实现，再给出审查意见" : "封面设计"
        $0.named = true
        $0.tasks = [
          MediaTask(id: "t1", kind: "image", prompt: "一只猫的水彩画", status: "completed", urls: ["/v1/files/cat.png"], progress: 1),
          MediaTask(id: "t2", kind: "image", prompt: "海边日落", status: "in_progress", progress: 0.4),
        ]
        $0.messages = [
          ChatMessage("assistant", "好的。这周有三件事：\n\n- 周一交方案\n- 周三评审\n- 周五发版\n\n需要我按优先级排一下吗？", id: "m0"),
          ChatMessage("user", "排一下", id: "m0b"),
          ChatMessage(
            "assistant",
            "## 优先级\n\n按**紧急程度**和*影响范围*排：\n\n1. 周三评审：先准备材料，见 [评审指南](https://example.com)\n2. 周五发版：用 `release.sh` 打包\n3. 周一交方案\n\n> 评审前一天锁定范围，避免临时加需求。\n\n```dart\nvoid main() {\n  print('hi');\n}\n```",
            reasoning: "先看每件事的截止时间，再看依赖关系：评审依赖方案，发版依赖评审。", id: "m0c"),
          ChatMessage("user", "好的，另外画一张封面", id: "m1"),
          ChatMessage("assistant", "", taskId: "t1", id: "m2"),
          ChatMessage("assistant", "", taskId: "t2", id: "m3"),
          ChatMessage("assistant", "这是封面预览：\n\n![封面](/v1/files/cat.png)\n\n如果满意我就用它。", id: "m4"),
        ]
      }
    }
  }

#endif
