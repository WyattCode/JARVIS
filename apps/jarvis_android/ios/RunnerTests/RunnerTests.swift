
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Runner

/// Native checks for `FilesService.normalizeImage`: same limits as Android (long edge <= 3072px, <= 3MB JPEG, white flatten).
class RunnerTests: XCTestCase {
  private func makeImage(
    width: Int, height: Int, type: UTType, alpha: Bool = false, orientation: Int? = nil
  ) throws -> Data {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let ctx = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue))
    if !alpha {
      ctx.setFillColor(UIColor.red.cgColor)
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    // Opaque blue block in the middle; the rest stays red (or fully transparent with alpha).
    ctx.setFillColor(UIColor.blue.cgColor)
    ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    let image = try XCTUnwrap(ctx.makeImage())
    let out = NSMutableData()
    let dest = try XCTUnwrap(
      CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil),
      "\(type.identifier) encoding is unavailable on this runtime")
    var props: [CFString: Any] = [:]
    if let orientation { props[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    return out as Data
  }

  private func decode(_ jpeg: Data) throws -> (w: Int, h: Int, image: CGImage) {
    XCTAssertEqual(Array(jpeg.prefix(3)), [0xFF, 0xD8, 0xFF], "output must be JPEG")
    let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return (image.width, image.height, image)
  }

  func testLargeHeicIsScaledToLongEdge3072AndStaysUnder3MB() throws {
    let heic = try makeImage(width: 3000, height: 4000, type: .heic)
    let out = try FilesService.normalizeImage(heic)
    let d = try decode(out)
    XCTAssertEqual(max(d.w, d.h), 3072)
    XCTAssertEqual(Double(d.w) / Double(d.h), 0.75, accuracy: 0.01, "aspect ratio is preserved")
    XCTAssertLessThanOrEqual(out.count, 3 * 1024 * 1024)
  }

  func testSmallImageIsNotUpscaled() throws {
    let out = try FilesService.normalizeImage(try makeImage(width: 640, height: 480, type: .jpeg))
    let d = try decode(out)
    XCTAssertEqual(d.w, 640)
    XCTAssertEqual(d.h, 480)
  }

  func testExifOrientationIsApplied() throws {
    // Orientation 6 = rotate 90 degrees CW for display, so a 400x200 file shows as 200x400.
    let out = try FilesService.normalizeImage(
      try makeImage(width: 400, height: 200, type: .jpeg, orientation: 6))
    let d = try decode(out)
    XCTAssertEqual(d.w, 200)
    XCTAssertEqual(d.h, 400)
  }

  func testTransparentPixelsAreFlattenedOntoWhite() throws {
    let out = try FilesService.normalizeImage(
      try makeImage(width: 200, height: 200, type: .png, alpha: true))
    let d = try decode(out)
    let ctx = try XCTUnwrap(
      CGContext(
        data: nil, width: d.w, height: d.h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.draw(d.image, in: CGRect(x: 0, y: 0, width: d.w, height: d.h))
    let px = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
    // Corner pixel (transparent in the source) must be near white, not black.
    XCTAssertGreaterThan(Int(px[0]) + Int(px[1]) + Int(px[2]), 3 * 245)
  }

  func testNonImageDataIsRejected() {
    XCTAssertThrowsError(try FilesService.normalizeImage(Data("not an image".utf8)))
  }
}
