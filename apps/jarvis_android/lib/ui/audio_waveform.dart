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
    motion.level += (target(audio) - motion.level) * .22;
    if (motion.level < .001) motion.level = 0;
    motion.time = elapsed.inMicroseconds / 1000000;
    motion.playing = audio.playing;
    motion.changed();
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

class _WavePainter extends CustomPainter {
  _WavePainter(this.motion, this.colors, this.reduced) : super(repaint: motion);
  final _WaveMotion motion;
  final ColorScheme colors;
  final bool reduced;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final count = size.width >= 440
        ? (size.width / 5.5).round().clamp(44, 128)
        : size.width >= 220
        ? 44
        : size.width >= 140
        ? 32
        : 24;
    final pitch = size.width / count;
    final width = math.min(2.5, pitch * .48);
    final base = motion.playing ? colors.onSurface : const Color(0xff8fdceb);
    final color = Color.lerp(
      colors.onSurfaceVariant,
      base,
      (motion.level * 4).clamp(0.0, 1.0),
    )!;
    final paint = Paint()
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final x = i / (count - 1);
      final envelope = math.pow(math.sin(math.pi * x), 1.6).toDouble();
      final ripple = .55 + .45 * (math.sin(i * 1.7) * math.cos(i * .6)).abs();
      final wobble = reduced || motion.level == 0
          ? 1.0
          : .45 + .55 * math.sin(i * .45 + motion.time * 7).abs();
      final height =
          math.max(
            .06,
            envelope * ripple * (.12 + motion.level * .88) * wobble,
          ) *
          math.max(0, size.height - width);
      paint.color = color.withValues(alpha: .35 + .6 * envelope);
      final at = (i + .5) * pitch;
      canvas.drawLine(
        Offset(at, (size.height - height) / 2),
        Offset(at, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.motion != motion || old.colors != colors || old.reduced != reduced;
}
