import 'dart:math' as math;
import 'dart:typed_data';

class PcmClip {
  const PcmClip(this.bytes, this.rate);
  final Uint8List bytes;
  final int rate;
  factory PcmClip.wav(Uint8List data) {
    final v = ByteData.sublistView(data);
    String tag(int at) => String.fromCharCodes(data.sublist(at, at + 4));
    if (data.length < 44 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const FormatException('试听不是WAV音频');
    }
    var rate = 0, channels = 0, bits = 0, format = 0;
    Uint8List? pcm;
    for (var at = 12; at + 8 <= data.length;) {
      final size = v.getUint32(at + 4, Endian.little), start = at + 8;
      if (start + size > data.length) throw const FormatException('音频不完整');
      if (tag(at) == 'fmt ' && size >= 16) {
        format = v.getUint16(start, Endian.little);
        channels = v.getUint16(start + 2, Endian.little);
        rate = v.getUint32(start + 4, Endian.little);
        bits = v.getUint16(start + 14, Endian.little);
      }
      if (tag(at) == 'data') {
        pcm = Uint8List.fromList(data.sublist(start, start + size));
      }
      at = start + size + (size % 2);
    }
    if (format != 1 ||
        channels != 1 ||
        bits != 16 ||
        rate < 8000 ||
        rate > 192000 ||
        pcm == null ||
        pcm.isEmpty ||
        pcm.length.isOdd) {
      throw const FormatException('试听需为16位单声道PCM音频');
    }
    return PcmClip(pcm, rate);
  }
}

/// RMS of little-endian signed 16-bit mono PCM, without copying the buffer.
double pcmRms(Uint8List bytes) {
  final samples = bytes.length ~/ 2;
  if (samples == 0) return 0;
  final view = ByteData.sublistView(bytes);
  var sum = 0.0;
  for (var i = 0; i < samples; i++) {
    final sample = view.getInt16(i * 2, Endian.little) / 32768;
    sum += sample * sample;
  }
  return math.sqrt(sum / samples);
}
