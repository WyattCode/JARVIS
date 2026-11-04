import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The app emblem is deliberately simpler than the in-app living core.
class JarvisMark extends StatelessWidget {
  const JarvisMark({super.key, this.size = 32, this.tile = false});
  final double size;
  final bool tile;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Jarvis',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: ColoredBox(
          color: tile ? Colors.black : Colors.transparent,
          child: Padding(
            padding: EdgeInsets.all(tile ? size * .11 : 0),
            child: Image.asset(
              'assets/jarvis-icon-night.png',
              excludeFromSemantics: true,
              filterQuality: FilterQuality.high,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                  .ceil()
                  .clamp(1, 512),
            ),
          ),
        ),
      ),
    );
  }
}

/// A page-specific wordmark emblem, drawn directly on the login background.
/// Uses the B1 winding geometry without launcher padding or a black tile.
class LoginBrandMark extends StatelessWidget {
  const LoginBrandMark({super.key});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: 28,
      child: CustomPaint(
        painter: _LoginBrandPainter(
          Theme.of(context).brightness == Brightness.dark,
        ),
      ),
    ),
  );
}

class _LoginBrandPainter extends CustomPainter {
  const _LoginBrandPainter(this.dark);
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(size.shortestSide / 28);
    final structure = dark ? const Color(0xffb1cbd7) : const Color(0xff3b6b7c);
    final energy = dark ? const Color(0xff8fdceb) : const Color(0xff16849b);
    Paint stroke(Color color, double width) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    Offset point(double angle, double radius) =>
        Offset(math.cos(angle) * radius, math.sin(angle) * radius);
    canvas.drawCircle(Offset.zero, 11.8, stroke(structure, .9));
    canvas.drawCircle(
      Offset.zero,
      8.1,
      stroke(structure.withValues(alpha: .85), .85),
    );
    for (var i = 0; i < 10; i++) {
      final a = -math.pi / 2 + i * math.pi / 5;
      final tangent = Offset(-math.sin(a), math.cos(a));
      for (final offset in [-.62, .62]) {
        canvas.drawLine(
          point(a, 9.2) + tangent * offset,
          point(a, 10.7) + tangent * offset,
          stroke(structure, .68),
        );
      }
    }
    for (var i = 0; i < 3; i++) {
      final a = -math.pi / 2 + i * math.pi * 2 / 3;
      canvas.drawLine(point(a, 4.7), point(a, 6.7), stroke(structure, .9));
    }
    canvas.drawCircle(Offset.zero, 3.6, stroke(energy, 1.25));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LoginBrandPainter oldDelegate) =>
      oldDelegate.dark != dark;
}

/// Shared reactor identity: launcher geometry becomes a layered living machine.
enum ReactorMode { idle, listening, thinking, speaking }

/// A launch begins at the native artwork's pose, then varies its flow and pace.
/// Ordinary scenes retain a fully random phase and energy signature.
class ReactorProfile {
  const ReactorProfile({
    required this.phase,
    required this.signature,
    required this.direction,
    required this.seconds,
  });
  final double phase, signature, direction;
  final int seconds;
  factory ReactorProfile.random({bool startup = false}) {
    final random = math.Random();
    return ReactorProfile(
      phase: startup ? 0 : random.nextDouble(),
      signature: startup ? 0 : random.nextDouble() * math.pi * 2,
      direction: random.nextBool() ? 1 : -1,
      seconds: 22 + random.nextInt(11),
    );
  }
}

class LoginScene extends StatefulWidget {
  const LoginScene({
    super.key,
    this.mode = ReactorMode.idle,
    this.profile,
    this.dayBlend,
    this.motionSpeed = 1,
  });
  final double motionSpeed;
  final ReactorMode mode;
  final ReactorProfile? profile;
  final double? dayBlend;
  @override
  State<LoginScene> createState() => _LoginSceneState();
}

class _LoginSceneState extends State<LoginScene> with TickerProviderStateMixin {
  late final profile = widget.profile ?? ReactorProfile.random();
  late final signature = profile.signature;
  late final direction = profile.direction;
  late final motion = AnimationController(
    vsync: this,
    duration: Duration(
      milliseconds: (profile.seconds * 1000 / widget.motionSpeed).round(),
    ),
    value: profile.phase,
  );
  late final transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
    value: 1,
  );
  ReactorMode? previous;
  bool reduced = false;
  @override
  void didUpdateWidget(LoginScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      previous = oldWidget.mode;
      if (reduced) {
        transition.value = 1;
      } else {
        transition.forward(from: 0);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      motion.stop();
      transition.value = 1;
    } else if (!motion.isAnimating) {
      motion.repeat();
    }
  }

  @override
  void dispose() {
    motion.dispose();
    transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: ReactorPainter(
          motion: motion,
          transition: transition,
          mode: widget.mode,
          previous: previous,
          reduced: reduced,
          signature: signature,
          direction: direction,
          dayBlend: widget.dayBlend,
          dark: Theme.of(context).brightness == Brightness.dark,
        ),
        child: const SizedBox.expand(),
      ),
    ),
  );
}

