import AVKit
import Combine
import SwiftUI
import UIKit

// MARK: State

struct WorksState: Codable {
  struct Work: Codable, Hashable, Identifiable {
    var id: String
    var kind: String
    var prompt: String
    var status: String
    var progress: Double
    var error: String?
    var pending: Bool
    var urls: [String]
    var highlight: Bool
  }
  var canCancel: Bool
  var tasks: [Work]
}

/// What a save button says while it works and for a moment after.
enum SaveNote: Equatable {
  case busy, saved, denied, failed
}

final class WorksStore: ObservableObject {
  @Published var state: WorksState
  @Published var notes: [String: SaveNote] = [:]
  @Published var copied: String?
  /// Sends one action to Flutter and hands back its JSON answer.
  var transport: (([String: Any], @escaping ([String: Any]?) -> Void) -> Void)?
  /// Asks Flutter for the bytes behind an address of the server.
  var fetch: ((String, @escaping (Data?) -> Void) -> Void)?
  private var timers: [String: Timer] = [:]

  init(state: WorksState) { self.state = state }

  func apply(_ json: String) {
    guard let data = json.data(using: .utf8), let next = try? JSONDecoder().decode(WorksState.self, from: data)
    else { return }
    state = next
  }

  func send(_ action: String, _ id: String, _ done: (([String: Any]?) -> Void)? = nil) {
    transport?(["a": action, "id": id]) { done?($0) }
  }

  func save(_ id: String) {
    if notes[id] == .denied {
      notes[id] = nil
      send("settings", id)
      return
    }
    guard notes[id] != .busy else { return }
    // The note of an earlier save may still be waiting to go: it must not clear this one's "saving".
    timers[id]?.invalidate()
    notes[id] = .busy
    send("save", id) { [weak self] reply in
      DispatchQueue.main.async {
        guard let self else { return }
        switch reply?["result"] as? String {
        case "saved": self.note(id, .saved, 2.2)
        case "denied": self.note(id, .denied, 9)
        case "failed": self.note(id, .failed, 2.2)
        default: self.notes[id] = nil
        }
      }
    }
  }

  private func note(_ id: String, _ note: SaveNote, _ seconds: Double) {
    notes[id] = note
    timers[id]?.invalidate()
    timers[id] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      self?.notes[id] = nil
    }
  }

  func copy(_ work: WorksState.Work) {
    UIPasteboard.general.string = work.prompt
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    copied = work.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
      if self?.copied == work.id { self?.copied = nil }
    }
  }
}

// MARK: Bridge

// MARK: Views

/// A button's label: the symbol and the words close together, in the text colour.
private struct ButtonLabel: View {
  let title: String
  let symbol: String
  init(_ title: String, _ symbol: String) {
    self.title = title
    self.symbol = symbol
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).font(.system(.subheadline, weight: .light))
      Text(title).font(.system(size: 14))
    }
    .foregroundStyle(Color(Palette.onSurfaceVariant))
    .padding(.horizontal, 8)
    .frame(minHeight: 40)
    .contentShape(Rectangle())
  }
}

private extension View {
  /// The original's card actions: bare icon and words, no capsule.
  func glassButtonStyle() -> some View { buttonStyle(.plain) }
}

struct WorksView: View {
  @ObservedObject var store: WorksStore
  let done: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("作品").font(.system(.title3, weight: .semibold)).foregroundStyle(Color(Palette.onSurface))
        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.top, 22)
      .padding(.bottom, 4)
      if store.state.tasks.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34)).foregroundStyle(Color(Palette.onSurfaceVariant))
          Text("还没有作品").foregroundStyle(Color(Palette.onSurfaceVariant))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Centred in the whole sheet, not in what the strip leaves of it.
        .ignoresSafeArea(.container, edges: .horizontal)
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(store.state.tasks) { work in WorkCard(store: store, work: work) }
          }
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .padding(.bottom, 24)
        }
      }
    }
    .background(Color(Palette.card))
  }
}

