import AVFoundation
import ImageIO
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// What a failed file operation says: a `code` for the caller to branch on and a message the user can act on.
struct FilesFailure: Error, Equatable {
  let code: String
  let message: String

  static let unreadable = FilesFailure(code: "image_invalid", message: "图片无法读取")
  static let fileTooLarge = FilesFailure(code: "image_file_too_large", message: "图片文件过大，请选择20MB以内的图片")
  static let dimensionsTooLarge = FilesFailure(code: "image_dimensions", message: "图片尺寸过大，请选择小于6000万像素的图片")
  static let stillTooLarge = FilesFailure(code: "image_compress", message: "图片压缩后仍超过3MB，请换一张较小的图片")
  static let busySaving = FilesFailure(code: "busy", message: "请先完成当前保存操作")
  static let busyPicking = FilesFailure(code: "busy", message: "请先完成当前选择")
  static let saveFailed = FilesFailure(code: "save_failed", message: "文件保存失败")
  static let noSaveSheet = FilesFailure(code: "save_failed", message: "无法打开保存窗口，请重试")
  static let shareFailed = FilesFailure(code: "share_failed", message: "无法打开分享，请重试")
  static let pickerFailed = FilesFailure(code: "picker_failed", message: "无法打开，请重试")
  static let photosDenied = FilesFailure(code: "photos_denied", message: "请在“设置”里允许 JARVIS 添加照片")
  static let photosFailed = FilesFailure(code: "save_failed", message: "保存到相册失败")
  static let cameraUnavailable = FilesFailure(code: "camera_unavailable", message: "此设备没有可用的相机")
  static let cameraDenied = FilesFailure(code: "camera_denied", message: "请在“设置”里允许 JARVIS 使用相机")
}

/// A file to hand to the system: in memory (`bytes`) or already on disk (`path`), under the name the user should see.
struct FileSource {
  var name: String
  var bytes: Data?
  var path: String?
}

/// One picture the user picked or took, or why it could not be loaded.
enum PickedPicture: Equatable {
  case picture(name: String, bytes: Data)
  case failed(String)
}

