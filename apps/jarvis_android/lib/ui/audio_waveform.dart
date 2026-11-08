import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../voice/audio_levels.dart';

/// The Web voice view's tapered round bars, driven by real duplex PCM levels.
/// Meter ticks repaint this boundary only; they never rebuild the conversation.
class AudioWaveform extends StatefulWidget {
  const AudioWaveform({super.key, required this.levels});
  final ValueListenable<AudioLevels> levels;
  @override
  State<AudioWaveform> createState() => _AudioWaveformState();
}

class _WaveMotion extends ChangeNotifier {
  double level = 0, time = 0;
  bool playing = false;
  void changed() => notifyListeners();
}

class _AudioWaveformState extends State<AudioWaveform>
    with SingleTickerProviderStateMixin {
  final motion = _WaveMotion();
  late final Ticker ticker;
  Duration last = Duration.zero;
  bool reduced = false;
  @override
  void initState() {
    super.initState();
    ticker = createTicker(frame);
    widget.levels.addListener(levelChanged);
  }

  void levelChanged() {
    if (reduced) {
      final audio = widget.levels.value;
      motion.level = target(audio);
      motion.playing = audio.playing;
      motion.changed();
    }
  }

  double target(AudioLevels audio) =>
      ((audio.playing ? audio.output * 9 : audio.input * 14)).clamp(0.0, 1.0);
  void frame(Duration elapsed) {
    if (elapsed - last < const Duration(milliseconds: 33)) return;
    last = elapsed;
    final audio = widget.levels.value;
    final before = motion.level;
    motion.level += (target(audio) - motion.level) * .22;
    if (motion.level < .001) motion.level = 0;
    motion.time = elapsed.inMicroseconds / 1000000;
    motion.playing = audio.playing;
    // At rest the bars are still dots: nothing to draw again (as on iOS).
    if (before != 0 || motion.level != 0) motion.changed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      ticker.stop();
      motion.time = 0;
      levelChanged();
    } else if (!ticker.isActive) {
      last = Duration.zero;
      ticker.start();
    }
  }

  @override
  void didUpdateWidget(AudioWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.levels != widget.levels) {
      oldWidget.levels.removeListener(levelChanged);
      widget.levels.addListener(levelChanged);
      levelChanged();
    }
  }

  @override
  void dispose() {
    widget.levels.removeListener(levelChanged);
    ticker.dispose();
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: CustomPaint(
        key: const Key('voice-waveform'),
        painter: _WavePainter(motion, Theme.of(context).colorScheme, reduced),
        size: Size.infinite,
      ),
    ),
  );
}

/// The level bars of the call, as the iOS app draws them: 64 tapered bars,
/// small dots at rest, rising and falling with the sound that is being played
/// or heard, with a ripple that travels along them while there is sound.
class _WavePainter extends CustomPainter {
  _WavePainter(this.motion, this.colors, this.reduced) : super(repaint: motion);
  final _WaveMotion motion;
  final ColorScheme colors;
  final bool reduced;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const count = 64;
    final step = size.width / count;
    final time = reduced ? 0.0 : motion.time;
    final level = motion.level;
    final paint = Paint()
      ..color = colors.onSurfaceVariant.withValues(alpha: level > 0 ? .9 : .45);
    final w = math.max(1.5, step * .5);
    for (var i = 0; i < count; i++) {
      final x = (i + .5) * step;
      final t = i / (count - 1);
      // Tapered at both ends; a travelling ripple while there is sound.
      final envelope = math.sin(t * math.pi);
      final ripple = .5 + .5 * math.sin(i * .55 + time * 6);
      final height = math.max(
        2.0,
        size.height * envelope * level * (.35 + .65 * ripple),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x - w / 2, size.height / 2 - height / 2, w, height),
          Radius.circular(w / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.motion != motion || old.colors != colors || old.reduced != reduced;
}