private struct WorkCard: View {
  @ObservedObject var store: WorksStore
  let work: WorksState.Work

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if work.status == "completed", !work.urls.isEmpty {
        ForEach(Array(work.urls.enumerated()), id: \.offset) { index, url in
          if index > 0 { Spacer().frame(height: 4) }
          WorkResult(store: store, work: work, url: url)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(work.prompt.isEmpty ? (work.kind == "video" ? "视频任务" : "图片任务") : work.prompt)
          .font(.system(size: 14)).foregroundStyle(Color(Palette.onSurface)).lineLimit(3)
        if work.pending {
          if work.progress > 0 {
            ProgressView(value: min(max(work.progress / 100, 0), 1))
          } else {
            ProgressView().progressViewStyle(.linear)
          }
          Text("后台生成中\(work.progress > 0 ? " · \(Int(work.progress.rounded()))%" : "")，可以继续对话")
            .font(.system(.caption)).foregroundStyle(Color(Palette.onSurfaceVariant))
        }
        if let error = work.error, !error.isEmpty {
          Text(error).font(.system(size: 14)).foregroundStyle(Color(Palette.error))
        }
      }
      .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
      actions
        .padding(.horizontal, 8).padding(.bottom, 8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(Palette.container)))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(work.highlight ? Color(Palette.accent).opacity(0.55) : Color(Palette.outlineVariant).opacity(0.7), lineWidth: work.highlight ? 1.5 : 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .animation(.easeOut(duration: 0.25), value: work.status)
  }

  private var actions: some View {
    let note = store.notes[work.id]
    return ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) { buttons(note) }
      VStack(alignment: .leading, spacing: 8) { buttons(note) }
    }
  }

  @ViewBuilder private func buttons(_ note: SaveNote?) -> some View {
    Button {
      store.copy(work)
    } label: {
      ButtonLabel(store.copied == work.id ? "已复制" : "复制提示词", store.copied == work.id ? "checkmark" : "doc.on.doc")
    }
    .glassButtonStyle().disabled(work.prompt.isEmpty)
    if work.status == "completed", !work.urls.isEmpty {
      Button {
        store.save(work.id)
      } label: {
        switch note {
        case .busy: ButtonLabel("保存中", "hourglass")
        case .saved: ButtonLabel("已保存到相册", "checkmark.circle")
        case .denied: ButtonLabel("去设置开启相册权限", "gearshape")
        case .failed: ButtonLabel("保存失败", "exclamationmark.circle")
        case nil: ButtonLabel(work.urls.count > 1 ? "全部保存" : "下载", "arrow.down.to.line")
        }
      }
      .glassButtonStyle().disabled(note == .busy)
      
    }
    if work.pending, store.state.canCancel {
      Button {
        store.send("cancel", work.id)
      } label: { ButtonLabel("取消", "xmark") }
        .glassButtonStyle()
    }
    if !work.pending, work.status != "completed" {
      Button {
        store.send("retry", work.id)
      } label: { ButtonLabel("重试", "arrow.clockwise") }
        .glassButtonStyle()
    }
  }
}

/// One finished picture or video; a tap opens it full screen.
private struct WorkResult: View {
  @ObservedObject var store: WorksStore
  let work: WorksState.Work
  let url: String
  @State private var image: UIImage?
  @State private var cover: UIImage?
  @State private var failed = false
  @State private var opening = false

  init(store: WorksStore, work: WorksState.Work, url: String) {
    _store = ObservedObject(wrappedValue: store)
    self.work = work
    self.url = url
    // A video already seen shows its cover from the first frame (the sheet's rows are made again when it is come back to).
    _cover = State(initialValue: work.kind == "video" ? VideoCover.cached(url) : nil)
  }

