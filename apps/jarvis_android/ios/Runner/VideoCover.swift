import AVFoundation
import UIKit

/// The cover of a video: its first picture, taken from the file. A video is kept as a file of the cache on the way (the player
/// takes it from there, so it is not asked for twice), under a name made from its address.
@MainActor
enum VideoCover {
  /// Saves the video of an address into a file (the byte count); set once the person's server is known.
  static var load: ((String, URL) async throws -> Int)?
  /// The full address of a video as the server is asked for it: the cover and the player may be given the same video by a relative
  /// address or a complete one, and must find the same file.
  static var normalize: ((String) -> String)?
  private static func key(_ address: String) -> String { normalize?(address) ?? address }

  /// Videos that could not be had, and when: asked for again only after a while (every cell drawn again would start the whole round).
  private static var failedAt: [String: Date] = [:]
  /// Moves on when the local data is cleared: a fetch begun before that does not put its file or cover back afterwards.
  private static var generation = 0
  private static let failedFor: TimeInterval = 30

  private static let covers = NSCache<NSString, UIImage>()
  private static var inflight: [String: Task<URL?, Never>] = [:]

  /// A video not looked at for this long, or the oldest ones past this much together, are removed by [sweep].
  nonisolated private static let keepDays = 7.0
  nonisolated private static let keepBytes = 500 * 1024 * 1024

  nonisolated static var directory: URL {
    LocalData.cacheRoot.appendingPathComponent("jarvis-video", isDirectory: true)
  }

  nonisolated static func file(for address: String) -> URL {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in address.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return directory.appendingPathComponent("\(String(hash, radix: 16)).mp4")
  }

  /// The video's file, fetched first if it is not in the cache yet (nil: it could not be had, or it is not a video that plays — a
  /// half-written file is not kept, so the next ask fetches it again).
  static func saved(_ address: String) async -> URL? {
    let address = key(address)
    let file = file(for: address)
    if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
      return file
    }
    if let running = inflight[address] { return await running.value }
    guard let load else { return nil }
    let started = generation
    let task = Task { () -> URL? in
      guard let size = try? await load(address, file), size > 0 else { return nil }
      if started != generation {
        try? FileManager.default.removeItem(at: file)
        return nil
      }
      guard (try? await AVURLAsset(url: file).load(.isPlayable)) == true else {
        try? FileManager.default.removeItem(at: file)
        return nil
      }
      return file
    }
    inflight[address] = task
    let result = await task.value
    // Only the one that is finished is cleared (a later one for the same address may be running by now).
    if inflight[address] == task { inflight[address] = nil }
    return result
  }

  /// Forgets the covers kept in memory (the files are removed with the other local data).
  static func forget() {
    generation += 1
    // (a fetch begun before is not joined by one asked for afterwards: it gives nothing now)
    inflight = [:]
    covers.removeAllObjects()
    failedAt = [:]
  }

  /// The cover when it is already in memory (a card drawn again, as the chat does when the page is come back to, takes it at once
  /// instead of showing its plain colour for the moment an asked-for cover takes).
  static func cached(_ address: String) -> UIImage? { covers.object(forKey: key(address) as NSString) }

  /// The first picture of the video, asked for again a few times when it is not there yet (a video that has only just been finished
  /// may not be served for the first moment).
  static func cover(_ address: String, tries: Int = 4) async -> UIImage? {
    let address = key(address)
    if let known = covers.object(forKey: address as NSString) { return known }
    if let failed = failedAt[address], Date().timeIntervalSince(failed) < failedFor { return nil }
    for attempt in 0..<tries {
      if let file = await saved(address) {
        if let image = await frame(of: file), FileManager.default.fileExists(atPath: file.path) {
          covers.setObject(image, forKey: address as NSString)
          return image
        }
        // No picture from it: asked again below. The file is not removed here (a player may be given it at the same moment); one
        // that does not play was removed when it was fetched.
      }
      if attempt < tries - 1 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
      if Task.isCancelled { return nil }
    }
    failedAt[address] = Date()
    return nil
  }

  /// Removes the videos nobody has looked at for a week, then the oldest until what is left is under the limit; also the files of the
  /// earlier versions, which were kept in the temporary folder. Run at launch.
  nonisolated static func sweep() {
    let manager = FileManager.default
    if let old = try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: nil) {
      for url in old where url.lastPathComponent.hasPrefix("jarvis-video-") { try? manager.removeItem(at: url) }
    }
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
    let cutoff = Date().addingTimeInterval(-keepDays * 86_400)
    var kept: [(url: URL, date: Date, size: Int)] = []
    for url in urls {
      let values = try? url.resourceValues(forKeys: Set(keys))
      let date = values?.contentModificationDate ?? .distantPast
      if date < cutoff || url.pathExtension != "mp4" { try? manager.removeItem(at: url); continue }
      kept.append((url, date, values?.fileSize ?? 0))
    }
    var total = kept.reduce(0) { $0 + $1.size }
    for item in kept.sorted(by: { $0.date < $1.date }) where total > keepBytes {
      try? manager.removeItem(at: item.url)
      total -= item.size
    }
  }

  private static func frame(of file: URL) async -> UIImage? {
    await Task.detached(priority: .userInitiated) { () -> UIImage? in
      let asset = AVURLAsset(url: file)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 1280, height: 1280)
      // A little way in, so that a fade-in from black is not the cover; a very short clip gives its first picture.
      let length = (try? await asset.load(.duration).seconds) ?? 0
      let at = CMTime(seconds: length > 1.5 ? 0.5 : 0, preferredTimescale: 600)
      guard let picture = try? await generator.image(at: at).image else { return nil }
      return UIImage(cgImage: picture)
    }.value
  }
}
