import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The talking-way switch of the call page: a glass capsule with two places and
/// a raised pill that moves to the one that is on. A finger pointing: hold to
/// talk. Sound bars: hands-free. Along the top the two places stand side by
/// side; along a side strip they are stacked. (The iOS call page's switch.)
class CallModeToggle extends StatefulWidget {
  const CallModeToggle({
    super.key,
    required this.ptt,
    required this.onChanged,
    this.horizontal = true,
  });
  final bool ptt, horizontal;

  /// `ptt` or `vad`.
  final ValueChanged<String> onChanged;

  @override
  State<CallModeToggle> createState() => _CallModeToggleState();
}

class _CallModeToggleState extends State<CallModeToggle>
    with SingleTickerProviderStateMixin {
  static const rim = 2.0, inset = 5.0, thickness = 48.0, length = 100.0;
  late final AnimationController motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  late bool from = widget.ptt, to = widget.ptt;

  @override
  void initState() {
    super.initState();
    motion.value = 1;
  }

  @override
  void didUpdateWidget(CallModeToggle old) {
    super.didUpdateWidget(old);
    // A tap on the switch already moved the pill; a change from elsewhere (the
    // settings) moves it as a tap would.
    if (old.ptt != widget.ptt && to != widget.ptt) _move(widget.ptt);
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  void _move(bool toPtt) {
    final now = _held;
    from = now;
    to = toPtt;
    if (MediaQuery.disableAnimationsOf(context)) {
      motion.value = 1;
    } else {
      motion.forward(from: 0);
    }
  }

  /// Which place the pill is (nearer to) now.
  bool get _held => motion.value >= .5 ? to : from;

  /// A place's extent along the capsule's long axis.
  (double, double) _place(bool top) {
    const side = thickness - 2 * rim;
    final start = top ? rim : length - rim - side;
    return (start + (inset - rim), start + side - (inset - rim));
  }

  void _choose(bool wantsHold) {
    if (wantsHold == widget.ptt) return;
    HapticFeedback.selectionClick();
    // The pill moves at once, as a tap would; the parent's state follows.
    _move(wantsHold);
    widget.onChanged(wantsHold ? 'ptt' : 'vad');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final width = widget.horizontal ? length : thickness;
    final height = widget.horizontal ? thickness : length;
    Widget icon(IconData data, bool isPtt) => AnimatedBuilder(
      animation: motion,
      builder: (context, _) {
        // The icons trade colours while the pill passes.
        final on = Curves.easeOut.transform(
          (motion.value * 380 / 200).clamp(0.0, 1.0),
        );
        final selectedNow = (to == isPtt);
        final t = selectedNow ? on : 1 - on;
        return Icon(
          data,
          size: 22,
          color: Color.lerp(colors.onSurface, colors.surface, t),
        );
      },
    );

    Widget place(bool top, IconData data, String key, String choice) {
      final label = '切换到$choice';
      final isPtt = top;
      return SizedBox(
        width: widget.horizontal ? thickness - 2 * rim : null,
        height: widget.horizontal ? null : thickness - 2 * rim,
        child: Semantics(
          key: ValueKey(key),
          button: true,
          selected: widget.ptt == isPtt,
          label: label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _choose(isPtt),
            child: Center(child: icon(data, isPtt)),
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      label: '对话方式',
      value: widget.ptt ? '按住说话' : '免按说话',
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(thickness / 2),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: DecoratedBox(
              key: const Key('call-mode-toggle'),
              decoration: BoxDecoration(
                color: colors.onSurface.withValues(alpha: dark ? .12 : .07),
                borderRadius: BorderRadius.circular(thickness / 2),
                border: Border.all(
                  color: colors.outlineVariant.withValues(alpha: .5),
                  width: .5,
                ),
              ),
              child: Stack(
                children: [
                  AnimatedBuilder(
                    animation: motion,
                    builder: (context, _) {
                      // The pill stretches towards the other place and then
                      // draws in behind itself, as one drop of liquid does.
                      final (fromA, fromB) = _place(from);
                      final (toA, toB) = _place(to);
                      final forward = toA > fromA;
                      final t = motion.value;
                      final lead = Curves.easeOutCubic.transform(
                        (t / .6).clamp(0.0, 1.0),
                      );
                      final trail = Curves.easeInOutCubic.transform(t);
                      double lerp(double a, double b, double k) =>
                          a + (b - a) * k;
                      final a = lerp(fromA, toA, forward ? trail : lead);
                      final b = lerp(fromB, toB, forward ? lead : trail);
                      const cross = rim + (inset - rim);
                      return Positioned(
                        left: widget.horizontal ? a : cross,
                        top: widget.horizontal ? cross : a,
                        width: widget.horizontal
                            ? b - a
                            : thickness - 2 * cross,
                        height: widget.horizontal
                            ? thickness - 2 * cross
                            : b - a,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.onSurface,
                            borderRadius: BorderRadius.circular(thickness),
                          ),
                        ),
                      );
                    },
                  ),
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(rim),
                      child: widget.horizontal
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                place(
                                  true,
                                  Icons.touch_app_rounded,
                                  'voice-mode-ptt',
                                  '按住说话',
                                ),
                                place(
                                  false,
                                  Icons.graphic_eq_rounded,
                                  'voice-mode-vad',
                                  '免按说话',
                                ),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                place(
                                  true,
                                  Icons.touch_app_rounded,
                                  'voice-mode-ptt',
                                  '按住说话',
                                ),
                                place(
                                  false,
                                  Icons.graphic_eq_rounded,
                                  'voice-mode-vad',
                                  '免按说话',
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