  var body: some View {
    Button(action: open) {
      ZStack {
        if work.kind == "video" {
          LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { if let cover { Image(uiImage: cover).resizable().scaledToFill() } }
            .clipped()
          if opening {
            ProgressView().tint(.white)
          } else {
            Image(systemName: "play.circle.fill").font(.system(size: 52)).foregroundStyle(.white.opacity(0.92))
          }
        } else if let image {
          Image(uiImage: image).resizable().aspectRatio(image.size, contentMode: .fit)
        } else {
          Rectangle().fill(Color(Palette.containerHigh)).aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
              if failed {
                Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
              } else {
                ProgressView()
              }
            }
        }
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(work.kind == "video" ? "播放视频" : (work.prompt.isEmpty ? "查看图片" : work.prompt))
    .task(id: url) { await load() }
  }

  /// The picture of a work that has only just been finished may not be there for the first moment (the sheet comes up as it is done): it
  /// is asked for again a few times before it is called lost, and a touch on the empty place asks once more.
  private func load() async {
    if work.kind == "video" {
      if cover == nil { cover = await VideoCover.cover(url) }
      return
    }
    guard image == nil else { return }
    failed = false
    for attempt in 0..<6 {
      let loaded: UIImage? = await withCheckedContinuation { continuation in
        PictureCache.shared.load("url:" + url) { continuation.resume(returning: $0) }
      }
      if let loaded {
        image = loaded
        return
      }
      if attempt < 5 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
      if Task.isCancelled { return }
    }
    failed = true
  }

  private func open() {
    guard !opening else { return }
    if work.kind != "video", image == nil {
      if failed { Task { await load() } }
      return
    }
    if work.kind == "video" {
      opening = true
      MediaViewer.play(url: url) { opening = false }
    } else {
      MediaViewer.show(url: url, source: ViewerSource(
        fetch: { url, done in store.fetch?(url, done) },
        save: { store.save(work.id) },
        notes: store.$notes.map { $0[work.id] }.eraseToAnyPublisher()))
    }
  }
}

enum WorksPresenter {
  static func top() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}

// MARK: Picture viewer

/// A picture on its own, full screen, on black: pinch and double tap to zoom, a finger to move it about once it is larger than the
/// screen. Its buttons are the system's own bar's (close at the leading side, save and share at the trailing one), so that they are
/// glass buttons where the bar is (along the top, or in the strip beside the screen of a foldable), as in the rest of the app.
final class PictureViewer: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  /// Every way up (see the root page): a page shown over it must not take the upside-down turn away again.
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
  private let url: String
  private let source: ViewerSource
  private var loaded: UIImage?
  private let scroll = UIScrollView()
  private let imageView = UIImageView()
  private let spinner = UIActivityIndicatorView(style: .large)
  private let failure = UILabel()
  private var saveItem: UIBarButtonItem?
  private var watching: AnyCancellable?
  private var lastSize = CGSize.zero

