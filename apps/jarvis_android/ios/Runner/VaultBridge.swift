import CryptoKit
import Flutter
import Foundation
import os
import Security

/// iOS counterpart of PrivateVault.kt. Same on-disk layout (version byte 1 + 12-byte nonce + ciphertext + tag),
/// with the AES-256 key kept in the Keychain instead of Android Keystore.
final class VaultBridge {
  private enum VaultError: Error {
    case keychain(OSStatus)
    case badId
    case corrupt
    case badArguments
  }

  private let queue = DispatchQueue(label: "ai.jarvis.app.vault")
  private let log = Logger(subsystem: "ai.jarvis.app", category: "vault")
  private let service = "ai.jarvis.app"
  private let account = "jarvis-private-state-v1"

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ai.jarvis.app/vault", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      guard ["read", "write", "readBlob", "writeBlob", "deleteBlob", "listBlobs", "keepUnreadable", "wipeEvidence", "eraseState"].contains(call.method) else {
        return result(FlutterMethodNotImplemented)
      }
      self.queue.async {
        let reply: Any?
        do {
          reply = try self.run(call)
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "vault_failed", message: "无法访问本机加密资料，原资料已保留", details: nil))
          }
          return
        }
        DispatchQueue.main.async { result(reply) }
      }
    }
  }

  private func run(_ call: FlutterMethodCall) throws -> Any? {
    switch call.method {
    case "read":
      guard let plain = try read(statePath()) else { return nil }
      return String(data: plain, encoding: .utf8)
    case "write":
      guard let text = call.arguments as? String else { throw VaultError.badArguments }
      try write(statePath(), Data(text.utf8))
      return nil
    case "readBlob":
      guard let id = call.arguments as? String else { throw VaultError.badArguments }
      guard let plain = try read(blobPath(id)) else { return nil }
      return FlutterStandardTypedData(bytes: plain)
    case "deleteBlob":
      guard let id = call.arguments as? String else { throw VaultError.badArguments }
      let path = try blobPath(id)
      if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
      return nil
    case "listBlobs":
      let dir = try root().appendingPathComponent("attachments", isDirectory: true)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
      // `unreadable-*` files are evidence kept by `preserve`, not attachments.
      return names.filter { $0.hasSuffix(".aes") && !$0.hasPrefix("unreadable-") }.map { String($0.dropLast(4)) }
    case "keepUnreadable":
      let path = try statePath()
      if FileManager.default.fileExists(atPath: path.path) { preserve(path, try Data(contentsOf: path)) }
      return nil
    case "wipeEvidence":
      // Sign-out-and-erase: the copies `preserve` set aside hold the old conversations too.
      let base = try root()
      for dir in [base, base.appendingPathComponent("attachments", isDirectory: true)] {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("unreadable-") {
          try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
      }
      return nil
    case "eraseState":
      // Sign-out-and-erase whose last write failed (a Keychain error, say): deleting needs no key.
      let path = try statePath()
      if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
      return nil
    default:
      guard let args = call.arguments as? [String: Any],
        let id = args["id"] as? String,
        let bytes = args["bytes"] as? FlutterStandardTypedData
      else { throw VaultError.badArguments }
      try write(blobPath(id), bytes.data)
      return nil
    }
  }

  private func key() throws -> SymmetricKey {
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var found: CFTypeRef?
    let status = SecItemCopyMatching(match as CFDictionary, &found)
    if status == errSecSuccess, let raw = found as? Data { return SymmetricKey(data: raw) }
    log.error("keychain lookup status=\(status, privacy: .public)")
    // Never mint a replacement key for any failure other than "no key yet": that would orphan existing data.
    guard status == errSecItemNotFound else { throw VaultError.keychain(status) }
    let fresh = SymmetricKey(size: .bits256)
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: fresh.withUnsafeBytes { Data($0) },
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else { throw VaultError.keychain(added) }
    return fresh
  }

  private func root() throws -> URL {
    var dir = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Jarvis", isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true  // parity with Android noBackupFilesDir
      try dir.setResourceValues(values)
    }
    return dir
  }

  private func statePath() throws -> URL {
    try root().appendingPathComponent("jarvis-state-v1.aes")
  }

  private func blobPath(_ id: String) throws -> URL {
    guard id.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil else { throw VaultError.badId }
    let dir = try root().appendingPathComponent("attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("\(id).aes")
  }

  private func read(_ path: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let bytes = try Data(contentsOf: path)
    // A Keychain failure (before first unlock, interaction not allowed) says nothing about the file: don't copy for it.
    let symmetricKey = try key()
    do {
      guard bytes.count >= 29, bytes[bytes.startIndex] == 1 else { throw VaultError.corrupt }
      let box = try AES.GCM.SealedBox(combined: Data(bytes.dropFirst()))
      return try AES.GCM.open(box, using: symmetricKey)
    } catch {
      log.error("decrypt failed: \(String(describing: error), privacy: .public) size=\(bytes.count, privacy: .public)")
      preserve(path, bytes)
      throw error
    }
  }

  /// Keeps the original encrypted bytes even if a later user action saves new state; at most one copy per distinct content.
  private func preserve(_ path: URL, _ bytes: Data) {
    let dir = path.deletingLastPathComponent()
    let suffix = "-\(path.lastPathComponent)"
    let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    for name in existing where name.hasPrefix("unreadable-") && name.hasSuffix(suffix) {
      if let old = try? Data(contentsOf: dir.appendingPathComponent(name)), old == bytes { return }
    }
    let keep = dir.appendingPathComponent("unreadable-\(Int(Date().timeIntervalSince1970 * 1000))\(suffix)")
    try? bytes.write(to: keep, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  private func write(_ path: URL, _ plain: Data) throws {
    let sealed = try AES.GCM.seal(plain, using: try key())
    guard let combined = sealed.combined else { throw VaultError.corrupt }
    var out = Data([1])
    out.append(combined)
    try out.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}
