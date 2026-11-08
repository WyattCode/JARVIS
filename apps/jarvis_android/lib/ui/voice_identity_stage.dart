import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/physics.dart';

import 'package:flutter/material.dart';

import 'jarvis_app.dart' show CoreAvatar;
import '../model/fold_proportions.dart';
import 'login_art.dart' show ReactorMode;

/// One retained reactor moves from welcome to transcript; no cross-faded clones.
class VoiceIdentityStage extends StatelessWidget {
  const VoiceIdentityStage({
    super.key,
    required this.compact,
    required this.windowHeight,
    required this.identity,
    required this.status,
    required this.hint,
    required this.mode,
    required this.onTap,
    required this.transcript,
    this.minimumTranscriptExtent = 72,
    this.waveform,
    this.hintIsError = false,
  });

  /// The hint is an error (drawn in the error colour).
  final bool hintIsError;
  final bool compact;
  final double windowHeight;
  final Object? identity;
  final String status, hint;
  final ReactorMode mode;
  final VoidCallback onTap;
  final Widget transcript;
  final double minimumTranscriptExtent;
  final Widget? waveform;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final colors = Theme.of(context).textTheme;
      final scaler = MediaQuery.textScalerOf(context);
      // One page for every phone, as on iOS: a straight phone gets the same
      // stage as the foldable (the round talk button, the large reactor that
      // moves up once someone speaks).
      const aspect = 1.0;
      const compactSize = FoldProportions.callCompactFigure;
      final labelOffset = compactSize + 14;
      final statusStyle = colors.titleMedium!.copyWith(
        fontSize: compact ? FoldProportions.callStatus : 20,
        fontWeight: FontWeight.w600,
      );
      final scheme = Theme.of(context).colorScheme;
      final hintStyle = colors.bodySmall!.copyWith(
        fontSize: compact ? FoldProportions.callHint : 14,
        // The explanation is quiet; an error is not.
        color: hintIsError ? scheme.error : scheme.onSurfaceVariant,
      );
      ({double height, double width, double baseline}) measure(
        String text,
        TextStyle style,
        double width,
        int lines,
      ) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: lines,
        )..layout(maxWidth: math.max(1, width));
        final result = (
          height: painter.height,
          width: painter.width,
          baseline: painter.computeDistanceToActualBaseline(
            TextBaseline.alphabetic,
          ),
        );
        painter.dispose();
        return result;
      }

      final width = bounds.maxWidth, height = bounds.maxHeight;
      final compactWidth = math.max(1.0, width - labelOffset);
      final gap = windowHeight < 500 ? 6.0 : 12.0;
      final headerBudget = compact
          ? math.max(
              compactSize * aspect,
              height - math.min(minimumTranscriptExtent, height * .65) - gap,
            )
          : double.infinity;
      const inlineGap = 14.0;
      final naturalStatus = measure(status, statusStyle, compactWidth, 1);
      // Keep normal-size labels on one baseline; large accessibility text can
      // use the stacked layout rather than squeeze the explanation to nothing.
      final inline =
          compact &&
          compactWidth >= naturalStatus.width + inlineGap + scaler.scale(64);
      final statusWidth = inline ? naturalStatus.width : compactWidth;
      final statusLines =
          inline ||
              (compact &&
                  measure(status, statusStyle, compactWidth, 2).height >
                      headerBudget * .5)
          ? 1
          : 2;
      final statusMetrics = measure(
        status,
        statusStyle,
        statusWidth,
        statusLines,
      );
      final statusHeight = statusMetrics.height;
      final hintWidth = inline
          ? math.max(1.0, compactWidth - statusWidth - inlineGap)
          : compactWidth;
      final hintLine = measure('字', hintStyle, hintWidth, 1);
      final baselineDelta = inline
          ? math.max(0.0, statusMetrics.baseline - hintLine.baseline)
          : 0.0;
      // At most two lines, and none while there is nothing to say.
      final hintLines = hint.isEmpty
          ? 0
          : compact
          ? ((headerBudget - (inline ? baselineDelta : statusHeight + 4)) /
                    hintLine.height)
                .floor()
                .clamp(0, 2)
          : 2;
      final hintHeight = hintLines == 0
          ? 0.0
          : measure(hint, hintStyle, hintWidth, hintLines).height;
      final labelGap = hintLines == 0 ? 0.0 : 4.0;
      final labelHeight = inline
          ? math.max(statusHeight, baselineDelta + hintHeight)
          : statusHeight + labelGap + hintHeight;
      final waveHeight = waveform == null
          ? 0.0
          : compact
          ? (headerBudget - labelHeight - 8).clamp(0.0, 16.0)
          : 16.0;
      final waveGap = waveHeight > 0 ? 10.0 : 0.0;
      const identityGap = FoldProportions.callIdleGap;
      const idleHintGap = FoldProportions.callLabelGap;
      final rowHeight = math.max(
        compactSize * aspect,
        labelHeight + waveGap + waveHeight,
      );
      final blockTop = math.max(
        0.0,
        (rowHeight - labelHeight - waveGap - waveHeight) / 2,
      );

      final largeSize = math.min(
        width,
        math.min(
          FoldProportions.callIdleFigure,
          math.max(
            56.0,
            (height -
                    (identityGap +
                        statusHeight +
                        idleHintGap +
                        hintHeight +
                        waveGap +
                        waveHeight)) /
                aspect,
          ),
        ),
      );
      // The idle reactor stands 48 below the top (as on iOS), less where the
      // window has no room for that.
      final largeTop = math.max(
        0.0,
        math.min(
          48.0,
          height -
              (largeSize * aspect +
                  identityGap +
                  statusHeight +
                  idleHintGap +
                  hintHeight +
                  waveGap +
                  waveHeight),
        ),
      );
      final still = MediaQuery.disableAnimationsOf(context);
      return TweenAnimationBuilder<double>(
        tween: Tween(end: compact ? 1 : 0),
        // A spring, as on iOS (0.65 s, damping .9): quick away, a long settle.
        duration: Duration(milliseconds: still ? 0 : 650),
        curve: const _StageSpring(),
        builder: (context, progress, _) {
          // The status, the hint and the level bars change their arrangement,
          // their sizes and their type: none of that can be tweened, so they
          // are not seen while it happens and come back in the new
          // arrangement as the reactor settles (0.3 s, after a 0.3 s wait).
          final info = progress <= 0 || progress >= 1
              ? 1.0
              : Curves.easeOut.transform(
                  ((progress - .46) / .46).clamp(0.0, 1.0),
                );
          final size = lerpDouble(largeSize, compactSize, progress)!;
          final avatarX = lerpDouble((width - largeSize) / 2, 0, progress)!;
          final avatarY = lerpDouble(
            largeTop,
            math.max(0, (rowHeight - compactSize * aspect) / 2),
            progress,
          )!;
          final textX = labelOffset * progress;
          final statusY = lerpDouble(
            largeTop + largeSize * aspect + identityGap,
            blockTop,
            progress,
          )!;
          final hintY = lerpDouble(
            largeTop +
                largeSize * aspect +
                identityGap +
                statusHeight +
                idleHintGap,
            blockTop + (inline ? baselineDelta : statusHeight + labelGap),
            progress,
          )!;
          final waveY = lerpDouble(
            largeTop +
                largeSize * aspect +
                identityGap +
                statusHeight +
                idleHintGap +
                hintHeight +
                waveGap,
            blockTop + labelHeight + waveGap,
            progress,
          )!;
          final transcriptTop = lerpDouble(
            height,
            math.min(height, rowHeight + 16),
            progress,
          )!;
          return ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: avatarX,
                  top: avatarY,
                  width: size,
                  height: size * aspect,
                  child: Semantics(
                    label: hintLines == 0 ? hint : null,
                    child: GestureDetector(
                      onTap: onTap,
                      child: CoreAvatar(
                        key: ValueKey('voice-reactor-$identity'),
                        size: size,
                        mode: mode,
                        motionSpeed: 1.2,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: textX,
                  right: inline ? (compactWidth - statusWidth) * progress : 0,
                  top: statusY,
                  child: Opacity(
                    opacity: info,
                    child: Align(
                      alignment: Alignment.lerp(
                        Alignment.center,
                        Alignment.centerLeft,
                        progress,
                      )!,
                      child: _Dissolve(
                        still: still,
                        alignment: Alignment.lerp(
                          Alignment.center,
                          Alignment.centerLeft,
                          progress,
                        )!,
                        child: Text(
                          status,
                          key: ValueKey(status),
                          maxLines: statusLines,
                          overflow: TextOverflow.ellipsis,
                          style: statusStyle,
                        ),
                      ),
                    ),
                  ),
                ),
                if (hintLines > 0)
                  Positioned(
                    left:
                        textX +
                        (inline ? (statusWidth + inlineGap) * progress : 0),
                    right: 0,
                    top: hintY,
                    child: Opacity(
                      opacity: info,
                      child: Align(
                        alignment: Alignment.lerp(
                          Alignment.center,
                          Alignment.centerLeft,
                          progress,
                        )!,
                        child: _Dissolve(
                          still: still,
                          alignment: Alignment.lerp(
                            Alignment.center,
                            Alignment.centerLeft,
                            progress,
                          )!,
                          child: Text(
                            hint,
                            key: ValueKey(hint),
                            maxLines: hintLines,
                            overflow: TextOverflow.ellipsis,
                            textAlign: progress < .5
                                ? TextAlign.center
                                : TextAlign.start,
                            style: hintStyle,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (waveHeight > 0)
                  Positioned(
                    left: textX,
                    right: 0,
                    top: waveY,
                    height: waveHeight,
                    child: Opacity(
                      opacity: info,
                      // At rest the bars stand 240 wide in the middle; beside
                      // the reactor they fill the room the labels have.
                      child: Align(
                        alignment: Alignment.lerp(
                          Alignment.center,
                          Alignment.centerLeft,
                          progress,
                        )!,
                        child: SizedBox(
                          width: lerpDouble(
                            math.min(240.0, width),
                            math.max(1.0, width - textX),
                            progress,
                          ),
                          height: waveHeight,
                          child: waveform!,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: transcriptTop,
                  bottom: 0,
                  child: ExcludeSemantics(
                    excluding: progress < .85,
                    child: IgnorePointer(
                      ignoring: progress < .85,
                      child: Opacity(
                        opacity: ((progress - .2) / .8).clamp(0.0, 1.0),
                        child: transcript,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

/// UIKit's spring (damping ratio .9, settled in about .65 s), as a curve.
class _StageSpring extends Curve {
  const _StageSpring();
  static final _sim = SpringSimulation(
    SpringDescription.withDampingRatio(mass: 1, stiffness: 75, ratio: .9),
    0,
    1,
    0,
  );

  @override
  double transformInternal(double t) => _sim.x(t * .65);
}

/// Words that change dissolve over 0.2 s (and only when they really changed:
/// the page keeps still while its state ticks over).
class _Dissolve extends StatelessWidget {
  const _Dissolve({
    required this.still,
    required this.child,
    this.alignment = Alignment.center,
  });
  final bool still;
  final Widget child;

  /// Where the old and the new words stand while they change places: where the
  /// words themselves are aligned, so that they do not jump sideways.
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => still
      ? child
      : AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          layoutBuilder: (current, previous) => Stack(
            alignment: alignment,
            children: [...previous, ?current],
          ),
          child: child,
        );
}
