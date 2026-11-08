import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../voice/spoken_text.dart';

/// JARVIS's words on the call page, lit as they are said: what the voice has
/// said is bright, what is still to come is dim, and at the front of the bright
/// part is a soft edge that moves on a character at a time and leaves a faint
/// cyan glow that dies away behind it. Nothing is boxed or underlined.
///
/// Where the voice is comes from `VoiceSession.speechProgress` (an estimate,
/// see `SpokenText`); this view only draws it, so the edge is soft on purpose:
/// it never claims to be exact. Without progress (a reply said to the end, or
/// one not being said yet) the text is plain. (As on the iOS call page.)
class SpokenTextView extends StatefulWidget {
  const SpokenTextView({
    super.key,
    required this.text,
    required this.size,
    required this.progress,
    this.onLine,
    this.now,
  });
  final String text;
  final double size;

  /// Asked about 30 times a second while the voice goes.
  final SpeechProgress? Function() progress;

  /// Called with the line the edge is on (global coordinates) when it has a new
  /// place: it moved to the next line, or the lines were re-flowed.
  final void Function(Rect line)? onLine;

  /// The clock, in seconds (a test sets its own).
  final double Function()? now;

  @override
  State<SpokenTextView> createState() => _SpokenTextViewState();
}

class _SpokenTextViewState extends State<SpokenTextView> {
  /// Characters behind the edge over which the glow dies away, and over which a
  /// character comes up from dim to bright.
  static const trail = 16;
  static const rise = 3.0;

  late SpokenText spoken = SpokenText(widget.text);
  final limiter = ReadingEdge();
  final paragraph = GlobalKey();
  Timer? timer;
  double? edge;
  Rect? lastLine;
  double lastWidth = 0;
  final stopwatch = Stopwatch()..start();

  double get clock => widget.now?.call() ?? stopwatch.elapsedMicroseconds / 1e6;

  @override
  void initState() {
    super.initState();
    _look(notify: false);
  }

  @override
  void didUpdateWidget(SpokenTextView old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      spoken = SpokenText(widget.text);
      lastLine = null;
    }
    // A build follows: nothing to ask for.
    _look(notify: false);
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  /// Takes the voice's place and draws it; keeps a 30 Hz look going only while
  /// the reply is being said (a frame at that rate is all the edge needs).
  void _look({bool notify = true}) {
    final progress = widget.progress();
    final raw = progress?.position(spoken);
    double? target;
    if (raw != null && progress != null) {
      final limit = spoken.clusters.length.toDouble();
      target = math.min(
        progress.cut ? limiter.freeze(raw) : limiter.advance(raw, clock),
        limit,
      );
    } else {
      limiter.reset();
    }
    if (target != edge) {
      edge = target;
      if (notify && mounted) setState(() {});
    }
    final live = progress?.live == true;
    if (live && timer == null) {
      timer = Timer.periodic(const Duration(milliseconds: 33), (_) => _look());
    } else if (!live && timer != null) {
      timer!.cancel();
      timer = null;
    }
    _locate();
  }

  /// Tells the page which line the edge is on, when that changed.
  void _locate() {
    final p = edge;
    if (p == null || spoken.clusters.isEmpty || widget.onLine == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final render = paragraph.currentContext?.findRenderObject();
      if (render is! RenderParagraph || !render.hasSize) return;
      final k = p.floor().clamp(0, spoken.clusters.length - 1);
      final (from, to) = spoken.clusters[k];
      final boxes = render.getBoxesForSelection(
        TextSelection(baseOffset: from, extentOffset: to),
      );
      if (boxes.isEmpty) return;
      final line = MatrixUtils.transformRect(
        render.getTransformTo(null),
        boxes.first.toRect(),
      );
      final width = render.size.width;
      if (line != lastLine || width != lastWidth) {
        lastLine = line;
        lastWidth = width;
        widget.onLine!(line);
      }
    });
  }

  TextStyle _style(Color color, {bool heavy = false, List<Shadow>? shadows}) =>
      TextStyle(
        fontSize: widget.size,
        height: (widget.size * 1.2 + 4) / widget.size,
        color: color,
        fontWeight: heavy ? FontWeight.w600 : FontWeight.w400,
        shadows: shadows,
      );

  /// Characters [from] to [to] (cluster numbers) in one colour, split where
  /// the heavier runs begin and end.
  void _block(List<InlineSpan> out, int from, int to, Color color) {
    if (from >= to) return;
    final text = spoken.plain;
    var start = spoken.clusters[from].$1;
    final end = spoken.clusters[to - 1].$2;
    for (final run in spoken.bold) {
      if (run.$2 <= start) continue;
      if (run.$1 >= end) break;
      if (run.$1 > start) {
        out.add(
          TextSpan(text: text.substring(start, run.$1), style: _style(color)),
        );
        start = run.$1;
      }
      final cut = math.min(run.$2, end);
      out.add(
        TextSpan(
          text: text.substring(start, cut),
          style: _style(color, heavy: true),
        ),
      );
      start = cut;
    }
    if (start < end) {
      out.add(TextSpan(text: text.substring(start, end), style: _style(color)));
    }
  }

  bool _heavy(int unit) {
    for (final run in spoken.bold) {
      if (unit >= run.$1 && unit < run.$2) return true;
      if (run.$1 > unit) break;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lit = colors.onSurface;
    final dim = colors.onSurface.withValues(alpha: .5);
    final glow = colors.brightness == Brightness.dark
        ? const Color(0xff8fdceb)
        : const Color(0xff137589);
    final p = edge;
    final n = spoken.clusters.length;
    final spans = <InlineSpan>[];
    if (p == null || n == 0 || !p.isFinite) {
      _block(spans, 0, n, lit);
    } else {
      final lo = math.min(math.max(0, p.floor() - trail), n);
      final hi = math.min(math.max(lo, p.ceil() + 1), n);
      _block(spans, 0, lo, lit);
      for (var k = lo; k < hi; k++) {
        // How far behind the edge this character is (a character is half said
        // when the edge is at its middle).
        final d = p - k - .5;
        final t = (d / rise).clamp(0.0, 1.0);
        final up = t * t * (3 - 2 * t);
        final flash = d > 0
            ? math.min(1.0, (d / 2) * math.exp(1 - d / 2))
            : 0.0;
        var color = Color.lerp(dim, lit, up)!;
        color = Color.lerp(color, glow, flash * .6)!;
        final (from, to) = spoken.clusters[k];
        spans.add(
          TextSpan(
            text: spoken.plain.substring(from, to),
            style: _style(
              color,
              heavy: _heavy(from),
              shadows: flash > .05
                  ? [
                      Shadow(
                        color: glow.withValues(alpha: flash * .85),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
          ),
        );
      }
      _block(spans, hi, n, dim);
    }
    return Text.rich(
      TextSpan(children: spans, style: _style(lit)),
      key: paragraph,
    );
  }
}
