import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The light of the call, as a wave of light along one edge of the screen: the
/// crest of it rises and falls with the sound, and the sound that has just been
/// made is what shapes it (the newest in the middle, spreading out to both
/// sides as it ages), so it moves like a voice does. JARVIS's own (the
/// reactor's cyan) hangs from the top edge while it speaks; yours (pale silver)
/// rises from the bottom edge while you do; at rest a faint, slow swell at the
/// foot.
///
/// It is not boxed: it runs past both sides of the screen, and every layer
/// fades to nothing before it reaches the far side of its own reach, so no edge
/// of a rectangle is ever seen.
class CallWaveGlow extends StatefulWidget {
  const CallWaveGlow({
    super.key,
    required this.fromTop,
    required this.color,
    required this.intensity,
    required this.level,
    this.reach = .34,
  });

  /// Hangs from the top edge (JARVIS's voice); otherwise rises from the bottom
  /// edge (yours).
  final bool fromTop;
  final Color color;

  /// How bright the light is, 0 to 1 (it comes and goes over a third of a
  /// second).
  final double intensity;

  /// The sound that shapes it, 0 to 1.
  final double level;

  /// The most the crest rises, as a share of the screen's height.
  final double reach;

  @override
  State<CallWaveGlow> createState() => _CallWaveGlowState();
}

class _WaveClock extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _CallWaveGlowState extends State<CallWaveGlow>
    with SingleTickerProviderStateMixin {
  /// 64 looks at 30 a second is a little over two seconds of sound.
  static const memory = 64;
  final history = List<double>.filled(memory, 0);
  final clock = _WaveClock();
  late final Ticker ticker = createTicker(frame);
  Duration last = Duration.zero,
      lastLook = Duration.zero,
      lastPaint = Duration.zero;
  double level = 0, time = 0;
  bool still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    still = MediaQuery.disableAnimationsOf(context);
    if (still) {
      ticker.stop();
      level = widget.level;
      history.fillRange(0, memory, widget.level);
      clock.tick();
    } else {
      _wake();
    }
  }

  @override
  void didUpdateWidget(CallWaveGlow old) {
    super.didUpdateWidget(old);
    if (still) {
      // With motion turned off the light shows the sound as it is, without
      // travelling.
      level = widget.level;
      history.fillRange(0, memory, widget.level);
      clock.tick();
    } else if (widget.level > 0) {
      _wake();
    }
  }

  /// The light moves only while there is sound to move it: at rest it is a
  /// still, faint swell (nothing keeps the screen drawing).
  void _wake() {
    if (ticker.isActive) return;
    last = lastLook = lastPaint = Duration.zero;
    ticker.start();
  }

  @override
  void dispose() {
    ticker.dispose();
    clock.dispose();
    super.dispose();
  }

  void frame(Duration elapsed) {
    final dt = (elapsed - last).inMicroseconds / 1e6;
    last = elapsed;
    if (still) return;
    time += dt.clamp(0.0, .1);
    // The level rises quickly and falls slowly, as a meter does.
    final target = widget.level.clamp(0.0, 1.0);
    level += (target - level) * (target > level ? .35 : .12);
    if (level < .001) level = 0;
    // A look at the sound 30 times a second: the newest goes to the front and
    // the rest move back.
    if ((elapsed - lastLook).inMicroseconds >= 33000) {
      lastLook = elapsed;
      for (var i = memory - 1; i > 0; i--) {
        history[i] = history[i - 1];
      }
      history[0] = level;
    }
    // About 30 paints a second is all a soft light needs.
    if ((elapsed - lastPaint).inMicroseconds >= 30000) {
      lastPaint = elapsed;
      clock.tick();
    }
    // The sound has died away and nothing is still travelling: rest.
    if (widget.level <= 0 && level <= 0 && !history.any((v) => v > .002)) {
      ticker.stop();
      clock.tick();
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(
            end: widget.color.withValues(
              alpha: widget.intensity.clamp(0.0, 1.0),
            ),
          ),
          duration: still ? Duration.zero : const Duration(milliseconds: 350),
          builder: (context, c, _) => RepaintBoundary(
            child: CustomPaint(
              size: Size.infinite,
              painter: _WavePainter(
                clock,
                this,
                c ?? widget.color.withValues(alpha: 0),
                widget.fromTop,
                widget.reach,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.clock, this.state, this.color, this.fromTop, this.reach)
    : super(repaint: clock);
  final _WaveClock clock;
  final _CallWaveGlowState state;
  final Color color;
  final bool fromTop;
  final double reach;

  /// One layer of the light: how far it rises, how fast its swell travels, how
  /// wide the swell is, and how bright it is.
  static const layers = [
    (rise: 1.0, speed: 1.1, span: .0105, bright: .55, phase: 0.0),
    (rise: .72, speed: -1.6, span: .0162, bright: .38, phase: 1.9),
    (rise: .5, speed: 2.1, span: .0245, bright: .26, phase: 4.1),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final base = color.a;
    if (base < .004 || size.isEmpty) return;
    final w = size.width, h = size.height;
    final edge = fromTop ? 0.0 : h;
    final dir = fromTop ? 1.0 : -1.0;
    final maxRise = h * reach;
    final history = state.history;
    final t = state.time;
    // Past both sides of the screen: no end of the light is seen.
    final from = -w * .15, to = w * 1.15;
    const step = 7.0;
    for (final layer in layers) {
      final path = Path()..moveTo(from, edge);
      final ridge = Path();
      var first = true;
      for (var x = from; x <= to + step; x += step) {
        // How long ago the sound was that shapes this place: the middle is the
        // newest, the sides the oldest.
        final away = ((x - w / 2).abs() / (w / 2)).clamp(0.0, 1.3);
        final at = away * (history.length - 1) / 1.3;
        final i = at.floor().clamp(0, history.length - 2);
        final env = history[i] + (history[i + 1] - history[i]) * (at - i);
        // The swell that runs along the light, two of them against each other.
        final swell =
            .5 +
            .5 *
                math.sin(x * layer.span + t * layer.speed + layer.phase) *
                (.65 + .35 * math.sin(x * layer.span * .43 - t * .7));
        // At rest a slow low swell; with sound the crest stands up in it.
        final rest = .06 + .035 * math.sin(t * .8 + x * .004 + layer.phase);
        final lift = (rest + (1 - rest) * env * (.45 + .55 * swell)).clamp(
          0.0,
          1.0,
        );
        final y = edge + dir * maxRise * layer.rise * lift;
        path.lineTo(x, y);
        if (first) {
          ridge.moveTo(x, y);
          first = false;
        } else {
          ridge.lineTo(x, y);
        }
      }
      path
        ..lineTo(to + step, edge)
        ..close();
      final bright = base * layer.bright;
      final top = edge + dir * maxRise * layer.rise;
      // Strongest at the edge, gone before the crest: the shape is felt in how
      // far the light reaches, not in a line it is cut along.
      final fill = Paint()
        ..shader = LinearGradient(
          begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
          end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [
            color.withValues(alpha: bright),
            color.withValues(alpha: bright * .45),
            color.withValues(alpha: 0),
          ],
          stops: const [0, .45, 1],
        ).createShader(Rect.fromPoints(Offset(0, edge), Offset(w, top)))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
      canvas.drawPath(path, fill);
      // A thin bright ridge where the crest is, so the wave can be read.
      canvas.drawPath(
        ridge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeJoin = StrokeJoin.round
          ..color = color.withValues(alpha: bright * .9)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.color != color || old.fromTop != fromTop || old.reach != reach;
}
