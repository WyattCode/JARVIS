import CryptoKit
import Foundation
import Security

public enum VaultError: Error, Equatable {
  case keychain(Int32)
  case badId
  case corrupt
}

/// Where the AES key comes from. The app's is the Keychain; tests bring their own.
public protocol KeyProvider: Sendable {
  func key() throws -> SymmetricKey
}

public struct FixedKey: KeyProvider {
  let bytes: Data
  public init(_ bytes: Data = Data(repeating: 7, count: 32)) { self.bytes = bytes }
  public func key() throws -> SymmetricKey { SymmetricKey(data: bytes) }
}

/// The AES-256 key in the Keychain, made on first use. Same service and account the Flutter app's vault used, so what it
/// saved is still readable.
public struct KeychainKey: KeyProvider {
  let service: String
  let account: String
  public init(service: String = "ai.jarvis.app", account: String = "jarvis-private-state-v1") {
    self.service = service
    self.account = account
  }

  public func key() throws -> SymmetricKey {
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var found: CFTypeRef?
    let status = SecItemCopyMatching(match as CFDictionary, &found)
    if status == errSecSuccess, let raw = found as? Data { return SymmetricKey(data: raw) }
    // Never mint a replacement key for any failure other than "no key yet": that would orphan existing data.
    guard status == errSecItemNotFound else { throw VaultError.keychain(status) }
    let fresh = SymmetricKey(size: .bits256)
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecValueData as String: fresh.withUnsafeBytes { Data($0) },
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else { throw VaultError.keychain(added) }
    return fresh
  }
}

/// What the app saves: one state file and any number of attachments.
public protocol Vault: Sendable {
  func readState() throws -> String?
  func writeState(_ value: String) throws
  func readBlob(_ id: String) throws -> Data?
  func writeBlob(_ id: String, _ bytes: Data) throws
  func deleteBlob(_ id: String) throws
  func listBlobs() throws -> [String]
  /// Sets aside the saved file it failed to read, before that file is replaced.
  func keepUnreadable() throws
  /// Deletes the copies `keepUnreadable` set aside.
  func wipeEvidence() throws
  /// Deletes the saved file itself: an erase whose last write failed must not leave the old one behind.
  func eraseState() throws
}

/// AES-GCM at rest, in files under `root`. Layout: a version byte (1), the 12-byte nonce, the ciphertext and the tag; the
/// same bytes the Flutter app's vault wrote.
public final class FileVault: Vault, @unchecked Sendable {
  private let root: URL
  private let keys: KeyProvider
  private let lock = NSLock()

  /// `root` is made if it is not there; `excludedFromBackup` keeps it out of iCloud and device backups.
  public init(root: URL, keys: KeyProvider = KeychainKey(), excludedFromBackup: Bool = true) {
    self.root = root
    self.keys = keys
    excluded = excludedFromBackup
  }

  private let excluded: Bool

