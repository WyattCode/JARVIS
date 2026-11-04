import CryptoKit
import XCTest

@testable import JarvisCore

final class VaultTests: XCTestCase {
  var root: URL!

  override func setUp() {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-vault-\(UUID().uuidString)")
  }

  override func tearDown() { try? FileManager.default.removeItem(at: root) }

  func vault(_ keys: KeyProvider = FixedKey()) -> FileVault { FileVault(root: root, keys: keys, excludedFromBackup: false) }

  func testStateRoundTripsAndIsEncryptedOnDisk() throws {
    let v = vault()
    XCTAssertNil(try v.readState())
    try v.writeState("你好 {\"a\":1}")
    XCTAssertEqual(try v.readState(), "你好 {\"a\":1}")
    let raw = try Data(contentsOf: root.appendingPathComponent("jarvis-state-v1.aes"))
    XCTAssertEqual(raw[0], 1, "version byte")
    XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("你好"))
    XCTAssertGreaterThanOrEqual(raw.count, 29)
  }

  func testTheLayoutIsTheOneTheFlutterVaultWrote() throws {
    // version 1 + nonce(12) + ciphertext + tag(16), sealed with AES-256-GCM and no associated data
    let key = Data(repeating: 9, count: 32)
    let sealed = try AES.GCM.seal(Data("old".utf8), using: SymmetricKey(data: key))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try (Data([1]) + sealed.combined!).write(to: root.appendingPathComponent("jarvis-state-v1.aes"))
    XCTAssertEqual(try vault(FixedKey(key)).readState(), "old")
  }

  func testBlobsAreListedDeletedAndTheirNamesChecked() throws {
    let v = vault()
    try v.writeBlob("abc_1-x", Data([1, 2, 3]))
    try v.writeBlob("def", Data([4]))
    XCTAssertEqual(try v.readBlob("abc_1-x"), Data([1, 2, 3]))
    XCTAssertEqual(Set(try v.listBlobs()), ["abc_1-x", "def"])
    try v.deleteBlob("def")
    XCTAssertNil(try v.readBlob("def"))
    for bad in ["../x", "a/b", "", String(repeating: "a", count: 161), "a b"] {
      XCTAssertThrowsError(try v.writeBlob(bad, Data()), bad) { XCTAssertEqual($0 as? VaultError, .badId) }
    }
  }

  func testAFileItCannotReadIsKeptAsEvidenceOnce() throws {
    let v = vault()
    try v.writeState("x")
    let path = root.appendingPathComponent("jarvis-state-v1.aes")
    try Data("garbage-garbage-garbage-garbage-garbage".utf8).write(to: path)
    XCTAssertThrowsError(try v.readState())
    XCTAssertThrowsError(try v.readState())
    let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("unreadable-") }
    XCTAssertEqual(kept.count, 1, "one copy per distinct content")
    XCTAssertFalse(try v.listBlobs().contains { $0.hasPrefix("unreadable-") })
    try v.wipeEvidence()
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("unreadable-") }.isEmpty)
  }

  func testAKeychainFailureIsNotTakenForACorruptFile() throws {
    struct Failing: KeyProvider { func key() throws -> SymmetricKey { throw VaultError.keychain(-25308) } }
    try vault().writeState("x")
    XCTAssertThrowsError(try vault(Failing()).readState()) { XCTAssertEqual($0 as? VaultError, .keychain(-25308)) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("unreadable-") }.isEmpty)
  }

  func testEraseStateNeedsNoKey() throws {
    struct Failing: KeyProvider { func key() throws -> SymmetricKey { throw VaultError.keychain(-1) } }
    try vault().writeState("x")
    try vault(Failing()).eraseState()
    XCTAssertNil(try vault().readState())
  }

  func testTheWrongKeyDoesNotOpenIt() throws {
    try vault(FixedKey(Data(repeating: 1, count: 32))).writeState("secret")
    XCTAssertThrowsError(try vault(FixedKey(Data(repeating: 2, count: 32))).readState())
  }
}
