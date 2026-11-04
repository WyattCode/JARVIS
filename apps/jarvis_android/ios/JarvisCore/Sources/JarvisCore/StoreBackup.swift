import Foundation

/// Backup, import and the diagnostics text: the settings page's data section, on the store.
extension JarvisStore {
  /// Writes the backup to files under `temp` (see `Backup.export`) and notes the attachments that could not be read.
  public func exportBackup(temp: URL, appName: String = "jarvis-ios") throws -> BackupExport {
    let export = try Backup.export(conversations, blobs: vault, appName: appName, temp: temp)
    backupSkipped = export.skipped
    return export
  }

  /// Takes the conversations of one backup file. Nothing visible changes until the whole document has been read, so a bad
  /// file leaves what is there as it was. Returns how many were imported.
  public func importBackup(_ input: Data) async throws -> Int {
    let epoch = dataEpoch
    let endpoint = api.endpoint
    let origin = endpoint.jarvisOrigin
    // The reading (up to 128 MB of JSON and base64) and the writing of the files (each one encrypted) are off the main actor, so that
    // the page keeps moving; the conversations are put in, as before, only when everything has been read and written.
    let imported = try await Task.detached {
      try Backup.read(
        input,
        mediaAllowed: { url in
          // An old backup's picture address is kept only when it is a file of this server (or relative to it).
          guard let u = URL(string: url, relativeTo: endpoint)?.absoluteURL, ["http", "https"].contains(u.scheme ?? "")
          else { return false }
          return u.jarvisOrigin == origin
        })
    }.value
    holdBlobs(Array(imported.blobs.keys))
    defer { releaseBlobs(Array(imported.blobs.keys)) }
    let vault = self.vault
    try await Task.detached { for (id, data) in imported.blobs { try vault.writeBlob(id, data) } }.value
    // The data was cleared, or the account left, while the file was being read: what was read is not brought back.
    if epoch != dataEpoch {
      blobsDirty = true
      throw JarvisException("导入期间本机数据已被清除，未导入")
    }
    installImported(imported.conversations)
    await save()
    if persistFailed { throw JarvisException("会话已导入，但未能保存到本机；退出应用前请先导出备份") }
    return imported.conversations.count
  }

  /// What the person copies into a bug report: no conversation text, no keys.
  public func diagnostics(now: Date = Date(), platform: String = "iOS") -> String {
    let session = voice as? VoiceSession
    let object: JSONValue = .object([
      "app": .string("Jarvis \(platform)"),
      "time": .string(ISO8601DateFormatter().string(from: now)),
      "server": .string(api.endpoint.jarvisOrigin),
      "model": .string(model),
      "reasoning_effort": .string(effort),
      "authenticated": .bool(authenticated),
      "api_key_present": .bool(!settings.apiKey.isEmpty),
      "conversations": .number(Double(conversations.count)),
      "active_text_requests": .number(Double(conversations.filter { isGenerating($0.id) }.count)),
      "media_tasks": .array(
        conversations.flatMap(\.tasks).map {
          .object(["kind": .string($0.kind), "status": .string($0.status), "progress": .number($0.progress)])
        }),
      "voice": .object([
        "active": .bool(voice?.active ?? false),
        "ready": .bool(session?.ready ?? false),
        "status": .string(session?.status ?? "已结束"),
        "speech_model": .string(settings.speechModel),
        "selected_voice": settings.voices[settings.speechModel].map { .string($0) } ?? .null,
        "language": .string(settings.language),
        "mode": .string(settings.voiceMode),
        "captured_pcm_bytes": .number(Double(session?.capturedPcmBytes ?? 0)),
        "sent_pcm_bytes": .number(Double(session?.sentPcmBytes ?? 0)),
        "received_pcm_bytes": .number(Double(session?.receivedPcmBytes ?? 0)),
        "buffered_frames": .number(Double(session?.bufferedFrames ?? 0)),
        "playback_rate": .number(Double(session?.playbackRate ?? 24000)),
      ]),
      "error": error.map { .string($0) } ?? .null,
      "storage_error": storageError.map { .string($0) } ?? .null,
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }
}