/// The system's file, photo, camera and share sheets and the Photos library, without Flutter: the Flutter bridge and the
/// native app both call this. Everything that touches UI runs on the main thread.
final class FilesService: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate,
  PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate
{
  typealias Reply<T> = (Result<T, FilesFailure>) -> Void

  static let shared = FilesService()

  private let io = DispatchQueue(label: "ai.jarvis.app.files", qos: .userInitiated)
  private var pendingSave: Reply<Bool>?
  private var pendingURLs: [URL] = []
  private var pendingPicker: UIViewController?
  // The document picker for opening files, and the call waiting for what it picks.
  private var pendingOpen: Reply<[URL]>?
  private var openPicker: UIViewController?
  // The photo library picker or the camera (one at a time) and the call waiting for its pictures.
  private var pendingPhotos: Reply<[PickedPicture]>?
  private var photoPicker: UIViewController?
  // Staged files that a picker, share sheet or Photos write still needs (main thread only).
  private var inFlight = Set<URL>()
  private static var exportsDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
  }

  /// Nothing staged by an earlier run is still needed: backups left by a killed app must not linger in tmp.
  func clearLeftovers() {
    try? FileManager.default.removeItem(at: Self.exportsDirectory)
    // The copies the document picker made of picked files (`asCopy`) wait in the temporary folder's Inbox for the system to clear.
    let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "")-Inbox", isDirectory: true)
    try? FileManager.default.removeItem(at: inbox)
  }

  /// Every pick or save that is waiting is answered as closed (the page under it is going: the session ended, say), so that the next
  /// one is not refused as "busy" and what waits for the answer goes on.
  /// Counts the photo picks (and the cancellations): the pictures of one that was cancelled are not given to the next.
  private var photoRun = 0

  func cancelAll() {
    photoRun += 1
    if pendingSave != nil { finishSave(.success(false)) }
    if pendingOpen != nil { finishOpen(.success([])) }
    if pendingPhotos != nil { finishPhotos(.success([])) }
  }

  /// Removes a file the picker copied for this app once it has been read (only ever one inside the temporary folder).
  static func discardCopy(_ url: URL) {
    let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    guard url.resolvingSymlinksInPath().path.hasPrefix(temp + "/") else { return }
    try? FileManager.default.removeItem(at: url)
  }

  /// Off the main thread, then back on it.
  func normalizeImage(_ data: Data, _ reply: @escaping Reply<Data>) {
    io.async {
      let outcome = Result { try Self.normalizeImage(data) }.mapError { ($0 as? FilesFailure) ?? .unreadable }
      DispatchQueue.main.async { reply(outcome) }
    }
  }

  /// Decodes (JPEG/PNG/WebP/HEIC), applies EXIF orientation, caps the long edge at 3072px, flattens onto white,
  /// and re-encodes as JPEG within 3MB: q=0.88 first, then lower quality, then a smaller picture, before giving up.
  static func normalizeImage(_ data: Data) throws -> Data {
    guard data.count <= 20 * 1024 * 1024 else { throw FilesFailure.fileTooLarge }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Int,
      let height = props[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else { throw FilesFailure.unreadable }
    guard Int64(width) * Int64(height) <= 60_000_000 else { throw FilesFailure.dimensionsTooLarge }
    let longEdge = min(3072, max(width, height))
    for scale in [1.0, 0.75, 0.5] {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, Int(Double(longEdge) * scale)),
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw FilesFailure.unreadable
      }
      let size = CGSize(width: image.width, height: image.height)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let flat = UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
      }
      for quality in [0.88, 0.75, 0.6] {
        if let jpeg = flat.jpegData(compressionQuality: quality), jpeg.count <= 3 * 1024 * 1024 { return jpeg }
      }
    }
    throw FilesFailure.stillTooLarge
  }

  /// Stages what a call carries as exports/<run id>/<name>, so the system dialog and the share sheet show the name the
  /// user should see. A file on disk is hard-linked (copied when that is not possible), never read into memory.
  private func stage(_ sources: [FileSource]) -> [URL]? {
    guard !sources.isEmpty else { return nil }
    let root = Self.exportsDirectory
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Only folders a sheet is still using are kept; anything else is a leftover.
    let busy = Set(inFlight.map { $0.deletingLastPathComponent().path })
    for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    where !busy.contains(url.path) {
      try? FileManager.default.removeItem(at: url)
    }
    let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
    var staged: [URL] = []
    for source in sources {
      let raw = (source.name as NSString).lastPathComponent
      var name = raw.isEmpty ? "jarvis-file" : raw
      if staged.contains(where: { $0.lastPathComponent == name }) {
        name = "\(staged.count + 1)-\(name)"
      }
      let file = dir.appendingPathComponent(name)
      do {
        if let bytes = source.bytes {
          try bytes.write(to: file, options: .completeFileProtection)
        } else if let path = source.path {
          var isDirectory: ObjCBool = false
          guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
          }
          let origin = URL(fileURLWithPath: path)
          do { try FileManager.default.linkItem(at: origin, to: file) } catch {
            try FileManager.default.copyItem(at: origin, to: file)
          }
        } else {
          throw CocoaError(.fileNoSuchFile)
        }
      } catch {
        try? FileManager.default.removeItem(at: dir)
        for url in staged { inFlight.remove(url) }
        return nil
      }
      inFlight.insert(file)
      staged.append(file)
    }
    return staged
  }

  /// Deletes a staged file (and its run folder once empty) when nothing needs it.
  private func discard(_ file: URL) {
    try? FileManager.default.removeItem(at: file)
    inFlight.remove(file)
    let dir = file.deletingLastPathComponent()
    if ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty {
      try? FileManager.default.removeItem(at: dir)
    }
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private final class Presentation { var finished = false }

  /// `present` silently does nothing while the top controller is itself being presented or dismissed (say, right after
  /// another sheet closed). Waits for a settled controller, then confirms the sheet really appeared; `failed` runs when
  /// it did not, so the caller never waits for a dialog that is not there. Exactly one of `presented` and `failed` runs.
  private func present(
    _ makeSheet: @escaping (UIViewController) -> UIViewController, attempts: Int = 5,
    presented: @escaping () -> Void = {}, failed: @escaping () -> Void
  ) {
    guard let top = topViewController(), !top.isBeingDismissed, !top.isBeingPresented else {
      guard attempts > 0 else { return failed() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        self.present(makeSheet, attempts: attempts - 1, presented: presented, failed: failed)
      }
      return
    }
    let sheet = makeSheet(top)
    let state = Presentation()
    top.present(sheet, animated: true) {
      // The caller was already told it failed: do not leave the sheet up for it.
      guard !state.finished else { return sheet.dismiss(animated: false) }
      state.finished = true
      presented()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard !state.finished, sheet.presentingViewController == nil else { return }
      state.finished = true
      failed()
    }
  }

  // MARK: Save to Files

  /// Offers the files to the system's save dialog. True when the user saved them, false when they closed it.
  func save(_ sources: [FileSource], _ reply: @escaping Reply<Bool>) {
    guard pendingSave == nil else { return reply(.failure(.busySaving)) }
    guard let files = stage(sources), !files.isEmpty else { return reply(.failure(.saveFailed)) }
    pendingSave = reply
    pendingURLs = files
    present(
      { [weak self] _ in
        let picker = UIDocumentPickerViewController(forExporting: files, asCopy: true)
        picker.delegate = self
        self?.pendingPicker = picker
        picker.presentationController?.delegate = self
        return picker
      },
      failed: { [weak self] in self?.finishSave(.failure(.noSaveSheet)) })
  }

  /// Saves a generated picture or video straight into the Photos library (add-only access, no browsing of it).
  func saveToPhotos(_ source: FileSource, mime: String, _ reply: @escaping Reply<Bool>) {
    let isVideo = mime.hasPrefix("video/")
    guard let staged = stage([source])?.first else { return reply(.failure(.saveFailed)) }
    // Photos takes JPEG/PNG/HEIC/GIF; anything else (WebP) is re-encoded losslessly first, off the main thread.
    guard !isVideo, !["image/jpeg", "image/png", "image/gif", "image/heic"].contains(mime) else {
      return addToPhotos(staged, isVideo: isVideo, reply)
    }
    io.async {
      let converted = staged.deletingPathExtension().appendingPathExtension("png")
      var written = false
      if let data = try? Data(contentsOf: staged), let image = UIImage(data: data), let png = image.pngData() {
        written = (try? png.write(to: converted, options: .completeFileProtection)) != nil
      }
      DispatchQueue.main.async {
        guard written else { return self.addToPhotos(staged, isVideo: isVideo, reply) }
        self.discard(staged)
        self.inFlight.insert(converted)
        self.addToPhotos(converted, isVideo: isVideo, reply)
      }
    }
  }

  private func addToPhotos(_ file: URL, isVideo: Bool, _ reply: @escaping Reply<Bool>) {
    let done: (FilesFailure?) -> Void = { failure in
      DispatchQueue.main.async {
        self.discard(file)
        reply(failure.map { .failure($0) } ?? .success(true))
      }
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else { return done(.photosDenied) }
      PHPhotoLibrary.shared().performChanges(
        {
          let request = PHAssetCreationRequest.forAsset()
          request.addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
        },
        completionHandler: { ok, _ in done(ok ? nil : .photosFailed) })
    }
  }

  /// Always leaves nothing pending: the next save must never find the previous one still "busy".
  private func finishSave(_ outcome: Result<Bool, FilesFailure>) {
    for url in pendingURLs { discard(url) }
    let reply = pendingSave
    pendingSave = nil
    pendingURLs = []
    pendingPicker = nil
    reply?(outcome)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    if controller === openPicker { return finishOpen(.success(urls)) }
    finishSave(.success(true))
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    if controller === openPicker { return finishOpen(.success([])) }
    finishSave(.success(false))
  }

  // MARK: Open files

  private func finishOpen(_ outcome: Result<[URL], FilesFailure>) {
    let reply = pendingOpen
    pendingOpen = nil
    openPicker = nil
    reply?(outcome)
  }

  /// The system's document picker for files to read (copies in the app's temporary folder, so they can be read at once).
  /// Gives the chosen files, none when it was closed.
  func openFiles(types: [UTType], multiple: Bool, _ reply: @escaping Reply<[URL]>) {
    guard pendingOpen == nil else { return reply(.failure(.busyPicking)) }
    pendingOpen = reply
    present(
      { [weak self] _ in
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = multiple
        picker.delegate = self
        self?.openPicker = picker
        picker.presentationController?.delegate = self
        return picker
      },
      failed: { [weak self] in self?.finishOpen(.failure(.pickerFailed)) })
  }

  /// Swiping the dialog down dismisses it without either delegate method on some iOS versions.
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if presentationController.presentedViewController === pendingPicker { finishSave(.success(false)) }
    if presentationController.presentedViewController === photoPicker { finishPhotos(.success([])) }
    if presentationController.presentedViewController === openPicker { finishOpen(.success([])) }
  }

  // MARK: Pictures to attach

  private func finishPhotos(_ outcome: Result<[PickedPicture], FilesFailure>) {
    let reply = pendingPhotos
    pendingPhotos = nil
    photoPicker = nil
    reply?(outcome)
  }

  private func beginPhotos(_ reply: @escaping Reply<[PickedPicture]>, _ makeSheet: @escaping () -> UIViewController) {
    guard pendingPhotos == nil else { return reply(.failure(.busyPicking)) }
    // (counted only for one that is really begun: a refused ask must not make the one before it lose its pictures)
    photoRun += 1
    pendingPhotos = reply
    present(
      { [weak self] _ in
        let sheet = makeSheet()
        self?.photoPicker = sheet
        sheet.presentationController?.delegate = self
        return sheet
      },
      failed: { [weak self] in self?.finishPhotos(.failure(.pickerFailed)) })
  }

  /// The system photo picker: it runs outside the app, so no Photos permission is needed. Gives each picture, in the
  /// order picked, or the reason one could not be loaded (empty when cancelled); `.compatible` hands over JPEG/PNG
  /// instead of HEIC or Live Photo bundles.
  func pickPhotos(limit: Int, _ reply: @escaping Reply<[PickedPicture]>) {
    beginPhotos(reply) { [weak self] in
      var configuration = PHPickerConfiguration(photoLibrary: .shared())
      configuration.filter = .images
      configuration.selectionLimit = max(1, min(4, limit))
      configuration.preferredAssetRepresentationMode = .compatible
      let picker = PHPickerViewController(configuration: configuration)
      picker.delegate = self
      return picker
    }
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard !results.isEmpty else { return finishPhotos(.success([])) }
    let run = photoRun
    let lock = NSLock()
    var pictures = [PickedPicture](repeating: .failed(FilesFailure.unreadable.message), count: results.count)
    let group = DispatchGroup()
    for (index, item) in results.enumerated() {
      group.enter()
      // The provider's temporary file is gone when this handler returns, so it is read here.
      item.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
        defer { group.leave() }
        let picture: PickedPicture
        if let url {
          let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
          if size > 20 * 1024 * 1024 {
            picture = .failed(FilesFailure.fileTooLarge.message)
          } else if let data = try? Data(contentsOf: url) {
            let base = item.itemProvider.suggestedName ?? "photo"
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            picture = .picture(name: "\(base).\(ext)", bytes: data)
          } else {
            picture = .failed(FilesFailure.unreadable.message)
          }
        } else if error != nil {
          // Typically an iCloud original that could not be downloaded.
          picture = .failed("图片无法下载，请检查网络后重试")
        } else {
          picture = .failed(FilesFailure.unreadable.message)
        }
        lock.lock()
        pictures[index] = picture
        lock.unlock()
      }
    }
    group.notify(queue: .main) { [weak self] in
      // (not if the pick was cancelled meanwhile, and another may have begun: it is not theirs)
      guard let self, run == self.photoRun else { return }
      self.finishPhotos(.success(pictures))
    }
  }

  /// One picture from the camera. A refused camera is reported, not left as a black screen.
  func takePhoto(_ reply: @escaping Reply<[PickedPicture]>) {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return reply(.failure(.cameraUnavailable)) }
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    guard status != .denied, status != .restricted else { return reply(.failure(.cameraDenied)) }
    beginPhotos(reply) { [weak self] in
      let picker = UIImagePickerController()
      picker.sourceType = .camera
      picker.mediaTypes = [UTType.image.identifier]
      picker.delegate = self
      return picker
    }
  }

  func imagePickerController(
    _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    guard let image = info[.originalImage] as? UIImage else { return finishPhotos(.failure(.unreadable)) }
    io.async {
      // The camera's orientation travels as metadata in the JPEG; the image normalizer applies it.
      let jpeg = image.jpegData(compressionQuality: 0.92)
      DispatchQueue.main.async {
        guard let jpeg else { return self.finishPhotos(.failure(.unreadable)) }
        let stamp = Int(Date().timeIntervalSince1970)
        self.finishPhotos(.success([.picture(name: "photo-\(stamp).jpg", bytes: jpeg)]))
      }
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    finishPhotos(.success([]))
  }

  // MARK: Share and settings

  func share(_ sources: [FileSource], _ reply: @escaping Reply<Bool>) {
    guard let files = stage(sources), !files.isEmpty else { return reply(.failure(.shareFailed)) }
    present(
      { [weak self] top in
        let sheet = UIActivityViewController(activityItems: files, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
          for file in files { self?.discard(file) }
        }
        if let popover = sheet.popoverPresentationController {
          popover.sourceView = top.view
          popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
          popover.permittedArrowDirections = []
        }
        return sheet
      },
      presented: { reply(.success(true)) },
      failed: { [weak self] in
        for file in files { self?.discard(file) }
        reply(.failure(.shareFailed))
      })
  }

  /// This app's page in the Settings app (e.g. to allow the microphone again).
  func openAppSettings(_ reply: @escaping (Bool) -> Void) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return reply(false) }
    UIApplication.shared.open(url, options: [:]) { opened in
      DispatchQueue.main.async { reply(opened) }
    }
  }
}

// MARK: async forms, for the native app

extension FilesService {
  private func wait<T>(_ start: (@escaping Reply<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
  }

  @MainActor func save(_ sources: [FileSource]) async throws -> Bool { try await wait { save(sources, $0) } }
  @MainActor func saveToPhotos(_ source: FileSource, mime: String) async throws -> Bool {
    try await wait { saveToPhotos(source, mime: mime, $0) }
  }
  @MainActor func share(_ sources: [FileSource]) async throws -> Bool { try await wait { share(sources, $0) } }
  @MainActor func openFiles(types: [UTType], multiple: Bool = false) async throws -> [URL] {
    try await wait { openFiles(types: types, multiple: multiple, $0) }
  }
  @MainActor func pickPhotos(limit: Int = 4) async throws -> [PickedPicture] { try await wait { pickPhotos(limit: limit, $0) } }
  @MainActor func takePhoto() async throws -> [PickedPicture] { try await wait { takePhoto($0) } }
  func normalizeImage(_ data: Data) async throws -> Data { try await wait { normalizeImage(data, $0) } }
}
