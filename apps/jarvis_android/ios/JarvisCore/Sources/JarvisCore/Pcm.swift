import Foundation

/// A try-out clip: 16-bit mono PCM and its sample rate.
public struct PcmClip: Equatable, Sendable {
  public let bytes: Data
  public let rate: Int

  public init(bytes: Data, rate: Int) {
    self.bytes = bytes
    self.rate = rate
  }

  public struct Invalid: Error, Equatable { public let message: String }

  /// Reads a WAV file: PCM, 16 bit, one channel, 8 to 192 kHz.
  public static func wav(_ data: Data) throws -> PcmClip {
    let d = [UInt8](data)
    func tag(_ at: Int) -> String { String(decoding: d[at..<at + 4], as: UTF8.self) }
    func u16(_ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    if d.count < 44 || tag(0) != "RIFF" || tag(8) != "WAVE" { throw Invalid(message: "试听不是WAV音频") }
    var rate = 0
    var channels = 0
    var bits = 0
    var format = 0
    var pcm: Data?
    var at = 12
    while at + 8 <= d.count {
      let size = u32(at + 4)
      let start = at + 8
      if start + size > d.count { throw Invalid(message: "音频不完整") }
      if tag(at) == "fmt ", size >= 16 {
        format = u16(start)
        channels = u16(start + 2)
        rate = u32(start + 4)
        bits = u16(start + 14)
      }
      if tag(at) == "data" { pcm = Data(d[start..<start + size]) }
      at = start + size + (size % 2)
    }
    guard format == 1, channels == 1, bits == 16, rate >= 8000, rate <= 192_000, let pcm, !pcm.isEmpty, pcm.count % 2 == 0 else {
      throw Invalid(message: "试听需为16位单声道PCM音频")
    }
    return PcmClip(bytes: pcm, rate: rate)
  }
}

/// RMS of little-endian signed 16-bit mono PCM.
public func pcmRms(_ bytes: Data) -> Double {
  let samples = bytes.count / 2
  if samples == 0 { return 0 }
  var sum = 0.0
  bytes.withUnsafeBytes { raw in
    for i in 0..<samples {
      let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
      let s = Double(value) / 32768
      sum += s * s
    }
  }
  return (sum / Double(samples)).squareRoot()
}

/// Normalized RMS levels; output comes from the hardware playback cursor.
public struct AudioLevels: Equatable, Sendable {
  public var input = 0.0
  public var output = 0.0
  public var playing = false
  public init(input: Double = 0, output: Double = 0, playing: Bool = false) {
    self.input = input
    self.output = output
    self.playing = playing
  }
}