  /// The folder the app keeps its state in.
  public static func applicationSupport() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("Jarvis", isDirectory: true)
  }

  private func folder() throws -> URL {
    var dir = root
    if !FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      if excluded {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
      }
    }
    return dir
  }

  private func statePath() throws -> URL { try folder().appendingPathComponent("jarvis-state-v1.aes") }

  private func attachments() throws -> URL {
    let dir = try folder().appendingPathComponent("attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func blobPath(_ id: String) throws -> URL {
    guard id.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil else { throw VaultError.badId }
    return try attachments().appendingPathComponent("\(id).aes")
  }

  private func read(_ path: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let bytes = try Data(contentsOf: path)
    // A Keychain failure (before first unlock, interaction not allowed) says nothing about the file: don't copy for it.
    let key = try keys.key()
    do {
      guard bytes.count >= 29, bytes[bytes.startIndex] == 1 else { throw VaultError.corrupt }
      let box = try AES.GCM.SealedBox(combined: Data(bytes.dropFirst()))
      return try AES.GCM.open(box, using: key)
    } catch {
      preserve(path, bytes)
      throw error
    }
  }

  /// Keeps the original encrypted bytes even if a later user action saves new state; at most one copy per distinct content.
  private func preserve(_ path: URL, _ bytes: Data) {
    let dir = path.deletingLastPathComponent()
    let suffix = "-\(path.lastPathComponent)"
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    where name.hasPrefix("unreadable-") && name.hasSuffix(suffix) {
      if let old = try? Data(contentsOf: dir.appendingPathComponent(name)), old == bytes { return }
    }
    let keep = dir.appendingPathComponent("unreadable-\(Int(Date().timeIntervalSince1970 * 1000))\(suffix)")
    try? bytes.write(to: keep, options: Self.writeOptions)
  }

  private func write(_ path: URL, _ plain: Data) throws {
    let sealed = try AES.GCM.seal(plain, using: try keys.key())
    guard let combined = sealed.combined else { throw VaultError.corrupt }
    var out = Data([1])
    out.append(combined)
    try out.write(to: path, options: Self.writeOptions)
  }

  #if os(iOS)
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
  #else
    static let writeOptions: Data.WritingOptions = [.atomic]
  #endif

  public func readState() throws -> String? {
    lock.lock(); defer { lock.unlock() }
    return try read(statePath()).flatMap { String(data: $0, encoding: .utf8) }
  }

  public func writeState(_ value: String) throws {
    lock.lock(); defer { lock.unlock() }
    try write(statePath(), Data(value.utf8))
  }

  public func readBlob(_ id: String) throws -> Data? {
    lock.lock(); defer { lock.unlock() }
    return try read(blobPath(id))
  }

  public func writeBlob(_ id: String, _ bytes: Data) throws {
    lock.lock(); defer { lock.unlock() }
    try write(blobPath(id), bytes)
  }

  public func deleteBlob(_ id: String) throws {
    lock.lock(); defer { lock.unlock() }
    let path = try blobPath(id)
    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
  }

  public func listBlobs() throws -> [String] {
    lock.lock(); defer { lock.unlock() }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: try attachments().path)) ?? []
    // `unreadable-*` files are evidence kept by `preserve`, not attachments.
    return names.filter { $0.hasSuffix(".aes") && !$0.hasPrefix("unreadable-") }.map { String($0.dropLast(4)) }
  }

  public func keepUnreadable() throws {
    lock.lock(); defer { lock.unlock() }
    let path = try statePath()
    if FileManager.default.fileExists(atPath: path.path) { preserve(path, try Data(contentsOf: path)) }
  }

  public func wipeEvidence() throws {
    lock.lock(); defer { lock.unlock() }
    let base = try folder()
    for dir in [base, base.appendingPathComponent("attachments", isDirectory: true)] {
      for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("unreadable-") {
        try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
      }
    }
  }

  public func eraseState() throws {
    lock.lock(); defer { lock.unlock() }
    let path = try statePath()
    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
  }
}

/// Nothing on disk: for tests and for previews.
public final class MemoryVault: Vault, @unchecked Sendable {
  private let lock = NSLock()
  private var state: String?
  private var blobs: [String: Data] = [:]
  public init(state: String? = nil) { self.state = state }

  public func readState() throws -> String? { lock.lock(); defer { lock.unlock() }; return state }
  public func writeState(_ value: String) throws { lock.lock(); state = value; lock.unlock() }
  public func readBlob(_ id: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return blobs[id] }
  public func writeBlob(_ id: String, _ bytes: Data) throws { lock.lock(); blobs[id] = bytes; lock.unlock() }
  public func deleteBlob(_ id: String) throws { lock.lock(); blobs[id] = nil; lock.unlock() }
  public func listBlobs() throws -> [String] { lock.lock(); defer { lock.unlock() }; return Array(blobs.keys) }
  public func keepUnreadable() throws {}
  public func wipeEvidence() throws {}
  public func eraseState() throws { lock.lock(); state = nil; lock.unlock() }
}