/// Paint-only animation: no widget-tree rebuilds per frame, no images or shaders
/// allocated asynchronously. All detail stays inside the supplied layout bounds.
class ReactorPainter extends CustomPainter {
  ReactorPainter({
    required this.motion,
    required this.transition,
    required this.mode,
    required this.dark,
    this.previous,
    this.reduced = false,
    this.signature = 0,
    this.direction = 1,
    this.dayBlend,
  }) : super(repaint: Listenable.merge([motion, transition]));
  final Animation<double> motion, transition;
  final ReactorMode mode;
  final ReactorMode? previous;
  final bool dark, reduced;
  final double signature, direction;
  final double? dayBlend;
  double energy(ReactorMode m) => switch (m) {
    ReactorMode.idle => .18,
    ReactorMode.listening => .48,
    ReactorMode.thinking => .72,
    ReactorMode.speaking => 1,
  };
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final radius = math.min(size.width * .44, size.height * .46);
    final t = reduced ? .0 : motion.value * math.pi * 2 * direction;
    final blend = Curves.easeInOutCubic.transform(transition.value);
    final e = energy(previous ?? mode) * (1 - blend) + energy(mode) * blend;
    final pulse = reduced ? .5 : .5 + .5 * math.sin(t * 12 + signature);
    final expressing =
        ((previous ?? mode) == ReactorMode.speaking ? 1.0 : 0.0) * (1 - blend) +
        (mode == ReactorMode.speaking ? 1.0 : 0.0) * blend;
    final expressionPulse = reduced
        ? .5
        : .5 + .5 * math.sin(t * 36 + signature);
    final daylight = dayBlend ?? (dark ? 0.0 : 1.0);
    Color tone(Color night, Color day) => Color.lerp(night, day, daylight)!;
    final white = tone(const Color(0xffe6f8ff), const Color(0xff326579));
    final cyan = tone(const Color(0xff8fdceb), const Color(0xff147f9f));
    final faint = tone(const Color(0xff39778e), const Color(0xff6a9dab));
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(
      radius / 100 * (1 + (reduced ? 0 : expressing * .032 * expressionPulse)),
    );
    final rect = Rect.fromCircle(center: Offset.zero, radius: 100);
    // An atmospheric halo rather than a square tile; legible on both themes.
    canvas.drawCircle(
      Offset.zero,
      100,
      Paint()
        ..shader = RadialGradient(
          colors: [
            cyan.withValues(
              alpha:
                  (.16 + e * .05 + expressing * .12 * expressionPulse) *
                      (1 - daylight) +
                  .07 * daylight,
            ),
            cyan.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
    canvas.drawCircle(
      Offset.zero,
      78,
      Paint()
        ..shader = RadialGradient(
          colors: [
            tone(const Color(0xff181b1e), const Color(0xffe9f8fc)),
            tone(
              const Color(0xff0d0f11),
              const Color(0xffcde9f1).withValues(alpha: .5),
            ),
            tone(
              const Color(0xff111315).withValues(alpha: .4),
              const Color(0xffeaf7fa).withValues(alpha: 0),
            ),
          ],
        ).createShader(rect),
    );
    void line(Offset a, Offset b, Color color, double width) => canvas.drawLine(
      a,
      b,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
    Offset polar(double a, double r) =>
        Offset(math.cos(a) * r, math.sin(a) * r);
    void ring(double r, Color c, double w) => canvas.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = w,
    );
    void arc(double r, double start, double sweep, Color c, double w) =>
        canvas.drawArc(
          Rect.fromCircle(center: Offset.zero, radius: r),
          start,
          sweep,
          false,
          Paint()
            ..color = c
            ..style = PaintingStyle.stroke
            ..strokeWidth = w
            ..strokeCap = StrokeCap.round,
        );
    ring(92, faint.withValues(alpha: .17), .6);
    // Precision outer telemetry: sparse accents, continuously counter-rotating.
    for (var i = 0; i < 60; i++) {
      final a = i * math.pi / 30 - t * .5;
      line(
        polar(a, i % 5 == 0 ? 86 : 89),
        polar(a, 91),
        faint.withValues(alpha: i % 5 == 0 ? .55 : .22),
        i % 5 == 0 ? .9 : .5,
      );
    }
    arc(96, t, .65, cyan.withValues(alpha: .55), .8);
    arc(96, t + math.pi, .4, cyan.withValues(alpha: .3), .8);
    ring(78, white.withValues(alpha: .8), 1.4);
    ring(75, faint.withValues(alpha: .4), .55);
    // Ten paired winding stations echo the selected B1 icon exactly.
    canvas.save();
    canvas.rotate(t * .1);
    for (var i = 0; i < 10; i++) {
      final a = -math.pi / 2 + i * math.pi / 5;
      final tangent = Offset(-math.sin(a), math.cos(a));
      for (final offset in [-2.0, 2.0]) {
        final x = tangent * offset;
        line(polar(a, 61) + x, polar(a, 72) + x, cyan.withValues(alpha: .1), 6);
        line(
          polar(a, 61) + x,
          polar(a, 72) + x,
          white.withValues(alpha: .76),
          1.7,
        );
      }
    }
    canvas.restore();
    ring(55, white.withValues(alpha: .75), 1.5);
    ring(52, faint.withValues(alpha: .36), .6);
    // Two flowing energy runners, a working rotor behind a stable identity.
    arc(58, -t * 2.0, 1.35, cyan.withValues(alpha: .14), 5);
    arc(58, -t * 2.0, 1.05, cyan.withValues(alpha: .85), 1.3);
    arc(49, t * 3 + math.pi, .9, cyan.withValues(alpha: .6), .8);
    for (var i = 0; i < 3; i++) {
      final a = -math.pi / 2 + i * math.pi * 2 / 3;
      line(polar(a, 32), polar(a, 47), white.withValues(alpha: .65), 2.2);
      canvas.drawCircle(polar(a, 48), 1.5, Paint()..color = cyan);
    }
    if (expressing > 0) {
      arc(
        83,
        -t * 7 + signature,
        .7 + expressionPulse * .6,
        cyan.withValues(alpha: expressing * (.35 + expressionPulse * .4)),
        2.2,
      );
    }
    // Central flux changes continuously with the actual conversation state.
    final core = Rect.fromCircle(center: Offset.zero, radius: 27);
    canvas.drawCircle(
      Offset.zero,
      30 + e * pulse * 2 + expressing * expressionPulse * 5,
      Paint()
        ..shader = RadialGradient(
          colors: [cyan.withValues(alpha: .28), cyan.withValues(alpha: 0)],
        ).createShader(core.inflate(12)),
    );
    ring(27, cyan.withValues(alpha: .14 + e * .08), 6);
    ring(27, cyan, 2.8);
    ring(22, faint.withValues(alpha: .35), .6);
    canvas.drawCircle(
      Offset.zero,
      20,
      Paint()
        ..shader = RadialGradient(
          colors: [
            white.withValues(
              alpha: .45 + e * pulse * .25 + expressing * expressionPulse * .18,
            ),
            cyan.withValues(alpha: .12),
            cyan.withValues(alpha: .015),
          ],
        ).createShader(core),
    );
    for (var i = 0; i < 24; i++) {
      final a = i * math.pi / 12;
      final wave = reduced
          ? .5
          : .5 + .5 * math.sin(t * 12 + i * .7 + signature);
      final length =
          1.4 +
          e * (2 + wave * 5) +
          expressing * (2 + expressionPulse * 6) * wave;
      line(
        polar(a, 34),
        polar(a, 34 + length),
        cyan.withValues(alpha: .22 + e * .35),
        1,
      );
    }
    // Tiny orbiting packets, not random frame-to-frame flicker.
    for (var i = 0; i < 4; i++) {
      final a = t * (i.isEven ? 1 : -1) + i * math.pi / 2;
      canvas.drawCircle(
        polar(a, i.isEven ? 82 : 44),
        i.isEven ? 1.3 : .9,
        Paint()..color = cyan.withValues(alpha: .75),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ReactorPainter old) =>
      old.dark != dark ||
      old.mode != mode ||
      old.previous != previous ||
      old.reduced != reduced ||
      old.dayBlend != dayBlend ||
      old.signature != signature ||
      old.direction != direction ||
      old.motion != motion ||
      old.transition != transition;
}
