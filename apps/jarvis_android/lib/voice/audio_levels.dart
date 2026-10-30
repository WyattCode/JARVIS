/// Normalized RMS levels; output comes from the native hardware playback cursor.
class AudioLevels {
  const AudioLevels({this.input = 0, this.output = 0, this.playing = false});
  final double input, output;
  final bool playing;
}
