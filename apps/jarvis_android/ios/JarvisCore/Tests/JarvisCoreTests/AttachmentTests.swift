import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import JarvisCore

final class FakePDF: PDFExtractor, @unchecked Sendable {
  var text = "第一页"
  func extractPDF(_ pdf: Data) async throws -> String { text }
}

func makeImage(_ width: Int, _ height: Int, type: UTType = .png, alpha: Bool = false) -> Data {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
  if alpha { context.clear(CGRect(x: 0, y: 0, width: width, height: height)) } else {
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  }
  let out = NSMutableData()
  let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  return out as Data
}

func size(of jpeg: Data) -> (Int, Int)? {
  guard let s = CGImageSourceCreateWithData(jpeg as CFData, nil),
    let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return nil }
  return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
}

final class ImageNormalizerTests: XCTestCase {
  func testAPictureBecomesAJpeg() throws {
    let out = try ImageNormalizer.normalize(makeImage(200, 100))
    XCTAssertEqual(out.prefix(2), Data([0xFF, 0xD8]))
    XCTAssertEqual(size(of: out)?.0, 200)
  }

  func testTransparencyIsFlattenedOntoWhite() throws {
    let out = try ImageNormalizer.normalize(makeImage(40, 40, alpha: true))
    let source = CGImageSourceCreateWithData(out as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
    XCTAssertGreaterThan(pixel[0], 240)
    XCTAssertGreaterThan(pixel[1], 240)
    XCTAssertGreaterThan(pixel[2], 240)
  }

  func testALargePictureIsCappedAt3072() throws {
    let out = try ImageNormalizer.normalize(makeImage(4000, 1000))
    XCTAssertEqual(size(of: out)?.0, 3072)
  }

  func testWhatIsNotAPictureIsRefused() {
    XCTAssertThrowsError(try ImageNormalizer.normalize(Data("not an image".utf8))) { XCTAssertEqual(($0 as? JarvisException)?.message, "图片无法读取") }
    XCTAssertThrowsError(try ImageNormalizer.normalize(Data(count: 20 * 1024 * 1024 + 1))) {
      XCTAssertEqual(($0 as? JarvisException)?.message, "图片文件过大，请选择20MB以内的图片")
    }
  }

  func testAPictureThatStaysTooBigAfterAllTheTriesIsRefused() {
    XCTAssertThrowsError(try ImageNormalizer.normalize(makeImage(300, 300), maxBytes: 10)) {
      XCTAssertEqual(($0 as? JarvisException)?.message, "图片压缩后仍超过3MB，请换一张较小的图片")
    }
  }
}

@MainActor
final class AttachmentIntakeTests: XCTestCase {
  var store: JarvisStore!
  var api: FakeTransport!
  let pdf = FakePDF()

  override func setUp() async throws {
    LocalData.sweepOnStart = false
    api = FakeTransport()
    api.modelsResult = .success([ModelInfo("chat-a", "chat-a", metadata: ["jarvis": .object(["image_input": .bool(true), "pdf_text": .bool(true)])])])
    store = JarvisStore(api: api, vault: MemoryVault())
    await store.initialize()
    _ = await store.login("u", "p")
  }

  func attach(_ files: [AttachmentSource]) async throws {
    try await Attachments.attach(files, to: store.current.id, in: store, pdf: pdf, normalize: { $0 })
  }

  func testATextFileBecomesADocumentWithItsText() async throws {
    try await attach([AttachmentSource(name: "笔记.MD", data: Data("# 标题\n内容".utf8))])
    let a = store.current.pendingAttachments[0]
    XCTAssertEqual(a.kind, "document")
    XCTAssertEqual(a.mime, "text/plain")
    XCTAssertEqual(a.text, "# 标题\n内容")
    XCTAssertEqual(a.name, "笔记.MD")
    XCTAssertTrue(a.id.hasPrefix("file_"))
    XCTAssertFalse(store.attachmentsLoading(store.current.id), "the loading state is over")
  }

  func testAPictureIsNormalisedAndNamedAnImage() async throws {
    try await attach([AttachmentSource(name: "IMG_1.HEIC", data: Data([1, 2, 3]))])
    XCTAssertEqual(store.current.pendingAttachments[0].kind, "image")
    XCTAssertEqual(store.current.pendingAttachments[0].mime, "image/jpeg")
    XCTAssertEqual(try store.vault.readBlob(store.current.pendingAttachments[0].id), Data([1, 2, 3]))
  }