  init(url: String, source: ViewerSource) {
    self.url = url
    self.source = source
    super.init(nibName: nil, bundle: nil)
    overrideUserInterfaceStyle = .dark
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The viewer in a navigation controller of its own (which brings the bar), over everything.
  static func present(url: String, source: ViewerSource, over presenter: UIViewController) {
    let nav = UINavigationController(rootViewController: PictureViewer(url: url, source: source))
    nav.modalPresentationStyle = .overFullScreen
    nav.modalTransitionStyle = .crossDissolve
    nav.overrideUserInterfaceStyle = .dark
    nav.view.backgroundColor = .black
    presenter.present(nav, animated: true)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    scroll.frame = view.bounds
    scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    scroll.delegate = self
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 6
    scroll.bouncesZoom = true
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    view.addSubview(scroll)
    imageView.contentMode = .scaleAspectFit
    imageView.isUserInteractionEnabled = true
    scroll.addSubview(imageView)
    let twice = UITapGestureRecognizer(target: self, action: #selector(zoom(_:)))
    twice.numberOfTapsRequired = 2
    scroll.addGestureRecognizer(twice)
    // One tap shows or hides the bar.
    let once = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
    once.require(toFail: twice)
    scroll.addGestureRecognizer(once)
    // A drag down (or up) with the picture at rest takes it away, as the system's viewers do.
    let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    drag.delegate = self
    scroll.addGestureRecognizer(drag)
    spinner.color = .white
    spinner.center = view.center
    spinner.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin, .flexibleLeftMargin, .flexibleRightMargin]
    view.addSubview(spinner)
    spinner.startAnimating()
    failure.text = "图片无法载入"
    failure.textColor = UIColor(white: 1, alpha: 0.7)
    failure.font = .systemFont(ofSize: 15)
    failure.sizeToFit()
    failure.isHidden = true
    failure.center = view.center
    failure.autoresizingMask = spinner.autoresizingMask
    view.addSubview(failure)

    func symbol(_ name: String) -> UIImage? {
      UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium))
    }
    let close = UIBarButtonItem(image: symbol("xmark"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    close.accessibilityLabel = "关闭"
    let save = UIBarButtonItem(image: symbol("arrow.down.to.line"), primaryAction: UIAction { [weak self] _ in self?.source.save() })
    save.accessibilityLabel = "保存到相册"
    saveItem = save
    let share = UIBarButtonItem(image: symbol("square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in self?.shareTapped() })
    share.accessibilityLabel = "分享"
    for item in [close, save, share] { item.tintColor = .white }
    navigationItem.leftBarButtonItem = close
    // Two separate round buttons, not one capsule (a space between them keeps the bar from joining them).
    navigationItem.rightBarButtonItems = [share, .fixedSpace(0), save]
    let bar = UINavigationBarAppearance()
    bar.configureWithTransparentBackground()
    navigationItem.standardAppearance = bar
    navigationItem.scrollEdgeAppearance = bar
    navigationController?.navigationBar.tintColor = .white
    // The save button says how it went (saving, saved, refused, failed) in its symbol.
    watching = source.notes.receive(on: DispatchQueue.main).sink { [weak self] note in
      guard let item = self?.saveItem else { return }
      let name: String
      switch note {
      case .busy: name = "hourglass"
      case .saved: name = "checkmark"
      case .denied: name = "gearshape"
      case .failed: name = "exclamationmark.triangle"
      case nil: name = "arrow.down.to.line"
      }
      item.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium))
    }

    // What the list already shows (a thumbnail the cache holds) is put up at once; the full picture replaces it when it comes. If the
    // service will not give the full one, the smaller is what there is.
    PictureCache.shared.load("url:" + url) { [weak self] image in
      guard let self, let image, self.loaded == nil else { return }
      self.show(image)
    }
    fetch(attempt: 0)
  }

  /// The full picture, asked for again a few times if it is not there yet (a work just finished); the failure is said only after that.
  private func fetch(attempt: Int) {
    source.fetch(url) { [weak self] data in
      DispatchQueue.main.async {
        guard let self else { return }
        if let data, let image = UIImage(data: data) {
          self.show(image)
        } else if self.loaded == nil {
          if attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
              guard let self, self.loaded == nil else { return }
              PictureCache.shared.load("url:" + self.url) { image in if let image, self.loaded == nil { self.show(image) } }
              self.fetch(attempt: attempt + 1)
            }
          } else {
            self.spinner.stopAnimating()
            self.failure.isHidden = false
          }
        }
      }
    }
  }

  private func show(_ image: UIImage) {
    loaded = image
    spinner.stopAnimating()
    failure.isHidden = true
    imageView.image = image
    scroll.zoomScale = 1
    lastSize = .zero
    view.setNeedsLayout()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // At rest the picture fills the screen (fitted inside it); zoomed, its frame belongs to the zoom.
    if scroll.zoomScale <= 1.001, lastSize != scroll.bounds.size {
      lastSize = scroll.bounds.size
      imageView.frame = CGRect(origin: .zero, size: scroll.bounds.size)
      scroll.contentSize = scroll.bounds.size
    }
    centre()
  }

  /// A picture smaller than the screen in a direction stands in the middle of it.
  private func centre() {
    let extraX = max(0, (scroll.bounds.width - imageView.frame.width) / 2)
    let extraY = max(0, (scroll.bounds.height - imageView.frame.height) / 2)
    scroll.contentInset = UIEdgeInsets(top: extraY, left: extraX, bottom: extraY, right: extraX)
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

  func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    guard let pan = recognizer as? UIPanGestureRecognizer, pan.view === scroll else { return true }
    let v = pan.velocity(in: scroll)
    return scroll.zoomScale <= 1.01 && abs(v.y) > abs(v.x) * 1.2
  }

  func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { false }

  @objc private func dragged(_ pan: UIPanGestureRecognizer) {
    let dy = pan.translation(in: view).y
    switch pan.state {
    case .changed:
      imageView.transform = CGAffineTransform(translationX: 0, y: dy)
      let fade = max(0, 1 - abs(dy) / 400)
      view.backgroundColor = UIColor.black.withAlphaComponent(fade)
      navigationController?.view.backgroundColor = UIColor.black.withAlphaComponent(fade)
    case .ended, .cancelled:
      if abs(dy) > 120 || abs(pan.velocity(in: view).y) > 900 {
        dismiss(animated: true)
      } else {
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
          self.imageView.transform = .identity
          self.view.backgroundColor = .black
          self.navigationController?.view.backgroundColor = .black
        }
      }
    default: break
    }
  }

  @objc private func toggleControls() {
    guard let nav = navigationController else { return }
    nav.setNavigationBarHidden(!nav.isNavigationBarHidden, animated: true)
  }

  @objc private func shareTapped() {
    guard let loaded else { return }
    let sheet = UIActivityViewController(activityItems: [loaded], applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = view
    sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.maxX - 60, y: view.safeAreaInsets.top + 30, width: 1, height: 1)
    present(sheet, animated: true)
  }

  @objc private func zoom(_ gesture: UITapGestureRecognizer) {
    if scroll.zoomScale > 1.01 {
      scroll.setZoomScale(1, animated: true)
    } else {
      let point = gesture.location(in: imageView)
      let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
      scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}


// MARK: Shared viewer plumbing

/// Where a viewer gets its bytes and how it saves: the works sheet and the single-picture bridge each bring their own.
struct ViewerSource {
  let fetch: (String, @escaping (Data?) -> Void) -> Void
  let save: () -> Void
  let notes: AnyPublisher<SaveNote?, Never>
}

enum MediaViewer {
  /// The videos on their way to the player: a second tap on the same one waits for it (two players would stack); another video opens.
  @MainActor private static var opening: Set<String> = []

  /// A picture full screen over whatever is on top.
  static func show(url: String, source: ViewerSource) {
    if let top = WorksPresenter.top() { PictureViewer.present(url: url, source: source, over: top) }
  }

  /// A video in the system player (its bytes go to a file first); [done] is called once it is on its way.
  @MainActor static func play(url: String, done: @escaping () -> Void) {
    // One at a time: a second tap on a card that is still being fetched would put a second player over the first.
    guard !opening.contains(url) else { return done() }
    opening.insert(url)
    Task { @MainActor in
      defer { opening.remove(url) }
      let file = await VideoCover.saved(url)
      done()
      guard let file else {
        let note = UIAlertController(title: "视频无法载入", message: "请稍后再试。", preferredStyle: .alert)
        note.addAction(UIAlertAction(title: "好", style: .default))
        WorksPresenter.top()?.present(note, animated: true)
        return
      }
      let player = AVPlayerViewController()
      player.player = AVPlayer(url: file)
      player.modalPresentationStyle = .fullScreen
      WorksPresenter.top()?.present(player, animated: true) { player.player?.play() }
    }
  }
}
