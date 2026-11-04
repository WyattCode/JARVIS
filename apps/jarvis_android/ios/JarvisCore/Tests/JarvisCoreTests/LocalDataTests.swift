import XCTest

@testable import JarvisCore

final class LocalDataTests: XCTestCase {
  func testClearingRemovesTheKeptVideosAndTellsTheListener() {
    let saved = LocalData.cacheRoot
    defer { LocalData.cacheRoot = saved; LocalData.onCleared = nil }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    LocalData.cacheRoot = root
    let folder = root.appendingPathComponent("jarvis-video", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: folder.appendingPathComponent("a.mp4").path, contents: Data([1]))
    nonisolated(unsafe) var told = false
    LocalData.onCleared = { told = true }
    LocalData.clearCachedMedia()
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertTrue(told)
  }

  func testNumbersFromTheServerThatDoNotFitAreNotTrapped() {
    XCTAssertNil(JSONValue.number(1e30).int)
    XCTAssertNil(JSONValue.number(.infinity).int)
    XCTAssertEqual(JSONValue.number(7.9).int, 7)
    XCTAssertEqual(JSONValue.number(-3).int, -3)
  }
}

final class ModelOrderTests: XCTestCase {
  func testTheModelsNamedLastGoAfterTheOthersAndTheRestKeepTheirOrder() {
    let names = ["MiniMax H3", "Qwen3", "minimax-h3-turbo", "Drama", "MiniMax M2"]
    XCTAssertEqual(ModelOrder.apply(names) { $0 }, ["Qwen3", "Drama", "MiniMax M2", "MiniMax H3", "minimax-h3-turbo"])
    XCTAssertEqual(ModelOrder.apply([String]()) { $0 }, [])
  }
}

final class OuterColumnsTests: XCTestCase {
  func testSidewaysTheBoxIsNineTenthsOfTheUprightShareOfTheScreenAndTheMessagesSixPercentLess() {
    // 466 x 678 pt with a strip of 84: upright the box is (466 - 84 - 32) of 466; sideways that share of 678, less a tenth.
    let w = OuterColumns.widths(shape: CGSize(width: 678, height: 466), pane: 594, keyboardUp: false)
    let uprightShare = (466.0 - 84 - 32) / 466
    XCTAssertEqual(w.composer / 678, uprightShare * 0.9, accuracy: 0.001)
    XCTAssertEqual(w.messages, w.composer * 0.94, accuracy: 0.001)
    XCTAssertLessThanOrEqual(w.composer, 594 - 32)
  }

  func testItNeverGoesPastThePane() {
    let w = OuterColumns.widths(shape: CGSize(width: 900, height: 466), pane: 500, keyboardUp: true)
    XCTAssertLessThanOrEqual(w.composer, 500 - 17)
  }
}