  func testAPictureFromAPickerIsAPictureWhateverItsNameSays() async throws {
    try await attach([AttachmentSource(name: "无扩展名", data: Data([9]), isImage: true)])
    XCTAssertEqual(store.current.pendingAttachments[0].kind, "image")
  }

  func testAPDFGivesItsTextOnlyWhereTheModelOffersIt() async throws {
    try await attach([AttachmentSource(name: "a.pdf", data: Data([1]))])
    XCTAssertEqual(store.current.pendingAttachments[0].text, "第一页")
    XCTAssertEqual(store.current.pendingAttachments[0].mime, "application/pdf")
    api.modelsResult = .success([ModelInfo("chat-a", "chat-a")])
    await store.connect()
    do { try await attach([AttachmentSource(name: "b.pdf", data: Data([1]))]); XCTFail() } catch {
      XCTAssertEqual((error as? JarvisException)?.message, "当前入口未开放PDF文字提取")
    }
    do { try await attach([AttachmentSource(name: "c.png", data: Data([1]))]); XCTFail() } catch {
      XCTAssertEqual((error as? JarvisException)?.message, "当前模型不支持图片输入")
    }
  }

  func testWhatIsNotReadableAsTextIsRefusedWithTheReason() async {
    let cases: [(String, Data, String)] = [
      ("x.exe", Data([1]), "不支持此附件格式"), ("x.txt", Data([0xFF, 0xFE, 0xFD]), "文本文件需为UTF-8编码"),
      ("x.txt", Data("a\u{0}b".utf8), "此文件不是可读取的文本"), ("x.txt", Data("   \n".utf8), "文件需有文字且不超过10万字符"),
      ("x.txt", Data(repeating: 97, count: 1024 * 1024 + 1), "文本文件最大1MB"),
      ("x.txt", Data(String(repeating: "字", count: 100_001).utf8), "文件需有文字且不超过10万字符"),
    ]
    for (name, data, message) in cases {
      do { try await attach([AttachmentSource(name: name, data: data)]); XCTFail(name) } catch {
        XCTAssertEqual((error as? JarvisException)?.message, message, name)
      }
    }
    XCTAssertTrue(store.current.pendingAttachments.isEmpty)
  }

  func testAFileOver20MBIsRefusedBeforeItIsRead() async {
    var read = false
    let big = AttachmentSource(name: "x.txt", length: { 21 * 1024 * 1024 }, read: { read = true; return Data() })
    do { try await attach([big]); XCTFail() } catch { XCTAssertEqual((error as? JarvisException)?.message, "单个附件不能超过20MB") }
    XCTAssertFalse(read)
  }

  func testOneBadFileDoesNotStopTheOthersAndTheFailuresAreCounted() async {
    let files = [
      AttachmentSource(name: "a.txt", data: Data("好".utf8)), AttachmentSource(name: "b.exe", data: Data([1])),
      AttachmentSource(name: "c.exe", data: Data([1])),
    ]
    do { try await attach(files); XCTFail() } catch {
      XCTAssertEqual((error as? JarvisException)?.message, "2 个未能添加：不支持此附件格式")
    }
    XCTAssertEqual(store.current.pendingAttachments.map(\.name), ["a.txt"])
    do { try await attach([AttachmentSource(name: "d.exe", data: Data([1]))]); XCTFail() } catch {
      XCTAssertEqual((error as? JarvisException)?.message, "不支持此附件格式", "one file: its own message")
    }
  }

  func testPicturesThatFailAreCountedAsPictures() async {
    let bad = (0..<2).map { _ in AttachmentSource(name: "图片", isImage: true, length: { throw JarvisException("图片无法读取") }, read: { Data() }) }
    do { try await attach(bad); XCTFail() } catch { XCTAssertEqual((error as? JarvisException)?.message, "2 张未能添加：图片无法读取") }
  }

  func testNoMoreThanFourAndNothingRead() async throws {
    for i in 0..<4 { try await attach([AttachmentSource(name: "f\(i).txt", data: Data("x".utf8))]) }
    var read = false
    let more = AttachmentSource(name: "g.txt", length: { 1 }, read: { read = true; return Data("x".utf8) })
    do { try await attach([more]); XCTFail() } catch { XCTAssertEqual((error as? JarvisException)?.message, "每条消息最多4个附件") }
    XCTAssertFalse(read)
  }
}
