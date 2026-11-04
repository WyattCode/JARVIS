import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns any picture the system can decode (JPEG, PNG, WebP, HEIC) into the JPEG the model is sent: orientation applied,
/// the long edge at most 3072 px, flattened onto white, at most 3 MB (quality 0.88, then lower, then a smaller picture,
/// before giving up).
public enum ImageNormalizer {
  public static func normalize(_ data: Data, maxBytes: Int = 3 * 1024 * 1024) throws -> Data {
    guard data.count <= 20 * 1024 * 1024 else { throw JarvisException("图片文件过大，请选择20MB以内的图片") }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else { throw JarvisException("图片无法读取") }
    guard Int64(width) * Int64(height) <= 60_000_000 else { throw JarvisException("图片尺寸过大，请选择小于6000万像素的图片") }
    let longEdge = min(3072, max(width, height))
    for scale in [1.0, 0.75, 0.5] {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: max(1, Int(Double(longEdge) * scale)),
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw JarvisException("图片无法读取")
      }
      guard let flat = flatten(image) else { throw JarvisException("图片无法读取") }
      for quality in [0.88, 0.75, 0.6] {
        if let jpeg = jpeg(flat, quality: quality), jpeg.count <= maxBytes { return jpeg }
      }
    }
    throw JarvisException("图片压缩后仍超过3MB，请换一张较小的图片")
  }

  private static func flatten(_ image: CGImage) -> CGImage? {
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(rect)
    context.draw(image, in: rect)
    return context.makeImage()
  }

  private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? out as Data : nil
  }
}

/// Something the person picked: read only once it has passed the size checks. `isImage`: it comes from a picture picker,
/// so the image decoder (not the file name) decides whether it is usable.
public struct AttachmentSource {
  public var name: String
  public var length: () async throws -> Int
  public var read: () async throws -> Data
  public var isImage: Bool

  public init(name: String, isImage: Bool = false, length: @escaping () async throws -> Int, read: @escaping () async throws -> Data) {
    self.name = name
    self.isImage = isImage
    self.length = length
    self.read = read
  }

  public init(name: String, data: Data, isImage: Bool = false) {
    self.init(name: name, isImage: isImage, length: { data.count }, read: { data })
  }
}

/// What the service can do with a file besides images (PDF text extraction).
public protocol PDFExtractor: AnyObject, Sendable {
  func extractPDF(_ pdf: Data) async throws -> String
}

extension JarvisAPI: PDFExtractor {}

public enum Attachments {
  public static let imageExtensions = ["jpg", "jpeg", "png", "webp", "heic", "heif"]
  public static let textExtensions = [
    "txt", "md", "csv", "json", "log", "py", "js", "ts", "css", "html", "xml", "yaml", "yml", "sql", "sh", "ini", "toml",
  ]

  /// The pictures a photo picker or the camera gave. The composer shows the loading state while the system picker (and
  /// any iCloud download behind it) runs, and sending waits for it.
  @MainActor
  public static func attach(
    _ files: [AttachmentSource], to ownerId: String, in store: JarvisStore, pdf: PDFExtractor?,
    normalize: @escaping (Data) throws -> Data = { try ImageNormalizer.normalize($0) }
  ) async throws {
    var total = 0
    var failures: [(error: Error, isImage: Bool)] = []
    for file in files {
      if store.conversation(ownerId) == nil { return }
      total += 1
      do {
        try await attachOne(file, to: ownerId, in: store, pdf: pdf, normalize: normalize)
      } catch let e as JarvisException {
        if e.unauthorized { throw e }
        failures.append((e, file.isImage))
      } catch {
        failures.append((error, file.isImage))
      }
    }
    if failures.isEmpty { return }
    if total == 1 { throw failures[0].error }
    let unit = failures.allSatisfy { $0.isImage } ? "张" : "个"
    let first = (failures[0].error as? JarvisException)?.message ?? "文件无法读取"
    throw JarvisException("\(failures.count) \(unit)未能添加：\(first)")
  }

  @MainActor
  static func attachOne(
    _ file: AttachmentSource, to ownerId: String, in store: JarvisStore, pdf: PDFExtractor?, normalize: (Data) throws -> Data
  ) async throws {
    guard let owner = store.conversation(ownerId) else { return }
    if owner.pendingAttachments.count >= 4 { throw JarvisException("每条消息最多4个附件") }
    let count = try await file.length()
    if count > 20 * 1024 * 1024 { throw JarvisException("单个附件不能超过20MB") }
    store.beginAttachment(ownerId)
    defer { store.endAttachment(ownerId) }
    let model = store.models.first { $0.id == store.model && $0.kind == "chat" }
    let ext = (file.name.lowercased().split(separator: ".").last).map(String.init) ?? file.name.lowercased()
    var bytes = try await file.read()
    var text: String?
    var mime = "text/plain"
    var kind = "document"
    if file.isImage || imageExtensions.contains(ext) {
      if model?.imageInput != true { throw JarvisException("当前模型不支持图片输入") }
      bytes = try normalize(bytes)
      mime = "image/jpeg"
      kind = "image"
    } else if ext == "pdf" {
      if model?.pdfInput != true { throw JarvisException("当前入口未开放PDF文字提取") }
      guard let pdf else { throw JarvisException("当前入口未开放PDF文字提取") }
      mime = "application/pdf"
      text = try await pdf.extractPDF(bytes)
    } else {
      if !textExtensions.contains(ext) { throw JarvisException("不支持此附件格式") }
      if bytes.count > 1024 * 1024 { throw JarvisException("文本文件最大1MB") }
      guard let decoded = String(data: bytes, encoding: .utf8) else { throw JarvisException("文本文件需为UTF-8编码") }
      if decoded.contains("\u{0}") { throw JarvisException("此文件不是可读取的文本") }
      text = decoded
    }
    if let text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf16.count > 100_000 {
      throw JarvisException("文件需有文字且不超过10万字符")
    }
    let item = Attachment(
      id: "file_\(Int(Date().timeIntervalSince1970 * 1_000_000))_\(store.nextAttachmentSerial())", name: file.name, mime: mime,
      kind: kind, text: text, size: bytes.count)
    try await store.addAttachment(ownerId, item, bytes: bytes)
  }
}
