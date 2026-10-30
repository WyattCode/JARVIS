import AVFoundation
import Flutter
import ImageIO
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// iOS counterpart of the `ai.jarvis.app/files` half of MainActivity.kt: image normalisation, save-to-Files, system share.
final class FilesBridge: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate,
  PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate
{
  /// Each case reaches Dart with its own code and a message the user can act on.
  private enum FilesError: Error {
    case unreadable, fileTooLarge, dimensionsTooLarge, stillTooLarge

    var flutterError: FlutterError {
      switch self {
      case .unreadable:
        return FlutterError(code: "image_invalid", message: "图片无法读取", details: nil)
      case .fileTooLarge:
        return FlutterError(code: "image_file_too_large", message: "图片文件过大，请选择20MB以内的图片", details: nil)
      case .dimensionsTooLarge:
        return FlutterError(code: "image_dimensions", message: "图片尺寸过大，请选择小于6000万像素的图片", details: nil)
      case .stillTooLarge:
        return FlutterError(code: "image_compress", message: "图片压缩后仍超过3MB，请换一张较小的图片", details: nil)
      }
    }
  }

  private let io = DispatchQueue(label: "ai.jarvis.app.files", qos: .userInitiated)
  private var pendingSave: FlutterResult?
  private var pendingURLs: [URL] = []
  private var pendingPicker: UIViewController?
  // The photo library picker or the camera (one at a time) and the call waiting for its pictures.
  private var pendingPhotos: FlutterResult?
  private var photoPicker: UIViewController?
  // Staged files that a picker, share sheet or Photos write still needs (main thread only).
  private var inFlight = Set<URL>()
  private static var exportsDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
  }

  func register(with messenger: FlutterBinaryMessenger) {
    // Nothing staged by an earlier run is still needed: backups left by a killed app must not linger in tmp.
    try? FileManager.default.removeItem(at: Self.exportsDirectory)
    let channel = FlutterMethodChannel(name: "ai.jarvis.app/files", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "normalizeImage":
        guard let data = (call.arguments as? FlutterStandardTypedData)?.data else {
          return result(FilesError.unreadable.flutterError)
        }
        self.io.async {
          let outcome = Result { try Self.normalizeImage(data) }
          DispatchQueue.main.async {
            switch outcome {
            case .success(let jpeg): result(FlutterStandardTypedData(bytes: jpeg))
            case .failure(let error): result((error as? FilesError ?? .unreadable).flutterError)
            }
          }
        }
      case "save": self.save(call, result)
      case "saveToPhotos": self.saveToPhotos(call, result)
      case "share": self.share(call, result)
      case "pickPhotos": self.pickPhotos(call, result)
      case "takePhoto": self.takePhoto(result)
      case "openAppSettings": self.openAppSettings(result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Decodes (JPEG/PNG/WebP/HEIC), applies EXIF orientation, caps the long edge at 3072px, flattens onto white,
  /// and re-encodes as JPEG within 3MB: q=0.88 first, then lower quality, then a smaller picture, before giving up.
  static func normalizeImage(_ data: Data) throws -> Data {
    guard data.count <= 20 * 1024 * 1024 else { throw FilesError.fileTooLarge }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Int,
      let height = props[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else { throw FilesError.unreadable }
    guard Int64(width) * Int64(height) <= 60_000_000 else { throw FilesError.dimensionsTooLarge }
    let longEdge = min(3072, max(width, height))
    for scale in [1.0, 0.75, 0.5] {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, Int(Double(longEdge) * scale)),
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw FilesError.unreadable
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
    throw FilesError.stillTooLarge
  }

  /// Stages what a call carries (`bytes` or `path`, or several under `files`) as exports/<run id>/<name>, so the system
  /// dialog and the share sheet show the name the user should see. A file on disk is hard-linked (copied when that is not
  /// possible), never read into memory.
  private func stage(_ call: FlutterMethodCall) -> [URL]? {
    guard let args = call.arguments as? [String: Any] else { return nil }
    var sources: [(name: String, bytes: FlutterStandardTypedData?, path: String?)] = []
    if let files = args["files"] as? [[String: Any]] {
      sources = files.map { ($0["name"] as? String ?? "", nil, $0["path"] as? String) }
    } else {
      sources = [(args["name"] as? String ?? "", args["bytes"] as? FlutterStandardTypedData, args["path"] as? String)]
    }
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
          try bytes.data.write(to: file, options: .completeFileProtection)
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

  private func save(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard pendingSave == nil else {
      return result(FlutterError(code: "busy", message: "请先完成当前保存操作", details: nil))
    }
    guard let files = stage(call), !files.isEmpty else {
      return result(FlutterError(code: "save_failed", message: "文件保存失败", details: nil))
    }
    pendingSave = result
    pendingURLs = files
    present(
      { [weak self] _ in
        let picker = UIDocumentPickerViewController(forExporting: files, asCopy: true)
        picker.delegate = self
        self?.pendingPicker = picker
        picker.presentationController?.delegate = self
        return picker
      },
      failed: { [weak self] in
        self?.finishSave(false, error: FlutterError(code: "save_failed", message: "无法打开保存窗口，请重试", details: nil))
      })
  }

  /// Saves a generated picture or video straight into the Photos library (add-only access, no browsing of it).
  private func saveToPhotos(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let mime = (call.arguments as? [String: Any])?["mime"] as? String ?? ""
    let isVideo = mime.hasPrefix("video/")
    guard let staged = stage(call)?.first else {
      return result(FlutterError(code: "save_failed", message: "文件保存失败", details: nil))
    }
    // Photos takes JPEG/PNG/HEIC/GIF; anything else (WebP) is re-encoded losslessly first, off the main thread.
    guard !isVideo, !["image/jpeg", "image/png", "image/gif", "image/heic"].contains(mime) else {
      return addToPhotos(staged, isVideo: isVideo, result)
    }
    io.async {
      let converted = staged.deletingPathExtension().appendingPathExtension("png")
      var written = false
      if let data = try? Data(contentsOf: staged), let image = UIImage(data: data), let png = image.pngData() {
        written = (try? png.write(to: converted, options: .completeFileProtection)) != nil
      }
      DispatchQueue.main.async {
        guard written else { return self.addToPhotos(staged, isVideo: isVideo, result) }
        self.discard(staged)
        self.inFlight.insert(converted)
        self.addToPhotos(converted, isVideo: isVideo, result)
      }
    }
  }

  private func addToPhotos(_ file: URL, isVideo: Bool, _ result: @escaping FlutterResult) {
    let done: (FlutterError?) -> Void = { error in
      DispatchQueue.main.async {
        self.discard(file)
        result(error ?? true)
      }
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        return done(FlutterError(code: "photos_denied", message: "请在“设置”里允许 JARVIS 添加照片", details: nil))
      }
      PHPhotoLibrary.shared().performChanges(
        {
          let request = PHAssetCreationRequest.forAsset()
          request.addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
        },
        completionHandler: { ok, _ in
          done(ok ? nil : FlutterError(code: "save_failed", message: "保存到相册失败", details: nil))
        })
    }
  }

  /// Always leaves nothing pending: the next save must never find the previous one still "busy".
  private func finishSave(_ saved: Bool, error: FlutterError? = nil) {
    for url in pendingURLs { discard(url) }
    let result = pendingSave
    pendingSave = nil
    pendingURLs = []
    pendingPicker = nil
    result?(error ?? saved)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finishSave(true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishSave(false)
  }

  /// Swiping the dialog down dismisses it without either delegate method on some iOS versions.
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if presentationController.presentedViewController === pendingPicker { finishSave(false) }
    if presentationController.presentedViewController === photoPicker { finishPhotos() }
  }

  // MARK: Pictures to attach

  private func finishPhotos(_ pictures: [[String: Any]] = [], error: FlutterError? = nil) {
    let result = pendingPhotos
    pendingPhotos = nil
    photoPicker = nil
    result?(error ?? pictures)
  }

  private func beginPhotos(_ result: @escaping FlutterResult, _ makeSheet: @escaping () -> UIViewController) {
    guard pendingPhotos == nil else {
      return result(FlutterError(code: "busy", message: "请先完成当前选择", details: nil))
    }
    pendingPhotos = result
    present(
      { [weak self] _ in
        let sheet = makeSheet()
        self?.photoPicker = sheet
        sheet.presentationController?.delegate = self
        return sheet
      },
      failed: { [weak self] in
        self?.finishPhotos(error: FlutterError(code: "picker_failed", message: "无法打开，请重试", details: nil))
      })
  }

  /// The system photo picker: it runs outside the app, so no Photos permission is needed. Returns each picture as
  /// `{name, bytes}` or, for one that could not be loaded, `{error}` (empty when cancelled); `.compatible` hands over
  /// JPEG/PNG instead of HEIC or Live Photo bundles.
  private func pickPhotos(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let asked = (call.arguments as? [String: Any])?["limit"] as? Int ?? 4
    beginPhotos(result) { [weak self] in
      var configuration = PHPickerConfiguration(photoLibrary: .shared())
      configuration.filter = .images
      configuration.selectionLimit = max(1, min(4, asked))
      configuration.preferredAssetRepresentationMode = .compatible
      let picker = PHPickerViewController(configuration: configuration)
      picker.delegate = self
      return picker
    }
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard !results.isEmpty else { return finishPhotos() }
    let lock = NSLock()
    // One entry per picture, in the order picked: {name, bytes}, or {error} for one that could not be loaded.
    let unreadable: [String: Any] = ["error": FilesError.unreadable.flutterError.message ?? ""]
    var pictures = [[String: Any]](repeating: unreadable, count: results.count)
    let group = DispatchGroup()
    for (index, item) in results.enumerated() {
      group.enter()
      // The provider's temporary file is gone when this handler returns, so it is read here.
      item.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
        defer { group.leave() }
        let picture: [String: Any]
        if let url {
          let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
          if size > 20 * 1024 * 1024 {
            picture = ["error": FilesError.fileTooLarge.flutterError.message ?? ""]
          } else if let data = try? Data(contentsOf: url) {
            let base = item.itemProvider.suggestedName ?? "photo"
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            picture = ["name": "\(base).\(ext)", "bytes": FlutterStandardTypedData(bytes: data)]
          } else {
            picture = ["error": FilesError.unreadable.flutterError.message ?? ""]
          }
        } else if error != nil {
          // Typically an iCloud original that could not be downloaded.
          picture = ["error": "图片无法下载，请检查网络后重试"]
        } else {
          picture = ["error": FilesError.unreadable.flutterError.message ?? ""]
        }
        lock.lock()
        pictures[index] = picture
        lock.unlock()
      }
    }
    group.notify(queue: .main) { [weak self] in
      self?.finishPhotos(pictures)
    }
  }

  /// One picture from the camera. A refused camera is reported, not left as a black screen.
  private func takePhoto(_ result: @escaping FlutterResult) {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      return result(FlutterError(code: "camera_unavailable", message: "此设备没有可用的相机", details: nil))
    }
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    guard status != .denied, status != .restricted else {
      return result(FlutterError(code: "camera_denied", message: "请在“设置”里允许 JARVIS 使用相机", details: nil))
    }
    beginPhotos(result) { [weak self] in
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
    guard let image = info[.originalImage] as? UIImage else {
      return finishPhotos(error: FilesError.unreadable.flutterError)
    }
    io.async {
      // The camera's orientation travels as metadata in the JPEG; the image bridge applies it when normalising.
      let jpeg = image.jpegData(compressionQuality: 0.92)
      DispatchQueue.main.async {
        guard let jpeg else { return self.finishPhotos(error: FilesError.unreadable.flutterError) }
        let stamp = Int(Date().timeIntervalSince1970)
        self.finishPhotos([["name": "photo-\(stamp).jpg", "bytes": FlutterStandardTypedData(bytes: jpeg)]])
      }
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    finishPhotos()
  }

  private func share(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let files = stage(call), !files.isEmpty else {
      return result(FlutterError(code: "share_failed", message: "无法打开分享，请重试", details: nil))
    }
    let failure = FlutterError(code: "share_failed", message: "无法打开分享，请重试", details: nil)
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
      presented: { result(true) },
      failed: { [weak self] in
        for file in files { self?.discard(file) }
        result(failure)
      })
  }

  /// This app's page in the Settings app (e.g. to allow the microphone again).
  private func openAppSettings(_ result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return result(false) }
    UIApplication.shared.open(url, options: [:]) { opened in
      DispatchQueue.main.async { result(opened) }
    }
  }
}
