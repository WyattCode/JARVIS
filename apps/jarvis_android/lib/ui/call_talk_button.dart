import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// The hands-free mark of the round talk button: five rounded bars that breathe
/// while the call is listening, and rest as small dots when it is not.
class ListeningBars extends StatefulWidget {
  const ListeningBars({super.key, required this.active, required this.color});
  final bool active;
  final Color color;

  @override
  State<ListeningBars> createState() => _ListeningBarsState();
}

class _ListeningBarsState extends State<ListeningBars>
    with TickerProviderStateMixin {
  static const heights = [12.0, 22.0, 32.0, 22.0, 12.0];
  late final AnimationController clock = AnimationController(
    vsync: this,
    // A day: the bars breathe for as long as a call can last.
    duration: const Duration(hours: 24),
  );
  late final AnimationController rise = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 250),
    value: widget.active ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) clock.forward();
  }

  @override
  void didUpdateWidget(ListeningBars old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active) return;
    if (widget.active) {
      clock.forward();
      rise.forward();
    } else {
      rise.reverse().whenComplete(() {
        if (mounted && !widget.active) clock.stop();
      });
    }
  }

  @override
  void dispose() {
    clock.dispose();
    rise.dispose();
    super.dispose();
  }

  /// A bar breathes between .45 and 1 and back, each on its own period and
  /// starting a little after the one before it.
  double breath(int i, double seconds) {
    final period = .55 + (i % 3) * .13;
    final x = (seconds - i * .09) / period;
    if (x < 0) return .45;
    final phase = x % 2;
    final tri = phase <= 1 ? phase : 2 - phase;
    return .45 + .55 * Curves.easeInOut.transform(tri);
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      width: 46,
      height: 34,
      child: AnimatedBuilder(
        animation: Listenable.merge([clock, rise]),
        builder: (context, _) {
          final seconds = clock.value * 86400;
          return Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < heights.length; i++) ...[
                if (i > 0) const SizedBox(width: 5),
                Container(
                  width: 5,
                  height:
                      heights[i] *
                      (.35 +
                          ((still ? 1.0 : breath(i, seconds)) - .35) *
                              rise.value),
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// The round, label-less talk button of the iOS call page: system-glass look,
/// the held state drawn over it in the reactor's light. A microphone for
/// hold-to-talk, sound bars for hands-free. Touch handling belongs to the page.
class CallTalkButton extends StatelessWidget {
  const CallTalkButton({
    super.key,
    required this.ptt,
    required this.ready,
    required this.held,
    required this.muted,
    required this.listening,
  });
  final bool ptt, ready, held, muted;

  /// Hands-free, ready and not muted: the bars breathe.
  final bool listening;

  static const energy = Color(0xff8fdceb);
  static const ink = Color(0xff152126);
  static const size = 80.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final still = MediaQuery.disableAnimationsOf(context);
    final duration = still
        ? Duration.zero
        : Duration(milliseconds: held ? 80 : 160);
    final mark = held ? ink : (muted ? colors.error : colors.onSurface);
    final dark = colors.brightness == Brightness.dark;
    return AnimatedOpacity(
      opacity: ready ? 1 : .38,
      duration: still ? Duration.zero : const Duration(milliseconds: 120),
      child: AnimatedScale(
        scale: held ? .96 : 1,
        curve: Curves.easeOutCubic,
        duration: duration,
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: held
                  ? [
                      BoxShadow(
                        color: energy.withValues(alpha: .34),
                        blurRadius: 22,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: AnimatedContainer(
                  key: const Key('voice-hold-surface'),
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: held
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color.lerp(Colors.white, energy, .5)!,
                              energy,
                              Color.lerp(energy, const Color(0xff408eac), .12)!,
                            ],
                          )
                        : null,
                    color: held
                        ? null
                        : colors.onSurface.withValues(alpha: dark ? .12 : .07),
                    border: Border.all(
                      color: held
                          ? energy.withValues(alpha: .5)
                          : muted
                          ? colors.error
                          : Colors.transparent,
                      width: muted && !held ? 2 : 1,
                    ),
                  ),
                  child: Center(
                    child: ptt
                        ? Icon(Icons.mic_rounded, size: 34, color: mark)
                        : ListeningBars(active: listening, color: mark),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
